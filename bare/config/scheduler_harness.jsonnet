// Scheduler configuration used by token_scenario.sh. It is scheduler.jsonnet
// with every harness knob read from the environment (std.extVar); the script
// always sets all of them, so there are no defaults here.
//
//   TOKEN_POOLS_ENABLED                     '0' or '1'
//   TOKEN_POOL_INSTANCE_NAME_PREFIX         e.g. 'local'
//   TOKEN_POOL_NAME                         e.g. 'synthetic'
//   TOKEN_POOL_CAPACITY                     integer as a string
//   TOKEN_POOL_STARTUP_GRACE_PERIOD         duration, e.g. '5s'
//   PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT  duration, e.g. '10s'
local base = import 'scheduler.jsonnet';
local tokenPools = import 'token_pools.libsonnet';

base {
  // An action whose platform matches no worker fails with FailedPrecondition
  // once the scheduler has been up this long (Unavailable before that, which
  // Bazel retries). The upstream default of 900s would hide the failure mode
  // of an unpatched scheduler behind Bazel's retry budget.
  platformQueueWithNoWorkersTimeout: std.extVar('PLATFORM_QUEUE_WITH_NO_WORKERS_TIMEOUT'),
} + tokenPools.schedulerFields(
  std.extVar('TOKEN_POOLS_ENABLED') == '1',
  std.extVar('TOKEN_POOL_INSTANCE_NAME_PREFIX'),
  std.extVar('TOKEN_POOL_NAME'),
  std.parseInt(std.extVar('TOKEN_POOL_CAPACITY')),
  std.extVar('TOKEN_POOL_STARTUP_GRACE_PERIOD'),
)
