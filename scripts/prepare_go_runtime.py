#!/usr/bin/env python3
"""Apply upstream's Darwin continuous-clock change to a private GOROOT copy.

The 2020 upstream unified diff relies on obsolete surrounding assembly. We replace
only its three exact symbol sites, verifying layout before copying. Unknown layouts
fail closed. The installed Go runtime and the vendored WireGuard source are untouched.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

SITES = {
    "src/runtime/sys_darwin.go": (b"libc_mach_absolute_time mach_absolute_time", b"libc_mach_continuous_time mach_continuous_time"),
    "src/runtime/sys_darwin_amd64.s": (b"CALL\tlibc_mach_absolute_time(SB)", b"CALL\tlibc_mach_continuous_time(SB)"),
    "src/runtime/sys_darwin_arm64.s": (b"BL\tlibc_mach_absolute_time(SB)", b"BL\tlibc_mach_continuous_time(SB)"),
}

def digest(data):
    return hashlib.sha256(data).hexdigest()

def plan(source):
    transformed = {}
    original_hashes = {}
    for relative, (old, new) in SITES.items():
        content = (source / relative).read_bytes()
        if content.count(old) == 1 and content.count(new) == 0:
            result = content.replace(old, new)
        elif content.count(old) == 0 and content.count(new) == 1:
            result = content
        else:
            raise ValueError(f"Unsupported Go clock implementation in {relative}; manual compatibility review required.")
        original_hashes[relative] = digest(content)
        transformed[relative] = result
    return transformed, original_hashes

def prepare(source, destination):
    source, destination = source.resolve(), destination.resolve()
    if source == destination or source in destination.parents or destination in source.parents:
        raise ValueError("The temporary GOROOT must be separate from the installed Go source.")
    transformed, source_hashes = plan(source)
    manifest = {"format":1, "goVersion":(source / "VERSION").read_text().splitlines()[0], "originalSHA256":source_hashes,
                "patchedSHA256":{p:digest(data) for p,data in transformed.items()}}
    manifest_path = destination / "npv-runtime-manifest.json"
    if destination.exists():
        if not manifest_path.exists() or json.loads(manifest_path.read_text()) != manifest or not (destination / ".prepared").exists():
            raise ValueError("Cached runtime is incomplete or differs; use a fresh Xcode DerivedData directory.")
        for path, expected in manifest["patchedSHA256"].items():
            if digest((destination / path).read_bytes()) != expected:
                raise ValueError("Cached patched runtime was modified; refusing to build.")
        return manifest
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    for relative, data in transformed.items():
        path = destination / relative
        # Do not follow a symlink out of the private runtime copy.
        if path.is_symlink() or destination not in path.resolve().parents:
            raise ValueError("Unexpected runtime source symlink.")
        path.write_bytes(data)
    manifest_path.write_text(json.dumps(manifest, indent=2)+"\n")
    (destination / ".prepared").touch()
    return manifest

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if args.check_only:
        _, hashes = plan(args.source)
        print("Compatible clock sites:", json.dumps(hashes, sort_keys=True))
    else:
        if args.destination is None:
            parser.error("--destination is required unless --check-only is used")
        info = prepare(args.source, args.destination)
        print("Private Darwin continuous-clock runtime prepared:", info["goVersion"])

if __name__ == "__main__": main()
