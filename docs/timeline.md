# Timeline — what actually happened

Wall-clock log of the field test, kept as it happened. Times are IST (UTC+5:30), 2026-10-16.
Identifiers are replaced with placeholders: `<PROJECT_ID>`, `<BILLING_ACCOUNT>`, `<ORG_ID>`.

Operator machine: Apple-silicon MacBook (arm64), Docker Desktop with 8 GB / 18 CPUs, on a home
connection in India. Cluster region: `us-west1-c`.

| Time | Step | Result | Elapsed |
|---|---|---|---|
| 11:22 | Prereq check: gcloud 588, kubectl 1.34, Go 1.27, Docker 29.7 | gcloud user token expired; ADC fine | — |
| 11:30 | `gcloud auth login` | OK | ~1 min |
| 11:31 | Org-policy check (nested virt, resource locations) | No blockers | ~1 min |
| 11:33 | Create throwaway project, link billing, $50 budget alert | OK | ~2 min |
| 11:37 | `go run ./tools/setup-gcp bootstrap` (APIs, GKE 1.36.4, 2× c3-standard-4, GCS bucket, IAM, dashboards) | OK | **6 min** |
| 11:36 | Local: `hack/create-kind-cluster.sh` + `install-ate-kind.sh` (parallel with GKE) | FAIL — postgres rollout 60 s timeout while the image was still pulling | 19 min |
| 11:45 | GKE: `hack/install-ate.sh --deploy-ate-system --deploy-demo-counter` (attempt 1) | FAIL — `apt-get update` inside envoy-dataplane image build could not reach deb.debian.org | 15 min |
| 12:00 | Local retry | FAIL — `k8s-credential-provider` rollout timeout (images still pulling) | 11 min |
| 12:03 | GKE attempt 2 | FAIL — same apt error | 2 min |
| 12:05 | Isolated repro of the apt step via `docker buildx` | Passes in 24 s → failure correlated with concurrent local build saturating Docker | — |
| 12:06 | GKE attempt 3 (apt layer now cached) | **OK** | 16 min |
| 12:13 | Local retry 3 | FAIL — kind API server TLS handshake timeout (Docker Desktop saturated) | 3 min |
| 12:17 | Paused kind node to give the GKE build the whole Docker VM | — | — |
| 12:24 | `go install ./cmd/kubectl-ate`, router port-forward, smoke test | counter answers; 3 counters increment | 2 min |
| 12:26 | **F1/F2** `tests/01-state-persistence.sh` (20 cycles) | PASS 20/20, 3 workers | 5 min |
| 12:31 | Deploy sandbox + claude-code-multiplex demos | OK | 9 min |
| 12:35 | **F5** credential injection, first version | 7/7 — but two checks too weak | 2 min |
| 12:38 | Add controls; control fails → diagnose → musl/search-domain DNS quirk; use FQDN | PASS 8/8 | 8 min |
| 12:46 | **F3** Claude multiplex, first version | 3/5 — demo has no egress policy (DNS blocked), and a worker holds many actors | 6 min |
| 12:55 | F3 rewritten: per-agent `api.anthropic.com` policy; strict answer check; bash 3.2 fix | PASS (final run 8/8) | 25 min |
| 13:08 | **F6** snapshot secret scan | API key found 77× in 12 snapshot objects | 6 min |
| 13:13 | Locust image build (Go under emulation) + workload deploy | image 12 min; deploy failed on macOS bash 3.2 bug | 13 min |
| 13:20 | Scaled demo worker pools to 0 for clean benchmark nodes | node CPU requests 88% → 69% | 1 min |
| 13:26 | Patched `deploy.sh` locally; workloads deployed | OK | 2 min |
| 13:28 | First in-cluster benchmark (pipeline check) | Resume p50 220 ms, Suspend p50 540 ms, 0 failures | 3 min |
| 13:32 | `bench/run-all.sh` gVisor suite (5 groups, 11 catalogue runs) | OK, 0 failures except 3 durdir runs | 45 min |
| 13:50 | Diagnose durdir failures: leftover actors from earlier tests filled the 1-worker pool (harness bug, ours) | `run-locust.py` now cleans between runs | 5 min |
| 14:16 | `install-microvm-deps.sh` | FAIL after a 924 MB download — needs `zstd` CLI (undocumented) | 4 min |
| 14:20 | Clean rerun of the 3 durdir runs | 0 failures | 11 min |
| 14:33 | microVM deps with a `zstd -d` shim | FAIL — shim picked up a python3 without `zstandard`; 924 MB downloaded again | 4 min |
| 14:40 | microVM deps, shim pinned to the right interpreter (third 924 MB download) | OK | 7 min |
| 14:45 | microVM 1 GiB and 2 GiB (upstream 1-min entries) | OK; 2 GiB fit one wake | 13 min |
| 15:00 | Same memory entries for 5 min, gVisor and microVM | OK, 0 failures; 2 GiB microVM 16 s vs gVisor 6.9 s | 37 min |
| 15:40 | Docs, report, sanitise, verify | — | — |

**Totals:** first command 11:22 → last benchmark 15:37, about **4 h 15 min** of wall-clock. Of
that, roughly 1 h 30 min was image builds and asset downloads through the laptop, ~1 h was
benchmark runtime, and the rest was tests, diagnosis and fixes.

## Lessons so far

1. **The installer builds every image from source on the operator's machine** (Go via ko, plus
   Docker builds for the Envoy dataplane, including a Rust dynamic module). There is no
   prebuilt-image install path in the dev quickstart.
2. **On Apple silicon, those builds run amd64 under emulation.** The Rust compile is the long pole.
3. **Readiness timeouts are 60 s.** On a slow link the first install fails while images are
   still pulling; a rerun succeeds. Not a bug in Substrate, but every first-time user will hit it.
4. **Don't build for two clusters at once on one laptop.** Docker Desktop at 8 GB could not serve
   a kind cluster and an emulated Rust build at the same time.
5. **Every heavy step goes through the operator's laptop**: images are built there and pushed,
   and the microVM assets (924 MB) are downloaded there and re-uploaded to the bucket. On a home
   connection that is most of the wall-clock time. Run setup from a cloud VM in the same region
   and most of these minutes disappear.
6. **The local kind path never completed** on this Mac. It was paused at 12:17 to free resources
   for GKE and we did not return to it; the field test is GKE-only.
