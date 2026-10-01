#!/usr/bin/env python3
"""Smoke-test a freshly packaged app on an ephemeral macOS CI runner."""
import subprocess
import sys
import tempfile
import time
from pathlib import Path

app = Path(sys.argv[1]).resolve()
executable = app / "Contents/MacOS/Launcher27B"
with tempfile.TemporaryFile() as stderr:
    process = subprocess.Popen([str(executable)], stdout=subprocess.DEVNULL, stderr=stderr)
    try:
        time.sleep(5)
        if process.poll() is not None:
            stderr.seek(0)
            raise SystemExit(f"Packaged app exited during startup ({process.returncode}):\n"
                             + stderr.read().decode(errors="replace"))
        print("Packaged app survived startup and resource initialization")
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
