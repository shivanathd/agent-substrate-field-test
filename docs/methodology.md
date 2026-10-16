# Methodology

## The question

> Can we run hundreds of **persistent, mostly-idle agents** (one per user/customer, each holding
> memory and files for days, active a few minutes an hour) on a handful of nodes — with resume
> fast enough that a person doesn't notice, and without losing state?

That is the workload Agent Substrate is built for. Every test below maps to one part of that
question. Pass/fail bars were written **before** any test ran.

## Environment

| | |
|---|---|
| Substrate | `agent-substrate/substrate` @ `main`, shallow clone 2026-10-16 (release v0.5.0 was 2026-10-14) |
| Cluster | GKE 1.36.4 zonal, `us-west1-c`, 2× `c3-standard-4` (4 vCPU / 16 GB), nested virtualisation on |
| Snapshot store | GCS, same region |
| Sandbox | gVisor (default); microVM (Cloud Hypervisor via Kata) where noted |
| Load generator | Upstream Locust harness, run as an in-cluster Job, so client latency is cluster-local |
| Operator | arm64 Mac, Docker Desktop 8 GB, India → us-west1 |

Everything is the upstream default unless stated. We did not tune anything.

## Tests

### Functional (does it do what it says?)

| ID | Test | Pass bar |
|---|---|---|
| F1 | State persistence: counter actor, 20 suspend → resume cycles via the router; memory, file and rootfs counters checked every cycle | 0 mismatches |
| F2 | Migration: same as F1, record which worker pod served each cycle | Actor observed on >1 worker with state intact |
| F3 | Claude Code multiplex: 3 real Claude Code agents on a 2-worker pool, upstream demo | All tasks complete; the waiting agent resumes with its workspace intact |
| F4 | Egress identity + policy: upstream egress demo | Allowed URL succeeds; disallowed URL is refused; non-actor client refused at mTLS |
| F5 | Credential injection: secret referenced by policy, injected at the gateway | Upstream call authenticated; the secret is absent from the actor's env, `/proc/*/environ` and filesystem |

### Benchmarks (how fast, how dense, what breaks?)

All via the upstream Locust tests in `benchmarking/locust/tests/`, results pulled as CSV.

| ID | Upstream test | Metric | What it answers | Bar |
|---|---|---|---|---|
| B1 | `glutton.py` baseline, 1 user | p50/p95/p99 suspend, resume | Floor latency of a small actor | resume p95 < 1 s |
| B2 | `glutton.py` 1 GiB resident memory, gVisor vs microVM | suspend/resume vs memory size; snapshot bytes | Cost of a "fat" agent (a real coding agent holds 0.5–2 GB) | Measured, priced |
| B3 | `durdir.py` explicit vs implicit (traffic-triggered) resume | `ResumeActor`, `DurDirServeAfterResume` | Does the first request after wake pay a lazy-load penalty? | Measured |
| B4 | `sweperf.py` (replayed real SWE-Perf agent task, suspend between cycles) | `ResumeToFirstExec`, `TaskWallClock` | Overhead on a realistic coding-agent task | **Not run** — F3 (real Claude Code agents) covered the realistic case; sweperf images are large and out of time budget |
| B5 | Oversubscription: rising users vs workers, upstream catalogue | resume p95, suspend p95, failures | Where density stops being free | Met: 0 failures at 15 users / 10 workers |
| B6 | Node kill mid-run | actors recovered, data since last snapshot | Failure blast radius | **Not run deliberately.** Observed once by accident (worker pod deleted under 3 actors → CRASHED); revert not exercised |

Benchmarks that ran differently from this plan: the multi-GiB memory entries were also run for 5
minutes instead of upstream's 1 minute, because 1 minute fits only 1–7 cycles. Both are kept.

## Cost model

`cost per 1,000 idle agents / month` =
`(nodes needed for the active set × node $/h × 730)` + `snapshot GB × GCS $/GB-month` +
`GCS operations` + `GKE management fee`

…compared against the naive baseline of one always-on pod per agent at the same pod size.
Inputs come from B2 (snapshot bytes), B5 (active set per node) and the public GCP price list
for `us-west1` on the test date.

## What we deliberately did not test

- Multi-zone / regional HA, upgrades, or anything over multiple days.
- Production auth (OIDC/JWT providers) — the dev install uses ServiceAccount tokens.
- Scale beyond 2 nodes. Upstream's own scale claims ("millions of sandboxes") are theirs, not ours.
