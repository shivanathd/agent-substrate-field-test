---
name: verify
description: Runtime-verify changes to this repo's scripts against a live Substrate cluster
---

# Verifying this repo

Two layers. Run both.

## 1. Static and lineage (no cluster)

    scripts/verify.sh --forbid <company> --forbid <email-local-part> --forbid <project-number> ...

Pass each `--forbid` as a literal argument (zsh does not word-split `$VAR`). It rebuilds
results/benchmarks.*, docs/cost.md, report/ in place, diffs against the committed copies,
checks links, and scans for identity leaks. The output is written to `results/verify-last.txt`.

## 2. Runtime (needs the cluster from scripts/setup.sh)

    kubectl config use-context <ctx>          # kubectl-ate rejects --context before the plugin name
    kubectl port-forward -n ate-system svc/atenet-router 8000:80 &   # tests 01/03 talk to the router
    cd /tmp && CONTEXT=<ctx> ~/substrate-field-test/tests/01-state-persistence.sh

Run tests from outside the repo to prove the `cd "$(dirname "$0")/.."` handling works.

| Flow | Pass looks like | Then check |
|---|---|---|
| tests/01 | `20/20` | `kubectl ate get actor -A` has no leftover test actor (also after SIGTERM and Ctrl-C in tmux) |
| tests/03 (needs `ANTHROPIC_API_KEY`) | `result: 8 passed, 0 failed`, ~5 min | luna/mars/orion all `ACTOR_STATE_SUSPENDED` afterwards |
| tests/05 | 8/8 | namespace-policy ConfigMap identical before and after; key never in the log |
| scripts/teardown.sh --verify | exit 2, "unknown option" | nothing deleted |
| scripts/teardown.sh --verify-only | lists resources, exit 1 while the cluster lives | |
| setup.sh / teardown.sh on an unlabeled project | refuses | |
| bench/run-all.sh bogus | exit 2, no new results/raw/bench-run-all-*.log | |

## Gotchas

- Ctrl-C probe: SIGINT to a background job is ignored by bash. Use SIGTERM, or a real Ctrl-C
  in `tmux -L verify new -d -e PATH=$PATH`.
- Mermaid blocks in README.md: render them (mermaid 11.4.1 in a browser) before claiming they parse.
- Never print the Anthropic key; tests/06 counts it without echoing.
