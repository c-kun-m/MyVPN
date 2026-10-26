#!/usr/bin/env python3
"""Fetch the exact upstream source into an ignored directory. No global installations."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
COMPATIBILITY_FIXES = {
    "Package.swift": ("// swift-tools-version:5.3\n", "// swift-tools-version:5.5\n"),
    "Sources/WireGuardKitC/WireGuardKitC.h": (
        '#include "key.h"\n', '#include <sys/types.h>\n#include "key.h"\n'),
}

def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def verify_vendor(target, revision, apply_compatibility_fixes=False):
    if run("git", "rev-parse", "HEAD", cwd=target) != revision:
        raise ValueError("Vendor revision differs from the lock; refusing to overwrite it.")
    status = subprocess.check_output(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=target, text=True)
    allowed_status = {" M " + path for path in COMPATIBILITY_FIXES}
    if any(line not in allowed_status for line in status.splitlines()):
        raise ValueError("Vendor has unexpected modifications; review before building.")
    pending = {}
    for relative, (old, new) in COMPATIBILITY_FIXES.items():
        original = subprocess.check_output(
            ["git", "show", revision+":"+relative], cwd=target, text=True, encoding="utf-8")
        if original.count(old) != 1 or new in original:
            raise ValueError("Unknown upstream layout; review compatibility fix: " + relative)
        expected = original.replace(old, new, 1)
        path = target / relative
        actual = path.read_text(encoding="utf-8")
        if actual == original and apply_compatibility_fixes:
            pending[path] = expected
        elif actual != expected:
            raise ValueError("Vendor differs from the allowed compatibility correction: " + relative)
    # Validate all files before applying either correction.
    for path, expected in pending.items():
        with path.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(expected)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    lock = json.loads((ROOT / "scripts/dependencies.json").read_text())["wireguardApple"]
    target = ROOT / "Vendor/wireguard-apple"
    if not target.exists():
        if args.verify_only:
            raise SystemExit("Run python3 scripts/bootstrap.py to prepare the dependency first.")
        target.parent.mkdir(exist_ok=True)
        run("git", "clone", "--depth", "1", "--branch", lock["tag"], lock["repository"], str(target))
    verify_vendor(target, lock["revision"], apply_compatibility_fixes=not args.verify_only)
    if args.verify_only:
        print("Dependency revision and bounded compatibility corrections verified.")
        return
    subprocess.run([sys.executable, str(ROOT / "scripts/generate_project.py")], check=True)
    print("Dependency verified at " + lock["revision"])
    print("Open NPV.xcodeproj on a Mac; configure Config/Local.xcconfig for device signing.")

if __name__ == "__main__":
    main()
