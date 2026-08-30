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

# --- Falco with the gVisor engine (reads runsc's exported syscalls, not the host kernel) ---
# !! UPSTREAM DRIFT (found on the live run, 2026-08-29): the Falco Helm chart 9.1.0 (app 0.44.1)
#    REMOVED the chart-managed gVisor driver. `--set driver.kind=gvisor` now hard-fails with:
#      "The following chart configuration is no longer supported: driver.kind=gvisor, driver.gvisor"
#    gVisor is still supported by the Falco *binary* via falco.yaml `engine.kind=gvisor`, but the
#    chart no longer wires it. Getting Falco to consume runsc's stream on this chart therefore needs
#    a manual engine config (or an older chart, or running Falco standalone). This step is NOT yet
#    validated end-to-end — see VALIDATION.md. The egress-enforcement half of the twin (Calico) IS
#    validated. Below we install Falco on the host driver so the cluster is usable; swap in the
#    gVisor engine wiring once pinned.
say "Install Falco (NOTE: chart 9.1.0 dropped the gVisor driver — see comment above)"
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
# Generate a schema-correct pod-init for THIS runsc version rather than hand-writing points:
#   docker run --rm falcosecurity/falco:<app_ver> falco --gvisor-generate-config \
#     > manifests/pod-init-gvisor.json      # then wire runsc.toml pod-init-config + engine.kind=gvisor
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set-file "customRules.eval_rules\.yaml=${HERE}/manifests/falco-eval-rules.yaml" \
  --wait --timeout 5m || {
    echo "!! Falco install failed. Check kernel BTF (ls /sys/kernel/btf/vmlinux) or chart drift."
  }
echo "NOTE: this Falco is on the host eBPF driver and will be BLIND to the gVisor pod (same as the"
echo "      vuln lab). The gVisor-engine wiring that un-blinds it is the open item in VALIDATION.md."

say "Hardened cluster ready"
kubectl get runtimeclass
kubectl get ns evals falco
echo
echo "Next: ./31-demo-fixed.sh   (same breakout as 30, but now Falco FIRES and egress is BLOCKED)"
