# I put Claude Code agents to sleep on Google's Agent Substrate. Here's what woke up.

Agent Substrate is Google's new open-source runtime for running agents on Kubernetes. The pitch:
most agents sit idle most of the time, so instead of one pod per agent, freeze each one to object
storage when it goes quiet and thaw it onto any free machine when work arrives. Millions of
sandboxes, sub-500 ms resume, secure by default.

I wanted to know which of those claims survive contact with a real cluster and a real coding
agent. So I stood it up from nothing on GKE, ran three Claude Code agents on it, attacked its
security story, and benchmarked it with its own harness. Total spend: about $3. Total time: one
working day, a lot of it waiting for Docker.

Everything is reproducible: https://github.com/shivanathd/agent-substrate-field-test. Here's what I found.

## The core trick works

I froze and thawed a stateful actor 20 times. Every time it came back with its memory, its files
and its root filesystem exactly as it left them, sometimes on a different machine.

Then the real test. Three Claude Code agents, each a loop that asks Claude a question every 45
seconds and keeps a counter only in process memory. I suspended all three mid-loop and resumed
them. Each counter picked up at N+1, one agent landed on a different node, and all three kept
getting answers from Claude. A live Node.js process tree, frozen to a bucket and thawed somewhere
else, with no idea anything happened.

That's genuinely impressive, and it's the thing that makes the economics work.

## "Sub-500 ms resume" is true. For small agents.

In-cluster, with upstream's own Locust harness:

| Agent memory | Wake p50 (p95) | Sleep p50 |
|---|---|---|
| a few MB | 0.22 s (0.33 s) | 0.54 s |
| 1 GiB | 3.5 s (4.0 s) | 3.5 s |
| 2 GiB | 6.9 s (15 s) | 10 s |

A real coding agent holds 0.5 to 2 GB. Budget about three and a half seconds of wake-up per
gigabyte, expect a long tail past 1 GB, and know that most of it is copying the snapshot to and
from object storage.

Substrate also offers microVMs, a stronger isolation boundary than gVisor. At 1 GB they woke
just as fast. At 2 GB they took 16 seconds against gVisor's 7, and the extra time was the
microVM restore itself.

Two things soften this. Resume time barely moved under load: 15 agents cycling on 10 workers, 2,123
requests, zero failures. And there's a "pause" mode that keeps the snapshot on the node's local
disk. It woke a 1 GiB agent in 0.9 s instead of 3.5 s.

## The security story is half right

The good half: Substrate can inject API keys at its egress gateway. I put a random secret in a
Kubernetes Secret, had the agent call out with a placeholder, and the upstream server received
the real key. Then I searched the agent's environment, every process's `/proc` environ and its
whole filesystem. Not there. Egress is deny-by-default, DNS included, and the allow-list works.

The other half: **memory snapshots are not encrypted.** They're zstd-compressed RAM in a bucket.
The upstream Claude Code demo passes the API key as an environment variable, so I scanned its
snapshots. The full key was in there 77 times.

So read access to the snapshot bucket is read access to every secret any agent ever held in
memory. The fix exists and works (inject credentials, don't hand them to the agent), but nothing
stops you from doing it the easy way, and the official demo does it the easy way.

## The rough edges

- The Claude Code demo can't actually reach Claude. Substrate blocks all egress for an actor with
  no policy, and the demo doesn't create one. Secure default, stale demo. One rule fixes it.
- Everything builds from source on your laptop, including a Rust module. On an M-series Mac
  that's amd64 under emulation: 16 minutes for the first install, three attempts to get it
  through.
- When a worker pod dies, its agents go to CRASHED and wait for a manual revert. Plan around
  that if you want spot nodes.
- Alpine-based agents couldn't resolve ordinary names like `example.com` inside the sandbox.
  The fully-qualified form (`example.com.`, trailing dot) works. Node-based agents were fine.

I've written all of these up with reproduction steps for the maintainers.

## Is it worth it?

It comes down to one number: how much of the time your agents are actually awake.

For 1,000 agents at half a vCPU and 1 GB each, always-on pods need about 128 nodes, roughly
$20k a month on-demand. If agents are awake 5% of the time, Substrate needs about 14 nodes,
roughly $2.3k. At 25% awake the saving is 2x. At 50% it's gone. Snapshot storage is a rounding
error either way.

Then I priced the hosted alternatives, and this part surprised me. E2B and Daytona bill per
second only while a sandbox runs; a paused one costs nothing. For the same 1,000 agents at 5%
awake that's about $1.5k a month, cheaper than Substrate on on-demand nodes at every duty cycle
I modelled, because you pay for exactly the awake time with no headroom and no control plane.
Substrate only comes out cheapest on spot nodes (about $1.1k), which I didn't test. So the
reason to run it yourself is control, not price: your VPC, your egress rules, your data staying
put.

My take:

- **A handful of agents, or busy ones?** Don't bother. A Deployment is simpler.
- **Hundreds of stateful, mostly-idle agents, one per user or customer?** This is the most
  credible open-source answer I've seen, and the snapshot/restore core is solid today.
- **Production this quarter?** Not yet. It's pre-1.0 and ships weekly. Prototype on it, and
  adopt the credential-injection pattern now whatever runtime you use.

The repo has the setup script, every test, the raw benchmark data and a verified teardown.
If you run it on different hardware, I'd like to see your numbers.

https://github.com/shivanathd/agent-substrate-field-test
