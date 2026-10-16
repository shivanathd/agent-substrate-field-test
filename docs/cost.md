# Cost

Prices are GCP list prices for `us-west1`, pulled from the Cloud Billing Catalog API on
2026-10-16 (pd-balanced and GCS operations from the public price page). Your discounts differ.

| Item | Price |
|---|---|
| C3 vCPU / GiB RAM, on-demand | $0.03465 / h, $0.003938 / h |
| → `c3-standard-4` (4 vCPU, 16 GiB) | **$0.2016 / h** on-demand, $0.0795 / h spot |
| pd-balanced boot disk (100 GB per node) | ~$0.10 / GB-month → $0.0137 / h per node |
| GKE cluster management fee | $0.10 / h (one zonal cluster per billing account is credited) |
| GCS Standard storage | $0.020 / GB-month |
| GCS Class A operations | $0.005 / 1,000 |

## What this field test cost

Test cluster: 2 nodes + disks + fee ≈ **$0.53 / h ≈ $12.73 / day**.

| | Hours | Approx. cost |
|---|---|---|
| Cluster up, install → end of benchmarks | ~4 | ~$2.10 |
| Container registry + snapshot bucket (a few GB, one day) | — | < $0.10 |
| Anthropic API (3 agents × one-sentence prompts × ~1 h) | — | < $1 |
| **Total** | | **~$3** |
| Leaving it running afterwards | per day | $12.73 |

The expensive resource in this test was **time**, not money: ~45–60 min to stand up from
nothing on a laptop, most of it image builds (see [timeline.md](timeline.md)).

## What it would cost to run agents on it

### Inputs we measured

| Input | Value | Source |
|---|---|---|
| Snapshot of an idle Claude Code agent | **~300 KB** own delta + **~18 MB** base shared per template (97 MB raw RAM) | F6 scan, GCS listing |
| Snapshots of deleted actors | removed with the actor — nothing orphaned | GCS listing after benchmarks |
| Worker capacity per `c3-standard-4` | 3.92 vCPU, ~13 GiB allocatable, 1,000-actor cap | `kubectl ate get workers` |
| Wake latency (gVisor, p50) | ~0.2 s small; ~3.5 s at 1 GiB; ~6.9 s at 2 GiB (microVM: 16 s) | [benchmarks.md](benchmarks.md) |

### Model: 1,000 agents, 0.5 vCPU / 1 GiB each when awake

- **Always on** (one pod per agent): bounded by CPU → **128 nodes ≈ $20,200 / month**.
- **Substrate**, agents awake 5% of the time, 2× headroom for bursts: 100 concurrently awake →
  13 nodes + 1 for the control plane → **14 nodes ≈ $2,270 / month**, plus snapshot storage
  (< $4 / month even with no dedupe) and GCS operations (~$30 / month at 20 wakes per agent
  per day).

| Agents awake | Nodes (vs 128 always-on) | Saving |
|---|---|---|
| 5% | 14 | **9.1×** |
| 10% | 27 | 4.7× |
| 25% | 65 | 2.0× |
| 50% | 129 | none |

**The whole case rests on duty cycle.** Below ~25% awake, Substrate is substantially cheaper;
by ~50% it is not. Storage and API costs are rounding errors next to compute.

### Against hosted sandboxes

Same 1,000 agents at 0.5 vCPU / 1 GiB, billed per second while awake. Monthly, list prices
read 2026-10-16 (see Sources in the report). Substrate rows include ~$30/month of GCS.

| Option | 5% awake | 10% | 25% | 50% |
|---|---|---|---|---|
| Substrate, on-demand nodes | $2,303 | $4,347 | $10,319 | $20,378 |
| Substrate, spot nodes (untested) | $1,056 | $1,941 | $4,527 | $8,882 |
| E2B or Daytona (identical rates; not billed while paused) | $1,511 | $3,022 | $7,556 | $15,111 |
| Vercel Sandbox (incl. $0.08/GB-month snapshots) | $3,190 | $6,300 | $15,629 | $31,178 |
| Always-on pods, one per agent | $20,191 | $20,191 | $20,191 | $20,191 |

- **A hosted sandbox that stops billing when paused beats Substrate on on-demand nodes at every
  duty cycle we modelled.** It pays for exactly the awake time, with no 2× headroom and no
  control-plane node. E2B documents pause at ~4 s per GiB and resume at ~1 s (vendor figures).
- **Substrate on spot nodes is the cheapest option**, 30–40% under E2B/Daytona. Spot was not
  tested; a reclaimed node CRASHes its actors until reverted.
- The reasons to self-host are mostly not price: data residency, VPC and egress control, your own
  models and quotas, and no per-vendor limits. Count the operating cost (Postgres, router,
  gateway, node agents, upgrades on a pre-1.0 project) before choosing on price.
- Daytona's disk beyond 5 GiB per sandbox ($0.000108/GiB-hour) and E2B's plan fees are excluded.

### What the model leaves out

- **Wake latency is the price you pay.** A 1 GiB agent takes ~3.5 s to wake. If users wait on it,
  that is a product cost the spreadsheet doesn't show.
- **Operations.** Postgres, router, egress gateway and a node agent are yours to run, upgrade
  and page on. Pre-1.0 means breaking changes.
- **Spot nodes** cut the node price ~60% ($0.0795 vs $0.2016/h) and suit this workload well,
  since actors already live in snapshots — but a reclaimed node CRASHes the actors on it
  (see B6 in [benchmarks.md](benchmarks.md)) and they need a revert. Not tested.
- **Committed-use discounts** would shrink both columns equally.
