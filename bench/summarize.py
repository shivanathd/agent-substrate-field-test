#!/usr/bin/env python3
"""Summarise every benchmark run under results/raw/bench/ into one CSV and one Markdown table.

Reads each run's stats.jsonl (written by upstream benchmarking/locust/runner.py):
  - grpc_/http_ rows: client-side latency percentiles per operation (ms)
  - trial_summary: cluster shape the run saw
  - phase_atelet_{restore,checkpoint}_* rows: server-side phase breakdown (ms)

Usage: bench/summarize.py [results/raw/bench] -> results/benchmarks.csv, results/benchmarks.md
"""
import csv, json, pathlib, sys

REPO = pathlib.Path(__file__).resolve().parent.parent
ROOT = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else REPO / "results/raw/bench"
OPS = ["ResumeActor", "SuspendActor", "ResumeActorFirstResume", "GluttonPing",
       "DurDirServeAfterResume", "DurDirServeWarm"]
PHASES = [("restore", "manifest_fetch"), ("restore", "download"), ("restore", "worker_restore"),
          ("restore", "total"), ("checkpoint", "worker_checkpoint"), ("checkpoint", "persist"),
          ("checkpoint", "total")]


def f(x):
    try:
        return round(float(x), 1)
    except (TypeError, ValueError):
        return None


def load(run: pathlib.Path):
    p = run / "stats.jsonl"
    if not p.exists():
        return None
    row = {"run": run.name}
    reqs = fails = 0
    for line in p.open():
        d = json.loads(line)
        m, v = d["metric"], d["measurements"]
        row.setdefault("test", d.get("test_name"))
        if m == "trial_summary":
            row.update(sandbox=v.get("sandbox_class"), workers=v.get("worker_pod_count"),
                       nodes=v.get("node_count"), machine=v.get("machine_type"))
        elif m.startswith(("grpc_", "http_")):
            op = m.split("_", 1)[1]
            reqs += int(v["request_count"]); fails += int(v["failure_count"])
            if op in OPS:
                row[f"{op}_n"] = int(v["request_count"])
                for q in ("p50", "p95", "p99"):
                    row[f"{op}_{q}"] = f(v[q])
        elif m.startswith("phase_atelet_") and "_latest_" in m:
            for op, ph in PHASES:
                if v.get("op") == op and v.get("phase") == ph:
                    row[f"{op}.{ph}_p50"] = f(v["p50_ms"]); row[f"{op}.{ph}_p95"] = f(v["p95_ms"])
    row.update(requests=reqs, failures=fails)
    return row


def main():
    rows = [r for r in (load(d) for d in sorted(ROOT.iterdir()) if d.is_dir()) if r]
    if not rows:
        sys.exit(f"no runs under {ROOT}")
    cols = ["test", "run", "sandbox", "workers", "nodes", "machine", "requests", "failures"]
    cols += [c for c in dict.fromkeys(k for r in rows for k in r) if c not in cols]
    out = REPO / "results"; out.mkdir(exist_ok=True)
    with (out / "benchmarks.csv").open("w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols); w.writeheader(); w.writerows(rows)

    md = ["| Test | Req | Fail | Resume p50 / p95 / p99 (ms) | Suspend p50 / p95 / p99 (ms) | "
          "Restore: fetch+download / sandbox (p50 ms) | Checkpoint: sandbox / upload (p50 ms) |",
          "|---|---|---|---|---|---|---|"]
    trip = lambda r, op: " / ".join(str(r.get(f"{op}_{q}", "–")) for q in ("p50", "p95", "p99"))
    for r in rows:
        fetch = (r.get("restore.manifest_fetch_p50") or 0) + (r.get("restore.download_p50") or 0)
        md.append(f"| `{r['test']}` | {r['requests']} | {r['failures']} | {trip(r, 'ResumeActor')} | "
                  f"{trip(r, 'SuspendActor')} | {round(fetch, 1)} / {r.get('restore.worker_restore_p50', '–')} | "
                  f"{r.get('checkpoint.worker_checkpoint_p50', '–')} / {r.get('checkpoint.persist_p50', '–')} |")
    (out / "benchmarks.md").write_text("\n".join(md) + "\n")
    print("\n".join(md))


if __name__ == "__main__":
    main()
