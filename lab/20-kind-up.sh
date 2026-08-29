#!/usr/bin/env bash
# Stand up the kind cluster and install the control-plane pieces:
#   gVisor RuntimeClass, Falco (runtime detection), Kyverno (admission), evals namespace + deny-egress.
set -euo pipefail
CLUSTER="evallab"
HERE="$(cd "$(dirname "$0")" && pwd)"

say(){ printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

say "Create kind cluster '$CLUSTER'"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --name "$CLUSTER" --wait 120s
else
  echo "cluster exists, reusing"
fi
kubectl cluster-info --context "kind-${CLUSTER}"

# --- gVisor into the kind node ---------------------------------------------------------
# kind runs the node as a Docker container with its own containerd (managed by systemd inside
# the node). We copy runsc in and register a 'runsc' containerd runtime, then restart containerd.
say "Install gVisor (runsc) into the kind node"
NODE="$(kind get nodes --name "$CLUSTER" | head -1)"   # e.g. evallab-control-plane
for b in runsc containerd-shim-runsc-v1; do
  docker cp "/usr/local/bin/${b}" "${NODE}:/usr/local/bin/${b}"
  docker exec "$NODE" chmod 0755 "/usr/local/bin/${b}"
done
# Register the runtime if not already present.
if ! docker exec "$NODE" grep -q 'runtimes.runsc' /etc/containerd/config.toml; then
  docker exec "$NODE" bash -c 'cat >> /etc/containerd/config.toml <<EOF

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
EOF'
  docker exec "$NODE" systemctl restart containerd
  echo "waiting for node Ready after containerd restart..."
  kubectl wait --for=condition=Ready "node/${NODE}" --timeout=120s
fi
kubectl apply -f "${HERE}/manifests/runtimeclass-gvisor.yaml"
echo "RuntimeClass 'gvisor' registered."

# --- evals namespace + default-deny egress ---------------------------------------------
say "Create evals namespace + default-deny egress NetworkPolicy"
kubectl create namespace evals --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "${HERE}/manifests/deny-egress.yaml"

# --- Falco (modern eBPF) ---------------------------------------------------------------
say "Install Falco (modern eBPF driver) with the eval breakout rules"
helm repo add falcosecurity https://falcosecurity.github.io/charts >/dev/null 2>&1 || true
helm repo update >/dev/null
# Load our custom rules via a values override that appends a custom rules file.
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set-file "customRules.eval_rules\.yaml=${HERE}/manifests/falco-eval-rules.yaml" \
  --wait --timeout 5m || {
    echo "!! Falco install failed. Most common cause: kernel lacks CO-RE BTF."
    echo "   Check: ls /sys/kernel/btf/vmlinux . If missing, try --set driver.kind=ebpf (legacy probe)."
  }
echo "Falco events:  kubectl -n falco logs -l app.kubernetes.io/name=falco -f | grep -i eval"

# --- Kyverno (admission control) -------------------------------------------------------
say "Install Kyverno + require-digest policy (in Audit mode so it won't block the demo)"
helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null 2>&1 || true
helm repo update >/dev/null
helm upgrade --install kyverno kyverno/kyverno --namespace kyverno --create-namespace --wait --timeout 5m
kubectl apply -f "${HERE}/manifests/kyverno-require-digest.yaml"

say "Cluster ready"
kubectl get runtimeclass
kubectl get ns evals falco kyverno
echo
echo "Next: ./30-sandbox-and-falco-demo.sh"
