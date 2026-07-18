# Snapshot and roll back a container

A **snapshot** commits a container's filesystem (and, by default, its hidden
volumes) to a tagged image, saving a state you can return to later. It's an
independent operation you can run at any time — before a risky change, before a
`dce rebuild-container`, or simply to preserve a state you want to keep around —
without touching your host repos. Restoring one is opt-in
(`dce rebuild-container --from-snap`); snapshots are otherwise inert until you
reclaim them.

## What a snapshot captures (and doesn't)

A snapshot captures:

- the **filesystem image** (the container's image plus its writable layer), and
- each **hidden volume** (`node_modules`, caches) by default — cloned into a
  snapshot-specific volume so a restore brings back dependency/cache state too.

It never captures:

- **the bind-mounted repo** — your host working tree was never at risk anyway.
  Under [`--sync`](sync-workspace.md) this is *stronger*: the host is explicitly
  canonical, so the sync volume (`dce-sync-<slug>-<12hex>`) is also excluded from
  snapshots — snapshotting it would be meaningless. A `--from-snap` restore
  re-mounts the live sync volume and reconnects the session instead. (`--sync`
  and `--from-snap` are mutually exclusive.)
- **injected credentials** — the SSH deploy key (`~/.ssh/id_ed25519`) and, under
  PAT auth, `~/.git-credentials` are removed from the writable layer *before* the
  commit, so they are never baked into the snapshot image. (The read-only
  bind-mounted `.npmrc` is also excluded — bind mounts aren't committed.)

Snapshot images are still **shareable artifacts**: anyone who exports, inspects,
restores, or shares one can read everything in the filesystem layer. The
credential scrub means your SSH key and git token are not in that layer, but
treat any snapshot image as sensitive anyway (it contains your code, config, and
history) and avoid exporting or sharing it unless you mean to. A failed scrub is
stamped on the image as the `dce.snapshot.cred_scrub=failed` label and called out
with a WARNING at snapshot time — in that case the snapshot may still contain
credentials, so do not share it.

So `--from-snap` restores the filesystem and the captured volumes, leaving the
live originals untouched. (Use `--exclude-volumes` to skip volume capture — see
below.) Snapshots live in the active backend's local image store only — they are
not pushed to a registry.

## Hidden volumes are captured by default

A snapshot is a complete restore point: it captures the filesystem image AND
each hidden volume (`node_modules`, caches) — so a restore brings back your
dependency/cache state too, not just the filesystem. You don't need a flag:

```
dce snapshot myapp before-rust-upgrade
```

This clones each hidden volume into a snapshot-specific volume
(`dce-snapvol-*`), in the same stop window as the filesystem commit. Two
guarantees:

- **The source is mounted read-only during the copy.** The copy runs as root; a
  read-only source makes it structurally impossible for a copy bug to corrupt
  the live volume your normal rebuilds depend on.
- **A restore always isolates volumes.** `dce rebuild-container --from-snap
  <label>` mounts the captured volumes (populated) and leaves the live originals
  untouched. It reports each volume as **populated** or **empty**. A volume is
  empty with a warning if it was excluded (below), the copy failed, or the path
  was added after the snapshot — it is never silently reused from the live
  volumes, and restore never fails fast over a missing volume.

A failed volume copy does **not** abort the snapshot: the filesystem image still
succeeds, the failed volume is left empty, and a WARNING names the path to
reinstall. `dce snapshots list` shows `captured N` (and any failures/excluded)
per snapshot.

Because copying volumes is slow and uses disk proportional to their size, the
command lists the volumes it will copy and asks for confirmation first:

```
This snapshot will copy 2 hidden volume(s):
  - node_modules
  - .cache
Copying is proportional to their size and may be slow / use significant disk.
Type 'yes' to continue:
```

`--yes`/`-y` skips the prompt (for scripting). The prompt only appears when
volumes will actually be copied.

### When you don't need the volumes: `--exclude-volumes`

Volume capture copies the full contents of every hidden volume, so it costs time
and disk proportional to your deps. For a fast, small snapshot where you only
care about the filesystem, exclude volumes:

```
dce snapshot myapp quick-config --exclude-volumes
```

Excluded volumes come back EMPTY on restore (with a note) — they are not reused
from the live volumes, and no confirmation prompt appears (nothing to copy).

To exclude just **some** volumes (everything except the giant `node_modules`),
use `--exclude-volume`, which is repeatable and accepts a comma-separated list:

```
dce snapshot myapp deps-but-no-nm --exclude-volume node_modules
dce snapshot myapp --exclude-volume node_modules,.cache
```

Capture is the default precisely because a snapshot that doesn't capture your
actual working state isn't a full restore point.

Snapshot volumes are full copies, not deltas — reclaim them with `dce clean
--snapshots` (the default `dce clean` and `dce clean --hidden-volumes` ignore
them).

## Two workflows, one mechanism

1. **Restore a known-good state.** Snapshot before a risky change (a toolchain
   upgrade, a config experiment). If it breaks, rebuild clean and then restore.
2. **Preserve a suspect state for forensics.** Snapshot the *broken* container,
   then rebuild clean and inspect the snapshot image later. Only the first
   workflow uses `--from-snap`; forensics just keeps the snapshot around.

## Take a snapshot

```
dce snapshot myapp                       # label defaults to a sortable timestamp
dce snapshot myapp before-rust-upgrade   # give it a meaningful label
```

This stops the container, commits its filesystem to
`dce-snap-myapp-before-rust-upgrade:latest`, and restarts it. (A clean commit
requires a stopped container on every backend.) Labels use the charset
`[A-Za-z0-9_.-]` and cannot be reused — re-running the same label refuses to
overwrite (reclaim it first with `dce snapshot rm`).

## List snapshots

```
dce snapshots list                # every project, newest-first, with sizes
dce snapshots list myapp          # scoped to one project
```

The table shows the label, project, size, volumes captured (e.g. `captured 2`),
UTC time, and the base image the container was running when the snapshot was
taken.

## Restore from a snapshot

```
dce rebuild-container myapp --from-snap before-rust-upgrade
```

This recreates the container from the snapshot image instead of the
scope-derived one. It is a **one-off restore**: it bypasses scope derivation and
does **not** rewrite `CONTAINER_IMAGE`. Afterward the container reads "stale" in
`dce list` / `dce status` until the next normal rebuild — that's expected, since
the container genuinely diverges from its configured image.

Restore always isolates hidden volumes: each comes back **populated** (if the
snapshot captured it) or **empty** with a warning (if it was excluded, the copy
failed, or the path was added after the snapshot). The live originals are never
reused and never touched — `--keep-hidden-volumes` does not apply to a snapshot
restore. The restore prints each volume's disposition so you know which need a
reinstall.

## Reclaim disk

Snapshots are full writable-layer copies, not deltas, so they add up. The
default `dce clean` **never** touches them — reclamation is explicit:

```
dce clean --snapshots --dry-run        # preview sizes, remove nothing
dce clean --snapshots myapp            # reclaim one project's snapshots
dce clean --snapshots                  # reclaim all snapshots
dce snapshot rm myapp before-rust-upgrade   # remove a single snapshot
```

## Worked example: experiment, break, restore

```
dce snapshot myapp before-big-refactor      # safety net
dce shell myapp "make big-risky-change"     # ...it breaks the environment
dce rebuild-container myapp                 # clean rebuild from the image
# still broken? roll back to the known-good filesystem:
dce rebuild-container myapp --from-snap before-big-refactor
```
