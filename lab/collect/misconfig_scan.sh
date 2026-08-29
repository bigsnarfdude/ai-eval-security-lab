#!/usr/bin/env bash
# Posture collection ("the unlocked door", pre-attack): inventory the misconfigurations that
# ENABLE a container->host escape, across all running containers. Pure `docker inspect` — a
# sysadmin tool pointed at detection.
set -euo pipefail
docker info >/dev/null 2>&1 || { echo "docker not running"; exit 1; }

printf '%-14s  %-26s  %s\n' "CONTAINER" "MISCONFIG" "UNLOCKS"
printf '%-14s  %-26s  %s\n' "---------" "---------" "-------"
found=0
for id in $(docker ps -q); do
  name=$(docker inspect -f '{{.Name}}' "$id" | sed 's#^/##')
  row(){ found=1; printf '%-14s  %-26s  %s\n' "${name:0:14}" "$1" "$2"; }
  insp=$(docker inspect "$id")
  echo "$insp" | grep -q '/var/run/docker.sock' && row "docker.sock mounted" "host root (spawn privileged sibling)"
  [ "$(docker inspect -f '{{.HostConfig.Privileged}}' "$id")" = "true" ] && row "privileged: true" "host devices / mount host disk"
  [ "$(docker inspect -f '{{.HostConfig.PidMode}}' "$id")" = "host" ] && row "pid=host" "/proc/1/root = host rootfs"
  docker inspect -f '{{range .HostConfig.Binds}}{{println .}}{{end}}' "$id" | grep -qE '(^|[^A-Za-z])/:|:/host(:|$)' \
    && row "host / bind-mounted" "read/write host filesystem"
  caps=$(docker inspect -f '{{range .HostConfig.CapAdd}}{{.}} {{end}}' "$id")
  echo " $caps" | grep -qiE 'SYS_ADMIN|SYS_PTRACE|DAC_READ_SEARCH|ALL' && row "cap add: ${caps}" "mount / ptrace / read-any escape"
done
[ "$found" = 0 ] && echo "(no escape-enabling misconfig on running containers)"
echo
echo "Note: each row is a door that makes container->host escape possible. The runtime IOC that"
echo "fires when the door is USED is collected separately (ioc_watch.sh)."
