#!/usr/bin/env bash
# HARDENED contrast to 30-sandbox-and-falco-demo.sh. Runs the SAME breakout against the SAME
# gVisor sandbox pod -- but on the hardened cluster the two bugs are fixed, so now:
#   * Falco FIRES on the shell + connect (gVisor driver: runsc exports the syscalls)
#   * the outbound connect is BLOCKED (Calico enforces deny-egress.yaml)
#
# STATUS: not yet live-validated (A10 terminated). Expected results annotated inline as EXPECT.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CLUSTER="evallab-hardened"
kubectl config use-context "kind-${CLUSTER}" >/dev/null

say(){ printf '\n\033[1;32m== %s ==\033[0m\n' "$*"; }

say "Build + load the eval-sandbox image into the hardened cluster"
docker build -t eval-sandbox:demo -f - "${HERE}" <<'DOCKER'
FROM python:3.12-slim
RUN useradd -u 10001 -m runner
USER 10001
DOCKER
kind load docker-image eval-sandbox:demo --name "$CLUSTER"

say "Deploy the hardened gVisor sandbox pod"
kubectl apply -f "${HERE}/manifests/eval-runner.yaml"
kubectl -n evals wait --for=condition=Ready pod/eval-sandbox --timeout=120s
POD=eval-sandbox

say "Confirm the pod is really on gVisor (fake kernel string) -- same boundary as the vuln lab"
kubectl -n evals exec "$POD" -- python3 -c "import platform;print('uname:',platform.uname().release)"

say "Egress check -- EXPECT: BLOCKED now (Calico enforces deny-egress.yaml)"
kubectl -n evals exec "$POD" -- python3 - <<'PY' || echo "   connect blocked (Calico enforcing) -- EXPECTED"
import socket
s=socket.socket(); s.settimeout(4)
try:
    s.connect(("1.1.1.1",80)); print("   connect SUCCEEDED -- UNEXPECTED on hardened cluster (check Calico)")
except Exception as e:
    print("   connect blocked:", e)
PY

say "Trigger the same breakout -- EXPECT: Falco FIRES this time (gVisor driver)"
echo "In another terminal:  kubectl -n falco logs -l app.kubernetes.io/name=falco -f | grep -i 'workload container'"
sleep 2
kubectl -n evals exec "$POD" -- /bin/sh -c 'echo i-should-not-have-a-shell' || true
kubectl -n evals exec "$POD" -- python3 -c "import socket;socket.socket().connect(('8.8.8.8',53))" 2>/dev/null || true

echo
echo "Now check Falco -- EXPECT hits (contrast with 30, which was silent):"
echo "   kubectl -n falco logs -l app.kubernetes.io/name=falco | grep -iE 'Shell spawned|Outbound connection'"
echo
echo "SIDE-BY-SIDE:"
echo "   30 (vuln):  gVisor + host-eBPF Falco + kindnet  -> Falco SILENT, connect SUCCEEDS"
echo "   31 (fixed): gVisor + Falco-gVisor driver + Calico -> Falco FIRES,  connect BLOCKED"
echo "Same isolation boundary, same payload. Only the detection vantage + the CNI changed."
