# Command reference


The day-to-day interface is the `dce` command with subcommands. All subcommands dispatch to scripts under `scripts/`. For every flag each command accepts, see the [flag reference](flags.md).

| Command | Description |
|---|---|
| `dce new` (forms below) | Create a new isolated container project |
| `dce status` (`dce s`) | Show overall status and per-project details |
| `dce start [name ...]` | Start one or more projects, or all configured projects if none given |
| `dce stop [name ...]` | Stop one or more projects, or all configured projects if none given |
| `dce list` (`dce ls`) | List DC Enclave and their running/stopped state |
| `dce shell <name> [command]` | Open a shell or run one command inside a project container; injects `GITHUB_TOKEN` and wraps the command in `zsh -ic` |
| `dce logs <name> [-f\|--follow] [--tail N]` | Fetch a container's stdout/stderr log stream (works on stopped containers) |
| `dce exec [--root] <name> <command...>` | Run a single command in a running container, docker-exec style: no `GITHUB_TOKEN`, no zsh wrapping, auto-TTY |
| `dce restart [name ...]` | Restart one or more projects, or all configured projects |
| `dce rm <name> [--yes] [--keep-config] [--keep-volumes]` | Remove a project: container, hidden volumes, and config+secrets (host code preserved) |
| `dce rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes] [--yes]` | Destroy and recreate container from selected image |
| `dce rebuild-image [all\|base]` | Rebuild base image and (for `all`) all configured derived images |
| `dce provenance <name> [--history\|--all]` | Show image provenance: team/user overlay commits + content fingerprints + base id + build time for the project's image |
| `dce clean [--dry-run] [--hidden-volumes [name]]` | Remove old/orphan managed image tags or orphan managed hidden volumes |
| `dce doctor [backend\|project]` | Run read-only preflight checks and report pass/fail per subsystem (nonzero if any fail) |
| `dce network <create\|ls\|members\|rm\|add\|remove> ...` | Manage private networks between containers (no host port publishing); see [private networks](../how-to/connect-private-networks.md) |
| `dce install <name> <path-to-dotfiles>` | Install or update dotfiles in a running container |
| `dce version` (`dce --version`, `dce -v`) | Print the DC Enclave version |
| `dce help [command]` (`dce --help`, `dce -h`) | Show usage summary or detailed help for a specific command |

> **`shell` vs `exec`:** `dce shell` is for working *inside* the container — it auto-starts the container, injects `GITHUB_TOKEN`, and runs commands through `zsh -ic` (so aliases and interactive config load). `dce exec` is a raw, docker-exec-style escape hatch for host-driven one-shots: no token, no zsh wrapping, args passed verbatim, and the container must already be running. The common pitfall is reaching for `exec` when a command needs the token, or `shell` when you want raw/piped output — see `dce help shell` and `dce help exec`.

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

