# LEARNING.md — a hands-on path through the lab

A self-paced way to actually *grok* this, one runnable slice at a time. Don't rush; the point is
to run a thing, **look at what it produced**, and let the concept land. Every lesson has the same
shape:

> **Goal** — what you'll understand · **Run** — the command · **Look** — what to inspect · **Grok** — the idea

Ask Claude to explain any step line by line. Reference docs: `docs/eval-infra-study-guide.html`
(the map), `docs/dfir-hunter-playbook.html` (the hunt), `docs/swarm-gauntlet-vision.html` (where it goes).

---

## Part 1 — Fundamentals, free on your Mac (Docker only)

You can do all of Part 1 with just Docker Desktop running. No cluster, no GPU, no cost.

### Lesson 1 — What a container actually *is* (namespaces + cgroups)
- **Goal:** see that "isolation" = separate *views* of one shared kernel, plus a resource slice.
- **Run:**
  ```bash
  docker run -d --rm --name demo --memory 256m --cpus 0.5 alpine sleep 300
  ```
- **Look:**
  ```bash
  docker exec demo ps aux           # it sees ONLY its own processes — its sleep is PID 1 (PID namespace)
  docker exec demo hostname         # its own hostname (UTS namespace)
  docker exec demo ip addr          # its own IP / interfaces (network namespace)
  docker exec demo ls /             # its own root filesystem (mount namespace)
  docker inspect demo | grep -iE '"Memory"|"NanoCpus"'   # its cgroup limits (the slice)
  ```
- **Grok:** the container isn't a VM — it's your host's kernel showing this process a private PID/net/mount view (namespaces) and capping its CPU/RAM (cgroups). That's the exact mechanism k8s uses per pod. `docker rm -f demo` when done.

### Lesson 2 — A real container → host escape (over-privilege + mount misconfig)
- **Goal:** understand why `privileged` / socket mounts are "root on the host."
- **Run:** `./lab/escape-room/R2-docker-socket.sh`
- **Look:** the CONTROL step (a normal container *can't* see the host file) vs the ESCAPE step (a socket-mounted container spawns a `--privileged --pid=host` sibling and reads `/proc/1/root/...`).
- **Grok:** mounting the Docker socket = giving a container the host's root daemon. Read `docs/dfir-hunter-playbook.html` **H1** alongside — that's how you'd *hunt* this.

### Lesson 3 — Collecting the misconfig and the IOC
- **Goal:** see that a misconfig (the unlocked door) and an IOC (the footstep) are the same data at two times.
- **Run:** `./lab/90-collect-and-detect.sh`
- **Look:** POSTURE flags the socket-mounted container *before* the attack; RUNTIME catches the privileged `--pid=host` launch *during* the R2 escape.
- **Grok:** both come from `docker inspect` — one as a snapshot, one streamed from `docker events`. Same instrument, two phases.

---

## Part 2 — The full stack on a real Linux box (rented A10)

Needs a real Linux host with root (a Lambda A10 is ideal — see `RUNBOOK.md`). `scp -r lab you@host:~/lab`, then run `./00-preflight.sh`, `./10-serve-model.sh`, `./20-kind-up.sh` first.

### Lesson 4 — Pods: how "each eval gets its own"
- **Goal:** make the k8s isolation unit concrete.
- **Run:** `./30-sandbox-and-falco-demo.sh` (then, before it cleans up, in another shell:)
- **Look:**
  ```bash
  kubectl get pods -n evals -o wide         # which node it's on
  kubectl describe pod eval-sandbox -n evals # runtimeClass, limits, QoS, events
  kubectl exec -n evals eval-sandbox -- uname -r   # 4.19.0-gvisor  <- its OWN (gVisor) kernel
  kubectl exec -n evals eval-sandbox -- ps aux     # only its own processes (PID namespace)
  kubectl get runtimeclass                  # the 'gvisor' class the pod uses
  ```
- **Grok:** one eval = one Pod = its own namespaces + cgroup slice (+ gVisor's own kernel). Running N evals = creating N of these; the scheduler bin-packs them onto nodes.

### Lesson 5 — The model server, and the client contract
- **Goal:** see what the agents actually call.
- **Look:**
  ```bash
  curl -s localhost:8000/v1/models
  curl -s localhost:8000/v1/chat/completions -H 'content-type: application/json' \
    -d '{"model":"Qwen/Qwen2.5-7B-Instruct","messages":[{"role":"user","content":"say hi"}]}'
  ```
- **Grok:** the GPU lives in *one* server (vLLM). Every agent is just an HTTP client of this. The GPU has one tenant; agents are multiplexed by **batching**, not by dividing the GPU.

### Lesson 6 — Running N evals at once (the scheduler in action)
- **Goal:** watch concurrency + scheduling for real.
- **Run:** in one shell `kubectl get pods -n evals -w`; in another, launch several sandboxed pods (ask Claude for the one-liner, or run `python3 harness/run_eval.py` a few times).
- **Look:** pods go `Pending → ContainerCreating → Running → Completed`; `-o wide` shows the node. All hit the one vLLM.
- **Grok:** "8 evals at once" = 8 CPU-only sandbox pods + 1 GPU-backed model server. Scale = more CPU nodes + a few more server replicas.

### Lesson 7 — Detection, and why the sandbox blinds it
- **Goal:** the isolation-vs-observability tension.
- **Run/Look:** trigger the breakout in `30`'s runc pod (Falco fires) vs the gVisor pod (Falco blind); `kubectl -n falco logs -l app.kubernetes.io/name=falco | grep -i workload`.
- **Grok:** gVisor handles syscalls in user space, so the host eBPF probe can't see the payload. Stronger isolation = less host visibility. (Study guide: "Real escapes… collecting the door & the footstep".)

### Lesson 8 — Supply chain (admission control)
- **Run:** `./40-image-hygiene.sh`
- **Look:** Kyverno *rejects* a tag-pinned pod and *admits* a digest-pinned one.
- **Grok:** signing/pinning is enforced at **admission**, not at build. Playbook H1's containment uses this.

### Lesson 9 — Memory forensics (presence → behavior → memory)
- **Run:** `./50-memory-forensics.sh`
- **Look:** the fileless `memfd` process whose `/proc/<pid>/exe → memfd:… (deleted)`, and the canary recovered straight from `/proc/<pid>/fd`.
- **Grok:** you can't trust a process's own story; get ground truth from `/proc`. Going fileless trades one IOC for a louder one. (Playbook H5.)

### Lesson 10 — The adversarial trio
- **Run:** `./60-covert-channel.sh`, `./70-transcript-spoof.sh`, `./80-escape-room.sh`
- **Look:** covert channel (isolated agents talk via a shared cache → detected → prevented); transcript spoof (self-report ≠ kernel exec); escape-room R1 (agent reads a root-only flag via a setuid helper, scored ESCAPED/DETECTED).
- **Grok:** these are the Hugging Face incident's behaviors in miniature — and each is caught by reconciling against a layer the agent can't edit. (Playbook H2/H3/H4.)

---

## Part 3 — Concepts & where it goes (reading, no run)

### Lesson 11 — How GPUs get shared
Read the study guide's serving section + ask Claude to re-explain: **application batching** (one server, one GPU tenant) vs **time-slicing / MIG / vGPU** (splitting one GPU among pods) vs **tensor parallelism** (combining many GPUs for one big model). Default k8s gives a pod a *whole* GPU.

### Lesson 12 — Hunting, end to end
Read `docs/dfir-hunter-playbook.html`. For each lateral you ran in Parts 1–2, map it to its hunt card (H1–H5): hypothesis → collect (posture) → hunt (runtime) → confirming IOC → contain.

### Lesson 13 — Where it goes: swarms
Read `docs/swarm-gauntlet-vision.html`, especially "What's genuinely hard — and how we de-risk it." Understand why 8 agents ≠ 8 GPUs, why the influence graph is the hard/novel tool, and why the P1 instrument v0 (forced split-flag on 2–3 agents) is the go/no-go.

---

## Checkpoint — you've grokked it when you can say, unprompted:

- [ ] a container is namespaces + cgroups over one shared kernel; a pod is one of those
- [ ] N evals = N sandbox pods + one shared GPU-backed model server (batched, not time-sliced)
- [ ] containers isolate for resource control; gVisor / microVMs isolate for security
- [ ] strong isolation blinds host detection — so ground truth must come from a layer the subject can't edit
- [ ] a real container escape comes from over-privilege + mount misconfig (socket, hostPath, privileged)
- [ ] a misconfig and an IOC are the same inventory viewed at two times
- [ ] the incident's failures reduce to one rule: never trust the observed to report on itself; reconcile
