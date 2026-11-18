#!/usr/bin/env python3
"""Apply Wisualizer's lifecycle fix to its exact supported GodotRealityKit revision."""

import argparse
from pathlib import Path
import subprocess
import sys

BASE = "fbfdaaeddd5899bfcae109eecbed253937c84aa4"
FILES = (
    "godotrealitykit/GodotRealityKit/GodotRealityKit.h",
    "godotrealitykit/GodotRealityKit/Nodes/window_hosts.mm",
    "godotrealitykit/GodotRealityKit/RealityKit/HandAnchors.swift",
    "godotrealitykit/GodotRealityKit/RealityKitBridge.swift",
    "godotrealitykit/GodotRealityKit/extension.mm",
)


def git(checkout, *args, check=True):
    return subprocess.run(
        ["git", "-C", str(checkout), *args],
        text=True, capture_output=True, check=check,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path, help="plugins-for-godot checkout at the pinned commit")
    parser.add_argument("--check", action="store_true", help="verify applicability or an exact already-applied patch without editing")
    args = parser.parse_args()
    checkout = args.checkout.resolve()
    patch = Path(__file__).resolve().parents[1] / "patches" / "godotrealitykit-hand-tracking.patch"
    try:
        if not patch.is_file():
            raise ValueError(f"Patch file is missing: {patch}")
        if Path(git(checkout, "rev-parse", "--show-toplevel").stdout.strip()).resolve() != checkout:
            raise ValueError("Pass the plugins-for-godot repository root, not a subdirectory.")
        head = git(checkout, "rev-parse", "HEAD").stdout.strip()
        if head != BASE:
            raise ValueError(f"Unsupported plugin revision {head}; expected {BASE}.")
        # Do not overwrite user edits, including staged changes. Changes to unrelated
        # files (such as generated local build configuration) remain outside this patch.
        current = git(checkout, "diff", "--no-ext-diff", "--no-renames", "--binary", "HEAD", "--", *FILES).stdout
        expected = patch.read_text()
        if current == expected:
            git(checkout, "apply", "--reverse", "--check", str(patch))
            print(f"Exact hand-tracking API revision 1 patch is already applied to {BASE}.")
            return 0
        if current or git(checkout, "diff", "--cached", "--no-ext-diff", "--name-only", "--", *FILES).stdout:
            raise ValueError("Patch target files have other changes; use a clean checkout of the pinned revision.")
        git(checkout, "apply", "--check", str(patch))
        if args.check:
            print(f"Hand-tracking patch can be applied to {BASE}; no files changed.")
            return 0
        git(checkout, "apply", str(patch))
        if git(checkout, "diff", "--no-ext-diff", "--no-renames", "--binary", "HEAD", "--", *FILES).stdout != expected:
            raise ValueError("Applied diff differs from the expected patch; inspect the checkout before building.")
        print(f"Applied hand-tracking API revision 1 patch to {BASE}. Rebuild the addon before use.")
        return 0
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        detail = error.stderr.strip() if isinstance(error, subprocess.CalledProcessError) else str(error)
        print(f"Hand-tracking patch: {detail}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
