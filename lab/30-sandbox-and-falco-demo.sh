#!/usr/bin/env bash
# The crown-jewel demo:
#   1. build a dedicated 'eval-sandbox:demo' image and load it into kind (so Falco can key on it)
#   2. deploy a hardened sandbox pod (gVisor, no-net, read-only rootfs, seccomp, no caps)
#   3. prove the boundary: confirm it's really running on runsc, no network
#   4. trigger a benign "breakout" (shell spawn + outbound connect) and watch Falco fire
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLUSTER="evallab"

say(){ printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

say "Build + load the eval-sandbox image (python, nothing else)"
docker build -t eval-sandbox:demo -f - "${HERE}" <<'EOF'
FROM python:3.12-slim
# deliberately minimal; the whole point is that untrusted code runs here with nothing handy
RUN useradd -u 10001 -m runner
USER 10001
EOF
kind load docker-image eval-sandbox:demo --name "$CLUSTER"

say "Deploy the hardened sandbox pod"
kubectl apply -f "${HERE}/manifests/eval-runner.yaml"
kubectl -n evals wait --for=condition=Ready pod/eval-sandbox --timeout=120s
POD=eval-sandbox

say "Prove the isolation boundary"
echo "-- kernel as seen INSIDE the sandbox (gVisor reports its own version string, not the host):"
kubectl -n evals exec "$POD" -- python3 -c "import platform;print('uname:',platform.uname().release)"
echo "-- is the runsc process present on the node? (this is gVisor intercepting syscalls)"
NODE="$(kind get nodes --name "$CLUSTER" | head -1)"
docker exec "$NODE" bash -c 'ps aux | grep -c "[r]unsc" || true'

say "Network egress check (default-deny NetworkPolicy)"
echo "-- NOTE: kind's default CNI (kindnet) does NOT enforce NetworkPolicy, so this connect may"
echo "   SUCCEED here even though the policy says deny. That's the teaching point: egress control"
echo "   lives in the CNI (use Calico for real enforcement) — Falco still SEES the connect either way."
kubectl -n evals exec "$POD" -- python3 - <<'PY' || echo "   (connect failed — enforced or no route)"
import socket
s=socket.socket(); s.settimeout(4)
try:
    s.connect(("1.1.1.1",80)); print("   connect SUCCEEDED (kindnet ignoring policy — expected on kind)")
except Exception as e:
    print("   connect blocked:", e)
PY

say "Start watching Falco, then trigger a benign breakout attempt"
echo "In another terminal, run:"
echo "   kubectl -n falco logs -l app.kubernetes.io/name=falco -f | grep -i 'eval sandbox'"
echo
sleep 2
echo "-- breakout attempt #1: spawn a shell inside the sandbox"
kubectl -n evals exec "$POD" -- /bin/sh -c 'echo i-should-not-have-a-shell' || true
echo "-- breakout attempt #2: try an outbound socket (Falco sees the connect syscall)"
kubectl -n evals exec "$POD" -- python3 -c "import socket;socket.socket().connect(('8.8.8.8',53))" 2>/dev/null || true

echo
echo "Now check Falco caught them:"
echo "   kubectl -n falco logs -l app.kubernetes.io/name=falco | grep -i 'eval sandbox'"
echo
echo "Expected: WARNING/NOTICE lines 'Shell spawned in eval sandbox' and/or"
echo "          'Outbound connection from eval sandbox'."
