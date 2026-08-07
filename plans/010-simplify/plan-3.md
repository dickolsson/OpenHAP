# Phase 3 — The Fugu:: sweep

This phase removes about 600 lines from `lib/Fugu/`, with the mirrored entries
in `man/fugu/*.3p` and the tests of deleted layers. It deletes the `warn`/`err`
level aliases (design decision 11). Phase 1 must land first. Phases 2, 4, and 5
are independent of it.

Every deletion re-verifies with a grep across `lib/ bin/ scripts/ t/` first. A
grep that finds a production caller stops the deletion and updates this plan.

## Tasks

### 3.1 Dead code

- `Fugu::Signal`: delete the graceful-exit facility — `setup_graceful_exit` (no
  caller at all), `add_cleanup` and `_run_cleanup_handlers` (test-only), and the
  `cleanups`/`exit_status` state. `bin/openhapd` uses `setup_interrupt_flag`
  only; the event loop made the rest obsolete. Delete `reset_all_interrupted`
  and move its eleven test call sites to fresh handler objects.
- `Fugu::SSH`: delete `make_remote_dir` — zero callers, including tests. (Phase
  5 removes the `Guest.pm` hand-rolled equivalent; the two phases do not
  conflict, because `Guest` never called this method.)
- `Fugu::StateFile`: delete `increment` and `exists`. The HAP stores own their
  counters, and `App::FuguVM::State` tests the raw hash.
- `Fugu::Config`: delete `bool`; every consumer calls `parse_bool`.
- `Fugu::Proxy`: delete `host_url` (the subclass exists because `host_url` is
  not what a guest can reach) and the test-only `Meta->remove` and
  `Meta->clear`.
- Delete the test-only accessors and methods: `EventLoop::has_fd`,
  `Config::block_types`, `Control::commands`, `Control::Client->exists`,
  `Pidfile::release`, `Process::reap`, `Process::reap_all`, `MQTT::unsubscribe`,
  `Log::crit` and its `%priority_map` row. Each takes its subtests with it.
- `Fugu::Mdnsd`: delete the nine `IMSG_*` constants with no reference. The
  positional enum lives in `spec/MDNS-Control.md §2`.

### 3.2 Test-only options

- `Fugu::Process`: delete the `check_alive` block — the only production caller
  passes `check_alive => 0` — with the `exited`/`exit_code` result keys that
  exist for it. Delete the `on_error`/`on_success` callbacks and their nine
  guards; every production caller reads the result hash.
- `Fugu::Proxy`: delete the `child` constructor option (never passed; subclasses
  override `run_child`). Keep `ports` — its test is the only cheap way to prove
  the range walk.
- `Fugu::Control`: delete the loop-less serving path — `serve_client`, the
  `unless ($loop)` branch, and the threaded `$timeout` parameter. `listen`
  already requires the loop for production. Move `t/fugu/control.t` to a real
  `Fugu::EventLoop`.
- `Fugu::Daemon`: delete `on_fork` (one test caller) and the `umask` option (no
  caller ever passed it; `022` stays as the constant).
- `Fugu::Log`: delete the `local0`–`local7` and `user` facility rows — only
  `daemon` is ever configured — and the `warn`/`err` aliases with
  `_canonical_level`, per decision 11. `openhapd.conf.5` documents the remaining
  level spellings already.

### 3.3 Redundant checks

- `Fugu::Mdnsd::_encode_service`: delete the `SERVICE_LEN` re-check; `new`
  proves the template and `_check_service` bounds every field. One layer keeps
  the check — the one at construction.
- `Fugu::Process`: keep one validation of the command argument (the arrayref
  check subsumes the truthiness check); hoist the PID guard pair into `is_alive`
  alone and let `terminate`, `reap`-callers, and `wait_exit` rely on it.
- `Fugu::Privdrop`: delete the pre-check at `:157-159`; the post-`setuid(0)`
  probe is strictly stronger.
- `Fugu::Sandbox`: delete the shape pre-pass over the unveil list; the
  destructure fails loudly on malformed entries, and the only caller builds the
  list from literals.
- Delete the `defined fileno`/`defined $key` guards in `EventLoop` and
  `Control::_drop_client` for handles the loop just dispatched on.
- `Fugu::Control`: delete the server-side `MAX_REPLY` check and the `eval`
  around encoding its own reply. The client keeps its bound — a hostile server
  is real; the server's own handlers are not.

### 3.4 Duplication

- `Fugu::Process`: extract `_fork_exec` and collapse `run` and
  `_run_passthrough` onto it.
- Promote `Fugu::File::_write_all` to a class method and call it from
  `Fugu::Proxy`, `Fugu::JSONSocket`, and `Fugu::Imsg`; delete their copies.
- `Fugu::SSH`: add `_with_connection(sub ($ssh2) {...})` and collapse the four
  open/branch/disconnect copies, including the duplicated SFTP guard.
- `Fugu::MQTT`: keep one warning-capture block and one subscribe closure;
  `resubscribe` loops over `subscribe`.
- `Fugu::Proxy`: serve the whole-file case through the streaming path and delete
  `_serve_whole`; hoist the repeated lazy `require` lines into `serve`.
- `Fugu::File`: fold `_temp_name` and `_make_temp_dir` onto one attempt loop.
- Keep the accessors, drop their weight: each `error`/`path` accessor shrinks to
  its minimal form with a one-line comment. No generator module (design
  non-goal).
- Apply the `Proxy.pm:63-66` loop idiom to the required-parameter `die` sites
  with three or more parameters; leave the one-parameter sites alone.
- Define `EXIT_ERROR` once in `Fugu::CLI` and import it in `Process` and `SSH`;
  fold the four usage `printf` shapes in `Fugu::CLI` into one.

### 3.5 Documentation and tests

- Update `man/fugu/<Module>.3p` for every deleted method: `Signal.3p`, `SSH.3p`,
  `StateFile.3p`, `Config.3p`, `Proxy.3p`, `EventLoop.3p`, `Control.3p`,
  `Pidfile.3p`, `Process.3p`, `MQTT.3p`, `Log.3p`, `Daemon.3p`, `Mdnsd.3p`,
  `Sandbox.3p`, `Privdrop.3p`, `File.3p`.
- Trim the matching subtests in `t/fugu/`, and keep `t/fugu/coreperl.t`
  untouched — nothing in this phase adds an import.

## Deliverables

- Smaller `lib/Fugu/*.pm` across sixteen modules.
- Updated `man/fugu/*.3p` pages.
- Trimmed `t/fugu/*.t`.

## Acceptance criteria

- `make check` passes.
- `mandoc -Tlint -W warning man/fugu/*.3p` reports nothing new.
- `grep -rn 'setup_graceful_exit\|make_remote_dir\|check_alive\|on_fork' lib bin t scripts`
  finds nothing.
- `grep -rn "'warn'\|'err'" lib/Fugu/Log.pm` finds nothing, and
  `prove -l t/fugu/log.t` still proves one name per level.
- `grep -c '_write_all' lib -r` reports one defining file.
- `t/fugu/sandbox.t` passes unchanged — the enforcement subtests it ships into
  the VM do not depend on the deleted pre-pass.
- `bin/openhapd` starts, pairs, and stops in the integration tier
  (`make integration` in CI) — the daemon path exercises `Signal`, `Process`,
  `Control`, `Mdnsd`, and `Log` together.
