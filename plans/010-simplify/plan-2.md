# Phase 2 — The Protocol:: sweep

This phase removes about 350 lines from `lib/Protocol/` and its tests: the
copy-paste blocks in `Server.pm` and `Controller.pm`, the dead constants, the
redundant wrappers, and the store lock. It executes decisions 1, 12, 15, and 18.
Phase 1 must land first.

Every task re-verifies its deletion with a grep before the code goes. A grep
that finds a caller stops the deletion and updates this plan — the review
already moved `get_failed_attempts`, the `Session` guards, and the
`Pairing::new` validation to the design's verified-keeps list this way.

## Tasks

### 2.1 Server.pm dedup

- Add three private helpers and replace their copies:
  `_char_status($aid, $iid, $code)` for the seven per-characteristic error
  blocks; `_resolve_char($aid, $iid)` for the duplicated
  accessory-then-characteristic lookup in the GET and PUT handlers;
  `_tlv_response($body)` for the seven `application/pairing+tlv8` response
  blocks.
- Replace the hand-built unknown-method error at `Server.pm:672-683` with
  `_pairings_error`, and fold the three copies of the admin check into one
  `_require_admin($session)`.
- Let `queue_event` resolve the characteristic value when the caller omits it,
  and delete the `_queue_change_event` wrapper.
- Delete the dead `$session->{timed_write}` capture in `_handle_prepare`; the
  repo's only mention of `timed_write` is that assignment. The 200/400 responses
  stay, and the malformed-request fallback at `:263-267` stays as it is — it
  routes through the same encrypted tail as every response.
- Flatten `_handle_identify`: `{bridge}` is set unconditionally in
  `_initialize`, so the `if ($bridge)` branch cannot be false. This also deletes
  the comment whose "blink an LED" wording the phase-4 grep matches.
- Pass `status_text` at the one 470 call site and shrink `_response`; drop the
  unreachable `// -1` on `last_paired_state`.
- Keep the `Host::listen`-side contract in mind: `Server` state set in
  `_initialize` is relied on by forked conformance tests; delete nothing that
  `t/conformance/hap-pairing-exchange.t` exercises across its fork.

### 2.2 Controller.pm and Session.pm

- Hold a `Protocol::HAP::Session` with the key roles swapped and delegate
  `_encrypt`/`_decrypt` framing to it, so the frame codec exists once.
- Rework the read path: `_round_trip`'s accumulate loop currently re-decrypts
  the whole buffer via `_decrypt_peek` on every read. Buffer until the 2-byte
  length header shows a whole frame, decrypt each frame exactly once through the
  session, then delete `_decrypt_peek`. This is a rewrite of the accumulation
  loop, not a drop-in: `Session::decrypt` advances its counter per consumed
  frame and has no peek mode. `_drain_frames` then reuses the same one-frame
  step.
- Inline `_build_request` and `_parse_response` at their single call sites.
- Extract the error TLV before the separator split in `list_pairings`, so
  `_tlv_request` stays the one decoder of error responses.
- Decision 18: `controller_id` becomes a required argument (die without it); the
  `OPENHAP_TEST_TIMEOUT` fallback leaves the library; the `timeout // 5` default
  stays. Users to update, verified:
  `lib/App/OpenHAP/Test/Integration.pm:138-144` (passes `controller_id` and
  `timeout => $ENV{OPENHAP_TEST_TIMEOUT} // 30`),
  `t/conformance/hap-pairing-exchange.t`,
  `t/conformance/hap-encryption-exchange.t`, `t/protocol/controller.t`, and
  `t/protocol/server.t`. The `Integration.pm` edit is minimal here; phase 4
  rewrites the harness later.
- Delete the two unread `my $result =` assignments in `add_pairing` and
  `remove_pairing`.

### 2.3 Pairing.pm and SRP.pm

- Fold the two auth-failure blocks into one `_auth_failure` helper, and the
  identical decode-and-check preambles of `handle_pair_setup` and
  `handle_pair_verify` into another.
- Keep one copy of the MAC-format rule: `Server::get_device_id` calls it;
  `Pairing::_get_accessory_pairing_id` goes.
- Delete the constants nothing references: `kTLVType_RetryDelay`,
  `kTLVType_Certificate`, `kTLVType_FragmentData`, `kTLVType_FragmentLast`, and
  the four referenced only by existence asserts in `t/protocol/pairing.t` (those
  asserts go too).
- In `SRP.pm`: drop the Client's duplicate `N_LEN` and `_i2b`; drop the
  pre-declared `undef` state slots; drop the redundant parameters of
  `compute_verifier`; keep one accessor name for the session key and update the
  one caller of the other; drop the two `die` guards in `generate_server_proof`
  that only `t/protocol/srp.t` reaches, with those subtests.

### 2.4 The data model

- Delete `%FORMATS` and `%PERMISSIONS` from `Characteristic.pm`; nothing reads
  them and `new` validates neither. Decision 15 applies: their two subtests
  carry the only `[HAP-Characteristics §2]` and `[§3]` citations in the tree, so
  re-home both onto the data-driven catalog subtest — it already asserts each
  row's format and permissions strings — before the tables go. Attach the
  coverage-matrix diff.
- Delete `maxLen` and the `$include_value` parameter of `to_json`; no caller
  passes either.
- Keep one copy of the short-UUID rule: a documented public `uuid_to_short` in
  `Protocol::HAP` (with a `HAP.pod` entry), used by `Characteristic`, `Service`,
  and `Server.pm:944`. A private sub there would have no same-file caller and a
  cross-package `_` name is a poor CPAN contract.
- Replace the six boilerplate `Characteristic->new` blocks in `Accessory.pm`
  with a table and a loop; delete the empty `identify` hook that no subclass
  overrides, and the Identify characteristic's `on_set` call into it.
- Lift the unconditional `require` calls in `Accessory`, `Bridge`, and `Service`
  to top-level `use` lines; `t/protocol/boundary.t` parses both forms.

### 2.5 The stores

- Decision 12: delete the shared lock from `Store::File::load_pairings`, and
  with it the `flock` promise and its comment in `bin/openhapd` (`:301`, `:311`)
  — the only post-pledge `flock` callers are these two lines; `Fugu::Pidfile`'s
  lock happens before the pledge. Collapse the log-then-die pairs to
  `open ... or die` with `_reason`.
- Delete the `path` accessor and its one subtest (`t/protocol/store-file.t:29`),
  and the unread `%args` of `Store::Memory::new`.
- Keep, per the design: the `/^\d+$/` counter guards (sole type checks on
  `state.json` values; `get_auth_attempts` feeds the lockout), the `O_EXCL`
  pre-unlink (crash recovery for a recycled pid), the `$data //= ''` line goes
  only if a fresh grep shows both callers pass defined strings — it did at audit
  time.
- Delete the deep copy in `Store::Memory::load_pairings` only if
  `Store/Memory.pod:24-25` changes in the same commit — the copy is a documented
  contract. Otherwise keep both. Prefer keeping both; the saving is three lines.

### 2.6 SetupCode, TLV, Imsg

- Decision 1: `bin/openhapd` calls `validate_setup_code` in place of
  `normalize_setup_code` — it normalizes internally, so the boundary validates
  once. A rejected code is a fatal config error before daemonize. Update
  `openhapd.conf.5` with one sentence.
- Keep one definition of the separator type: `TLV::kTLVType_Separator` goes,
  `Pairing.pm` keeps its constant, and `encode_separator` moves its two test
  callers to `TLV::encode`.
- Delete `Imsg::_decode_header`; inline the `unpack` at its one call site.

### 2.7 Documentation and tests

- Update the sidecars for every deleted or changed public name:
  `Store/File.pod`, `Characteristic.pod`, `SRP.pod`, `TLV.pod`, `Controller.pod`
  (the `controller_id` contract), `SetupCode.pod`, `HAP.pod` (the new
  `uuid_to_short`).
- Follow commit 0ae2b25 for every conformance subtest that leaves or moves: name
  the citations and where each lands, per decision 15.

## Deliverables

- Smaller
  `lib/Protocol/HAP/{Server,Controller,Session,Pairing,SRP, Characteristic,Service,Accessory,Bridge,SetupCode,TLV}.pm`,
  `Store/{File,Memory}.pm`, and `lib/Protocol/Imsg.pm`.
- `bin/openhapd`: setup-code validation wired, `flock` promise gone.
- Updated sidecars and `man/openhap/openhapd.conf.5`.
- Trimmed `t/protocol/` and `t/conformance/` files, plus the `Integration.pm`
  constructor-argument edit.

## Acceptance criteria

- `make check` passes; `prove -l t/conformance/*.t` passes.
- `scripts/spec-coverage` (without `--quiet`) shows the same per-file section
  counts as before the phase; the §2/§3 citations moved, not vanished. The diff
  is attached to the commit.
- `git grep -n 'timed_write\|_decrypt_peek\|_queue_change_event\|encode_separator' lib t`
  finds nothing.
- `git grep -n 'FORMATS\|PERMISSIONS' lib t` finds nothing — the conformance
  test spells them `$Protocol::HAP::Characteristic::FORMATS`, so the pattern
  must not require the `%` sigil.
- `git grep -n 'sub uuid_to_short' lib` reports exactly one definition, in
  `lib/Protocol/HAP.pm`.
- `git grep -n 'flock' bin/openhapd` finds nothing, and
  `git grep -n 'flock' lib/Protocol` finds nothing.
- `openhapd -n` on a config with setup code `000-00-000` fails with a
  human-readable message; the same config with a valid code passes.
- Byte-level pairing behavior is unchanged: `hap-pairing.t`,
  `hap-pairing-exchange.t`, `hap-encryption.t`, and `hap-encryption-exchange.t`
  pass, with their only edits being explicit `controller_id`/`timeout`
  arguments.
