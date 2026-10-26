#!/usr/bin/env python3
"""Fetch the exact upstream source into an ignored directory. No global installations."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]

def run(*args, cwd=ROOT):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()

def verify_vendor(target, revision, apply_manifest_fix=False):
    if run("git", "rev-parse", "HEAD", cwd=target) != revision:
        raise ValueError("Vendor revision differs from the lock; refusing to overwrite it.")
    status = subprocess.check_output(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"], cwd=target, text=True)
    if status not in ["", " M Package.swift\n"]:
        raise ValueError("Vendor has unexpected modifications; review before building.")
    original = subprocess.check_output(
        ["git", "show", revision+":Package.swift"], cwd=target, text=True)
    old = "// swift-tools-version:5.3\n"
    if not original.startswith(old):
        raise ValueError("Unknown upstream manifest; review the compatibility fix.")
    expected = "// swift-tools-version:5.5\n" + original[len(old):]
    manifest = target / "Package.swift"
    actual = manifest.read_text(encoding="utf-8")
    if actual == original and not status and apply_manifest_fix:
        # The pinned manifest uses macOS 12 / iOS 15 APIs introduced in SwiftPM 5.5.
        with manifest.open("w", encoding="utf-8", newline="\n") as handle:
            handle.write(expected)
    elif actual != expected:
        raise ValueError("Vendor manifest differs from the one allowed tools-version correction.")

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
    verify_vendor(target, lock["revision"], apply_manifest_fix=not args.verify_only)
    if args.verify_only:
        print("Dependency revision and bounded manifest correction verified.")
        return
    subprocess.run([sys.executable, str(ROOT / "scripts/generate_project.py")], check=True)
    print("Dependency verified at " + lock["revision"])
    print("Open NPV.xcodeproj on a Mac; configure Config/Local.xcconfig for device signing.")

if __name__ == "__main__":
    main()
