# Phase 3 — FuguVM conversion

This phase makes FuguVM a thin wrapper: QEMU, disk, image, and OpenBSD-install
logic stay; every generic concern moves to FuguLib or is deleted. The `fuguvm`
command surface and `.fuguvmrc` grammar are unchanged.

## Tasks

### 3.1 Move FuguVM::SSH to FuguLib::SSH

- The module moves nearly as-is; nothing in it is QEMU-aware. One structural
  change: the compile-time `use Net::SSH2` becomes a lazy `require` at
  `_connect` time, to keep the design's core-Perl load contract and the phase 2
  `coreperl.t` walk green.
- `FuguLib::Process->exit_code` replaced `_exit_code` in phase 1; nothing to
  move here.
- `wait_available` becomes a thin use of `FuguLib::Util::wait_until`.
- Fix during the move: check the return value of the SFTP
  `$remote_fh->write($content)` call in `write_file`; it is unchecked today (the
  channel reads already check theirs).
- New `man/fugulib/SSH.3p`; `t/fuguvm/ssh.t` moves to `t/fugulib/ssh.t` (skips
  without Net::SSH2); delete `lib/FuguVM/SSH.pm`.

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
- The `cache` subcommand bodies construct `FuguVM::Proxy::Cache` directly; they
  move to the new `FuguLib::Proxy::Cache` name deleted by task 3.2 — the two
  tasks land together.
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
- Test-file fates, stated so nothing dangles: `t/fuguvm/util.t` is deleted (its
  coverage lives in `t/fugulib/crypto.t`); `t/fuguvm/ssh.t` moves to
  `t/fugulib/ssh.t`; `t/fuguvm/{proxy-cache,proxy-metacache}.t` fold into the
  new `t/fugulib/proxy.t`, and `t/fuguvm/proxy.t` keeps only the FuguVM policy
  (patterns, prune, guest URL); `t/fuguvm/{cli,vm,state,config}.t` update in
  place.
- Net::SSH2 and HTTP::Daemon stay in the test and develop dependency tiers; the
  installed FuguLib modules are inert without them, per the design's packaging
  contract.

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

- `make check` is green. `make integration` passes twice in sequence on a
  development host: a cold run that installs and stores the base image, then a
  warm run (after `fuguvm destroy`) that restores from the cache — the two runs
  together exercise install, store, restore, and destroy.
- Grep proves the deletions: no `FuguVM::Output`, `FuguVM::Util`, `FuguVM::SSH`,
  `Proxy::MetaCache` references; no bare `kill(0,` liveness checks under
  `lib/FuguVM`; no `$state->{` internals access outside `FuguVM::State`.
- A VM whose QEMU became a zombie is reported as stopped, not running
  (unit-tested with an unreaped child).
- The proxy cache file layout on disk is unchanged. One-time procedure before
  merge: populate the cache with a pre-phase build, run the post-phase
  `fuguvm up`, and record the cache hit in the pull request.
- The exit codes that `t/fuguvm/cli.t` asserts today (0, 1, 2, 3, 5, 11) are
  unchanged, and the constants keep the values `man/fuguvm/fuguvm.1` documents.
