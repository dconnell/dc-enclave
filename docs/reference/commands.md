# Command reference


The day-to-day interface is the `dce` command with subcommands. All subcommands dispatch to scripts under `scripts/`. For every flag each command accepts, see the [flag reference](flags.md).

| Command | Description |
|---|---|
| `dce new` (forms below) | Create a new isolated container project |
| `dce status` (`dce s`) | Show overall status and per-project details |
| `dce start [name ...]` | Start one or more projects, or all configured projects if none given |
| `dce stop [name ...]` | Stop one or more projects, or all configured projects if none given |
| `dce list` (`dce ls`) | List DC Enclave and their running/stopped state |
| `dce shell [--no-wait] <name> [command]` | Open a shell or run one command inside a project container; injects the project's git token as the provider env var (`GITHUB_TOKEN` / `GITLAB_TOKEN`) and wraps the command in `zsh -ic`. For a synced workspace, interactive entry waits for the Mutagen session to settle first (`--no-wait` / `DCE_SYNC_NO_WAIT=1` opts out) |
| `dce logs <name> [-f\|--follow] [--tail N]` | Fetch a container's stdout/stderr log stream (works on stopped containers) |
| `dce editor [--editor <id>] [--no-wait] <name>` | Launch your editor attached to the running container at `/workspace` (VS Code by default; Docker-compatible backends only). Under PAT auth, also sync VS Code's attached-container config so editor/terminal Git uses the container credential store instead of VS Code's host-forwarding helper. For a synced workspace, waits for the Mutagen session to settle before launch (`--no-wait` / `DCE_SYNC_NO_WAIT=1` opts out). |
| `dce sync-status [--once] <name>` | Show Mutagen sync state for a [synced workspace](../how-to/sync-workspace.md): live by default (`mutagen sync monitor`), or `--once` for a one-shot snapshot (`mutagen sync list`). Host-side only. |
| `dce extensions <list\|host\|available\|show\|diff\|capture> ...` | Inspect declared/runtime editor extension sets, compare drift, and capture curated manifests under `extensions/<editor>/<scope>.txt`. |
| `dce exec [--root] <name> <command...>` | Run a single command in a running container, docker-exec style: no token, no zsh wrapping, auto-TTY |
| `dce restart [name ...]` | Restart one or more projects, or all configured projects |
| `dce rm <name> [--yes] [--keep-config] [--keep-volumes]` | Remove a project: container, hidden volumes, snapshot artifacts, and config+secrets (host code preserved). Snapshot artifacts follow `--keep-volumes` (preserved with the flag, removed without it) |
| `dce rebuild-container <name> [--rotate-keys] [--inject-creds] [--keep-hidden-volumes] [--yes]` | Destroy and recreate container from selected image |
| `dce rebuild-container <name> --from-snap <label>` | Recreate container from a saved snapshot (one-off restore; does not rewrite the configured image; credentials not injected unless `--inject-creds`/`--rotate-keys`) |
| `dce rebuild-container <name> --sync [--sync-ignore <path[,path...]> ...]` | Enable/refresh a [synced workspace](../how-to/sync-workspace.md) on rebuild; the sync volume is preserved and flushed pre-destroy |
| `dce rebuild-image [all\|base]` | Rebuild base image and (for `all`) all configured derived images |
| `dce snapshot <name> [<label>] [--exclude-volumes] [--exclude-volume <path>] [--yes]` | Snapshot a container's filesystem AND hidden volumes to a tagged image (`dce-snap-<name>-<label>:latest` + `dce-snapvol-*`); source volumes are copied read-only; prompts before copying unless `--yes`; `--exclude-volumes`/`--exclude-volume` skip volumes — see [snapshots & rollback](../how-to/snapshot-and-rollback.md) |
| `dce snapshot rm <name> <label>` | Remove one snapshot image, its captured volumes (`dce-snapvol-*`), and its manifest |
| `dce snapshots list [<name>]` | List snapshots newest-first (project, size, volumes captured, time, base image); optional project scope |
| `dce provenance <name> [--history\|--all]` | Show image provenance: team/user overlay commits + content fingerprints + base id + build time for the project's image |
| `dce clean [--dry-run] [--hidden-volumes [name]] [--snapshots [name]]` | Reclaim old/orphan image tags, orphan hidden volumes, or snapshots |
| `dce config <show\|get\|set\|sync-vscode\|ls> ...` | Inspect/edit a project's config (validating wrapper over the config file). `sync-vscode` reconciles MANAGED `.devcontainer/devcontainer.json` fields on demand (`--dry-run` available), including `customizations.vscode.extensions` once manifests are adopted; attach-mode named config used by `dce editor` is managed automatically at editor launch. |
| `dce doctor [backend\|project]` | Run read-only preflight checks and report pass/fail per subsystem (nonzero if any fail) |
| `dce network <create\|ls\|members\|rm\|add\|remove> ...` | Manage private networks between containers (no host port publishing); see [private networks](../how-to/connect-private-networks.md) |
| `dce install <name> <path-to-dotfiles>` | Install or update dotfiles in a running container |
| `dce rotate-token <name>` | Push the project's current git token (PAT) into its container without a rebuild — state-preserving, idempotent, force-overwrites a stale value (no-op under ssh/none). See [rebuild & recover](../how-to/rebuild-and-recover.md). |
| `dce version` (`dce --version`, `dce -v`) | Print the DC Enclave version |
| `dce help [command]` (`dce --help`, `dce -h`) | Show usage summary or detailed help for a specific command |

> **`shell` vs `exec`:** `dce shell` is for working *inside* the container — it auto-starts the container, injects the project's git token (as the provider env var `GITHUB_TOKEN` / `GITLAB_TOKEN`), and runs commands through `zsh -ic` (so aliases and interactive config load). `dce exec` is a raw, docker-exec-style escape hatch for host-driven one-shots: no token, no zsh wrapping, args passed verbatim, and the container must already be running. The common pitfall is reaching for `exec` when a command needs the token, or `shell` when you want raw/piped output — see `dce help shell` and `dce help exec`.

`<scope>` values in `dce new` are overlay scopes that match `Containerfile.<scope>` files in your overlay directories. Scope is optional — `dce new <name>` creates a base-only project. The `all` scope is always auto-layered when `Containerfile.all` exists.

### Command aliases

Several commands have short aliases:

| Command | Aliases |
|---|---|
| `dce status` | `dce s` |
| `dce list` | `dce ls` |
| `dce version` | `dce --version`, `dce -v` |
| `dce help` | `dce --help`, `dce -h` |
| `dce network` | `dce net` |

`dce start` and `dce stop` accept multiple project names (for example `dce start web api db`) — when no names are given they operate on every configured project.

**`dce new` forms** — `<scope>` can be any scope name matching a `Containerfile.<scope>` in your overlays or a comma-separated combination:

| Form | Description |
|---|---|
| `dce new <name> [scope[,scope...]] [host:container ...]` | Basic form with port mappings |
| `dce new <name> [scope[,scope...]] [--config <path>] [--save-team] [--save-user] [--git-host <provider>] [--repo-path <path>] [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [--sync] [--sync-ignore <path[,path...]> ...] [--network <name[,name...]>] [--ip <addr>] [host:container ...]` | With recipe defaults, optional recipe save, git-host selection, resource limits, hidden paths, [synced workspace](../how-to/sync-workspace.md), and networks (see [Hiding generated paths](../how-to/hide-generated-paths.md)) |

## Command support by backend

DC Enclave supports five container runtimes (see [backends](backends.md)): the Docker family — `docker`, `orbstack`, `colima` — plus `apple` (apple/container) and `podman`. The four Docker-compatible backends (`docker`/`orbstack`/`colima`/`podman`) share most capabilities; `apple/container` diverges most often because it does not expose the Docker API.

### Command matrix

Command-level support. ✅ fully supported · 🟡 works, but some flags/subcommands are unsupported (see [Backend-limited features](#backend-limited-features)) · ❌ unsupported. Most commands run on every backend; `dce editor` is the only one that refuses outright — others showing 🟡 still work, just with caveats on specific options.

| Command | Docker / OrbStack / Colima | apple / container | Podman |
|---|---|---|---|
| `dce new` | ✅ | 🟡 | 🟡 |
| `dce status` | ✅ | ✅ | ✅ |
| `dce start` | ✅ | ✅ | ✅ |
| `dce stop` | ✅ | ✅ | ✅ |
| `dce list` | ✅ | ✅ | ✅ |
| `dce shell` | ✅ | ✅ | ✅ |
| `dce logs` | ✅ | ✅ | ✅ |
| `dce editor` | ✅ | ❌ | ✅ |
| `dce sync-status` | ✅ | ✅ | ✅ |
| `dce extensions` | ✅ | 🟡 | ✅ |
| `dce exec` | ✅ | ✅ | ✅ |
| `dce restart` | ✅ | ✅ | ✅ |
| `dce rm` | ✅ | ✅ | ✅ |
| `dce rebuild-container` | ✅ | 🟡 | 🟡 |
| `dce rebuild-image` | ✅ | ✅ | ✅ |
| `dce snapshot` | ✅ | ✅ | ✅ |
| `dce snapshot rm` | ✅ | ✅ | ✅ |
| `dce snapshots list` | ✅ | ✅ | ✅ |
| `dce provenance` | ✅ | ✅ | ✅ |
| `dce clean` | ✅ | ✅ | ✅ |
| `dce config` | ✅ | 🟡 | ✅ |
| `dce doctor` | ✅ | ✅ | ✅ |
| `dce network` | ✅ | 🟡 | ✅ |
| `dce install` | ✅ | ✅ | ✅ |
| `dce rotate-token` | ✅ | ✅ | ✅ |
| `dce version` | ✅ | ✅ | ✅ |
| `dce help` | ✅ | ✅ | ✅ |

### Backend-limited features

These flags/subcommands run on only a subset of backends. Each fails fast with an actionable message rather than silently misbehaving — the command itself still works; only the listed option is constrained.

| Feature | Docker / OrbStack / Colima | apple / container | Podman | Reason |
|---|---|---|---|---|
| `dce editor` | ✅ | ❌ | ✅ | VS Code Dev Containers needs the Docker API socket; apple/container has no attach path |
| `dce new --sync`, `dce rebuild-container --sync` | ✅ | ❌ | ❌ | [Synced workspace](../how-to/sync-workspace.md) needs a Mutagen transport; none exists for apple or podman |
| `dce new --ip` (static IPv4) | ✅ | ❌ | ✅ | apple/container allows a single network with no static IP |
| `dce config sync-vscode` | ✅ | ❌ | ✅ | rewrites `.devcontainer/devcontainer.json`, which apple projects don't carry (also requires `jq`) |
| `dce network add`, `dce network remove` | ✅ | ❌ | ✅ | apple/container sets networks only at container create time (no live attach/detach) |
| `dce network rm --force` | ✅ | ❌ | ✅ | force-removing a network with live members requires live-detach, which apple can't do |
| `dce extensions list`, `available`, `diff`, `capture --all` | ✅ | ❌ | ✅ | read the in-container VS Code Server store over the Docker API (need a running container); `show`, `host`, and `capture <id>...` are static and work on apple |

> **Note:** `dce network create` on apple/container additionally requires macOS 26+ for user-defined networks; the other backends have no such version floor.

See [backends](backends.md) for runtime auto-detection, the `--sync` transport matrix, and per-platform setup notes.
