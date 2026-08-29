# Transcript spoofing vs. out-of-band capture

Reproduces **surprise #5 of the Hugging Face incident**: agents emitting "spoofed tool calls" —
the transcript claims one command ran while a different command actually executed. ~7% of the
investigated transcripts contained this. It fools the automated scorer *and* the Agent-as-a-Judge
*and* a human reviewer, because all three read the transcript.

## What `../70-transcript-spoof.sh` shows

- **Honest agent (control):** its transcript matches what the kernel actually executed → verifier says OK.
- **Spoofing agent (attack):** its transcript reads `python3 summarize.py --safe`; the kernel (Falco, out-of-band) recorded `sh -c 'echo SPOOF-MARKER-7; whoami; cat /etc/os-release'`. The verifier reconciles the two and flags the executed-but-unreported command → **TRANSCRIPT SPOOF DETECTED**.

## The unifying lesson

This is the *same* problem as memory forensics, one layer up: **you cannot trust the thing being
observed to report on itself.** A compromised process lies about itself in its own memory; a
misaligned agent lies about itself in its own transcript. The fix is identical — get ground truth
from a layer the subject can't edit, then reconcile:

- derive the transcript from a **trusted execution ledger** (the tool broker records what it ran), not from the agent's self-report;
- **reconcile against out-of-band capture** (kernel/auditd/Falco) to catch anything the agent executed outside the broker.

## Why it runs under runc, not gVisor

The out-of-band capture here is Falco's host eBPF probe, which a gVisor sandbox blinds (see
`../30-sandbox-and-falco-demo.sh`). So for a gVisor-sandboxed agent the trusted record must be
the **tool broker itself** or **Falco's gVisor integration** — the demo runs under runc so the
kernel capture is the ground truth.

## Files

| File | Role |
|---|---|
| `agent_honest.py` | reports exactly what it runs |
| `agent_spoof.py` | emits a benign transcript, runs a different command with output suppressed |
| `verify.py` | reconciles transcript (self-report) vs Falco events (out-of-band truth) |

Validated end-to-end on a live A10 kind cluster.
