#!/usr/bin/env bash
# Serve a real small model with vLLM on the host GPU (OpenAI-compatible API on :8000).
# Runs OUTSIDE kind on purpose: GPU-in-kind is painful; the in-cluster harness just calls
# this host endpoint. Same client contract as a prod serving layer.
set -euo pipefail

MODEL="${MODEL:-Qwen/Qwen2.5-7B-Instruct}"   # ~15GB bf16, fits A10 24GB; override with MODEL=...
PORT="${PORT:-8000}"
NAME="vllm-eval"

echo "== Starting vLLM: $MODEL on :$PORT =="
docker rm -f "$NAME" >/dev/null 2>&1 || true

# --gpus all: give the container the A10. First run downloads weights into the HF cache volume.
docker run -d --name "$NAME" --gpus all --restart unless-stopped \
  -p "${PORT}:8000" \
  -v "${HOME}/.cache/huggingface:/root/.cache/huggingface" \
  ${HF_TOKEN:+-e HF_TOKEN="$HF_TOKEN"} \
  vllm/vllm-openai:latest \
  --model "$MODEL" \
  --max-model-len 8192 \
  --gpu-memory-utilization 0.90

echo "Waiting for the model to load (first run pulls weights — can be several minutes)..."
for i in $(seq 1 120); do
  if curl -fsS "http://localhost:${PORT}/v1/models" >/dev/null 2>&1; then
    echo "vLLM is up:"; curl -fsS "http://localhost:${PORT}/v1/models" 2>/dev/null | head -c 400 || true; echo
    echo "Tail logs with: docker logs -f $NAME"
    exit 0
  fi
  sleep 5
done

echo "!! vLLM did not become ready in ~10 min. Check: docker logs $NAME"
echo "   Common causes: model still downloading, OOM (try a smaller MODEL=Qwen/Qwen2.5-3B-Instruct),"
echo "   or --gpus all not working (revisit nvidia-container-toolkit in preflight)."
exit 1
