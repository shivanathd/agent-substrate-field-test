# Findings

Agent Substrate @ `main` (2026-10-16, after v0.5.0), GKE 1.36.4, 2× c3-standard-4, gVisor.
Every claim below links to a script in `tests/` and a raw log in `results/raw/`.

## Summary

| # | Claim we tested | Result | Evidence |
|---|---|---|---|
| F1 | Actor state survives suspend/resume | **Holds.** 20/20 cycles, memory + file + rootfs counters exact | `tests/01-state-persistence.sh` |
| F2 | An actor can resume on any worker | **Holds.** 20 cycles landed on all 3 workers, state intact | same |
| F1b | Resume is sub-500 ms | **Holds for a small actor.** Resume overhead p50 0.27 s, p95 0.34 s (first request minus warm request) | same |
| F3 | Real coding agents can be suspended mid-life and resumed | **Holds.** 3 Claude Code agents; every agent's in-memory loop counter continued after resume and Claude kept answering | `tests/03-claude-multiplex.sh` |
| F5 | Credentials are injected outside the agent's reach | **Holds.** 8/8 incl. controls | `tests/05-credential-injection.sh` |
| F6 | — (not claimed) Secrets in RAM end up in snapshots | **Yes, in plaintext.** API key found 77× across 12 snapshot objects | `tests/06-snapshot-secret-scan.py` |

## F1 / F2 — state persistence and migration

Upstream counter demo, 20 cycles of: request (wakes actor) → request (warm) → suspend.

| | p50 | p95 | max |
|---|---|---|---|
| First request after suspend (incl. wake) | 0.907 s | 0.990 s | 1.018 s |
| Warm request | 0.642 s | 0.697 s | 0.839 s |
| **Resume overhead** (first − warm) | **0.269 s** | **0.336 s** | 0.345 s |

The absolute numbers include India → us-west1 plus a `kubectl port-forward` tunnel; the
difference is the wake cost. Server-side numbers from the in-cluster benchmark are in
[benchmarks.md](benchmarks.md).

The operator-side "suspend" column (~8.5 s) is **not** a suspend latency: it is dominated by
`kubectl ate` opening a fresh port-forward for every status poll. Don't quote it.

## F3 — Claude Code agents

Three upstream demo agents, each a shell loop calling `claude --print` every 45 s with a TICK
counter held only in process memory. After suspending all three and resuming them:

| Agent | Tick at suspend | Tick after resume | Claude answered after resume |
|---|---|---|---|
| luna | 23 | 26 | yes — resumed on a **different worker pod** |
| mars | 22 | 25 | yes |
| orion | 24 | 28 | yes |

Result 8/8 (`results/raw/03-claude-multiplex-*.log`). Placement is the scheduler's choice: across
the three runs we made, 1, 2 and 0 of 3 agents moved pods, always with ticks intact. Each
suspend or resume, as seen from the CLI, took 3.7–5.1 s end to end for a ~100 MB Claude Code
process tree (this includes CLI tunnel setup from India; see benchmarks for server-side time).

Two things the upstream demo gets wrong today:

1. **It never answers.** Substrate denies all egress, DNS included, for an actor with no
   `EgressPolicy` (`"Actor has no egress policy; blocking all DNS queries"`), and the demo
   creates none. Every `claude` call fails with `EAI_AGAIN`. One `tls_passthrough` rule for
   `api.anthropic.com:443` per agent fixes it. Secure default; stale demo.
2. **"Two pods for three agents" is not how placement works now.** A worker reports capacity of
   `0/1000` actors, `3920m` CPU, `~13.6 GB` memory. With 2 GiB agents ~6 fit per worker, so the
   third agent did not wait for a pod — it was packed beside the first. Density comes from
   bin-packing plus suspension, not one actor per pod.

## F5 — egress credential injection and policy

A random secret in a Kubernetes Secret; actor sends `Authorization: placeholder`.

- PASS upstream received `Bearer <secret>`; never saw the placeholder
- PASS upstream saw the request from the **egress gateway pod IP**
- PASS secret absent from the actor's env, every `/proc/*/environ`, and a full filesystem grep
- PASS HTTPS to a host the policy does not cover is refused
- PASS **control:** the same HTTPS request succeeds once a `tls_passthrough` rule allows it

### DNS quirk found while building the control

Inside the gVisor sandbox (Alpine/musl), names resolved through the search-domain list fail:
`wget https://example.com/` → `bad address`, `getent hosts example.com` → nothing, while
`nslookup example.com` and the fully-qualified `https://example.com./` work. Upstream's resolver
appears to answer search-domain expansions (`example.com.<ns>.svc.cluster.local` …, `ndots:5`)
in a way musl treats as fatal. glibc clients (Node, in the Claude agents) were unaffected.
**Workaround:** trailing-dot FQDNs, or `ndots:1` in the actor's resolv.conf.

## F6 — secrets in memory snapshots

`MEMORY`-fidelity snapshots are the actor's RAM, zstd-compressed (format: `ATESPRSE` magic,
4-byte version, zstd stream) and written to the bucket. **Not encrypted by Substrate**; only
the object store's default at-rest encryption applies.

The demo passes `ANTHROPIC_API_KEY` as an env var (it is also stored in the ActorTemplate, i.e.
in Substrate's Postgres). Scanning 12 snapshot objects found the full key **77 times**: in the
template's golden image (8–52× per object), in each actor's incremental page delta (5×), and in
checkpoint metadata (1×).

**Implication:** read access to the snapshot bucket = read access to every secret any agent
ever held in memory. Mitigations, in order:

1. Don't put secrets in actors. Use egress credential injection (F5) — it works.
2. Treat the snapshot bucket as a secret store: CMEK, no broad `storage.objectViewer`,
   access logging, retention limits.
3. Short-lived tokens only, if an agent must hold one.

## Install and operations

| Finding | Detail |
|---|---|
| Everything is built from source on the operator's machine | Go images via `ko`, Envoy dataplane via Docker incl. a Rust dynamic module. No prebuilt-image path in the quickstart. First install 16 min. |
| Apple silicon is slow and fragile | amd64 images build under emulation. Two concurrent builds (kind + GKE) made `apt-get` inside a build time out; serial builds worked. |
| 60 s readiness timeouts | First install on a slow link fails while images are still pulling; a rerun succeeds. |
| GKE bootstrap is good | `setup-gcp bootstrap` produced cluster + bucket + IAM + dashboards in 6 min, no edits. |
| No managed install of the benchmark harness | Upstream automation assumes a second orchestration cluster; we render its Job template directly (`bench/run-locust.py`). |
