// Second worker for token_scenario.sh: worker.jsonnet with the knobs that
// distinguish it from the default worker read from the environment. It runs
// from its own working directory (the paths in worker.jsonnet are relative),
// so only the listen port, the platform and the concurrency need overriding.
//
//   WORKER_DIAG_PORT    e.g. '9988'
//   WORKER_POOL         value of the 'pool' platform property; '' for none
//   WORKER_CONCURRENCY  integer as a string
//   WORKER_HOSTNAME     workerId.hostname, so the two workers are telling apart
local common = import 'common.libsonnet';
local base = import 'worker.jsonnet';
local pool = std.extVar('WORKER_POOL');

base {
  global: common.globalWithDiagnosticsHttpServer(':' + std.extVar('WORKER_DIAG_PORT')),
  buildDirectories: [
    bd {
      runners: [
        r {
          concurrency: std.parseInt(std.extVar('WORKER_CONCURRENCY')),
          platform: if pool == '' then {} else { properties: [{ name: 'pool', value: pool }] },
          workerId+: { hostname: std.extVar('WORKER_HOSTNAME') },
        }
        for r in bd.runners
      ],
    }
    for bd in base.buildDirectories
  ],
}
