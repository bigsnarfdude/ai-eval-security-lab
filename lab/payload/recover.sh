#!/usr/bin/env bash
# Recover a fileless payload from a running process's memory, and prove ground truth.
# Usage: recover.sh <pid> [canary-string]
set -euo pipefail
PID="${1:?usage: recover.sh <pid> [canary]}"
CANARY="${2:-CANARY-9f2c1a7b-training-only}"
OUT="$(mktemp -d)"

say(){ printf '\n\033[1;36m-- %s --\033[0m\n' "$*"; }
[ -d "/proc/$PID" ] || { echo "no such pid $PID"; exit 1; }

say "IOC 1: is the executable backing deleted / anonymous?"
ls -l "/proc/$PID/exe" 2>/dev/null || echo "(exe unreadable — try sudo)"
echo "  ^ 'memfd:... (deleted)' or '(deleted)' here = fileless binary. Nothing legit runs this way."

say "IOC 2: memfd / deleted / anonymous executable mappings"
grep -Ei 'memfd|deleted' "/proc/$PID/maps" 2>/dev/null || echo "  (none in maps — script-mode payloads show up as an fd instead, see IOC 3)"

say "IOC 3: open file descriptors backed by a deleted memfd"
ls -l "/proc/$PID/fd" 2>/dev/null | grep -Ei 'memfd|deleted' || echo "  (none)"

say "Recover the payload bytes straight from RAM"
# script-mode: the memfd fd is readable directly
FD="$(ls -l "/proc/$PID/fd" 2>/dev/null | grep -Ei 'memfd' | awk '{print $9}' | head -1 || true)"
if [ -n "${FD:-}" ]; then
  cat "/proc/$PID/fd/$FD" > "$OUT/recovered_payload"
  echo "recovered $(wc -c < "$OUT/recovered_payload") bytes from /proc/$PID/fd/$FD -> $OUT/recovered_payload"
  echo "  first lines:"; head -5 "$OUT/recovered_payload" | sed 's/^/    /'
else
  echo "  no readable memfd fd; falling back to a full process core dump"
fi

say "Ground-truth check: is the CANARY resident?"
PROVEN=0
# (a) primary: do the bytes we recovered from RAM contain the canary? (always works for scripts)
if [ -f "$OUT/recovered_payload" ] && grep -q "$CANARY" "$OUT/recovered_payload"; then
  echo "  ✓ canary present in the RAM-recovered payload: $CANARY"
  PROVEN=1
fi
# (b) secondary: carve it from a full process core dump (gcore needs ptrace -> sudo on yama scope 1)
if command -v gcore >/dev/null 2>&1; then
  sudo timeout 20 gcore -o "$OUT/core" "$PID" >/dev/null 2>&1 || timeout 20 gcore -o "$OUT/core" "$PID" >/dev/null 2>&1 || true
  CORE="$(ls "$OUT"/core.* 2>/dev/null | head -1 || true)"
  if [ -n "${CORE:-}" ] && strings -a "$CORE" 2>/dev/null | grep -q "$CANARY"; then
    echo "  ✓ canary also carved from a full process core dump ($CORE)"
    PROVEN=1
  fi
fi
[ "$PROVEN" = 1 ] \
  && echo "    -> we proved exactly what was resident. That's the forensic win." \
  || echo "  canary not confirmed (process may have exited before capture)"

echo
echo "artifacts in: $OUT"
