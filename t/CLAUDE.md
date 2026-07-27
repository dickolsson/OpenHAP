# t/

Applies when working on files under `t/`.

## Test tiers

| Tier        | Location                  | Verifies                             | Runs via           |
| ----------- | ------------------------- | ------------------------------------ | ------------------ |
| Conformance | `t/conformance/`          | spec requirements, wire formats, KAT | `make test` (host) |
| Module      | `t/openhap/` `t/fugulib/` | Perl API behavior, error paths       | `make test` (host) |
| Module      | `t/openhvf/`              | the OpenBSD VM utility               | `make test` (host) |
| Integration | `t/openhap/integration/`  | real daemon, full protocol flow      | `make integration` |

Module tests follow the unit-test rules in the root `CLAUDE.md` (skip gracefully
on missing dependencies) and need no citations. Integration tests follow the
stricter rules in `t/openhap/integration/CLAUDE.md` (never skip, no log
parsing).

## Conformance tier

One `.t` per normative spec topic file, named after the lowercased stem
(`spec/HAP-TLV8.md` ↔ `t/conformance/hap-tlv8.t`). Rules:

- Every subtest name starts with a citation; catalog tables are data-driven
  loops citing `/<row>`; wire examples from the spec are replayed byte-exactly;
  crypto known-answer vectors live under the algorithm sections.
- Host-side, `Test::More` + `subtest`, `skip_all` on missing CPAN dependencies.
- Data tables and vectors live inline — no network, no `external/`.
- Shared mocks live in `t/lib/` (e.g. `OpenHAP::TestMock::MQTT`), loaded with
  `use lib "$RealBin/../lib"`.
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

The grep pattern is `\[(HAP|MQTT)[A-Za-z0-9-]* §[0-9][0-9.]*(/[^\]]+)?\]`. One
test may carry several citations. A citation asserts the section's requirement —
do not cite a section the test merely mentions.

Coverage of `spec/` and stale-citation detection are computed by
`make spec-coverage` (`scripts/spec-coverage`).

Spec citations replace references to audit findings ("Finding N") and compliance
IDs: audit scratchpads are gitignored and ephemeral, so tests must cite the spec
sections directly.
