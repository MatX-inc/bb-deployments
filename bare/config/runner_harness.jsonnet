// Runner for the second worker of token_scenario.sh: runner.jsonnet with the
// diagnostics port read from RUNNER_DIAG_PORT. The build directory and the
// listen socket are relative to the working directory, which the script sets
// to the second worker's own tree.
local common = import 'common.libsonnet';
local base = import 'runner.jsonnet';

base {
  global: common.globalWithDiagnosticsHttpServer(':' + std.extVar('RUNNER_DIAG_PORT')),
}
