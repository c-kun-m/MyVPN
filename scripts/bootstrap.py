#!/usr/bin/env python3
"""Fetch the exact upstream source into an ignored directory. No global installations."""
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def main():
    lock = json.loads((ROOT / "scripts/dependencies.json").read_text())["wireguardApple"]
    target = ROOT / "Vendor/wireguard-apple"
    if not target.exists():
        target.parent.mkdir(exist_ok=True)
        run("git", "clone", "--depth", "1", "--branch", lock["tag"], lock["repository"], str(target))
    actual = run("git", "rev-parse", "HEAD", cwd=target)
    if actual != lock["revision"]:
        raise SystemExit("Vendor revision differs from the lock; refusing to overwrite it.")
    if run("git", "status", "--porcelain", cwd=target):
        raise SystemExit("Vendor has modifications; review before building.")
    subprocess.run([sys.executable, str(ROOT / "scripts/generate_project.py")], check=True)
    print("Dependency verified at " + actual)
    print("Open NPV.xcodeproj on a Mac; configure Config/Local.xcconfig for device signing.")

if __name__ == "__main__":
    main()
