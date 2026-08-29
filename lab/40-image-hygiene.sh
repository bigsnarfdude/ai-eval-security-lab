#!/usr/bin/env bash
# Supply-chain hygiene demo: inspect an image with Skopeo (no daemon), then show Kyverno
# enforcing "images must be pinned by digest" at ADMISSION time.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
say(){ printf '\n\033[1;34m== %s ==\033[0m\n' "$*"; }

say "Skopeo: inspect an image without pulling/running it"
echo "-- manifest digest + config of python:3.12-slim (this is what you'd pin):"
skopeo inspect docker://docker.io/library/python:3.12-slim | \
  python3 -c "import sys,json;d=json.load(sys.stdin);print('Name  :',d['Name']);print('Digest:',d['Digest']);print('Created:',d.get('Created'));print('Layers:',len(d['Layers']))"

DIGEST="$(skopeo inspect docker://docker.io/library/python:3.12-slim | python3 -c 'import sys,json;print(json.load(sys.stdin)["Digest"])')"
echo "Pinned reference would be:  python@${DIGEST}"

say "Flip the Kyverno policy to Enforce so it actually blocks"
kubectl patch clusterpolicy require-image-digest --type merge -p '{"spec":{"validationFailureAction":"Enforce"}}'
sleep 3

say "Try to admit a pod using a floating TAG (should be REJECTED)"
set +e
kubectl -n evals run bad-image --image=python:3.12-slim --restart=Never --command -- sleep 5 2>&1 | sed 's/^/  /'
echo "  ^ expect: admission webhook 'require-image-digest' denied the request."
set -e

say "Now admit the SAME image pinned by digest (should be ALLOWED)"
kubectl -n evals run good-image --image="python@${DIGEST}" --restart=Never --command -- sleep 5
kubectl -n evals get pod good-image -o wide
kubectl -n evals delete pod good-image --ignore-not-found

echo
echo "That's the whole supply-chain story: signing/pinning is enforced at ADMISSION, not just at build."
# IMPORTANT: reset to Audit so later steps (60/70/80/harness) that use tag images in 'evals'
# aren't blocked by this policy. (Enforce above was only to demonstrate the block.)
kubectl patch clusterpolicy require-image-digest --type merge \
  -p '{"spec":{"validationFailureAction":"Audit"}}' >/dev/null 2>&1 \
  && echo "Policy reset to Audit — later tag-image steps will run. Flip to Enforce again to re-demo the block."
