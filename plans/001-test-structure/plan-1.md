# Phase 1 — Hygiene and conventions

Prerequisite for all later phases: make the existing suite honest, run
everything that exists, and establish the citation convention that phases 2–5
build on. No new test tiers yet.

## Tasks

### 1.1 Wire `t/fugulib` into `make test`

- Add `prove -l -v t/fugulib/*.t` to the `test` target in `Makefile`.
- Update the command comment in the root `CLAUDE.md`.
- Fix any failures this exposes (the files have never run in CI).

### 1.2 Remove vacuous and dead tests

- `t/openhap/device-loading.t`: tests 3–6 assert properties of local hash
  literals. Rewrite to load real device modules through `OpenHAP::DeviceLoader`
  and assert observable behavior, or delete the file.
- `t/openhap/srp_padding.t`: the K1/K2 block computes values and asserts nothing
  — add the missing assertions.
- `t/openhap/integration/configuration.t`, `hapctl.t`, `accessories.t`: replace
  `ok(1, ...)` placeholders and always-true expressions (`$x != 0 || 1`) with
  real assertions or remove them.
- `t/openhap/integration/tasmota-protocol.t`: the `$..._received` flags are
  captured but never asserted — assert them (the plumbing exists). Tests that
  cannot assert anything until Phase 5 are removed, not stubbed with `ok(1)`.

### 1.3 Fix integration-rule violations

Per `t/openhap/integration/CLAUDE.md` (no SKIP, no log parsing):

- `tasmota-protocol.t`, `mdns.t`, `mdns-cleanup.t`: remove SKIP blocks; make
  missing prerequisites (mdnsctl, broker, devices) hard failures with clear
  diagnostics, matching `mqtt.t`'s existing die-on-missing pattern.
- `mdns.t`: replace `get_log_lines` assertions with `mdnsctl browse`-based
  checks.
- `scripts/integration.sh`: make `environment.t` run first under `prove` too
  (pass an explicit file list), not only in the shell fallback.

### 1.4 Minor rule fixes

- `t/openhap/config.t`: write its temp config under a `File::Temp` directory
  instead of `/tmp` (repo rule: never use `/tmp`).

### 1.5 Establish the citation convention

- Create `t/CLAUDE.md` documenting the citation format from `design.md`
  (Contract 1): the `[<spec-stem> §<section>]` prefix, the `/<row>` form for
  table rows, when a citation is required (any assertion of spec-defined
  behavior), and the rule that spec citations replace audit "Finding N"
  references.
- Convert the existing references as a proof of convention:
  - `srp_padding.t` comment citations → citation-prefixed test names.
  - "Finding N" comments in `pairing.t`, `hap.t`, `storage.t`, integration
    `pairing.t` → spec citations (e.g. Finding 1 → `[HAP-Pairing §2.5]` A mod N
    check).
  - `pin.t`/`daemon.t` "per HAP spec" → concrete citations (`[HAP §5]` setup
    code format, `[HAP-mDNS §2]` TXT keys).
  - Compliance IDs (C1…L3) in `tasmota.t` → `[MQTT-* §N.M]` citations.

## Deliverables

- Modified: `Makefile`, `CLAUDE.md`, `scripts/integration.sh`, the test files
  listed above.
- New: `t/CLAUDE.md`.

## Acceptance criteria

- `make check` passes and now runs `t/fugulib`.
- `grep -rn 'ok(1' t/` returns no placeholder assertions.
- `grep -rn 'Finding [0-9]' t/` returns nothing.
- No SKIP blocks remain under `t/openhap/integration/`.
- `grep -rEn '\[(HAP|MQTT)[A-Za-z-]* §' t/` finds citations in at least
  `srp_padding.t`, `pairing.t`, `pin.t`, `daemon.t`, `tasmota.t`.
