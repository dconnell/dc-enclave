# Flag reference

Every flag each `dce` command accepts, derived from the command help (`dce help <command>`). Positional arguments are shown in angle brackets; optional ones in square brackets. Flags can also be previewed in your shell via tab completion (see [getting started](../tutorials/getting-started.md#shell-completion)).

## `dce new` — create a project

| Flag / arg | Description |
|---|---|
| `<name>` *(required)* | Project name. Allowed chars: letters, numbers, dot, underscore, hyphen. Must not already exist. |
| `[scope[,scope...]]` | Overlay scope(s) matching `Containerfile.<scope>` in team/user overlays. Omit for a base-only project. |
| `[host:container ...]` | Port mapping(s) to publish. A bare port (e.g. `5173`) maps the same port on both sides; `8080:3000` maps different ports. Repeatable. |
| `--config <path>` | Load one explicit container recipe file as defaults; skips name-based recipe lookup. CLI flags still override. |
| `--repo-path <path>` | Override the repo mount location. Default `$DC_REPOS_DIR/<name>` or `~/repos/<name>`. |
| `--save-team` | Save the CLI-supplied recipe keys from this run to `$DC_TEAM_DIR/container-recipes/<name>`. |
| `--save-user` | Save the CLI-supplied recipe keys from this run to `$DC_USER_DIR/container-recipes/<name>`. Pass both to write both. |
| `--cpus <N>` | CPU limit (e.g. `2`, `1.5`). Empty = backend default. See [manage resources](../how-to/manage-resources.md). |
| `--memory <val>` | Memory limit with suffix (e.g. `4g`, `512m`). Empty = backend default. |
| `--hide <path[,path...]>` | Keep one or more `/workspace`-relative paths in a named volume. Repeatable. See [hide generated paths](../how-to/hide-generated-paths.md). Mutually exclusive with `--sync`. |
| `--sync` | Replace the `/workspace` bind mount with a Mutagen-synced named volume (`dce-sync-<slug>-<12hex>`) on native ext4. Two-way, host-canonical. The escape hatch for large repos where the bind mount is too slow on macOS/WSL2. Supported on docker/orbstack/colima; apple and podman fail fast (no Mutagen transport). Requires the `mutagen` CLI. See [sync workspace](../how-to/sync-workspace.md). |
| `--sync-ignore <path[,path...]>` | Exclude `/workspace`-relative paths from Mutagen sync (the sync-world analog of `--hide`). Same grammar; repeatable. Only meaningful with `--sync`. |
| `--network <name[,name...]>` | Attach to private dce network(s) so the container can reach peers by name without publishing ports. `name:ip` pins a static IPv4. Repeatable. See [private networks](../how-to/connect-private-networks.md). |
| `--ip <addr>` | Static IPv4 for the primary (first) network; equivalent to `name:ip` on the first `--network` entry. Not supported on apple/container. |
| `--yes`, `-y` | Skip the recipe-`repo-path` confirmation prompt (see below). Non-interactive runs without `--yes` abort instead of mounting. |

> **Recipe `repo-path` is gated.** An auto-loaded recipe cannot silently widen the
> host bind mount: a recipe-sourced `repo-path` that resolves outside the default
> repos dir (`$DC_REPOS_DIR` or `~/repos`) asks for confirmation (`--yes`/`-y`
> honors it); values resolving to `/`, your home, the repos root, or a parent of
> it are rejected, as are values with characters unsafe in a bind-mount source.
> A recipe `repo-path` inside the default repos dir needs no confirmation, and
> CLI `--repo-path` is never gated (escape hatch). See [configuration: recipes](configuration.md).

## `dce logs` — container log stream

| Flag / arg | Description |
|---|---|
| `<name>` *(required)* | Project/container name. |
| `-f`, `--follow` | Follow log output (stream until interrupted). |
| `--tail N` *(or `--tail=N`)* | Show only the last `N` lines (non-negative integer). |

## `dce exec` — raw one-shot in a running container

| Flag / arg | Description |
|---|---|
| `<name>` *(required)* | Project/container name. Must already be running. |
| `<command...>` *(required)* | Command and args, passed through verbatim (args beginning with `-` reach the command untouched). |
| `--root` | Run as uid 0, non-interactively. Never allocates a TTY (for a root interactive session, use `dce shell` then `sudo`). |

A TTY is allocated automatically only when both stdin and stdout are interactive.

## `dce rm` — remove a project

| Flag / arg | Description |
|---|---|
| `<name>` *(required)* | Project/container name. |
| `--yes`, `-y` | Skip the confirmation prompt. |
| `--keep-config` | Preserve the config + secrets directory (removes container + volumes only). |
| `--keep-volumes` | Preserve managed hidden volumes (removes container + config/secrets only). |

## `dce rebuild-container` — destroy and recreate a container

| Flag / arg | Description |
|---|---|
| `<name>` *(required)* | Project/container name. Must already exist. |
| `--rotate-keys` | Regenerate the SSH deploy key before recreating (old key backed up, new `.pub` printed, command pauses for you to update GitHub). Implies credential injection (the new key + current git token are written). |
| `--inject-creds` | Inject the current SSH deploy key and git token into the rebuilt container, overwriting any credentials already present (idempotent: the token is rewritten only when it differs). Always in effect for a normal rebuild and for `--rotate-keys`; it matters with `--from-snap`, where a bare restore injects nothing so a (possibly suspect) snapshot's credential state is preserved for inspection. |
| `--keep-hidden-volumes` | Preserve hidden volumes instead of removing them (default removes them for a clean slate). Combining with `--rotate-keys` triggers a loud warning. |
| `--sync` | Enable a synced workspace on a project created without `--sync` (converts the bind mount to a Mutagen-synced volume). A project already created with `--sync` stays synced automatically. The sync volume is preserved across rebuild and a `mutagen sync flush` drains pending changes before the container is destroyed. Mutually exclusive with `--from-snap`. |
| `--sync-ignore <path[,path...]>` | Adjust the Mutagen ignore set; re-creates the sync session so the new rules apply. Same grammar as the `dce new` flag. Allowed only on the sync path (`--sync` or an already-synced project) and not with `--from-snap`. |
| `--from-snap <label>` | Recreate from the snapshot `dce-snap-<name>-<label>:latest` instead of the scope-derived image. Bypasses scope derivation and does NOT rewrite `CONTAINER_IMAGE`. Hidden volumes are ALWAYS isolated on restore: each is mounted from its snapshot volume (populated where captured, empty otherwise) and the live originals are left untouched, so `--keep-hidden-volumes` has no effect here. A restore does NOT inject credentials by default — the rebuilt container keeps exactly what the snapshot baked (nothing, for a scrubbed snapshot); pass `--inject-creds` to inject current credentials, or `--rotate-keys` to regenerate the SSH key. See [snapshots & rollback](../how-to/snapshot-and-rollback.md). |
| `--yes`, `-y` | Skip the confirmation prompt (for scripted incident response). |

## `dce rebuild-image` — rebuild managed images

| Arg | Description |
|---|---|
| `[all\|base]` | `all` (default): rebuild `dce-base:latest` and every configured derived image. `base`: rebuild `dce-base:latest` only. |

## `dce config` — inspect/edit config + sync managed devcontainer fields

| Form / arg | Description |
|---|---|
| `show <name>` | Print a grouped, human-readable view of the project config. |
| `get <name> <key>` | Print one value (`cpus`, `memory`, `scopes`, `ports`, `hide`, `networks`, and read-only `project`, `backend`, `image`, `repos`). |
| `set <name> <key>=<value>` | Validate + atomically write one mutable key (`cpus`, `memory`, `scopes`, `ports`, `hide`, `networks`). Empty clears a key back to default. |
| `set <name> <key> <value>` | Space-separated equivalent of `key=value`. |
| `sync-vscode <name>` | Rewrite MANAGED fields in `<repos>/.devcontainer/devcontainer.json` to match current config while preserving user keys/mounts. Includes `customizations.vscode.extensions` when extension manifests are adopted (migration guard preserves hand-curated arrays pre-adoption). Docker-compatible projects only. Requires `jq`. |
| `--dry-run` *(with `sync-vscode`)* | Preview drift + planned managed-field rewrites without writing the file. |
| `ls` | List projects that have a config file. |

## `dce provenance` — image provenance

| Flag / arg | Description |
|---|---|
| `<project>` *(required)* | Project/container name. |
| `--history`, `--all` | Print every recorded build as a table (oldest first) instead of just the current one. |

## `dce clean` — reclaim image tags / hidden volumes / snapshots

| Flag / arg | Description |
|---|---|
| `--dry-run` | Show what would be removed (and how much space) without deleting. |
| `--hidden-volumes [name]` | Operate on orphan hidden volumes instead of managed image tags. Optional trailing project name narrows scope to one project. |
| `--snapshots [name]` | Operate on `dce-snap-*` snapshot images and their `dce-snapvol-*` snapshot volumes instead of managed image tags. Optional trailing project name narrows scope to one project. Default `dce clean` never touches snapshots. Mutually exclusive with `--hidden-volumes`. |

## `dce snapshot` / `dce snapshots` — container snapshots

| Form / arg | Description |
|---|---|
| `snapshot <name> [<label>]` | Stop → commit → restart the container, producing `dce-snap-<name>-<label>:latest`, AND clone each hidden volume into `dce-snapvol-<name>-<label>-<hash>`. `<label>` defaults to a sortable UTC timestamp (`YYYYmmdd-HHMMSS`); charset `[A-Za-z0-9_.-]`. Refuses to overwrite an existing label. The source volume is mounted **read-only** during the copy, so the live volume can't be corrupted. A failed copy does NOT abort — the path is restored empty with a WARNING. Because copying is slow/disk-heavy, the command lists the volumes to copy and **prompts for confirmation** first. |
| `--exclude-volumes` | Skip ALL hidden-volume capture (filesystem image only). Excluded volumes come back EMPTY on restore — never silently reused from the live volumes. No confirmation prompt (nothing to copy). |
| `--exclude-volume <path[,path...]>` | Exclude specific hidden volumes only (repeatable, comma-separated); the rest are captured. Useful for "everything except the huge `node_modules`". Unknown paths are warned and ignored. |
| `--yes`, `-y` | Skip the confirmation prompt (for scripting). |
| `snapshot rm <name> <label>` | Remove one snapshot image, its captured volumes, and its manifest. |
| `snapshots list [<name>]` | List snapshots newest-first with project, size, volumes captured, UTC time, and base image. Optional `<name>` scopes to one project. |

Restore with `dce rebuild-container <name> --from-snap <label>` (one-off; never rewrites `CONTAINER_IMAGE`). See [snapshots & rollback](../how-to/snapshot-and-rollback.md).

## `dce network` — private networks

| Subcommand | Args |
|---|---|
| `create <name>` | `[--subnet <cidr>] [--subnet-v6 <cidr>]` — subnet auto-allocated unless given. |
| `ls` / `list` | *(none)* — list networks and their dce members. |
| `members <name>` | *(positional)* — show which projects are on a network. |
| `rm <name>` | `[--force\|-f]` — remove a network; refuses while members exist unless `--force` (Docker-compatible only). |
| `add <name> <project>` | `[--ip <addr>]` — attach an existing container and record it in project config. Docker-compatible only. |
| `remove <name> <project>` | *(positional)* — detach a container and drop it from project config. Docker-compatible only. |

## `dce doctor` — preflight checks

| Arg | Description |
|---|---|
| `[backend\|project]` | A backend name (`apple`, `docker`, `orbstack`, `colima`, `podman`) selects that backend; any other name is treated as a project. Omit for all detected backends + host checks. |

## Commands with no flags

These take only positional arguments (or none):

- `dce start [name ...]`, `dce stop [name ...]`, `dce restart [name ...]` — all configured projects when no name is given.
- `dce status`, `dce list` — no arguments.
- `dce install <name> <path>` — path to a dotfiles directory containing an executable `install.sh`.
- `dce version` (`--version`, `-v`), `dce help [command]` (`--help`, `-h`).

## Global

| Env var | Description |
|---|---|
| `CONTAINER_BACKEND` | Force a backend (`apple`, `colima`, `docker`, `orbstack`, `podman`) instead of auto-detection. See [backends](backends.md). |
| `DC_REPOS_DIR` | Override the host repos root (default `~/repos`). |
| `DC_TEAM_DIR` / `DC_USER_DIR` | Team and user overlay/recipe roots, set by `setup.sh` in `~/.config/dce-enclave/config`. |
