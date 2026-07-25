# Phase 4 — HAP test controller

Build `OpenHAP::Test::Controller` (`design.md` Contract 4): a minimal HomeKit
controller able to complete pair-setup, pair-verify, and encrypted sessions.
Depends on Phase 3's known-answer vectors (they validate the crypto the
controller reuses). This phase is host-side only; the VM integration usage lands
in Phase 5.

## Tasks

### 4.1 Client-side SRP

- `lib/OpenHAP/Test/Controller/SRP.pm`: SRP-6a client role (a, A = g^a mod N, x
  = H(s | H(I:P)), u, S = (B − k·g^x)^(a+u·x), K = H(S), M1/M2 proofs) using the
  same 3072-bit group and padding rules as `OpenHAP::SRP` (`[HAP-Pairing §2]`).
  Reuse `OpenHAP::Crypto` primitives; Math::BigInt like the server side.
  Test-only namespace — not installed, excluded from the release tarball if
  `make build` globs `lib/OpenHAP/`.

### 4.2 Controller core

- `lib/OpenHAP/Test/Controller.pm` + `.pod` sidecar, per the interface in
  `design.md`:
  - `new(host, port, pin, transport?)` — `transport` is an optional code ref
    `($request_bytes) -> $response_bytes` enabling in-process use against
    `OpenHAP::HAP` without sockets; default is `IO::Socket::INET`.
  - `pair_setup` — M1→M6 over `POST /pair-setup` (`application/pairing+tlv8`),
    TLV via `OpenHAP::TLV`, Ed25519 device key generated once per controller,
    accessory LTPK stored on success; returns undef (bare `return`) on any
    protocol error, recording the TLV error code in `$c->last_error`.
  - `pair_verify` — X25519 handshake, HKDF session keys (`[HAP-Pairing §3]`),
    switches the connection to encrypted framing.
  - `request(method, path, body?, headers?)` — ChaCha20-Poly1305 framed HTTP/1.1
    (`[HAP-Encryption §2–§5]`), returns the `parse_http_response` hash shape.
  - `next_event(timeout)` — reads and decrypts until an `EVENT/1.0` message;
    returns parsed event or undef on timeout (uses `IO::Select`, no threads).
  - `add_pairing/remove_pairing/list_pairings` — `/pairings` TLV flows
    (`[HAP-Pairing §7]`).
- Error handling per repo rules: undef for protocol/IO errors, die for
  programming errors; never `eval` for flow control.

### 4.3 In-process full-exchange tests

- `t/conformance/hap-pairing-exchange.t`: wire the controller's in-process
  transport to an `OpenHAP::HAP` instance (temp storage dir) and assert, with
  citations:
  - full pair-setup M1–M6 success with the real PIN (`§2.2–§2.8`);
  - wrong PIN → M4 error 0x02 and attempt counter increment (`§2.6`, `§8`);
  - pair-verify success and key derivation (`§3`);
  - already-paired M2 error 0x06 (`§2.3`);
  - remove-pairing idempotence and last-admin behavior (`§7`).
- `t/conformance/hap-encryption-exchange.t`: over a verified in-process session,
  assert frame layout on the actual bytes both directions, counter increments
  per frame, tamper → connection-level failure (`§2–§5`, `§9`).
- Controller unit tests `t/openhap/test-controller.t`: constructor, transport
  injection, error paths (connection refused, malformed TLV), `last_error`.

### 4.4 Documentation

- `lib/OpenHAP/Test/Controller.pod`: full API, ENVIRONMENT, an example.
- `t/openhap/integration/CLAUDE.md`: mention the controller as the way to test
  paired behavior (usage arrives in Phase 5).

## Deliverables

- New: `lib/OpenHAP/Test/Controller.pm` + `.pod`,
  `lib/OpenHAP/Test/Controller/SRP.pm` + `.pod`,
  `t/conformance/hap-pairing-exchange.t`,
  `t/conformance/hap-encryption-exchange.t`, `t/openhap/test-controller.t`.
- Modified: `t/openhap/integration/CLAUDE.md`, possibly `Makefile`/`build`
  packaging excludes.

## Acceptance criteria

- `make check` passes; new modules pass `make lint` severity 4.
- The in-process exchange test completes real SRP M1–M6 and pair-verify with no
  mocked crypto — the accessory ends the test actually paired.
- `make spec-coverage`: `HAP-Pairing §2.*`, `§3.*`, `§7.*`, `§8` and
  `HAP-Encryption §1–§6` all cited by exchange tests.
- No production module depends on anything under `OpenHAP::Test::`.
