I froze three Claude Code agents mid-task, moved one to a different machine, and woke them up. None of them noticed.

That's Agent Substrate, Google's new open-source runtime for running agents on Kubernetes. Idle agents get snapshotted to a bucket and thawed onto whatever machine is free. I spent a day testing it on GKE for about $3. What held up:

→ State survived 20 out of 20 freeze/thaw cycles, across machines
→ Wake-up is about 0.2 s for a small agent. For a 1 GB agent it's 3.5 s, and 7 s at 2 GB (16 s with microVM isolation). Memory size is everything.
→ 15 agents on 10 workers: 2,123 requests, zero failures
→ API keys can be injected at the gateway so the agent never holds them. I checked; it doesn't.

What didn't:

→ Memory snapshots aren't encrypted. The official demo's API key was sitting in them 77 times.
→ The Claude Code demo can't reach Claude out of the box (deny-by-default egress, no policy).
→ The install builds everything from source on your laptop. Slow on a Mac.

The economics come down to one number: how much of the time your agents are awake. For 1,000 agents awake 5% of the time it's roughly 9x cheaper than one pod per agent. By 50% the saving is gone.

The surprise: hosted sandboxes that don't bill while paused (E2B, Daytona) came in cheaper than self-hosting on on-demand nodes at every duty cycle I modelled. Self-hosting only wins on spot nodes. Run it for control, not price.

Setup, tests, raw data and teardown are open source: [repo link]

#AIagents #Kubernetes #ClaudeCode #OpenSource
