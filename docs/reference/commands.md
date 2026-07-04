# Command reference


The day-to-day interface is the `dce` command with subcommands. All subcommands dispatch to scripts under `scripts/`. For every flag each command accepts, see the [flag reference](flags.md).

| Command | Description |
|---|---|
| `dce new` (forms below) | Create a new isolated container project |
| `dce status` (`dce s`) | Show overall status and per-project details |
| `dce start [name ...]` | Start one or more projects, or all configured projects if none given |
| `dce stop [name ...]` | Stop one or more projects, or all configured projects if none given |
| `dce list` (`dce ls`) | List DC Enclave and their running/stopped state |
| `dce shell <name> [command]` | Open a shell or run one command inside a project container; injects the project's git token as the provider env var (`GITHUB_TOKEN` / `GITLAB_TOKEN`) and wraps the command in `zsh -ic` |
| `dce logs <name> [-f\|--follow] [--tail N]` | Fetch a container's stdout/stderr log stream (works on stopped containers) |
| `dce editor [--editor <id>] <name>` | Launch your editor attached to the running container at `/workspace` (VS Code by default; Docker-compatible backends only). Under PAT auth, also sync VS Code's attached-container config so editor/terminal Git uses the container credential store instead of VS Code's host-forwarding helper. |
| `dce extensions <list\|host\|available\|show\|diff\|capture> ...` | Inspect declared/runtime editor extension sets, compare drift, and capture curated manifests under `extensions/<editor>/<scope>.txt`. |
| `dce exec [--root] <name> <command...>` | Run a single command in a running container, docker-exec style: no token, no zsh wrapping, auto-TTY |
| `dce restart [name ...]` | Restart one or more projects, or all configured projects |
| `dce rm <name> [--yes] [--keep-config] [--keep-volumes]` | Remove a project: container, hidden volumes, snapshot artifacts, and config+secrets (host code preserved). Snapshot artifacts follow `--keep-volumes` (preserved with the flag, removed without it) |
| `dce rebuild-container <name> [--rotate-keys] [--inject-creds] [--keep-hidden-volumes] [--yes]` | Destroy and recreate container from selected image |
| `dce rebuild-container <name> --from-snap <label>` | Recreate container from a saved snapshot (one-off restore; does not rewrite the configured image; credentials not injected unless `--inject-creds`/`--rotate-keys`) |
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
| `dce new <name> [scope[,scope...]] [--config <path>] [--save-team] [--save-user] [--repo-path <path>] [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [--network <name[,name...]>] [--ip <addr>] [host:container ...]` | With recipe defaults, optional recipe save, resource limits, hidden paths, and networks (see [Hiding generated paths](../how-to/hide-generated-paths.md)) |
