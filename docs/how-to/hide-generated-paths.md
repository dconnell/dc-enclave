# Hide generated paths from the host

By default, `/workspace` is the project root assembled from one read-write bind mount per repo at `/workspace/<repo-name>` plus the managed `/workspace/.cache` cache volume — each repo inside the container is a live view of its host repo directory. That works well for source code, but generated paths such as `node_modules`, build caches, and compiled output don't belong on the host. They can contain thousands of files, platform-specific binaries, and large caches that are meaningless or even harmful on the host filesystem.

The `--hide` flag solves this by mounting a named container volume over a `/workspace`-relative path so its contents live inside the container's volume store instead of on the host.

### Why use `--hide`

- **Bind-mount performance** — On macOS (Docker Desktop, OrbStack, Colima) and WSL2, bind mounts crossing the VM boundary are slow for heavy file I/O. A directory like `node_modules` with tens of thousands of tiny files can make `npm install`, `git status`, and file watchers slow. Moving it to a named volume restores native filesystem speed.

  On a native Linux host running Podman or Docker with no VM, bind mounts are already native-speed, so performance is not a reason to use `--hide` there — but platform correctness and host cleanliness still apply.
- **Platform correctness** — Native dependencies (e.g. `node-gyp` binaries, Go build artifacts) compiled inside the Linux container are not compatible with a macOS or Windows host. Keeping them in a container-only volume avoids platform mismatch errors.
- **Host cleanliness** — Generated output, caches, and lock-file side effects won't clutter your host checkout, won't confuse `git status`, and won't risk accidental commits.

### Usage

`--hide` accepts one or more comma-separated paths and can be repeated. Paths are relative to `/workspace`:

```
dce new myapp nodejs --hide node_modules 3000:3000
dce new monorepo nodejs,golang \
  --repo ~/repos/monorepo/web \
  --repo api=~/repos/monorepo/api \
  --hide web/node_modules,api/node_modules \
  3000:3000 8080:8080
```

### Repo-prefixed paths

Hidden paths are `/workspace`-relative and persisted repo-prefixed, because each repo binds at `/workspace/<repo-name>`:

- **Single-repo projects** — an unprefixed path is auto-prefixed with the repo name: `--hide node_modules` persists as `<repo>/node_modules`.
- **Multi-repo projects** — values must name the repo (`web/node_modules`); an ambiguous unprefixed path is rejected.
- **`.cache` is reserved** — `/workspace/.cache` is the dce-managed persistent cache volume, so `.cache` (and anything under `.cache/`) is rejected as a hidden path.

### How it works

- Each hidden path gets a deterministic named volume (`dce-hide-<project>-<hash>`) mounted at `/workspace/<path>`.
- After container start, dce ensures the hidden mount points are writable by the `dev` user (root `mkdir`/`chown` fallback applied across all backends).
- Hidden paths are persisted in the project config (`CONTAINER_HIDDEN_PATHS`) and automatically remounted on `dce rebuild-container`.
- **`dce rebuild-container` removes hidden volumes by default** for a clean slate (fresh dependency install, no stale caches). Use `--keep-hidden-volumes` to preserve them.
- For Docker-compatible backends, hidden paths are also added as mounts to the managed `devcontainer.json` (`~/.config/dce-enclave/<project>/devcontainer.json`) so VS Code Dev Containers uses the same layout. Existing files are preserved; if managed fields drift, `dce new` / `dce rebuild-container` print a notice and you can reconcile with `dce config sync-vscode <name>` (`--dry-run` previews only).

### Cleaning up hidden volumes

Hidden volumes are removed automatically during `dce rebuild-container` (default behavior) so the rebuilt container starts clean. To reclaim space from orphaned volumes left behind by deleted projects:

```
dce clean --hidden-volumes --dry-run    # preview what would be removed
dce clean --hidden-volumes              # remove orphan hidden volumes
dce clean --hidden-volumes myproject    # scope to one project
```

Only `dce-hide-*` managed volumes that no longer correspond to an active project config are removed.

## See also

- [Overlays: install-on-start behavior](../reference/overlays.md#install-on-start-behavior) — how overlays auto-sync dependencies (e.g. `npm ci`) into hidden volumes on container start, including the trusted-vs-untrusted matrix.
- [Example overlays](../../Containerfiles/example/README.md) — per-language `--hide` paths and sync commands.
