# Phase 2 — The Protocol:: sweep

This phase removes about 470 lines from `lib/Protocol/` and its tests: the
copy-paste blocks in `Server.pm` and `Controller.pm`, the dead constants and
test-only accessors, the redundant validation, and the store fixes. It wires in
`validate_setup_code` (design decision 1). Phase 1 must land first — the
vocabulary gate guards the comments this phase edits.

Every task re-verifies its deletion with a grep before the code goes. A grep
that finds a caller stops the deletion and updates this plan.

## Tasks

### 2.1 Server.pm dedup

- Add three private helpers and replace their copies:
  `_char_status($aid, $iid, $code)` for the seven per-characteristic error
  blocks; `_resolve_char($aid, $iid)` for the duplicated accessory-then-
  characteristic lookup in the GET and PUT handlers; `_tlv_response($body)` for
  the seven `application/pairing+tlv8` response blocks.
- Replace the hand-built unknown-method error at `Server.pm:672-683` with
  `_pairings_error`, and fold the three copies of the admin check into one
  `_require_admin($session)`.
- Let `queue_event` resolve the characteristic value when the caller omits it,
  and delete the `_queue_change_event` wrapper.
- Delete the dead `$session->{timed_write}` capture in `_handle_prepare`; the
  repo's only mention of `timed_write` is that assignment. The 200/400 responses
  stay.
- Flatten `_handle_identify`: `{bridge}` is set unconditionally in
  `_initialize`, so the `if ($bridge)` branch cannot be false.
- Pass `status_text` at the one 470 call site and shrink `_response`; return a
  400 directly from `_serve_request` on a malformed request; drop the
  unreachable `// -1` on `last_paired_state`.

### 2.2 Controller.pm and Session.pm

- Hold a `Protocol::HAP::Session` with the key roles swapped and delegate
  `_encrypt`/`_decrypt` to it. Rework `_drain_frames` to consume only whole
  frames through the same path, then delete `_decrypt_peek`.
- Inline `_build_request` and `_parse_response` at their single call sites.
- Extract the error TLV before the separator split in `list_pairings`, so
  `_tlv_request` stays the one decoder of error responses.
- Move the test-harness defaults out of the library: the two integration tests
  pass `timeout` and `controller_id`; the `OPENHAP_TEST_TIMEOUT` fallback and
  the `openhap-test-ctrl` literal leave `Controller.pm`.
- Delete the two unread `my $result =` assignments, and the unreachable
  `return $data unless $self->{encrypted}` guards in `Session::encrypt` and
  `decrypt` — every call site already gates on the session state.

### 2.3 Pairing.pm and SRP.pm

- Delete the re-validation in `Pairing::new` of the setup code and store that
  `Server::new` proved three lines earlier. Users: `Server::_initialize`,
  `Server::_regenerate_identity`, and `t/protocol/pairing.t` (the store `die`
  subtest goes with the check).
- Fold the two auth-failure blocks into one `_auth_failure` helper, and the
  identical decode-and-check preambles of `handle_pair_setup` and
  `handle_pair_verify` into another.
- Keep one copy of the MAC-format rule: `Server::get_device_id` calls it;
  `Pairing::_get_accessory_pairing_id` goes.
- Delete the constants nothing references: `kTLVType_RetryDelay`,
  `kTLVType_Certificate`, `kTLVType_FragmentData`, `kTLVType_FragmentLast`, and
  the four referenced only by existence asserts in `t/protocol/pairing.t` (those
  asserts go too).
- Delete `get_failed_attempts`; its comment says "(for testing)". The tests read
  `{failed_auth_attempts}` directly.
- In `SRP.pm`: drop the Client's duplicate `N_LEN` and `_i2b`; drop the
  pre-declared `undef` state slots; drop the redundant parameters of
  `compute_verifier`; keep one accessor name for the session key (the
  specification's term wins) and rename the one caller of the other; drop the
  two `die` guards in `generate_server_proof` that only `t/protocol/srp.t`
  reaches, with those subtests.

### 2.4 The data model

- Delete `%FORMATS` and `%PERMISSIONS` from `Characteristic.pm`; nothing reads
  them, and `new` validates neither. The two conformance subtests that assert
  the tables contain their own entries go with them; both cite catalog sections
  that `t/conformance/hap-characteristics.t` still covers with data-driven rows.
- Delete `maxLen` and the `$include_value` parameter of `to_json`; no caller
  passes either.
- Keep one copy of `HAP_BASE_UUID` and `_uuid_to_short`, in `Protocol::HAP`, and
  point `Characteristic`, `Service`, and `Server.pm:944` at it.
- Replace the six boilerplate `Characteristic->new` blocks in `Accessory.pm`
  with a table and a loop; delete the empty `identify` hook that no subclass
  overrides.
- Lift the unconditional `require` calls in `Accessory`, `Bridge`, and `Service`
  to top-level `use` lines. `t/protocol/boundary.t` parses both forms, so the
  dependency rule keeps holding.

### 2.5 The stores

- Delete the shared lock from `Store::File::load_pairings` (design decision 12)
  and collapse the log-then-die pairs to `open ... or die` with `_reason`.
- Delete: the `path` accessor (no caller anywhere), the `/^\d+$/` re-validation
  of counters this module wrote itself, the `$data //= ''` fallback, and the
  `unlink` before `sysopen O_EXCL` that defeats the exclusivity check.
- Delete the defensive deep-copy in `Store::Memory::load_pairings`; no caller
  mutates the result. Drop the unread `%args` of `new`.

### 2.6 SetupCode and TLV

- Wire `validate_setup_code` into `bin/openhapd` beside the existing
  `normalize_setup_code` call: a configured code that validation rejects is a
  fatal config error. Update `openhapd.conf.5` with one sentence.
- Keep one definition of the separator type: `TLV::kTLVType_Separator` goes,
  `Pairing.pm` keeps its constant, and `encode_separator` moves its two test
  callers to `TLV::encode`.
- Delete `Imsg::_decode_header`; inline the `unpack` at its one call site.

### 2.7 Documentation and tests

- Update the `.pod` sidecars for every deleted public name: `Store/File.pod`,
  `Characteristic.pod`, `Pairing.pod`, `SRP.pod`, `TLV.pod`, `Controller.pod`,
  `SetupCode.pod`.
- Follow commit 0ae2b25 for every conformance subtest that leaves: name the spec
  citations it carried and the surviving subtest that still covers each.

## Deliverables

- Smaller
  `lib/Protocol/HAP/{Server,Controller,Session,Pairing,SRP, Characteristic,Service,Accessory,Bridge,SetupCode,TLV}.pm`,
  `Store/{File,Memory}.pm`, and `lib/Protocol/Imsg.pm`.
- `bin/openhapd` validates the configured setup code.
- Updated sidecars and `man/openhap/openhapd.conf.5`.
- Trimmed `t/protocol/` and `t/conformance/` files.

## Acceptance criteria

- `make check` passes; `make spec-coverage` reports no stale citation.
- `prove -l t/conformance/*.t` passes.
- `grep -rn 'timed_write\|%FORMATS\|%PERMISSIONS\|get_failed_attempts' lib t`
  finds nothing.
- `grep -rn 'encode_separator\|_decrypt_peek\|_queue_change_event' lib t` finds
  nothing.
- `grep -c '_uuid_to_short' lib -r` reports exactly one defining file.
- `openhapd -n` on a config with setup code `000-00-000` fails with a
  human-readable message; the same config with a valid code passes.
- Byte-level pairing behavior is unchanged: `t/conformance/hap-pairing.t` and
  `hap-encryption.t` pass without edits to their vectors.
