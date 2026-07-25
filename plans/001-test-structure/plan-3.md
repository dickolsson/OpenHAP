# Phase 3 — Conformance tier

Create `t/conformance/` mirroring the spec topic files (`design.md` Contract 3).
Depends on Phases 1–2 (convention + coverage tool to measure progress). This is
the largest phase; the sub-tasks are ordered by requirement density and can land
as separate commits.

Shared rules for every file in this phase:

- One `.t` per spec topic file, named after the lowercased stem.
- `Test::More` with `subtest`; every subtest name starts with a citation.
- Host-side, `skip_all` on missing CPAN dependencies (unit-test rule).
- Added to `make test` via `prove -l -v t/conformance/*.t`.
- Data tables and vectors live inline or under `t/conformance/data/` — no
  network, no `external/`.

## Tasks

### 3.1 `hap-tlv8.t` — wire format

- Replay the byte-exact examples from `HAP-TLV8.md §8` (M1 bytes, 384-byte
  fragmentation split `FF`/`81`).
- Assert the strict fragmentation rule (§2): every non-final fragment exactly
  255 bytes; round-trip and byte-level layout.
- Full pairing TLV type table (§5), methods (§6), error codes (§7) as a
  data-driven loop against `OpenHAP::TLV`/`OpenHAP::Pairing` constants.
- Parser rules (§10): unknown-type tolerance, malformed input rejection — decode
  tests with hand-built hostile buffers (currently absent everywhere).

### 3.2 `hap-pairing.t` — SRP, HKDF, state machines

- Known-answer vectors: HKDF-SHA-512 (RFC 5869-style), Ed25519 (RFC 8032),
  X25519 (RFC 7748) under §1; SRP group parameters and a fixed-value SRP
  exchange (RFC 5054 3072-bit group, deterministic a/b) under §2.
- All six HKDF salt/info string pairs (§4) and the four fixed nonces (§5)
  asserted against the implementation's constants.
- M1→M6 message shape table (§2.2–§2.8): TLV contents and sizes per message,
  driven through `OpenHAP::Pairing` with a scripted client side (full live
  exchange arrives in Phase 4; here sizes/fields/error codes are asserted).
- Error matrix: §2.4 (A mod N), §2.6/§2.8 (0x02 Authentication), §7.4 (pairings
  management errors), §8 (attempt limit 100, persistence).

### 3.3 `hap-encryption.t` — session framing

- Frame layout (§2): 2-byte LE length + ciphertext + 16-byte tag, AAD = length
  field, max plaintext 1024 — asserted on raw frame bytes, not round-trip.
- Nonce construction (§4): 4 zero bytes + 8-byte LE counter from 0, per
  direction; ChaCha20-Poly1305 known-answer vector (RFC 8439) under §7.
- Error handling table (§9): bad tag, oversize length, truncated frame.

### 3.4 `hap-http.t` — endpoints and status codes

- Endpoint/auth/content-type matrix (§1–§2) against `OpenHAP::HAP` request
  dispatch (in-process, no sockets).
- HAP status code table (§12) and HTTP tables (§13); 207 semantics (§9);
  `/identify` paired vs unpaired (§3); event message format `EVENT/1.0` (§14).

### 3.5 Catalog tables (data-driven)

- `hap-services.t`: §6 UUID table and §3/§4 required-characteristic rows — loop
  over a table, cite `[HAP-Services §4/<Name>]` per row; assert
  `OpenHAP::Service` resolution and short-form JSON encoding.
- `hap-characteristics.t`: §6 UUID table plus §5 rows (format, permissions,
  ranges) for every characteristic OpenHAP defines; §2 formats, §3 permissions,
  §4 units as constant checks.
- `hap-categories.t`: §1 identifier table; bridge ci=2 rule.
- `hap-mdns.t`: §2 required TXT keys, §3 field semantics (c# rules, sf flags,
  §3.9 setup-hash algorithm with a fixed SetupID/DeviceID vector), §4–§6 name
  and port rules. Migrate/absorb the TXT assertions now in `daemon.t`/`hap.t`.

### 3.6 `mqtt-*.t` — Tasmota conformance

- `mqtt-transport.t`, `mqtt-control.t`, `mqtt-state.t`, `mqtt-sensors.t`:
  restructure the protocol assertions of `t/openhap/tasmota.t` (~110, already
  the strongest in the suite) into the four spec-mirroring files with citations,
  extracting `MockMQTT` into `t/lib/OpenHAP/TestMock/MQTT.pm` so it is shared.
  `t/openhap/tasmota.t` keeps only module/API tests.
- Fill measured gaps per the Phase 2 `--uncovered` report (e.g. Backlog rules
  §2, PubSubClient rc table §4.2, STATE schema field-presence rules).

## Deliverables

- New: `t/conformance/*.t` (12 files), `t/lib/OpenHAP/TestMock/MQTT.pm`,
  optional `t/conformance/data/`.
- Modified: `Makefile` (`test` target), root `CLAUDE.md`, `t/CLAUDE.md` (tier
  description), slimmed `t/openhap/tasmota.t`, `daemon.t`, `hap.t`.

## Acceptance criteria

- `make check` passes; `make spec-coverage` exits 0.
- Coverage: every numbered section of `HAP-TLV8`, `HAP-Pairing`,
  `HAP-Encryption`, `HAP-HTTP`, `HAP-mDNS` is cited; catalog files ≥ the rows
  OpenHAP implements; overall coverage reported and recorded in the commit
  message.
- Crypto self-consistency tests in `t/openhap/crypto.t` are now backed by
  known-answer vectors in the conformance tier.
