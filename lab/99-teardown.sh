#!/usr/bin/env bash
# Tear the lab down. Does NOT terminate the Lambda instance — do that in their dashboard.
set -euo pipefail
CLUSTER="evallab"

echo "== Deleting kind cluster '$CLUSTER' =="
kind delete cluster --name "$CLUSTER" || true

echo "== Stopping vLLM container =="
docker rm -f vllm-eval 2>/dev/null || true

echo "== Removing demo image =="
docker rmi eval-sandbox:demo 2>/dev/null || true

echo
echo "Local lab gone. The HF weights cache is kept at ~/.cache/huggingface (delete to reclaim disk)."
echo
echo ">>> The meter is STILL RUNNING. Terminate the A10 instance from the Lambda dashboard. <<<"
