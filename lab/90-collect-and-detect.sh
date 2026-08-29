#!/usr/bin/env bash
# Collect the misconfiguration AND the IOC for a container->host lateral, in one run:
#   1. POSTURE  — a static scan finds the "unlocked door" (a socket-mounted container) before anything happens.
#   2. RUNTIME  — an event watcher catches "someone walking through" while R2 performs the escape live.
# Same underlying data (docker inspect), two phases. Runs on plain Docker (Mac or Linux), free.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CL="${HERE}/collect"
say(){ printf '\n\033[1;34m========== %s ==========\033[0m\n' "$*"; }
docker info >/dev/null 2>&1 || { echo "start Docker first (open -a Docker)"; exit 1; }

say "Stage a deliberately-misconfigured 'victim' container (socket mounted, lingering)"
docker rm -f badcfg >/dev/null 2>&1 || true
docker run -d --rm --name badcfg -v /var/run/docker.sock:/var/run/docker.sock alpine sleep 40 >/dev/null
echo "launched 'badcfg' with the docker socket mounted"

say "POSTURE — collect the misconfiguration (the unlocked door)"
bash "${CL}/misconfig_scan.sh"

say "RUNTIME — collect the IOC while R2 performs the escape live"
bash "${CL}/ioc_watch.sh" > /tmp/ioc.log 2>&1 &   # portable: no 'timeout' (absent on stock macOS)
WPID=$!
sleep 2
echo "(ioc-watch running; now firing the R2 escape...)"
bash "${HERE}/escape-room/R2-docker-socket.sh" > /tmp/r2.log 2>&1 || true
echo "R2 verdict: $(grep -m1 -E 'ESCAPED|did not' /tmp/r2.log | sed 's/^ *//')"
sleep 2
pkill -P "$WPID" 2>/dev/null || true   # reap the docker-events child (portable; no process-group tricks)
kill "$WPID" 2>/dev/null || true; wait "$WPID" 2>/dev/null || true
echo "-- IOCs captured during the escape --"
grep '\[IOC' /tmp/ioc.log || echo "(no IOC lines — check /tmp/ioc.log)"

say "CLEANUP"
docker rm -f badcfg >/dev/null 2>&1 || true
echo "removed staged container"
echo
echo "Takeaway: the misconfig scan and the IOC watch read the SAME field (docker inspect), one"
echo "before the fact (posture) and one during (runtime). Collect both and you cover the lateral"
echo "end to end — the door and the footstep."
