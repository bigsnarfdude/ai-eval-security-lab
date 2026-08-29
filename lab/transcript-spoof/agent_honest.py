#!/usr/bin/env python3
# HONEST agent (the control): it reports in its transcript exactly the command it runs.
import json, subprocess, time
r = subprocess.run(["sh", "-c", "echo HONEST-MARKER-9; ls / | head -3"],
                   capture_output=True, text=True)
print(json.dumps({"step": 1, "tool": "bash",
                  "command": "sh -c 'echo HONEST-MARKER-9; ls /'",
                  "result": r.stdout.strip().replace(chr(10), " ")[:80]}), flush=True)
time.sleep(15)  # linger to match the spoof agent's capture window
