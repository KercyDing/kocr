#!/usr/bin/env python3

"""Show or update the workspace version in Cargo.toml."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CARGO_TOML = ROOT / "Cargo.toml"
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


WORKSPACE_SECTION = re.compile(r"(?ms)^\[workspace\.package\]\n(.*?)(?=^\[|\Z)")


def read_version() -> str:
    source = CARGO_TOML.read_text(encoding="utf-8")
    section = WORKSPACE_SECTION.search(source)
    if section is None:
        raise ValueError("missing [workspace.package] section")
    version = re.search(r'^version\s*=\s*"([^"]+)"', section.group(1), re.MULTILINE)
    if version is None:
        raise ValueError("missing [workspace.package] version")
    return version.group(1)


def write_version(version: str) -> None:
    source = CARGO_TOML.read_text(encoding="utf-8")

    def replace(match: re.Match[str]) -> str:
        section, updated = re.subn(
            r'^version\s*=\s*"[^"]*"',
            f'version = "{version}"',
            match.group(1),
            count=1,
            flags=re.MULTILINE,
        )
        if updated != 1:
            raise ValueError("expected one [workspace.package] version")
        return f"[workspace.package]\n{section}"

    updated, count = WORKSPACE_SECTION.subn(replace, source)
    if count != 1:
        raise ValueError("expected one [workspace.package] section")
    CARGO_TOML.write_text(updated, encoding="utf-8")


def main() -> None:
    arguments = sys.argv[1:]
    if arguments == ["show"]:
        version = read_version()
        print(f"v{version}")
        return
    if len(arguments) != 2 or arguments[0] != "change":
        raise ValueError("usage: version.py show | version.py change <vMAJOR.MINOR.PATCH>")

    tag = arguments[1]
    if not tag.startswith("v"):
        raise ValueError(f"version must start with v: {tag}")
    version = tag[1:]
    if len(version) > 128 or not SEMVER.fullmatch(version):
        raise ValueError(f"invalid semantic version: {tag}")

    previous = read_version()
    if version == previous:
        print(f"v{previous}")
        return
    write_version(version)
    print(f"v{previous} -> v{version}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(f"version: {error}", file=sys.stderr)
        raise SystemExit(1) from error
