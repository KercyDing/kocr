#!/usr/bin/env python3

"""Emit per-OS GitHub Actions matrices from declarative build dimensions."""

from __future__ import annotations

import json
import sys
from dataclasses import asdict, dataclass
from itertools import product


@dataclass(frozen=True)
class Arch:
    name: str
    suffix: str
    deb_arch: str | None = None
    rpm_arch: str | None = None


@dataclass(frozen=True)
class Os:
    name: str
    label: str
    runners: dict[str, str]
    targets: dict[str, str]


@dataclass(frozen=True)
class Platform:
    platform: str
    name: str
    kind: str
    target: str
    suffix: str
    asset_key: str
    components: tuple[str, ...]
    deb_arch: str | None = None
    rpm_arch: str | None = None


COMPONENTS = ("cli", "gui")

ARCHES = (
    Arch("x64", "amd64", "amd64", "x86_64"),
    Arch("arm64", "arm64", "arm64", "aarch64"),
)

OPERATING_SYSTEMS = (
    Os(
        "linux",
        "Linux",
        {"x64": "ubuntu-22.04", "arm64": "ubuntu-24.04-arm"},
        {
            "x64": "x86_64-unknown-linux-gnu",
            "arm64": "aarch64-unknown-linux-gnu",
        },
    ),
    Os(
        "macos",
        "macOS",
        {"x64": "macos-15-intel", "arm64": "macos-15"},
        {
            "x64": "x86_64-apple-darwin",
            "arm64": "aarch64-apple-darwin",
        },
    ),
    Os(
        "windows",
        "Windows",
        {"x64": "windows-latest", "arm64": "windows-11-arm"},
        {
            "x64": "x86_64-pc-windows-msvc",
            "arm64": "aarch64-pc-windows-msvc",
        },
    ),
)

KINDS = tuple(os.name for os in OPERATING_SYSTEMS)


def build_platforms() -> tuple[Platform, ...]:
    platforms = []
    for (os, arch) in product(OPERATING_SYSTEMS, ARCHES):
        platforms.append(
            Platform(
                platform=os.runners[arch.name],
                name=f"{os.label} {arch.name}",
                kind=os.name,
                target=os.targets[arch.name],
                suffix=arch.suffix,
                asset_key=f"{os.name}-{arch.name}",
                components=COMPONENTS,
                deb_arch=arch.deb_arch if os.name == "linux" else None,
                rpm_arch=arch.rpm_arch if os.name == "linux" else None,
            )
        )
    return tuple(platforms)


PLATFORMS = build_platforms()


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
        if not entry.components:
            fail(f"no components for {entry.asset_key}")
        unknown = set(entry.components) - set(COMPONENTS)
        if unknown:
            fail(f"unsupported components for {entry.asset_key}: {sorted(unknown)}")
        if entry.kind == "linux" and (
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
                    key: (list(value) if isinstance(value, tuple) else value)
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
