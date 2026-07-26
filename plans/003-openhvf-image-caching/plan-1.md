# Phase 1 — Core base-image cache

Introduce the native installed-image cache: a new `OpenHVF::ImageCache` module,
backing-file support actually used by `OpenHVF::Disk`, and save/restore wiring
in `OpenHVF::VM::up`. After this phase, any machine with a warm `cache_dir`
boots an installed VM without downloading the miniroot or running the installer.

## Tasks

### 1.1 `Disk::create` backing format

- `OpenHVF::Disk::create` already accepts `$backing_image` but hardwires
  `-F raw` (`lib/OpenHVF/Disk.pm:44`). Add a backing-format parameter (the cache
  passes `qcow2`) and keep the current default for compatibility.
- Overlays are created without an explicit size so they inherit the backing
  image's virtual size. Make the size optional —
  `sub create ( $self, $name, $size = undef, $backing_image = undef, $backing_format = 'raw' )`
  — and split `Disk.pm:47` so the size is appended only when defined.
- `Disk::create` returns early on an existing path (`Disk.pm:39`), so every
  "replace the working disk with an overlay" step in this plan must unlink first
  — otherwise it silently succeeds and changes nothing.

### 1.2 `OpenHVF::ImageCache`

New module (plus `.pod` sidecar and `t/openhvf/imagecache.t`):

- `new($cache_dir)` — expands `~` like `OpenHVF::Image` does.
- `key($vm_config)` — returns `<version>-<arch>-<hash8>`; `hash8` is a truncated
  `Digest::SHA` SHA-256 over version, `OpenHVF::Image::ARCH`, `disk_size`, the
  bytes of the `install.exp` that `OpenHVF::Expect` resolves, and the contents
  of `share/openhvf/cache-generation` (bump that file when install-driver
  behavior changes outside `install.exp`). Serialize the inputs with an
  unambiguous delimiter. The generation counter is a data file rather than a
  constant in `ImageCache.pm` so a `hashFiles()` CI key can observe it:
  `actions/cache` runs no save step on a primary-key hit, so a generation bump
  the workflow key cannot see would rotate openhvf's key, miss, reinstall, and
  then discard the result on every run until some unrelated hashed file changed.
  Expose the script path from `OpenHVF::Expect` via a small public method
  instead of duplicating its search logic.
- `lookup($key)` — returns `{base => $path, meta => $hashref}` when both
  `base.qcow2` and a parseable `meta.json` exist, else undef (a half-written
  entry is a miss, not an error).
- `store($key, $disk_path, $meta)` — build the entire entry in a sibling temp
  directory `installed/.tmp.<pid>.<rand>/`: `qemu-img convert -O qcow2` to
  `base.qcow2` (then chmod 0400), and `meta.json` (0600) with the root password,
  creation time, and the key inputs echoed for diagnostics. Publish by
  `rename()`ing the DIRECTORY into place. One rename of one directory, not two
  renames of two files: the root password is generated per install, so a base
  from one install beside a `meta.json` from another is not a half-written entry
  — it looks live, `lookup` hits it, and the seeded password then never opens
  its own image, wedging `up` in `_wait_ssh_password` with no phase-1 way out.
  `ENOTEMPTY` over a populated entry gives write-once for free; on collision
  keep the existing entry and fall through to the degrade path rather than
  re-pointing existing overlays at a foreign base. Remove the temp tree on every
  failure path and from a SIGINT/`END` guard — an interrupt during the
  minutes-long convert, not between renames, is what orphans multi-GB
  temporaries. Returns the base path, undef on any failure.
- `list` / `remove($key)` — enumeration and deletion for later phases.

Re-storing an existing key needs no concurrency to reach: `up` creates the disk
before the installer runs and marks the state installed only after it succeeds,
so an aborted install leaves a disk present and state not-installed, and the
next `up` re-installs onto it and arrives at `store` with the same key.

### 1.3 Save and restore in `VM::up`

- **Key derivation:** derive the key exactly once per `up`, unconditionally and
  before `run_install`, and pass that one value to both `lookup` and `store`.
  `key()` reads `install.exp` at call time, so re-deriving it after a
  tens-of-minutes install would publish the image the OLD installer produced
  under the NEW digest; and the disk-exists-but-not-installed path never enters
  the lookup block, so it has no key to carry otherwise.
- **Restore:** in the no-disk path, consult `lookup` before creating a blank
  disk. On a hit, create the working disk as an overlay backed by the base, seed
  state from `meta.json` (`mark_installed`, `set_root_password`, plus a
  `cached_from` key for diagnostics), and skip `OpenHVF::Image->ensure` entirely
  — only the install path needs the miniroot. Gating that call also clears a
  pre-existing wart: `ensure` runs unconditionally today (`VM.pm:119-132`) and
  hard-fails an already-installed VM whose miniroot has been pruned. The
  existing `_needs_ssh_key_update` flow then installs the checkout's SSH key
  using the seeded password.
- **Save:** in the just-installed path, gate the capture on a QEMU that is
  provably gone. `VM.pm:199-201` discards the return values of both `_qmp_quit`
  and `_wait_exit`, and `clear_vm_pid` only unlinks the pid file, after which
  `_is_running` and `_force_stop` are blind — so "the installer VM is stopped"
  is an assumption, and the design's "bit-identical to a cleanly shut-down disk"
  contract rests on it. Capture the pid, check `_wait_exit`'s result, and only
  then `clear_vm_pid` and `store`. A QEMU that had to be SIGKILLed
  (`FuguLib::Process` escalates) disqualifies the capture: warn and skip
  caching, never publish. On success delete the standalone disk and recreate it
  as an overlay backed by the new base before restarting. On failure, log a
  warning and continue with the standalone disk — `up` must never fail because
  caching failed.
- **Chain check:** when a disk already exists, verify with `qemu-img info` that
  its backing file (if any) resolves; if not, error with the remedy "backing
  image missing from cache; run `openhvf destroy` and `openhvf up`" instead of
  letting QEMU fail opaquely at boot. Run this check before the existing
  `was_unclean_shutdown` branch (`VM.pm:90-102`), which otherwise reaches the
  same condition first, maps it to `Disk::check`'s blanket 'corrupted' verdict,
  and prints "run 'openhvf disk repair'" — a dead end, since
  `qemu-img check -r all` cannot recreate a missing backing file. Skip or
  downgrade that disk check when a broken chain is the proven cause.

### 1.4 Configured `cache_dir` reaches `VM::up`

`VM::_cache_dir` (`VM.pm:967-971`) hardcodes `$ENV{HOME}/.cache/openhvf`. The
configurable accessor `Config::cache_dir` is used only by the `image` verb
(`CLI.pm:315`), and `CLI.pm:155-160` hands `VM` nothing but the per-VM config
hash. Since save/restore lives in `VM::up`, a non-default `cache_dir` would have
`up` write `installed/<key>/` under `$HOME` while phase 2's `cache list` /
`clear --stale` and phase 3's snapshot verbs work on a different tree.

Inject the resolved `cache_dir` into the per-VM config in `Config::load_vm`
exactly as `ssh_pubkey` is injected (`Config.pm:169`), or add it as a `VM->new`
argument, and delete the hardcoded path. Phase 2 needs the same Config→VM
channel for `image_cache`, so this is cheap now. Two riders: it also relocates
the proxy/miniroot cache under a non-default `cache_dir`, and the workflow's
hardcoded `path: ~/.cache/openhvf` documents the default only.

### 1.5 One CI cache entry for the disk and its base

Phase 4 retires `.openhvf` caching entirely; until then a cached `.openhvf`
contains an overlay whose absolute backing reference points into
`~/.cache/openhvf/installed/<key>/`. Coupling the keys of the two existing
`actions/cache` steps is not sufficient — it makes them _rotate_ together, not
be _present_ together. They are separate entries that hit, miss and get
LRU-evicted independently. Restore `.openhvf` without `~/.cache/openhvf` and the
new chain check fails the job, `scripts/vm_up.sh` runs under `set -e`, no step
runs the `openhvf destroy` the message asks for, and the cache post-step does
not save on a failed job — so every rerun fails identically until someone
deletes the entry out of band.

In `.github/workflows/integration.yml`:

- Replace the two cache steps with ONE `actions/cache` step listing both paths
  (`~/.cache/openhvf` and `.openhvf`) under one key, so presence is atomic and
  an overlay is never restored without its base.
- Key it on `runner.arch` plus
  `hashFiles('.openhvfrc', 'share/openhvf/expect/install.exp', 'share/openhvf/cache-generation', 'deps/OpenBSD.txt', 'scripts/vm_provision.sh')`,
  keeping the manual `v<N>` suffix as the documented cold-cache lever. Hashing
  the generation file keeps a bump observable in CI during phases 1-3, where a
  restored `.openhvf` means `ImageCache::key` is never called at all.
- Note in a comment why the paths share one entry.

Update `.claude/skills/integration-tests/SKILL.md` in this phase: its cold-cache
procedure names two cache keys that no longer exist, and "bump `v<N>`" must name
the surviving key.

## Deliverables

- `lib/OpenHVF/ImageCache.pm` + `lib/OpenHVF/ImageCache.pod`
- `share/openhvf/cache-generation`
- Changes to `lib/OpenHVF/Disk.pm`, `lib/OpenHVF/VM.pm`, `lib/OpenHVF/Expect.pm`
  (script-path accessor), `lib/OpenHVF/Config.pm` (`cache_dir` injection)
- `t/openhvf/imagecache.t`; extended `t/openhvf/disk.t`, `t/openhvf/vm.t` and
  `t/openhvf/config.t`
- Single-cache-step edit to `.github/workflows/integration.yml`
- `.claude/skills/integration-tests/SKILL.md` cold-cache procedure

## Acceptance criteria

- Unit tests cover: key stability and rotation (each input, including the
  generation file, changes the key), lookup miss on empty/partial entries,
  store/lookup round-trip including metadata and permissions, `store` refusing
  to overwrite a populated key, temp-tree cleanup after a forced failure, and
  overlay creation with a qcow2 backing file. Tests skip gracefully when
  `qemu-img` is unavailable, per `t/` conventions.
- On a host with QEMU: `openhvf up` (cold) installs and populates
  `installed/<key>/`; `openhvf destroy && openhvf up` (warm) reaches "VM ready"
  with no installer run and no miniroot download, and `openhvf ssh` works —
  key-installed via the seeded root password.
- Deleting the cached base under a stopped VM's existing overlay produces the
  chain-check error and its `openhvf destroy` remedy — not "Disk corruption
  detected", and not an opaque QEMU failure.
- With `cache_dir` set to a non-default path, `up` populates that path and
  nothing under `~/.cache/openhvf`.
- Disabling or corrupting the cache entry degrades to a full install with a
  warning, not a failure.
- `make check` stays green.
