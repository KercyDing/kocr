#!/usr/bin/env python3
"""Package a prebuilt ncnn static library as a Zig package tarball."""

import argparse
import hashlib
import json
import shutil
import sys
import tarfile
import tempfile
import zlib
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--prefix", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--ncnn-zig", required=True)
    parser.add_argument("--zig", default="")
    args = parser.parse_args()

    prefix = Path(args.prefix)
    lib = prefix / "lib" / "libncnn.a"
    if not lib.exists():
        lib = prefix / "lib" / "ncnn.lib"
    include = prefix / "include"
    if not lib.exists() or not include.is_dir():
        sys.exit(f"missing {lib} or {include}")

    ncnn_zon = Path("ncnn.zon")
    if not ncnn_zon.exists():
        sys.exit("ncnn.zon is missing; run from the kocr root")

    stage = Path(tempfile.mkdtemp(prefix="ncnn-prebuilt-"))
    try:
        (stage / "lib").mkdir()
        shutil.copy2(lib, stage / "lib" / lib.name)
        shutil.copytree(include, stage / "include")
        shutil.copy2(ncnn_zon, stage / "ncnn.zon")

        name = "ncnn_prebuilt_%08x" % (zlib.crc32(args.target.encode()) & 0xFFFFFFFF)
        fingerprint = ((zlib.crc32(name.encode()) & 0xFFFFFFFF) << 32) | 1
        (stage / "build.zig").write_text(
            'pub fn build(_: *@import("std").Build) void {}\n'
        )
        (stage / "build.zig.zon").write_text(
            f""".{{
    .name = .{name},
    .version = "{args.version}",
    .fingerprint = 0x{fingerprint:x},
    .paths = .{{
        "build.zig",
        "build.zig.zon",
        "lib",
        "include",
        "ncnn.zon",
        "manifest.json",
    }},
}}
"""
        )

        flags_hash = hashlib.sha256(
            ncnn_zon.read_bytes() + args.ncnn_zig.encode()
        ).hexdigest()
        manifest = {
            "target": args.target,
            "version": args.version,
            "ncnn_zig": args.ncnn_zig,
            "zig": args.zig,
            "flags_sha256": flags_hash,
        }
        (stage / "manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        )

        out = Path(args.out)
        out.mkdir(parents=True, exist_ok=True)
        archive = out / f"ncnn-prebuilt-{args.version}-{args.target}.tar.gz"
        with tarfile.open(archive, "w:gz") as tar:
            for entry in sorted(stage.rglob("*")):
                tar.add(entry, arcname=entry.relative_to(stage), recursive=False)

        digest = hashlib.sha256(archive.read_bytes()).hexdigest()
        print(archive)
        print(digest)
    finally:
        shutil.rmtree(stage)


if __name__ == "__main__":
    main()
