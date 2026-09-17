// Scheduler configuration fragment for license token pools.
//
// An unpatched upstream bb_scheduler rejects the tokenPools and
// tokenPoolStartupGracePeriod fields as unknown, so the fragment is empty
// unless enabled. Callers pass every value explicitly; bb binaries expose
// process environment variables through std.extVar(), which is how
// token_scenario.sh drives scheduler_harness.jsonnet.
{
  schedulerFields(enabled, instanceNamePrefix, name, capacity, startupGracePeriod)::
    if enabled then {
      tokenPools: [{
        instanceNamePrefix: instanceNamePrefix,
        name: name,
        capacity: capacity,
      }],
      tokenPoolStartupGracePeriod: startupGracePeriod,
    } else {},
}
