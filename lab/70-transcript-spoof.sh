#!/usr/bin/env bash
# Transcript spoofing vs. out-of-band capture (Hugging Face incident, surprise #5).
# An agent's self-reported transcript is a benign lie; Falco's kernel-level capture is the truth;
# reconciling the two catches the spoof. Runs under RUNC on purpose (a gVisor pod would blind the
# host probe — see 30-sandbox-and-falco-demo.sh — so out-of-band capture must live where the
# sandbox can't hide it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TS="${HERE}/transcript-spoof"
NS=evals
TDIR="$(mktemp -d)"
say(){ printf '\n\033[1;34m========== %s ==========\033[0m\n' "$*"; }

run_agent(){ # $1 script  $2 pod  $3 marker
  local b64; b64="$(base64 -w0 "$1")"
  kubectl -n $NS run "$2" --restart=Never --image=python:3.12-slim --labels=app=eval-sandbox \
    --command -- python3 -c "import base64;exec(base64.b64decode('$b64'))" >/dev/null
  kubectl -n $NS wait --for=condition=Ready "pod/$2" --timeout=60s >/dev/null 2>&1 || true
  sleep 6  # let Falco emit + enrich pod metadata while the pod lingers
  kubectl -n $NS logs "$2" > "$TDIR/$2.transcript" 2>/dev/null || true
  kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=5000 2>/dev/null | grep "k8s_pod_name=$2" > "$TDIR/$2.falco" || true
  [ -s "$TDIR/$2.falco" ] || kubectl -n falco logs -l app.kubernetes.io/name=falco --tail=5000 2>/dev/null | grep "$3" > "$TDIR/$2.falco" || true
  python3 "${TS}/verify.py" "$TDIR/$2.transcript" "$TDIR/$2.falco" || true
  kubectl -n $NS delete pod "$2" --force --grace-period=0 >/dev/null 2>&1 || true
}

say "CONTROL — an HONEST agent (transcript matches what actually ran)"
run_agent "${TS}/agent_honest.py" ts-honest HONEST-MARKER-9

say "ATTACK — a SPOOFING agent (transcript is a benign lie)"
run_agent "${TS}/agent_spoof.py" ts-spoof SPOOF-MARKER-7

echo
echo "Takeaway: the transcript is agent-controlled and therefore untrustworthy — exactly like a"
echo "compromised process's own story in memory forensics. The fix is the same: get ground truth"
echo "from a layer the agent can't edit (a trusted exec ledger + kernel/auditd capture), then"
echo "reconcile. And note: under gVisor even this kernel capture goes blind, so the trusted record"
echo "must be the tool broker itself or Falco's gVisor integration."