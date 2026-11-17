#!/usr/bin/env python3
"""Validate the native frontend and worker as a relocatable, private app bundle."""
from pathlib import Path
import plistlib
import subprocess
import sys


def architectures(binary):
    return set(subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split())


def validate(app):
    contents = app / "Contents"
    with (contents / "Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    assert info["CFBundleExecutable"] == "CTDoNative", "Wrong frontend executable"
    assert info["CFBundleIdentifier"].endswith(".native"), "Native app must have its own identity"
    assert info["CFBundleShortVersionString"] != "0.0.0", "Version was not stamped"
    frontend = contents / "MacOS/CTDoNative"
    core = contents / "Helpers/ctdozlite-core"
    for binary in (frontend, core):
        assert binary.is_file() and binary.stat().st_mode & 0o111, f"Not executable: {binary.name}"
    assert architectures(frontend) == architectures(core), "Frontend/worker architectures differ"
    # Every bundled helper must run on each architecture the frontend runs on.
    for name in ("Helpers/HistoryCodec", "Helpers/DailyNotifier.app/Contents/MacOS/DailyNotifier",
                 "Resources/EmojiPreview", "Resources/MediaPreview", "Resources/DailyMediaViewer"):
        helper = contents / name
        if helper.is_file():
            assert architectures(helper) == architectures(frontend), f"Helper architectures differ: {helper.name}"
    for path in contents.rglob("*"):
        name = path.name.lower()
        assert not (name.startswith("session") and name.endswith(".json")), "Session in bundle"
        assert not name.endswith((".db", ".sqlite", ".sqlite3", ".log")), "Private data in bundle"
        assert name not in {"qr.png", "call_relay.json"}, "Runtime state in bundle"
        if path.is_symlink():
            assert path.resolve().is_relative_to(contents.resolve()), "External bundle symlink"
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    print("Native frontend and Rust worker bundle validated.")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: validate-swiftui-bundle.py APP")
    validate(Path(sys.argv[1]))
