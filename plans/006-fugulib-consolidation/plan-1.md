# Phase 1 — Harden the existing nine modules

This phase redesigns the nine FuguLib modules in place. It fixes the known bugs,
applies the interface convention from the design, and renames `FuguLib::State`
to `FuguLib::Pidfile`. Consumers get mechanical updates only. No new subsystems
appear.

## Tasks

### 1.1 FuguLib::Daemon

- `daemonize` also does `chdir('/')` and sets a configurable `umask` (default
  `022`), as `daemon(3)` does.
- New `pidfile => $path` argument. The child writes the PID file through
  `FuguLib::Pidfile->acquire` after `setsid` and holds the lock for life.
  `on_fork` stays for callers that need more.
- Add the missing `t/fugulib/daemon.t` (fork-free tests where possible; skip
  gracefully where not).

### 1.2 FuguLib::Pidfile (rename of FuguLib::State)

- Rename file, package, man page, and test. The old name said "state"; the
  module manages a PID file and nothing else. The rename frees the name for the
  phase 2 `FuguLib::Store`.
- Constructor becomes `FuguLib::Pidfile->new(path => $path)`, in line with the
  convention; the positional form goes away.
- Fix the lock order: open with `O_CREAT|O_RDWR`, `flock`, then truncate and
  write. Today the open truncates before the lock, so a concurrent writer loses
  its content.
- New `acquire` method: write the PID and keep the locked handle open, so "am I
  already running" has an authoritative answer. `release` drops it.
- Update the call sites: `OpenHAP::Daemon->check_running` and `bin/hapctl`.

### 1.3 FuguLib::Privdrop

- Fix the re-escalation check: the verification runs in a discarded `eval`, so a
  successful `setuid(0)` is not detected. Make the check die on failure.
- New `prepare_statedir(path => ..., user => ..., group => ...)`: chown a state
  directory and its files before the drop. This replaces the 25 hand-rolled
  lines in `bin/openhapd:117-141` and the phantom `chown_runtime_files` example
  in the module comment.
- Supplementary groups: keep the current OpenBSD-relevant behavior, add a
  `clear_groups => 1` option that calls `setgroups`, and document the default.
- Remove the `_openhap` example from the module and make the man page examples
  consistent (`_myapp` throughout).

### 1.4 FuguLib::Sandbox

- Move `_perl_lib_dirs` from `OpenHAP::Daemon` here as `perl_lib_dirs` (reads
  `%Config` for `privlibexp`, `archlibexp`, `sitelibexp`, `sitearchexp`).
- New `system_paths` class method: the standard read-only unveil inventory every
  daemon repeats (`/etc/resolv.conf`, `/etc/hosts`, `/etc/services`,
  `/etc/protocols`, `/etc/localtime`, `/dev/urandom`).
- Use the named `$class` invocant, like the other modules.

### 1.5 FuguLib::Signal

- Make state per-object: the interrupt flag and the cleanup list move into the
  instance, and the installed handlers close over it. Two managers in one
  process no longer share state.
- `interrupted` and `reset_interrupted` become methods. A package-level
  `FuguLib::Signal::check_interrupted()` remains for code without the object,
  reading the flags of all live instances.
- Cleanups survive a second signal: do not empty the list while running it.
- New `exit_status => $n` option; the default stays 130.

### 1.6 FuguLib::Log

- New `reopen` method: close and reopen syslog with the same settings. This
  replaces the `$logger = undef` then re-create dance after privilege drop, and
  serves SIGHUP.
- New process default: `FuguLib::Log->default` returns the default instance and
  creates a stderr logger on first use; `FuguLib::Log->set_default($log)`
  replaces it. This is the target for the phase 4 logger convention.
- Autoflush stderr output. Add a `level` getter.
- Drop the `warn`/`err` aliases; the levels are `debug`, `info`, `notice`,
  `warning`, `error`, `crit`. Document the `MODE_*` constants; FuguVM already
  uses them.

### 1.7 FuguLib::Process

- `check_alive` default becomes 0, and the check uses an exec-error pipe
  (`close-on-exec`) instead of `sleep 1`, so spawn failures report exactly and
  immediately.
- A child that exits fast with status 0 is not a failure: the result becomes
  `{success => 1, pid => ..., exited => 1, exit_code => 0}`.
- New `run(cmd => \@argv, timeout => $s)`: run a child and capture stdout,
  stderr, and the exit code through pipes. This replaces backticks and `system`
  string forms in FuguVM (phase 3) and `rcctl` calls in the test harness (phase
  4).
- Move `_exit_code` (the `$?` mapping) here from `FuguVM::SSH`.
- `terminate` polls with sub-second granularity.
- `is_alive` stays reaping (documented); callers that need the status use `run`
  or `waitpid` directly.

### 1.8 FuguLib::Imsg

- `send` accepts `peerid`; `recv` returns `type`, `peerid`, `pid`, and `data`.
- New `close` method and `is_dead` predicate. `FuguLib::MDNS` stops reaching
  into `$self->{imsg}{fh}`.
- Cite `spec/MDNS-Imsg.md` as a repository document, not as an installed one.

### 1.9 FuguLib::MDNS

- New one-call `publish(%args)`: connect on demand, then publish. The
  connect/publish split remains available, but `bin/openhapd` shrinks its 26
  lines of nested error handling to one call and one error report.
- Add `DESTROY`: withdraw on object destruction, since the held socket is the
  advertisement lifetime.
- `_encode_service` returns undef and sets `error` instead of dying, like the
  rest of the module. Validate the struct size expectation in `new`.

### 1.10 Consumers and documentation

- `bin/openhapd` passes `pidfile => '/var/run/openhapd.pid'` to `daemonize`.
  Today nothing writes that file, so `hapctl status` always reports "not
  running". Keep the privdrop chown of the PID file so `remove` works later.
- `bin/openhapd` uses `Privdrop->prepare_statedir`, `Log->reopen`,
  `Sandbox->system_paths` plus `perl_lib_dirs`, and `MDNS->publish`.
- `OpenHAP::Daemon` keeps working on the renamed modules; its deletion waits for
  phase 4.
- Update all nine man pages; rename `State.3p` to `Pidfile.3p`; update the
  `MAN3P` list in the `Makefile`.
- Update `man/openhap/openhapd.8` FILES with `/var/run/openhapd.pid`.
- Update `web/fugulib.body.html` module descriptions where behavior changed.

## Deliverables

- Reworked
  `lib/FuguLib/{Daemon,Privdrop,Sandbox,Signal,Log,Process,Imsg,MDNS}.pm`
- `lib/FuguLib/Pidfile.pm` (renamed from `State.pm`)
- Updated `bin/openhapd`, `lib/OpenHAP/Daemon.pm`, `bin/hapctl` call sites
- Updated `man/fugulib/*.3p` (nine pages, one renamed), `Makefile`,
  `man/openhap/openhapd.8`, `web/fugulib.body.html`
- New `t/fugulib/daemon.t`; extended tests for every changed module

## Acceptance criteria

- `make check` is green; `mandoc -Tlint` passes on all changed pages.
- `t/fugulib/pidfile.t` proves the lock precedes truncation and that `acquire`
  blocks a second acquire.
- A spawned child that fails to exec reports the exec error without a one-second
  delay; a fast clean exit reports `exited`, not failure.
- Two Signal objects with separate cleanups do not run each other's cleanups.
- `openhapd` on OpenBSD writes the PID file, and `hapctl status` finds the
  running daemon by PID.
- Grep finds no `FuguLib::State` reference and no `$self->{imsg}{fh}` access
  outside `FuguLib::Imsg`.
