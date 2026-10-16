#!/usr/bin/env python3
"""Test 06: are secrets held in an actor's RAM readable in its snapshots?

Substrate's MEMORY-fidelity snapshots write the actor's memory pages to object storage. Any
secret the agent holds in RAM (an API key in its environment, a token it fetched) goes with
them. This downloads snapshot objects, unwraps Substrate's container format, and counts how
often a given secret appears. It never prints the secret.

File format observed (v0.5.0): 8-byte magic b"ATESPRSE", 4-byte little-endian version (2),
then a zstd stream (possibly multi-frame).

Usage:
  SCAN_SECRET="$(security find-generic-password -s <item> -w)" \
    tests/06-snapshot-secret-scan.py gs://<bucket>/<storageLocation-prefix>/ [--max-files 20]

Exit 1 if the secret is found in any snapshot (that is the finding, not a test bug).
Needs: gcloud, `pip install zstandard`.
"""
import argparse, io, os, subprocess, sys, tempfile, pathlib

import zstandard

MAGIC = b"ATESPRSE"


def unwrap(blob: bytes) -> bytes:
    if blob[:8] != MAGIC:
        raise ValueError(f"unexpected magic {blob[:8]!r}")
    reader = zstandard.ZstdDecompressor().stream_reader(io.BytesIO(blob[12:]), read_across_frames=True)
    return reader.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("prefix", help="gs:// prefix holding snapshots (the template's storageLocation)")
    ap.add_argument("--max-files", type=int, default=20)
    a = ap.parse_args()
    secret = os.environ.get("SCAN_SECRET", "").encode()
    if len(secret) < 12:
        sys.exit("set SCAN_SECRET to the secret to search for (>= 12 chars)")

    listing = subprocess.run(["gcloud", "storage", "ls", "-r", a.prefix.rstrip("/") + "/**"],
                             check=True, text=True, capture_output=True).stdout.split()
    objs = [o for o in listing if o.endswith(".zstd") and ("/pages" in o or "/checkpoint" in o)][: a.max_files]
    found = 0
    print(f"{'object':90} {'compressed':>11} {'raw':>12} {'matches':>7}")
    with tempfile.TemporaryDirectory() as td:
        for o in objs:
            local = pathlib.Path(td, "obj")
            subprocess.run(["gcloud", "storage", "cp", "-q", o, str(local)], check=True)
            blob = local.read_bytes()
            raw = unwrap(blob)
            n = raw.count(secret)
            found += n
            print(f"{o[-90:]:90} {len(blob):>11,} {len(raw):>12,} {n:>7}")
            local.unlink()
    print(f"\nsecret occurrences across {len(objs)} snapshot objects: {found}")
    print("FINDING: secret is readable in snapshots" if found else "secret not found in scanned snapshots")
    sys.exit(1 if found else 0)


if __name__ == "__main__":
    main()
