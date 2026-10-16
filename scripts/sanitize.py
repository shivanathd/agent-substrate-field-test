#!/usr/bin/env python3
"""Strip your own identifiers from results and docs before publishing.

Run logs embed your project ID, bucket name, local paths and so on. This rewrites them in place.

  scripts/sanitize.py --replace my-project=<PROJECT_ID> --replace /Users/me=~ [paths...]
  scripts/sanitize.py --check my-project --check me@corp.com [paths...]   # exit 1 if any remain

Default paths: results/ docs/ post/ README.md. Credential-shaped strings (sk-ant-, AIza, ghp_,
-----BEGIN) are always checked.
"""
import argparse, pathlib, re, sys

ALWAYS = [r"sk-ant-[A-Za-z0-9_-]{10,}", r"AIza[0-9A-Za-z_-]{30,}", r"ghp_[A-Za-z0-9]{30,}",
          r"-----BEGIN [A-Z ]*PRIVATE KEY-----"]


def files(paths):
    for p in map(pathlib.Path, paths):
        if p.is_file():
            yield p
        elif p.is_dir():
            yield from (f for f in p.rglob("*") if f.is_file() and ".git" not in f.parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--replace", action="append", default=[], metavar="OLD=NEW")
    ap.add_argument("--check", action="append", default=[], metavar="STRING")
    ap.add_argument("paths", nargs="*", default=["results", "docs", "post", "README.md"])
    a = ap.parse_args()
    bad_args = [r for r in a.replace if "=" not in r or not r.split("=", 1)[0]]
    if bad_args:
        ap.error(f"--replace needs a non-empty OLD=NEW, got {bad_args}")
    pairs = [r.split("=", 1) for r in a.replace]
    pairs.sort(key=lambda kv: -len(kv[0]))  # longest first, so paths beat their prefixes
    changed = bad = 0
    for f in files(a.paths):
        try:
            text = f.read_text()
        except (UnicodeDecodeError, OSError):
            continue
        new = text
        for old, rep in pairs:
            new = new.replace(old, rep)
        if new != text:
            f.write_text(new); changed += 1
        for s in a.check:
            if s in new:
                print(f"REMAINS  {s!r} in {f}"); bad += 1
        for rx in ALWAYS:
            if re.search(rx, new):
                print(f"CREDENTIAL-SHAPED  /{rx}/ in {f}"); bad += 1
    print(f"rewrote {changed} files; {bad} problems")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
