# Phase 5 — Proof and operability

Phases 1–4 make the daemon restricted. This phase makes the restriction
_provable_ and _operable_: tests that fail if either mechanism silently stops
working, and documentation an operator can act on when it bites. Depends on
phases 3 and 4.

The motivating risk is specific. `FuguLib::Sandbox` is a no-op on Linux and
Darwin by design, which is exactly the shape of a bug that hides: if a refactor
makes `is_supported` return false on OpenBSD, or a `pledge` call is dropped from
`bin/openhapd`, every existing test still passes. Nothing in phases 1–4 catches
that. Something has to — and it has to be something that actually fails when the
call is removed.

## Tasks

### 5.1 Tests that fail when the restriction is absent

In `t/openhap/integration/` (which never skips, and **never parses logs** — see
`t/openhap/integration/CLAUDE.md`), inside the OpenBSD VM.

The design constraint that shapes all of these: **a pledge violation kills the
process.** So "the daemon is still alive and its trace shows no violation" is
satisfied identically by a correctly pledged daemon and by a completely
unpledged one. Any test built on the absence of violations is a null test. What
is observable is the _syscall itself_.

- **The daemon really pledges, with the right promise set.** Start `openhapd`
  under `ktrace` from exec — `ktrace -di -f <file> rcctl start openhapd`, or
  start the daemon directly under `ktrace` — then `kdump` and assert that a
  `pledge` syscall appears **and that its promise-string argument is exactly the
  production set**. `kdump` prints the string, so this asserts far more than
  presence: an empty string, a typo, or a stray `proc exec` all fail. Remove the
  `FuguLib::Sandbox->pledge` call from `bin/openhapd` and the syscall is simply
  absent — the test fails. This is the assertion the earlier draft's two
  approaches could not make: a test-only helper that pledges itself proves
  nothing about the daemon, and "no violations in the trace" proves nothing at
  all.
- **The daemon really unveils, with the right paths.** Same trace, same method:
  assert `unveil` calls appear with the expected path and permission arguments,
  and that a final argument-less `unveil` (the lock) follows them. Removing the
  unveil call or the lock makes this fail.
- **Unveil actually restricts.** The syscall trace proves the call was made;
  this proves it took effect. Assert from inside the VM that a file outside the
  view is unreachable to the daemon's uid _through the daemon_, using whatever
  operator- supplied path the daemon reads. If no such path exists — likely —
  then say so plainly and rely on `t/fugulib/sandbox.t`'s forked-child unveil
  test (phase 3, extended in phase 4) for the enforcement semantics, plus the
  trace assertion above for the daemon's participation. Do not invent a
  log-parsing probe: the integration tier forbids it, and a file the daemon
  failed to open produces no other observable artifact.
- **No child processes.** `pgrep -P $(pgrep openhapd)` is empty. This is phase
  2's contract, and it is what keeps `proc exec` out of the promise set; without
  a test it regresses the moment anyone adds a `system()` call.
- **Startup still succeeds in every configuration that worked before.** From
  phase 4: no config file, `mdnsd` stopped, and `-f` on a host with no log file.
  These are the tests that catch a disposition regression in the inventory.

**No test-only flag or environment override in `bin/openhapd`.** The earlier
draft wanted one to force a bogus promise string, with the caveat "make sure the
override cannot loosen anything". No such mechanism exists: the first `pledge`
call defines the sandbox absolutely, so an externally supplied superset
(`... proc exec prot_exec`) is a _weaker_ sandbox that starts fine — "bogus" and
"wider" are the same input class. It would put external input on the security
decision path of a root-started daemon, against `CLAUDE.md`'s "never trust
external input" and against `plan-3.md` 3.1's own "no `force => 0`, no
warn-and-continue". Fail-closed behaviour is proven where it belongs, in
`t/fugulib/sandbox.t`, by calling `FuguLib::Sandbox` directly with a bogus
promise string and a nonexistent required path.

Each test above must fail when the corresponding call is commented out of
`bin/openhapd`. Verify that by actually commenting it out once during
development; a test that cannot fail is not evidence. Where a test cannot meet
that bar — the enforcement probe, if no operator-supplied read path exists — say
so in the file's comments rather than letting it read as proof.

### 5.2 `openhapd.8` SECURITY section

One place an operator can read to understand the daemon's posture:

- The promise set, with a one-line gloss on why each promise is present, and the
  explicit statement that `proc`, `exec`, and `prot_exec` are absent. Note
  whether `unix` is present, since phase 3 makes it conditional on the mDNS
  reconnect mechanism.
- The unveiled paths and their permissions, marking required versus optional
  (cross-referencing FILES from phase 4).
- The privilege model: starts as root, `chown`s `$db_path`, drops to `_openhap`,
  then unveils and pledges. Say plainly that pledge and unveil are applied
  _after_ the privilege drop and what that does and does not buy. **Write only
  what phase 2's measurement established** about `/var/run/mdnsd.sock` access.
  The long-standing comment at `bin/openhapd:116` claims `_openhap` must be in
  `wheel`, but `FuguLib::Privdrop` calls only `setgid`/`setuid` — never
  `setgroups`/`initgroups` — and Perl's `$) = $gid` at `Privdrop.pm:73` itself
  invokes `setgroups`, which would drop wheel rather than keep it. Do not
  restate an unverified privilege boundary in an installed man page.
- OpenBSD-only enforcement. Linux and Darwin are development platforms and the
  restrictions are no-ops there. An operator who reads only the README should
  not be able to conclude that a Linux deployment is hardened.
- What a violation looks like in practice: the process aborts, `dmesg` and
  `/var/log/messages` carry a `pledge` line naming the syscall. This is the
  single most useful paragraph in the section — it turns "the daemon died" into
  a diagnosis.

### 5.3 Close out `TODO.md`

- Mark the pledge and unveil items (`TODO.md:10-20`) done, in the style the file
  already uses for completed entries — a short "Implemented:" summary with the
  files, as at `TODO.md:48-53`. Do not just tick the box; the file's value is
  that finished entries say what landed.
- The `Privilege separation` item (`TODO.md:489`) stays open, but update it: a
  pledged monolith changes what separation would buy, and the entry should say
  so.
- Add a `hapctl` pledge item. It is now cheap — `FuguLib::Sandbox` exists, and
  `hapctl` reads config and state and prints, so `stdio rpath` plus a handful of
  unveiled paths covers it — and leaving it undone while `openhapd` is pledged
  is the kind of asymmetry that goes unnoticed.
- Add an item for re-establishing the mDNS advertisement after an `mdnsd`
  restart. Phase 2 documents this as parity with the old `mdnsctl` behaviour,
  which makes it a known limitation rather than a bug, but "known" should mean
  "recorded".
- Add an item for the unimplemented half of `spec/MDNS-Control.md`: browse,
  resolve and lookup are specified but only publish is coded. A spec section
  with no implementation and no conformance citation is exactly what
  `make spec-coverage` is for, so record it rather than letting the coverage gap
  read as an oversight.
- **Add an item for SIGHUP.** `etc/rc.d/openhapd:16-18` reloads with
  `pkill -HUP`, but `bin/openhapd:177` registers HUP via
  `setup_graceful_exit('INT','TERM','HUP')`, so `rcctl reload openhapd` _stops_
  the daemon — and after phase 2 that also closes the held mdnsd socket,
  withdrawing the advertisement, since the socket is the advertisement. This is
  a pre-existing bug that plan 005 deliberately does not fix, and three parts of
  the design lean on reload as future work, so it must be recorded. Note the
  pledge constraint while recording it: a real reload must not re-exec, or
  `exec` returns to the promise set and the benefit goes.
- **Add an item for the `wheel` privilege model**, if phase 2's measurement
  showed the comment at `bin/openhapd:116` does not describe what actually
  grants socket access.

### 5.4 Verify the aspirational docs are now accurate

No rewriting — checking. Read each claim against what shipped and confirm it is
true rather than merely plausible. If any overreaches — for instance implying
Linux is hardened too — fix that specific sentence, and only that one.

- `README.md:16`, `CLAUDE.md:7`, `CLAUDE.md:107-108`,
  `web/index.body.html:19-20` — the pledge/unveil claims. (The earlier draft
  cited `CLAUDE.md:103`; that line is the `IO::Select` rule.)

Two more that phases 2–4 falsify and no earlier phase is allowed to touch:

- **`web/fugulib.body.html:8`** reads "It is deliberately small. Six modules, no
  dependencies outside core Perl" and enumerates exactly six in a `<dl>`. This
  plan adds `Imsg`, `MDNS` and `Sandbox` — nine. Update the count and add the
  three entries. `t/web/site.t` will not catch this: its exhaustiveness
  assertion counts only `/^(?:OpenHAP|OpenHVF)::.*\.3p\.html$/` against `.pod`
  sidecars and deliberately excludes FuguLib.
- **`CLAUDE.md:14-15`** scopes FuguLib as "generic OpenBSD-style daemon
  utilities (daemonize, privilege drop, signals, logging, process, state)" — an
  enumeration that an mdnsd protocol client and a pledge/unveil wrapper fall
  outside of. Extend it.

## Deliverables

- New/extended tests in `t/openhap/integration/`
- `man/openhap/openhapd.8` SECURITY section
- `TODO.md` updates
- `web/fugulib.body.html` module count and entries
- Any narrow corrections to `README.md`, `CLAUDE.md`, `web/index.body.html`

## Acceptance criteria

- The pledge and unveil trace assertions fail when the corresponding call is
  removed from `bin/openhapd` — demonstrated by removing it once, not assumed.
  The pledge assertion checks the promise _string_, so a wrong or empty set
  fails too.
- Any test in 5.1 that cannot meet that bar says so in its own comments.
- `make integration` green on OpenBSD; `make check` green on Linux and Darwin.
- `openhapd.8` renders clean under `mandoc -Tlint -W warning` and answers,
  without reference to the source: what is pledged, what is unveiled, which
  paths are optional, what happens on violation, and where enforcement applies.
- `TODO.md` has no remaining claim that pledge or unveil is unimplemented, and
  records the SIGHUP reload bug.
- `web/fugulib.body.html` no longer says six modules.
- `make spec-coverage` exits zero with `MDNS-Imsg` and `MDNS-Control` coverage
  no lower than phase 2 left it, and HAP-mDNS coverage no lower than before
  phase 2. This phase adds no spec citations, so the check is a regression net.
