# Concepts and glossary

Short definitions for the terms used across these docs. Follow the links for fuller treatments.

## The project model

- **Project** — one isolated dev container plus its host-side config and secrets. Created by `dce new <name>`; lives under `~/.config/dce-enclave/<name>/`. Each project gets its own container, SSH key, optional PAT, and optional `.npmrc`.
- **Backend** — the container runtime `dce` drives: `apple` (apple/container), `docker`, `orbstack`, `colima`, or `podman`. Auto-detected or forced with `CONTAINER_BACKEND`. Details in [backends](backends.md).
- **Workspace** — the directory mounted at `/workspace` inside the container. By default a read-write bind mount of `${DC_REPOS_DIR:-$HOME/repos}/<project>` on the host; under `--sync`, a Mutagen-synced volume mounted at the same path. See [sync workspace](../how-to/sync-workspace.md).

## Images and overlays

- **Base image** (`dce-base:latest`) — the minimal shared image all projects start from. Built by `scripts/setup.sh`. Read more: [overlays](overlays.md#base-image-tools).
- **Overlay** — a Dockerfile fragment (`Containerfile.<scope>`) layered on top of `dce-base` to add a toolchain or capability. Lives in team or user overlay dirs. Read more: [overlay model](../explanation/overlay-model.md).
- **Scope** — a label that selects one or more overlays to compose into a derived image (e.g. `nodejs`, `golang`, `nodejs,golang`). The special `all` scope is auto-layered when present.
- **Derived image** (`dce-img-<hash>:latest`) — the composed image built from `dce-base` plus the project's effective overlay scopes. Identified by a deterministic content hash of the layered files.

## Configuration and roots

- **Team root** (`$DC_TEAM_DIR`) — shared team directory holding `overlays/`, `container-recipes/`, and `extensions/`. Typically a git checkout.
- **User root** (`$DC_USER_DIR`) — same layout as team root, but personal. Typically a git checkout.
- **Recipe** — a `key=value` file under `container-recipes/<name>` that supplies defaults for `dce new`. Loaded automatically by project name. Details in [configuration](configuration.md#container-recipes).
- **Project config** — `~/.config/dce-enclave/<name>/config`, written by `dce new` and edited via `dce config set`. Source of truth for the project's ports, scopes, mounts, resource limits, and backend.
- **Global config** — `~/.config/dce-enclave/config`, written by `setup.sh`. Holds `DC_TEAM_DIR` and `DC_USER_DIR`.

## Volumes and mounts

- **Hidden volume** (`dce-hide-<slug>-<hash>`) — a named volume mounted over a `/workspace`-relative path so its contents stay inside the container (e.g. `node_modules`). Created by `--hide`. See [hide generated paths](../how-to/hide-generated-paths.md).
- **Sync volume** (`dce-sync-<slug>-<12hex>`) — a Mutagen-synced named volume that replaces the bind mount at `/workspace` under `--sync`. See [sync workspace](../how-to/sync-workspace.md).
- **Snapshot volume** (`dce-snapvol-*`) — a captured clone of a hidden volume, created by `dce snapshot`. Used by `--from-snap` restores.

## Editor integration

- **Managed field** — a field in `.devcontainer/devcontainer.json` that `dce` owns (e.g. `build.dockerfile`, `mounts`, `forwardPorts`, `customizations.vscode.extensions`). User-edited keys are preserved; managed keys are reconciled by `dce config sync-vscode`.
- **Extension manifest** — plain-text file under `extensions/<editor>/<scope>.txt` declaring one editor extension ID per line. Layered like overlays.

## Trust and recovery

- **Snapshot** (`dce-snap-<name>-<label>:latest`) — a tagged image capturing a container's filesystem and (by default) its hidden volumes at a point in time. Restored with `dce rebuild-container --from-snap`. See [snapshots and rollback](../how-to/snapshot-and-rollback.md).
- **Provenance** — a per-project JSONL log plus OCI image labels recording the team/user overlay commits and content fingerprints that produced each build. See [provenance](provenance.md).
- **Credential injection** — the SSH deploy key, git-host token (PAT) for git auth, and read-only `.npmrc` that `dce` writes into the container on `new`/`start`/`shell`/`editor`/`rebuild-container`. Bypassed by VS Code's own *Rebuild Container*, which is why you should always rebuild via `dce`. Details in [isolation and security](../explanation/isolation-and-security.md).
