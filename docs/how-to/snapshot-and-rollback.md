# Snapshot and roll back a container

A **snapshot** commits a container's filesystem to a tagged image, saving a
state you can return to later. It's an independent operation you can run at any
time — before a risky change, before a `dce rebuild-container`, or simply to
preserve a state you want to keep around — without touching your host repos.
Restoring one is opt-in (`dce rebuild-container --from-snap`); snapshots are
otherwise inert until you reclaim them.

## What a snapshot captures (and doesn't)

A snapshot is **filesystem-layer only**: the image plus the container's writable
layer. It never captures:

- **named (hidden) volumes** — e.g. `node_modules`, build caches. Those are
  governed by the existing `--keep-hidden-volumes` rebuild logic.
- **the bind-mounted repo** — your host working tree was never at risk anyway.

So `--from-snap` restores the filesystem layer; hidden-volume state follows
whatever `--keep-hidden-volumes` (or its absence) decides. Snapshots live in the
active backend's local image store only — they are not pushed to a registry.

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

The table shows the label, project, size, UTC time, and the base image the
container was running when the snapshot was taken.

## Restore from a snapshot

```
dce rebuild-container myapp --from-snap before-rust-upgrade
```

This recreates the container from the snapshot image instead of the
scope-derived one. It is a **one-off restore**: it bypasses scope derivation and
does **not** rewrite `CONTAINER_IMAGE`. Afterward the container reads "stale" in
`dce list` / `dce status` until the next normal rebuild — this is correct (the
container genuinely diverges from its configured image), not an error.

Restore is filesystem-layer only. To keep `node_modules` and other hidden-volume
state across the restore, add `--keep-hidden-volumes` (independent of the
snapshot):

```
dce rebuild-container myapp --from-snap before-rust-upgrade --keep-hidden-volumes
```

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
