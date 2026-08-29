# ai-eval-security-lab

A **toy-scale replica of how a frontier AI lab runs model evals** — built to learn and to
demo the part that actually matters: the **security layer**. An eval platform is really an
*untrusted-code execution service that happens to score models* (agentic/coding evals run code
the model-under-test wrote), so isolation, runtime detection, supply-chain hygiene, and memory
forensics are the design — not an add-on.

Everything here runs on **one machine** (a laptop, or a single rented GPU box). The primitives
are the same ones the big labs run; only the scale differs — most of an eval stack scales *out,
not up*.

> Built as a hands-on study/portfolio project. Benign throughout — see **Safety** below.

## What's inside

```
docs/eval-infra-study-guide.html   Standalone study guide: architecture, toy↔scale per layer,
                                   the sandboxing/forensics deep-dive, and an interview Q&A bank.
lab/                               The runnable lab (one script per layer).
  00-preflight.sh                  Host checks + install kind, kubectl, skopeo, runsc, helm
  10-serve-model.sh                vLLM serves a real small model (OpenAI-compatible)
  20-kind-up.sh                    kind + gVisor RuntimeClass + Falco (eBPF) + Kyverno
  30-sandbox-and-falco-demo.sh     Hardened sandbox → trigger a breakout → Falco catches it
  40-image-hygiene.sh              Skopeo inspect + Kyverno rejecting an unpinned image
  50-memory-forensics.sh           detect → adapt → recover: presence → behavior → memory
  harness/run_eval.py              Model writes code → runs it IN the sandbox → scored
  payload/                         Benign memory-forensics samples (canary agent, fileless launcher)
```

## The layers, and what each teaches

| Layer | Tool | The idea |
|---|---|---|
| Serving | vLLM | identical client contract to prod; only parallelism changes at scale |
| Control plane | kind / k8s | a scheduler for ephemeral, mutually-untrusted jobs |
| **Isolation** | **gVisor** (`runsc`) | containers isolate for resource control; gVisor isolates for *security* |
| **Runtime detection** | **Falco** (eBPF) | detection sits *under* prevention — defense in depth |
| Supply chain | Skopeo + Kyverno | signing/pinning is enforced at *admission*, not just at build |
| **Memory forensics** | `/proc`, gVisor, gcore | when an attacker defeats disk detection, memory is the last ground |

## Status

- **`50-memory-forensics.sh` + `payload/` — validated end-to-end on a live NVIDIA A10 (Ubuntu 22.04, kernel 6.8).** Presence → behavioral → fileless-`memfd` IOC → exact-bytes recovery from `/proc/<pid>/fd` with a confirmed canary.
- **`00`–`40` + `harness/` — runnable reference**, exercised on the same box; the fiddly steps (gVisor-into-kind, Falco's eBPF probe, GPU-in-Docker) are flagged inline with their failure modes. Verify as you go rather than assuming.

## Run it

On a real Linux host (root recommended; a rented single-GPU box is ideal):

```bash
scp -r lab you@host:~/lab && ssh you@host
cd ~/lab
./00-preflight.sh
./50-memory-forensics.sh          # the forensics chain — no cluster needed, runs anywhere
./10-serve-model.sh               # then the k8s/serving/sandbox stack, top to bottom
./20-kind-up.sh
./30-sandbox-and-falco-demo.sh
./40-image-hygiene.sh
python3 harness/run_eval.py
./99-teardown.sh                  # and terminate the instance from your provider
```

The **memory-forensics chain needs no GPU or cluster** — it runs on any Linux box with
`python3` (3.8+) and `/proc`.

## The one line to remember

Going fileless to beat the disk scanner **trades one IOC for a worse one**: a process running
from a `memfd:… (deleted)` image is wildly abnormal on a hardened host. *Fileless execution
isn't stealthier against a memory hunter — it's louder.*

## Safety

Every sample here is **benign and for defensive/educational use only**: no persistence, no real
payload, no lateral movement, no evasion aimed at real targets. The "attacker" samples exist so
there is something with known ground truth to detect and recover — the standard way memory
forensics is taught. Nothing in this repo targets a system you don't own.
