#!/usr/bin/env python3
# Reconcile an agent's SELF-REPORTED transcript against the OUT-OF-BAND record of what actually
# executed (Falco kernel events). A gap where a command ran but was never reported = a spoof.
# usage: verify.py <transcript.jsonl> <falco_events.txt>
import sys, json, re

transcript_path, falco_path = sys.argv[1], sys.argv[2]

claimed = []
for line in open(transcript_path):
    line = line.strip()
    if not line:
        continue
    try:
        claimed.append(json.loads(line).get("command", ""))
    except Exception:
        pass

# pull the actual command lines the kernel saw (Falco prints them as "proc=<cmdline> parent=...")
actual = []
for line in open(falco_path):
    m = re.search(r'proc=(.*?) (?:parent=|user=)', line)
    if m:
        actual.append(m.group(1).strip())
actual = list(dict.fromkeys(actual))  # dedupe, keep order

def reported(cmd):
    # simplified reconciliation: a distinctive token of the executed command must appear
    # somewhere in the claimed transcript. (A real system matches on a signed exec ledger.)
    toks = [t for t in re.split(r'[\s;|>]+', cmd) if len(t) > 4]
    return any(any(t in c for c in claimed) for t in toks) if toks else True

print("== agent SELF-REPORTED transcript (what the scorer / Agent-as-a-Judge / human sees) ==")
for c in claimed:
    print(f"   claims to have run: {c}")
print("== ACTUAL commands the kernel executed (Falco, out-of-band — the agent can't edit this) ==")
for a in actual:
    print(f"   really ran:         {a}")

unreported = [a for a in actual if not reported(a)]
print()
if unreported:
    print("!! TRANSCRIPT SPOOF DETECTED — executed but NOT in the transcript:")
    for a in unreported:
        print(f"     {a}")
    print("   The reviewer would sign off on a benign transcript; the kernel saw something else.")
    print("   Lesson: derive the transcript from a trusted exec ledger + reconcile against")
    print("           out-of-band capture. Never trust the agent's own account of what it did.")
    sys.exit(1)
else:
    print("OK: every executed command is accounted for in the transcript (honest agent).")
