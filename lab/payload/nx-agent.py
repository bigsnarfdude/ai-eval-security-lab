#!/usr/bin/env python3
"""
nx-agent — a BENIGN training sample for memory-forensics practice.

It does nothing harmful: it holds a unique CANARY string and a fake config in memory,
makes ONE outbound DNS-port connection (so a behavioral monitor like Falco has something to
see), then idles. The whole point is *ground truth*: because you wrote it and know the exact
CANARY, you can prove whether a memory dump recovered it correctly.

Not malware. No persistence, no payload, no lateral movement, no obfuscation-for-evasion.
"""
import socket, time, os

CANARY = "CANARY-9f2c1a7b-training-only"          # unique marker -> proves recovery
CONFIG = {                                        # fake "C2 config" held resident in RAM
    "c2": "http://example.invalid/pull",
    "key": "deadbeefcafe0123",
    "interval_s": 3600,
}

def main():
    print(f"nx-agent up pid={os.getpid()} (canary resident, config resident)", flush=True)
    _keep = (CANARY, CONFIG)                       # keep referenced so it stays in memory
    try:
        # one benign beacon: a bare TCP connect to a public DNS resolver's port 53.
        s = socket.socket(); s.settimeout(3)
        s.connect(("8.8.8.8", 53)); s.close()
        print("nx-agent beacon sent", flush=True)
    except OSError as e:
        print(f"nx-agent beacon blocked ({e}) — fine, that's egress control working", flush=True)
    # idle so a forensicator can catch it live; the lab script kills it when done.
    time.sleep(CONFIG["interval_s"])

if __name__ == "__main__":
    main()
