#!/usr/bin/env bash
# Preflight: sanity-check the A10 host and install the toolchain.
# Safe to re-run. Assumes fresh Lambda Ubuntu with root (or passwordless sudo).
set -euo pipefail

say(){ printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

say "Host facts"
uname -a
echo "kernel: $(uname -r)  (Falco modern-eBPF wants >= 5.8; you have this on Lambda)"

say "GPU"
if have nvidia-smi; then nvidia-smi --query-gpu=name,memory.total --format=csv; else
  echo "!! nvidia-smi missing — Lambda images normally ship it. vLLM will fail without a GPU."; fi

say "Firecracker capability (informational)"
if [ -e /dev/kvm ]; then
  echo "/dev/kvm present -> Firecracker COULD run here."
else
  echo "/dev/kvm ABSENT -> Firecracker won't run (expected on a Lambda VM). gVisor is unaffected."
fi

say "Docker + NVIDIA runtime"
have docker || { echo "!! docker missing — Lambda images normally include it"; exit 1; }
docker info 2>/dev/null | grep -qi 'Runtimes:.*nvidia' \
  && echo "nvidia container runtime: OK" \
  || echo "!! nvidia runtime not shown in 'docker info' — 'docker run --gpus all' may fail; check nvidia-container-toolkit"

say "Installing CLI tools (kind, kubectl, skopeo, runsc, helm)"
ARCH="$(dpkg --print-architecture)"   # amd64 on Lambda A10

if ! have kind; then
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/v0.23.0/kind-linux-${ARCH}"
  $SUDO install -m0755 /tmp/kind /usr/local/bin/kind
fi
if ! have kubectl; then
  KV="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/${ARCH}/kubectl"
  $SUDO install -m0755 /tmp/kubectl /usr/local/bin/kubectl
fi
if ! have skopeo; then $SUDO apt-get update -qq && $SUDO apt-get install -y -qq skopeo; fi
if ! have helm; then curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | $SUDO bash; fi

# gVisor (runsc + containerd shim) on the host; we copy these into the kind node later.
if ! have runsc; then
  ( set -e; URL="https://storage.googleapis.com/gvisor/releases/release/latest/${ARCH/amd64/x86_64}"
    cd /tmp
    for f in runsc containerd-shim-runsc-v1; do
      curl -fsSLO "${URL}/${f}"; curl -fsSLO "${URL}/${f}.sha512"
      sha512sum -c "${f}.sha512"
    done
    $SUDO install -m0755 runsc containerd-shim-runsc-v1 /usr/local/bin/ )
fi

say "Versions"
# note: kubectl/helm use 'version', not '--version'; check presence first to avoid false MISSING
for b in docker kind kubectl skopeo helm runsc; do
  printf '%-10s ' "$b"
  if ! command -v "$b" >/dev/null 2>&1; then echo "MISSING"; continue; fi
  case "$b" in
    kubectl) { kubectl version --client 2>/dev/null | head -1; } || true;;
    helm)    helm version --short 2>/dev/null || true;;
    *)       { "$b" --version 2>/dev/null | head -1; } || true;;
  esac
done

echo
echo "Preflight done. Next: ./10-serve-model.sh"
