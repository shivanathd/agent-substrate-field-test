# Invalid runs — kept for transparency

These ran after earlier tests in the same group had left their last actor running (upstream
Locust tests do not clean up). Leftover actors held the single worker's CPU, so new actors got
`ResourceExhausted: no worker has room for the actor` (durdir_full_baseline: 59 failures,
durdir_implicit_resume: 9, durdir_data_baseline: 1). `bench/run-locust.py` now deletes leftover
actors before each run; the clean reruns are in `../bench/`.
