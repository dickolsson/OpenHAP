# Simplification — Design

## Problem

An audit of the whole tree found about 2,800 removable lines in `lib/` and
`bin/` (12–13%), plus about 330 test lines and 250 documentation lines. The
design is not at fault, and no tier carries an abstraction too many. The bloat
has six recurring shapes, and backward compatibility — the usual suspect — is
almost absent: the clean-break rule from plan 008 works.

| Shape                    | Example                                                         |
| ------------------------ | --------------------------------------------------------------- |
| Test-only API            | `Fugu::Process` `check_alive`; `Pairing::get_failed_attempts`   |
| Unreachable option       | Tasmota `fulltopic`; `Characteristic` `maxLen`                  |
| Documentation–code drift | `openhapd.conf.5` documents six thermostat options nobody reads |
| Multi-layer validation   | `Pairing::new` re-checks what `Server::new` proved              |
| Copy-paste blocks        | the ChaCha20 frame loop exists three times                      |
| Refactor leftovers       | the QGA subsystem; `fuguweb page` and `fuguweb index`           |

The audit also found real bugs that hide inside the bloat: an integer `%` in
`_rgb_to_hsb` that no production path reaches, a shared lock in the file store
that the write side defeats, and config keys (`arch`, `hap_model`) that the
manuals promise and no code reads.

Nothing in `make check` detects any of the six shapes today. `.perlcriticrc`
runs at severity 4, so the policies that find unused code never run — and nine
of its sixteen entries disable policies that the severity filter already
excludes. The config file is itself an instance of the problem.

## Goals

1. Delete about 2,800 lines from `lib/` and `bin/`, with the matching test and
   documentation lines, and with no change to module boundaries.
2. The observable HAP behavior of a paired accessory does not change. The
   decisions below list every user-visible exception.
3. Every deletion is verified first: a grep across `lib/ bin/ t/` proves the
   code is unreachable, test-only, or duplicated, before it goes.
4. Code, tests, and documentation leave together. No orphaned `.pod` section, no
   `.3p` entry for a deleted method, no test of a deleted layer.
5. Two of the six shapes get permanent gates: compatibility vocabulary
   (extending `t/scripts/namespaces.t`) and undeclared or unused API surface (a
   new `t/scripts/symbols.t` plus two Perl::Critic policies).
6. The root `CLAUDE.md` grows by three rules. The audit procedure lives in a new
   `shrink` skill, per the placement table.

## Non-goals

- No module folds. `Fugu::Sandbox` + `Fugu::Privdrop` + `Fugu::Daemon`,
  `Fugu::StateFile`, `Fugu::Timeout`, and `Fugu::Random` each have one consumer
  and could merge, but that is a structure change for another effort.
- No new base classes. A shared-accessor generator would shrink twelve
  accessors, at the cost of a new inheritance root. Not worth it.
- No complexity-ceiling policies (`ProhibitExcessComplexity`,
  `ProhibitDeepNests`). A numeric ceiling misfires on protocol dispatch code,
  and the unused-code policies carry the enforcement without it.
- No code-coverage tooling. `Devel::Cover` is a new dependency, against the
  minimal-dependency rule. `spec-coverage` stays the one coverage tool.
- No comment trimming. The comment style is deliberate. A comment leaves only
  when its code leaves.
- No rewrite of `plans/001`–`009`. They record what was true when written.

## Decisions

Fifteen findings need a call between delete and wire-up. Take these knowingly.

1. **`validate_setup_code` is wired in, not deleted.** `bin/openhapd` gains the
   two-line call. Rejecting the trivial setup codes is documented policy and a
   fail-closed default; deleting it would drop a security check to save twenty
   lines.
2. **`has_humidity` becomes a config option.** The HumiditySensor code and its
   conformance tests work; only the config path is missing. Wiring costs a few
   lines in `Devices.pm` and `openhapd.conf.5`. Deleting would remove a real
   capability of the product's core purpose.
3. **`default_vm` is wired in.** `fuguvm init` writes the setting and
   `fuguvm(1)` documents it, but `App::FuguVM::CLI::_prepare` hardcodes
   `'default'`. Honor the setting.
4. **The QGA subsystem goes whole.** Nothing ever runs `firstboot.exp`, so no
   guest has an agent, so every `App::FuguVM::QGA` path is dead at runtime and
   costs about forty seconds on every failed graceful shutdown. Delete the
   module, its sidecar, its test, the fallback branch in `Guest`, the
   virtio-serial arguments, and `firstboot.exp`. This is the one module deletion
   in the effort.
5. **`fuguvm image` goes.** Its `download` subcommand does not download, and
   `list` restates what `up` reports. `Miniroot::list` and `_release_root` exist
   only for it.
6. **`fuguweb page` and `fuguweb index` go.** Plan 009 kept them because "a
   project may want one page out of the set". No caller appeared. The `mdoc`
   pipeline example in `fuguweb(1)` goes with them.
7. **The `arch` key goes.** No code reads it, so `arch amd64` silently produces
   an arm64 VM. `fuguvm(1)` states the fixed architecture instead.
8. **`hap_model` and `hap_manufacturer` go from the documentation.** The daemon
   hardcodes both values. Deleting two sample lines and four manual lines is
   smaller than plumbing two knobs nobody set.
9. **The six thermostat options go from `openhapd.conf.5`.** None appears in any
   code. The manual stops promising them.
10. **The FuguWeb knobs `banner`, `pod_center`, `pod_release`, and the
    `extra.css` hook go.** Only their own round-trip tests set them. `lang`
    stays: a non-English project needs it on day one.
11. **The `warn`/`err` level aliases go from `Fugu::Log`.** No config file or
    fixture uses either spelling. This is the tier's only backward-compat
    construct.
12. **The file store loses its shared lock.** `load_pairings` takes `LOCK_SH`,
    but the writer unlinks and recreates the file, which the lock cannot see.
    One daemon process owns the store; the honest fix is no lock, not more lock.
13. **`openhapd -n` stays.** Config-check flags are OpenBSD daemon convention,
    even though `hapctl check` covers the same ground.
14. **The non-falsifiable subtests of `t/openhap/integration/hap-protocol.t`
    go.** Eleven of them accept every plausible status code, and exact
    assertions for the same endpoints exist in `accessories.t` and
    `characteristics.t`.
15. **`t/conformance/` assertions of deleted layers go with their code**, the
    way commit 0ae2b25 did it: every spec citation the deleted subtest carried
    must stay covered elsewhere, and `make spec-coverage` proves no citation
    went stale.

## The gates

The clean-break rule got `t/scripts/namespaces.t`; the simplicity rules get
gates in the same style. Every gate must fail on a planted violation before its
phase closes.

1. **Vocabulary.** `namespaces.t` gains a `@BANNED` table beside `@RETIRED`,
   with the same self-testing pattern shape: `deprecat`, `backward compat`,
   `for compatibility`, `compatibility shim|layer|alias|wrapper|path`. The sweep
   skips `plans/` and `spec/` — the specs quote other projects' deprecations,
   and the plans are history.
2. **API surface.** A new `t/scripts/symbols.t` proves three invariants over the
   tracked tree: every public sub in `Fugu::` and `App::` has a caller in `lib/`
   or `bin/` (with `App::OpenHAP::Test::` exempt — the integration tier is its
   caller — and a named allowlist for the rest); every module has its sidecar or
   `.3p` page and every sidecar has its module; every non-core import in `lib/`
   appears in `cpanfile` and the `deps/` manifests. `Protocol::` is exempt from
   the caller rule: it is a library, and its `.pod` contract is its caller.
3. **Perl::Critic.** `Subroutines::ProhibitUnusedPrivateSubroutines` and
   `Variables::ProhibitUnusedVariables` run at severity 4 via per-policy
   overrides. `Miscellanea::ProhibitUnrestrictedNoCritic` and
   `ProhibitUselessNoCritic` join them, so suppression cannot become the escape
   hatch. The nine no-op entries leave the file.
4. **`make check` gains `spec-coverage`.** The script is core Perl, so the gate
   costs nothing locally. `prettier` stays CI-only: it needs `npx`, and no
   `deps/` manifest provides node.

What stays review discipline, not a gate: multi-layer validation, copy-paste
blocks, and unreachable options. Text analysis cannot decide those; the `shrink`
skill carries the hunt procedure and the keep list.

## The keep list

Deletion must not touch:

- Checks on external input: HAP wire data, MQTT payloads, config files, and
  anything a controller or a device sends. Fail closed.
- The deliberate duplication across the CPAN boundary. `Protocol::` stays
  self-contained; `Fugu::Random` documents why it will not be the single source
  of randomness.
- The OpenBSD/Linux/Darwin split. Production is OpenBSD; the other two run
  development and CI.
- `plan skip_all` on missing dependencies in module tests, and the never-skip
  rule in integration tests.
- Both store implementations, the sans-IO engine, and the store contract.

## Phases

1. **The ground rules.** The vocabulary gate, the `.perlcriticrc` cleanup,
   `spec-coverage` in `make check`, the three `CLAUDE.md` rules, and the
   `shrink` skill. Two comments reword so the gate passes.
2. **`Protocol::`.** About 470 lines: the `Server.pm` and `Controller.pm` dedup,
   the dead constants, the store fixes, and decision 1.
3. **`Fugu::`.** About 600 lines plus the mirrored `.3p` entries: the dead
   graceful-exit facility, the test-only options, the four-fold idioms, and
   decision 11.
4. **`App::OpenHAP`.** About 740 lines of lib and bin plus 330 test lines: the
   unreachable Tasmota surface, the base-class dedup, the manual cleanup, the
   integration-harness dedup, and decisions 2, 8, 9, 14.
5. **`App::FuguVM` and `App::FuguWeb`.** About 1,000 lines: the QGA deletion,
   the CLI dedup, the extraction leftovers, and decisions 3–7, 10.
6. **The lock.** `t/scripts/symbols.t` and the Perl::Critic enables land last,
   because they only pass after the sweeps.

Phases 2 to 5 depend only on phase 1 and are mutually independent. Phase 6
depends on all of them. Each phase lands whole — code, tests, sidecars, manuals,
and samples together — and `make check` passes at its end.

## Testing

Every phase re-verifies its deletions with the greps in its acceptance criteria;
the audit that produced the counts is input, not proof. Phase 2 ends with the
conformance tier green. Phase 4 ends with `make integration` green in CI. Phase
5 ends with the double-build check of `t/web/site.t`. Phases 1 and 6 plant one
violation per gate and watch the gate fail, then remove the plant.
