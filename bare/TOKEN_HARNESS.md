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
- `synthetic/` is a dependency-free client workspace: ten `sleep 20` genrules
  carrying `exec_properties = {"token:synthetic": "1"}` (`//:tokened`), four
  untokened `sleep 5` controls (`//:controls`), and `//:bogus` requiring a
  pool no scheduler configures. Every command embeds `$(RUN_ID)`; the script
  passes a fresh `--define=RUN_ID=...` per build so nothing is an action cache
  hit. Its `.bazelrc` targets `grpc://localhost:8980`, instance `local`,
  `--spawn_strategy=remote`.
- `bare/token_scenario.sh` builds `//bare:bare` with the scheduler under test
  swapped in via `--override_module=com_github_buildbarn_bb_remote_execution`,
  launches the six processes itself (the `bare` launcher stops all of them
  when any one exits, so it cannot restart only the scheduler), samples
  `:9982/metrics` once a second, runs the scenarios and prints a PASS/FAIL
  table. Logs and samples land in `$RUN_DIR`.

## Running

```sh
# Scheduler under test (a bb-remote-execution checkout), tokens on:
BB_RE_DIR=/path/to/bb-remote-execution TOKENS=1 bare/token_scenario.sh

# Build the deployment's binaries on a remote executor instead of this host:
BUILD_STARTUP=--bazelrc=/path/to/rbe.bazelrc BUILD_FLAGS=--config=rbe TOKENS=1 bare/token_scenario.sh

# Reuse the last build, baseline expectations (stock scheduler):
BUILD=0 TOKENS=0 bare/token_scenario.sh
```

Knobs, all environment variables with defaults in the script:

| Variable | Meaning |
|---|---|
| `BB_RE_DIR` | bb-remote-execution checkout providing bb_scheduler, bb_worker, bb_runner |
| `TOKENS` | `1` configures the pool; `0` runs baseline expectations |
| `TOKEN_POOL_NAME`, `TOKEN_POOL_CAPACITY`, `TOKEN_POOL_STARTUP_GRACE_PERIOD`, `TOKEN_POOL_INSTANCE_NAME_PREFIX` | pool definition; durations must be in seconds (`5s`) |
| `PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT` | default `10s`, instead of upstream's `900s`, so an action for a platform without workers fails with FailedPrecondition instead of Unavailable retries |
| `BUILD`, `BUILD_STARTUP`, `BUILD_FLAGS` | skip the build, add startup options (`--bazelrc=`), add build flags (`--config=`) |
| `BAZEL_STARTUP`, `OUTPUT_USER_ROOT` | startup options for the deployment build (default `--output_user_root=/bazel-cache/greg/bbdep --host_jvm_args=-Xmx6g`) |
| `LAUNCH=0`, `EXECUTOR`, `INSTANCE_NAME`, `METRICS_URL`, `ADMIN_URL`, `BQS_ADDRESS` | target a deployment that is already running elsewhere |
| `GRPCURL` | path to grpcurl for scenario e; falls back to the admin HTML |
| `SCENARIOS` | subset of `ab c d e` |
| `WORK_DIR`, `RUN_DIR`, `KEEP=1` | bare working directory, per-run output, leave the deployment up on exit |

The bare processes hold ports 7982, 8980-8984, 9982, 9986, 9987; the script
refuses to launch while any is in use. The client runs with
`--nosystem_rc --nohome_rc` so this host's BES or cache settings do not sit
between the client and the deployment under test.

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

The metrics sampled are
`buildbarn_builder_in_memory_build_queue_token_pool_{capacity,in_use,blocked_tasks}{instance_name_prefix,token}`.

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
