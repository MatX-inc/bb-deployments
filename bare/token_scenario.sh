#!/usr/bin/env bash
# Scenario harness for scheduler license token pools. See TOKEN_HARNESS.md.
#
# Builds //bare:bare with the scheduler under test swapped in, launches the
# bare deployment's processes one by one (the bare launcher stops every
# process when any one exits, which rules out restarting only the scheduler),
# drives the synthetic/ client workspace against the frontend and prints a
# PASS/FAIL table. Every knob is an environment variable so the same script
# can run against another deployment with LAUNCH=0.
set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

# --- Knobs -------------------------------------------------------------------
# Scheduler under test: a bb-remote-execution checkout swapped in with
# --override_module.
: "${BB_RE_DIR:=/home/greg/s/bb-remote-execution-token-pools}"
: "${HARNESS_ROOT:=/home/greg/tmp/bb-bare}"
: "${WORK_DIR:=$HARNESS_ROOT/work}"          # bare's working directory
: "${RUN_DIR:=$HARNESS_ROOT/runs/$(date +%Y%m%d-%H%M%S)}"
: "${OUTPUT_USER_ROOT:=/bazel-cache/greg/bbdep}"
: "${BAZEL:=bazel}"
: "${BAZEL_STARTUP:=--output_user_root=$OUTPUT_USER_ROOT --host_jvm_args=-Xmx6g}"
: "${BUILD:=1}"                              # 0 = reuse the last //bare:bare build
: "${BUILD_STARTUP:=}"                       # e.g. --bazelrc=<rbe.bazelrc>
: "${BUILD_FLAGS:=}"                         # e.g. --config=rbe
: "${LAUNCH:=1}"                             # 0 = target an already running deployment
: "${KEEP:=0}"                               # 1 = leave the deployment running on exit
: "${OS:=Linux}"                             # std.extVar('OS') in worker/runner configs

# Client side; override for another deployment.
: "${EXECUTOR:=grpc://localhost:8980}"
: "${INSTANCE_NAME:=local}"
: "${METRICS_URL:=http://localhost:9982/metrics}"
: "${ADMIN_URL:=http://localhost:7982}"
: "${BQS_ADDRESS:=localhost:8984}"
: "${GRPCURL:=$(command -v grpcurl || true)}"
: "${CLIENT_JVM_ARGS:=-Xmx1g}"

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

: "${SCENARIOS:=ab c d e f}"
TOKENED_COUNT=10
CONTROL_COUNT=4

export OS TOKEN_POOL_INSTANCE_NAME_PREFIX TOKEN_POOL_NAME TOKEN_POOL_CAPACITY \
  TOKEN_POOL_STARTUP_GRACE_PERIOD PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT
export TOKEN_POOLS_ENABLED=$TOKENS

# --- Plumbing ----------------------------------------------------------------
mkdir -p "$WORK_DIR" "$RUN_DIR"
LOG_DIR=$RUN_DIR/logs
mkdir -p "$LOG_DIR"
declare -A PIDS=()
SAMPLER_PID=
# One Bazel output base per scenario so client builds can run concurrently.
CLIENT_BASES=("$RUN_DIR"/ob-{a,b,c,d,f})
RESULTS=()
FAILED=0

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
  for ob in "${CLIENT_BASES[@]}"; do
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
build_bare() {
  log "Building //bare:bare with bb_remote_execution=$BB_RE_DIR"
  (cd "$REPO" && $BAZEL $BAZEL_STARTUP $BUILD_STARTUP build $BUILD_FLAGS \
    --override_module=com_github_buildbarn_bb_remote_execution="$BB_RE_DIR" \
    //bare:bare) >"$LOG_DIR/build.log" 2>&1 || { tail -30 "$LOG_DIR/build.log" >&2; return 1; }
}

runfiles_dir() {
  local bin
  bin=$(cd "$REPO" && $BAZEL $BAZEL_STARTUP info bazel-bin 2>/dev/null)
  echo "$bin/bare/bare_/bare.runfiles"
}

start_process() { # name binary config
  local name=$1 bin=$2 cfg=$3
  ( cd "$WORK_DIR" && exec env PWD="$WORK_DIR" "$bin" "$cfg" ) >>"$LOG_DIR/$name.log" 2>&1 &
  PIDS[$name]=$!
  log "Started $name (pid ${PIDS[$name]})"
}

check_ports_free() {
  local busy
  busy=$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(7982|8980|8981|8982|8983|8984|9982|9986|9987)$' || true)
  if [[ -n $busy ]]; then
    log "Ports already in use, refusing to launch:"; echo "$busy" >&2
    return 1
  fi
}

launch_deployment() {
  check_ports_free
  local rf; rf=$(runfiles_dir)
  local storage=$rf/com_github_buildbarn_bb_storage+/cmd/bb_storage/bb_storage_/bb_storage
  local re=$rf/com_github_buildbarn_bb_remote_execution+/cmd
  local portal=$rf/com_github_buildbarn_bb_portal+/cmd/bb_portal/bb_portal_/bb_portal
  local cfg=$HERE/config
  # Same directories the bare launcher creates.
  mkdir -p "$WORK_DIR"/{storage-ac,storage-cas,storage-fsac}/persistent_state \
    "$WORK_DIR"/worker/{build,cache,cas/persistent_state}
  SCHEDULER_BIN=$re/bb_scheduler/bb_scheduler_/bb_scheduler
  SCHEDULER_CFG=$cfg/scheduler_harness.jsonnet
  start_process storage "$storage" "$cfg/storage.jsonnet"
  start_process frontend "$storage" "$cfg/frontend.jsonnet"
  start_scheduler
  start_process worker "$re/bb_worker/bb_worker_/bb_worker" "$cfg/worker.jsonnet"
  start_process runner "$re/bb_runner/bb_runner_/bb_runner" "$cfg/runner.jsonnet"
  if [[ -x $portal ]]; then start_process portal "$portal" "$cfg/portal.jsonnet"; fi
}

start_scheduler() {
  start_process scheduler "$SCHEDULER_BIN" "$SCHEDULER_CFG"
  SCHEDULER_START=$(now)
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
  # A worker has to synchronize before the platform queue exists.
  deadline=$(( $(now) + 60 ))
  # Buffer the body: grep -q would close the pipe early and pipefail would
  # report curl's SIGPIPE as a failure.
  until grep -q '^buildbarn_builder_in_memory_build_queue_workers_created_total' <<<"$(curl -sf "$METRICS_URL")"; do
    (( $(now) > deadline )) && { log "no worker registered with the scheduler"; return 1; }
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
  client_bazel "$1" build --nobuild --define=RUN_ID=warm //:tokened //:controls //:bogus //:oversized \
    >"$LOG_DIR/warm-$1.log" 2>&1
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
    record f PASS "3 tokens against capacity $TOKEN_POOL_CAPACITY rejected in ${tf}s: ${err:0:160}"
  else
    record f FAIL "rc=$rf in ${tf}s; expected rc!=0, <30s, FailedPrecondition mentioning capacity; got: $(grep_error "$lf" "(ERROR|$ERR_RE)" | head -c 200)"
  fi
}

# --- Main --------------------------------------------------------------------
log "run dir $RUN_DIR; mode $([[ $TOKENS == 1 ]] && echo tokens-on || echo baseline)"
if [[ $LAUNCH == 1 ]]; then
  [[ $BUILD == 1 ]] && build_bare
  launch_deployment
  wait_for_scheduler
  wait_for_no_workers_window
else
  SCHEDULER_START=0
fi
for s in $SCENARIOS; do
  case $s in
    ab) scenario_ab ;;
    c) scenario_c ;;
    d) scenario_d ;;
    e) scenario_e ;;
    f) scenario_f ;;
    *) log "unknown scenario $s"; exit 2 ;;
  esac
done
exit $FAILED
