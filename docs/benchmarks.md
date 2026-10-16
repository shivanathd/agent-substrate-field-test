# Benchmarks

Upstream's own Locust harness (`benchmarking/locust`), running **in-cluster** as a Job, so these
are cluster-local numbers with no laptop or WAN in the path. Each row is an upstream catalogue
entry (`benchmarking/automation/tests.yaml`) run unmodified; `bench/run-all.sh` only groups them
and redeploys the workload shape each group needs. Summary: `results/benchmarks.csv`; raw runs:
`results/raw/bench/`.

**Cluster:** 2× `c3-standard-4` (7.84 vCPU, 25.9 GB allocatable), GKE 1.36.4, gVisor, GCS in
the same region. Upstream's `glutton` workload: a small Go server that can hold, churn and
re-read a configurable amount of memory. Each benchmark actor reserves 1 vCPU.

**How to read the operations**

- **Suspend**: checkpoint the sandbox → upload the snapshot to object storage → free the worker.
- **Resume**: fetch manifest → download snapshot → restore the sandbox on any worker.
- **Pause / resume-from-pause**: checkpoint to the *node's local disk* (no upload); the next
  resume is steered back to that node. Cheaper, but the actor stays pinned to the node.

## B1 — floor latency, one small actor

| Run | n | Resume p50 / p95 / p99 | Suspend p50 / p95 |
|---|---|---|---|
| `glutton_baseline_1_user` (run 1) | 33 | 220 / 330 / 350 ms | 540 / 640 ms |
| `glutton_baseline_1_user` (run 2) | 33 | 210 / 340 / 380 ms | 510 / 640 ms |
| `glutton_baseline_1_user_pause` | 46 | **130 / 140 / 140 ms** (from pause) | — |

Where the time goes (server-side phase breakdown, p50):

| Resume ≈ 205 ms | | Suspend ≈ 440 ms | |
|---|---|---|---|
| manifest fetch (GCS) | 31 ms | sandbox checkpoint (gVisor) | 118 ms |
| snapshot download (GCS) | 47 ms | **snapshot upload (GCS)** | **315 ms** |
| sandbox restore (gVisor) | 122 ms | other | ~5 ms |

**The "sub-500 ms resume" claim holds for small actors**, with margin at p99. Object storage is
~40% of resume and ~70% of suspend.

## B2 — memory size is the dominant factor

Upstream's memory entries run for 1 minute, which fits only 1–7 cycles of a multi-GiB actor. We
ran the same entries, same flags, for **5 minutes** (`*_5m` in the results) and report those; the
1-minute runs are listed for comparison.

| Resident memory | Run | Wakes measured | Wake p50 / p95 / p99 | Sleep p50 / p95 | Wake from pause p50 |
|---|---|---|---|---|---|
| few MB | `glutton_baseline_1_user` | 33 | 0.22 / 0.33 / 0.35 s | 0.54 / 0.64 s | 0.13 s |
| 1 GiB | `glutton_mem_1gi_gvisor_5m` | 36 | **3.5 / 4.0 / 4.5 s** | 3.5 / 4.2 s | 0.92 s (1-min run) |
| 2 GiB | `glutton_mem_2gi_gvisor_5m` | 13 | **6.9 / 15 / 15 s** | 10 / 18 s | — |
| *1 GiB, 1-min* | `glutton_mem_1gi_gvisor` | 7 | 3.2 / 3.7 s | 3.5 / 3.7 s | |
| *2 GiB, 1-min* | `glutton_mem_2gi_gvisor` | 3 | 7.3 s | 9.5 s | |

| Phase (gVisor, p50) | few MB | 1 GiB | 2 GiB |
|---|---|---|---|
| snapshot download | 0.05 s | 2.31 s | 4.96 s |
| sandbox restore | 0.12 s | 1.03 s | 1.77 s |
| sandbox checkpoint | 0.12 s | 0.85 s | 5.90 s |
| snapshot upload | 0.33 s | 2.44 s | 3.93 s |

- **Budget ~3.5 s of wake per GiB**, and a heavy tail past 1 GiB: at 2 GiB one wake in twenty
  took 15 s. A real coding agent sits at 0.5–2 GiB, so plan in seconds, not milliseconds.
- Transfer to and from object storage is about two thirds of wake time at 1 GiB.
- **Pause** avoids the transfer: 3.5× faster wake at 1 GiB. Use it for short idle gaps;
  suspend for long ones (it frees the node).
- `--mem-read all` makes the actor touch all of its memory after every wake, so this is the
  worst case for lazy page loading.

## B3 — durable directories

An 8 MiB file in a durable directory (a volume Substrate persists with the actor), read back and
verified by SHA-256 after every resume. All three runs: 0 failures.

| Run | What's snapshotted | Resume p50 / p95 | Suspend p50 / p95 | First read after resume p50 / p95 | Warm read p50 |
|---|---|---|---|---|---|
| `durdir_data_baseline` | durable dir only, explicit resume | 250 / 290 ms | 610 / 720 ms | 83 / 100 ms | 59 ms |
| `durdir_implicit_resume` | same, **woken by the request itself** | — | 620 / 720 ms | **330 / 370 ms** (wake + read) | 58 ms |
| `durdir_full_baseline` | durable dir **and** memory | 370 / 540 ms | 1,400 / 1,800 ms | 67 / 110 ms | 54 ms |

- **Letting the router wake the actor costs nothing extra**: 330 ms for wake-plus-read equals an
  explicit resume (250) plus a read (83). Agents can simply be addressed; no wake RPC needed.
- The first read after a resume pays ~25 ms of lazy loading over a warm read.
- Snapshotting memory as well as the volume roughly doubles suspend time (upload: 0.46 s → 1.1 s).

## B5 — concurrency and oversubscription

| Run | Users / workers | Requests | Fail | Resume p50 / p95 / p99 | Suspend p50 / p95 | Upload p50 |
|---|---|---|---|---|---|---|
| `glutton_baseline_1_user` | 1 / 1 | 103 | 0 | 220 / 330 / 350 ms | 540 / 640 ms | 0.33 s |
| `glutton_baseline_5_users` | 5 / 5 | 469 | 0 | 230 / 290 / 340 ms | 560 / 1000 ms | 0.36 s |
| `glutton_baseline_10_users` | 10 / 10 | 793 | 0 | 250 / 330 / 370 ms | 820 / 1500 ms | 0.59 s |
| `glutton_oversubscribe_15_users` | **15 / 10** | **2,123** | **0** | 270 / 370 / 450 ms | 1400 / 2200 ms | 1.12 s |

- **Resume barely moves with load**; 1.5× oversubscription produced zero failures.
- **Suspend degrades with concurrency**, and almost all of it is upload: with 15 actors cycling,
  upload p50 goes from 0.33 s to 1.12 s. Two nodes' worth of egress to GCS is the bottleneck,
  not the scheduler.

## B6 — what happens when a worker disappears

Not a planned test: we observed it when a workload redeploy deleted a worker pod that was still
hosting three actors. All three went to **`ACTOR_STATE_CRASHED`** with
`"suspend failed: worker pod went away while hosting the actor"` (or `resume failed: …`).

- Recovery is not automatic. Upstream's CLI documents `kubectl ate revert actor …` to return a
  crashed actor to its last external snapshot; **we did not exercise revert** (our cleanup
  deleted these actors), so "nothing lost up to the last snapshot" is upstream's claim, not a
  measured result.
- Whatever an actor did after its last snapshot is, by construction, not in any snapshot.
- Implication for spot nodes or node upgrades: suspend actors before draining, or plan for
  reverts. Snapshot frequency is your recovery-point objective.

## microVM vs gVisor

Same catalogue entries with `sandboxClass: microvm` (Cloud Hypervisor via Kata, nested
virtualisation on the C3 nodes), 5-minute runs. All 0 failures.

| Memory | Sandbox | Wakes measured | Wake p50 / p95 / p99 | Sleep p50 / p95 | Download / restore (p50) |
|---|---|---|---|---|---|
| 1 GiB | gVisor | 36 | 3.5 / 4.0 / 4.5 s | 3.5 / 4.2 s | 2.31 / 1.03 s |
| 1 GiB | microVM | 23 | 3.5 / 4.1 / **8.4 s** | 3.7 / 4.3 s | 2.55 / 0.84 s |
| 2 GiB | gVisor | 13 | 6.9 / 15 / 15 s | 10 / 18 s | 4.96 / 1.77 s |
| 2 GiB | microVM | 8 | **16 / 17 / 17 s** | 11 / 13 s | 6.47 / **9.54 s** |

- **At 1 GiB the two are the same at the median**; microVM has the heavier tail (p99 8.4 s vs
  4.5 s, and an outlier of 9.4 s in the 1-minute run too).
- **At 2 GiB microVM wakes take more than twice as long**, and the difference is the sandbox
  restore itself (9.5 s vs 1.8 s), not the bucket. Choosing the stronger isolation boundary is
  cheap for small agents and expensive for big ones.
- 8 and 13 wakes are small samples; the 2 GiB medians are solid enough to act on, the p95s less so.
- First run of `install-microvm-deps.sh` needs a `zstd` binary and downloads 924 MB through the
  operator's machine (issue 8 in [upstream-issues.md](upstream-issues.md)).

## Harness notes

- Three runs were invalid: leftover actors from the previous test in the group filled the
  single worker and new actors got `no worker has room for the actor`. They are kept in
  `results/raw/bench-invalid/` with an explanation; `bench/run-locust.py` now cleans up between
  runs, and the reruns are what's reported.
- `server_summary.json` (cluster packing, PSI) is empty: it needs upstream's optional
  Prometheus stack, which we did not install.
- Upstream's runs are 1–2 minutes long. Good for latency percentiles, too short to say
  anything about drift, leaks or long-tail behaviour.
