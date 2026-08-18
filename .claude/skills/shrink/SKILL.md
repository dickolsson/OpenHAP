---
name: shrink
description:
  Hunt for code bloat and remove it safely. Use when asked to shrink, audit for
  dead code, or remove unused API, options, or duplication from the tree.
---

# Shrink

## Objective

Find bloat, prove each finding, and delete the code with its tests and
documentation. See `plans/010-simplify/design.md` for the background.

## The six shapes of creep

1. Test-only API — `Fugu::Process` had `check_alive`; only tests called it.
2. Unreachable option — Tasmota had `fulltopic`; no constructor could pass it.
3. Documentation–code drift — `openhapd.conf.5` listed six thermostat options
   that no code read.
4. Multi-layer validation — `App::FuguVM::CLI` validated one timeout three
   times.
5. Copy-paste blocks — the ChaCha20 frame loop existed three times.
6. Refactor leftovers — the QGA subsystem stayed after its last caller left.

## The procedure

1. Grep `lib/ bin/ t/` for callers before every deletion. An audit claim is
   input, not proof.
2. Check `t/conformance/` for spec citations on the code. A citation may drop
   only when its behavior leaves the tree. Diff the `scripts/spec-coverage`
   matrix before and after, and list each dropped citation in the commit
   message.
3. Delete code, test, and documentation together. Leave no orphaned `.pod`
   section, no `.3p` entry for a deleted method, no test of a deleted layer.
4. Run `make check`.
5. Commit as `refactor`, with `!` when observable behavior changes.

## The keep list

Deletion must not touch:

- Checks on external input: HAP wire data, MQTT payloads, config files,
  control-socket messages, and state files read back from disk. Fail closed.
- Behavior a conformance test asserts with a spec citation, unless the citation
  is accounted for as step 2 describes.
- The deliberate duplication across the CPAN boundary: `Protocol::` stays
  self-contained.
- The OpenBSD/Linux/Darwin split; `plan skip_all` in module tests; the
  never-skip rule in integration tests.
- Both store implementations, the sans-IO engine, and the store contract.

## Cautionary examples

A cold review refuted these audit claims. Each looked dead and was not. Grep
found the truth; keep these in mind before you trust a "no callers" claim:

- `get_failed_attempts` — eight test callers, two with conformance citations.
- The nine `IMSG_*` constants — the Fugu repository’s `mdns-control.t` pins the
  positional enum.
- The `Host::listen` memoization — a conformance test forks after binding port
  0, and the guard keeps the child on the parent's port.
- The `Session` pass-through guards — `hap-encryption.t` asserts them.
- `Pairing::new` validation — the sidecar's SYNOPSIS depends on it.
- `Store::Memory`'s deep copy — a documented contract.
- The `Privdrop` pre-check — a distinct diagnostic.
- Both `hapctl uptime` checks — shape and future-timestamp are different faults.
- `Control`'s `MAX_REPLY` bound and encode `eval` — a blocking write and an
  else-unanswered request.
- The `Devices.pm` eval — it guards `require` of config-named classes after
  daemonize.
- The `EventLoop` `fileno` guard — a callback can close a sibling handle
  mid-pass.
- `Miniroot::_ftp_script` — a production call site, and a seam against silent
  rename breakage.
