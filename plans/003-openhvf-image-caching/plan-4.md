# Phase 4 — CI adoption and provisioning snapshots

Move the Integration workflow onto the native cache and retire the
workflow-level disk archiving. `.openhvf` becomes fully ephemeral in CI; the
only cached artifact is `~/.cache/openhvf`.

## Tasks

### 4.1 Provisioning snapshot in the scripts

- `scripts/vm_provision.sh` computes a provisioning key — a short SHA-256 over
  `deps/OpenBSD.txt`, the `cpanfile` if present, and the provisioning sections
  of the script itself — and splits its guest work:
  1. **Deps layer (cacheable):** `pkg_add -u`, cpanm bootstrap, `make deps`.
     Attempted first via `openhvf snapshot restore deps-<hash>`; on a miss, run
     the deps layer, then `openhvf down`, `openhvf snapshot save deps-<hash>`,
     `openhvf up`, `openhvf wait`. The stop/start cost is paid only when
     dependencies actually changed.
  2. **OpenHAP layer (never cached):** build tarball, scp, `make install`,
     user/service setup — unchanged, runs every time.
- Snapshot restore requires a stopped VM, so the restore attempt belongs in
  `scripts/vm_up.sh` before `openhvf up`, guarded to run only when no working
  disk exists yet; it exports whether the deps layer was restored so
  `vm_provision.sh` can skip it. Keep the exact split simple and legible — the
  scripts own this policy, openhvf only provides the verbs.
- Prune old provisioning snapshots: after a successful save, remove `deps-*`
  snapshots other than the current hash.

### 4.2 Workflow simplification

In `.github/workflows/integration.yml`:

- Replace the two cache steps ("Cache OpenBSD miniroot image", "Cache
  provisioned VM disk") with a single step caching `~/.cache/openhvf`:
  - `key`: runner arch +
    `hashFiles('.openhvfrc', 'share/openhvf/expect/install.exp', 'deps/OpenBSD.txt', 'scripts/vm_provision.sh')`
  - `restore-keys`: the arch-scoped prefix, so a key rotation still restores the
    miniroot, still-valid bases, and lets openhvf's own keying decide what is
    reusable. `actions/cache` saves on miss, so a rotated key re-saves the
    updated cache automatically.
- Run `./bin/openhvf cache clear --stale` in the post-test cleanup step to bound
  cache growth before the save.
- Drop the `.openhvf`-specific choreography that existed only for archiving: the
  socket `find -delete` and the cache-consistency comments. Keep the
  `openhvf down` step itself — a clean shutdown is still correct hygiene and
  keeps the qcow2 consistent for the snapshot machinery.
- Keep the ephemeral-SSH-key step; note that it now interacts only with the
  guest, not with any cached artifact, since `.openhvf` is no longer saved.

### 4.3 Documentation

- Update the workflow comments to describe the new single-cache model.
- Update the `integration-tests` skill only if its operator procedure changes;
  behavior reference stays in `openhvf.1` and the workflow file.

## Deliverables

- Changes to `scripts/vm_up.sh`, `scripts/vm_provision.sh`,
  `.github/workflows/integration.yml`

## Acceptance criteria

- Two consecutive Integration runs on the same tree: the first (cold) run
  installs, provisions, and populates the cache; the second (warm) run performs
  no OS install and no `make deps` package installation, with a clearly lower
  job wall-clock, and the full suite stays green on both.
- A run after touching `deps/OpenBSD.txt` re-runs only the deps layer (new
  snapshot), not the OS install; a run after touching `install.exp` re-runs the
  OS install (new base key).
- `.openhvf` no longer appears in any `actions/cache` path; no run depends on a
  previous run's state directory.
- `make integration` still works unchanged on a developer machine with no
  GitHub-specific assumptions.
