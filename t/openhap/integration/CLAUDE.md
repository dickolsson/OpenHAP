# t/openhap/integration/

Applies when working on files under `t/openhap/integration/`. These tests run
inside the OpenBSD VM (or on an OpenBSD host), not as part of `make test`.

## Philosophy

Integration tests verify actual functionality end-to-end, without workarounds:

- Test real interfaces: HTTP endpoints, sockets, commands
- Verify complete data flows (request → processing → response)
- Use production tools: `hapctl`, `rcctl`, actual HAP clients
- Never parse logs to assert behavior
- **Never use SKIP blocks** — tests must fail if the environment is not ready
  (this deliberately differs from the unit-test skip rule in the root CLAUDE.md)
- Proper setup ensures the environment is ready; proper teardown leaves a clean
  state

## Prerequisites

A provisioned OpenBSD installation as described in the ENVIRONMENT section of
`lib/OpenHAP/Test/Integration.pod`, plus mosquitto (MQTT tests) and mdnsd (mDNS
tests).

## Writing a new test

Each file covers one functional area with no overlap between files. Start from
this skeleton and use the `OpenHAP::Test::Integration` helpers (API in
`lib/OpenHAP/Test/Integration.pod`):

```perl
#!/usr/bin/env perl
use v5.36;
use Test::More;
use FindBin qw($RealBin);
use lib "$RealBin/../../../lib";

use OpenHAP::Test::Integration;

my $env = OpenHAP::Test::Integration->new;
$env->setup;

my $response = $env->http_request('GET', '/accessories');
ok(defined $response, 'got response');

$env->teardown;
done_testing();
```

## Paired behavior

Testing anything behind pair-verify (authenticated endpoints, events,
encrypted framing) goes through `OpenHAP::Test::Controller` (API in
`lib/OpenHAP/Test/Controller.pod`): complete `pair_setup`/`pair_verify`
in setup, use `request`/`next_event`, and `remove_pairing` in teardown so
the shared daemon is never left paired between files.

## Ordering and state

- `scripts/integration.sh` runs the files as an explicit ordered list
  with `environment.t` always first.
- Files own their pairing lifecycle: call `$env->ensure_unpaired` in
  setup, pair via the controller if needed, and unpair in teardown. The
  shared daemon is never left paired between files.
- `lib/OpenHAP/Test/` and `t/lib/` ship to the VM alongside the tests;
  `prove` runs with `-It/lib`.

## References

- Running and debugging the suite: `integration-tests` skill
- VM lifecycle: `openhvf` skill
