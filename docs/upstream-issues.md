# Issues worth reporting upstream

Observed against `603e006` (2026-10-16). Not yet filed; each has enough to reproduce.

## 1. Memory snapshots are not encrypted by Substrate (security, docs)

`MEMORY`-fidelity snapshots are written as `ATESPRSE` + version + zstd, with no application-layer
encryption. Any secret in the actor's RAM is readable by anyone with read access to the bucket.
We found an API key 77 times across 12 objects (`tests/06-snapshot-secret-scan.py`).

**Ask:** document this prominently next to `snapshotConfig`, recommend egress credential
injection over env-var secrets, and consider optional per-atespace envelope encryption (CMEK).

## 2. claude-code-multiplex demo can never reach the API (demo)

The demo creates no `EgressPolicy`, and an actor without one has all egress *including DNS*
blocked (`"Actor has no egress policy; blocking all DNS queries"`). Every `claude` call fails with
`EAI_AGAIN`. The demo also bakes `ANTHROPIC_API_KEY` into the ActorTemplate (stored in Postgres,
and in every snapshot — see #1).

**Ask:** create a `tls_passthrough` policy for `api.anthropic.com:443` per agent in the
installer, and switch the key to egress credential injection.

## 3. claude-code-multiplex README describes old placement (docs)

"Two pods for three agents … the third agent stays suspended until a pod opens up." Workers now
report capacity `0/1000` actors with CPU/memory bin-packing, so the third agent is placed beside
the first and nothing waits.

## 4. musl clients can't resolve names through search domains in the sandbox (bug?)

Alpine sandbox (`demos/sandbox`): `wget https://example.com/` → `bad address`; `getent hosts
example.com` → empty; but `nslookup example.com` works and `https://example.com./` (FQDN) works.
`resolv.conf` has `ndots:5` and six search domains pointing at `169.254.17.1`. glibc (Node)
clients are fine. Looks like the actor DNS proxy answers search-domain expansions in a way musl
treats as fatal (e.g. SERVFAIL/REFUSED rather than NXDOMAIN).

## 5. `benchmarking/workloads/deploy.sh` fails on macOS bash 3.2 (bug, one-line fix)

`"${FAKE_ATELET_ENV[@]}"` on an empty array under `set -u` → `unbound variable`. Fix:
`${FAKE_ATELET_ENV[@]+"${FAKE_ATELET_ENV[@]}"}` — see [upstream-patch-bash32.diff](upstream-patch-bash32.diff).

## 6. First install fails on slow links (UX)

Rollout waits are 60 s. Pulling `postgres:18-alpine` and others took ~3 min from India, so the
first `install-ate.sh` / `install-ate-kind.sh` fails and a rerun succeeds.

**Ask:** a `--wait-timeout` on install (the workloads script already has one), or pre-pull.

## 7. No prebuilt-image install path (UX)

Every install builds every image from source on the operator's machine (Go via ko, Envoy
dataplane via Docker, including a Rust dynamic module). On Apple silicon that is amd64 under
emulation: 16 min for a first install and 12 min for the Locust image. Published release images
would make the quickstart minutes, not tens of minutes.

## 8. `install-microvm-deps.sh` needs the `zstd` CLI on the operator machine (docs)

It downloads the 924 MB `kata-static` release to the laptop, then `tar` fails with
`unable to run program "zstd -d -qq"` if `zstd` isn't installed — after the full download.
Not listed in prerequisites. Check for it up front (and consider having the cluster fetch the
assets itself rather than round-tripping ~1 GB through the operator's connection).

## 9. Benchmark automation assumes a second cluster (docs)

`benchmarking/automation` drives runs from a separate orchestration cluster. Running one
catalogue entry against your own cluster is easy (render `runner-job.yaml.tmpl`, see
`bench/run-locust.py` here) but undocumented.
