#!/usr/bin/env python3
"""
Minimal eval harness — the toy version of the real thing, end to end:

  1. ask the model (served by vLLM on :8000) to solve a coding task
  2. extract the code it wrote
  3. run that UNTRUSTED code inside the gVisor sandbox (a k8s Job, runtimeClassName: gvisor)
  4. score it against hidden tests and print a verdict

This is the pattern a frontier eval platform uses; only the scale differs. The security
property that matters — the model's code never runs on your trusted host, only in the sandbox —
is exactly the same here as in prod.

Deps: none beyond the Python standard library. Talks to the cluster via kubectl.
"""
import json, re, subprocess, sys, tempfile, textwrap, time, os
import urllib.request

VLLM = os.environ.get("VLLM_URL", "http://localhost:8000/v1")
MODEL = os.environ.get("MODEL", "Qwen/Qwen2.5-7B-Instruct")
NS = "evals"

TASK = "Write a Python function `is_palindrome(s: str) -> bool` that ignores case and non-alphanumeric characters."
TESTS = [
    ("A man, a plan, a canal: Panama", True),
    ("race a car", False),
    ("", True),
    ("0P", False),
]

def ask_model() -> str:
    """Get a completion and pull the python code block out of it."""
    print(f"[harness] asking {MODEL} to solve the task...")
    payload = json.dumps({
        "model": MODEL,
        "temperature": 0.2,
        "messages": [
            {"role": "system", "content": "You are a terse coding assistant. Reply with ONLY a python code block."},
            {"role": "user", "content": TASK},
        ],
    }).encode()
    req = urllib.request.Request(f"{VLLM}/chat/completions", data=payload,
                                 headers={"Content-Type": "application/json"})
    content = json.loads(urllib.request.urlopen(req, timeout=120).read())["choices"][0]["message"]["content"]
    m = re.search(r"```(?:python)?\s*(.*?)```", content, re.S)
    code = (m.group(1) if m else content).strip()
    print("[harness] model returned code:\n" + textwrap.indent(code, "    "))
    return code

def run_in_sandbox(candidate: str) -> str:
    """Run the model's code + tests inside a gVisor-sandboxed Job, return its logs."""
    runner = "import json\n" + candidate + "\n" + textwrap.dedent(f"""
        cases = {TESTS!r}
        passed = 0
        for s, want in cases:
            try:
                got = is_palindrome(s)
            except Exception as e:
                print("ERROR on", repr(s), e); continue
            ok = (got == want)
            passed += ok
            print(f"{{'PASS' if ok else 'FAIL'}} is_palindrome({{s!r}}) -> {{got}} (want {{want}})")
        print(json.dumps({{"passed": passed, "total": len(cases)}}))
    """)

    job = f"job-eval-{int(time.time())}"
    # candidate code delivered via a ConfigMap, mounted read-only into the sandbox.
    with tempfile.TemporaryDirectory() as d:
        cm = os.path.join(d, "run.py"); open(cm, "w").write(runner)
        subprocess.run(["kubectl","-n",NS,"create","configmap",job,f"--from-file=run.py={cm}"],
                       check=True)
        manifest = f"""
apiVersion: batch/v1
kind: Job
metadata:
  name: {job}
  namespace: {NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels: {{ app: eval-sandbox }}
    spec:
      runtimeClassName: gvisor
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext: {{ runAsNonRoot: true, runAsUser: 10001, seccompProfile: {{ type: RuntimeDefault }} }}
      containers:
        - name: runner
          image: eval-sandbox:demo
          imagePullPolicy: IfNotPresent
          command: ["python3","/code/run.py"]
          securityContext: {{ allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, capabilities: {{ drop: ["ALL"] }} }}
          resources: {{ requests: {{ cpu: "100m", memory: "128Mi" }}, limits: {{ cpu: "500m", memory: "256Mi" }} }}
          volumeMounts: [{{ name: code, mountPath: /code, readOnly: true }}]
      volumes:
        - name: code
          configMap: {{ name: {job} }}
"""
        mf = os.path.join(d, "job.yaml"); open(mf, "w").write(manifest)
        subprocess.run(["kubectl","apply","-f",mf], check=True)
        print(f"[harness] sandbox Job {job} running the model's code under gVisor...")
        subprocess.run(["kubectl","-n",NS,"wait","--for=condition=complete",f"job/{job}",
                        "--timeout=120s"], check=False)
        logs = subprocess.run(["kubectl","-n",NS,"logs",f"job/{job}"],
                              capture_output=True, text=True).stdout
        subprocess.run(["kubectl","-n",NS,"delete","job",job,"--ignore-not-found"], check=False)
        subprocess.run(["kubectl","-n",NS,"delete","configmap",job,"--ignore-not-found"], check=False)
    return logs

def main():
    code = ask_model()
    logs = run_in_sandbox(code)
    print("\n[harness] sandbox output:\n" + textwrap.indent(logs.strip(), "    "))
    score = None
    for line in logs.splitlines():
        try: score = json.loads(line)
        except Exception: pass
    if score:
        p, t = score["passed"], score["total"]
        print(f"\n[harness] SCORE: {p}/{t}  ->  {'PASS' if p==t else 'FAIL'}")
        sys.exit(0 if p == t else 1)
    print("[harness] could not parse a score — inspect the sandbox output above.")
    sys.exit(2)

if __name__ == "__main__":
    main()
