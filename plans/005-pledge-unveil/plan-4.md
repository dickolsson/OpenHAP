# Phase 4 — Proof and operability

Phases 1–3 make the daemon restricted. This phase makes the restriction
_provable_ and _operable_: tests that fail if either mechanism silently stops
working, and documentation an operator can act on when it bites. Depends on
phases 2 and 3.

The motivating risk is specific. `FuguLib::Sandbox` is a no-op on Linux and
Darwin by design, which is exactly the shape of a bug that hides: if a refactor
makes `is_supported` return false on OpenBSD, or a `pledge` call is dropped from
`bin/openhapd`, every existing test still passes. Nothing in phases 1–3 catches
that. Something has to.

## Tasks

### 4.1 Negative integration tests

In `t/openhap/integration/` (which never skips — see
`t/openhap/integration/CLAUDE.md`), inside the OpenBSD VM:

- **Pledge is really on.** Start `openhapd`, then confirm from outside that the
  process is pledged. `ps -o pledge` is not available; the reliable signal is
  that a pledge violation aborts. Two workable approaches, in order of
  preference:
  1. A test-only helper invocation that pledges with the production promise set
     and then deliberately violates it, asserting `SIGABRT`. This proves the
     promise string in the daemon is a real pledge, not an empty string.
  2. `ktrace -p $(pgrep openhapd)` during a normal pairing and `kdump` asserting
     no `pledge` violations — a regression net for promise-set drift, since a
     missing promise shows up here before it shows up in production.
- **Unveil is really on.** Assert the daemon cannot read a file outside its
  unveiled set. Create `/tmp/openhap-unveil-probe` and drive the daemon down a
  path that would read an operator-supplied path; if no such path exists, use
  the helper from the pledge test to unveil the production inventory and then
  probe.
- **No child processes.** `pgrep -P $(pgrep openhapd)` is empty. This is phase
  1's contract, and it is what keeps `proc exec` out of the promise set; without
  a test it can regress the moment anyone adds a `system()` call.
- **Startup fails closed.** With a deliberately bogus promise string or a
  nonexistent unveil path, `openhapd` exits nonzero and logs why, rather than
  starting unrestricted. Drive this through a test-only flag or environment
  override — not by editing the production string — and make sure the override
  cannot loosen anything, only break startup.

Each of these must fail when the corresponding call is commented out of
`bin/openhapd`. Verify that by actually commenting it out once during
development; a test that cannot fail is not evidence.

### 4.2 `openhapd.8` SECURITY section

One place an operator can read to understand the daemon's posture. Contents:

- The promise set, with a one-line gloss on why each promise is present, and the
  explicit statement that `proc`, `exec`, and `prot_exec` are absent.
- The unveiled paths and their permissions (cross-referencing FILES from phase
  3).
- The privilege model: starts as root, `chown`s `$db_path`, drops to `_openhap`,
  requires `wheel` membership for `/var/run/mdnsd.sock`, then unveils and
  pledges. Say plainly that pledge and unveil are applied _after_ the privilege
  drop and what that does and does not buy.
- OpenBSD-only enforcement. Linux and Darwin are development platforms and the
  restrictions are no-ops there. An operator who reads only the README should
  not be able to conclude that a Linux deployment is hardened.
- What a violation looks like in practice: the process aborts, `dmesg` and
  `/var/log/messages` carry a `pledge` line naming the syscall. This is the
  single most useful paragraph in the section — it turns "the daemon died" into
  a diagnosis.

### 4.3 Close out `TODO.md`

- Mark the pledge and unveil items (`TODO.md:10-20`) done, in the style the file
  already uses for completed entries — a short "Implemented:" summary with the
  files, as at `TODO.md:48-53`. Do not just tick the box; the file's value is
  that finished entries say what landed.
- The `Privilege separation` item (`TODO.md:489`) stays open, but update it: a
  pledged monolith changes what separation would buy, and the entry should say
  so rather than reading as though nothing has happened.
- Add a `hapctl` pledge item. It is now cheap — `FuguLib::Sandbox` exists, and
  `hapctl` reads config and state and prints, so `stdio rpath` plus a handful of
  unveiled paths covers it — and leaving it undone while `openhapd` is pledged
  is the kind of asymmetry that goes unnoticed.
- Add an item for re-establishing the mDNS advertisement after an `mdnsd`
  restart. Phase 1 documents this as parity with the old `mdnsctl` behaviour,
  which makes it a known limitation rather than a bug, but "known" should mean
  "recorded".

### 4.4 Verify the aspirational docs are now accurate

No rewriting — checking. `README.md:16`, `CLAUDE.md:7`, `CLAUDE.md:103`, and
`web/index.body.html:19-20` all claim pledge/unveil support. Read each one
against what shipped and confirm it is now true rather than merely plausible. If
any claim overreaches — for instance implying Linux is hardened too — fix that
specific sentence, and only that one.

## Deliverables

- New/extended tests in `t/openhap/integration/`
- `man/openhap/openhapd.8` SECURITY section
- `TODO.md` updates
- Any narrow corrections to `README.md`, `CLAUDE.md`, `web/index.body.html`

## Acceptance criteria

- Every test in 4.1 provably fails when the corresponding `bin/openhapd` call is
  removed — demonstrated, not assumed.
- `make integration` green on OpenBSD; `make check` green on Linux and Darwin.
- `openhapd.8` renders clean under `mandoc -Tlint -W warning` and answers,
  without reference to the source: what is pledged, what is unveiled, what
  happens on violation, and where enforcement applies.
- `TODO.md` has no remaining claim that pledge or unveil is unimplemented.
- `make spec-coverage` unaffected (no spec citations change in this plan).
