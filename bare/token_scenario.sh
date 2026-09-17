#!/usr/bin/env bash
# Scenario harness for scheduler license token pools. See TOKEN_HARNESS.md.
#
# Builds bb_scheduler, bb_worker and bb_runner in the checkout under test and
# the rest of the deployment from this workspace's //bare:bare, launches the
# processes one by one (the bare launcher stops every process when any one
# exits, which rules out restarting only the scheduler),
# drives the synthetic/ client workspace against the frontend and prints a
# PASS/FAIL table. Every knob is an environment variable so the same script
# can run against another deployment with LAUNCH=0.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# --- Knobs -------------------------------------------------------------------
# Scheduler under test: a bb-remote-execution checkout. Its own Bazel
# workspace builds bb_scheduler, bb_worker and bb_runner, so its module graph
# never has to agree with this repository's pins.
: "${BB_RE_DIR:?set BB_RE_DIR to a bb-remote-execution checkout that implements token pools}"
: "${HARNESS_ROOT:=${TMPDIR:-/tmp}/bb-bare}"
: "${WORK_DIR:=$HARNESS_ROOT/work}"          # bare's working directory
: "${RUN_DIR:=$HARNESS_ROOT/runs/$(date +%Y%m%d-%H%M%S)}"
: "${OUTPUT_USER_ROOT:=$HARNESS_ROOT/bazel}"  # keeps the deployment build off ~/.cache
: "${BAZEL:=bazel}"
: "${BAZEL_STARTUP:=--output_user_root=$OUTPUT_USER_ROOT --host_jvm_args=-Xmx6g}"
: "${BUILD:=1}"                              # 0 = reuse the last builds
: "${BUILD_STARTUP:=}"                       # e.g. --bazelrc=<rbe.bazelrc>
: "${BUILD_FLAGS:=}"                         # e.g. --config=rbe
# The same for the build inside BB_RE_DIR; default to the values above.
: "${RE_BUILD_STARTUP=$BUILD_STARTUP}"
: "${RE_BUILD_FLAGS=$BUILD_FLAGS}"
: "${LAUNCH:=1}"                             # 0 = target an already running deployment
: "${KEEP:=0}"                               # 1 = leave the deployment running on exit
: "${OS:=Linux}"                             # std.extVar('OS') in worker/runner configs

# Client side; override for another deployment.
: "${EXECUTOR:=grpc://localhost:8980}"
: "${INSTANCE_NAME:=local}"
: "${METRICS_URL:=http://localhost:9982/metrics}"
: "${ADMIN_URL:=http://localhost:7982}"
: "${BQS_ADDRESS:=localhost:8984}"
: "${GRPCURL:=$(command -v grpcurl || { [[ -x $HARNESS_ROOT/bin/grpcurl ]] && echo "$HARNESS_ROOT/bin/grpcurl"; } || true)}"
: "${CLIENT_JVM_ARGS:=-Xmx1g}"

# Second worker/runner pair for scenario i: platform property pool=<POOL>,
# its own working directory under WORK_DIR, its own diagnostics ports. 'auto'
# launches it only when scenario i is selected.
: "${WORKER_X:=auto}"
: "${WORKER_X_POOL:=x}"
: "${WORKER_X_CONCURRENCY:=1}"
: "${WORKER_X_DIAG_PORT:=9988}"
: "${RUNNER_X_DIAG_PORT:=9989}"
# REv2 priority of the token-free filler in scenario i; lower runs first.
# The scheduler breaks ties between fresh invocations arbitrarily, so the
# filler needs an edge over the unblocked tokened task.
: "${I_FILLER_PRIORITY:=-100}"

# Scheduler configuration (scheduler_harness.jsonnet reads these).
: "${TOKENS:=0}"                             # 1 = configure the token pool
# Pools are resolved by the platform queue's prefix, i.e. the worker's
# instanceNamePrefix ('' in bare/config/worker.jsonnet), not by the client's
# --remote_instance_name.
: "${TOKEN_POOL_INSTANCE_NAME_PREFIX=}"
: "${TOKEN_POOL_NAME:=synthetic}"
: "${TOKEN_POOL_CAPACITY:=2}"
: "${TOKEN_POOL_STARTUP_GRACE_PERIOD:=5s}"
: "${PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT:=10s}"

# Scenario i needs TOKEN_POOL_CAPACITY=1 and is skipped otherwise; run it in
# its own invocation: TOKEN_POOL_CAPACITY=1 SCENARIOS=i.
: "${SCENARIOS:=ab c d e f gh j}"
TOKENED_COUNT=10
CONTROL_COUNT=4

export OS TOKEN_POOL_INSTANCE_NAME_PREFIX TOKEN_POOL_NAME TOKEN_POOL_CAPACITY \
  TOKEN_POOL_STARTUP_GRACE_PERIOD PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT
export TOKEN_POOLS_ENABLED=$TOKENS

# --- Plumbing ----------------------------------------------------------------
mkdir -p "$WORK_DIR" "$RUN_DIR"
LOG_DIR=$RUN_DIR/logs
PROOF_DIR=$RUN_DIR/proof   # artifacts of the monitoring-surface scenarios g-j
mkdir -p "$LOG_DIR" "$PROOF_DIR"
declare -A PIDS=()
SAMPLER_PID=
OPS_POLLER_PID=
# One Bazel output base per scenario so client builds can run concurrently.
CLIENT_BASES=("$RUN_DIR"/ob-{a,b,c,d,f,gh,ia,ib,ie,if})
RESULTS=()
FAILED=0
# Rejections the scheduler under test has counted in this process lifetime;
# scenario j derives the expected metric series from these.
REJECTED_UNKNOWN=0
REJECTED_OVERSIZED=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
now() { date +%s; }
duration_s() { echo "${1%s}"; }   # '10s' -> 10

record() { # name status detail
  RESULTS+=("$1|$2|$3")
  [[ $2 == FAIL ]] && FAILED=1
  log "$1: $2 - $3"
}

cleanup() {
  local rc=$?
  set +e
  [[ -n $SAMPLER_PID ]] && kill "$SAMPLER_PID" 2>/dev/null
  [[ -n $OPS_POLLER_PID ]] && kill "$OPS_POLLER_PID" 2>/dev/null
  for ob in "${CLIENT_BASES[@]}"; do
    [[ -d $ob ]] || continue
    (cd "$REPO/synthetic" && $BAZEL --nosystem_rc --nohome_rc --output_user_root="$OUTPUT_USER_ROOT" --output_base="$ob" shutdown >/dev/null 2>&1)
  done
  if [[ $LAUNCH == 1 && $KEEP != 1 ]]; then
    for name in "${!PIDS[@]}"; do kill "${PIDS[$name]}" 2>/dev/null; done
    local deadline=$(( $(now) + 15 ))
    for name in "${!PIDS[@]}"; do
      while kill -0 "${PIDS[$name]}" 2>/dev/null && (( $(now) < deadline )); do sleep 0.5; done
      kill -9 "${PIDS[$name]}" 2>/dev/null
      wait "${PIDS[$name]}" 2>/dev/null
    done
  fi
  print_table
  exit $rc
}
trap cleanup EXIT

print_table() {
  {
    echo
    printf 'mode=%s capacity=%s executor=%s instance=%s run_dir=%s\n' \
      "$([[ $TOKENS == 1 ]] && echo tokens-on || echo baseline)" \
      "$TOKEN_POOL_CAPACITY" "$EXECUTOR" "$INSTANCE_NAME" "$RUN_DIR"
    printf '%-4s %-6s %s\n' SCEN STATUS DETAIL
    for r in "${RESULTS[@]}"; do
      IFS='|' read -r n s d <<<"$r"
      printf '%-4s %-6s %s\n' "$n" "$s" "$d"
    done
  } | tee "$RUN_DIR/results.txt"
}

# --- Deployment --------------------------------------------------------------
RE_TARGETS=(//cmd/bb_scheduler //cmd/bb_worker //cmd/bb_runner)

build_deployment() {
  log "Building //bare:bare (storage, frontend, portal)"
  (cd "$REPO" && $BAZEL $BAZEL_STARTUP $BUILD_STARTUP build $BUILD_FLAGS //bare:bare) \
    >"$LOG_DIR/build.log" 2>&1 || { tail -30 "$LOG_DIR/build.log" >&2; return 1; }
  log "Building ${RE_TARGETS[*]} in $BB_RE_DIR"
  # No convenience symlinks: the checkout may belong to somebody else's
  # Bazel server and must not be touched.
  (cd "$BB_RE_DIR" && $BAZEL $BAZEL_STARTUP $RE_BUILD_STARTUP build $RE_BUILD_FLAGS \
    --experimental_convenience_symlinks=ignore "${RE_TARGETS[@]}") \
    >"$LOG_DIR/build_re.log" 2>&1 || { tail -30 "$LOG_DIR/build_re.log" >&2; return 1; }
}

# Absolute path of a target's output file under the flags it was built with.
# The Go binaries sit behind a configuration transition, so their output
# directory carries a hash that `bazel info bazel-bin` does not show.
target_file() { # workspace startup_options build_flags target
  local ws=$1 startup=$2 flags=$3 target=$4 root rel
  root=$(cd "$ws" && $BAZEL $BAZEL_STARTUP $startup info execution_root 2>/dev/null)
  rel=$(cd "$ws" && $BAZEL $BAZEL_STARTUP $startup cquery $flags \
    --experimental_convenience_symlinks=ignore --output=files "$target" 2>/dev/null | head -1)
  [[ -n $root && -n $rel ]] || { log "cannot locate $target in $ws"; return 1; }
  echo "$root/$rel"
}

start_process() { # name binary config [working directory]
  local name=$1 bin=$2 cfg=$3 dir=${4:-$WORK_DIR}
  # >> opens the log O_APPEND, so scheduler_log_mark can interleave markers.
  ( cd "$dir" && exec env PWD="$dir" "$bin" "$cfg" ) >>"$LOG_DIR/$name.log" 2>&1 &
  PIDS[$name]=$!
  log "Started $name (pid ${PIDS[$name]})"
}

check_ports_free() {
  local ports='7982|8980|8981|8982|8983|8984|9982|9986|9987' busy
  [[ $WORKER_X == 1 ]] && ports="$ports|$WORKER_X_DIAG_PORT|$RUNNER_X_DIAG_PORT"
  busy=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ":($ports)\$" || true)
  if [[ -n $busy ]]; then
    log "Ports already in use, refusing to launch:"; echo "$busy" >&2
    return 1
  fi
}

launch_deployment() {
  check_ports_free
  local rf; rf=$(target_file "$REPO" "$BUILD_STARTUP" "$BUILD_FLAGS" //bare:bare).runfiles
  local storage=$rf/com_github_buildbarn_bb_storage+/cmd/bb_storage/bb_storage_/bb_storage
  local portal=$rf/com_github_buildbarn_bb_portal+/cmd/bb_portal/bb_portal_/bb_portal
  WORKER_BIN=$(target_file "$BB_RE_DIR" "$RE_BUILD_STARTUP" "$RE_BUILD_FLAGS" //cmd/bb_worker)
  RUNNER_BIN=$(target_file "$BB_RE_DIR" "$RE_BUILD_STARTUP" "$RE_BUILD_FLAGS" //cmd/bb_runner)
  CFG_DIR=$HERE/config
  # Same directories the bare launcher creates.
  mkdir -p "$WORK_DIR"/{storage-ac,storage-cas,storage-fsac}/persistent_state \
    "$WORK_DIR"/worker/{build,cache,cas/persistent_state}
  SCHEDULER_BIN=$(target_file "$BB_RE_DIR" "$RE_BUILD_STARTUP" "$RE_BUILD_FLAGS" //cmd/bb_scheduler)
  SCHEDULER_CFG=$CFG_DIR/scheduler_harness.jsonnet
  start_process storage "$storage" "$CFG_DIR/storage.jsonnet"
  start_process frontend "$storage" "$CFG_DIR/frontend.jsonnet"
  start_scheduler
  start_process worker "$WORKER_BIN" "$CFG_DIR/worker.jsonnet"
  start_process runner "$RUNNER_BIN" "$CFG_DIR/runner.jsonnet"
  if [[ -x $portal ]]; then start_process portal "$portal" "$CFG_DIR/portal.jsonnet"; fi
  if [[ $WORKER_X == 1 ]]; then launch_worker_x; fi
}

# Second worker/runner pair (scenario i) in its own working directory, since
# worker.jsonnet and runner.jsonnet address everything relative to it.
launch_worker_x() {
  local dir=$WORK_DIR/x
  mkdir -p "$dir"/worker/{build,cache,cas/persistent_state}
  export WORKER_POOL=$WORKER_X_POOL WORKER_CONCURRENCY=$WORKER_X_CONCURRENCY \
    WORKER_DIAG_PORT=$WORKER_X_DIAG_PORT RUNNER_DIAG_PORT=$RUNNER_X_DIAG_PORT WORKER_HOSTNAME=worker-x
  start_process worker-x "$WORKER_BIN" "$CFG_DIR/worker_harness.jsonnet" "$dir"
  start_process runner-x "$RUNNER_BIN" "$CFG_DIR/runner_harness.jsonnet" "$dir"
}

# Append a marker to the scheduler's log (O_APPEND keeps it in order with the
# process's own output) so save_scheduler_log can cut out one scenario.
scheduler_log_mark() { # start|end scenario
  [[ $LAUNCH == 1 ]] || return 0
  printf '### harness %s scenario %s %s\n' "$1" "$2" "$(date +%FT%T)" >>"$LOG_DIR/scheduler.log"
}
save_scheduler_log() { # scenario
  [[ $LAUNCH == 1 ]] || return 0
  awk -v s="$1" '$0 ~ "^### harness start scenario " s " " { on = 1 } on { print } $0 ~ "^### harness end scenario " s " " { on = 0 }' \
    "$LOG_DIR/scheduler.log" >"$PROOF_DIR/$1_scheduler.log"
}

start_scheduler() {
  start_process scheduler "$SCHEDULER_BIN" "$SCHEDULER_CFG"
  SCHEDULER_START=$(now)
  # Counters live in the process: a restart (scenario d) starts them over.
  REJECTED_UNKNOWN=0; REJECTED_OVERSIZED=0
}

wait_for_scheduler() {
  local deadline=$(( $(now) + 120 ))
  until curl -sf "$METRICS_URL" >/dev/null 2>&1; do
    if [[ -n ${PIDS[scheduler]:-} ]] && ! kill -0 "${PIDS[scheduler]}" 2>/dev/null; then
      log "scheduler exited during startup:"; tail -20 "$LOG_DIR/scheduler.log" >&2; return 1
    fi
    (( $(now) > deadline )) && { log "scheduler metrics never came up"; return 1; }
    sleep 1
  done
  # A worker has to synchronize before its platform queue exists; the
  # metric has one series per platform queue.
  local want=1; [[ $WORKER_X == 1 ]] && want=2
  deadline=$(( $(now) + 60 ))
  # Buffer the body: grep -q would close the pipe early and pipefail would
  # report curl's SIGPIPE as a failure.
  until (( $(grep -c '^buildbarn_builder_in_memory_build_queue_workers_created_total' <<<"$(curl -sf "$METRICS_URL")") >= want )); do
    (( $(now) > deadline )) && { log "fewer than $want platform queues have workers"; return 1; }
    sleep 1
  done
}

wait_for_no_workers_window() {
  # Actions for an unknown platform get Unavailable (which Bazel retries)
  # until the scheduler has been up this long; wait so failures are crisp.
  local until=$(( SCHEDULER_START + $(duration_s "$PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT") + 1 ))
  while (( $(now) < until )); do sleep 1; done
}

# --- Metrics -----------------------------------------------------------------
# Lines: <epoch> <in_use|blocked_tasks|capacity> <value>, sampled every second.
sampler_start() { # file
  local file=$1
  (
    set +e
    while :; do
      ts=$(now)
      curl -sf "$METRICS_URL" 2>/dev/null | awk -v ts="$ts" -v tok="$TOKEN_POOL_NAME" '
        /^buildbarn_builder_in_memory_build_queue_token_pool_/ && index($0, "token=\"" tok "\"") {
          split($1, a, "{"); m = a[1]
          sub(/^buildbarn_builder_in_memory_build_queue_token_pool_/, "", m)
          print ts, m, $2
        }'
      sleep 1
    done >>"$file"
  ) &
  SAMPLER_PID=$!
}
sampler_stop() { [[ -n $SAMPLER_PID ]] && kill "$SAMPLER_PID" 2>/dev/null; SAMPLER_PID=; }
metric_max() { # file metric [since_epoch] [until_epoch]
  awk -v m="$2" -v since="${3:-0}" -v until="${4:-9999999999}" \
    '$2 == m && $1 >= since && $1 <= until { if ($3 > x) x = $3 } END { print x + 0 }' "$1"
}
metric_samples() { awk -v m="$2" '$2 == m' "$1" | wc -l; }
# Number of samples where in_use + reserved exceeds capacity (must be 0).
metric_overcommits() { # file
  awk '{ v[$1, $2] = $3; ts[$1] = 1 }
       END { n = 0; for (t in ts) if (v[t, "in_use"] + v[t, "reserved"] > v[t, "capacity"]) n++; print n }' "$1"
}
wait_for_metric_at_least() { # file metric value timeout_s [pid that must stay alive]
  local deadline=$(( $(now) + $4 ))
  while (( $(metric_max "$1" "$2") < $3 )); do
    (( $(now) > deadline )) && return 1
    if [[ -n ${5:-} ]] && ! kill -0 "$5" 2>/dev/null; then return 1; fi
    sleep 1
  done
}
# Longest run of consecutive samples (seconds) in which metric == value.
metric_longest_run() { # file metric value
  awk -v m="$2" -v v="$3" '$2 == m { if ($3 == v) { n++; if (n > best) best = n } else n = 0 } END { print best + 0 }' "$1"
}
# Max of one metric over the samples where another metric equals a value.
metric_max_while() { # file metric other_metric other_value
  awk -v m="$2" -v o="$3" -v ov="$4" '{ v[$1, $2] = $3; ts[$1] = 1 }
       END { for (t in ts) if (v[t, o] == ov && v[t, m] > x) x = v[t, m]; print x + 0 }' "$1"
}
# Pool gauges scraped now: lines "<metric> <value>" for the harness pool.
scrape_pool_gauges() { # file
  curl -sf "$METRICS_URL" 2>/dev/null | awk -v tok="$TOKEN_POOL_NAME" '
    /^buildbarn_builder_in_memory_build_queue_token_pool_/ && index($0, "token=\"" tok "\"") {
      split($1, a, "{"); m = a[1]
      sub(/^buildbarn_builder_in_memory_build_queue_token_pool_/, "", m)
      print m, $2
    }' >"$1"
}
gauge_value() { awk -v m="$2" '$1 == m { print $2 + 0; f = 1 } END { if (!f) print -1 }' "$1"; } # file metric
within_one() { local d=$(( $1 - $2 )); (( d >= -1 && d <= 1 )); }

# --- BuildQueueState -----------------------------------------------------------
bqs_call() { # method [json request]
  if [[ -n ${2:-} ]]; then
    "$GRPCURL" -plaintext -d "$2" "$BQS_ADDRESS" "buildbarn.buildqueuestate.BuildQueueState/$1"
  else
    "$GRPCURL" -plaintext "$BQS_ADDRESS" "buildbarn.buildqueuestate.BuildQueueState/$1"
  fi
}
# Operation timeline sampled every second:
#   <epoch> <target_id> <QUEUED|EXECUTING|COMPLETED> <blocked_on_token|-> <tokens|-> <operation name>
ops_poller_start() { # file
  local file=$1
  (
    set +e
    while :; do
      ts=$(now)
      bqs_call ListOperations '{"pageSize":1000}' 2>/dev/null | jq -r --arg ts "$ts" '
        .operations[]? | [
          $ts, (.targetId // "-"),
          (if .queued != null then "QUEUED" elif .executing != null then "EXECUTING" elif .completed != null then "COMPLETED" else "UNKNOWN" end),
          (.blockedOnToken // "-"),
          ((.tokenRequirements // []) | map(.name + "=" + (.amount | tostring)) | join(",") | if . == "" then "-" else . end),
          .name] | @tsv'
      sleep 1
    done >>"$file"
  ) &
  OPS_POLLER_PID=$!
}
ops_poller_stop() { [[ -n $OPS_POLLER_PID ]] && kill "$OPS_POLLER_PID" 2>/dev/null; OPS_POLLER_PID=; }
# First sample time at which target was in stage (BLOCKED = queued with
# blocked_on_token set); 0 if never.
ops_first() { # file target stage
  awk -v t="$2" -v s="$3" '$2 == t && ((s == "BLOCKED" && $4 != "-") || $3 == s) { print $1; exit }' "$1" | grep . || echo 0
}
wait_for_op() { # file target stage timeout_s [pid that must stay alive]
  local deadline=$(( $(now) + $4 ))
  while (( $(ops_first "$1" "$2" "$3") == 0 )); do
    (( $(now) > deadline )) && return 1
    if [[ -n ${5:-} ]] && ! kill -0 "$5" 2>/dev/null; then return 1; fi
    sleep 1
  done
}

# --- Admin UI ----------------------------------------------------------------
# Table rows (newlines collapsed) of an admin page that contain a pattern.
html_rows() { # file pattern
  tr -d '\n\t' <"$1" | sed 's#</tr>#</tr>\n#g' | grep -- "$2" || true
}
# Numbers in the text-end cells of a row, in column order.
html_row_numbers() { grep -oE '<td class="text-end">(<a href="[^"]*">)?[0-9]+' | grep -oE '[0-9]+$'; }
# Relative hrefs of a row, HTML-unescaped.
html_row_hrefs() { grep -oE 'href="[^"]*"' | sed 's/^href="//; s/"$//; s/&amp;/\&/g'; }

# --- Client ------------------------------------------------------------------
client_bazel() { # output_base_name args...
  local ob=$RUN_DIR/ob-$1; shift
  # System and home rc files (BES upload, caches) would put this host's
  # environment between the client and the deployment under test.
  (cd "$REPO/synthetic" && $BAZEL --nosystem_rc --nohome_rc --output_user_root="$OUTPUT_USER_ROOT" \
    --output_base="$ob" --host_jvm_args="$CLIENT_JVM_ARGS" "$@")
}
client_build() { # output_base_name targets...
  local ob=$1; shift
  client_bazel "$ob" build --define=RUN_ID="$(date +%s%N)-$ob" \
    --remote_executor="$EXECUTOR" --remote_instance_name="$INSTANCE_NAME" "$@"
}
client_warm() { # output_base_name
  client_bazel "$1" build --nobuild --define=RUN_ID=warm //... >"$LOG_DIR/warm-$1.log" 2>&1
}
grep_error() { # log pattern: first match plus up to 200 following characters
  grep -m1 -oE "$2.{0,200}" "$1" || true
}
ERR_RE='(FAILED_PRECONDITION|UNAVAILABLE|No workers exist)'

# --- Scenarios ---------------------------------------------------------------
scenario_ab() {
  local m=$RUN_DIR/metrics_ab.txt la=$LOG_DIR/build_a.log lb=$LOG_DIR/build_b.log
  client_warm a; client_warm b
  sampler_start "$m"
  local t0 ra rb ta tb
  t0=$(now)
  client_build a //:tokened >"$la" 2>&1 & local pa=$!
  client_build b //:controls >"$lb" 2>&1 & local pb=$!
  rb=0; wait $pb || rb=$?; tb=$(( $(now) - t0 ))
  ra=0; wait $pa || ra=$?; ta=$(( $(now) - t0 ))
  sampler_stop
  local in_use blocked reserved samples over
  in_use=$(metric_max "$m" in_use); blocked=$(metric_max "$m" blocked_tasks)
  reserved=$(metric_max "$m" reserved); over=$(metric_overcommits "$m")
  samples=$(metric_samples "$m" in_use)
  local detail="tokened rc=$ra ${ta}s; max in_use=$in_use max blocked=$blocked max reserved=$reserved; in_use+reserved>capacity in $over of ${samples} samples"
  if [[ $TOKENS == 1 ]]; then
    local expect_blocked=$(( TOKENED_COUNT - TOKEN_POOL_CAPACITY ))
    local expect_wall=$(( (TOKENED_COUNT + TOKEN_POOL_CAPACITY - 1) / TOKEN_POOL_CAPACITY * 20 - 10 ))
    if (( ra == 0 && ta > expect_wall && in_use == TOKEN_POOL_CAPACITY && blocked >= expect_blocked && over == 0 )); then
      record a PASS "$detail; serialized into waves (>${expect_wall}s)"
    else
      record a FAIL "$detail; expected rc=0, wall>${expect_wall}s, in_use==$TOKEN_POOL_CAPACITY, blocked>=$expect_blocked, no overcommit; $(grep_error "$la" "$ERR_RE")"
    fi
  else
    local err; err=$(grep_error "$la" 'No workers exist')
    if (( ra != 0 && samples == 0 )) && grep -q 'token:synthetic' "$la"; then
      record a PASS "baseline: $detail; unpatched scheduler: ${err:0:120}"
    else
      record a FAIL "baseline: $detail; expected failure naming token:synthetic and no token_pool metrics; got: ${err:0:120}"
    fi
  fi
  # With token pools on, the controls must also finish while tokened work is
  # still queued; in the baseline the tokened build fails at once.
  if (( rb == 0 && tb < 30 )) && { [[ $TOKENS != 1 ]] || (( tb < ta )); }; then
    record b PASS "controls rc=0 in ${tb}s while tokened work took ${ta}s"
  else
    record b FAIL "controls rc=$rb in ${tb}s (tokened ${ta}s); expected rc=0, <30s; $(grep_error "$lb" "$ERR_RE")"
  fi
}

scenario_c() {
  local lc=$LOG_DIR/build_c.log t0 rc tc
  client_warm c
  t0=$(now)
  rc=0; client_build c //:bogus >"$lc" 2>&1 || rc=$?; tc=$(( $(now) - t0 ))
  local err; err=$(grep_error "$lc" '(FAILED_PRECONDITION|FailedPrecondition)')
  if (( rc != 0 && tc < 30 )) && [[ -n $err ]] && grep -q 'bogus' "$lc"; then
    [[ $TOKENS == 1 ]] && REJECTED_UNKNOWN=$(( REJECTED_UNKNOWN + 1 ))
    record c PASS "bogus token rejected in ${tc}s: ${err:0:160}"
  else
    record c FAIL "rc=$rc in ${tc}s; expected rc!=0, <30s, FailedPrecondition naming bogus; got: $(grep_error "$lc" "(ERROR|$ERR_RE)" | head -c 200)"
  fi
}

scenario_d() {
  if [[ $TOKENS != 1 ]]; then record d SKIP "restart needs token pools on"; return; fi
  if [[ $LAUNCH != 1 ]]; then record d SKIP "cannot restart a remote scheduler"; return; fi
  local m=$RUN_DIR/metrics_d.txt ld=$LOG_DIR/build_d.log
  client_warm d
  sampler_start "$m"
  local t0 rd td
  t0=$(now)
  client_build d //:tokened >"$ld" 2>&1 & local pd=$!
  if ! wait_for_metric_at_least "$m" in_use 1 60 $pd; then
    sampler_stop; kill $pd 2>/dev/null || true; wait $pd || true
    record d FAIL "no token was acquired within 60s before the restart; $(grep_error "$ld" "$ERR_RE")"; return
  fi
  sleep 3
  log "Killing scheduler pid ${PIDS[scheduler]} mid-run"
  kill -9 "${PIDS[scheduler]}"; wait "${PIDS[scheduler]}" 2>/dev/null || true
  local t_kill; t_kill=$(now)
  start_scheduler
  wait_for_scheduler
  local t_up; t_up=$(now)
  # The grace period starts with the scheduler process. Samples at 1 s
  # resolution: leave a 2 s margin before its end when asserting it held.
  local grace_s; grace_s=$(duration_s "$TOKEN_POOL_STARTUP_GRACE_PERIOD")
  local grace_end=$(( SCHEDULER_START + grace_s ))
  rd=0; wait $pd || rd=$?; td=$(( $(now) - t0 ))
  sampler_stop
  local after; after=$(metric_max "$m" in_use "$grace_end")
  local in_grace; in_grace=$(metric_max "$m" in_use "$SCHEDULER_START" "$(( grace_end - 2 ))")
  local requeued; requeued=$(metric_max "$m" blocked_tasks "$SCHEDULER_START" "$(( grace_end - 2 ))")
  local over; over=$(metric_overcommits "$m")
  local detail="rc=$rd ${td}s; scheduler down $(( t_up - t_kill ))s; during grace in_use=$in_grace blocked=$requeued; max in_use after grace=$after; in_use+reserved>capacity in $over samples"
  if (( rd == 0 && in_grace == 0 && after >= 1 && after <= TOKEN_POOL_CAPACITY && over == 0 )); then
    record d PASS "$detail"
  else
    record d FAIL "$detail; expected rc=0, in_use==0 during grace, 1<=in_use<=$TOKEN_POOL_CAPACITY after, no overcommit; $(grep_error "$ld" "$ERR_RE")"
  fi
}

scenario_e() {
  local found=absent via
  if [[ -n $GRPCURL ]] && "$GRPCURL" -plaintext "$BQS_ADDRESS" \
      buildbarn.buildqueuestate.BuildQueueState/ListPlatformQueues >"$RUN_DIR/platform_queues.json" 2>"$LOG_DIR/grpcurl.log"; then
    via=grpcurl
    if jq -e --arg n "$TOKEN_POOL_NAME" --argjson c "$TOKEN_POOL_CAPACITY" \
        '[.tokenPools[]? | select(.name == $n and ((.capacity // 0) | tonumber) == $c)] | length > 0' \
        "$RUN_DIR/platform_queues.json" >/dev/null; then found=present; fi
  else
    via=admin-html
    curl -sf "$ADMIN_URL/" >"$RUN_DIR/admin.html" 2>/dev/null || true
    grep -q "$TOKEN_POOL_NAME" "$RUN_DIR/admin.html" && found=present
  fi
  if [[ $TOKENS == 1 ]]; then
    [[ $found == present ]] && record e PASS "pool $TOKEN_POOL_NAME capacity $TOKEN_POOL_CAPACITY listed via $via" \
      || record e FAIL "pool $TOKEN_POOL_NAME not listed via $via (see $RUN_DIR/platform_queues.json or admin.html)"
  else
    [[ $found == absent ]] && record e PASS "baseline: no token pool listed via $via" \
      || record e FAIL "baseline: unexpected pool listed via $via"
  fi
}

scenario_f() {
  if [[ $TOKENS != 1 ]]; then record f SKIP "oversized request needs token pools on"; return; fi
  local lf=$LOG_DIR/build_f.log t0 rf tf
  client_warm f
  t0=$(now)
  rf=0; client_build f //:oversized >"$lf" 2>&1 || rf=$?; tf=$(( $(now) - t0 ))
  local err; err=$(grep_error "$lf" '(FAILED_PRECONDITION|FailedPrecondition)')
  if (( rf != 0 && tf < 30 )) && [[ -n $err ]] && grep -qi 'capacity' "$lf"; then
    REJECTED_OVERSIZED=$(( REJECTED_OVERSIZED + 1 ))
    record f PASS "3 tokens against capacity $TOKEN_POOL_CAPACITY rejected in ${tf}s: ${err:0:160}"
  else
    record f FAIL "rc=$rf in ${tf}s; expected rc!=0, <30s, FailedPrecondition mentioning capacity; got: $(grep_error "$lf" "(ERROR|$ERR_RE)" | head -c 200)"
  fi
}

# Scenarios g and h probe the admin UI and BuildQueueState while a tokened
# build has the pool saturated (first wave running, the rest parked).
scenario_gh() {
  if [[ $TOKENS != 1 ]]; then record g SKIP "admin UI probe needs token pools on"; record h SKIP "BuildQueueState probe needs token pools on"; return; fi
  local m=$RUN_DIR/metrics_gh.txt lg=$LOG_DIR/build_gh.log
  client_warm gh
  sampler_start "$m"
  client_build gh //:tokened >"$lg" 2>&1 & local pg=$!
  if ! wait_for_metric_at_least "$m" in_use 1 60 $pg || ! wait_for_metric_at_least "$m" blocked_tasks 1 30 $pg; then
    sampler_stop; kill $pg 2>/dev/null || true; wait $pg || true
    record g FAIL "pool never saturated within 60s; $(grep_error "$lg" "$ERR_RE")"
    record h FAIL "pool never saturated within 60s"; return
  fi
  sleep 2   # let the first wave settle: the state then holds for ~18 s
  probe_admin_ui
  probe_build_queue_state
  local rg=0; wait $pg || rg=$?
  sampler_stop
  (( rg == 0 )) || record g FAIL "tokened build behind the probes failed rc=$rg; $(grep_error "$lg" "$ERR_RE")"
}

probe_admin_ui() { # scenario g
  local html=$PROOF_DIR/g_admin.html gauges=$PROOF_DIR/g_gauges.txt
  # Page and gauges within the same second.
  curl -sf "$ADMIN_URL/" >"$html" 2>/dev/null || { record g FAIL "GET $ADMIN_URL/ failed"; return; }
  scrape_pool_gauges "$gauges"
  local row; row=$(html_rows "$html" ">$TOKEN_POOL_NAME</span>" | head -1)
  if [[ -z $row ]]; then record g FAIL "no token pools row for $TOKEN_POOL_NAME in $html"; return; fi
  # Columns: capacity, in use, reserved, blocked tasks.
  local nums; read -r -a nums <<<"$(html_row_numbers <<<"$row" | tr '\n' ' ')"
  local links; read -r -a links <<<"$(html_row_hrefs <<<"$row" | tr '\n' ' ')"
  if (( ${#nums[@]} != 4 || ${#links[@]} != 3 )); then record g FAIL "unexpected pool row shape (${#nums[@]} numbers, ${#links[@]} links): ${row:0:300}"; return; fi
  local g_in g_bl g_re
  g_in=$(gauge_value "$gauges" in_use); g_bl=$(gauge_value "$gauges" blocked_tasks); g_re=$(gauge_value "$gauges" reserved)
  local detail="row cap=${nums[0]} in_use=${nums[1]} reserved=${nums[2]} blocked=${nums[3]} vs gauges in_use=$g_in reserved=$g_re blocked=$g_bl"
  local ok=1
  (( nums[0] == TOKEN_POOL_CAPACITY )) || ok=0
  within_one "${nums[1]}" "$g_in" && within_one "${nums[2]}" "$g_re" && within_one "${nums[3]}" "$g_bl" || ok=0
  # Links: in use -> EXECUTING holders, reserved -> QUEUED requirers, blocked -> parked only.
  [[ ${links[0]} == *filter_stage=EXECUTING*filter_token=$TOKEN_POOL_NAME* ]] || ok=0
  [[ ${links[2]} == *filter_stage=QUEUED*filter_token=$TOKEN_POOL_NAME*filter_token_blocked_only=1* ]] || ok=0
  local page rows total with_token executing blocked
  for page in in_use:0 reserved:1 blocked:2; do
    curl -sf "$ADMIN_URL/${links[${page#*:}]}" >"$PROOF_DIR/g_${page%:*}.html" 2>/dev/null || { ok=0; detail="$detail; GET ${links[${page#*:}]} failed"; continue; }
  done
  rows=$(html_rows "$PROOF_DIR/g_in_use.html" 'href="operation?name=')
  total=$(grep -c . <<<"$rows" || true); with_token=$(grep -c ">$TOKEN_POOL_NAME=[0-9]*</span>" <<<"$rows" || true)
  executing=$(grep -c '>Executing<' <<<"$rows" || true)
  detail="$detail; in-use page rows=$total with_token=$with_token executing=$executing"
  (( total > 0 && total == with_token && total == executing )) && within_one "$total" "${nums[1]}" || ok=0
  rows=$(html_rows "$PROOF_DIR/g_blocked.html" 'href="operation?name=')
  total=$(grep -c . <<<"$rows" || true); with_token=$(grep -c ">$TOKEN_POOL_NAME=[0-9]*</span>" <<<"$rows" || true)
  blocked=$(grep -c "blocked on token $TOKEN_POOL_NAME<" <<<"$rows" || true)
  detail="$detail; blocked page rows=$total with_token=$with_token parked=$blocked"
  (( total > 0 && total == with_token && total == blocked )) && within_one "$total" "${nums[3]}" || ok=0
  if (( ok )); then record g PASS "$detail"; else record g FAIL "$detail; expected cap=$TOKEN_POOL_CAPACITY, row==gauges (+-1), pages listing only $TOKEN_POOL_NAME holders / parked tasks"; fi
}

probe_build_queue_state() { # scenario h
  if [[ -z $GRPCURL ]]; then record h SKIP "grpcurl not found"; return; fi
  local tok=$TOKEN_POOL_NAME pfx=$TOKEN_POOL_INSTANCE_NAME_PREFIX gauges=$PROOF_DIR/h_gauges.txt
  local base="\"pageSize\":1000,\"filterTokenName\":\"$tok\""
  scrape_pool_gauges "$gauges"
  bqs_call ListOperations "{$base,\"filterTokenInstanceNamePrefix\":\"$pfx\"}" >"$PROOF_DIR/h_filter_token.json" 2>"$LOG_DIR/grpcurl_h.log" || { record h FAIL "ListOperations with token filter failed: $(head -c 200 "$LOG_DIR/grpcurl_h.log")"; return; }
  bqs_call ListOperations "{$base,\"filterTokenInstanceNamePrefix\":\"$pfx\",\"filterTokenBlockedOnly\":true}" >"$PROOF_DIR/h_blocked_only.json" 2>>"$LOG_DIR/grpcurl_h.log" || true
  bqs_call ListOperations "{$base,\"filterTokenInstanceNamePrefix\":\"no-such-prefix\"}" >"$PROOF_DIR/h_wrong_prefix.json" 2>>"$LOG_DIR/grpcurl_h.log" || true
  # "operations" is a reserved instance name component.
  local malformed_rc=0
  bqs_call ListOperations "{$base,\"filterTokenInstanceNamePrefix\":\"operations\"}" >"$PROOF_DIR/h_malformed_prefix.txt" 2>&1 || malformed_rc=$?
  local g_in g_bl n_exec n_blocked n_total n_with_token wrong
  g_in=$(gauge_value "$gauges" in_use); g_bl=$(gauge_value "$gauges" blocked_tasks)
  n_total=$(jq '[.operations[]?] | length' "$PROOF_DIR/h_filter_token.json")
  n_with_token=$(jq --arg t "$tok" '[.operations[]? | select(any(.tokenRequirements[]?; .name == $t))] | length' "$PROOF_DIR/h_filter_token.json")
  n_exec=$(jq '[.operations[]? | select(.executing != null)] | length' "$PROOF_DIR/h_filter_token.json")
  n_blocked=$(jq '[.operations[]? | select((.blockedOnToken // "") != "")] | length' "$PROOF_DIR/h_filter_token.json")
  jq -r '.operations[]? | select((.blockedOnToken // "") != "") | .name' "$PROOF_DIR/h_filter_token.json" | sort >"$PROOF_DIR/h_parked_from_filter.txt"
  jq -r '.operations[]? | .name' "$PROOF_DIR/h_blocked_only.json" | sort >"$PROOF_DIR/h_parked_from_blocked_only.txt"
  wrong=$(jq '[.operations[]?] | length' "$PROOF_DIR/h_wrong_prefix.json")
  local detail="filter_token: $n_total ops ($n_with_token require $tok), executing=$n_exec vs in_use=$g_in, blocked_on_token=$n_blocked vs blocked=$g_bl; blocked_only=$(wc -l <"$PROOF_DIR/h_parked_from_blocked_only.txt") ops; wrong prefix=$wrong ops; malformed prefix rc=$malformed_rc $(grep -o 'Code: [A-Za-z]*' "$PROOF_DIR/h_malformed_prefix.txt" | head -1)"
  if (( n_total > 0 && n_total == n_with_token && wrong == 0 && malformed_rc != 0 )) && within_one "$n_exec" "$g_in" && within_one "$n_blocked" "$g_bl" \
      && cmp -s "$PROOF_DIR/h_parked_from_filter.txt" "$PROOF_DIR/h_parked_from_blocked_only.txt" \
      && grep -q 'InvalidArgument' "$PROOF_DIR/h_malformed_prefix.txt"; then
    record h PASS "$detail"
  else
    record h FAIL "$detail; expected counts==gauges (+-1), blocked_only==parked set, wrong prefix empty, malformed prefix InvalidArgument"
  fi
}

# Scenario i: the reservation window. Pool capacity 1 shared by two platform
# queues: worker X (pool=x, concurrency 1) and the default worker (idle).
#   A tokened on X runs; B tokened on X parks; E token-free on X queues behind
#   A. When A ends, B leaves the FIFO with a reservation and X takes E (its
#   priority wins), so reserved==1, in_use==0 for E's duration. F, tokened on
#   the default platform, must park despite an idle worker, and may only run
#   after B.
scenario_i() {
  if [[ $TOKENS != 1 ]]; then record i SKIP "reservation window needs token pools on"; return; fi
  if (( TOKEN_POOL_CAPACITY != 1 )); then record i SKIP "needs TOKEN_POOL_CAPACITY=1 (run: TOKEN_POOL_CAPACITY=1 SCENARIOS=i)"; return; fi
  if [[ $WORKER_X != 1 ]]; then record i SKIP "second worker not launched (WORKER_X=1)"; return; fi
  if [[ -z $GRPCURL ]]; then record i SKIP "grpcurl not found"; return; fi
  local m=$RUN_DIR/metrics_i.txt ops=$PROOF_DIR/i_ops.tsv
  client_warm ia; client_warm ib; client_warm ie; client_warm if
  sampler_start "$m"; ops_poller_start "$ops"
  local pa pb pe pf ra=0 rb=0 re=0 rf=0 fail=
  client_build ia //:i_a >"$LOG_DIR/build_ia.log" 2>&1 & pa=$!
  wait_for_metric_at_least "$m" in_use 1 60 $pa || fail="A never acquired the token"
  if [[ -z $fail ]]; then
    client_build ie //:i_e --remote_execution_priority="$I_FILLER_PRIORITY" >"$LOG_DIR/build_ie.log" 2>&1 & pe=$!
    wait_for_op "$ops" //:i_e QUEUED 30 $pe || fail="E did not queue behind A"
  fi
  if [[ -z $fail ]]; then
    client_build ib //:i_b >"$LOG_DIR/build_ib.log" 2>&1 & pb=$!
    wait_for_op "$ops" //:i_b BLOCKED 30 $pb || fail="B did not park"
  fi
  if [[ -z $fail ]]; then
    # A ends within 20 s; B is then taken off the FIFO with a reservation.
    wait_for_metric_at_least "$m" reserved 1 40 $pb || fail="no reservation appeared after A finished"
  fi
  local t_f_parked=0
  if [[ -z $fail ]]; then
    client_build if //:i_f >"$LOG_DIR/build_if.log" 2>&1 & pf=$!
    if wait_for_op "$ops" //:i_f BLOCKED 30 $pf; then
      t_f_parked=$(now)
      bqs_call ListPlatformQueues >"$PROOF_DIR/i_platform_queues_f_parked.json" 2>/dev/null || true
      scrape_pool_gauges "$PROOF_DIR/i_gauges_f_parked.txt"
    else
      fail="F did not park"
    fi
  fi
  [[ -n ${pa:-} ]] && { wait $pa || ra=$?; }; [[ -n ${pb:-} ]] && { wait $pb || rb=$?; }
  [[ -n ${pe:-} ]] && { wait $pe || re=$?; }; [[ -n ${pf:-} ]] && { wait $pf || rf=$?; }
  sampler_stop; ops_poller_stop
  cp "$m" "$PROOF_DIR/i_metrics.txt"
  local xa xe xb xf window in_use_while_reserved over idle_default
  xa=$(ops_first "$ops" //:i_a EXECUTING); xe=$(ops_first "$ops" //:i_e EXECUTING)
  xb=$(ops_first "$ops" //:i_b EXECUTING); xf=$(ops_first "$ops" //:i_f EXECUTING)
  window=$(metric_longest_run "$m" reserved 1)
  in_use_while_reserved=$(metric_max_while "$m" in_use reserved 1)
  over=$(metric_overcommits "$m")
  idle_default=$(jq '[.platformQueues[]? | select((.name.platform.properties // []) | length == 0) | .sizeClassQueues[].rootInvocation.idleWorkersCount // 0] | add // 0' "$PROOF_DIR/i_platform_queues_f_parked.json" 2>/dev/null || echo -1)
  local order="X took"; if (( xe > 0 && (xb == 0 || xe < xb) )); then order="$order E (filler, priority $I_FILLER_PRIORITY) before B"; else order="$order B before E"; fi
  local detail="rc A=$ra B=$rb E=$re F=$rf; $order; reserved==1 for $window consecutive s with max in_use=$in_use_while_reserved; F parked at +$(( t_f_parked > 0 ? t_f_parked - xa : -1 ))s with $idle_default idle default worker(s); start offsets E=+$(( xe - xa ))s B=+$(( xb - xa ))s F=+$(( xf - xa ))s; overcommits=$over"
  if [[ -z $fail ]] && (( ra == 0 && rb == 0 && re == 0 && rf == 0 && xe > 0 && xe < xb && window >= 10 && in_use_while_reserved == 0 && t_f_parked > 0 && idle_default >= 1 && xf > xb && over == 0 )); then
    record i PASS "$detail"
  else
    record i FAIL "${fail:+$fail; }$detail; expected all rc=0, E before B, reserved==1 for >=10s with in_use 0, F parked while a default worker is idle, F starts after B, no overcommit"
  fi
}

# Scenario j: the metric series are exactly one per gauge per pool plus the
# rejection counter labelled by prefix and reason (never by the client's
# token name), after this run's rejections.
scenario_j() {
  if [[ $TOKENS != 1 ]]; then record j SKIP "metric series check needs token pools on"; return; fi
  local actual=$PROOF_DIR/j_token_pool_series.txt expected=$PROOF_DIR/j_expected_series.txt
  curl -sf "$METRICS_URL" | grep token_pool | grep -v '^#' >"$actual" || true
  local pfx=$TOKEN_POOL_INSTANCE_NAME_PREFIX g
  {
    for g in blocked_tasks capacity in_use reserved; do
      echo "buildbarn_builder_in_memory_build_queue_token_pool_${g}{instance_name_prefix=\"$pfx\",token=\"$TOKEN_POOL_NAME\"}"
    done
    (( REJECTED_OVERSIZED > 0 )) && echo "buildbarn_builder_in_memory_build_queue_token_pool_rejections_total{instance_name_prefix=\"$pfx\",reason=\"ExceedsCapacity\"} $REJECTED_OVERSIZED"
    (( REJECTED_UNKNOWN > 0 )) && echo "buildbarn_builder_in_memory_build_queue_token_pool_rejections_total{instance_name_prefix=\"$pfx\",reason=\"UnknownPool\"} $REJECTED_UNKNOWN"
    true
  } | sort >"$expected"
  # Gauge values vary; compare rejection counters by value, gauges by name.
  local normalized=$PROOF_DIR/j_actual_normalized.txt
  awk '/rejections_total/ { print; next } { print $1 }' "$actual" | sort >"$normalized"
  local detail="$(wc -l <"$actual") series: $(awk '{ sub(/^buildbarn_builder_in_memory_build_queue_token_pool_/, ""); printf "%s ", $0 }' "$actual")"
  if diff -u "$expected" "$normalized" >"$PROOF_DIR/j_diff.txt"; then
    record j PASS "$detail; matches expected set (UnknownPool=$REJECTED_UNKNOWN ExceedsCapacity=$REJECTED_OVERSIZED)"
  else
    record j FAIL "$detail; differs from expected, see $PROOF_DIR/j_diff.txt"
  fi
}

# --- Main --------------------------------------------------------------------
log "run dir $RUN_DIR; mode $([[ $TOKENS == 1 ]] && echo tokens-on || echo baseline)"
if [[ $WORKER_X == auto ]]; then
  WORKER_X=0; for s in $SCENARIOS; do [[ $s == i ]] && WORKER_X=1; done
fi
if [[ $LAUNCH == 1 ]]; then
  [[ $BUILD == 1 ]] && build_deployment
  launch_deployment
  wait_for_scheduler
  wait_for_no_workers_window
else
  SCHEDULER_START=0
fi
for s in $SCENARIOS; do
  scheduler_log_mark start "$s"
  case $s in
    ab) scenario_ab ;;
    c) scenario_c ;;
    d) scenario_d ;;
    e) scenario_e ;;
    f) scenario_f ;;
    gh) scenario_gh ;;
    i) scenario_i ;;
    j) scenario_j ;;
    *) log "unknown scenario $s"; exit 2 ;;
  esac
  scheduler_log_mark end "$s"
  save_scheduler_log "$s"
done
exit $FAILED
