# Toy Frontier-Eval Lab — Lambda A10 bundle

**Goal:** stand up a laptop-scale replica of how a frontier lab runs model evals, on a
single rented **Lambda A10 (24 GB)** instance, so you can *demo* the crown-jewel layer
(sandboxing + runtime security) and speak to it from hands-on experience.

Pairs with the study guide: `~/Desktop/highlevel_eval-infra-interview-prep_2026-08-28.html`.

> **Status: reference scripts, not tested against a live A10.** I wrote these to be correct
> and runnable, but I could not execute them (no instance). Treat the fiddly steps
> (gVisor-into-kind, Falco eBPF, GPU-in-Docker) as "should work, verify as you go." Where a
> step commonly fights back, the script says so. Fail loud — if something skips, don't call
> it done.

---

## What it builds

```
 host (Lambda A10, Ubuntu, root)
 ├─ vLLM (Docker, --gpus all) ── serves a real small model on :8000 (OpenAI-compatible)
 └─ kind cluster "evallab"
     ├─ RuntimeClass: gvisor (runsc)         ← the isolation boundary
     ├─ namespace evals + default-deny egress
     ├─ Falco DaemonSet (modern eBPF)        ← watches syscalls, catches breakout
     ├─ Kyverno + require-digest policy      ← only digest-pinned images admitted
     └─ eval task Job (runtimeClassName: gvisor, no-net, read-only rootfs, seccomp)
```

The harness (`harness/run_eval.py`) closes the loop: ask the model to solve a coding task →
run the model's code **inside the gVisor sandbox** → score it. That's the real pattern, at toy
scale.

## The two caveats that decide your setup (read first)

1. **Firecracker needs `/dev/kvm`; a Lambda A10 VM probably won't expose it.** `00-preflight.sh`
   checks. **gVisor does not need KVM** (its default `systrap` platform is user-space), so the
   demo runs regardless — you just say "Firecracker is the same idea with a hardware-virt
   boundary; I'd use it on bare metal."
2. **The box is ephemeral and metered (~$0.75/hr).** That's why this is *scripted* — a
   reproducible one-command lab is a better interview artifact than a hand-built box. Snapshot
   or `99-teardown.sh` when done. Lambda A10 availability is spotty; grab one when it's free.

## Run order

```bash
# on the fresh A10, from this folder (scp it up, or paste files)
./00-preflight.sh          # checks + installs kind, kubectl, skopeo, runsc, helm
./10-serve-model.sh        # start vLLM; wait for the health check to pass (first run pulls weights)
./20-kind-up.sh            # kind cluster + gVisor RuntimeClass + Falco + Kyverno
./30-sandbox-and-falco-demo.sh   # deploy a hardened sandbox; trigger a breakout; watch Falco catch it
./40-image-hygiene.sh      # skopeo inspect + Kyverno rejects an unpinned image
python3 harness/run_eval.py      # end-to-end: model writes code → runs in sandbox → scored
./99-teardown.sh           # kind delete + stop vLLM
```

Each script is independent and re-runnable (idempotent-ish). Read the banner each one prints.

## What each piece is *for* (the interview mapping)

| File | Demonstrates | Interview line it earns you |
|---|---|---|
| `10-serve-model.sh` | serving layer, OpenAI-compatible contract | "the client contract is identical to prod; only parallelism changes at scale" |
| `20-kind-up.sh` | k8s as an untrusted-workload control plane | "k8s is the control plane for ephemeral untrusted jobs, not a buzzword" |
| `manifests/runtimeclass-gvisor.yaml` + `eval-runner.yaml` | the isolation boundary | "containers isolate for resource control; gVisor isolates for security" |
| `manifests/falco-eval-rules.yaml` | runtime detection under prevention | "detection sits *under* prevention — defense in depth" |
| `manifests/kyverno-require-digest.yaml` | supply-chain enforcement point | "signing is enforced at *admission*, not just at build" |
| default-deny NetworkPolicy | egress control | "mediated, audited egress — not a binary on/off" |

## Teardown / cost hygiene

`./99-teardown.sh` deletes the cluster and stops vLLM. Then **terminate the Lambda instance
from their dashboard** — the script can't do that for you, and the meter runs until you do.
```
