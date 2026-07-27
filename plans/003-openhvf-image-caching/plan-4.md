# Phase 4 — CI adoption and provisioning snapshots

Move the Integration workflow onto the native cache and retire the
workflow-level disk archiving. `.openhvf` becomes fully ephemeral in CI; the
only cached artifact is `~/.cache/openhvf`.

## Tasks

### 4.1 Provisioning snapshot in the scripts

- `scripts/vm-provision` computes a provisioning key — a short SHA-256 over
  `deps/OpenBSD.txt`, `scripts/deps`, the `cpanfile` if present, and the
  provisioning sections of the script itself — and splits its guest work:
  1. **Deps layer (cacheable):** `pkg_add -u`, cpanm bootstrap, `make deps`.
     Attempted first via `openhvf snapshot restore deps-<hash>`; on a miss, run
     the deps layer, then `openhvf down`, `openhvf snapshot save deps-<hash>`,
     `openhvf up`, `openhvf wait`. The stop/start cost is paid only when
     dependencies actually changed.
  2. **OpenHAP layer (never cached):** `make install`, user/service setup —
     unchanged, runs every time.
- `scripts/deps` must be in the key: `make deps` is driven by it, and today's
  workflow key omits it too, so editing it currently leaves the cached guest
  stale — the same incomplete-invalidation class this plan exists to fix.
- **Tarball first.** `make deps` only exists inside the extracted tarball
  (`Makefile:55-56`, `DEPS = scripts/deps`, and `deps` reads `deps/${OS}.txt`
  relative to cwd); all three reach the guest via the package. So building,
  scp'ing and extracting the tarball must happen BEFORE the deps layer, not with
  `make install` after it — otherwise layer 1's `cd /tmp/openhap-*` matches
  nothing and aborts under `set -e` on every run. Copying only `Makefile`,
  `scripts/deps` and `deps/` for that layer is an equally valid split; pick one
  and say which.
- **Leave no versioned tree in the snapshot.** `TAG` derives from
  `git rev-list --count HEAD`, and `vm-provision` currently removes only
  `openhap`, not `openhap-*`. A snapshot that bakes in `/tmp/openhap-<TAG>/`
  makes the later `cd /tmp/openhap-*` multi-match on the next commit and abort
  under `set -e`. `rm -rf /tmp/openhap-*` before `snapshot save`, or widen the
  existing cleanup.
- **No handoff variable.** `vm-up` and `vm-provision` are sibling make recipes
  in separate shells (`Makefile:208-212`, no `.ONESHELL`, no
  `.EXPORT_ALL_VARIABLES`), so an exported flag cannot reach the consumer — it
  would always read "not restored", making every warm run redo `make deps` and
  the stop/start, silently, with the suite still green. Let `vm-provision`
  decide from evidence in its own process: a guest-side marker written as the
  last step of the deps layer, before `openhvf down`, e.g.
  `vm_run 'test -f /var/db/openhvf-deps-<hash>'`. Guest-side rather than
  host-side, because the marker travels inside the snapshot layer and also
  answers the local case where nothing was restored but the working disk already
  carries the deps. `snapshot list` is a cross-check only — a snapshot existing
  in the cache says nothing about what the current disk is backed by.
- The restore attempt still belongs in `scripts/vm-up` before `openhvf up`,
  guarded to run only when no working disk exists yet. Keep the split simple and
  legible — the scripts own this policy, openhvf only provides the verbs.
- Both `snapshot restore` and `snapshot save` run under `set -e` while a
  best-effort base-cache miss legitimately leaves a standalone disk, which phase
  3 makes a diagnosed `save` error. Guard them script-side (`|| warn`) so a
  cache miss cannot abort provisioning; do not soften the verb.
- Prune old provisioning snapshots: after a successful save, remove `deps-*`
  snapshots other than the current hash. Safe because phase 3 flattens snapshots
  onto `base.qcow2`, so no `deps-*` snapshot is another one's parent.

### 4.2 Workflow simplification

In `.github/workflows/integration.yml`:

- Drop `.openhvf` from the merged cache step phase 1 created, leaving a single
  step caching `~/.cache/openhvf` alone:
  - `key`: runner arch + the manual `v<N>` lever +
    `hashFiles('.openhvfrc', 'share/openhvf/expect/install.exp', 'share/openhvf/cache-generation', 'deps/OpenBSD.txt', 'scripts/deps', 'scripts/vm-provision')`
  - `restore-keys`: the arch-scoped prefix, so a key rotation still restores the
    miniroot, still-valid bases, and lets openhvf's own keying decide what is
    reusable.
  - State the save rule precisely, because it constrains the key: the post-step
    saves only on a **primary-key miss**, so a rotated key re-saves
    automatically, while any input the workflow key does not hash can never be
    persisted at all — which is why the generation counter is a hashed file and
    not a constant.
- Run `./bin/openhvf cache clear --stale || true` in the post-test cleanup step
  to bound cache growth before the save. The `|| true` is not optional: that
  step is `if: always()`, `run:` blocks are `bash -e`, and the cache post-step
  is `post-if: success()`, so any non-zero exit there would discard the cache
  the run just populated. No cleanup command may determine job status. A
  `--stale` prune gated on `success()` would instead skip exactly the red runs
  where the cache grows, so keep it unconditional and guarded.
- Drop the `.openhvf`-specific choreography that existed only for archiving: the
  socket `find -delete` and the cache-consistency comments. Keep the
  `openhvf down` step itself — a clean shutdown is still correct hygiene and
  keeps the qcow2 consistent for the snapshot machinery.
- Keep the ephemeral-SSH-key step, and correct its comment rather than extending
  it: the key is still written to the global `~/.openhvfrc` to keep the project
  `.openhvfrc` hash stable, since that file is still hashed into the surviving
  cache key. What changes is only that no `.openhvf` state directory is
  archived. The root password is not thereby removed from the cache — it moves
  into `meta.json` under `~/.cache/openhvf`, which is still saved.

### 4.3 Documentation

- Update the workflow comments to describe the new single-cache model.
- Update the `integration-tests` skill's cold-cache procedure again: phase 1
  merged two keys into one, this phase changes what that key covers. Behavior
  reference stays in `openhvf.1` and the workflow file.

## Deliverables

- Changes to `scripts/vm-up`, `scripts/vm-provision`,
  `.github/workflows/integration.yml`

## Acceptance criteria

- Two consecutive Integration runs on the same branch (cache entries are
  branch-scoped, so "same tree" is not enough): the first (cold) run installs,
  provisions, and populates the cache; the second (warm) run performs no OS
  install and no `make deps` package installation, with a clearly lower job
  wall-clock, and the full suite stays green on both.
- The warm run's log shows the deps layer SKIPPED, not re-run. This is the
  criterion the handoff bug would have satisfied vacuously — every step is
  idempotent and the suite stays green either way — so check the log, not the
  exit status.
- A run after touching `deps/OpenBSD.txt` or `scripts/deps` re-runs only the
  deps layer (new snapshot), not the OS install; a run after touching
  `install.exp` or `share/openhvf/cache-generation` re-runs the OS install (new
  base key).
- `.openhvf` no longer appears in any `actions/cache` path; no run depends on a
  previous run's state directory.
- `make integration` works on a developer machine with a persistent `.openhvf`,
  twice in a row and across a commit that changes `TAG`, with no GitHub-specific
  assumptions.
