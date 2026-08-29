# Memory-forensics samples (benign, training-only)

These are **controlled, benign samples** for practicing memory acquisition and recovery. None
is malware: no persistence, no real payload, no lateral movement, no evasion intended for real
targets. The design goal is *ground truth* — you know exactly what's in memory, so you can prove
whether a dump recovered it.

| File | What it is |
|---|---|
| `nx-agent.py` | A fake agent that holds a unique **canary** string + a fake config in RAM, sends one benign beacon, then idles. You wrote it, so recovery is verifiable. |
| `fileless_launch.py` | Runs a binary or script entirely from RAM via `memfd_create` — the fileless technique, used here to generate a sample that never touches disk. |
| `recover.sh` | Given a PID, surfaces the fileless IOCs (`memfd`/deleted exe, memfd fds), recovers the payload bytes from `/proc`, and confirms the canary is resident. |

Driven end-to-end by `../50-memory-forensics.sh` (detect → adapt → recover).

## The lesson in one line

Going fileless to beat the disk scanner **trades one IOC for a worse one**: a process running
from a `memfd:… (deleted)` image is wildly abnormal on a hardened host. Fileless execution
isn't stealthier against a memory hunter — it's louder.

## Requires

Linux with `/proc`, `python3` (3.8+ for `memfd_create`), and ideally `gcore` (`gdb`) for the
full-core canary check. Runs as your own user against processes you launched; `sudo` widens it
to other processes.
