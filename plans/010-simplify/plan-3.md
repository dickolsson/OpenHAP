# Phase 3 — The Fugu:: sweep

This phase removes about 500 lines from `lib/Fugu/`, with the mirrored entries
in `man/fugu/*.3p` and the tests of deleted layers. Phases 1 and 2 must land
first. The log-vocabulary work (design decision 11) is **not** here: it spans
`Fugu::Log`, `bin/openhapd`, and `openhapd.conf.5`, so phase 4 owns it whole.

Every deletion re-verifies with a grep across `lib/ bin/ scripts/ t/` first. A
grep that finds a production caller stops the deletion and updates this plan —
the review moved the `MAX_REPLY` bound, the encode `eval`, the `Privdrop`
pre-check, and the `EventLoop` `fileno` guard to the design's verified-keeps
list this way.

## Tasks

### 3.1 Dead code

- `Fugu::Signal`: delete the graceful-exit facility — `setup_graceful_exit` (no
  caller at all), `add_cleanup` and `_run_cleanup_handlers` (test-only), and the
  `cleanups`/`exit_status` state. `bin/openhapd` uses `setup_interrupt_flag`
  only; the event loop made the rest obsolete. Delete `reset_all_interrupted`
  and rework its eleven call sites across `t/fugu/signal.t`, `t/fugu/timeout.t`,
  and `t/fugu/eventloop.t` to use fresh handler objects.
- `Fugu::SSH`: delete `make_remote_dir` — zero callers, including tests.
- `Fugu::StateFile`: delete `increment` and `exists`. The HAP stores own their
  counters, and `App::FuguVM::State` tests the raw hash.
- `Fugu::Config`: delete `bool`; every consumer calls `parse_bool`.
- `Fugu::Proxy`: delete `host_url` and the test-only `Meta->remove` and
  `Meta->clear`. `host_url`'s callers are all tests: `t/fugu/proxy.t:214, 246`
  and `t/fuguvm/proxy.t:76-77`; edit both files and drop the mention in
  `lib/App/FuguVM/Proxy.pod:52` — cross-tier fallout this phase owns.
- Delete the test-only accessors and methods: `EventLoop::has_fd`,
  `Config::block_types`, `Control::commands`, `Control::Client->exists`,
  `Pidfile::release`, `Process::reap`, `Process::reap_all`, `MQTT::unsubscribe`,
  `Log::crit` (zero callers of any kind; its vocabulary row falls under phase
  4's decision 11). Each takes its subtests with it.
- Keep the nine `IMSG_*` constants: `t/conformance/mdns-control.t:70-86` pins
  the whole positional enum via `->can`, the only drift check against mdnsd's C
  enum.

### 3.2 Test-only options

- `Fugu::Process`: delete the `check_alive` block — the only production caller
  passes `check_alive => 0` — with the `exited`/`exit_code` result keys that
  exist for it, the `on_error`/`on_success` callbacks, and their nine guards.
  Remove the now-meaningless `check_alive => 0` argument and its comment at
  `lib/App/FuguVM/Guest.pm:1085` in the same commit; phase 5 rewrites the
  surrounding wait separately.
- `Fugu::Proxy`: delete the `child` constructor option (never passed; subclasses
  override `run_child`). Keep `ports` — its test is the only cheap way to prove
  the range walk.
- `Fugu::Control`: delete the loop-less serving path — `serve_client`, the
  `unless ($loop)` branch, and the threaded `$timeout` parameter — and make
  `listen` require its loop (`die` without one). `t/fugu/control.t:34` currently
  listens with no loop; give the test a real `Fugu::EventLoop`.
- `Fugu::Daemon`: delete `on_fork` and `umask` — both are test-only
  (`t/fugu/daemon.t:79` passes `umask => 027`, `:99` asserts it; those subtests
  go). `022` stays as the constant.

### 3.3 Redundant checks

- `Fugu::Mdnsd::_encode_service`: delete the `SERVICE_LEN` re-check; `new`
  proves the template and `_check_service` bounds every field. The check at
  construction is the one that stays.
- `Fugu::Process`: keep one validation of the command argument (the arrayref
  check subsumes the truthiness check); keep the PID guard in `is_alive` and
  delete the copies in `terminate` and `wait_exit`.
- `Fugu::Sandbox`: delete the shape pre-pass over the unveil list; the
  destructure fails loudly on malformed entries, and the only caller builds the
  list from literals.
- `Fugu::Control::_drop_client`: delete the `defined $key` arm — its only caller
  passes a handle that is still open (`recv` marks `{dead}` without closing).
  The similar guard in `EventLoop` **stays**: a callback earlier in the same
  ready-pass can close a sibling handle.

### 3.4 Duplication

- `Fugu::Process`: extract `_fork_exec` and collapse `run` and
  `_run_passthrough` onto it.
- Promote `Fugu::File::_write_all` to a class method and point `Fugu::Proxy`'s
  private copy at it. `Fugu::JSONSocket` and `Fugu::Imsg` keep their inline
  loops: theirs set transport failure state (`{error}`/disconnect, `{dead}`),
  which the shared helper must not absorb. `Protocol::HAP::Store::File` keeps
  its own copy — the CPAN boundary.
- `Fugu::SSH`: add `_with_connection(sub ($ssh2) {...})` and collapse the
  connect/branch/disconnect copies, including the duplicated SFTP guard.
- `Fugu::MQTT`: keep one warning-capture block and one subscribe closure;
  `resubscribe` loops over `subscribe`.
- `Fugu::Proxy`: serve the whole-file case through the streaming path and delete
  `_serve_whole`; hoist the repeated lazy `require` lines into `serve`.
- `Fugu::File`: fold `_temp_name` and `_make_temp_dir` onto one attempt loop.
- Keep the accessors, drop their weight: each `error`/`path` accessor shrinks to
  its minimal form with a one-line comment. No generator module.
- Apply the `Proxy.pm:63-66` loop idiom to the required-parameter `die` sites
  with three or more parameters; leave the one-parameter sites alone.
- Define `EXIT_ERROR` once in `Fugu::CLI` and import it in `Process` and `SSH`;
  fold the four usage `printf` shapes in `Fugu::CLI` into one.

### 3.5 Documentation and tests

- Update `man/fugu/<Module>.3p` for every deleted method: `Signal.3p`, `SSH.3p`,
  `StateFile.3p`, `Config.3p`, `Proxy.3p`, `EventLoop.3p`, `Control.3p`,
  `Pidfile.3p`, `Process.3p`, `MQTT.3p`, `Daemon.3p`, `Sandbox.3p`, `File.3p`.
- Trim the matching subtests in `t/fugu/`, plus the two cross-tier files named
  above (`t/fuguvm/proxy.t`, `lib/App/FuguVM/Proxy.pod`). Keep
  `t/fugu/coreperl.t` untouched — nothing in this phase adds an import.

## Deliverables

- Smaller `lib/Fugu/*.pm` across fifteen modules.
- One line removed from `lib/App/FuguVM/Guest.pm` (the dead `check_alive`
  argument).
- Updated `man/fugu/*.3p`, `lib/App/FuguVM/Proxy.pod`.
- Trimmed `t/fugu/*.t` and `t/fuguvm/proxy.t`.

## Acceptance criteria

- `make check` passes.
- `mandoc -Tlint -W warning man/fugu/*.3p` reports nothing new.
- `git grep -n 'setup_graceful_exit\|make_remote_dir\|check_alive\|on_fork\|serve_client\|host_url' lib bin t scripts`
  finds nothing.
- `git grep -n 'sub _write_all' lib` reports exactly two definitions:
  `lib/Fugu/File.pm` and `lib/Protocol/HAP/Store/File.pm`.
- `prove -l t/conformance/mdns-control.t` passes unchanged — the enum is intact.
- `t/fugu/sandbox.t` passes unchanged — the enforcement subtests it ships into
  the VM do not depend on the deleted pre-pass.
- `make integration` in CI is green: the daemon path exercises `Signal`,
  `Process`, `Control`, and `Mdnsd` together, and `fuguvm` exercises `Proxy` and
  `SSH`.
