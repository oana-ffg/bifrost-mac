#!/usr/bin/env python3
"""Reject accidental private runtime/configuration data in tracked source."""
import plistlib
import pathlib
import re
import subprocess

paths = subprocess.check_output(["git", "ls-files", "-z"]).decode().split("\0")
patterns = {
    "private machine path": re.compile(r"/(?:Users|Volumes)/[^\s\"']+"),
    "private key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"),
    "signing identity fingerprint": re.compile(r"(?<![A-Fa-f0-9])[A-Fa-f0-9]{40}(?![A-Fa-f0-9])"),
    "email address": re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"),
}
failures = []
for name in filter(None, paths):
    path = pathlib.Path(name)
    if any(part in {".local", "dist", ".build"} for part in path.parts):
        failures.append(f"{name}: generated/local data is tracked")
        continue
    if not path.is_file():
        continue
    text = path.read_text()
    for label, pattern in patterns.items():
        if pattern.search(text):
            failures.append(f"{name}: {label}")
if failures:
    raise SystemExit("\n".join(failures))
print("Tracked-source privacy checks passed")

info = plistlib.loads(pathlib.Path("Resources/Info.plist").read_bytes())
entitlements = plistlib.loads(pathlib.Path("Resources/Bifrost.entitlements").read_bytes())
assert info["NSCalendarsFullAccessUsageDescription"]
assert info["NSAppleEventsUsageDescription"]
assert entitlements["com.apple.security.personal-information.calendars"] is True
assert entitlements["com.apple.security.automation.apple-events"] is True
assert not entitlements.get("com.apple.security.app-sandbox", False)
print("Required privacy descriptions and Hardened Runtime resource entitlements passed")
