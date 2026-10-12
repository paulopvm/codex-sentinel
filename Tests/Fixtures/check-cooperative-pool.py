#!/usr/bin/env python3
"""Catch blocking pipe reads that starve Swift tasks on Macs with fewer cores."""
import os
import signal
import subprocess
import sys

runtime_env = os.environ.copy()
runtime_env["LIBDISPATCH_COOPERATIVE_POOL_STRICT"] = "1"
process = subprocess.Popen(sys.argv[1:], env=runtime_env, start_new_session=True)
try:
    result = process.wait(timeout=45)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    sys.exit("Writer checks stalled with a constrained Swift cooperative pool")
if result != 0:
    sys.exit(result)
print("Writer lifecycle checks passed with a constrained Swift cooperative pool")
