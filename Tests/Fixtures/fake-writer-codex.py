#!/usr/bin/env python3
"""Model a writer lease held until its App Server process exits."""
import json
import os
import pathlib
import signal
import sys
import threading
import time

root = pathlib.Path(os.environ["CODEX_HOME"])
lease = None

def cleanup(*_):
    if lease is not None:
        lease.unlink(missing_ok=True)
    sys.exit(0)

signal.signal(signal.SIGTERM, cleanup)

def send(value):
    print(json.dumps(value), flush=True)

def finish(thread):
    while not (root / (thread + ".finish")).exists():
        time.sleep(0.01)
    status = "failed" if thread == "failed" else "interrupted" if thread == "interrupted" else "completed"
    send({"method": "turn/completed", "params": {"threadId": thread, "turn": {"id": thread + "-turn", "status": status}}})

try:
    for line in sys.stdin:
        request = json.loads(line)
        method, params = request["method"], request.get("params", {})
        result = {}
        if method == "initialized":
            continue
        if method == "thread/resume":
            thread = params["threadId"]
            lease = root / (thread + ".lease")
            lease.write_text(str(os.getpid()))
        elif method == "turn/start":
            thread = params["threadId"]
            if thread == "rejected":
                send({"id": request["id"], "error": {"message": "fixture turn rejected"}})
                continue
            result = {"turn": {"id": thread + "-turn", "status": "inProgress"}}
            if thread == "ambiguous":
                result = {}
            threading.Thread(target=finish, args=(thread,), daemon=True).start()
        elif method == "thread/read":
            thread = params["threadId"]
            (root / (thread + ".polled")).touch()
            done = (root / (thread + ".finish")).exists()
            result = {"thread": {"status": {"type": "idle" if done else "active", "activeFlags": []},
                                  "turns": [{"id": thread + "-turn", "status": "completed" if done else "inProgress"}]}}
        elif method == "account/rateLimits/read":
            result = {"rateLimits": {"primary": {"usedPercent": 12, "windowDurationMins": 300}}}
        send({"id": request["id"], "result": result})
finally:
    if lease is not None:
        lease.unlink(missing_ok=True)
