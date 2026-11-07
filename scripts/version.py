#!/usr/bin/env python3

"""Show or update the version in build.zig.zon."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ZON = ROOT / "build.zig.zon"
VERSION = re.compile(r'^(\s*)\.version\s*=\s*"([^"]*)"', re.MULTILINE)
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


def read_version() -> str:
    match = VERSION.search(ZON.read_text(encoding="utf-8"))
    if match is None:
        raise ValueError("missing .version in build.zig.zon")
    return match.group(2)


def write_version(version: str) -> None:
    source = ZON.read_text(encoding="utf-8")
    updated, count = VERSION.subn(lambda m: f'{m.group(1)}.version = "{version}"', source, count=1)
    if count != 1:
        raise ValueError("expected one .version in build.zig.zon")
    ZON.write_text(updated, encoding="utf-8")


def main() -> None:
    arguments = sys.argv[1:]
    if arguments == ["show"]:
        print(f"v{read_version()}")
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
    except ValueError as error:
        print(error, file=sys.stderr)
        sys.exit(1)
