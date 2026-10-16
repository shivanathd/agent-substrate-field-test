# Use cases — where Agent Substrate fits, and where it doesn't

The shape Substrate is built for: **many agents, each with real state, each idle most of the
time.** If your agents are stateless, or you have ten of them, a plain Deployment (or one VPS)
is simpler and you should stop reading here.

## Good fits

### 1. One persistent coding agent per engineer or per ticket
A Claude Code / Codex sandbox per person that keeps its checkout, installed toolchain, shell
history and running processes for days, but costs nothing while nobody is typing.

- **Tested:** F3 — three Claude Code agents suspended mid-loop and resumed (sometimes on another
  worker) with their process memory intact, still answering.
- **Watch:** a real coding agent holds 0.5–2 GB. See B2 in [benchmarks.md](benchmarks.md) for
  how suspend/resume time grows with memory.

### 2. A dormant agent per customer, user or recruiter
Thousands of agents, each with its own memory and files, woken by a webhook, a Slack message or a
schedule. The density math is the whole point: idle agents cost snapshot storage, not RAM.

- **Tested:** F1/F2 — counter state exact over 20 cycles across 3 workers; resume overhead
  p95 0.34 s for a small actor.
- **Cost:** an idle Claude Code agent's own snapshot delta was ~300 KB on top of an ~18 MB
  per-template base. See [cost.md](cost.md).

### 3. Running untrusted, agent-written code
gVisor (or microVM) isolation per actor, default-deny egress, and an allow-list per actor.

- **Tested:** F5 — uncovered egress refused, allowed egress works, DNS is blocked entirely for an
  actor with no policy.

### 4. Keeping API keys out of the agent
The egress gateway injects credentials into outbound requests, so the agent never holds them.

- **Tested:** F5 — upstream got the real token; the token was nowhere in the actor's env, `/proc`
  or filesystem.
- **This matters more than it looks:** F6 showed that anything an agent *does* hold in RAM is
  written in plaintext to every memory snapshot.

### 5. RL / eval fleets
Thousands of short-lived environments forked from a golden snapshot. Each template already
builds a golden snapshot, and actors start from it.

- **Not tested here.** Upstream's `sweperf` benchmark targets this; see B4.

## Poor fits

| Situation | Why | Use instead |
|---|---|---|
| < ~50 agents, or always-busy agents | No idle time to multiplex; you pay the operational cost for nothing | A Deployment, or one VM |
| You don't run Kubernetes | It is a Kubernetes add-on with its own Postgres, router, gateway and node agent | Hosted sandboxes (E2B, Modal, Daytona) |
| You need it production-ready this quarter | Pre-1.0, weekly releases, APIs explicitly unstable | Watch it; prototype on it |
| Agents must hold long-lived secrets | Memory snapshots will contain them (F6) | Egress injection, or don't snapshot memory |
