# Phase 3 — FuguVM conversion

This phase makes FuguVM a thin wrapper: QEMU, disk, image, and OpenBSD-install
logic stay; every generic concern moves to FuguLib or is deleted. The `fuguvm`
command surface and `.fuguvmrc` grammar are unchanged.

## Tasks

### 3.1 Move FuguVM::SSH to FuguLib::SSH

- The module moves nearly as-is; nothing in it is QEMU-aware.
- `_exit_code` already moved to `FuguLib::Process` in phase 1; call it there.
- `wait_available` becomes a thin use of `FuguLib::Util::wait_until`.
- Fix during the move: check the `read` return value; today a short read of
  `/dev/urandom`-derived data passes silently (`FuguVM::Util` had the same bug
  and dies with the module).
- New `man/fugulib/SSH.3p`, `t/fugulib/ssh.t` (skips without Net::SSH2); delete
  `lib/FuguVM/SSH.pm` and its test moves.

### 3.2 Move the proxy to FuguLib::Proxy

- `lib/FuguLib/Proxy.pm` holds three packages in one file, per house style:
  `FuguLib::Proxy` (supervisor and serve loop), `FuguLib::Proxy::Cache`
  (URL-to-file store), `FuguLib::Proxy::Meta` (stat-validated metadata with
  ETag).
- Generic content: the `HTTP::Daemon` plus `IO::Select` loop with the self-pipe
  SIGTERM trick, forward, streaming with partial-write handling, port scan,
  readiness wait (now `Util::wait_until`), atomic cache store (now
  `File::write_atomic`), one shared directory walker instead of two.
- Cacheability is a callback: `cacheable => sub ($url) {...}`. Content types
  come from a table with an override hook.
- `FuguVM::Proxy` remains as policy: the OpenBSD mirror patterns, the
  version-scoped `prune`, the QEMU SLIRP `guest_url` (`10.0.2.2`), and the port
  range. `Proxy::Cache` and `Proxy::MetaCache` files are deleted.
- `stop` uses `FuguLib::Process->terminate` instead of the hand-rolled
  TERM/sleep/KILL ladder.
- `FuguVM::Image` stops hardcoding the cache layout: it asks the cache for the
  path (`cache_path`), removing the hidden coupling.

### 3.3 QMP and QGA onto FuguLib::JSONSocket

- Both modules keep only their command sets (`query_status`, `powerdown`,
  `quit`; `sync`, `fsfreeze`, `ping`, `shutdown`) and their handshake choice.
- The duplicated connect, read-line, deadline, and buffer code is deleted.

### 3.4 FuguVM::State becomes pure persistence

- The JSON blob rides on `FuguLib::Store`; the two PID-file copies become two
  `FuguLib::Pidfile` objects (`vm.pid`, `proxy.pid`). This removes the
  missing-`flock` and zombie-is-alive defects in one pass.
- Proxy lifecycle (`ensure_proxy`, `get_proxy`, `stop_proxy`) moves to
  `FuguVM::VM`; the lazy `require` cycle between State and Proxy disappears.
- Directory hygiene and name validation come from `FuguLib::File` (`ensure_dir`,
  `valid_name`).
- `VM.pm` and `CLI.pm` stop reaching into `$state->{...}` internals; the
  accessors exist and become the only path.

### 3.5 FuguVM::Config onto FuguLib::Config

- The module keeps the `DEFAULT_*` constants, `load_vm` merging, and the
  `image_cache` switch; parsing, `find_project_root`, bool handling, and `~`
  expansion come from FuguLib.
- Behavior note in the `.pod`: bad lines now fail with file and line instead of
  being skipped.

### 3.6 FuguVM::CLI onto FuguLib::CLI

- The five repeated option-parse blocks and the dispatcher go; the subcommand
  bodies stay.
- Exit codes: generic constants from `FuguLib::CLI`; the domain codes
  (`EXIT_VM_NOT_FOUND` and friends) are defined once in `FuguVM::CLI` and
  `FuguVM::VM` uses them from there.
- `_format_size` and `_write_file` are deleted in favor of `FuguLib::Util` and
  `FuguLib::File`.

### 3.7 FuguVM::VM and Expect cleanup

- `_bounded` becomes `FuguLib::Util::bounded`; `_wait_exit` becomes
  `FuguLib::Process->wait_exit`; `_wait_console_ready` becomes a `wait_until`
  with the pid-death early abort kept.
- Every bare `kill(0, $pid)` liveness check becomes `FuguLib::Process->is_alive`
  (zombie fix).
- `FuguVM::Disk` invocations normalize on `FuguLib::Process->run` — one style
  instead of backticks, string `system`, and list `system`.
- `Expect` resolves scripts via `FuguLib::File::share_path` and runs them via
  `FuguLib::Process->run`; the unused `install_ssh_key` and `halt_system` are
  deleted.
- `ImageCache` uses `File::atomic_dir`, `File::read_json`, `File::write_json`
  (mode-before-content fix), and `File::valid_name`.
- Delete `FuguVM::Output` (unreferenced) and `FuguVM::Util` (moved).

### 3.8 Documentation

- Add or update `.pod` sidecars for every FuguVM module this phase touches:
  `VM`, `State`, `Config`, `CLI`, `Proxy`, `QMP`, `QGA`, `Expect`, `Disk`,
  `Image`, `ImageCache`. FuguVM keeps sidecars; it is development-only and is
  not installed.
- New `man/fugulib/{SSH,Proxy}.3p`; `Proxy.3p` documents the three packages.
  Extend `MAN3P`.
- `man/fuguvm/fuguvm.1` needs no interface change; verify and adjust the FILES
  and DIAGNOSTICS sections where messages changed.
- Update `web/fugulib.body.html` for the two new modules.

## Deliverables

- `lib/FuguLib/SSH.pm`, `lib/FuguLib/Proxy.pm` (+ pages, tests)
- Reworked
  `lib/FuguVM/{VM,State,Config,CLI,Proxy,QMP,QGA,Expect,Disk,Image,ImageCache}.pm`
  with `.pod` sidecars
- Deleted: `lib/FuguVM/{Output,Util,SSH}.pm`,
  `lib/FuguVM/Proxy/{Cache,MetaCache}.pm`
- Updated `t/fuguvm/*.t`, new `t/fugulib/{ssh,proxy}.t`
- Updated `Makefile`, `web/fugulib.body.html`

## Acceptance criteria

- `make check` is green; `make integration` provisions a VM end to end (install,
  cache store, restore, snapshot, destroy) on a development host.
- Grep proves the deletions: no `FuguVM::Output`, `FuguVM::Util`, `FuguVM::SSH`,
  `Proxy::MetaCache` references; no bare `kill(0,` liveness checks under
  `lib/FuguVM`; no `$state->{` internals access outside `FuguVM::State`.
- A VM whose QEMU became a zombie is reported as stopped, not running.
- The proxy cache file layout on disk is unchanged; an existing cache populated
  before this phase still hits after it.
- `fuguvm` exit codes are unchanged for every documented failure.
