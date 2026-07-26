# Phase 1 — Core base-image cache

Introduce the native installed-image cache: a new `OpenHVF::ImageCache` module,
backing-file support actually used by `OpenHVF::Disk`, and save/restore wiring
in `OpenHVF::VM::up`. After this phase, any machine with a warm `cache_dir`
boots an installed VM without downloading the miniroot or running the installer.

## Tasks

### 1.1 `Disk::create` backing format

- `OpenHVF::Disk::create` already accepts `$backing_image` but hardwires
  `-F raw` (`lib/OpenHVF/Disk.pm`). Add a backing-format parameter (the cache
  passes `qcow2`) and keep the current default for compatibility.
- Overlays are created without an explicit size so they inherit the backing
  image's virtual size; verify `create` handles the size argument being optional
  when a backing image is given.

### 1.2 `OpenHVF::ImageCache`

New module (plus `.pod` sidecar and `t/openhvf/imagecache.t`):

- `new($cache_dir)` — expands `~` like `OpenHVF::Image` does.
- `key($vm_config)` — returns `<version>-<arch>-<hash8>`; `hash8` is a truncated
  `Digest::SHA` SHA-256 over version, `OpenHVF::Image::ARCH`, `disk_size`, the
  bytes of the `install.exp` that `OpenHVF::Expect` resolves, and a
  `CACHE_GENERATION` constant (bump when install-driver behavior changes outside
  `install.exp`). Expose the script path from `OpenHVF::Expect` via a small
  public method instead of duplicating its search logic.
- `lookup($key)` — returns `{base => $path, meta => $hashref}` when both
  `base.qcow2` and a parseable `meta.json` exist, else undef (a half-written
  entry is a miss, not an error).
- `store($key, $disk_path, $meta)` — `qemu-img convert -O qcow2` into a temp
  file inside `installed/<key>/`, write `meta.json` (0600) with the root
  password, creation time, and the key inputs echoed for diagnostics, then
  atomically rename both and chmod the base 0400. Returns the base path, undef
  on any failure.
- `list` / `remove($key)` — enumeration and deletion for later phases.

### 1.3 Save and restore in `VM::up`

- **Restore:** in the no-disk path, consult
  `ImageCache->lookup(ImageCache->key($config))` before creating a blank disk.
  On a hit, create the working disk as an overlay backed by the base, seed state
  from `meta.json` (`mark_installed`, `set_root_password`, plus a `cached_from`
  key for diagnostics), and skip `OpenHVF::Image->ensure` entirely — only the
  install path needs the miniroot. The existing `_needs_ssh_key_update` flow
  then installs the checkout's SSH key using the seeded password.
- **Save:** in the just-installed path, after the installer VM is stopped and
  `clear_vm_pid` has run, call `store`; on success delete the standalone disk
  and recreate it as an overlay backed by the new base before restarting. On
  failure, log a warning and continue with the standalone disk — `up` must never
  fail because caching failed.
- **Chain check:** when a disk already exists, verify with `qemu-img info` that
  its backing file (if any) resolves; if not, error with the remedy "backing
  image missing from cache; run `openhvf destroy` and `openhvf up`" instead of
  letting QEMU fail opaquely at boot.

### 1.4 Keep the two CI caches rotating together

Phase 4 removes the `.openhvf` cache step, but until then a cached `.openhvf`
may contain an overlay referencing `~/.cache/openhvf/installed/<key>/...`. Add
`share/openhvf/expect/install.exp` to **both** `actions/cache` keys in
`.github/workflows/integration.yml` so a base-key rotation also rotates the
state cache, and note the coupling in a comment.

## Deliverables

- `lib/OpenHVF/ImageCache.pm` + `lib/OpenHVF/ImageCache.pod`
- Changes to `lib/OpenHVF/Disk.pm`, `lib/OpenHVF/VM.pm`, `lib/OpenHVF/Expect.pm`
  (script-path accessor)
- `t/openhvf/imagecache.t`; extended `t/openhvf/disk.t` and `t/openhvf/vm.t`
- Key-coupling edit to `.github/workflows/integration.yml`

## Acceptance criteria

- Unit tests cover: key stability and rotation (each input changes the key),
  lookup miss on empty/partial entries, store/lookup round-trip including
  metadata and permissions, and overlay creation with a qcow2 backing file.
  Tests skip gracefully when `qemu-img` is unavailable, per `t/` conventions.
- On a host with QEMU: `openhvf up` (cold) installs and populates
  `installed/<key>/`; `openhvf destroy && openhvf up` (warm) reaches "VM ready"
  with no installer run and no miniroot download, and `openhvf ssh` works —
  key-installed via the seeded root password.
- Disabling or corrupting the cache entry degrades to a full install with a
  warning, not a failure.
- `make check` stays green.
