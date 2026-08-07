# Phase 5 — The App::FuguVM and App::FuguWeb sweeps

This phase removes about 850 lines across the two development tools: the QGA
subsystem, the CLI dedup, and the extraction leftovers of plan 009. It executes
decisions 4–7, 10, 16, and 17. Phases 1–4 must land first (phase 3 already
removed the dead `check_alive` argument from `Guest.pm`).

Every deletion re-verifies with a grep across
`lib/ bin/ t/ scripts/ share/ .github/ .fuguvmrc .fuguwebrc` first — `.github/`
is in scope because the integration workflow reads `share/` paths.

## Tasks

### 5.1 The QGA subsystem goes whole (decision 4)

- Delete `lib/App/FuguVM/QGA.pm`, `QGA.pod`, and `t/fuguvm/qga.t`.
- Delete from `Guest.pm`: the QGA fallback in `_graceful_shutdown`,
  `_qga_socket_path`, `_qga_connect`, and the virtio-serial `-device`,
  `-chardev`, and `virtserialport` arguments. `_graceful_shutdown` becomes: SSH
  sync, ACPI powerdown, report.
- Delete `share/fuguvm/expect/firstboot.exp`; installing an agent nothing talks
  to was its only job. `login.exp` and `command.exp` stay — operator tools for
  `fuguvm expect`.
- Edit `lib/App/FuguVM/QMP.pod:70`: drop `App::FuguVM::QGA` from SEE ALSO (the
  only remaining QGA reference outside the deleted files).
- Increment `share/fuguvm/cache-generation` to `2`: the file exists to rotate
  the disk-cache key when the install driver changes in ways the `install.exp`
  hash cannot see, and removing the virtio-serial device is such a change. The
  mechanism stays (decision 4); the `integration.yml` paths and cache key
  already hash it.
- Update `fuguvm(1)` and `Guest.pod` where they mention the agent.

### 5.2 FuguVM dedup

- `Guest.pm`: `down` becomes `_stop_proxy` plus `return $self->stop`; the
  five-statement force-stop epilogue becomes one private helper; the install
  tail of `up` becomes `return $self->_complete_ssh_setup`; `wait_ssh` and
  `_wait_ssh_password` fold into one method with a `password` flag; the
  hand-rolled remote mkdir uses one quoted command in one place.
- `CLI.pm`: the five load-and-call commands dispatch through the `method` field
  `%COMMANDS` already carries; `_current_cache_key` folds its diagnostic in,
  removing four copies; the snapshot-lookup diagnostic and the sorted key-dump
  loop each keep one copy; `run` stops copying `%COMMANDS` field by field.
- `DiskCache.pm`: fold `_tree_size` onto `Fugu::Proxy::Cache`'s walk. `dir_size`
  is an instance method (`sub dir_size ($self, $dir)`), so first verify it reads
  nothing from `$self` and lift it to a class-callable form; otherwise keep
  `_tree_size` and drop only the duplicated inner loop. The four hand-rolled
  unlink-on-failure paths in `snapshot_store` use the `Fugu::File` atomics that
  `store` already uses.

### 5.3 FuguVM dead code and redundant checks

- Delete from `State.pm`: the seven proxy pid/port methods (production reaches
  the pidfile and store directly), `is_ssh_key_installed`, and
  `ssh_key_matches`. Their subtests in `t/fuguvm/state.t:102-178` go.
- Decision 17: `mark_running` moves to the main start path — its only call today
  sits inside the pidfile fallback branch this phase deletes, which is why crash
  detection almost never armed. With it on the main path,
  `was_unclean_shutdown`'s `running` branch works; the three no-op `delete`
  calls become live.
- Delete: `Disk::disk_exists` and `Disk::remove` (with `t/fuguvm/disk.t:33` and
  the `state.t:202` caller moving to `State::disk_exists`), `QMP::socket_path`
  and `QMP::is_available` (with their `t/fuguvm/qmp.t` subtests), `Guest::pid`,
  `Config::project_root`, the three never-returned exit codes in `CLI.pm` and
  one in `Guest.pm`, `DiskCache::cache_dir` (with its `diskcache.t` and
  `guest.t` callers), the unreachable `return EXIT_ERROR` in `cmd_disk`, and the
  self-cancelling `timeout` round trip in `Console.pm`.
- Keep `Miniroot::_ftp_script`: it has a production caller (`Miniroot.pm:106`),
  and its comment explains the seam guards against silent rename breakage.
- Decision 16: after `_prepare` loads the config, resolve the VM name as
  `$cli->option('vm') // $config->default_vm` — `Config::default_vm` already
  ends in `// 'default'`. Offline commands, which return before the config
  exists, keep the literal `'default'`.
- Decision 7: delete the `arch` key from `.fuguvmrc`,
  `share/fuguvm/fuguvm.conf.sample`, `share/fuguvm/vms/default.conf.sample:9`,
  `share/fuguvm/vms/minimal.conf.sample:8`, and the `fuguvm(1)` entry; the
  manual states the fixed architecture once. `DiskCache`'s internal `arch`
  cache-key component stays — it names the constant, not the config key.
- Decision 5: delete `cmd_image`, `Miniroot::list`, `_release_root`, the `image`
  entries in `%COMMANDS` and `fuguvm(1)`, and their subtests in
  `t/fuguvm/miniroot.t:82,101` and `t/fuguvm/cli.t`.
- Delete the unreachable `backing_format` default (every call site passes
  `qcow2`), the `cmd_init` pre-checks that `Fugu::File` failure reporting
  already covers, the double diagnostic after `State->new`, and the three-stage
  timeout validation (one anchored regex).
- `Guest.pm`: replace the self-doubting pidfile wait with one
  `Fugu::Timeout::wait_until`; the fallback branch goes with decision 17.
  `_is_running` asks the kernel only; the QMP handshake leaves the hot path.
  `_wait_console_ready` runs for the installer only.

### 5.4 FuguWeb extraction leftovers

- Decision 6: delete `cmd_page`, `cmd_index`, their `%COMMANDS` entries, the two
  `use` lines, and their subtests in `t/fuguweb/cli.t:111-148`. `Page::document`
  folds into `Page::write`; `Index::DEFAULT_TITLE` goes with its only reachable
  use. Update the pipeline example in `fuguweb(1)`.
- Delete `Check::_check_xrefs`; `_check_references` reports the same class of
  failure for the same inputs. Update the one regex in `t/fuguweb/check.t`.
- Delete the `@TITLE@` machinery: `TITLE_PLACEHOLDER`, `@LITERAL`,
  `_without_literals`, the check, and its subtests in `t/fuguweb/check.t`.
- Delete the dead accessors: `Site::out`, `Site::render`, `Check::config`,
  `Check::out`, `Page::config`, `Index::config`, `Config::Group::dir`,
  `Config::Group::module_root`, `Manual::group`. Delete the dead `out` defaults
  in `Site::new` and `Check::new`; every caller passes `out`.
- Delete `CLI::new`'s unused `%opts` and the write-only `quiet` field.

### 5.5 FuguWeb dedup and knobs

- One directory-listing helper beside `escape_html` in `App::FuguWeb` replaces
  the six opendir/filter/closedir blocks; one `inventory` method on `Config`
  replaces the two inventory computations; one stylesheet constant in
  `App::FuguWeb` replaces the three definitions of `'style.css'`. The shared
  helpers are documented in `FuguWeb.pod`, not `_`-prefixed — a cross-package
  private name is what phase 6's floor exists to keep out.
- One prefix-test helper replaces `Config::_below` and `Site::_holds` (whose two
  unreachable early returns go); `Site::clean` and `_prune_output` share one
  classification step; one `_copy` helper replaces the three read-then-write
  paths.
- `Page::_head` becomes a heredoc over pre-escaped values and `_nav` becomes a
  `join`; `t/fuguweb/page.t` pins the output byte for byte.
- Decision 10: delete the `banner`, `pod_center`, and `pod_release` config keys
  and the `extra.css` hook; `lang` stays. `Page` renders `$config->site` where
  `banner` stood (its default, so the built site is unchanged). The `--center`
  and `--release` values move into `Render` as constants — they pin `pod2man`
  output so the site does not vary with the build host. Test fallout, verified:
  `t/fuguweb/config.t:48,56-57,66-87`, `t/fuguweb/page.t:71,150,174-177`,
  `t/fuguweb/site.t:83,180,239`.
- Delete `Config::anonymous`'s parser construction — its one caller needs `root`
  only. Trim `$STARTER` to a minimal buildable description.
- The probe for missing tools lives in `Site::build`; `cmd_build` maps the
  result to `EXIT_TOOL_MISSING` without probing again. `POD_SECTION` defines
  once.

### 5.6 Documentation

- Update the sidecars of every touched module in both namespaces, the two
  chapter-1 manuals, and the sample configs.

## Deliverables

- Deleted: `lib/App/FuguVM/QGA.pm`, `QGA.pod`, `t/fuguvm/qga.t`,
  `share/fuguvm/expect/firstboot.exp`.
- `share/fuguvm/cache-generation` reads `2`.
- Smaller `lib/App/FuguVM/*.pm` and `lib/App/FuguWeb/*.pm` with updated sidecars
  (including `QMP.pod`).
- Updated `man/fuguvm/fuguvm.1`, `man/fuguweb/fuguweb.1`, `.fuguvmrc`,
  `.fuguwebrc`, and the three `share/fuguvm` samples.
- Trimmed `t/fuguvm/{state,disk,qmp,miniroot,diskcache,guest,cli}.t` and
  `t/fuguweb/{cli,check,config,page,site}.t`.

## Acceptance criteria

- `make check` passes.
- `git grep -niE 'qga|qemu-ga|guest-exec' lib bin t share scripts` finds
  nothing.
- `git grep -n 'cmd_image\|_check_xrefs\|TITLE_PLACEHOLDER' lib t` finds
  nothing.
- `git grep -nE '^\s*arch\b' .fuguvmrc share/fuguvm` finds nothing, and
  `git grep -n 'arch' man/fuguvm/fuguvm.1` finds only the fixed-architecture
  sentence and the cache-filename format.
- `fuguvm up` and `fuguvm down` work in `make integration` in CI, and the run
  rebuilds its base image — the generation bump invalidated the cache built with
  the old device model.
- `make web WEBOUT=<tmp>` builds a tree that `diff -r` reports identical to the
  pre-phase build (`banner` defaulted to `site` and `web/` has no `extra.css`,
  so nothing changes); `prove -l t/web/site.t` passes, including the
  double-build subtest.
- `git grep -n 'banner\|pod_center\|pod_release\|extra\.css' lib/App/FuguWeb .fuguwebrc`
  finds only the `Render` constants and their comment.
