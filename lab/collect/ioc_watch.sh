#!/usr/bin/env bash
# Runtime IOC collection ("someone walked through the door", during-attack): watch the Docker
# event stream and flag the launch of any container with escape-grade privileges — a socket
# mount, privileged, or pid=host. Same data (docker inspect) as the posture scan, but streamed live.
set -euo pipefail
docker info >/dev/null 2>&1 || { echo "docker not running"; exit 1; }
echo "[ioc-watch] streaming docker events for escape-grade container launches..."
docker events --filter type=container --filter event=create --format '{{.Actor.ID}} {{.Actor.Attributes.image}}' \
| while read -r id img; do
    insp=$(docker inspect "$id" 2>/dev/null) || continue   # may already be gone (fast --rm); skip
    # grep -q before && is set-e-exempt, so a non-matching container can't kill the stream
    # (the earlier 'grep -c' returned exit 1 on zero matches and stopped the watcher).
    p=false;  printf '%s' "$insp" | grep -q '"Privileged": true' && p=true
    pid=none; printf '%s' "$insp" | grep -q '"PidMode": "host"' && pid=host
    sock=no;  printf '%s' "$insp" | grep -q '/var/run/docker.sock' && sock=yes
    if [ "$p" = true ] || [ "$pid" = host ] || [ "$sock" = yes ]; then
      echo "[IOC $(date +%H:%M:%S)] escape-grade launch: img=$img privileged=$p pid=$pid socket=$sock (id=${id:0:12})"
    fi
  done
