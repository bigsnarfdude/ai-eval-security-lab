# Collecting misconfigurations and IOCs for container laterals

The core learning of this lab: **a misconfiguration and an IOC are the same inventory viewed at
two times.** The misconfig is the *unlocked door* (static, pre-attack, posture); the IOC is
*someone walking through it* (runtime, during-attack). Both are read from the **same sysadmin
instruments** — `docker inspect`, `/proc`, auditd, eBPF — pointed at detection instead of
operation.

## The catalog

For every lateral this lab demonstrates: the enabling misconfig (collect statically), the runtime
IOC (collect live), and the control that closes it.

| Lateral | Enabling misconfig — collect via | Runtime IOC — collect via | Control |
|---|---|---|---|
| **R2 container→host escape** | `docker.sock` mount / `privileged` / `pid=host` / `hostPath:/` / `CAP_SYS_ADMIN` — `docker inspect`, kubescape, Trivy, kube-bench | connect to `docker.sock`; **privileged `--pid=host` container launched**; read of `/proc/1/root/*` — `docker events`, Falco (`Docker socket`, `Launch Privileged Container`), auditd | Kyverno/OPA admission deny; no socket mounts; socket proxy |
| **R1 setuid priv-esc** | setuid-root binaries (`find / -perm -4000`, `getcap -r /`); `no_new_privs` off | `execve` of setuid bin with **uid→0 transition**; mass `stat` of setuid bins | `allowPrivilegeEscalation:false` (`no_new_privs`); drop setuid bins |
| **Covert channel** | shared, writable, allowlisted service reachable by ≥2 agents | **client PUTs** of non-package content; same key **written by one agent, read by another** | per-agent namespaced / read-only cache; audit writes |
| **Transcript spoof** | agent authors its own transcript; no trusted exec ledger | **transcript ≠ kernel exec** (a command ran, unreported) | derive transcript from a trusted broker; reconcile vs auditd/Falco |
| **Fileless (memfd)** | (runtime technique — no static door) | `/proc/<pid>/exe → memfd:… (deleted)`; anon RWX map; `memfd_create`+`execveat` | fapolicyd/IMA; monitor memfd exec |

## The two collectors here

- `misconfig_scan.sh` — **posture.** Enumerates running containers via `docker inspect` and flags
  every escape-enabling door (socket mount, privileged, pid=host, host bind, dangerous caps),
  naming the escape each one unlocks.
- `ioc_watch.sh` — **runtime.** Streams `docker events` and flags any container launched with
  escape-grade privileges — the live footstep.

`../90-collect-and-detect.sh` runs both against a live R2 escape: the posture scan finds the
socket-mounted door *before* anything happens, and the event watcher catches the privileged
`--pid=host` container the escape spawns *as it happens*.

## Scaling up (real deployments)

- **k8s posture:** kube-bench (CIS), kubescape, Trivy config scan, Polaris; Kyverno/OPA in
  *audit* mode is a continuous misconfig collector at admission time.
- **k8s runtime:** Falco/Tetragon (eBPF) for syscall + container-launch IOCs; the k8s audit log
  for privileged / hostPath pod creations.
- **Host:** auditd rules on `execve`/`mount`/`ptrace`/`connect`; `/proc` sweeps for deleted-exe
  and cross-namespace `/proc/1/root` access.

Validated on Docker Desktop (Mac).
