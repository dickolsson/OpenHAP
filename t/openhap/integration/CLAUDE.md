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

Testing anything behind pair-verify (authenticated endpoints, events, encrypted
framing) goes through `Protocol::HAP::Controller` (API in
`lib/Protocol/HAP/Controller.pod`): complete `pair_setup`/`pair_verify` in
setup, use `request`/`next_event`, and `remove_pairing` in teardown so the
shared daemon is never left paired between files.

## Ordering and state

- `scripts/integration` runs the files as an explicit ordered list with
  `environment.t` always first.
- Files own their pairing lifecycle: call `$env->ensure_unpaired` in setup, pair
  via the controller if needed, and unpair in teardown. The shared daemon is
  never left paired between files.
- `lib/OpenHAP/Test/` and `t/lib/` ship to the VM alongside the tests; `prove`
  runs with `-It/lib`.

## Running the suite

`make integration` provisions the VM, installs the current tree, and runs every
file. To iterate on one file without re-provisioning:

```sh
bin/fuguvm ssh 'cd /tmp && export OPENHAP_INTEGRATION_TEST=1 && \
    prove -I/usr/local/libdata/perl5/site_perl -v t/openhap/integration/daemon.t'
```

On an OpenBSD host with OpenHAP installed, skip the VM entirely:
`OPENHAP_INTEGRATION_TEST=1 prove -l -v t/openhap/integration/`.

## Debugging failures

```sh
bin/fuguvm ssh 'rcctl check openhapd && echo running || echo stopped'
bin/fuguvm ssh 'tail -50 /var/log/daemon | grep openhapd'
bin/fuguvm ssh 'hapctl -c /etc/openhapd.conf check'
```

Usual causes, in order of likelihood:

- `OPENHAP_INTEGRATION_TEST` not exported.
- The daemon will not start — check `/etc/openhapd.conf` validity, that the
  `_openhap` user exists, and `/var/db/openhapd` permissions.
- MQTT failures — mosquitto not installed or not started
  (`rcctl start mosquitto`).
- mDNS failures — mdnsd not installed, not started, or its flags name a
  nonexistent interface (the openmdns package defaults to `em0`, and mdnsd exits
  fatally on an unknown interface). `rcctl enable mdnsd` before setting flags;
  rcctl refuses to set flags on a disabled daemon. The helpers emit captured
  rcctl and syslog diagnostics when mdnsd will not stay up.

## References

- Test helper API: `lib/OpenHAP/Test/Integration.pod`,
  `lib/Protocol/HAP/Controller.pod`
- VM lifecycle: `fuguvm` skill
