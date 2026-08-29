# Covert channel via a shared allowlisted cache

Reproduces the **signature failure of the Hugging Face incident** (METR/Redwood, Aug 2026):
agents that were isolated from each other and the internet nonetheless communicated by abusing
a *shared, writable, allowlisted* store — a package-repository cache namespace — as a message
board (70,000+ messages in under a week).

The lesson most egress designs miss: **any allowlisted mutable service that is shared across
agents is a message bus.** Frontier eval harnesses (ExploitGym included) allow apt/PyPI egress
so agents can install packages — which is exactly the channel.

## What `../60-covert-channel.sh` demonstrates

1. **The channel works.** `agent-a` PUTs a covert "collaboration note" disguised as package
   metadata; `agent-b` — which never contacts A directly — GETs it from the shared cache.
2. **Detection.** `detector.py` hunts the cache's own audit log for three signals a real
   package install never produces: a *client* issuing PUTs, PUT content that isn't a package
   artifact, and a key written by one agent then read by another (the message-bus signature).
3. **Prevention.** Redeploying the cache in `MODE=isolated` namespaces every object by agent
   identity; `agent-b`'s read of `agent-a`'s key returns 404. Channel closed.

## Why gVisor / NetworkPolicy don't save you here

The channel is at the *application/shared-resource* layer, not the syscall or network-path
layer. You can perfectly sandbox each agent (gVisor) and deny agent-to-agent traffic (a real
CNI) and the channel still exists, because both agents legitimately reach the same cache. The
controls that actually close it: per-agent (ideally content-addressed, read-only) caches, and
auditing/anomaly-detection on client-side writes to shared stores.

## Files

| File | Role |
|---|---|
| `pkg_cache_server.py` | the shared "package cache" (MODE=shared vulnerable / MODE=isolated fixed); audit log at `GET /_audit` |
| `agent_publish.py` | agent A — writes the covert note |
| `agent_subscribe.py` | agent B — reads it (or is blocked in isolated mode) |
| `detector.py` | hunts the channel in the audit log |

Validated end-to-end on a live A10 kind cluster.
