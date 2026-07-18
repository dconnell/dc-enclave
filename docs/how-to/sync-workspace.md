# Sync the workspace onto native ext4 (`--sync`)

By default the entire workspace is a **bind mount**: `/workspace` inside the
container is a live view of the host repos directory. That keeps exactly one
copy of the source — on the host — and is the default you should start with.

On VM-backed backends (Docker Desktop, OrbStack, Colima, Podman Machine on
macOS/WSL2) that bind mount crosses the VM boundary through VirtioFS. Every
per-file syscall (`stat`, `open`, `read`, file-watch event) is a host↔VM round
trip. For large repos with heavy small-file workloads (Nx/Vite, module
federation, big `git status` walks) this can make the container feel unusable
even though the same checkout is fast on the host. VirtioFS through any Mac VM
is already the fastest bind mount available — there is no faster one to switch
to.

`--sync` is the escalation path. It **replaces** the `/workspace` bind mount with
a Mutagen-synced named volume (`dce-sync-<slug>-<12hex>`) mounted at the **same
`/workspace` path**, so source-tree file I/O stays on the container VM's native
ext4 instead of crossing VirtioFS on every syscall. The host checkout stays
canonical; Mutagen reconciles changes both ways.

> `--sync` is **opt-in and not the default**. It adds a host-side daemon and a
> second copy of the tree. Use it only when the bind mount is too slow. For
> keeping just `node_modules`/caches off the host (the common ask),
> [`--hide`](hide-generated-paths.md) is simpler and is the default accelerator.

## When to use it

- A large repo (Nx monorepo, Vite/module-federation) where dev-server file
  serving, file watchers, or `git status` are slow **inside** the container but
  fast on the host.
- You've already tried `--hide` for `node_modules`/caches and the *source tree
  itself* is still the bottleneck.

On a **native Linux host** (no VM) bind mounts are already native-speed, so
`--sync` there brings no benefit — don't use it. `--sync` is a VM-backend feature.

## The model (read this first)

- **Two-way sync, host canonical.** Mutagen runs alpha=host, beta=the sync
  volume, with host-wins conflict resolution. Container-side edits (AI agents,
  editors running inside) reconcile back to the host — the same property the
  read-write bind mount already gives you. A one-way sync would silently drop
  container-side edits on the next rebuild.
- **`/workspace` does not move.** The sync volume is mounted at `/workspace` —
  the same path the bind mount uses. No tooling, editor target, or doc path
  changes; only the storage backing `/workspace` changes.
- **Rebuild stays data-loss-free.** The sync volume is preserved across rebuild
  (never in the clean-slate removal path) and a `mutagen sync flush` drains
  pending container→host changes before the container is destroyed, so no
  container-side edit is lost to sync lag.
- **Snapshots exclude the sync volume.** The host is canonical, so the source's
  authoritative state lives on the host, not in any volume. `--from-snap`
  re-mounts the live sync volume and reconnects the session.

## Usage

```
dce new monorepo nodejs --sync --sync-ignore node_modules,.nx,dist 3000:3000
```

- `--sync` swaps the bind mount for the synced volume.
- `--sync-ignore` (comma list, repeatable, same grammar as `--hide`) excludes
  workspace-relative paths from Mutagen sync. Excluded paths live on the sync
  volume's native ext4 (fast) but are never replicated to/from the host.

`--sync` and `--hide` are **mutually exclusive**. They belong to different
worlds: under the bind mount you exclude generated paths with `--hide`; under
`--sync` you exclude them with `--sync-ignore` on the one sync volume (no second
volume needed). `--sync-ignore` without `--sync` is rejected. The same
mutual-exclusion rule is enforced on the merged recipe+CLI inputs too (for
example, a recipe with `sync=1` plus CLI `--hide` fails fast).

### Why the recommended Node shape includes `--sync-ignore`

Without `--sync-ignore`, the **entire** tree — including `node_modules`, `dist`,
build caches — runs on native ext4 (the perf win) **but** Mutagen also pushes
those generated paths back to the host: host clutter, Linux-specific binaries on
a macOS host, and real host I/O on every install. The recommended shape keeps
those on ext4 but off the host:

```
dce new monorepo nodejs --sync --sync-ignore node_modules,.nx,dist 3000:3000
```

The overlay install-on-start hook repopulates an empty `node_modules` on first
start regardless of *why* it's empty (hidden volume, sync-ignored, or a fresh
volume), so `--sync-ignore node_modules` still gets `npm ci` on start.

### `.git` syncs by default

`.git` is replicated to the volume so in-container git is fast. For a repo with
huge packfiles where the initial sync or `git gc` is expensive, opt out with
`--sync-ignore .git` (or a scoped subset) — no special-casing needed.

## Backend support

`--sync` works identically across the docker-family backends:

| Backend | Supported | Transport |
| --- | --- | --- |
| docker | yes | Mutagen docker transport |
| orbstack | yes | Mutagen docker transport |
| colima | yes | Mutagen docker transport |
| podman | **no** | Mutagen has no podman transport, and the docker-transport bridge to a podman-machine VM is blocked by SSH host-key verification (the socket lives inside the VM). Fails fast — use `--hide`, or docker/orbstack/colima for `--sync`. |
| apple/container | **no** | no Mutagen transport — fails fast (use `--hide`) |

`--sync` on apple or podman aborts before creating anything, pointing at
`--hide` (or a docker-family backend) as the available accelerator there.

## Installing Mutagen

`--sync` requires the `mutagen` CLI on the host (a host-side daemon, not an
in-container hook). dce verifies it is present and fails fast with a hint if not;
it never installs it for you.

- **macOS:** `brew install mutagen-io/mutagen/mutagen`
- **Linux:** install the release binary from the official Mutagen release archive

Then re-run your `dce new ... --sync` command.

## Lifecycle under `--sync`

- **`dce new --sync`** — verifies Mutagen, creates the `dce-sync-<slug>-<12hex>` volume,
  mounts it at `/workspace`, then `mutagen sync create` host→volume with
  `--sync-ignore` rules and dev-coerced ownership. The first create does a full
  host→volume copy (minus ignored paths); for a large repo this is **minutes,
  not seconds** — progress is surfaced.
- **`dce start`** — `mutagen sync resume` (idempotent; covers a host reboot
  between stop/start).
- **`dce shell`** — for a synced project, prints a one-line sync state and
  (interactive entry only) **waits for the session to settle** before entering,
  so you never land in a half-synced `/workspace`. A one-shot command
  (`dce shell <name> <command>`) never waits; `--no-wait` or `DCE_SYNC_NO_WAIT=1`
  opts out. See [Watch sync state](#watch-sync-state).
- **`dce editor`** — same settle wait before launching the editor, so VS Code's
  attached terminal opens into a synced tree. `--no-wait` / `DCE_SYNC_NO_WAIT=1`
  opt out.
- **`dce stop`** — leaves the session (Mutagen tolerates a down beta and
  retries). Nothing is destroyed.
- **`dce rebuild-container`** — while the container is still running, flushes
  pending changes, then destroys the container,
  recreates it re-mounting the **same** preserved volume, then reconnects the
  session. Sub-second container recreation; no source re-copied. Pass
  `--sync-ignore` to adjust the ignore set (the session is recreated).
- **`dce rm`** — `mutagen sync terminate`, then removes the sync volume. The
  host checkout is never touched (honors `--keep-volumes`).
- **`dce snapshot`** — the sync volume is **excluded** (host is canonical);
  `--from-snap` is not combinable with `--sync`.

## Watch sync state

Mutagen runs on the **host**, so authoritative sync state is a host-side
concern. The one command to reach it:

```bash
dce sync-status myapp            # live stream (Ctrl-C to stop)
dce sync-status myapp --once     # one-shot snapshot
```

This resolves the project's session name (`dce-sync-<slug>-<12hex>`) for you
and runs `mutagen sync monitor` (live, default) or `mutagen sync list`
(`--once`). It refuses fast with the fix command if the project isn't synced,
Mutagen is absent, or no session exists.

**At entry.** `dce shell` and `dce editor` print a one-line sync state and, by
default, wait for the session to settle before entering (interactive shell /
editor only). While waiting on a TTY, the line refreshes live with the current
Mutagen phase, elapsed seconds, and the total file count being synced — e.g.
`Sync: staging files on beta · 3s · 27,533 files`. The phase transitions
(scanning → staging → applying → watching) plus the ticking seconds are the
progress signal; the file count gives the scale. (Mutagen stages to a side
directory and applies atomically, so a per-file countdown is not meaningful
during staging — watch the phase instead.) The wait is bounded
by `DCE_SYNC_ENTRY_WAIT_TIMEOUT` (default 600s) and is always interruptible
with Ctrl-C. Disable it with `--no-wait` or `DCE_SYNC_NO_WAIT=1`:

```bash
dce shell --no-wait myapp
DCE_SYNC_NO_WAIT=1 dce editor myapp
```

A paused session (conflict) never blocks — dce warns and points at
`mutagen sync resolve`. `dce doctor` also reports one-word session health.

**From inside the container** there is no first-class sync signal (Mutagen is
host-only). As a rough proxy, `du -sh /workspace` converges as reconciliation
proceeds; for authoritative state run `dce sync-status <name>` on the host.

## Ownership and conflicts

- **Ownership is coerced to `dev`.** Mutagen would otherwise preserve host
  UIDs/GIDs and break the `dev`-owned workspace the base image expects. Ignored
  paths are untouched by Mutagen; whatever creates them owns them (npm runs as
  `dev` → `dev`-owned).
- **Conflicts pause the whole session.** Mutagen halts on the first conflict and
  stops syncing *everything* until resolved. The symptom (edits not appearing)
  is silent. `dce doctor` surfaces "session paused: N conflicts" and points at
  `mutagen sync resolve`; dce does not invent its own conflict UI.

## Workspace-type messaging

At create, dce bakes `--env DCE_WORKSPACE_TYPE=sync` into the container. Every
interactive shell (`dce shell`, VS Code Dev Containers terminal, Codespaces)
prints a one-line banner: `workspace: synced (mutagen) — host is canonical`. The
host-side `dce shell` banner also shows the type before entering the container.

## See also

- [Hide generated paths from the host](hide-generated-paths.md) — the
  bind-mount-world analog of `--sync-ignore`; the simpler choice when only
  `node_modules`/caches are the problem.
- [Rebuild and recover](rebuild-and-recover.md) — the sync volume is preserved
  across rebuild; a flush runs pre-destroy.
- [Snapshot and roll back](snapshot-and-rollback.md) — the sync volume is
  excluded from snapshots (host is canonical).
- [Flags reference](../reference/flags.md) — `--sync`, `--sync-ignore` semantics.
