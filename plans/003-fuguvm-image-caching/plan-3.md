# Phase 3 — Named snapshots

A generic layer verb over the same backing-chain mechanism, so scripts can cache
states fuguvm knows nothing about — the motivating consumer is `vm-provision`
caching its `make deps` result (wired up in phase 4). Mechanism lives here;
policy stays in the scripts.

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

### 3.1 `FuguVM::ImageCache` snapshot primitives

- `snapshot_store($key, $name, $disk_path, $meta)` — flatten the (stopped)
  working overlay into `snapshots/`, atomically, 0400, with
  `qemu-img convert -O qcow2 -B <absolute .../base.qcow2> -F qcow2` so the
  snapshot's parent is always `base.qcow2`. Do not plain-copy the overlay: a
  copy carries the backing-file header verbatim, which is only correct while the
  working disk hangs directly off the base. After a `snapshot restore` it hangs
  off a snapshot, so a copy would either stack chains without bound or — when
  the same name is re-saved, which phase 4's deps layer does on a normal second
  run — publish a qcow2 that names itself as its own backing file. Flattening
  also keeps the model above true, so no snapshot is ever another snapshot's
  parent and `snapshot rm` cannot orphan one. Validate `$name` like VM names (no
  `/`, no NUL, bounded length).
- `snapshot_lookup($key, $name)`, `snapshot_list($key)`,
  `snapshot_remove($key, $name)`.
- Snapshot metadata records the state fields the disk embodies at save time:
  `installed`, the installed SSH public key, and the root password (copied from
  the base's `meta.json`), so restore can reseed `FuguVM::State` and the
  existing `_needs_ssh_key_update` path reconciles a different per-checkout key
  afterwards.

### 3.2 CLI verb

- `fuguvm snapshot save <name>` — requires an existing, installed, **stopped**
  VM (`EXIT_VM_RUNNING` otherwise; a live overlay copy is not consistent).
  Requires the disk to resolve to a cached base, whether directly or through a
  snapshot — re-saving after a restore is normal. Only a standalone disk (from
  `--no-cache` or a pre-phase-1 state) is a diagnosed error, not a crash. Add
  `EXIT_VM_RUNNING` and the missing-snapshot code to `FuguVM::CLI`'s existing
  exit-code set rather than inventing local numbers.
- `fuguvm snapshot restore <name>` — VM stopped; unlinks the working disk and
  recreates it as a fresh overlay backed by the snapshot (`Disk::create` returns
  early on an existing path, so a restore that skips the unlink reports success
  while changing nothing), then reseeds state from snapshot metadata. Missing
  snapshot returns a distinct, scriptable failure so callers can do
  `restore || provision-from-scratch`. Verify the snapshot's own chain resolves
  and report a broken snapshot as a miss, so that same idiom recovers instead of
  failing hard.
- Restore must also work from nothing — no working disk, no state — because
  phase 4 calls it on a fresh checkout before `fuguvm up`. Only `save` requires
  an existing installed VM.
- `fuguvm snapshot list` / `fuguvm snapshot rm <name>` — scoped to the current
  configuration's key; `cache list` gains real snapshot counts.

### 3.3 Documentation

- `man/fuguvm/fuguvm.1`: snapshot subcommand, the consistency rule (VM must be
  stopped), and the invalidation relationship to the base key.
- `.pod` updates for the new `ImageCache` methods.

## Deliverables

- Changes to `lib/FuguVM/ImageCache.pm` (+ `.pod`), `lib/FuguVM/CLI.pm`
- Extended `t/fuguvm/imagecache.t` and `t/fuguvm/cli.t`
- `man/fuguvm/fuguvm.1` updates

## Acceptance criteria

- Unit tests cover: name validation, store/lookup/list/remove round-trips,
  restore reseeding state, restore into an empty state directory (no disk, no
  state — the shape phase 4 uses), restore over an existing disk actually
  replacing it, the running-VM and standalone-disk refusals, and the scriptable
  missing-snapshot exit code.
- A stored snapshot's backing file is `base.qcow2` even when it was saved from a
  disk that had been restored from another snapshot; re-saving the same name
  twice leaves a resolvable chain.
- On a host with QEMU: `up` (warm base) → mutate guest → `down` →
  `snapshot save s1` → mutate guest again → `down` → `snapshot restore s1` →
  `up` shows the first mutation and not the second.
- `destroy` (empty state directory) → `snapshot restore s1` → `up` → `ssh`
  works, exercising the reseed-from-nothing path phase 4 depends on.
- `fuguvm ssh` works after a restore in a checkout with a different SSH key than
  the one saved (exercises reseeded password + key reinstall).
- `make check` stays green.
