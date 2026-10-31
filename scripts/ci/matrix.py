#!/usr/bin/env python3

"""Emit per-kind GitHub Actions matrices for release builds."""

from __future__ import annotations

import json
import sys
from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Platform:
    platform: str
    name: str
    kind: str
    target: str
    suffix: str
    asset_key: str
    deb_arch: str | None = None
    rpm_arch: str | None = None


KINDS = ("linux-qt", "linux-gtk", "macos-cli", "windows-cli")

PLATFORMS = (
    Platform(
        platform="ubuntu-22.04",
        name="Linux x86_64 Qt",
        kind="linux-qt",
        target="x86_64-unknown-linux-gnu",
        suffix="amd64",
        asset_key="linux-x64-qt",
        deb_arch="amd64",
        rpm_arch="x86_64",
    ),
    Platform(
        platform="ubuntu-24.04-arm",
        name="Linux ARM64 Qt",
        kind="linux-qt",
        target="aarch64-unknown-linux-gnu",
        suffix="arm64",
        asset_key="linux-arm64-qt",
        deb_arch="arm64",
        rpm_arch="aarch64",
    ),
    Platform(
        platform="ubuntu-24.04",
        name="Linux x86_64 GTK",
        kind="linux-gtk",
        target="x86_64-unknown-linux-gnu",
        suffix="amd64",
        asset_key="linux-x64-gtk",
        deb_arch="amd64",
        rpm_arch="x86_64",
    ),
    Platform(
        platform="ubuntu-24.04-arm",
        name="Linux ARM64 GTK",
        kind="linux-gtk",
        target="aarch64-unknown-linux-gnu",
        suffix="arm64",
        asset_key="linux-arm64-gtk",
        deb_arch="arm64",
        rpm_arch="aarch64",
    ),
    Platform(
        platform="macos-15",
        name="macOS ARM64 CLI",
        kind="macos-cli",
        target="aarch64-apple-darwin",
        suffix="arm64",
        asset_key="macos-arm64-cli",
    ),
    Platform(
        platform="macos-15-intel",
        name="macOS x64 CLI",
        kind="macos-cli",
        target="x86_64-apple-darwin",
        suffix="x64",
        asset_key="macos-x64-cli",
    ),
    Platform(
        platform="windows-latest",
        name="Windows x64 CLI",
        kind="windows-cli",
        target="x86_64-pc-windows-msvc",
        suffix="x64",
        asset_key="windows-x64-cli",
    ),
    Platform(
        platform="windows-11-arm",
        name="Windows ARM64 CLI",
        kind="windows-cli",
        target="aarch64-pc-windows-msvc",
        suffix="arm64",
        asset_key="windows-arm64-cli",
    ),
)


def fail(message: str) -> None:
    print(f"matrix: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate() -> None:
    asset_keys: set[str] = set()
    for entry in PLATFORMS:
        if entry.kind not in KINDS:
            fail(f"unsupported kind: {entry.kind}")
        if entry.asset_key in asset_keys:
            fail(f"duplicate asset_key: {entry.asset_key}")
        asset_keys.add(entry.asset_key)
        if entry.kind in {"linux-qt", "linux-gtk"} and (
            entry.deb_arch is None or entry.rpm_arch is None
        ):
            fail(f"missing package architectures for {entry.asset_key}")

    for kind in KINDS:
        if not any(entry.kind == kind for entry in PLATFORMS):
            fail(f"no entries for kind: {kind}")


def main() -> None:
    validate()
    for kind in KINDS:
        matrix = {
            "include": [
                {
                    key: value
                    for key, value in asdict(entry).items()
                    if value is not None
                }
                for entry in PLATFORMS
                if entry.kind == kind
            ]
        }
        print(f"{kind.replace('-', '_')}={json.dumps(matrix, separators=(',', ':'))}")


if __name__ == "__main__":
    main()
