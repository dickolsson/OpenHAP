# t/

Applies when working on files under `t/`.

## Test tiers

| Tier        | Location                      | Verifies                                       | Runs via           |
| ----------- | ----------------------------- | ---------------------------------------------- | ------------------ |
| Conformance | `t/conformance/`              | spec requirements, wire formats, KAT           | `make test` (host) |
| Module      | `t/openhap/` `t/fugu/`        | Perl API behavior, error paths                 | `make test` (host) |
| Module      | `t/protocol/`                 | the Protocol:: libraries, dependency boundary  | `make test` (host) |
| Module      | `t/fuguvm/`                   | the OpenBSD VM utility                         | `make test` (host) |
| Tooling     | `t/scripts/` `t/web/` `t/ci/` | what `scripts/`, `web/` and `.github/` produce | `make test` (host) |
| Integration | `t/openhap/integration/`      | real daemon, full protocol flow                | `make integration` |

Module tests follow the unit-test rules in the root `CLAUDE.md` (skip gracefully
on missing dependencies) and need no citations. Integration tests follow the
stricter rules in `t/openhap/integration/CLAUDE.md` (never skip, no log
parsing).

One module test crosses tiers: `scripts/integration` ships `t/fugu/sandbox.t`
into the VM and proves it with the integration files, because its enforcement
subtests (pledge aborts, unveil hides the filesystem) are OpenBSD-only and would
otherwise never run in CI — `make check` runs on Linux, where they skip.

Tooling tests are named after what they cover — `t/scripts/deps.t` for
`scripts/deps` — and drive it as a subprocess rather than loading a module, so
they assert on exit status and output. `t/scripts/conventions.t` covers the
directory as a whole: exec bits, shebangs, and that every Perl script compiles.

`t/ci/` is the exception to driving anything: nothing under `.github/` runs
outside a runner, so these tests read the workflows and composite actions as
text and assert the invariants that only fail in CI — that every consumer of an
action passes it a value the action accepts, and that a cache key hashes every
input which decides what it caches.

## Conformance tier

One `.t` per normative spec topic file, named after the lowercased stem
(`spec/HAP-TLV8.md` ↔ `t/conformance/hap-tlv8.t`, `spec/MDNS-Imsg.md` ↔
`t/conformance/mdns-imsg.t`). Rules:

- Every subtest name starts with a citation; catalog tables are data-driven
  loops citing `/<row>`; wire examples from the spec are replayed byte-exactly;
  crypto known-answer vectors live under the algorithm sections.
- Host-side, `Test::More` + `subtest`, `skip_all` on missing CPAN dependencies.
- Data tables and vectors live inline — no network, no external checkouts.
- Shared mocks live in `t/lib/` (e.g. `App::OpenHAP::TestMock::MQTT`), loaded
  with `use lib "$RealBin/../lib"`.
- The index files (`HAP.md`, `MQTT.md`) and `IMPLEMENTATIONS.md` get no test
  file; their few normative facts are covered by topic files.

## Spec citations

Any assertion of behavior defined by the protocol references in `spec/` must
carry a machine-parseable citation as a prefix of its subtest name or assertion
description:

```
[<spec-stem> §<section>] <free text>
[<spec-stem> §<section>/<row>] <free text>      # unnumbered table rows
```

- `<spec-stem>` is the spec file name without `spec/` and `.md`, e.g.
  `HAP-Pairing` for `spec/HAP-Pairing.md`.
- `<section>` is a numbered `##`/`###` heading anchor, e.g. `2.6` or `8`.
- The `/<row>` form points into an unnumbered table row, e.g.
  `[HAP-Characteristics §5/Brightness]`.

Examples:

```perl
ok($error == 0x02, '[HAP-Pairing §2.6] M4 returns kTLVError_Authentication');
subtest '[HAP-TLV8 §2] fragmentation' => sub { ... };
```

The grep pattern is `\[(HAP|MQTT|MDNS)[A-Za-z0-9-]* §[0-9][0-9.]*(/[^\]]+)?\]`.
One test may carry several citations. A citation asserts the section's
requirement — do not cite a section the test merely mentions.

Coverage of `spec/` and stale-citation detection are computed by
`make spec-coverage` (`scripts/spec-coverage`).

Cite spec sections, never audit findings ("Finding N") or compliance IDs: audit
scratchpads are gitignored and ephemeral, so the spec is the only durable
anchor.
