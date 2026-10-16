#!/usr/bin/env python3
"""Run one upstream Substrate Locust benchmark as an in-cluster Job and pull its results.

Upstream's automation (benchmarking/automation) drives this from a separate orchestration
cluster. We only need the last step, so this renders upstream's own runner-job.yaml.tmpl,
appends the test's flags, applies it, waits, and copies <dest>/runs/<tag>/ to results/raw/.

Usage:
  bench/run-locust.py --substrate ~/src/substrate --context <ctx> --bucket <bucket> \
      --name glutton_baseline --file /app/tests/glutton.py -t 2m -u 1 -- --min-wait-time 1.0
"""
import argparse, json, pathlib, re, subprocess, sys, time

import yaml  # PyYAML


def sh(*cmd, check=True, capture=False):
    print("+", " ".join(cmd), file=sys.stderr)
    r = subprocess.run(cmd, check=check, text=True, capture_output=capture)
    return r.stdout if capture else None


def clean_actors(context, atespace="benchmark"):
    """Upstream's Locust tests leave their last actor running when a test ends. Each benchmark
    actor reserves 1 vCPU, so leftovers fill a small pool and the next test fails with
    "no worker has room for the actor". Upstream's automation tears the whole stack down between
    tests; we delete the test atespace's actors instead."""
    out = sh("kubectl", "ate", "--context", context, "get", "actors", "-a", atespace, "-o", "json",
             check=False, capture=True) or "{}"
    names = [x["metadata"]["name"] for x in json.loads(out).get("actors", [])]
    for n in names:
        sh("kubectl", "ate", "--context", context, "delete", "actor", n, "-a", atespace, "--any-state",
           check=False, capture=True)
    if names:
        print(f"cleaned {len(names)} leftover actors from atespace {atespace}", file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--substrate", required=True, help="path to the substrate checkout")
    ap.add_argument("--context", required=True)
    ap.add_argument("--bucket", required=True)
    ap.add_argument("--image", required=True, help="locust-test image built by upstream build_and_push.sh")
    ap.add_argument("--catalog", help="take name/file/duration/users/flags from upstream "
                    "benchmarking/automation/tests.yaml entry of this name")
    ap.add_argument("--duration-override", help="with --catalog: run longer than the catalogue "
                    "entry (its 1 min fits only a few cycles of a multi-GiB actor); the run's "
                    "name gets a _<duration> suffix so it is never mistaken for the upstream entry")
    ap.add_argument("--name")
    ap.add_argument("--file")
    ap.add_argument("-t", "--duration", default="2m")
    ap.add_argument("-u", "--users", default="1")
    ap.add_argument("--timeout-min", type=int, default=30)
    ap.add_argument("--out", default="results/raw")
    ap.add_argument("flags", nargs="*", help="extra runner/test flags (after --)")
    a = ap.parse_args()
    if a.catalog:
        cat = yaml.safe_load(pathlib.Path(a.substrate, "benchmarking/automation/tests.yaml").read_text())
        t = next(x for x in cat["tests"] if x["name"] == a.catalog)
        a.name, a.file, a.duration, a.users = t["name"], t["file"], t["duration"], t["users"]
        a.flags = t.get("flags", []) + a.flags
        if a.duration_override:
            a.duration = a.duration_override
            a.name = f"{a.name}_{a.duration_override}"
    if not (a.name and a.file):
        ap.error("--catalog or both --name and --file are required")

    tag = f"{a.name}-{time.strftime('%Y%m%d-%H%M%S')}"
    job = re.sub(r"[^a-z0-9-]", "-", f"bench-{a.name}".lower())[:50].rstrip("-")
    dest = f"gs://{a.bucket}/bench"
    tmpl = pathlib.Path(a.substrate, "benchmarking/automation/manifests/runner-job.yaml.tmpl").read_text()
    vals = dict(JOB_NAME=job, IMAGE=a.image, TEST_FILE=a.file, DURATION=a.duration, USERS=str(a.users),
                TAG=tag, NAME=a.name, DEST=dest, RUNNER_CPU="1", RUNNER_MEMORY="2Gi")
    rendered = re.sub(r"\$\{(\w+)\}", lambda m: vals.get(m.group(1), m.group(0)), tmpl)
    docs = [d for d in yaml.safe_load_all(rendered) if d]
    for d in docs:
        if d.get("kind") == "Job":
            d["spec"]["template"]["spec"]["containers"][0]["args"] += a.flags

    kubectl = ["kubectl", "--context", a.context]
    clean_actors(a.context)
    sh(*kubectl, "-n", "benchmarking", "delete", "job", job, "--ignore-not-found")
    subprocess.run(kubectl + ["apply", "-f", "-"], input=yaml.safe_dump_all(docs), text=True, check=True)

    # Wait for the Job's terminal condition (Complete or Failed), not the first pod failure.
    deadline, outcome = time.time() + a.timeout_min * 60, "timeout"
    while time.time() < deadline:
        st = json.loads(sh(*kubectl, "-n", "benchmarking", "get", "job", job, "-o", "json", capture=True))["status"]
        done = {c["type"] for c in st.get("conditions", []) if c.get("status") == "True"}
        if done & {"Complete", "Failed"}:
            outcome = "complete" if "Complete" in done else "failed"
            break
        time.sleep(15)
    logs = sh(*kubectl, "-n", "benchmarking", "logs", f"job/{job}", "--tail=-1", check=False, capture=True) or ""
    if outcome == "timeout":  # don't leave it running into the next test
        sh(*kubectl, "-n", "benchmarking", "delete", "job", job, "--wait=false", check=False)
    out = pathlib.Path(a.out, tag); out.mkdir(parents=True, exist_ok=True)
    (out / "runner.log").write_text(logs)
    # runner.py partitions: <dest>/runs/<name>/run_date=…/run_ts=…/run_tag=<tag>/
    sh("gcloud", "storage", "cp", "-r", f"{dest}/runs/{a.name}/**/run_tag={tag}/*", str(out), check=False)
    ok = outcome == "complete" and (out / "stats.jsonl").exists()
    print(f"{'OK' if ok else 'FAILED (' + outcome + ', stats.jsonl ' + ('present' if (out / 'stats.jsonl').exists() else 'missing') + ')'} {a.name} -> {out}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
