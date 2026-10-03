#!/usr/bin/env python3
"""Reject preview binaries whose linked SDK differs from the selected build SDK."""

import re
import subprocess
import sys


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


if len(sys.argv) != 3:
    sys.exit("Usage: verify-macos-sdk.py EXECUTABLE EXPECTED_SDK_VERSION")

binary, expected_sdk = sys.argv[1:]
commands = subprocess.check_output(["/usr/bin/otool", "-l", binary], text=True)
blocks = re.findall(r"cmd LC_BUILD_VERSION\n(.*?)(?=Load command|\Z)", commands, re.S)
if not blocks:
    sys.exit("Missing LC_BUILD_VERSION; refusing to launch an unverified UI preview.")

for block in blocks:
    platform = re.search(r"^\s*platform (\S+)", block, re.M)
    minimum = re.search(r"^\s*minos ([\d.]+)", block, re.M)
    sdk = re.search(r"^\s*sdk ([\d.]+)", block, re.M)
    if not platform or platform.group(1) not in ("1", "MACOS") or not minimum or not sdk:
        sys.exit("Missing or unexpected macOS build metadata.")
    if version(sdk.group(1)) != version(expected_sdk):
        sys.exit(f"Linked SDK {sdk.group(1)} != selected SDK {expected_sdk}. "
                 "Rebuild with scripts/preview-app.sh; do not copy a plain SwiftPM executable.")
    if version(minimum.group(1)) != version("14.4"):
        sys.exit(f"Unexpected minimum macOS {minimum.group(1)}; expected 14.4.")
    print(f"Verified linked SDK {sdk.group(1)}, minimum macOS {minimum.group(1)}")
