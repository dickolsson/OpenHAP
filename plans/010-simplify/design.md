# Simplification — Design

## Problem

An audit of the whole tree found about 3,000 candidate lines in `lib/` and
`bin/`. A five-angle cold review then refuted part of the audit: some
"defensive" code turned out to be load-bearing, and some "dead" code has live
callers. What survives both passes is about 2,400 lines of `lib/` and `bin/`
(10–11%), plus about 330 test lines and 250 documentation lines. The bloat has
six recurring shapes. Backward compatibility — the usual suspect — is almost
absent: the clean-break rule from plan 008 works.

| Shape                    | Example                                                         |
| ------------------------ | --------------------------------------------------------------- |
| Test-only API            | `Fugu::Process` `check_alive`; `Fugu::Pidfile` `release`        |
| Unreachable option       | Tasmota `fulltopic`; `Characteristic` `maxLen`                  |
| Documentation–code drift | `openhapd.conf.5` documents six thermostat options nobody reads |
| Multi-layer validation   | `App::FuguVM::CLI` validates one timeout three times            |
| Copy-paste blocks        | the ChaCha20 frame loop exists three times                      |
| Refactor leftovers       | the QGA subsystem; `fuguweb page` and `fuguweb index`           |

The audit and the review also found real bugs that the plan fixes in passing.
Each is named in the decision that owns it:

1. `_rgb_to_hsb` computes hue with an integer `%` on a live inbound path
   (decision 3).
2. `Host::_write` has no SIGPIPE handling, so a controller that closes mid-write
   can kill the daemon (decision 19).
3. Unknown `log_level` and `log_facility` values fall back silently, and the
   manual promises spellings the code rejects (decision 11).
4. The file store takes a shared lock the writer defeats (decision 12).
5. `arch` and `hap_model` are documented keys no code reads (decisions 7, 8),
   and `has_humidity` is a working key no manual documents (decision 2).
6. `State::mark_running` is called only from a fallback branch, so crash
   detection almost never arms (decision 17).

Nothing in `make check` detects any of the six shapes today. `.perlcriticrc`
runs at severity 4, so policies that find unused code never run — and nine of
its fifteen entries are inert: eight name policies below severity 4, and one
configures a policy the severity filter excludes.

## Goals

1. Delete about 2,400 lines from `lib/` and `bin/`, with the matching test and
   documentation lines, and with no change to module boundaries.
2. The observable HAP behavior of a paired accessory does not change. The
   decisions below list every user-visible exception.
3. Every deletion is verified first: a grep across `lib/ bin/ t/` proves the
   code is unreachable, test-only, or duplicated, before it goes. The audit is
   input, not proof — the review killed a dozen audit claims this way.
4. Code, tests, and documentation leave together. No orphaned `.pod` section, no
   `.3p` entry for a deleted method, no test of a deleted layer.
5. Two of the six shapes get permanent gates: compatibility vocabulary
   (extending `t/scripts/namespaces.t`) and undeclared or unused API surface (a
   new `t/scripts/symbols.t` plus Perl::Critic enables).
6. The root `CLAUDE.md` grows by three rules. The audit procedure lives in a new
   `shrink` skill, per the placement table.

## Non-goals

- No module folds. `Fugu::Sandbox` + `Fugu::Privdrop` + `Fugu::Daemon`,
  `Fugu::StateFile`, `Fugu::Timeout`, and `Fugu::Random` each have one consumer
  and could merge, but that is a structure change for another effort.
- No new base classes, and no accessor-generator module.
- No complexity-ceiling policies, and no `ProhibitUnusedPrivateSubroutines`:
  measured on this tree, that policy flags seven live template-method overrides
  in `Tasmota/*.pm` and none of the real dead code. The `symbols.t` floor covers
  private subs without those false positives.
- No code-coverage tooling. `Devel::Cover` is a new dependency, against the
  minimal-dependency rule.
- No comment trimming. A comment leaves only when its code leaves.
- No unknown-key rejection in `Fugu::Config`. Deleted config keys become ignored
  keys; the gates and manuals carry the vocabulary, not a parser feature no tier
  has.
- No rewrite of `plans/001`–`009`.

## Decisions

Nineteen calls, each verified against the tree. Take them knowingly.

1. **`validate_setup_code` replaces the `normalize_setup_code` call in
   `bin/openhapd`.** It normalizes internally and also rejects the trivial
   codes, so the boundary validates once and gains the documented check.
2. **`has_humidity` gets documented, not rebuilt.** `Devices.pm:67` already
   reads it from the sensor block; only `openhapd.conf.5` never mentions it. The
   no-op "auto-detected humidity" log branch in `Sensor.pm` goes — it sets
   nothing and can add no service after construction.
3. **The color pipeline stays; its bug goes.** `_parse_color` runs on every
   inbound `STATE`/`RESULT` payload and feeds hue and saturation to HomeKit, so
   it is live. Fix the integer-`%` hue bug. Delete only the outbound surface
   nothing calls: `set_color`, `dimmer_step`, `dimmer_min`, `dimmer_max`,
   `toggle_power`, `blink`, `force_telemetry`, with their subtests, under
   decision 15.
4. **The QGA subsystem goes whole.** Nothing ever runs `firstboot.exp`, so no
   guest has an agent and every `App::FuguVM::QGA` path is dead at runtime.
   Delete the module, sidecar, test, the `Guest` fallback and virtio-serial
   arguments, `firstboot.exp`, and the `QMP.pod` SEE ALSO entry. This is the one
   module deletion in the effort. `share/fuguvm/cache-generation` stays and
   increments to 2: it exists to rotate the disk-cache key when the install
   driver changes invisibly, and deleting the virtio-serial device is such a
   change.
5. **`fuguvm image` goes**, with `Miniroot::list`, `_release_root`, and their
   subtests in `t/fuguvm/miniroot.t` and `cli.t`.
6. **`fuguweb page` and `fuguweb index` go**, with their subtests in
   `t/fuguweb/cli.t` and the stale pipeline example in `fuguweb(1)`.
7. **The `arch` key goes.** No code reads it, so `arch amd64` silently produces
   an arm64 VM. It leaves `.fuguvmrc`, all three `share/fuguvm` samples, and
   `fuguvm(1)`, which states the fixed architecture once.
8. **`hap_model` and `hap_manufacturer` go from the documentation.** The daemon
   hardcodes both values.
9. **The six thermostat options go from `openhapd.conf.5`.** None appears in any
   code.
10. **FuguWeb sheds four knobs.** `banner` goes — `Page` renders
    `$config->site`, which was the default. `pod_center` and `pod_release` go as
    config keys, but their values stay as `Render` constants: they pin `pod2man`
    output so the site does not vary with the build host. The `extra.css` hook
    goes — the only site has no such file. `lang` stays.
11. **One spelling per log level, validated at the boundary.** The manual
    promises `err`, `crit`, `alert`, and `emerg`; the code accepts `warn`,
    `err`, and `crit` as extras and silently maps everything unknown to `info`,
    and unknown facilities to `daemon`. The vocabulary becomes the five method
    names of `Fugu::Log`; the alias rows and the `crit` priority row go; the
    facility rows stay — the manual documents them and its own example uses
    `local0`. `bin/openhapd` validates both keys at startup and fails closed
    with a named value. `openhapd.conf.5:138` changes to match.
12. **The file store loses its shared lock.** The writer unlinks and recreates
    the file, which `LOCK_SH` cannot see, and one process owns the store. The
    `flock` pledge promise and its comment leave `bin/openhapd` with it. The
    `/^\d+$/` counter guards **stay**: they are the only type checks on values
    read back from `state.json`, and `get_auth_attempts` feeds the pair-setup
    lockout. The `O_EXCL` pre-unlink **stays**: it is crash recovery for a
    pid-recycled daemon.
13. **`openhapd -n` stays.** Config-check flags are OpenBSD daemon convention.
14. **The non-falsifiable integration subtests go.** Eleven `hap-protocol.t`
    tests accept every plausible status code; exact assertions exist in
    `accessories.t` and `characteristics.t`.
15. **Spec coverage is checked by diff, not by the tool's exit code.**
    `scripts/spec-coverage` fails only on stale citations; it cannot see a
    deleted one. Every phase that deletes a cited subtest diffs the coverage
    matrix before and after, re-homes citations whose behavior survives (the
    `[HAP-Characteristics §2]` and `[§3]` citations move to the catalog rows),
    and lists every dropped citation in the commit message. A citation may drop
    only when its behavior leaves the tree.
16. **`default_vm` is honored.** `_prepare` resolves the VM name from the
    option, then from `Config::default_vm`, once the config exists; offline
    commands keep `'default'`.
17. **`mark_running` moves to the main start path**, so `was_unclean_shutdown`
    detects a crash again. This is a bug fix, and the fallback branch that held
    the only call goes.
18. **`Controller` sheds its test-harness defaults.** `controller_id` becomes a
    required argument; the `OPENHAP_TEST_TIMEOUT` fallback moves into the
    integration harness; the `timeout // 5` default stays. The conformance and
    protocol tests that relied on the literal pass it explicitly.
19. **`Host::_write` is rebuilt, not stripped.** The audit called its three
    guards redundant; the review proved none of them handles SIGPIPE and the
    `syswrite` return is discarded. It becomes one checked write through
    `Fugu::File`'s shared loop with a local SIGPIPE guard.

**Verified keeps.** The review refuted these audit claims; the code stays, and
the `shrink` skill cites them as cautionary examples: `get_failed_attempts`
(eight test callers, two conformance-cited), the nine `IMSG_*` constants
(`mdns-control.t` pins the positional enum), the `Host::listen` memoization (the
pairing-exchange test forks after binding port 0), the `Session` pass-through
guards (`hap-encryption.t` asserts them), `Pairing::new` validation (the
sidecar's SYNOPSIS depends on it), `Store::Memory`'s deep copy (documented
contract), the `Privdrop` pre-check (distinct diagnostic), both `hapctl uptime`
checks, `Control`'s `MAX_REPLY` bound and encode `eval` (a blocking write and an
else-unanswered request), the `Devices.pm` eval (it guards `require` of
config-named classes after daemonize), the `EventLoop` `fileno` guard
(reachable: a callback can close a sibling handle mid-pass), and
`Miniroot::_ftp_script` (a production call site, and a seam against silent
rename breakage).

## The gates

Every gate must fail on a planted, `git add`-ed violation before its phase
closes — `namespaces.t` sweeps tracked files only.

1. **Vocabulary.** `namespaces.t` gains a `@BANNED` table beside `@RETIRED`,
   same self-testing shape: `deprecat`, `backward compat`, `for compatibility`,
   `compatibility shim|layer|alias|wrapper|path`. The sweep skips `plans/` and
   `spec/` — the specs quote other projects' deprecations. The gate is
   line-based; a phrase split across a comment wrap escapes it. Accept that: the
   gate catches vocabulary, review catches intent.
2. **API surface.** A new `t/scripts/symbols.t` proves three invariants: every
   sub defined in `lib/Fugu/` and `lib/App/` — public or private — is named at
   least once in `lib/` or `bin/` outside its definition line; every module has
   its sidecar or `.3p` page, both directions, with an exemption table seeded
   with `Protocol/HAP/Store.pod` (the contract POD); every non-core import in
   `lib/` and `bin/` appears in `cpanfile`. `Protocol::` is exempt from the
   caller floor (its `.pod` contract is its caller), and `App::OpenHAP::Test::`
   counts `t/openhap/integration/` as its caller. The floor is textual and
   therefore a floor: a name that collides across the CPAN boundary (both
   `Random` modules define `random_bytes`) passes wrongly, and the allowlist
   names such cases.
3. **Perl::Critic.** `Variables::ProhibitUnusedVariables`,
   `Miscellanea::ProhibitUnrestrictedNoCritic`, and `ProhibitUselessNoCritic`
   run at severity 4 via per-policy overrides. The nine inert entries leave the
   file.
4. **`make check` gains `spec-coverage`.** The script is core Perl. CI already
   runs it; the gain is local parity. `prettier` stays CI-only: it needs `npx`,
   and no `deps/` manifest provides node.

What stays review discipline: multi-layer validation, copy-paste blocks,
unreachable options. The `shrink` skill carries the hunt procedure, the keep
list, and the verified-keeps list above.

## The keep list

Deletion must not touch:

- Checks on external input: HAP wire data, MQTT payloads, config files,
  control-socket messages, and state files read back from disk. Fail closed.
- Behavior a conformance test asserts with a spec citation, unless the decision
  list names it and decision 15 accounts for the citation.
- The deliberate duplication across the CPAN boundary: `Protocol::` stays
  self-contained.
- The OpenBSD/Linux/Darwin split; `plan skip_all` in module tests; the
  never-skip rule in integration tests.
- Both store implementations, the sans-IO engine, and the store contract.

## Phases

The phases land in order; phase N may rely on every phase before it. They are
not mutually independent: `bin/openhapd` is edited by phases 2 and 4, `Guest.pm`
by phases 3 and 5, and the phase-4 `blink` grep is clean only after phase 2
deletes the `identify` hook whose comment names it.

1. **The ground rules.** The vocabulary gate, three cleanups it forces (two
   comments, one `TODO.md` line), the `.perlcriticrc` cleanup, `spec-coverage`
   in `make check`, the three `CLAUDE.md` rules, and the `shrink` skill.
2. **`Protocol::`.** About 350 lines: the `Server.pm` and `Controller.pm` dedup,
   dead constants, the store lock, and decisions 1, 15, 18.
3. **`Fugu::`.** About 500 lines plus mirrored `.3p` entries: the dead
   graceful-exit facility, test-only options, four-fold idioms.
4. **`App::OpenHAP`.** About 700 lines of lib and bin plus 330 test lines: the
   unreachable Tasmota surface, base-class dedup, the manual cleanup, the
   integration-harness dedup, and decisions 2, 3, 8, 9, 11, 14, 19.
5. **`App::FuguVM` and `App::FuguWeb`.** About 850 lines: the QGA deletion, CLI
   dedup, extraction leftovers, and decisions 4–7, 10, 16, 17.
6. **The lock.** `t/scripts/symbols.t` and the Perl::Critic enables land last,
   because they only pass after the sweeps.

Each phase lands whole — code, tests, sidecars, manuals, and samples together —
and `make check` passes at its end.

## Testing

Every phase re-verifies its deletions with the greps in its acceptance criteria.
Phase 2 ends with the conformance tier green. Phase 4 ends with
`make integration` green in CI. Phase 5 ends with the double-build check of
`t/web/site.t` byte-identical to the pre-phase build. Phases 1 and 6 plant one
violation per gate rule, tracked with `git add`, watch the gate fail, then
remove the plant. Phases that delete cited subtests attach the
`scripts/spec-coverage` matrix diff (decision 15).
