# Phase 1 — Foundation: pure codecs and primitives

This phase creates the `Protocol::HAP` namespace and moves the modules with no
protocol state: `TLV`, `PIN`, `Crypto`, and `SRP`. It shrinks `FuguLib::Crypto`
to `FuguLib::Random`. It adds the `t/protocol/` tier and the boundary test that
enforces the dependency rules for every later phase.

## Tasks

### 1.1 Protocol::HAP umbrella module

- Create `lib/Protocol/HAP.pm`: the namespace overview comment and the null
  logger package (`Protocol::HAP::Log::Null`) with no-op `debug`, `info`,
  `warning`, and `error` methods. Multiple packages in one file follow the style
  rules.
- Create the `Protocol/HAP.pod` sidecar: what the library is, the host contracts
  at a glance, and pointers to the per-module pods.
- No `$VERSION`. Version policy is release work; record it in `TODO.md` under a
  new "Protocol::HAP CPAN release" section, with PAUSE registration and the
  `spec/` redistribution-license review.

### 1.2 Move OpenHAP::TLV to Protocol::HAP::TLV

- `git mv`, rename the package, keep the code as is: the module is already pure.
- Update the users: `OpenHAP::Pairing`, `OpenHAP::HAP`,
  `OpenHAP::Test::Controller`, and the tests.
- Move `t/openhap/tlv.t` to `t/protocol/tlv.t`. Retarget the imports in
  `t/conformance/hap-tlv8.t`.
- Move the `.pod` sidecar with the module.

### 1.3 Move OpenHAP::PIN to Protocol::HAP::PIN

- Same procedure. Users: `OpenHAP::SRP`, `OpenHAP::Pairing`, `OpenHAP::HAP`,
  `OpenHAP::Test::Controller::SRP`.
- Move `t/openhap/pin.t` to `t/protocol/pin.t`.

### 1.4 Split FuguLib::Crypto

- Create `Protocol::HAP::Crypto` from `FuguLib::Crypto`: `random_bytes`, the
  Ed25519, X25519, HKDF, and AEAD groups, the lazy `_load`, and `preload`.
- Shrink `FuguLib::Crypto` to `FuguLib::Random`: `random_bytes` and
  `random_password` only. Rename the file, the package, and the test.
- Update the users: `OpenHAP::SRP`, `Session`, `Pairing`, `HAP`,
  `Test::Controller`, `Test::Controller::SRP` use `Protocol::HAP::Crypto`;
  `FuguVM::VM` uses `FuguLib::Random`; `bin/openhapd` preloads
  `Protocol::HAP::Crypto` before it pledges.
- Split `t/fugulib/crypto.t`: the randomness subtests become
  `t/fugulib/random.t`; the algorithm and known-answer subtests become
  `t/protocol/crypto.t`.
- Replace `man/fugulib/Crypto.3p` with `man/fugulib/Random.3p`, rewritten for
  the shrunk module. Update `MAN3P` in the `Makefile`, the `.Xr`
  cross-references in the other 3p pages, `web/fugulib.body.html`, and any
  page-name assertion in `t/web/site.t`.
- Write the `Protocol/HAP/Crypto.pod` sidecar.

### 1.5 Move OpenHAP::SRP to Protocol::HAP::SRP

- `git mv`, rename the package and its imports (`Protocol::HAP::Crypto`,
  `Protocol::HAP::PIN`).
- Update the users: `OpenHAP::Pairing`, `OpenHAP::Test::Controller::SRP`.
- Move `t/openhap/srp.t` and `t/openhap/srp_padding.t` to `t/protocol/`.
- The controller role joins this module in phase 5, not now.

### 1.6 The t/protocol/ tier and the boundary test

- Add `prove -l -v t/protocol/*.t` to the `Makefile` test target, after the
  `t/fugulib` line.
- Add the tier row to the table in `t/CLAUDE.md`.
- Write `t/protocol/boundary.t`. It parses `use` and `require` lines under
  `lib/Protocol/` and fails on: any `FuguLib::`, `FuguVM::`, or `OpenHAP::`
  module; any non-core module outside the declared list (`Crypt::Ed25519`,
  `Crypt::Curve25519`, `Crypt::KeyDerivation`,
  `Crypt::AuthEnc::ChaCha20Poly1305`). It also fails on `FuguLib::` lines that
  name `Protocol::HAP` or `OpenHAP`, in both directions of the rule.
- Update the Layout section of the root `CLAUDE.md`: add `lib/Protocol/` and the
  `t/protocol/` tier, and correct the stale `lib/OpenHAP/` module list.

## Deliverables

- `lib/Protocol/HAP.pm`, `TLV.pm`, `PIN.pm`, `Crypto.pm`, `SRP.pm`, each with a
  `.pod` sidecar.
- `lib/FuguLib/Random.pm` and `man/fugulib/Random.3p`.
- `t/protocol/` with `boundary.t`, `tlv.t`, `pin.t`, `crypto.t`, `srp.t`,
  `srp_padding.t`; `t/fugulib/random.t`.
- Updated `Makefile`, root `CLAUDE.md`, `t/CLAUDE.md`, `TODO.md`,
  `web/fugulib.body.html`.

## Acceptance criteria

- `make check` passes.
- `grep -r 'OpenHAP::TLV\|OpenHAP::PIN\|OpenHAP::SRP\|FuguLib::Crypto' lib bin t`
  finds nothing.
- `t/protocol/boundary.t` passes and fails correctly when given a planted
  violation (prove the failure mode once, manually, before commit).
- `make spec-coverage` reports no stale citations.
