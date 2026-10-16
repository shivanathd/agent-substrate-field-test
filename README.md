# Agent Substrate — a field test

An independent, reproducible test of [agent-substrate/substrate](https://github.com/agent-substrate/substrate),
the open-source Kubernetes runtime for running large numbers of suspendable agent sandboxes.

We stood it up from zero on GKE, ran real Claude Code agents on it, checked its security claims,
benchmarked it with its own harness, and wrote down what it cost and how long everything took —
including the parts that broke.

**Tested:** upstream `main` @ [`603e006`](https://github.com/agent-substrate/substrate/commit/603e006236f576d9435f46757e3fe2e556768ddf)
(2026-10-16, two days after v0.5.0) · GKE 1.36.4 · 2× `c3-standard-4` · gVisor · `us-west1`.

## Results at a glance

| Agent memory | Wake p50 / p95 (gVisor) | Wake p50 (microVM) | Sleep p50 |
|---|---|---|---|
| a few MB | 0.22 / 0.33 s | — | 0.54 s |
| 1 GiB | 3.5 / 4.0 s | 3.5 s | 3.5 s |
| 2 GiB | 6.9 / 15 s | 16 s | 10 s |

In-cluster, upstream's own Locust harness; 15 agents on 10 workers ran 2,123 requests with zero
failures. Full tables and phase breakdown in [benchmarks.md](docs/benchmarks.md); a visual
report is in [report/index.html](report/index.html).

| Question | Answer | Evidence |
|---|---|---|
| Does state survive suspend/resume? | **Yes.** 20/20 cycles exact (RAM, files, rootfs), across 3 workers | [F1](docs/findings.md#f1--f2--state-persistence-and-migration) |
| Can a real coding agent be frozen and thawed? | **Yes.** 3 Claude Code agents resumed mid-loop, sometimes on another node, and kept working | [F3](docs/findings.md#f3--claude-code-agents) |
| Can agents use API keys without holding them? | **Yes.** Egress gateway injects them; the key was nowhere in the sandbox | [F5](docs/findings.md#f5--egress-credential-injection-and-policy) |
| Is anything the agent *does* hold safe at rest? | **No.** Memory snapshots are unencrypted; we found the API key in them 77 times | [F6](docs/findings.md#f6--secrets-in-memory-snapshots) |
| Is "sub-500 ms resume" true? | **For small agents.** 1 GiB takes ~3.5 s, 2 GiB ~7 s (16 s on microVM) | [benchmarks](docs/benchmarks.md#b2--memory-size-is-the-dominant-factor) |
| What does the test cost? | **~$3** for the day; $12.73/day if left running | [cost.md](docs/cost.md) |
| Is it cheaper than one pod per agent? | **~9× at 5% awake, 2× at 25%, no saving at 50%** (1,000 agents) | [cost.md](docs/cost.md#model-1000-agents-05-vcpu--1-gib-each-when-awake) |
| Is it cheaper than a hosted sandbox? | **Not on on-demand nodes.** E2B/Daytona (not billed while paused) cost less at every duty cycle; Substrate wins only on spot nodes | [cost.md](docs/cost.md#against-hosted-sandboxes) |
| How long to stand up? | ~45–60 min from nothing on an arm64 Mac, of which ~30 is image builds | [timeline](docs/timeline.md) |

## Diagrams

### What we ran

Drawn with [Archify](https://github.com/tt-a1i/archify) from [`report/diagrams/cluster.architecture.json`](report/diagrams/cluster.architecture.json).

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="report/diagrams/arch-dark.svg">
  <img alt="Agent Substrate on GKE: client and kubectl reach the router and API server; worker pods hold sandboxed actors; atelet checkpoints them to a GCS bucket; all egress goes through atenet-egress, which injects keys from the credential provider" src="report/diagrams/arch-light.svg">
</picture>

The same system as Mermaid, for editing:

```mermaid
flowchart LR
  subgraph gke["GKE cluster · us-west1-c · 2 × c3-standard-4"]
    api["ate-api-server<br/>gRPC control plane"]
    pg[("PostgreSQL<br/>actors, templates, policies")]
    router["atenet-router<br/>Envoy ingress, wakes actors"]
    subgraph sandbox["sandboxed actors"]
      workers["Worker pods<br/>many actors per pod<br/>gVisor or microVM"]
    end
    atelet["atelet<br/>node agent"]
    egress["atenet-egress<br/>mTLS, policy, key injection"]
    cred["Credential provider<br/>reads k8s Secrets"]
  end
  cli["kubectl ate<br/>operator laptop"]
  client["Client or Locust"]
  gcs[("GCS snapshot bucket<br/>zstd RAM + disk, unencrypted")]
  ext["External APIs<br/>e.g. api.anthropic.com"]

  cli -->|gRPC| api
  api -->|actor state| pg
  client -->|"HTTP + ate-target-actor"| router
  router -->|resolve, resume| api
  router -->|route request| workers
  atelet -->|checkpoint, restore| workers
  atelet -->|upload, download| gcs
  workers -->|"all egress, mTLS"| egress
  egress -->|fetch key| cred
  egress -->|allow-list only| ext
```

### How a sleeping agent wakes up

Upstream's resume flow ([`docs/architecture.md`](https://github.com/agent-substrate/substrate/blob/603e006236f576d9435f46757e3fe2e556768ddf/docs/architecture.md)),
annotated with the server-side phase times we measured for a small agent (gVisor, median).

```mermaid
sequenceDiagram
  actor Client
  participant Router as atenet-router
  participant API as ate-api-server
  participant Atelet as atelet
  participant Store as GCS bucket
  participant Worker as worker pod (gVisor)

  Client->>Router: HTTP request (ate-target-actor)
  Router->>API: ResumeActor
  API->>Atelet: Restore
  Atelet->>Store: fetch manifest (31 ms)
  Store-->>Atelet: download snapshot (47 ms)
  Atelet->>Worker: restore sandbox (122 ms)
  Worker-->>Atelet: ready
  Atelet-->>API: worker pod IP
  API-->>Router: worker assignment
  Router->>Worker: forward request (mTLS tunnel)
  Worker-->>Client: response, state intact
  Note over Client,Worker: wake p50: 0.22 s small · 3.5 s at 1 GiB · 6.9 s at 2 GiB (16 s on microVM)
```

### Actor states

Upstream's state machine plus the crash path, which we hit when a worker pod was deleted under
three running actors.

```mermaid
stateDiagram-v2
  [*] --> SUSPENDED : CreateActor
  SUSPENDED --> RESUMING : ResumeActor or inbound request
  RESUMING --> RUNNING : restore complete
  RUNNING --> SUSPENDING : SuspendActor (upload to bucket)
  RUNNING --> SUSPENDING : PauseActor (node-local snapshot)
  SUSPENDING --> SUSPENDED : checkpoint complete
  RUNNING --> CRASHED : worker pod went away
  SUSPENDING --> CRASHED : worker pod went away
  CRASHED --> REVERTING : kubectl ate revert
  REVERTING --> SUSPENDED : back to last snapshot
  SUSPENDED --> [*] : DeleteActor
```

### How the field test ran

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="report/diagrams/flow-dark.svg">
  <img alt="Field test workflow across laptop, GCP project and GKE cluster lanes, with a lane of failures and their fixes" src="report/diagrams/flow-light.svg">
</picture>

The real day, from the timestamps in [`docs/timeline.md`](docs/timeline.md) (IST):

```mermaid
gantt
  title Field test, 16 Oct 2026 (IST)
  dateFormat HH:mm
  axisFormat %H:%M
  section Provision
    Login, project, budget          :done, 11:22, 15m
    setup-gcp bootstrap (GKE)       :done, 11:37, 6m
  section Install
    Install attempt 1 (failed)      :crit, 11:45, 15m
    Install attempt 2 (failed)      :crit, 12:03, 2m
    Install attempt 3               :done, 12:06, 16m
  section Test
    F1 state persistence            :done, 12:26, 5m
    Demos deploy                    :done, 12:31, 9m
    F5 credential injection         :done, 12:35, 11m
    F3 Claude Code agents           :done, 12:46, 22m
    F6 snapshot secret scan         :done, 13:08, 6m
  section Benchmark
    Locust image build              :done, 13:13, 13m
    gVisor suite                    :done, 13:32, 45m
    microVM assets (3 tries)        :crit, 14:16, 31m
    microVM 1-min runs              :done, 14:45, 13m
    5-minute memory runs            :done, 15:00, 37m
```

### Should you run it?

```mermaid
flowchart TD
  q1{"Hundreds of agents with<br/>state they must keep?"}
  q2{"Awake less than<br/>~25% of the time?"}
  q3{"Need your own VPC, egress<br/>control or data residency?"}
  q4{"Already run Kubernetes<br/>and can run spot nodes?"}
  no1["A Deployment or one VM"]
  hosted["Hosted sandbox that stops<br/>billing when paused"]
  sub["Agent Substrate<br/>(prototype: pre-1.0)"]

  q1 -->|no| no1
  q1 -->|yes| q2
  q2 -->|no| no1
  q2 -->|yes| q3
  q3 -->|no| hosted
  q3 -->|yes| q4
  q4 -->|no| hosted
  q4 -->|yes| sub
```

## Charts

From the in-cluster benchmarks; all numbers are in [`results/benchmarks.csv`](results/benchmarks.csv).

**Wake and sleep time by agent memory** (blue gVisor, orange microVM; dot median, whisker p95)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="report/charts/wake-sleep-by-memory-wake-dark.svg">
  <img width="420" alt="Wake time by memory: 0.22 s for a small agent, 3.5 s at 1 GiB on both sandboxes, 6.9 s on gVisor and 16 s on microVM at 2 GiB" src="report/charts/wake-sleep-by-memory-wake-light.svg">
</picture>
<picture>
  <source media="(prefers-color-scheme: dark)" srcset="report/charts/wake-sleep-by-memory-sleep-dark.svg">
  <img width="420" alt="Sleep time by memory: 0.54 s small, 3.5 s at 1 GiB, about 10 s at 2 GiB" src="report/charts/wake-sleep-by-memory-sleep-light.svg">
</picture>

**Where the time goes** (green: transfer to or from the bucket; purple: sandbox checkpoint or restore)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="report/charts/phase-breakdown-dark.svg">
  <img alt="Phase breakdown: bucket transfer is about two thirds of wake and sleep time at 1 GiB" src="report/charts/phase-breakdown-light.svg">
</picture>

**1,000 agents a month** (blue Substrate on-demand, orange Substrate spot, green E2B or Daytona,
yellow Vercel Sandbox, dashed red one always-on pod per agent)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="report/charts/cost-1000-agents-dark.svg">
  <img alt="Monthly cost by share of time awake: E2B/Daytona below Substrate on-demand at every point; Substrate on spot nodes lowest; always-on pods flat at about $20k" src="report/charts/cost-1000-agents-light.svg">
</picture>

The full interactive report (tabs, tooltips, tables) is `report/index.html`; open it locally,
since GitHub shows HTML as source.

## Reproduce it

You need: a GCP billing account, `gcloud`, `kubectl`, `go` ≥ 1.25, `docker`, `python3` with
`pyyaml` and `zstandard`, and `zstd` if you want the microVM runs. Budget about **$0.53/hour**
while the cluster is up. Running setup from a cloud VM in the same region instead of a laptop
avoids most of the build and download time.

```bash
cp scripts/env.example.sh scripts/env.sh   # set PROJECT_ID, BILLING_ACCOUNT
scripts/setup.sh                           # ~45-60 min: project, GKE, substrate, demos, bench harness

export CONTEXT=$(kubectl config current-context)
kubectl --context $CONTEXT -n ate-system port-forward svc/atenet-router 8000:80 &

tests/01-state-persistence.sh              # F1/F2  ~5 min
tests/05-credential-injection.sh           # F5     ~2 min
tests/03-claude-multiplex.sh               # F3     ~6 min, needs the Claude demo + an API key
SCAN_SECRET=$ANTHROPIC_API_KEY tests/06-snapshot-secret-scan.py gs://<bucket>/claude-multiplex-demo/

SUBSTRATE=.upstream/substrate CONTEXT=$CONTEXT BUCKET=<bucket> \
  IMAGE=gcr.io/<project>/ate-images/locust-test:latest bench/run-all.sh   # ~1-1.5 h
bench/summarize.py                         # -> results/benchmarks.{csv,md}
python3 report/build_report.py             # -> report/index.html
scripts/sanitize.py --replace <your-project>=<PROJECT_ID>   # strip your identifiers from logs
scripts/verify.sh --forbid <your-project>  # tests, data lineage, links, identifiers: all must pass

scripts/teardown.sh --delete-project       # removes everything; verifies nothing billable remains
```

## Layout

| Path | What |
|---|---|
| [docs/methodology.md](docs/methodology.md) | The question, the tests, pass bars (written before any test ran) |
| [docs/findings.md](docs/findings.md) | What held, what didn't, with evidence |
| [docs/benchmarks.md](docs/benchmarks.md) | Latency, phase breakdown, memory scaling, oversubscription |
| [docs/cost.md](docs/cost.md) | What the test cost, and a cost model for idle agents |
| [docs/use-cases.md](docs/use-cases.md) | Where it fits and where it doesn't |
| [docs/timeline.md](docs/timeline.md) | Every step with wall-clock time, including failures |
| [docs/upstream-issues.md](docs/upstream-issues.md) | Bugs and doc gaps worth reporting upstream |
| [docs/code-review.md](docs/code-review.md) | Independent review of this repo's own scripts, and what was fixed |
| `scripts/` | Setup, verified teardown, `sanitize.py` (strip identifiers), `verify.sh` (publish gate) |
| `report/` | `build_report.py` turns `results/benchmarks.csv` into the visual report |
| `tests/` | Functional tests (bash + python, run from a laptop) |
| `bench/` | Thin wrappers that run upstream's own Locust benchmarks in-cluster |
| `results/` | Raw logs and CSVs from our runs; `benchmarks.csv` is the summary |

## What this is not

- Not a scale test. Two nodes. Upstream's "millions of sandboxes" is their claim, not ours.
- Not a production review: no HA, no upgrades, no multi-day soak, dev-mode auth.
- Not affiliated with the Substrate project or Google.

## License

MIT for everything in this repo ([LICENSE](LICENSE)). Upstream Substrate is Apache-2.0; we
vendor none of it — `scripts/setup.sh` clones it. `docs/upstream-patch-bash32.diff` is a
two-line patch against upstream, offered under upstream's license.
