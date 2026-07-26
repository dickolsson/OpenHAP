# Phase 3 — Named snapshots

A generic layer verb over the same backing-chain mechanism, so scripts can cache
states openhvf knows nothing about — the motivating consumer is
`vm_provision.sh` caching its `make deps` result (wired up in phase 4).
Mechanism lives here; policy stays in the scripts.

## Model

A snapshot is an immutable copy of the working overlay, stored under the base it
was created against:

```
installed/<key>/snapshots/<name>.qcow2   # 0400, references base.qcow2
installed/<key>/snapshots/<name>.json    # 0600, state fields + created_at
```

Chain after a restore: `base.qcow2 ← <name>.qcow2 ← disk.qcow2`. Storing
snapshots inside `installed/<key>/` means base invalidation (new key,
`cache clear`) invalidates the snapshots that depend on that exact base file,
for free.

## Tasks

### 3.1 `OpenHVF::ImageCache` snapshot primitives

- `snapshot_store($key, $name, $disk_path, $meta)` — copy the (stopped) working
  overlay into `snapshots/`, atomically, 0400. The overlay's absolute backing
  reference to `base.qcow2` stays valid because bases are immutable. Validate
  `$name` like VM names (no `/`, no NUL, bounded length).
- `snapshot_lookup($key, $name)`, `snapshot_list($key)`,
  `snapshot_remove($key, $name)`.
- Snapshot metadata records the state fields the disk embodies at save time:
  `installed`, the installed SSH public key, and the root password (copied from
  the base's `meta.json`), so restore can reseed `OpenHVF::State` and the
  existing `_needs_ssh_key_update` path reconciles a different per-checkout key
  afterwards.

### 3.2 CLI verb

- `openhvf snapshot save <name>` — requires an existing, installed, **stopped**
  VM (`EXIT_VM_RUNNING` otherwise; a live overlay copy is not consistent).
  Requires the disk to be an overlay of a cached base (standalone disks from
  `--no-cache` or pre-phase-1 states are a diagnosed error, not a crash).
- `openhvf snapshot restore <name>` — VM stopped; replaces the working disk with
  a fresh overlay backed by the snapshot and reseeds state from snapshot
  metadata. Missing snapshot returns a distinct, scriptable failure so callers
  can do `restore || provision-from-scratch`.
- `openhvf snapshot list` / `openhvf snapshot rm <name>` — scoped to the current
  configuration's key; `cache list` gains real snapshot counts.

### 3.3 Documentation

- `man/openhvf/openhvf.1`: snapshot subcommand, the consistency rule (VM must be
  stopped), and the invalidation relationship to the base key.
- `.pod` updates for the new `ImageCache` methods.

## Deliverables

- Changes to `lib/OpenHVF/ImageCache.pm` (+ `.pod`), `lib/OpenHVF/CLI.pm`
- Extended `t/openhvf/imagecache.t` and `t/openhvf/cli.t`
- `man/openhvf/openhvf.1` updates

## Acceptance criteria

- Unit tests cover: name validation, store/lookup/list/remove round-trips,
  restore reseeding state, the running-VM and standalone-disk refusals, and the
  scriptable missing-snapshot exit code.
- On a host with QEMU: `up` (warm base) → mutate guest → `down` →
  `snapshot save s1` → mutate guest again → `down` → `snapshot restore s1` →
  `up` shows the first mutation and not the second.
- `openhvf ssh` works after a restore in a checkout with a different SSH key
  than the one saved (exercises reseeded password + key reinstall).
- `make check` stays green.
