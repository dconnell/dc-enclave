# DC Enclave

Isolated dev containers for any repo. Spin one up with a single command, shell in from the terminal or open it in VS Code, and run your code and AI agents inside a sandbox you can wipe and rebuild in seconds.

Runs on macOS, Linux, and WSL2 across five backends: apple/container, Docker Desktop, OrbStack, Colima, and Podman.

## Why

Every developer now runs tools that touch their whole repo — AI agents in VS Code extensions, TUI runners like Claude Code, OpenCode, or Pi launched from the terminal, build scripts, dependency installers. Left on the host, each one can read your global credentials, mutate files outside the project, and leave state that survives the session. DC Enclave puts a hard boundary around all of it: the container is the boundary, and anything you run inside it stays inside.

- **Whatever runs in the container, stays in the container.** Launch a TUI agent from `dce shell`, or run a VS Code extension from the integrated terminal — both operate inside the same boundary. Your host filesystem, shell history, and global credentials stay out of reach.
- **Each project is its own trust zone.** A container for project A holds only what you've put in it; project B is invisible to it. Link them only when you mean to.
- **A bad session is one command to undo.** `dce rebuild-container <name>` destroys the container filesystem and recreates it from a known-good image. No snapshots to manage, no manual cleanup, no digging through `git reflog`.
- **Trust is pinned, not learned on first use.** GitHub's SSH host keys are baked into the base image and verified by a guard test, so a hijacked network can't silently redirect git traffic.
- **Your host code is never touched.** Repos live on the host and bind-mount in; destroying the container leaves your checkout exactly where it was.

The container is the undo button. Rebuild it and you're back to a known-good state in under a minute.

## Quick start

```bash
# one-time: build the base image and wire up the `dce` command
scripts/setup.sh

# create an isolated container for a repo
dce new myapp nodejs 3000:3000

# shell in from the terminal
dce shell myapp

# or open the repo folder in VS Code and run: Dev Containers: Reopen in Container
```

You now have a container named `myapp` running your chosen toolchain, your repo bind-mounted at `/workspace`, your per-project credentials injected, and a generated `devcontainer.json` so VS Code lands on the exact same container `dce shell` uses.

The generated `devcontainer.json` follows the [dev container spec](https://containers.dev), so other spec-compliant clients (Codespaces, etc.) can attach too — only VS Code Dev Containers is tested.

`dce new` also generates a per-project SSH keypair and creates placeholder files for a GitHub token and `.npmrc` under `~/.config/dce-enclave/<name>/`. Completing them is optional hardening — see [Isolation design](#isolation-design).

## Design principles

- **The orchestrator has no install footprint.** `dce` is pure Bash 4+ — no Node runtime, no Python, no `npm install -g`, no Homebrew formula. The tool that manages your sandboxes is just shell scripts running on the Bash every Unix already ships. Nothing outside your containers needs a package manager, so nothing outside your containers needs patching, pinning, or CVE auditing. Clone, run `setup.sh`, done.
- **Per-project isolation by default.** Each container gets its own credentials, hidden volumes, and (optionally) its own network. Projects can't see each other unless you explicitly link them.
- **Rebuildable, not stateful.** Containers are disposable; your code and config are not. Everything that matters lives on the host or in version-controlled overlay files; the container is regenerated from them on demand.
- **Reproducible by provenance.** Every built image records the overlay commits and content fingerprints that produced it, so you can answer "what state were my overlays in when this image was built?" without archaeology.
- **Fail-closed on trust.** Host keys pinned in-image, no runtime `ssh-keyscan`, no `accept-new`. A poisoned pin is caught by a test, not by a breach.

## Isolation design

Each project container runs with its own credentials and container state, so projects stay independent. The credentials below are **optional hardening** — the container runs fine without any of them. `dce new` generates the SSH keypair and creates placeholder/template files for the rest, then prints a checklist steering you through completing the ones you want.

- Per-project SSH deploy key (generated) — `dce new` creates a dedicated keypair at `~/.config/dce-enclave/<name>/ssh_key` and prints the `.pub`. Add it as a GitHub deploy key to use it; skip if you don't need repo write from inside the container.
- Per-project GitHub PAT (optional) — drop a fine-grained, repo-scoped token (no admin) into `~/.config/dce-enclave/<name>/github-token`. `dce shell` injects it as `GITHUB_TOKEN` only when the file is non-empty.
- Per-project .npmrc (optional) — a template is created at `~/.config/dce-enclave/<name>/.npmrc`; edit it for projects that use npm. It is mounted read-only at `/home/dev/.npmrc`.
- Host-mounted workspace — code lives at `${DC_REPOS_DIR:-$HOME/repos}/<project>` on your machine and is bind-mounted to `/workspace` inside the container.

If a container's state is ever suspect, `dce rebuild-container` replaces the container from a known-good image without touching your host repos.

### GitHub SSH host key pinning

GitHub's SSH host keys are **pinned in the base image** (`Containerfiles/ssh/github_known_hosts`), not learned at runtime. The base image sets `StrictHostKeyChecking yes` for `github.com` and points its `UserKnownHostsFile` at the pinned file, so an unknown or mismatched host key fails closed instead of being silently trusted on first contact. `dce new`, `dce start`, and `dce rebuild-container` only inject your deploy key — they no longer run `ssh-keyscan`.

Rotating the pin (e.g. when GitHub changes a key) is a deliberate, reviewed change:

1. Re-verify the new keys against three independent channels — see `plans/security/m4.md` ("Verification channels").
2. Update `Containerfiles/ssh/github_known_hosts` **and** the `FP_*` constants in `tests/security-ssh-host-trust.sh` in the same change.
3. `dce rebuild-image base` then `dce rebuild-container <name>` to pick up the new pin.

The `tests/security-ssh-host-trust.sh` guard blocks a wrong/poisoned pin (it asserts the pinned fingerprints match GitHub's published values) and fails if `accept-new` or runtime `ssh-keyscan github.com` is reintroduced.

## Command reference

The day-to-day interface is the `dce` command with subcommands. All subcommands dispatch to scripts under `scripts/`.

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
| `dce rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes]` | Destroy and recreate container from selected image |
| `dce rebuild-image [all\|base]` | Rebuild base image and (for `all`) all configured derived images |
| `dce provenance <name> [--history]` | Show image provenance: team/user overlay commits + content fingerprints + base id + build time for the project's image |
| `dce clean [--dry-run] [--hidden-volumes [name]]` | Remove old/orphan managed image tags or orphan managed hidden volumes |
| `dce doctor [backend\|project]` | Run read-only preflight checks and report pass/fail per subsystem (nonzero if any fail) |
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

`dce start` and `dce stop` accept multiple project names (for example `dce start web api db`) — when no names are given they operate on every configured project.

**`dce new` forms** — `<scope>` can be any scope name matching a `Containerfile.<scope>` in your overlays or a comma-separated combination:

| Form | Description |
|---|---|
| `dce new <name> [scope[,scope...]] [host:container ...]` | Basic form with port mappings |
| `dce new <name> [scope[,scope...]] [--config <path>] [--save-team] [--save-user] [--repo-path <path>] [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [host:container ...]` | With recipe defaults, optional recipe save, resource limits, and hidden paths (see [Hiding generated paths](#hiding-generated-paths-from-the-host---hide)) |

## Global configuration and overlays

`setup.sh` bootstraps global configuration in:

```
~/.config/dce-enclave/config
```

Required keys:

```bash
DC_TEAM_DIR="$HOME/.config/dce-enclave/team"
DC_USER_DIR="$HOME/.config/dce-enclave/user"
```

`dce new`, `dce rebuild-image`, and `dce rebuild-container` load `DC_TEAM_DIR` and `DC_USER_DIR` from this config file. If the global config file is missing, either root is unset, or a root does not exist, the command fails fast with remediation guidance.

Each root is an independent directory (each may be its own git repo) holding two namespaces:

```
$DC_TEAM_DIR/                      # team root (optional git repo)
  overlays/                        # image overlay Containerfile fragments
  ├── Containerfile.all            # auto-layered when it exists
  └── Containerfile.<scope>        # any scope name you define
  container-recipes/               # shareable dce new recipe files
  └── <name>                       # filename is the container name
$DC_USER_DIR/                      # user root (optional git repo)
  overlays/
  ├── Containerfile.all
  └── Containerfile.<scope>
  container-recipes/
  └── <name>
```

`setup.sh` creates both roots and their `overlays/` and `container-recipes/` subdirectories (+ starter READMEs).

### Container recipes (`container-recipes/`)

`dce new <name>` auto-loads recipes by container name from:

- `$DC_TEAM_DIR/container-recipes/<name>`
- `$DC_USER_DIR/container-recipes/<name>`

Recipe files are plain `key=value` lines. Supported keys:

- `scopes`
- `cpus`
- `memory`
- `hide` (repeatable)
- `network` (repeatable)
- `ip`
- `repo-path`
- `port` (repeatable)

Merge and override rules:

- user recipe overrides team recipe per key
- list keys (`hide`, `network`, `port`) replace as a whole (not union)
- CLI args override recipe values for that run

You can load one explicit recipe file with `--config <path>`.

You can also persist the CLI-supplied recipe keys from a `dce new` run:

- `--save-team` writes `$DC_TEAM_DIR/container-recipes/<name>`
- `--save-user` writes `$DC_USER_DIR/container-recipes/<name>`
- pass both to write both files

Saved recipes include only keys explicitly supplied on that CLI invocation (not
values inherited from an existing team/user recipe).

Example:

```bash
dce new api nodejs,golang --cpus 2 --memory 4g --hide node_modules 3000:3000 --save-team
dce new api --cpus 3 --hide .cache --save-user
```

### Overlay ownership model

- `Containerfiles/example/` in this repo is for reference templates only (never auto-layered)
- `$DC_TEAM_DIR/overlays/` is for shared team overlays
- `$DC_USER_DIR/overlays/` is for personal overlays


### Canonical layering order

For scope list `<scope1>,<scope2>`, overlay composition order is:

1. `team/all`
2. `user/all`
3. `team/<scope1>`
4. `user/<scope1>`
5. `team/<scope2>`
6. `user/<scope2>`


`dce-base` is always the only repo-defined base layer. The `all` scope is always checked first — if `Containerfile.all` exists in team or user overlays, it is included automatically even without specifying `all` on the command line.

Missing unrequested overlay files are skipped silently. If you request a named scope and it is missing in both `team/` and `user/`, the command fails fast.

## Why DC Enclave?

If you are already comfortable with Docker, Podman, or apple/container CLIs, `dce` still saves work by orchestrating repetitive setup and recovery steps consistently across projects and machines.

What `dce` adds beyond raw backend commands:

- project bootstrap from a shared base image plus optional overlay Containerfiles
- persisted per-project configuration in `~/.config/dce-enclave/<name>/config`
- consistent mounts, ports, and resource limit handling across backends
- optional per-project credential layout for PAT/SSH key/.npmrc with repeatable rebuild flows
- one-command rebuild and key-rotation workflows for incident response

The table below intentionally focuses on the high-leverage commands where `dce` saves the most effort. It is not a complete mapping of every subcommand. Docker, OrbStack, and Colima are grouped because they share the Docker CLI.

| `dce` command | docker / orbstack / colima | podman | apple/container |
|---|---|---|---|
| `dce new myapp nodejs 3000:3000` | Compose Containerfile layers, run `docker build`, `docker create` (mounts/ports/limits), and `docker start`; then set up project config, keys, and editor files | Same flow with `podman` | Same flow with `container` |
| `dce new ...` (with overlay) | Merge team/user overlay fragments over `dce-base` (composition rules), then build/create/start | Same flow | Same flow |
| `dce rebuild-container myapp` | Re-derive target image from scopes, then `docker rm -f myapp`, recreate with the original `docker create` flags, and `docker start` | Same flow with `podman` | `container delete myapp`, then recreate and start |
| `dce rebuild-container myapp --rotate-keys` | Rebuild-container flow plus SSH key regeneration and deploy-key rotation | Same flow | Same flow |
| `dce clean` | `docker image ls` + remove non-`latest` tags for managed repos | Same flow with `podman image ls/rm` | Same flow with `container image ls/rm` |
| `dce install myapp ~/.dotfiles` | Stream dotfiles via `tar` + `docker exec`, run `install.sh`, then remove temp files | Same flow with `podman` | Same flow with `container exec` |

`dce new`, `dce rebuild-image`, and `dce rebuild-container` are the biggest differentiators: repeatable orchestration for image lifecycle, container recovery, and security response without retyping fragile backend-specific command sequences. `dce clean` and `dce install` reduce ongoing maintenance overhead once projects are up and running.

## Common Tools Included In Base Image

The base image is intentionally minimal and shared across all scope selections. It includes essentials only:

- git
- curl
- wget
- openssh-client
- ca-certificates
- gnupg
- zsh
- procps
- sudo
- tzdata (IANA timezone database — needed to resolve `TZ`; see [Timezone syncing](#timezone-syncing))

The base image also includes default shell setup for `dev` with `alias ll='ls -la'`.

Preferred day-to-day tools (for example `tree`, `rg`, `fzf`, `psql`, custom CLIs) should be layered through a user overlay Containerfile. Personal shell/editor/git preferences remain in dotfiles.

## Backend selection

Set CONTAINER_BACKEND to one of:

- apple
- colima
- docker
- orbstack
- podman

If not set, detection order is:

1. docker context name contains orbstack
2. docker context points to Colima
3. apple/container CLI available
4. docker CLI available
5. podman CLI available

Docker context notes:

- Docker context is a Docker CLI concept (`docker context ...`), not a DC Enclave-specific setting
- DC Enclave reads the active context to distinguish OrbStack/Colima from generic Docker
- when forcing `CONTAINER_BACKEND=colima`, DC Enclave requires a Colima Docker context and will fail fast if the active context is not Colima

Selected backend is stored per project in `~/.config/dce-enclave/<name>/config`.

### Backend support policy

DC Enclave targets the **latest stable release** of each backend. If you hit behavior differences on an older version, upgrade the backend first.

- **Podman** — tested baseline at migration: Podman 5.2.x.
- **Colima** — use Colima with Docker runtime (`colima start --runtime docker`). If Colima is running with a non-Docker runtime (for example containerd), switch back to Docker runtime before using DC Enclave.

### Platform-specific notes

**macOS + Colima**: Install with `brew install colima docker`, then run `colima start --runtime docker`. Colima usually auto-activates its Docker context; if needed, run `docker context use colima`.

**Linux + Colima**: Install Colima and Docker CLI, then run `colima start --runtime docker`. Ensure virtualization support is available (for example KVM access where required by your distro setup).

**macOS + Podman**: Podman runs in a VM on macOS. Run `podman machine start` before using DC Enclave, or let `setup.sh` start it for you.

**Linux + Podman**: Podman runs rootless with no daemon. Works out of the box on most distros (`apt install podman`, `dnf install podman`).

**WSL2**: Docker Desktop's WSL2 integration makes `docker` available inside WSL2. Podman can be installed natively inside WSL2 (`apt install podman`). For best bind-mount performance, keep repos inside the WSL2 filesystem (`${DC_REPOS_DIR:-$HOME/repos}/`) rather than on the Windows mount (`/mnt/c/`).

## Repository layout

```
dce-enclave/
├── Containerfiles/
│   ├── Containerfile.base
│   ├── ssh/
│   │   └── github_known_hosts         # pinned, three-channel-verified GitHub SSH host keys
│   ├── example/
│   │   ├── Containerfile.nodejs        # overlay template example
│   │   ├── Containerfile.golang        # overlay template example
│   │   ├── Containerfile.rust          # overlay template example
│   │   ├── Containerfile.dotnet        # overlay template example
│   │   ├── Containerfile.python        # overlay template example
│   │   ├── Containerfile.all           # overlay template example
│   │   └── README.md
│   └── generated/                      # auto-generated composed files (project overlays)
├── lib/
│   ├── common.sh                       # bash 4+ version guard, shared helpers
│   ├── platform.sh                     # OS/shell detection, profile helpers
│   ├── complete-data.sh                # shared completion discovery (bash + zsh)
│   ├── container-backend.sh            # backend abstraction
│   └── vscode.sh                       # VS Code attach-config seeding
├── scripts/
│   ├── dce                               # CLI entry point
│   ├── dce-complete.bash                 # bash tab completion
│   ├── _dce                              # native zsh tab completion
│   ├── setup.sh
│   ├── help.sh                          # per-command help text (dce help <command>)
│   ├── compose-containerfile.sh
│   ├── new-container.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── shell.sh
│   ├── logs.sh
│   ├── exec.sh
│   ├── restart.sh
│   ├── rm.sh
│   ├── status.sh
│   ├── rebuild-container.sh
│   ├── rebuild-image.sh
│   ├── install-dotfiles.sh
│   ├── clean.sh
│   └── list.sh
├── templates/
│   └── dotfiles/                       # starter dotfiles repo (fork for personal config)
```

Host-side paths:

- code: ${DC_REPOS_DIR:-$HOME/repos}/<project>
- secrets: ~/.config/dce-enclave/<project>
- per-project config: ~/.config/dce-enclave/<project>/config (backend, image, ports, resource limits, secrets paths)
- global config: ~/.config/dce-enclave/config
- team root: `DC_TEAM_DIR` (typically `~/.config/dce-enclave/team`) — holds `overlays/` and `container-recipes/`
- user root: `DC_USER_DIR` (typically `~/.config/dce-enclave/user`) — holds `overlays/` and `container-recipes/`

## Three-source model (repo, team overlays, user overlays)

Keep these sources separate:

1. **DC Enclave repo** (`Containerfiles/base + Containerfiles/example`, scripts, docs)
2. **team overlays source** (files synced into `$DC_TEAM_DIR/overlays`)
3. **user overlays source** (files synced into `$DC_USER_DIR/overlays`)

This separation avoids coupling team customization with personal customization and keeps layering deterministic.

Recommended flow:

- keep `$DC_TEAM_DIR` as a git checkout of a private team root repository (overlays + recipes) and update with `git pull`
- keep `$DC_USER_DIR` as a git checkout of your personal root repository (overlays + recipes) and update with `git pull`
- keep the public `DC Enclave` repository focused on base image definition and reference templates under `Containerfiles/example/`

Example setup:

```
git clone git@github.com:YOUR-ORG/dc-enclave-team-root.git "$DC_TEAM_DIR"
git clone git@github.com:YOUR-USER/dc-enclave-user-root.git "$DC_USER_DIR"
```

Then keep them current:

```bash
git -C "$DC_TEAM_DIR" pull --ff-only
git -C "$DC_USER_DIR" pull --ff-only
```

## Initial setup

**Important**: `setup.sh` builds `dce-base` into the selected backend's image store. Each container backend maintains its own separate image store. If you want to use multiple backends, you must run `setup.sh` once per backend:

```
CONTAINER_BACKEND=docker scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
```

Images built on one backend are not visible to another. `dce new` checks for `dce-base:latest` on the active backend and fails early if setup has not been run for that backend.

`setup.sh` also bootstraps global configuration and directories:

- `~/.config/dce-enclave/config` with `DC_TEAM_DIR` and `DC_USER_DIR`
- `$DC_TEAM_DIR/overlays` and `$DC_TEAM_DIR/container-recipes`
- `$DC_USER_DIR/overlays` and `$DC_USER_DIR/container-recipes`

1. Ensure Bash 4+ is installed:

```
bash --version
```

macOS users: if version is 3.x, run `brew install bash`.

2. Ensure one backend is installed and running:

- apple/container (macOS), or
- Docker Desktop (macOS, Linux, WSL2), or
- OrbStack (macOS), or
- Colima (macOS, Linux), or
- Podman (macOS, Linux, WSL2)

3. Initialize repository and aliases:

```
cd ~/dce-enclave
chmod +x scripts/*.sh scripts/dce
scripts/setup.sh
```

4. Reload your shell profile (setup detects your login shell via `$SHELL` and writes to the right file):

```
source ~/.zshrc         # if your shell is zsh (macOS default)
source ~/.bashrc        # Linux/WSL2 bash
source ~/.bash_profile  # macOS bash
```

Optional: force backend during setup:

```
CONTAINER_BACKEND=podman scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
```

### Shell completion

`setup.sh` wires tab completion for `dce` into whichever shell your `$SHELL` points at:

- **zsh** — setup defines `dce` as a shell function (`dce() { '<repo>/scripts/dce' "$@"; }`) and removes the legacy managed alias line, so `dce` cannot be shadowed by another PATH command. Native completion (`scripts/_dce`, a real `#compdef dce` function) is autoloaded by adding `scripts/` to `fpath` and bound to `dce` with `compdef _dce dce`.
- **bash** — `scripts/dce-complete.bash` is sourced. Setup writes to `~/.bash_profile` on macOS or `~/.bashrc` elsewhere.

Both front-ends share one discovery layer (`lib/complete-data.sh`), including the hardened global-config parser, so project/scope lists and security guarantees are identical across shells. If you previously bridged the bash completion into zsh by hand, re-running `setup.sh` removes that stale line in favor of native zsh completion.

Completion covers each command's real argument grammar, e.g. `dce start`/`dce stop` complete multiple project names (excluding ones already typed), `dce rebuild-container` offers `--rotate-keys`/`--keep-hidden-volumes`, and `dce install` completes a dotfiles directory after the project.

## Setup of a new repo

Use `dce new` (shell command), not direct script invocation.

Base-only example (no scopes needed — base image plus `Containerfile.all` if present):

```
dce new myapp 3000:3000
```

Single-scope examples (scope names match `Containerfile.<scope>` in your overlay dirs):

```
dce new myapp-frontend nodejs 3000:3000 5173:5173
dce new myapp-backend golang 8080:8080 9000:9000
dce new work-api golang --repo-path ~/code/company/api 8080:8080
```

Monorepo with multiple overlay scopes and multiple ports:

```
dce new myapp-monorepo nodejs,golang 3000:3000 5173:5173 8080:8080 9000:9000
```

Auto overlays example (`team/all`, `user/all`, plus scope-specific files when present):

```
dce new myapp-monorepo nodejs,golang 3000:3000 8080:8080
```

With resource limits:

```
dce new myapp-backend golang --cpus 2 --memory 4g 8080:8080
```

What scope combinations mean:

- `<scope>` -> include `Containerfile.<scope>` overlay files from team/user dirs
- `<scope1>,<scope2>` -> include both scopes in canonical order (all first, then listed order)
- (no scope) -> base image only, plus `Containerfile.all` when it exists
- auto overlays -> loaded from `$DC_TEAM_DIR/overlays` and `$DC_USER_DIR/overlays`


Overlay contract:

- Treated as Dockerfile fragments layered on top of `dce-base`
- `FROM` and `CMD` are ignored during composition
- `COPY` and `ADD` are not allowed (to avoid external build-context coupling)

Starter file note:

- `Containerfiles/example/Containerfile.all` is a reference template.
- Copy it into `$DC_TEAM_DIR/overlays` or `$DC_USER_DIR/overlays`, then customize.

After dce new:

1. Edit ~/.config/dce-enclave/<name>/github-token
2. Add ~/.config/dce-enclave/<name>/ssh_key.pub as GitHub Deploy Key
3. Clone repo(s) into ${DC_REPOS_DIR:-$HOME/repos}/<name>

Port mapping notes:

- Format is host-port:container-port
- Multiple mappings are supported in one dce new command
- Example: 3000:3000 5173:5173 8080:8080

## CPU and memory limits

All five backends support per-container CPU and memory limits. Set them at creation time or change them in the config file and rebuild.

Set limits at creation:

```
dce new myapp nodejs --cpus 2 --memory 4g 3000:3000
```

Omit scope for a base-only project with resource limits:

```
dce new myapp --cpus 2 --memory 4g 3000:3000
```

Omit both flags to use backend defaults (typically unrestricted).

Change limits on an existing project:

1. Edit `~/.config/dce-enclave/<name>/config`
2. Update `CONTAINER_CPUS` and/or `CONTAINER_MEMORY`
3. Run `dce rebuild-container <name>`

Resource limits are applied at container creation time. Changes to the config file take effect only after `dce rebuild-container` — `dce start` simply starts the existing container with its existing limits.

Config keys:

- `CONTAINER_CPUS` — number of CPUs (e.g. `2`, `1.5`). Empty = backend default.
- `CONTAINER_MEMORY` — memory limit with suffix (e.g. `4g`, `512m`). Empty = backend default.

All backends use the same flag syntax (`--cpus`, `--memory`). No backend-specific configuration is needed.

## Timezone syncing

Each container mirrors its developer's host timezone, so timestamps (`date`, logs, build output) match the local machine. This is applied per-container at creation time — the timezone is **not** baked into the shared image, because a team may span multiple timezones and every developer should see their own.

On `dce new` and `dce rebuild-container`, the host zone is detected and passed to the container as `--env TZ=<zone>`:

1. If `$TZ` is set in your shell, that value is used (must be a clean IANA name like `America/New_York`).
2. Otherwise the zone is read from `/etc/localtime` (works on macOS and Linux hosts).
3. If neither yields a clean value, `--env TZ` is omitted and the container keeps the image default (UTC).

Override the detected zone for a single command:

```
TZ=Europe/Berlin dce new myapp nodejs 3000:3000
```

For the base image to resolve a named zone, it ships the IANA timezone database (`tzdata`). This installs only the global database — it does **not** select a zone — so it stays timezone-neutral and safe to share across the team. Picking up `tzdata` after an upgrade requires rebuilding the base image:

```
dce rebuild-image base
dce rebuild-container <name>
```

On Docker-compatible backends, `dce new` also writes the detected `TZ` into the generated `.devcontainer/devcontainer.json` (`containerEnv`), so a VS Code "Reopen in Container" build lands on the same timezone as the `dce`-created container.

## Hiding generated paths from the host (`--hide`)

By default, the entire workspace is a bind mount: everything under `/workspace` inside the container is a live view of the host repos directory. This is great for source code but problematic for generated paths like `node_modules`, build caches, or compiled output. Those directories can contain thousands of files, platform-specific binaries, and large caches that are meaningless—or even harmful—on the host filesystem.

The `--hide` flag solves this by mounting a named container volume over a `/workspace`-relative path so its contents live inside the container's volume store instead of on the host.

### Why use `--hide`

- **Bind-mount performance** — On macOS (Docker Desktop, OrbStack, Colima) and WSL2, bind mounts crossing the VM boundary are slow for heavy file I/O. A directory like `node_modules` with tens of thousands of tiny files can make `npm install`, `git status`, and file watchers painfully slow. Moving it to a named volume restores native filesystem speed.
- **Platform correctness** — Native dependencies (e.g. `node-gyp` binaries, Go build artifacts) compiled inside the Linux container are not compatible with a macOS or Windows host. Keeping them in a container-only volume avoids platform mismatch errors.
- **Host cleanliness** — Generated output, caches, and lock-file side effects won't clutter your host checkout, won't confuse `git status`, and won't risk accidental commits.

### Usage

`--hide` accepts one or more comma-separated paths and can be repeated. Paths are relative to `/workspace`:

```
dce new myapp nodejs --hide node_modules 3000:3000
dce new monorepo nodejs,golang \
  --hide node_modules \
  --hide apps/web/node_modules,apps/api/node_modules \
  --hide .cache/go/mod,.cache/go/build \
  3000:3000 8080:8080
```

### How it works

- Each hidden path gets a deterministic named volume (`dce-hide-<project>-<hash>`) mounted at `/workspace/<path>`.
- After container start, dce ensures the hidden mount points are writable by the `dev` user (root `mkdir`/`chown` fallback applied across all backends).
- Hidden paths are persisted in the project config (`CONTAINER_HIDDEN_PATHS`) and automatically remounted on `dce rebuild-container`.
- **`dce rebuild-container` removes hidden volumes by default** for a clean slate (fresh dependency install, no stale caches). Use `--keep-hidden-volumes` to preserve them.
- For Docker-compatible backends, hidden mounts are also added to the generated `devcontainer.json` so VS Code Dev Containers uses the same layout.

### Overlay integration

Scope-specific overlays can build on hidden volumes. The Node.js overlay
(`Containerfile.nodejs`) includes an entrypoint that:

- detects a hidden `node_modules` volume
- runs `npm ci` (if a lockfile exists) or `npm install` automatically on container start
- writes a hash sentinel so deps are only re-installed when `package.json` or `package-lock.json` changes
- fails soft by default; set `DC_NODE_INSTALL_STRICT=1` to make install errors fatal

The `golang`, `rust`, `dotnet`, and `python` example overlays follow the same
shape with their own package manager (`go mod download`, `cargo fetch`,
`dotnet restore`, `uv sync`) and a matching `DC_<LANG>_INSTALL_STRICT=1` env.
See `Containerfiles/example/README.md` for each overlay's `--hide` paths and
sync command.

This means you get fast, correct dependency sync without any `node_modules` files touching your host.

> **Install-on-start can run code (security).** For `nodejs` and `python`, the
> sync step can execute lifecycle/build scripts (`npm` hooks; uv/PEP 517 source
> builds) — so an untrusted dependency can run code at container start. The
> `golang`/`rust`/`dotnet` sync steps only download and do not run fetched code.
> For untrusted inputs, disable install-time code with `DC_NODE_IGNORE_SCRIPTS=1`
> or `DC_PYTHON_IGNORE_SCRIPTS=1`. See the *Trusted vs untrusted overlays*
> section in `Containerfiles/example/README.md`.

### Cleaning up hidden volumes

Hidden volumes are removed automatically during `dce rebuild-container` (default behavior) so the rebuilt container starts clean. To reclaim space from orphaned volumes left behind by deleted projects:

```
dce clean --hidden-volumes --dry-run    # preview what would be removed
dce clean --hidden-volumes              # remove orphan hidden volumes
dce clean --hidden-volumes myproject    # scope to one project
```

Only `dce-hide-*` managed volumes that no longer correspond to an active project config are removed.

## Monorepo and multi-repo patterns

Monorepo:

- One container, one workspace tree (example: ${DC_REPOS_DIR:-$HOME/repos}/myapp-monorepo)
- Can combine scopes with dce new ... `<scope1>,<scope2>` ...

Multi-repo with separate trust boundaries:

- Separate containers (frontend/backend) with separate credentials

Single-container multi-repo workspace:

- Put all repos under one host folder for that container
- Example: ${DC_REPOS_DIR:-$HOME/repos}/project-fe/frontend-app, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/shared-ui, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/api-client
- All appear in container under /workspace

## VS Code behavior by backend

docker/orbstack/colima/podman backends:

- dce new generates ${DC_REPOS_DIR:-$HOME/repos}/<project>/.devcontainer/devcontainer.json
- For multi-scope and/or overlay projects, it points to a generated composed Containerfile
- Existing devcontainer.json is not overwritten
- To attach VS Code to the exact same running container as dce shell, use: Dev Containers: Attach to Running Container... and choose <project>
- dce new and dce rebuild-container also seed VS Code attached-container **named** config (`workspaceFolder=/workspace`) for that container name, so attach behavior stays consistent across image rebuilds/re-tags (existing named config is preserved)
- Dev Containers: Reopen in Container may create a separate `vsc-*` container for editor workflows

apple backend:

- dce new generates ${DC_REPOS_DIR:-$HOME/repos}/<project>/.vscode/settings.json
- Integrated terminal profile routes through dce shell
- Existing settings.json is not overwritten

VS Code is optional. Alias-based shell workflow is always supported.

## Daily usage example without VS Code Dev Containers

```
# status and lifecycle
dce status
dce start myapp-monorepo

# shell into the container
dce shell myapp-monorepo
cd /workspace

# run frontend and backend commands as needed
npm run dev
go test ./...

# one-shot command
dce shell myapp-monorepo "go run ./cmd/server"

# raw one-off command in the running container (no token/zsh wrapping)
dce exec myapp-monorepo node -v

# check why a container exited (works on stopped containers)
dce logs myapp-monorepo --tail 100

# restart (re-applies hidden mounts and SSH key, like stop+start)
dce restart myapp-monorepo

# stop when done
dce stop myapp-monorepo
```

## Daily usage example with VS Code Dev Containers

For docker/orbstack/colima/podman backends:

1. Open project folder:

```
code ${DC_REPOS_DIR:-$HOME/repos}/myapp-monorepo
```

2. Run: Dev Containers: Reopen in Container
3. Use integrated terminals and editor as usual
4. Use dce commands for lifecycle/recovery:

```
dce status
dce rebuild-container myapp-monorepo
```

For apple backend, use normal local folder + generated terminal profile instead of Dev Containers extension.

## Rebuild and incident recovery

Rebuild container (hidden volumes removed by default for a clean slate):

```
dce rebuild-container myapp-monorepo
```

Rebuild and rotate SSH key:

```
dce rebuild-container myapp-monorepo --rotate-keys
```

Rebuild while preserving hidden volumes (skip dependency re-install):

```
dce rebuild-container myapp-monorepo --keep-hidden-volumes
```

For incident recovery (e.g. suspected supply-chain compromise), always rebuild **without** `--keep-hidden-volumes` so hidden volumes like `node_modules` and build caches are destroyed and reinstalled from scratch. When the project has hidden paths configured, combining `--rotate-keys` with `--keep-hidden-volumes` triggers a loud warning (key rotation implies incident response, where preserving volumes may be unsafe).

## Rebuilding after Containerfile changes

If you change `Containerfile.base`, rebuild managed images first, then recreate containers:

```
dce rebuild-image all
dce rebuild-container myapp-monorepo
```

If you change overlay Containerfiles, rebuild managed images then recreate containers:

```
dce rebuild-image all
dce rebuild-container myapp-monorepo
```

`dce rebuild-image all` rebuilds the shared base image and all derived images selected by configured project scopes.

`dce rebuild-container` re-derives the image for that project and recreates only the container.

If you changed multiple Containerfiles and want everything refreshed:

```
dce rebuild-image all
dce rebuild-container myapp-monorepo
```

Notes:

- `dce rebuild-image` is backend-agnostic (apple/colima/docker/orbstack/podman via `CONTAINER_BACKEND` detection/override).
- `dce rebuild-image all` rebuilds `dce-base` and all configured derived images.
- `dce rebuild-container <project>` never rebuilds images. If the required image is missing, it fails and instructs you to run `dce rebuild-image all`.

## Image provenance

Each derived image (`dce-img-*`) is rebuilt in place and `:latest` is overwritten on every rebuild by design, so to answer *"what state were my overlay repos in when this image was built?"* DC Enclave records provenance:

- **OCI labels on the image** — `docker image inspect <img>` / `podman image inspect <img>` show `dce.team.git_commit`, `dce.user.git_commit`, `dce.team.content_hash`, `dce.content.hash`, `dce.base.id`, `dce.scopes`, `dce.built.utc`, and `org.opencontainers.image.revision`. Per overlay source (`team/`, `user/`) the git HEAD commit is recorded when that directory is a git checkout; a content fingerprint of the layered files is always recorded.
- **A per-project log** — `~/.config/dce-enclave/<name>/provenance.jsonl` (JSON Lines, owner-only) appends one entry per distinct image state, so the history survives the `:latest` overwrite. It is written when a derived image is actually built (`dce new`, `dce rebuild-image`), not on `dce rebuild-container` (which does not build) or base-only projects.

Read it back with:

```
dce provenance myapp                 # current build's provenance (pretty)
dce provenance myapp --history       # full timeline as a table
dce status                           # one-line provenance summary per project
```

To reproduce a build for debugging: read the `team`/`user` commit from `dce provenance`, check it out in the corresponding root (`git -C "$DC_TEAM_DIR" checkout <sha>` or `git -C "$DC_USER_DIR" checkout <sha>`), then `dce rebuild-image all && dce rebuild-container <name>`. A side not under git shows only its content fingerprint — no commit to check out, but the fingerprint still tells you whether your current files match that build.

`git_dirty: true` (label / log) means the image includes uncommitted overlay edits at build time.

## Cleaning old DC Enclave images

To clean managed DC Enclave images:

```
dce clean
```

Preview only:

```
dce clean --dry-run
```

Safety and cleanup scope:

- `dce clean` is backend-agnostic and uses the active backend (apple/colima/docker/orbstack/podman).
- It targets managed image repositories (`dce-base` and `dce-img-<hash>`) discovered from current project configs and backend image state.
- For expected managed repos, it preserves `:latest` and removes non-latest tags.
- For orphan managed repos, it removes all tags (including `:latest`).
- It does not remove unrelated images (for example VS Code `vsc-*` images).
- If a tag is still referenced by a container, removal may fail and is reported (no force delete).

## Removing a project

`dce rm` removes a dev container project outright. By default it performs a full teardown:

1. stops the container if it is running, then deletes it
2. removes every managed hidden volume (`dce-hide-<project>-<hash>`)
3. removes the per-project config + secrets directory (`~/.config/dce-enclave/<name>`), including the SSH key, GitHub token, and `.npmrc`

```
dce rm myapp                       # remove everything (prompts to confirm)
dce rm myapp --yes                 # remove everything without prompting
dce rm myapp --keep-config         # remove container + volumes, keep config/secrets
dce rm myapp --keep-volumes        # remove container + config/secrets, keep volumes
```

Safety notes:

- **Your host code is never touched.** The repo directory at `${DC_REPOS_DIR:-$HOME/repos}/<name>` (including the generated `.devcontainer/devcontainer.json`) is preserved. Remove it manually if it is no longer needed:
  ```
  rm -rf "${DC_REPOS_DIR:-$HOME/repos}/myapp"
  ```
- `dce rm` is destructive and prompts for confirmation (type `yes`) unless `--yes`/`-y` is given.
- The project name is validated and the secrets directory's real path is checked to reside under the DC Enclave config root, so a symlinked project directory cannot redirect deletion elsewhere.
- If the backend is unreachable, container/volume removal is skipped with a warning, but the config + secrets are still removed (unless `--keep-config`).
- To wipe only the container filesystem while keeping config and code, use `dce rebuild-container <name>` instead.

## Personal configuration (dotfiles)

Each team member sets up their own dotfiles for personal preferences (git identity, editor config, shell customizations).

### VS Code (automatic on create/rebuild)

In VS Code user settings (`Cmd+,`), point at a git repo or a local path:

Using a git repo:

```json
{
  "dev.containers.dotfilesRepository": "https://github.com/YOUR_USERNAME/dotfiles",
  "dev.containers.dotfilesInstallCommand": "install.sh"
}
```

Using a local path:

```json
{
  "dev.containers.dotfilesRepository": "/Users/YOU/.dotfiles",
  "dev.containers.dotfilesInstallCommand": "install.sh"
}
```

The Dev Containers extension clones or copies your dotfiles and runs the install script automatically after every container creation or rebuild.

### Command line (any backend)

```
dce install myapp ~/.dotfiles
```

Copies the dotfiles directory into the running container and executes its `install.sh`. Safe to re-run — idempotent if your install script is. This works with all backends and is the only option for the apple/container backend since it doesn't use the Dev Containers extension.

### What goes where

- Shared essentials → `Containerfile.base`
- Overlay examples (copy-first templates) → `Containerfiles/example/` (`Containerfile.all`, `Containerfile.nodejs`, `Containerfile.golang`, and any others you add)
- Preferred day-to-day tools → user overlay Containerfile(s) layered during `dce new`/`dce rebuild-image`
- Project secrets (PAT, SSH key, .npmrc) → `~/.config/dce-enclave/<name>/`
- Personal preferences (git identity, vim, shell) → your dotfiles repo

### Starter dotfiles

See `templates/dotfiles/` in this repo for a ready-to-fork example.

## Troubleshooting

Run `dce doctor` first. It runs read-only preflight checks across the host environment and every detected backend (or one backend / one project if given) and prints a pass/fail per subsystem — bash version, global config and overlay root, backend CLI presence, runtime reachability, Colima context/runtime drift, and a per-backend `dce-base:latest`. It never starts or mutates anything and exits nonzero if anything fails, so it pinpoints drift (Colima context drifted, Podman machine stopped, stale dce-base, wrong bash) in one shot.

```
dce doctor              # all detected backends + host checks
dce doctor colima       # one backend
dce doctor myapp        # one project + its backend
```

Bash version too old:

```
bash --version
# if < 4.0 on macOS:
brew install bash
```

No backend detected:

- install apple/container, Docker Desktop, OrbStack, Colima, or Podman
- rerun scripts/setup.sh

Need specific backend:

```
CONTAINER_BACKEND=apple scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
CONTAINER_BACKEND=podman dce new myapp nodejs 3000:3000
```

Colima backend issues:

```
# start Colima with the required runtime
colima start --runtime docker

# ensure Docker CLI is using Colima context
docker context use colima

# verify status and runtime
colima status
```

devcontainer.json or settings.json not overwritten:

- expected behavior to avoid clobbering local config
- update file manually if needed

Changed ports or resource limits:

- update ~/.config/dce-enclave/<name>/config
- run dce rebuild-container <name>

SSH auth issues:

- verify ~/.config/dce-enclave/<name>/ssh_key and github-token
- restart with dce start or recreate with dce rebuild-container

Podman on macOS not starting:

```
podman machine start
```

## Smoke tests

Run every test file in `tests/` with a single pass/fail summary (no fail-fast, so you see every failure in one run):

```
tests/run-all.sh
tests/run-all.sh -v   # stream each file's output live
```

The suite includes `tests/shellcheck.sh`, a static-analysis pass over every Bash
script in the repo. ShellCheck is optional at runtime: when installed, any
finding fails the suite; when absent, the run still passes but prints one
`WARN:` line per script (surfaced under the `-> PASS:` line) with the install
link. Install it to silence the warnings and enable the checks:

```
brew install shellcheck        # macOS
# https://github.com/koalaman/shellcheck
```

`tests/smoke.sh` is the lightweight command smoke suite. Help, version, and security-guard checks always run; `dce list`, `dce status`, and `dce clean` checks run when a backend is reachable and are otherwise skipped:

```
tests/smoke.sh
```

Optional backend override:

```
CONTAINER_BACKEND=podman tests/run-all.sh
CONTAINER_BACKEND=colima tests/smoke.sh
```

## Connecting to host PostgreSQL securely

You do not need SSH tunneling for normal local development. A normal connection string is enough.

For docker/orbstack/colima backends, use `host.docker.internal` as host:

```
postgresql://<user>:<password>@host.docker.internal:5432/<db>
```

For podman backend, use `host.containers.internal`:

```
postgresql://<user>:<password>@host.containers.internal:5432/<db>
```

Note: `dce new` configures podman containers with `host.docker.internal` as an alias, so either hostname works with podman.

For this to work, your PostgreSQL instance must allow it:

- listen on an address reachable from the container runtime
- allow container network clients in pg_hba.conf
- keep auth strict (password/scram), and avoid opening broad CIDRs unnecessarily

If you install PostgreSQL client in your overlay Containerfile, verify with:

```
dce shell <name> "psql --version"
```

## Private networks between containers

By default dce containers are isolated: they cannot reach each other. To let two
containers talk (e.g. an app and its database) **without publishing any port to
the host**, create a private network and attach both containers to it on purpose:

```
dce network create myapp
dce new myapp-db  --network myapp
dce new myapp-web --network myapp
# myapp-web can now reach myapp-db by name; no -p port publishing required
```

Linking is explicit — a container is only reachable from peers that share one of
its networks. Containers created without `--network` are not dce-linked to anyone.

### Addressing (peer names)

Containers on the same network resolve each other by **project name**:

- docker / orbstack / colima / podman: the bare name, e.g. `myapp-db`
- apple/container: `<name>.test`, e.g. `myapp-db.test` (requires macOS 26+)

So inside `myapp-web`, point your app at the hostname `myapp-db` (docker) or
`myapp-db.test` (apple/container).

### Static IPs (optional)

Names are usually all you need. For apps that hardcode an address, pin a static
IPv4 on the primary network:

```
dce new myapp-db --network myapp --ip 10.0.0.10
# or equivalently: --network myapp:10.0.0.10
```

Static IPs are supported on Docker-compatible backends only (not apple/container).

### Managing networks

```
dce network ls                       # list networks + their dce members
dce network members myapp            # which projects are on a network
dce network add myapp myapp-web --ip 10.0.0.20   # attach an existing container
dce network remove myapp myapp-web   # detach a container
dce network rm myapp                 # remove (refuses while members exist)
```

`dce network add`/`remove` keep the project config in sync, so the membership
survives `dce rebuild-container`. On apple/container, attach networks at
`dce new` time (live add/remove and static IPs are not supported, and a container
may join a single network).

### Security note

Putting containers on a shared network widens their east-west reach — but only
to the projects explicitly placed on that same network, and only over the network
(no shared filesystem, PID, or IPC namespace). For the local single-user dev
model this is strictly safer than the alternative of publishing dev databases on
the host.
