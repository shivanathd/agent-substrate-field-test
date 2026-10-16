# Copy to scripts/env.sh and fill in. scripts/env.sh is gitignored.
#
# Everything here is yours: the project is created by scripts/setup.sh if it doesn't exist,
# and deleted by scripts/teardown.sh --delete-project.

export PROJECT_ID=my-substrate-poc            # throwaway project; must be globally unique
export BILLING_ACCOUNT=XXXXXX-XXXXXX-XXXXXX   # gcloud billing accounts list
export ORG_ID=                                # optional: create the project under this org
export BUDGET_USD=50                          # alert at 50/90/100 %

export REGION=us-west1
export ZONE=us-west1-c
export NODE_MACHINE_TYPE=c3-standard-4        # must support nested virtualisation for microVMs
# GKE version must be >= 1.36. Pick a current one with:
#   gcloud container get-server-config --zone $ZONE --format="value(defaultClusterVersion)"
export GKE_VERSION=1.36.4-gke.1391002

# Upstream commit this field test was run against. Change it to test something newer.
export SUBSTRATE_REF=603e006236f576d9435f46757e3fe2e556768ddf
# setup.sh clones and owns this checkout (re-pins, patches, overwrites .ate-dev-env.sh), so it
# must be a fresh path, never a checkout you use for other work. Default: inside this repo.
export SUBSTRATE_DIR=${SUBSTRATE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.upstream/substrate}

# Only for tests/03-claude-multiplex.sh. Use a key with a spend cap, and revoke it after:
# memory snapshots will contain it (see docs/findings.md, F6).
# export ANTHROPIC_API_KEY=
