#!/usr/bin/env python3
"""Render the tap from the final signed DMG; never use a placeholder checksum."""
import argparse
import hashlib
import re
from pathlib import Path


def render(version: str, digest: str) -> str:
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ValueError("Expected a numeric MAJOR.MINOR.PATCH version")
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("Expected a SHA-256 digest")
    return f'''cask "27b-launcher" do
  version "{version}"
  sha256 "{digest}"

  url "https://github.com/mreasonyang/27b-launcher/releases/download/v#{{version}}/27B-Launcher-#{{version}}-macOS-arm64.dmg"
  name "27B Launcher"
  desc "Native launcher for local 27B models"
  homepage "https://github.com/mreasonyang/27b-launcher"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "27B Launcher.app"
end
'''


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    expected = f"27B-Launcher-{args.version}-macOS-arm64.dmg"
    if args.dmg.name != expected:
        parser.error(f"DMG must be named {expected}")
    hasher = hashlib.sha256()
    with args.dmg.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            hasher.update(chunk)
    digest = hasher.hexdigest()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(render(args.version, digest), encoding="utf-8")
    print(f"Generated {args.output} for {args.version}: {digest}")


if __name__ == "__main__":
    main()
