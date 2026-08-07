# Phase 5 — The App::FuguVM and App::FuguWeb sweeps

This phase removes about 1,000 lines across the two development tools: the QGA
subsystem, the CLI dedup, the cache-key speculation, and the extraction
leftovers of plan 009. It executes design decisions 3–7 and 10. Phase 1 must
land first. Phases 2, 3, and 4 are independent of it.

Every deletion re-verifies with a grep across
`lib/ bin/ t/ scripts/ share/ .fuguvmrc .fuguwebrc` first.

## Tasks

### 5.1 The QGA subsystem goes whole (decision 4)

- Delete `lib/App/FuguVM/QGA.pm`, `QGA.pod`, and `t/fuguvm/qga.t`.
- Delete from `Guest.pm`: the QGA fallback in `_graceful_shutdown`,
  `_qga_socket_path`, `_qga_connect`, and the virtio-serial `-device`,
  `-chardev`, and `virtserialport` arguments. `_graceful_shutdown` becomes: SSH
  sync, ACPI powerdown, report.
- Delete `share/fuguvm/expect/firstboot.exp`; installing an agent nothing talks
  to was its only job. `login.exp` and `command.exp` stay — they are operator
  tools for `fuguvm expect`.
- Update `fuguvm(1)` and `Guest.pod` where they mention the agent.

### 5.2 FuguVM dedup

- `Guest.pm`: `down` becomes `_stop_proxy` plus `return $self->stop`; the
  five-statement force-stop epilogue becomes one private helper; the install
  tail of `up` becomes `return $self->_complete_ssh_setup`; `wait_ssh` and
  `_wait_ssh_password` fold into one method with a `password` flag; the
  hand-rolled remote mkdir uses one quoted command in one place.
- `CLI.pm`: the five load-and-call commands dispatch through the `method` field
  that `%COMMANDS` already carries; `_current_cache_key` folds its diagnostic
  in, removing four copies; the snapshot-lookup diagnostic and the sorted
  key-dump loop each keep one copy; `run` stops copying `%COMMANDS` field by
  field.
- `DiskCache.pm`: `_tree_size` calls `Fugu::Proxy::Cache::dir_size`; the four
  hand-rolled unlink-on-failure paths in `snapshot_store` use the `Fugu::File`
  atomics that `store` already uses.

### 5.3 FuguVM dead code and redundant checks

- Delete from `State.pm`: the seven proxy pid/port methods (production reaches
  the pidfile and store directly), `is_ssh_key_installed`, and
  `ssh_key_matches`. Resolve the near-dead `running` key: `mark_running` moves
  to the main start path, so `was_unclean_shutdown` detects a crash again — or,
  when that costs more than it returns, the key and its four no-op `delete`
  calls go. Decide in review; record the choice in the commit.
- Delete: `Disk::disk_exists` and `Disk::remove`, `QMP::socket_path` and
  `QMP::is_available`, `Guest::pid`, `Config::project_root`, the three
  never-returned exit codes in `CLI.pm` and one in `Guest.pm`,
  `DiskCache::cache_dir`, the unreachable `return EXIT_ERROR` in `cmd_disk`,
  `Miniroot::_ftp_script` (a test-only seam, per its own comment), and the
  self-cancelling `timeout` round trip in `Console.pm`.
- Wire in `default_vm` (decision 3): `_prepare` reads
  `$cli->option('vm') // $config->default_vm // 'default'`.
- Delete the `arch` key from `.fuguvmrc`, the samples, and `fuguvm(1)` (decision
  7); the manual states the fixed architecture once.
- Delete `cmd_image`, `Miniroot::list`, `_release_root`, and the `image` entries
  in `%COMMANDS` and `fuguvm(1)` (decision 5).
- Delete the `cache-generation` mechanism: the constant, the `share_path`
  lookup, the file read, and `share/fuguvm/cache-generation` itself. The cache
  key already hashes every real input, and the file never changed.
- Delete the unreachable `backing_format` default (every call site passes
  `qcow2`), the pre-checks that `Fugu::File` failure reporting already covers
  (`cmd_init`), the double diagnostic after `State->new`, and the three-stage
  timeout validation (one anchored regex).
- `Guest.pm`: replace the self-doubting pidfile wait with one
  `Fugu::Timeout::wait_until`; drop the fallback that contradicts its own
  `check_alive => 0` premise. `_is_running` asks the kernel only; the QMP
  handshake leaves the hot path. `_wait_console_ready` runs for the installer
  only, not on every start.

### 5.4 FuguWeb extraction leftovers

- Delete `cmd_page`, `cmd_index`, their `%COMMANDS` entries, and the two `use`
  lines (decision 6). `Page::document` folds into `Page::write`;
  `Index::DEFAULT_TITLE` goes with its only reachable use. Update the pipeline
  example in `fuguweb(1)`.
- Delete `Check::_check_xrefs`; `_check_references` reports the same class of
  failure for the same inputs (verified by execution). Update the one regex in
  `t/fuguweb/check.t`.
- Delete the `@TITLE@` machinery: `TITLE_PLACEHOLDER`, `@LITERAL`,
  `_without_literals`, the check, and its subtests. No code path can emit the
  token since the sed chrome retired.
- Delete the dead accessors: `Site::out`, `Site::render`, `Check::config`,
  `Check::out`, `Page::config`, `Index::config`, `Config::Group::dir`,
  `Config::Group::module_root`, `Manual::group`. Delete the dead `out` defaults
  in `Site::new` and `Check::new`; every caller passes `out`.
- Delete `CLI::new`'s unused `%opts` and the write-only `quiet` field.

### 5.5 FuguWeb dedup and knobs

- One `_names($dir)` helper in `App::FuguWeb` replaces the six
  opendir/filter/closedir blocks; one `inventory` method on `Config` replaces
  the two inventory computations; one `STYLESHEET` constant in `App::FuguWeb`
  replaces the three definitions of `'style.css'`.
- One prefix-test helper replaces `Config::_below` and `Site::_holds` (whose two
  unreachable early returns go); `Site::clean` and `_prune_output` share one
  classification step; one `_copy` helper replaces the three read-then-write
  paths and makes their diagnostics agree.
- `Page::_head` becomes a heredoc over pre-escaped values and `_nav` becomes a
  `join`; `t/fuguweb/page.t` pins the output byte for byte, so the rewrite
  proves itself.
- Delete the knobs only their round-trip test sets: `banner`, `pod_center`,
  `pod_release`, and the `extra.css` hook (decision 10). `lang` stays. Delete
  `Config::anonymous`'s parser construction — its one caller needs `root` only.
  Trim `$STARTER` to a minimal buildable description.
- The probe for missing tools lives in `Site::build`; `cmd_build` maps the
  result to `EXIT_TOOL_MISSING` without probing again. `POD_SECTION` defines
  once.

### 5.6 Documentation

- Update the sidecars of every touched module in both namespaces, the two
  chapter-1 manuals, and the sample configs.

## Deliverables

- `lib/App/FuguVM/QGA.pm`, `QGA.pod`, `t/fuguvm/qga.t`,
  `share/fuguvm/expect/firstboot.exp`, and `share/fuguvm/cache-generation`
  deleted.
- Smaller `lib/App/FuguVM/*.pm` and `lib/App/FuguWeb/*.pm` with updated
  sidecars.
- Updated `man/fuguvm/fuguvm.1`, `man/fuguweb/fuguweb.1`, `.fuguvmrc`,
  `.fuguwebrc`, and `share/` samples.

## Acceptance criteria

- `make check` passes.
- `grep -rn 'QGA\|qemu-ga\|guest-exec' lib bin t share scripts` finds nothing.
- `grep -rn 'cmd_image\|cache-generation\|_check_xrefs\|@TITLE@' lib t share`
  finds nothing.
- `grep -n 'arch' .fuguvmrc share/fuguvm/*.sample man/fuguvm/fuguvm.1` finds
  nothing but the fixed-architecture sentence.
- `fuguvm up` and `fuguvm down` work in `make integration` in CI; the provision
  path no longer waits on a guest agent.
- `make web WEBOUT=<tmp>` builds a tree that `diff -r` reports identical to the
  pre-phase build, except pages the deleted knobs shaped;
  `prove -l t/web/site.t` passes, including the double-build subtest.
- A `.fuguwebrc` with a `banner` setting now fails config validation with a
  named file and block, proving the knob is gone, not ignored.
