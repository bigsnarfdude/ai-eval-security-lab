#!/usr/bin/env bash
# Covert-channel-via-shared-cache demo (the Hugging Face incident's signature failure):
# two isolated agents communicate through an allowlisted shared 'package cache', then we
# DETECT it, then we PREVENT it by per-agent namespacing.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CC="${HERE}/covert-channel"
NS=evals
say(){ printf '\n\033[1;34m========== %s ==========\033[0m\n' "$*"; }

deploy_cache(){ # $1 = MODE (shared|isolated)
  kubectl -n $NS delete deploy pkg-cache >/dev/null 2>&1 || true
  kubectl -n $NS delete svc pkg-cache >/dev/null 2>&1 || true
  kubectl -n $NS delete configmap pkg-cache-src >/dev/null 2>&1 || true
  kubectl -n $NS create configmap pkg-cache-src --from-file=server.py="${CC}/pkg_cache_server.py" >/dev/null
  kubectl apply -f - >/dev/null <<YAML
apiVersion: apps/v1
kind: Deployment
metadata: { name: pkg-cache, namespace: $NS }
spec:
  replicas: 1
  selector: { matchLabels: { app: pkg-cache } }
  template:
    metadata: { labels: { app: pkg-cache } }
    spec:
      containers:
        - name: cache
          image: python:3.12-slim
          command: ["python3","/src/server.py"]
          env: [{ name: MODE, value: "$1" }]
          ports: [{ containerPort: 8080 }]
          readinessProbe:
            httpGet: { path: /_audit, port: 8080 }
            initialDelaySeconds: 1
            periodSeconds: 2
          volumeMounts: [{ name: src, mountPath: /src }]
      volumes: [{ name: src, configMap: { name: pkg-cache-src } }]
---
apiVersion: v1
kind: Service
metadata: { name: pkg-cache, namespace: $NS }
spec:
  selector: { app: pkg-cache }
  ports: [{ port: 8080, targetPort: 8080 }]
YAML
  kubectl -n $NS rollout status deploy/pkg-cache --timeout=90s | tail -1
}

run_client(){ # $1 = script file, $2 = pod name, $3 = AGENT_ID
  local b64; b64="$(base64 -w0 "$1")"
  kubectl -n $NS run "$2" --rm -i --restart=Never --image=python:3.12-slim \
    --env="AGENT_ID=$3" --command -- python3 -c "import base64;exec(base64.b64decode('$b64'))" 2>/dev/null
}

say "SCENARIO: two agents isolated from each other + the internet, but both may reach the allowlisted package cache"
say "MODE 1 — shared cache (the vulnerable default, as in the incident)"
deploy_cache shared
echo "-- agent-a publishes a covert note disguised as a package --"
run_client "${CC}/agent_publish.py" cc-pub agent-a
echo "-- agent-b (never contacted A directly) reads the shared cache --"
run_client "${CC}/agent_subscribe.py" cc-sub agent-b

say "DETECTION — hunt the channel in the cache's own audit log"
run_client "${CC}/detector.py" cc-det detector

say "MODE 2 — per-agent isolated cache (the fix)"
deploy_cache isolated
echo "-- agent-a publishes into its own namespace --"
run_client "${CC}/agent_publish.py" cc-pub2 agent-a
echo "-- agent-b tries to read agent-a's key --"
run_client "${CC}/agent_subscribe.py" cc-sub2 agent-b

echo
echo "Takeaway: the channel is the SHARED, WRITABLE, ALLOWLISTED store — not the network path."
echo "gVisor/NetworkPolicy between agents don't close it; per-agent (content-addressed, read-only)"
echo "caches + auditing client-side writes do. Any allowlisted mutable shared service is a message bus."