#!/usr/bin/env bash
# Memory forensics walkthrough: detect -> adapt -> recover.
# Runs at HOST level (memory forensics is a host skill) and complements the k8s Falco demo.
# Teaches why, on a hardened box, an attacker escalates past each detector until only memory is left.
#
# Stages:
#   1. naive netcat on disk        -> caught by PRESENCE (allowlist / IMA)
#   2. living off the land (/dev/tcp) -> presence sees nothing; caught by BEHAVIOR
#   3. fileless netcat (memfd)      -> disk scan clean; caught in MEMORY (deleted-exe IOC)
#   4. recover the canary agent     -> prove ground truth from /proc
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PL="${HERE}/payload"
say(){ printf '\n\033[1;34m========== %s ==========\033[0m\n' "$*"; }

# A pretend allowlist for a "hardened" host: only these are sanctioned.
ALLOWLIST="bash sh python3 curl systemd sshd"
is_allowed(){ for a in $ALLOWLIST; do [ "$1" = "$a" ] && return 0; done; return 1; }

NC="$(command -v nc || command -v ncat || true)"
[ -z "$NC" ] && { echo "installing netcat for the demo..."; sudo apt-get install -y -qq netcat-openbsd >/dev/null 2>&1 || true; NC="$(command -v nc || true)"; }

say "STAGE 1 — naive netcat on disk (PRESENCE detection)"
echo "On a hardened host we ALLOWLIST. Anything off-list is an IOC by mere existence."
BIN="$(basename "${NC:-nc}")"
if is_allowed "$BIN"; then echo "  $BIN is sanctioned"; else
  echo "  ✗ IOC: '$BIN' ($NC) is NOT on the allowlist — near-zero false positive."
  echo "    Real enforcers: fapolicyd (exec allowlist), IMA/EVM (binary integrity)."
fi

say "STAGE 2 — living off the land: bash /dev/tcp (BEHAVIOR detection)"
echo "A smart attacker won't bring nc. They use what's allowed — here, a bash builtin."
echo "PRESENCE sees nothing (bash is sanctioned). You must go behavioral."
timeout 4 bash -c 'exec 3<>/dev/tcp/1.1.1.1/80 && echo "  (bash opened a raw socket to 1.1.1.1:80 — no foreign tool touched disk)"' 2>/dev/null \
  || echo "  (connect blocked/failed — behavior is still the signal: bash should not open raw sockets)"
echo "  Detection = Falco 'unexpected outbound connection' / a bash with an external socket fd."

say "STAGE 3 — fileless netcat via memfd (MEMORY detection)"
if [ -n "$NC" ]; then
  # run nc filelessly as a LISTENER so it stays resident long enough to hunt (nc -h would exit instantly)
  python3 "${PL}/fileless_launch.py" "$NC" -l 19999 </dev/null >/dev/null 2>&1 &
  FPID=$!; sleep 1
  echo "  launched nc filelessly (pid $FPID, listening). On disk: nothing new. In memory:"
  # find any process whose exe backing is a deleted memfd
  found=0
  for p in $(ls /proc | grep -E '^[0-9]+$'); do
    tgt="$(readlink "/proc/$p/exe" 2>/dev/null || true)"
    case "$tgt" in *memfd:*|*"(deleted)"*) echo "  ✗ IOC: pid $p exe -> $tgt  (fileless — nothing legit runs from a deleted image)"; found=1;; esac
  done
  [ "$found" = 0 ] && echo "  (no deleted-exe process found — nc may have exited; check 'nc -l' syntax on this host)"
  kill "$FPID" 2>/dev/null || true
  echo "  Lesson: going fileless beat the disk scanner but CREATED a louder memory IOC."
else
  echo "  (no nc available; skipping — the memfd technique is shown with nx-agent in stage 4)"
fi

say "STAGE 4 — recover the canary agent from memory (GROUND TRUTH)"
python3 "${PL}/fileless_launch.py" "${PL}/nx-agent.py" &
APID=$!; sleep 2
echo "  nx-agent running filelessly as pid $APID — its script exists ONLY in a memfd."
bash "${PL}/recover.sh" "$APID" || true
kill "$APID" 2>/dev/null || true

echo
echo "Done. Chain: presence -> behavior -> memory, then a verified recovery."
echo "This is exactly why memory forensics is the last line: each detector the attacker defeats"
echo "pushes the evidence one layer deeper, and memory is where it stops."
