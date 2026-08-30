#!/usr/bin/env bash
# HARDENED twin of 20-kind-up.sh. Same lab, two bugs fixed:
#   BUG 1 (detection):  gVisor pod + host-eBPF Falco => Falco BLIND.
#                       FIX -> Falco's gVisor driver: runsc exports its intercepted syscalls to
#                       Falco over a socket, so detection lives INSIDE the mediator.
#   BUG 2 (enforcement): kindnet CNI ignores NetworkPolicy => deny-egress.yaml is decorative.
#                       FIX -> Calico CNI, which actually enforces NetworkPolicy.
#
# The vulnerable path (20/30) is left UNTOUCHED. Run this to stand up the fixed contrast cluster,
# then ./31-demo-fixed.sh. Both clusters can coexist (different names).
#
# STATUS: written correct-by-construction against the real Falco chart flags + gVisor runtime
# monitoring config, but NOT yet live-validated (the A10 was terminated). See VALIDATION.md.
set -euo pipefail
CLUSTER="evallab-hardened"
HERE="$(cd "$(dirname "$0")" && pwd)"
CALICO_VER="v3.27.3"

say(){ printf '\n\033[1;32m== %s ==\033[0m\n' "$*"; }

say "Create kind cluster '$CLUSTER' with kindnet DISABLED (Calico will own the network)"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --config "${HERE}/manifests/kind-hardened.yaml" --wait 120s
else
  echo "cluster exists, reusing"
fi
kubectl cluster-info --context "kind-${CLUSTER}"

# --- BUG 2 FIX: real, policy-enforcing CNI -------------------------------------------------
say "Install Calico CNI (enforces NetworkPolicy, unlike kindnet)"
# NOTE: use server-side apply — the tigera-operator manifest's Installation CRD carries
# annotations larger than kubectl's client-side last-applied limit (262144 bytes), so a plain
# `kubectl apply` fails with "metadata.annotations: Too long". (Found on first live run.)
kubectl apply --server-side --force-conflicts -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VER}/manifests/tigera-operator.yaml"
# Match Calico's IP pool to kind's podSubnet (10.244.0.0/16 from kind-hardened.yaml).
kubectl apply -f - <<'YAML'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - cidr: 10.244.0.0/16
        encapsulation: VXLANCrossSubnet
YAML
echo "waiting for Calico to be ready..."
kubectl -n calico-system wait --for=condition=Available deploy --all --timeout=300s || true
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# --- gVisor into the node (same as vuln path) ---------------------------------------------
say "Install gVisor (runsc) into the kind node + register the runsc containerd runtime"
NODE="$(kind get nodes --name "$CLUSTER" | head -1)"
for b in runsc containerd-shim-runsc-v1; do
  docker cp "/usr/local/bin/${b}" "${NODE}:/usr/local/bin/${b}"
  docker exec "$NODE" chmod 0755 "/usr/local/bin/${b}"
done

# --- BUG 1 FIX: point runsc at Falco, and register runtime with the pod-init trace config ---
say "Wire runsc runtime monitoring -> Falco (this is what un-blinds detection)"
docker exec "$NODE" mkdir -p /run/falco
docker cp "${HERE}/manifests/pod-init-gvisor.json" "${NODE}:/etc/containerd/runsc-pod-init.json"
if ! docker exec "$NODE" grep -q 'runtimes.runsc' /etc/containerd/config.toml; then
  docker exec "$NODE" bash -c 'cat >> /etc/containerd/config.toml <<TOML

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
  ConfigPath = "/etc/containerd/runsc.toml"
TOML'
  # runsc.toml turns on the monitoring interface + points at the trace/pod-init config.
  docker exec "$NODE" bash -c 'cat > /etc/containerd/runsc.toml <<TOML
[runsc_config]
  pod-init-config = "/etc/containerd/runsc-pod-init.json"
TOML'
  docker exec "$NODE" systemctl restart containerd
  kubectl wait --for=condition=Ready "node/${NODE}" --timeout=180s
fi
kubectl apply -f "${HERE}/manifests/runtimeclass-gvisor.yaml"

# --- evals namespace + default-deny egress (now actually ENFORCED by Calico) --------------
say "Create evals namespace + default-deny egress (Calico enforces it now)"
kubectl create namespace evals --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/manifests/deny-egress.yaml"

# --- Falco (host eBPF) — and WHY it stays blind to gVisor here on purpose --------------------
# !! FALCO+gVISOR IS DEAD UPSTREAM (established on the live run, 2026-08-29). We chased it to the
#    end; all three rungs are broken:
#      - Falco binary 0.44:   gVisor engine + `--gvisor-generate-config` REMOVED (deprecated 0.43).
#      - Falco chart 9.1.0:   `driver.kind=gvisor` hard-fails ("no longer supported").
#      - Falco chart 8.0.5 / app 0.43.1 (the LAST version with gVisor): its gvisor-init container
#        crash-loops — the init script calls `/bin/bash`, absent from the 0.43.1 image
#        (exec: "/bin/bash": no such file or directory). Broken against its own image.
#    Conclusion: you cannot un-blind a gVisor pod with host-side Falco anymore without forking
#    Falco's images. This is the field conceding the lab's own thesis — you can't monitor a layer
#    built to be opaque to you. So the DURABLE un-blinding is NOT host-syscall capture; it is:
#      1. EGRESS at the CNI/proxy  -> Calico, VALIDATED above (connect from the gVisor pod BLOCKED).
#      2. A trusted TOOL-BROKER / exec-ledger reconciled against the transcript -> see 70-transcript
#         -spoof.sh (works regardless of runtime; the broker records truth the sandbox can't edit).
#    We install host-eBPF Falco below so the cluster is usable and the runc-vs-gVisor contrast from
#    the vuln lab still holds; it is BLIND to the gVisor pod on purpose. See VALIDATION.md.
say "Install Falco (host eBPF; blind to gVisor by design — see comment: Falco+gVisor is EOL upstream)"
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set-file "customRules.eval_rules\.yaml=${HERE}/manifests/falco-eval-rules.yaml" \
  --wait --timeout 5m || {
    echo "!! Falco install failed. Check kernel BTF (ls /sys/kernel/btf/vmlinux) or chart drift."
  }
echo "NOTE: host-eBPF Falco is BLIND to the gVisor pod by design. Detection that survives gVisor"
echo "      lives at the egress boundary (Calico, validated) and the tool-broker ledger (see 70)."

say "Hardened cluster ready"
kubectl get runtimeclass
kubectl get ns evals falco
echo
echo "Next: ./31-demo-fixed.sh   (same breakout as 30, but now Falco FIRES and egress is BLOCKED)"
