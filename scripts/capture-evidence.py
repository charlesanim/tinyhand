#!/usr/bin/env python3
"""Record live capture tests over a separate, privacy-safe native window."""

import argparse
import os
from pathlib import Path
import select
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="A new output directory")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    subprocess.run(["swift", "build"], cwd=root, check=True)
    subprocess.run(
        ["swiftc", str(root / "scripts/capture-fixture.swift"), "-o", str(output / "fixture")],
        check=True,
    )
    fixture = subprocess.Popen([str(output / "fixture")], stdout=subprocess.PIPE, text=True)
    recorder = None
    try:
        if (
            not select.select([fixture.stdout], [], [], 10)[0]
            or fixture.stdout.readline().strip() != "fixture ready"
        ):
            raise RuntimeError("The privacy-safe fixture did not become ready")
        time.sleep(0.5)
        recorder = subprocess.Popen(
            ["/usr/sbin/screencapture", "-x", "-v", "-V", "20", "-m", str(output / "demo.mov")]
        )
        result = subprocess.run(
            [str(root / ".build/debug/TinyHand"), "--e2e-test"],
            cwd=root,
            env=dict(os.environ, TH_CAPTURE_OUTPUT=str(output)),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=60,
        )
        (output / "e2e.log").write_text(result.stdout)
        print(result.stdout, end="")
        # Keep the fixture on screen until recording ends, even if a test failed.
        recorder.wait(timeout=30)
        result.check_returncode()
        if recorder.returncode:
            raise RuntimeError(f"Recording failed with status {recorder.returncode}")
    finally:
        if recorder is not None and recorder.poll() is None:
            recorder.terminate()
            recorder.wait(timeout=10)
        if fixture.poll() is None:
            fixture.terminate()
            fixture.wait(timeout=5)


if __name__ == "__main__":
    main()
