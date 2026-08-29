#!/usr/bin/env python3
# Agent B: read the shared cache key. It never talked to agent A directly (they're isolated),
# yet in shared mode it receives A's message. In isolated mode the read is blocked.
import os, time, urllib.request, urllib.error
CACHE = os.environ.get("CACHE", "http://pkg-cache.evals.svc.cluster.local:8080")
AGENT = os.environ.get("AGENT_ID", "agent-b")
KEY = "__meta__/collab-lane3"
req = urllib.request.Request(f"{CACHE}/cache/{KEY}", headers={"X-Agent-Id": AGENT})
for attempt in range(8):
    try:
        body = urllib.request.urlopen(req, timeout=5).read().decode()
        print(f"{AGENT} GET {KEY} -> RECEIVED PEER MESSAGE (they never contacted me directly):", flush=True)
        print("   " + body, flush=True); break
    except urllib.error.HTTPError as e:
        # 404 in isolated mode = the fix working; not a connection failure, don't retry
        print(f"{AGENT} GET {KEY} -> BLOCKED ({e.code}): cannot read another agent's namespace. Channel closed.", flush=True); break
    except urllib.error.URLError:
        time.sleep(1)  # endpoint not up yet, retry

