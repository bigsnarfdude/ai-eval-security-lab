# Runbook — operating the replication

Operator's view: stand up the lab and run each reproduction. (Defender's view — how to *hunt*
these laterals — is the separate **[DFIR Hunter Playbook](docs/dfir-hunter-playbook.html)**.)

## Prereqs

- A Linux host with root (a laptop or a single rented GPU box such as a Lambda A10, 24 GB).
- Docker present. Kernel headers + BTF (for Falco eBPF). `python3` 3.8+.

## Stand up (real-Linux / A10)

```bash
scp -r lab you@host:~/lab && ssh you@host && cd ~/lab
./00-preflight.sh        # install kind, kubectl, skopeo, runsc, helm; checks GPU / /dev/kvm
./10-serve-model.sh      # vLLM serves a small model (OpenAI-compatible) — for the harness & escape-room
./20-kind-up.sh          # kind + gVisor RuntimeClass + Falco (eBPF) + Kyverno
```

## Run the reproductions

| Step | Reproduces | Expected |
|---|---|---|
| `./30-sandbox-and-falco-demo.sh` | isolation + the gVisor-blinds-detection edge | `uname` = `*-gvisor`; runc breakout caught, gVisor breakout invisible |
| `./40-image-hygiene.sh` | supply-chain admission | Kyverno rejects a tag-pinned pod, admits a digest-pinned one |
| `./50-memory-forensics.sh` | presence → behavior → memory | fileless `memfd` IOC; canary recovered from `/proc` |
| `./60-covert-channel.sh` | HF-incident covert channel | agent-b reads agent-a via shared cache; detector fires; isolated mode blocks |
| `./70-transcript-spoof.sh` | spoofed tool calls | honest reconciles clean; spoof caught by kernel record |
| `python3 harness/run_eval.py` | model→sandbox→score loop | model writes code, runs in gVisor sandbox, scored |
| `./80-escape-room.sh` | escape-room eval (R1 priv-esc) | agent reads root-only flag via setuid helper; ESCAPED / DETECTED |
| `./90-collect-and-detect.sh` | misconfig + IOC collection | posture flags the socket door; IOC watch catches the privileged launch |

## Run anywhere (plain Docker, no cluster/GPU — Mac included)

```bash
./escape-room/R2-docker-socket.sh   # real container->host escape via the docker socket
./90-collect-and-detect.sh          # posture scan + live IOC watch against an R2 escape
./50-memory-forensics.sh            # the forensics chain needs only python3 + /proc
```

## Tear down

```bash
./99-teardown.sh                    # kind delete + stop vLLM
# then terminate the rented instance from your provider (stops billing)
```

Every result the docs mark "validated" was run end-to-end this way on a live A10 (cluster
pieces) or Docker Desktop (R2 / collector).
