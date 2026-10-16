#!/usr/bin/env bash
# One command that checks this repo is internally consistent and safe to publish.
#
#   scripts/verify.sh [--forbid STRING ...]
#
#  1. code      every script parses (bash -n, py_compile)
#  2. tests     each functional test log ends in its pass line
#  3. bench     every summarised run has raw data; zero failures outside bench-invalid/
#  4. lineage   every number in the README/post/report traces to results/benchmarks.csv;
#               the summary and report rebuild byte-identical from raw data
#  5. links     every relative Markdown link resolves
#  6. identity  no forbidden identifiers or credential-shaped strings in publishable files
#
# Exit 0 only if every check passes.
set -uo pipefail
cd "$(dirname "$0")/.."
FORBID=()
while [ $# -gt 0 ]; do
  case "$1" in
    --forbid) [ $# -ge 2 ] || { echo "--forbid needs a value" >&2; exit 2; }; FORBID+=(--check "$2"); shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
fail=0
# Keep a copy of this run's output for the report's Verification tab (no timestamps, so a
# re-run with the same results writes an identical file and the report rebuild stays stable).
LAST=results/verify-last.txt; exec > >(tee "$LAST.tmp") 2>&1
ok()  { printf '  PASS  %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; fail=1; }

echo "1. code"
for f in scripts/*.sh tests/*.sh bench/*.sh; do bash -n "$f" || bad "bash -n $f"; done
python3 -m py_compile bench/*.py tests/*.py report/*.py scripts/*.py && ok "all scripts parse" || bad "python compile"

echo "2. tests"
f=$(ls results/raw/01-state-persistence-*.csv 2>/dev/null | tail -1)
[ -n "$f" ] && python3 -c "
import csv,sys; r=list(csv.DictReader(open('$f')))
sys.exit(0 if r and all(x['ok']=='1' for x in r) else 1)" && ok "F1 $(($(wc -l <"$f")-1)) cycles, all state checks ok" || bad "F1 log"
for t in 03-claude-multiplex 05-credential-injection; do
  f=$(ls results/raw/$t-*.log 2>/dev/null | tail -1)
  [ -n "$f" ] && grep -qE '^result: [0-9]+ passed, 0 failed' "$f" && ok "$t: $(grep '^result' "$f")" || bad "$t log missing or has failures"
done
f=$(ls results/raw/06-snapshot-secret-scan-*.log 2>/dev/null | tail -1)
[ -n "$f" ] && grep -q 'secret occurrences across' "$f" && ok "F6: $(grep 'secret occurrences' "$f")" || bad "F6 log"

echo "3. bench"
python3 - <<'PY' || fail=1
import csv, pathlib, sys
rows = list(csv.DictReader(open("results/benchmarks.csv")))
missing = [r["run"] for r in rows if not (pathlib.Path("results/raw/bench") / r["run"] / "stats.jsonl").exists()]
failed = [r["test"] for r in rows if int(r["failures"])]
raw = sorted(p.name for p in pathlib.Path("results/raw/bench").iterdir() if (p / "stats.jsonl").exists())
unsummarised = sorted(set(raw) - {r["run"] for r in rows})
for cond, msg in [(not missing, f"{len(rows)} summarised runs all have raw stats.jsonl"),
                  (not unsummarised, "every raw run is in the summary"),
                  (not failed, f"{sum(int(r['requests']) for r in rows):,} requests, 0 failures")]:
    print(("  PASS  " if cond else "  FAIL  ") + msg)
if missing or failed or unsummarised:
    print("        missing:", missing, "failed:", failed, "unsummarised:", unsummarised); sys.exit(1)
PY

echo "4. lineage"
# Rebuild from raw data and compare. verify never leaves the repo changed: originals are
# restored afterwards, so a drift shows as FAIL rather than being silently "fixed".
T=$(mktemp -d); cp results/benchmarks.csv results/benchmarks.md report/index.html "$T"/
if python3 bench/summarize.py >/dev/null && python3 report/build_report.py >/dev/null; then
  cmp -s results/benchmarks.csv "$T/benchmarks.csv" && ok "benchmarks.csv rebuilds identically from raw runs" || bad "benchmarks.csv drifted from raw runs (run bench/summarize.py)"
  cmp -s report/index.html "$T/index.html" && ok "report rebuilds identically from benchmarks.csv" || bad "report/index.html is stale (run report/build_report.py)"
else
  bad "rebuild failed (bench/summarize.py or report/build_report.py)"
fi
cp "$T/benchmarks.csv" "$T/benchmarks.md" results/; cp "$T/index.html" report/; rm -rf "$T"
python3 - <<'PY' || fail=1
import csv, pathlib, sys
ALL = list(csv.DictReader(open("results/benchmarks.csv")))
R = {r["test"]: r for r in ALL}
def s(t, k):
    # a test can have repeat runs; a stated number must equal one of them exactly
    vals = [float(r[k]) / 1000 for r in ALL if r["test"] == t and r.get(k)]
    return vals
claims_exact = True
txt = {f: pathlib.Path(f).read_text() for f in ["README.md", "post/post.md", "post/linkedin.md", "docs/benchmarks.md", "docs/cost.md"]}
# (claim, value from data, string that must then appear, files that state it)
claims = [
  ("small wake p50", s("glutton_baseline_1_user", "ResumeActor_p50"), "0.22", ["README.md", "post/post.md"]),
  ("1 GiB gVisor wake p50", s("glutton_mem_1gi_gvisor_5m", "ResumeActor_p50"), "3.5", ["README.md", "post/post.md", "post/linkedin.md"]),
  ("1 GiB gVisor wake p95", s("glutton_mem_1gi_gvisor_5m", "ResumeActor_p95"), "4.0", ["README.md", "post/post.md"]),
  ("2 GiB gVisor wake p50", s("glutton_mem_2gi_gvisor_5m", "ResumeActor_p50"), "6.9", ["README.md", "post/post.md", "docs/cost.md"]),
  ("2 GiB microVM wake p50", s("glutton_mem_2gi_microvm_5m", "ResumeActor_p50"), "16", ["README.md", "post/post.md", "post/linkedin.md"]),
  ("15/10 requests", [float(R["glutton_oversubscribe_15_users"]["requests"])], "2,123", ["README.md", "post/linkedin.md"]),
]
bad = 0
for name, vals, s_, files in claims:
    want = float(s_.replace(",", ""))
    if not any(abs(v - want) < 1e-9 for v in vals):
        print(f"  FAIL  {name}: data has {vals}, docs say {s_}"); bad += 1; continue
    missing = [f for f in files if s_ not in txt[f]]
    print(("  FAIL  " if missing else "  PASS  ") + f"{name} = {s_} (exact match in data)" + (f" missing in {missing}" if missing else ""))
    bad += bool(missing)
# cost table in docs/cost.md must equal the report's cost model, cell for cell
src = pathlib.Path("report/build_report.py").read_text().split("# ------------------------------------------------------------------ tables")[0]
ns = {"__file__": str(pathlib.Path("report/build_report.py").resolve())}
exec(compile(src, "build_report", "exec"), ns)
cost_md = pathlib.Path("docs/cost.md").read_text()
cells = [f"${v:,.0f}" for d in ns["DUTY"] for v in ns["costs"](d).values()]
missing = sorted({c for c in cells if c not in cost_md})
print(("  FAIL  cost table differs from model: " + ", ".join(missing)) if missing
      else f"  PASS  docs/cost.md matches the cost model ({len(cells)} cells)")
bad += bool(missing)
sys.exit(1 if bad else 0)
PY

echo "5. links"
python3 - <<'PY' || fail=1
import pathlib, re, sys
broken = []
for md in [pathlib.Path("README.md"), *pathlib.Path("docs").glob("*.md"), *pathlib.Path("results/raw").rglob("README.md")]:
    for target in re.findall(r"\]\(([^)#\s]+)(?:#[^)]*)?\)", md.read_text()):
        if target.startswith(("http://", "https://", "mailto:")): continue
        if not (md.parent / target).exists(): broken.append(f"{md} -> {target}")
print(("  FAIL  " + "; ".join(broken)) if broken else "  PASS  all relative links resolve")
sys.exit(1 if broken else 0)
PY

echo "6. identity"
# Only files git would publish: local gitignored files (scripts/env.sh) may hold real identifiers.
python3 scripts/sanitize.py ${FORBID[@]+"${FORBID[@]}"} $(git ls-files -co --exclude-standard -- \
    results 'docs/*.md' 'docs/*.diff' post README.md report scripts tests bench LICENSE .gitignore .claude) \
  | sed 's/^/  /' | tail -20
[ "${PIPESTATUS[0]}" = 0 ] && ok "no forbidden identifiers or credential-shaped strings" || bad "identity check"
git check-ignore -q docs/internal/x 2>/dev/null && ok "docs/internal/ is gitignored" || bad "docs/internal/ not ignored"

echo
[ $fail = 0 ] && echo "VERIFY: all checks passed" || echo "VERIFY: FAILED"
sleep 0.2; mv "$LAST.tmp" "$LAST"
exit $fail
