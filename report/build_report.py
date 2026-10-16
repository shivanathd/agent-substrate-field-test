#!/usr/bin/env python3
"""Build report/index.html (tabbed, self-contained) from the repo's data.

Inputs:  results/benchmarks.csv (bench/summarize.py), docs/code-review.json,
         results/verify-last.txt (written by scripts/verify.sh), report/diagrams/*.svg
Output:  report/index.html, docs/code-review.md
Memory-scaling views prefer the 5-minute runs (`*_5m`): upstream's 1-minute entries fit only a
few cycles of a multi-GiB actor.
"""
import csv, html, json, math, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
rows = list(csv.DictReader((ROOT / "results/benchmarks.csv").open()))
esc = html.escape
S = 1 / 1000  # ms -> s


def run(test):
    """Best row for a catalogue test: the 5-minute variant if present, else the run with the
    most wake samples."""
    cands = [r for r in rows if r["test"] == f"{test}_5m"] or [r for r in rows if r["test"] == test]
    return max(cands, key=lambda r: int(r.get("ResumeActor_n") or 0), default=None)


def v(r, k, scale=1.0):
    try:
        return float(r[k]) * scale
    except (TypeError, ValueError, KeyError):
        return None


def fmt(x, unit="s"):
    if x is None:
        return "–"
    if unit == "s":
        return f"{x:.2f} s" if x < 10 else f"{x:.1f} s"
    return f"{x:,.0f} {unit}".strip()


def money(x):
    return f"${x:,.0f}"


def table(head, body, cls=""):
    h = "".join(f"<th>{c}</th>" for c in head)
    b = "".join("<tr>" + "".join(f"<td>{c}</td>" for c in r) + "</tr>" for r in body)
    return f'<div class="tw"><table class="{cls}"><thead><tr>{h}</tr></thead><tbody>{b}</tbody></table></div>'


trip = lambda r, op: " / ".join(fmt(v(r, f"{op}_{q}", S)) for q in ("p50", "p95", "p99")) if r else "–"

# ------------------------------------------------------------------ memory scaling chart
mem = {"few MB": (run("glutton_baseline_1_user"), None),
       "1 GiB": (run("glutton_mem_1gi_gvisor"), run("glutton_mem_1gi_microvm")),
       "2 GiB": (run("glutton_mem_2gi_gvisor"), run("glutton_mem_2gi_microvm"))}


def memory_panel(metric, title, ymax):
    W, H, L, R, T, B = 330, 230, 44, 70, 26, 34
    xs = list(mem)
    inset = 18
    px = lambda i: L + inset + (W - L - R - 2 * inset) * (i / (len(xs) - 1))
    py = lambda s: T + (H - T - B) * (1 - s / ymax)
    used = []
    out = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="{esc(title)}">',
           f'<text class="ptitle" x="{L}" y="14">{esc(title)}</text>']
    step = 4 if ymax > 12 else 2
    for t in range(0, int(ymax) + 1, step):
        out.append(f'<line class="grid" x1="{L}" x2="{W-R}" y1="{py(t):.1f}" y2="{py(t):.1f}"/>'
                   f'<text class="tick" x="{L-8}" y="{py(t)+4:.1f}" text-anchor="end">{t} s</text>')
    for i, x in enumerate(xs):
        out.append(f'<text class="tick" x="{px(i):.1f}" y="{H-12}" text-anchor="middle">{x}</text>')
    for si, (cls, name) in enumerate([("s1", "gVisor"), ("s2", "microVM")]):
        pts, marks = [], []
        for i, x in enumerate(xs):
            r = mem[x][si]
            p50, p95 = (v(r, f"{metric}_p50", S), v(r, f"{metric}_p95", S)) if r else (None, None)
            if p50 is None:
                continue
            dx = -5 if si == 0 else 5
            pts.append((px(i) + dx, py(p50)))
            tip = f"{name}, {x}: median {fmt(p50)}, p95 {fmt(p95)}, n={r.get(metric + '_n')}"
            if p95 and p95 > p50:
                marks.append(f'<line class="whisk {cls}" x1="{px(i)+dx:.1f}" x2="{px(i)+dx:.1f}" y1="{py(p50):.1f}" y2="{py(p95):.1f}"/>')
            marks.append(f'<circle class="dot {cls}" cx="{px(i)+dx:.1f}" cy="{py(p50):.1f}" r="5" data-tip="{esc(tip)}" tabindex="0"><title>{esc(tip)}</title></circle>')
        if len(pts) > 1:
            out.append(f'<polyline class="ln {cls}" points="{" ".join(f"{a:.1f},{b:.1f}" for a, b in pts)}"/>')
        out.extend(marks)
        if pts:
            lx, ly = pts[-1]; ly += 4
            for uy in used:
                if abs(ly - uy) < 13:
                    ly = uy + 13 if ly >= uy else uy - 13
            used.append(ly)
            out.append(f'<text class="dlabel" x="{lx+10:.1f}" y="{ly:.1f}">{name}</text>')
    out.append("</svg>")
    return "\n".join(out)


ymax = max([x for g, m in mem.values() for r in (g, m) if r for x in
            (v(r, "ResumeActor_p95", S), v(r, "SuspendActor_p95", S)) if x] + [2])
ymax = 4 * math.ceil(ymax / 4)
chart_mem = memory_panel("ResumeActor", "Wake (resume)", ymax) + memory_panel("SuspendActor", "Sleep (suspend)", ymax)

# ------------------------------------------------------------------ phase breakdown chart
phase_items = []
for x, (g, _) in mem.items():
    if g:
        fetch = (v(g, "restore.manifest_fetch_p50", S) or 0) + (v(g, "restore.download_p50", S) or 0)
        phase_items.append((f"Wake · {x}", fetch, v(g, "restore.worker_restore_p50", S) or 0, "download from bucket", "restore sandbox"))
for x, (g, _) in mem.items():
    if g:
        phase_items.append((f"Sleep · {x}", v(g, "checkpoint.persist_p50", S) or 0, v(g, "checkpoint.worker_checkpoint_p50", S) or 0, "upload to bucket", "checkpoint sandbox"))


def phase_chart():
    W, L, R, rowh = 680, 112, 56, 30
    H = 40 + rowh * len(phase_items)
    tot = max((a + b for _, a, b, *_ in phase_items), default=1)
    sx = lambda s: (W - L - R) * s / tot
    out = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Phase breakdown of wake and sleep time">']
    for i, (lab, a, b, la, lb) in enumerate(phase_items):
        y = 10 + i * rowh
        wa, wb = sx(a), sx(b)
        ta, tb = f"{lab}: {la} {fmt(a)}", f"{lab}: {lb} {fmt(b)}"
        out.append(f'<text class="tick" x="{L-10}" y="{y+15}" text-anchor="end">{esc(lab)}</text>'
                   f'<rect class="bar s3" x="{L}" y="{y+4}" width="{max(wa-1,1):.1f}" height="16" rx="2" data-tip="{esc(ta)}" tabindex="0"><title>{esc(ta)}</title></rect>'
                   f'<rect class="bar s4" x="{L+wa+1:.1f}" y="{y+4}" width="{max(wb-1,1):.1f}" height="16" rx="2" data-tip="{esc(tb)}" tabindex="0"><title>{esc(tb)}</title></rect>'
                   f'<text class="vlabel" x="{L+wa+wb+6:.1f}" y="{y+16}">{fmt(a+b)}</text>')
    out.append("</svg>")
    return "\n".join(out)


# ------------------------------------------------------------------ cost model
# Prices: GCP Cloud Billing Catalog API (us-west1, 2026-10-16); vendor pricing pages (2026-10-16).
P = dict(c3_core=0.03465, c3_gib=0.003938, c3_core_spot=0.01367, c3_gib_spot=0.001553,
         pd_gb_mo=0.10, gke_h=0.10, gcs_gb_mo=0.020, gcs_classa_per_k=0.005,
         e2b_vcpu_h=0.000014 * 3600, e2b_gib_h=0.0000045 * 3600,
         day_vcpu_h=0.0504, day_gib_h=0.0162,
         vercel_cpu_h=0.128, vercel_gb_h=0.0212, vercel_snap_gb_mo=0.08)
HOURS, N, CPU, GIB = 730, 1000, 0.5, 1.0
NODE_OD = 4 * P["c3_core"] + 16 * P["c3_gib"] + 100 * P["pd_gb_mo"] / HOURS
NODE_SPOT = 4 * P["c3_core_spot"] + 16 * P["c3_gib_spot"] + 100 * P["pd_gb_mo"] / HOURS
nodes = lambda active: math.ceil(max(active * CPU / 3.92, active * GIB / 13.0))
ALWAYS = nodes(N)
DUTY = [0.05, 0.10, 0.25, 0.50]
# GCS for Substrate: ~300 KB own snapshot + 18 MB template base per agent kind; 20 wakes/agent/day,
# ~10 Class A ops per suspend/resume cycle (estimate). Rounding error either way.
gcs_month = N * 0.0003 * P["gcs_gb_mo"] + N * 20 * 30 * 10 / 1000 * P["gcs_classa_per_k"]


def costs(d):
    awake_h = N * d * HOURS
    sub = nodes(N * d * 2) + 1
    return {
        "Substrate, on-demand nodes": sub * NODE_OD * HOURS + P["gke_h"] * HOURS + gcs_month,
        "Substrate, spot nodes (untested)": sub * NODE_SPOT * HOURS + P["gke_h"] * HOURS + gcs_month,
        # E2B and Daytona list the same per-second rates, so they are one line
        "E2B or Daytona (not billed while paused)": awake_h * (CPU * P["e2b_vcpu_h"] + GIB * P["e2b_gib_h"]),
        "Vercel Sandbox": awake_h * (CPU * P["vercel_cpu_h"] + GIB * P["vercel_gb_h"]) + N * GIB * P["vercel_snap_gb_mo"],
        "Always-on pods, one per agent": ALWAYS * NODE_OD * HOURS + P["gke_h"] * HOURS,
    }


COST_SERIES = list(costs(0.05))
COST_CLS = ["c1", "c2", "c3", "c4", "ref"]  # reference palette slots 1-5 + reference line


def cost_chart():
    W, H, L, R, T, B = 680, 300, 62, 20, 16, 38
    data = {d: costs(d) for d in DUTY}
    ymax = 5000 * math.ceil(max(max(c.values()) for c in data.values()) / 5000)
    px = lambda i: L + 30 + (W - L - R - 60) * i / (len(DUTY) - 1)
    py = lambda y: T + (H - T - B) * (1 - y / ymax)
    out = [f'<svg viewBox="0 0 {W} {H}" role="img" aria-label="Monthly cost for 1,000 agents by share of time awake">']
    for t in range(0, int(ymax) + 1, 5000):
        out.append(f'<line class="grid" x1="{L}" x2="{W-R}" y1="{py(t):.1f}" y2="{py(t):.1f}"/>'
                   f'<text class="tick" x="{L-8}" y="{py(t)+4:.1f}" text-anchor="end">${t//1000}k</text>')
    for i, d in enumerate(DUTY):
        out.append(f'<text class="tick" x="{px(i):.1f}" y="{H-14}" text-anchor="middle">{d:.0%} awake</text>')
    for name, cls in zip(COST_SERIES, COST_CLS):
        pts = [(px(i), py(data[d][name])) for i, d in enumerate(DUTY)]
        dash = ' stroke-dasharray="5 4"' if cls == "ref" else ""
        out.append(f'<polyline class="ln {cls}"{dash} points="{" ".join(f"{a:.1f},{b:.1f}" for a, b in pts)}"/>')
        for i, d in enumerate(DUTY):
            tip = f"{name}, {d:.0%} awake: {money(data[d][name])}/month"
            out.append(f'<circle class="dot {cls}" cx="{pts[i][0]:.1f}" cy="{pts[i][1]:.1f}" r="4.5" data-tip="{esc(tip)}" tabindex="0"><title>{esc(tip)}</title></circle>')
    out.append(f'<line class="axis" x1="{L}" x2="{W-R}" y1="{H-B}" y2="{H-B}"/></svg>')
    return "\n".join(out)


cost_legend = "".join(f'<span><i class="sw {c}"></i>{esc(n)}</span>' for n, c in zip(COST_SERIES, COST_CLS))
cost_rows = [[esc(n)] + [money(costs(d)[n]) for d in DUTY] for n in COST_SERIES]
node_rows = [[f"{d:.0%}", nodes(N * d * 2) + 1, ALWAYS, f"{ALWAYS/(nodes(N*d*2)+1):.1f}×"] for d in DUTY]

# ------------------------------------------------------------------ tables
cat = lambda t: ("1 · floor" if "baseline_1" in t else "2 · memory" if "mem_" in t else
                 "3 · durable dir" if "durdir" in t else "4 · concurrency")
all_rows = []
for r in sorted(rows, key=lambda r: (cat(r["test"]), r["test"], r["run"])):
    all_rows.append([f'<code>{esc(r["test"])}</code>', r.get("sandbox") or "–", r.get("workers") or "–",
                     r.get("ResumeActor_n") or "–", trip(r, "ResumeActor"), trip(r, "SuspendActor"),
                     f'{int(r["requests"]):,}', r["failures"]])

cmp_rows = []
for m in ("1gi", "2gi"):
    for cls in ("gvisor", "microvm"):
        r = run(f"glutton_mem_{m}_{cls}")
        if r:
            cmp_rows.append([m.replace("gi", " GiB"), "gVisor" if cls == "gvisor" else "microVM", r.get("ResumeActor_n"),
                             trip(r, "ResumeActor"), trip(r, "SuspendActor"),
                             fmt(v(r, "restore.download_p50", S)), fmt(v(r, "restore.worker_restore_p50", S))])

conc = [(f"{u} / {w}", run(t)) for u, w, t in [(1, 1, "glutton_baseline_1_user"), (5, 5, "glutton_baseline_5_users"),
        (10, 10, "glutton_baseline_10_users"), (15, 10, "glutton_oversubscribe_15_users")]]
conc_rows = [[u, f'{int(r["requests"]):,}', r["failures"], fmt(v(r, "ResumeActor_p95", S)),
              fmt(v(r, "SuspendActor_p95", S)), fmt(v(r, "checkpoint.persist_p50", S))] for u, r in conc if r]

dd_rows = []
for t, what in [("durdir_data_baseline", "volume only, explicit wake"), ("durdir_implicit_resume", "volume only, woken by the request"),
                ("durdir_full_baseline", "volume and memory")]:
    r = run(t)
    if r:
        dd_rows.append([f"<code>{t}</code>", what, " / ".join(fmt(v(r, f"ResumeActor_{q}", S)) for q in ("p50", "p95")),
                        " / ".join(fmt(v(r, f"SuspendActor_{q}", S)) for q in ("p50", "p95")),
                        " / ".join(fmt(v(r, f"DurDirServeAfterResume_{q}", S)) for q in ("p50", "p95")),
                        fmt(v(r, "DurDirServeWarm_p50", S))])

pause_rows = []
for label, sus, pau in [("few MB", "glutton_baseline_1_user", "glutton_baseline_1_user_pause"),
                        ("1 GiB", "glutton_mem_1gi_gvisor", "glutton_mem_1gi_gvisor_pause")]:
    a, b = run(sus), run(pau)
    if a and b:
        pause_rows.append([label, fmt(v(a, "ResumeActor_p50", S)), fmt(v(b, "ResumeActor_p50", S)),
                           f'{v(a,"ResumeActor_p50")/v(b,"ResumeActor_p50"):.1f}×'])

phase_rows = [[esc(l), fmt(a), fmt(b), fmt(a + b)] for l, a, b, *_ in phase_items]

# ------------------------------------------------------------------ verification
review = json.loads((ROOT / "docs/code-review.json").read_text())
sev_order = {"high": 0, "medium": 1, "low": 2, "info": 3}
rev_rows = [[f'<span class="chip {"bad" if f["sev"]=="high" else "warn" if f["sev"]=="medium" else "mute"}">{f["sev"]}</span>',
             f'<code>{esc(f["file"])}</code>', esc(f["issue"]), esc(f["fix"]),
             f'<span class="chip {"good" if f["status"]=="fixed" else "warn"}">{f["status"]}</span>']
            for f in sorted(review["findings"], key=lambda f: sev_order[f["sev"]])]
counts = {s: sum(f["sev"] == s for f in review["findings"]) for s in sev_order}
fixed = sum(f["status"] == "fixed" for f in review["findings"])
vpath = ROOT / "results/verify-last.txt"
verify_lines = vpath.read_text().strip().splitlines() if vpath.exists() else ["(run scripts/verify.sh)"]
verify_html = "\n".join(
    f'<li class="{"ok" if "PASS" in l else "no" if "FAIL" in l else "hd"}">{esc(l.strip())}</li>' for l in verify_lines if l.strip())

(ROOT / "docs/code-review.md").write_text(
    "# Code review\n\n" + review["method"] + f"\n\nReviewed {review['reviewed']}. "
    f"{len(review['findings'])} findings ({counts['high']} high, {counts['medium']} medium, {counts['low']} low, "
    f"{counts['info']} info); {fixed} fixed.\n\n| Severity | File | Issue | Fix | Status |\n|---|---|---|---|---|\n" +
    "".join(f"| {f['sev']} | `{f['file']}` | {f['issue']} | {f['fix']} | {f['status']} |\n"
            for f in sorted(review["findings"], key=lambda f: sev_order[f["sev"]])) +
    "\n_Generated by `report/build_report.py` from `docs/code-review.json`._\n")

# ------------------------------------------------------------------ assemble
svg = lambda n: (ROOT / f"report/diagrams/{n}.svg").read_text()
b1, g1, g2, m2 = run("glutton_baseline_1_user"), mem["1 GiB"][0], mem["2 GiB"][0], mem["2 GiB"][1]
o15 = run("glutton_oversubscribe_15_users")
c5 = costs(0.05)
fill = {
    "CHART_MEM": chart_mem, "CHART_PHASE": phase_chart(), "CHART_COST": cost_chart(), "COST_LEGEND": cost_legend,
    "TABLE_ALL": table(["Run", "Sandbox", "Workers", "Wakes", "Wake p50 / p95 / p99", "Sleep p50 / p95 / p99", "Requests", "Fail"], all_rows, "dense"),
    "TABLE_CMP": table(["Memory", "Sandbox", "Wakes", "Wake p50 / p95 / p99", "Sleep p50 / p95 / p99", "Download p50", "Restore p50"], cmp_rows),
    "TABLE_CONC": table(["Agents / workers", "Requests", "Failures", "Wake p95", "Sleep p95", "Upload p50"], conc_rows),
    "TABLE_DD": table(["Run", "What is snapshotted", "Wake p50 / p95", "Sleep p50 / p95", "First read after wake", "Warm read"], dd_rows),
    "TABLE_PAUSE": table(["Memory", "Wake from bucket (p50)", "Wake from pause (p50)", "Faster by"], pause_rows),
    "TABLE_PHASE": table(["Operation (gVisor, p50)", "Bucket transfer", "Sandbox", "Total"], phase_rows),
    "TABLE_COST": table(["Option, 1,000 agents"] + [f"{d:.0%} awake" for d in DUTY], cost_rows),
    "TABLE_NODES": table(["Share awake", "Substrate nodes", "Always-on nodes", "Fewer by"], node_rows),
    "TABLE_REVIEW": table(["Severity", "File", "Issue", "Fix", "Status"], rev_rows, "review"),
    "VERIFY_LINES": verify_html,
    "REVIEW_SUMMARY": f"{len(review['findings'])} findings: {counts['high']} high, {counts['medium']} medium, {counts['low']} low, {counts['info']} open note. {fixed} fixed.",
    "SVG_ARCH_L": svg("arch-light"), "SVG_ARCH_D": svg("arch-dark"), "SVG_FLOW_L": svg("flow-light"), "SVG_FLOW_D": svg("flow-dark"),
    "SMALL_RESUME": fmt(v(b1, "ResumeActor_p50", S)), "G1_RESUME": fmt(v(g1, "ResumeActor_p50", S)),
    "G2_RESUME": fmt(v(g2, "ResumeActor_p50", S)), "M2_RESUME": fmt(v(m2, "ResumeActor_p50", S)),
    "O15_REQ": f'{int(o15["requests"]):,}' if o15 else "–",
    "TOTAL_REQ": f'{sum(int(r["requests"]) for r in rows):,}', "TOTAL_RUNS": str(len(rows)),
    "TOTAL_FAIL": str(sum(int(r["failures"]) for r in rows)),
    "ALWAYS": str(ALWAYS), "DUTY5": str(nodes(N * 0.05 * 2) + 1),
    "C5_SUB": money(c5["Substrate, on-demand nodes"]), "C5_SPOT": money(c5["Substrate, spot nodes (untested)"]),
    "C5_E2B": money(c5["E2B or Daytona (not billed while paused)"]), "C5_VERCEL": money(c5["Vercel Sandbox"]),
    "C5_ALWAYS": money(c5["Always-on pods, one per agent"]),
    "NODE_OD": f"{NODE_OD:.4f}", "NODE_SPOT": f"{NODE_SPOT:.4f}",
}
# Post kit tab: drafts, a fact sheet built from the same numbers as the rest of the page, and the docs as raw source.
pre = lambda t: html.escape(t)
li = (ROOT / "post/linkedin.md").read_text()
facts = {
    "repo": "https://github.com/shivanathd/agent-substrate-field-test",
    "upstream": "https://github.com/agent-substrate/substrate @ 603e006 (after v0.5.0)",
    "setup": "GKE 1.36.4, 2 x c3-standard-4, us-west1, gVisor and microVM sandboxes",
    "test_cost_usd": "about 3", "wall_clock": "4 h 15 m", "cluster_cost_per_day_usd": "12.73",
    "state_persistence": "20 of 20 freeze/thaw cycles exact (memory, files, root filesystem), across workers",
    "claude_code_agents": "3 agents suspended and resumed mid-loop; in-memory counters continued; all resumed on a different worker; 8/8 checks",
    "credential_injection": "8/8: gateway injected the secret; absent from agent env, /proc environ and filesystem",
    "snapshot_secret_copies": 77,
    "wake_p50_seconds": {"small": fill["SMALL_RESUME"], "1GiB_gvisor": fill["G1_RESUME"], "2GiB_gvisor": fill["G2_RESUME"], "2GiB_microvm": fill["M2_RESUME"]},
    "benchmark": {"runs": fill["TOTAL_RUNS"], "requests": fill["TOTAL_REQ"], "failures": fill["TOTAL_FAIL"], "oversubscribed_15_agents_on_10_workers_requests": fill["O15_REQ"]},
    "monthly_cost_1000_agents_5pct_awake_usd": {"substrate_on_demand": fill["C5_SUB"], "substrate_spot_untested": fill["C5_SPOT"],
        "e2b_or_daytona": fill["C5_E2B"], "vercel_sandbox": fill["C5_VERCEL"], "always_on_pods": fill["C5_ALWAYS"]},
    "nodes_1000_agents_5pct_awake": {"substrate": fill["DUTY5"], "always_on": fill["ALWAYS"]},
}
fact_rows = [[k.replace("_", " "), html.escape(json.dumps(v) if isinstance(v, dict) else str(v))] for k, v in facts.items()]
DOCS = ["findings", "use-cases", "cost", "benchmarks", "methodology", "timeline", "upstream-issues", "code-review"]
fill.update({
    "POST_LI": pre(li), "POST_LI_CHARS": f"{len(li):,}", "POST_LONG": pre((ROOT / "post/post.md").read_text()),
    "POST_FACTS": table(["Fact", "Value"], fact_rows),
    "POST_FACTS_JSON": json.dumps(facts, indent=2).replace("</", "<\\/"),
    "POST_SOURCES": "\n".join(f'<details><summary>docs/{d}.md</summary><div class="code"><pre class="md">{pre((ROOT / f"docs/{d}.md").read_text())}</pre></div></details>' for d in DOCS),
    "FONTS_CSS": (ROOT / "report/fonts.css").read_text(),
})
page = (ROOT / "report/template.html").read_text()
for k, val in fill.items():
    page = page.replace("{{" + k + "}}", str(val))
assert "{{" not in page, page[page.index("{{"):page.index("{{") + 40]
(ROOT / "report/index.html").write_text(page)
print("wrote report/index.html and docs/code-review.md")
