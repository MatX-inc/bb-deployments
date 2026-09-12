# Token pool scenario harness

`bare/token_scenario.sh` exercises a bb_scheduler feature, license token
pools, against the bare (container-less) deployment on one Linux host. Token
pools are configured as `token_pools: [{instance_name_prefix, name, capacity}]`
plus `token_pool_startup_grace_period`; actions declare requirements as REv2
platform properties `token:<name>=<n>` (Bazel `exec_properties`), which the
scheduler strips before platform matching and enforces at dequeue. The
harness works with a stock scheduler too, in which case it documents the
failure mode the feature removes.

## Pieces

- `bare/config/scheduler_harness.jsonnet` extends `scheduler.jsonnet`; every
  knob is an environment variable (bb binaries expose the environment through
  `std.extVar`). `bare/config/token_pools.libsonnet` holds the token fields
  and returns `{}` unless enabled, because an unpatched scheduler rejects them
  as unknown fields at startup. `bare/config/scheduler.jsonnet` itself is
  unchanged and `bazel run //bare:bare` behaves as before.
- `bare/config/worker_harness.jsonnet` and `runner_harness.jsonnet` extend
  `worker.jsonnet`/`runner.jsonnet` for a second worker/runner pair (scenario
  i): diagnostics port, `pool=<x>` platform property, runner concurrency and
  worker hostname come from the environment; every path in the base configs
  is relative, so the pair runs from its own working directory `$WORK_DIR/x`.
- `synthetic/` is a dependency-free client workspace: ten `sleep 20` genrules
  carrying `exec_properties = {"token:synthetic": "1"}` (`//:tokened`), four
  untokened `sleep 5` controls (`//:controls`), `//:bogus` requiring a pool
  no scheduler configures, `//:oversized` requiring more than the capacity,
  and the scenario i quartet `//:i_a`, `//:i_b` (tokened, `pool=x`),
  `//:i_e` (token-free, `pool=x`, `sleep 40`), `//:i_f` (tokened, default
  platform). Every command embeds `$(RUN_ID)`; the script passes a fresh
  `--define=RUN_ID=...` per build so nothing is an action cache hit. Its
  `.bazelrc` targets `grpc://localhost:8980`, instance `local`,
  `--spawn_strategy=remote`.
- `bare/token_scenario.sh` builds `//bare:bare` with the scheduler under test
  swapped in via `--override_module=com_github_buildbarn_bb_remote_execution`,
  launches the six processes itself (the `bare` launcher stops all of them
  when any one exits, so it cannot restart only the scheduler), samples
  `:9982/metrics` once a second, runs the scenarios and prints a PASS/FAIL
  table. Logs and samples land in `$RUN_DIR`; the monitoring-surface
  scenarios g-j save what they fetched (admin pages, BuildQueueState JSON,
  metric series, operation timelines) under `$RUN_DIR/proof/`, together with
  the slice of the scheduler log between `### harness start/end scenario`
  markers for every scenario.

## Running

```sh
# Scheduler under test (a bb-remote-execution checkout), tokens on:
BB_RE_DIR=/path/to/bb-remote-execution TOKENS=1 bare/token_scenario.sh

# Build the deployment's binaries on a remote executor instead of this host:
BUILD_STARTUP=--bazelrc=/path/to/rbe.bazelrc BUILD_FLAGS=--config=rbe TOKENS=1 bare/token_scenario.sh

# Reuse the last build, baseline expectations (stock scheduler):
BUILD=0 TOKENS=0 bare/token_scenario.sh

# Reservation window (scenario i): capacity 1 and the second worker pair.
BUILD=0 TOKENS=1 TOKEN_POOL_CAPACITY=1 SCENARIOS=i bare/token_scenario.sh
```

Knobs, all environment variables with defaults in the script:

| Variable | Meaning |
|---|---|
| `BB_RE_DIR` | bb-remote-execution checkout providing bb_scheduler, bb_worker, bb_runner |
| `TOKENS` | `1` configures the pool; `0` runs baseline expectations |
| `TOKEN_POOL_NAME`, `TOKEN_POOL_CAPACITY`, `TOKEN_POOL_STARTUP_GRACE_PERIOD` | pool definition; durations must be in seconds (`5s`) |
| `TOKEN_POOL_INSTANCE_NAME_PREFIX` | default empty: pools are resolved by the platform queue's prefix, which is the worker's `instanceNamePrefix` (empty in `worker.jsonnet`), not by the client's `--remote_instance_name` |
| `PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT` | default `10s`, instead of upstream's `900s`, so an action for a platform without workers fails with FailedPrecondition instead of Unavailable retries |
| `BUILD`, `BUILD_STARTUP`, `BUILD_FLAGS` | skip the build, add startup options (`--bazelrc=`), add build flags (`--config=`) |
| `BAZEL_STARTUP`, `OUTPUT_USER_ROOT` | startup options for the deployment build (default `--output_user_root=/bazel-cache/greg/bbdep --host_jvm_args=-Xmx6g`) |
| `LAUNCH=0`, `EXECUTOR`, `INSTANCE_NAME`, `METRICS_URL`, `ADMIN_URL`, `BQS_ADDRESS` | target a deployment that is already running elsewhere |
| `GRPCURL` | path to grpcurl (default: `$PATH`, then `$HARNESS_ROOT/bin/grpcurl`); scenario e falls back to the admin HTML without it, h and i need it |
| `SCENARIOS` | subset of `ab c d e f gh i j`; default `ab c d e f gh j` |
| `WORKER_X`, `WORKER_X_POOL`, `WORKER_X_CONCURRENCY`, `WORKER_X_DIAG_PORT`, `RUNNER_X_DIAG_PORT` | second worker/runner pair; `WORKER_X=auto` (default) launches it only when scenario i is selected, platform `pool=x`, concurrency 1, ports 9988/9989 |
| `I_FILLER_PRIORITY` | REv2 priority of the token-free filler in scenario i (default `-100`, lower runs first) |
| `WORK_DIR`, `RUN_DIR`, `KEEP=1` | bare working directory, per-run output, leave the deployment up on exit |

The bare processes hold ports 7982, 8980-8984, 9982, 9986, 9987 (plus 9988,
9989 for the second pair); the script refuses to launch while any is in use.
The client runs with `--nosystem_rc --nohome_rc` so this host's BES or cache
settings do not sit between the client and the deployment under test.

Building against a checkout newer than the pinned `bb_remote_execution` needs
the root `go.sum` to know the checkout's dependency versions: gazelle's
`go_deps` resolves versions across all Bazel modules but reads hashes from the
root `go.sum` only. This branch appends the checkout's `go.sum` and drops the
root's go-fuse `replace` and patch override, which the newer checkout no
longer carries.

## Scenarios

| Scenario | Proves | Assertion with `TOKENS=1` | Assertion with `TOKENS=0` (baseline) |
|---|---|---|---|
| a | Capacity is enforced and excess work waits | `//:tokened` succeeds; wall time above 90 s (ten 20 s sleeps in five waves of two); max `in_use` equals capacity 2; max `blocked_tasks` at least 8 | `//:tokened` fails with `No workers exist ... token:synthetic` and no `token_pool` metrics exist |
| b | Token-free work is never blocked | `//:controls`, started concurrently in a separate output base, succeeds in under 30 s and before the tokened build | succeeds in under 30 s |
| c | Unknown tokens fail fast | `//:bogus` fails in under 30 s with FailedPrecondition naming `bogus` | same text, produced by the platform mismatch |
| d | Restart safety | SIGKILL the scheduler once `in_use >= 1`, relaunch it; the tokened build still succeeds and, after the grace period, `1 <= in_use <= capacity` | skipped |
| e | BuildQueueState exposes pools | `ListPlatformQueues.tokenPools` (grpcurl, server reflection) lists `synthetic` with capacity 2 | nothing listed |
| f | Oversized requests fail fast | `//:oversized` (`token:synthetic=3`) fails in under 30 s with FailedPrecondition mentioning the capacity | skipped |
| g | Admin UI shows the pool and its holders | while `//:tokened` saturates the pool: the token pools row on `:7982/` shows the capacity and in-use/reserved/blocked numbers within ±1 of the `:9982` gauges scraped in the same second; the row's in-use link lists only EXECUTING operations requiring the token, the blocked link only operations "blocked on token", each count within ±1 of the row | skipped |
| h | BuildQueueState token filters | same moment, via grpcurl: `ListOperations{filter_token_name,filter_token_instance_name_prefix}` returns only operations requiring the token, with EXECUTING count == `in_use` and `blocked_on_token` count == `blocked_tasks` (±1); `filter_token_blocked_only` returns exactly the parked set; a prefix without a pool returns nothing; a prefix with a reserved keyword (`operations`) is InvalidArgument | skipped |
| i | Reservation window; FIFO not overtaken across platform queues | capacity 1, two platform queues sharing the pool. A (tokened, `pool=x`) runs on worker X; E (token-free, `pool=x`, `sleep 40`, priority `I_FILLER_PRIORITY`) queues behind it; B (tokened, `pool=x`) parks. When A ends, B leaves the FIFO with a reservation and X takes E, so `reserved==1`, `in_use==0` for at least 10 consecutive seconds; F (tokened, default platform) must park while the default worker is idle and may only start after B; no overcommit | skipped; also skipped unless `TOKEN_POOL_CAPACITY=1` and the second worker pair is up |
| j | Metric series are bounded | `:9982/metrics` has exactly one series per gauge for the pool and, for each rejection produced earlier in the same scheduler process (c: `UnknownPool`, f: `ExceedsCapacity`), one `..._rejections_total{instance_name_prefix,reason}` series with that count; the client's token name never appears as a label | skipped |

The metrics sampled are
`buildbarn_builder_in_memory_build_queue_token_pool_{capacity,in_use,reserved,blocked_tasks}{instance_name_prefix,token}`.
Scenarios a, d and i also require `in_use + reserved <= capacity` at every
sample (`reserved` counts tokens promised to unparked tasks not yet running).
Scenario i additionally records a one-second operation timeline
(`proof/i_ops.tsv`: target, stage, `blocked_on_token`, token requirements)
from `ListOperations`, from which the start order of A, E, B and F is read.

## Baseline result (stock scheduler, 2026-09-12)

Scheduler from bb-remote-execution `13313e6` (no token pool code), built on
RBE, `TOKENS=0`:

```
mode=baseline capacity=2 executor=grpc://localhost:8980 instance=local
SCEN STATUS DETAIL
a    PASS   baseline: tokened rc=34 6s; max in_use=0 max blocked=0 (0 samples); unpatched scheduler: No workers exist for instance name prefix "local" platform {"properties":[{"name":"token:synthetic","value":"1"}]}
b    PASS   controls rc=0 in 6s while tokened work took 6s
c    PASS   bogus token rejected in 0s: FAILED_PRECONDITION: No workers exist for instance name prefix "local" platform {"properties":[{"name":"token:bogus","value":"1"}]}
d    SKIP   restart needs token pools on
e    PASS   baseline: no token pool listed via grpcurl
```

The stock scheduler does not hang on a `token:` property: with no platform
queue for `{token:synthetic=1}` it answers `Execute` with FailedPrecondition
immediately once it has been up for `platformQueueWithNoWorkersTimeout`
(Unavailable before that, which Bazel retries). With `TOKENS=1` the stock
scheduler exits at startup:
`Failed to unmarshal configuration: proto: (line 90:4): unknown field
"tokenPoolStartupGracePeriod"`, which is why the fields stay behind the flag.

## Result with token pools (bb-remote-execution `660c1e3`, 2026-09-12)

`TOKENS=1`, capacity 2, grace 5 s (the same table, minus the `reserved`
numbers, was produced by the branch's previous commit `dfa74d8`):

```
SCEN STATUS DETAIL
a    PASS   tokened rc=0 101s; max in_use=2 max blocked=8 max reserved=0; in_use+reserved>capacity in 0 of 99 samples; serialized into waves (>90s)
b    PASS   controls rc=0 in 6s while tokened work took 101s
c    PASS   bogus token rejected in 0s: FAILED_PRECONDITION: No token pool named "bogus" exists for instance name prefix ""
d    PASS   rc=0 110s; scheduler down 1s; during grace in_use=0 blocked=10; max in_use after grace=2; in_use+reserved>capacity in 0 samples
e    PASS   pool synthetic capacity 2 listed via grpcurl
f    PASS   3 tokens against capacity 2 rejected in 1s: FAILED_PRECONDITION: Action requires 3 tokens of pool "synthetic" for instance name prefix "", which exceeds its capacity of 2
```

`in_use`/`blocked_tasks` over scenario a: `2/8` at t+1 s, then `2/6`, `2/4`,
`2/2`, `2/0` at 20 s intervals. After the SIGKILL in scenario d the new
process shows `0/10` for the grace period and then resumes the waves. With
`TOKEN_POOL_CAPACITY=1` the same ten genrules take 201 s with `in_use` never
above 1 and `blocked` counting down from 9.

Pools are looked up by the platform queue's prefix: with the default worker
config (`instanceNamePrefix` unset) a pool declared for prefix `local` is
invisible to actions sent with `--remote_instance_name=local`, and they fail
with `No token pool named "synthetic" exists for instance name prefix ""`.

## Monitoring surfaces against the live scheduler (`660c1e3`, 2026-09-12)

Default set, capacity 2, grace 5 s (run `20260912-043142`):

```
SCEN STATUS DETAIL
a    PASS   tokened rc=0 101s; max in_use=2 max blocked=8 max reserved=0; in_use+reserved>capacity in 0 of 99 samples; serialized into waves (>90s)
b    PASS   controls rc=0 in 6s while tokened work took 101s
c    PASS   bogus token rejected in 0s: FAILED_PRECONDITION: No token pool named "bogus" exists for instance name prefix ""
d    PASS   rc=0 111s; scheduler down 1s; during grace in_use=0 blocked=10; max in_use after grace=2; in_use+reserved>capacity in 0 samples
e    PASS   pool synthetic capacity 2 listed via grpcurl
f    PASS   3 tokens against capacity 2 rejected in 1s: FAILED_PRECONDITION: Action requires 3 tokens of pool "synthetic" for instance name prefix "", which exceeds its capacity of 2
g    PASS   row cap=2 in_use=2 reserved=0 blocked=8 vs gauges in_use=2 reserved=0 blocked=8; in-use page rows=2 with_token=2 executing=2; blocked page rows=8 with_token=8 parked=8
h    PASS   filter_token: 16 ops (16 require synthetic), executing=2 vs in_use=2, blocked_on_token=8 vs blocked=8; blocked_only=8 ops; wrong prefix=0 ops; malformed prefix rc=67 Code: InvalidArgument
j    PASS   5 series: blocked_tasks{...} 0 capacity{...} 2 in_use{...} 0 rejections_total{instance_name_prefix="",reason="ExceedsCapacity"} 1 reserved{...} 0 ; matches expected set (UnknownPool=0 ExceedsCapacity=1)
```

The 16 operations in h are the 10 of the in-flight build plus 6 completed
ones the scheduler still lists; only the EXECUTING and `blocked_on_token`
counts are compared with the gauges. j lists no `UnknownPool` series because
scenario c's rejection was counted by the scheduler process that d killed;
counters restart with the process, and the harness resets its expectation
when it relaunches the scheduler. A run of `c gh j` alone (`20260912-041639`)
shows `rejections_total{instance_name_prefix="",reason="UnknownPool"} 1` and
the same g/h numbers.

Scenario i, capacity 1, second worker pair (`TOKEN_POOL_CAPACITY=1
SCENARIOS=i`), filler priority -100 (run `20260912-041907`):

```
i    PASS   rc A=0 B=0 E=0 F=0; X took E (filler, priority -100) before B; reserved==1 for 40 consecutive s with max in_use=0; F parked at +22s with 8 idle default worker(s); start offsets E=+20s B=+60s F=+81s; overcommits=0
```

Operation timeline (`proof/i_ops.tsv`, offsets from A's start) and gauges
(`proof/i_metrics.txt`):

```
+0s   A EXECUTING                         in_use=1 reserved=0 blocked=0
+2s   E QUEUED (behind A on worker X)
+5s   B QUEUED blocked_on_token=synthetic  in_use=1 reserved=0 blocked=1
+20s  A done; E EXECUTING on X            in_use=0 reserved=1 blocked=0   <- B off the FIFO, token reserved
+21s  F QUEUED blocked_on_token=synthetic  in_use=0 reserved=1 blocked=1   <- default worker idle (8/8), F still parks
+60s  E done; B EXECUTING on X            in_use=1 reserved=0 blocked=1
+81s  B done; F EXECUTING on default      in_use=1 reserved=0 blocked=0
```

`ListPlatformQueues` at the moment F parked: platform `{pool=x}` 1 worker
executing, 1 queued (B, indirect); platform `{}` 8 workers all idle,
`blockedOperationsCount` 1 (F); `tokenPools:
[{"name":"synthetic","capacity":1,"blockedTasksCount":1,"reserved":1}]`.
Without the reservation F would have taken the token while B waited behind E,
which is the FIFO leak the reservation fixes.

The scheduler picks between B's and E's invocations with `isPreferred`:
equal executing counts and equal priority tie-break on `lastOperationStarted`,
which is unset for both fresh invocations, so the code promises no order. The
harness submits E before B and gives the filler REv2 priority -100 (factor 2
in the score), which makes X take E regardless of heap layout. A probe with
`I_FILLER_PRIORITY=0` (run `20260912-042834`) produced the same timeline
(E +20 s, B +60 s, F +81 s, `reserved==1` for 40 s): on a tie the heap keeps
the earlier-pushed child at its root, so submission order alone sufficed
there, but that is an implementation detail rather than a guarantee.

The scheduler log carries nothing about token pools at the default log
level: across all runs its only lines are the shutdown notice and, in
scenario d, the second process's startup. `proof/<scenario>_scheduler.log`
slices are therefore empty apart from the harness markers; metrics,
BuildQueueState and the admin UI are the observability surface.
