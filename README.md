# dev-containers

Isolated development containers for macOS, Linux, and WSL2 with one shared Bash codebase and five supported backends:

- apple/container (macOS)
- Docker Desktop (macOS, Linux, WSL2)
- OrbStack (macOS)
- Colima (macOS, Linux)
- Podman (macOS, Linux, WSL2)

## Goal

**dev-containers** standardizes per-project containerized development environments from a shared Bash codebase. After one-time setup, `dc new` creates an isolated workspace for any repo while letting each developer use their preferred backend, tools, and dotfiles through overlay Containerfiles. Teams share the same base image and overlay model, and projects can optionally keep separate credentials and container state. If an environment is compromised or drifts, you can regenerate it quickly with `dc rebuild-image all` + `dc rebuild-container`, then audit repos and rotate access tokens.

## Requirements

- **Bash 4+** — all scripts require Bash 4 or later
  - macOS: `brew install bash` (macOS ships bash 3.2)
  - Linux: included by default on most distros
  - WSL2: included by default
- One container backend installed and running (see Backend selection below)

Podman support policy:

- dev-containers supports the latest stable Podman release only
- tested baseline at migration: Podman 5.2.x
- if you hit Podman behavior differences on older releases, upgrade Podman first

Colima support policy:

- dev-containers supports the latest stable Colima release only
- use Colima with Docker runtime (`colima start --runtime docker`)
- if Colima is running with a non-Docker runtime (for example containerd), switch back to Docker runtime before using dev-containers

## Isolation design

Each project container is set up with its own credentials and container state so projects stay independent:

- Per-project GitHub PAT — store a fine-grained, repo-scoped token (no admin) in `~/.config/dev-containers/<name>/github-token`
- Per-project SSH deploy key — add a dedicated key pair under `~/.config/dev-containers/<name>/`
- Per-project .npmrc — place a config alongside the other secrets for projects that use npm
- Host-mounted workspace — code lives at `${DC_REPOS_DIR:-$HOME/repos}/<project>` on your machine and is bind-mounted to `/workspace` inside the container

If a container's state is ever suspect, `dc rebuild-container` replaces the container from a known-good image without touching your host repos.

### GitHub SSH host key pinning

GitHub's SSH host keys are **pinned in the base image** (`Containerfiles/ssh/github_known_hosts`), not learned at runtime. The base image sets `StrictHostKeyChecking yes` for `github.com` and points its `UserKnownHostsFile` at the pinned file, so an unknown or mismatched host key fails closed instead of being silently trusted on first contact. `dc new`, `dc start`, and `dc rebuild-container` only inject your deploy key — they no longer run `ssh-keyscan`.

Rotating the pin (e.g. when GitHub changes a key) is a deliberate, reviewed change:

1. Re-verify the new keys against three independent channels — see `plans/security/m4.md` ("Verification channels").
2. Update `Containerfiles/ssh/github_known_hosts` **and** the `FP_*` constants in `tests/security-ssh-host-trust.sh` in the same change.
3. `dc rebuild-image base` then `dc rebuild-container <name>` to pick up the new pin.

The `tests/security-ssh-host-trust.sh` guard blocks a wrong/poisoned pin (it asserts the pinned fingerprints match GitHub's published values) and fails if `accept-new` or runtime `ssh-keyscan github.com` is reintroduced.

## Command reference

The day-to-day interface is the `dc` command with subcommands. All subcommands dispatch to scripts under `scripts/`.

| Command | Description |
|---|---|
| `dc new` (forms below) | Create a new isolated container project |
| `dc status` | Show overall status and per-project details |
| `dc start [name]` | Start one project or all configured projects |
| `dc stop [name]` | Stop one project or all configured projects |
| `dc shell <name> [command]` | Open a shell or run one command inside a project container |
| `dc rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes]` | Destroy and recreate container from selected image |
| `dc rebuild-image [all\|base]` | Rebuild base image and (for `all`) all configured derived images |
| `dc clean [--dry-run] [--hidden-volumes [name]]` | Remove old/orphan managed image tags or orphan managed hidden volumes |
| `dc install <name> <path-to-dotfiles>` | Install or update dotfiles in a running container |
| `dc help` | Show usage information |

`<scope>` values in `dc new` are overlay scopes that match `Containerfile.<scope>` files in your overlay directories. Scope is optional — `dc new <name>` creates a base-only project. The `all` scope is always auto-layered when `Containerfile.all` exists.

**`dc new` forms** — `<scope>` can be any scope name matching a `Containerfile.<scope>` in your overlays or a comma-separated combination:

| Form | Description |
|---|---|
| `dc new <name> [scope[,scope...]] [host:container ...]` | Basic form with port mappings |
| `dc new <name> [scope[,scope...]] [--repo-path <path>] [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [host:container ...]` | With resource limits and hidden paths (see [Hiding generated paths](#hiding-generated-paths-from-the-host---hide)) |

## Global configuration and overlays

`setup.sh` bootstraps global configuration in:

```
~/.config/dev-containers/config
```

Required key:

```bash
DC_OVERLAYS_DIR="$HOME/.config/dev-containers/overlays"
```

`dc new`, `dc rebuild-image`, and `dc rebuild-container` load `DC_OVERLAYS_DIR` from this config file. If the global config file is missing, `DC_OVERLAYS_DIR` is unset, or the overlays root does not exist, the command fails fast with remediation guidance.

Overlay layout under `DC_OVERLAYS_DIR`:

```
$DC_OVERLAYS_DIR/
├── team/
│   ├── README.md
│   ├── Containerfile.all          # auto-layered when it exists
│   └── Containerfile.<scope>      # any scope name you define
└── user/
    ├── README.md
    ├── Containerfile.all
    └── Containerfile.<scope>
```

`setup.sh` creates the overlays root and both namespace directories (`team/`, `user/`) and adds starter README files if missing.

### Overlay ownership model

- `Containerfiles/example/` in this repo is for reference templates only (never auto-layered)
- `$DC_OVERLAYS_DIR/team/` is for shared team overlays
- `$DC_OVERLAYS_DIR/user/` is for personal overlays


### Canonical layering order

For scope list `<scope1>,<scope2>`, overlay composition order is:

1. `team/all`
2. `user/all`
3. `team/<scope1>`
4. `user/<scope1>`
5. `team/<scope2>`
6. `user/<scope2>`


`dev-base` is always the only repo-defined base layer. The `all` scope is always checked first — if `Containerfile.all` exists in team or user overlays, it is included automatically even without specifying `all` on the command line.

Missing unrequested overlay files are skipped silently. If you request a named scope and it is missing in both `team/` and `user/`, the command fails fast.

## Why dev-containers?

If you are already comfortable with Docker, Podman, or apple/container CLIs, `dc` still saves work by orchestrating repetitive setup and recovery steps consistently across projects and machines.

What `dc` adds beyond raw backend commands:

- project bootstrap from a shared base image plus optional overlay Containerfiles
- persisted per-project configuration in `~/.config/dev-containers/<name>/config`
- consistent mounts, ports, and resource limit handling across backends
- optional per-project credential layout for PAT/SSH key/.npmrc with repeatable rebuild flows
- one-command rebuild and key-rotation workflows for incident response

The table below intentionally focuses on the high-leverage commands where `dc` saves the most effort. It is not a complete mapping of every subcommand. Docker, OrbStack, and Colima are grouped because they share the Docker CLI.

| `dc` command | docker / orbstack / colima | podman | apple/container |
|---|---|---|---|
| `dc new myapp nodejs 3000:3000` | Compose Containerfile layers, run `docker build`, `docker create` (mounts/ports/limits), and `docker start`; then set up project config, keys, and editor files | Same flow with `podman` | Same flow with `container` |
| `dc new ...` (with overlay) | Merge team/user overlay fragments over `dev-base` (composition rules), then build/create/start | Same flow | Same flow |
| `dc rebuild-container myapp` | Re-derive target image from scopes, then `docker rm -f myapp`, recreate with the original `docker create` flags, and `docker start` | Same flow with `podman` | `container delete myapp`, then recreate and start |
| `dc rebuild-container myapp --rotate-keys` | Rebuild-container flow plus SSH key regeneration and deploy-key rotation | Same flow | Same flow |
| `dc clean` | `docker image ls` + remove non-`latest` tags for managed repos | Same flow with `podman image ls/rm` | Same flow with `container image ls/rm` |
| `dc install myapp ~/.dotfiles` | Stream dotfiles via `tar` + `docker exec`, run `install.sh`, then remove temp files | Same flow with `podman` | Same flow with `container exec` |

`dc new`, `dc rebuild-image`, and `dc rebuild-container` are the biggest differentiators: repeatable orchestration for image lifecycle, container recovery, and security response without retyping fragile backend-specific command sequences. `dc clean` and `dc install` reduce ongoing maintenance overhead once projects are up and running.

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

- Docker context is a Docker CLI concept (`docker context ...`), not a dev-containers-specific setting
- dev-containers reads the active context to distinguish OrbStack/Colima from generic Docker
- when forcing `CONTAINER_BACKEND=colima`, dev-containers requires a Colima Docker context and will fail fast if the active context is not Colima

Selected backend is stored per project in `~/.config/dev-containers/<name>/config`.

### Platform-specific notes

**macOS + Colima**: Install with `brew install colima docker`, then run `colima start --runtime docker`. Colima usually auto-activates its Docker context; if needed, run `docker context use colima`.

**Linux + Colima**: Install Colima and Docker CLI, then run `colima start --runtime docker`. Ensure virtualization support is available (for example KVM access where required by your distro setup).

**macOS + Podman**: Podman runs in a VM on macOS. Run `podman machine start` before using dev-containers, or let `setup.sh` start it for you.

**Linux + Podman**: Podman runs rootless with no daemon. Works out of the box on most distros (`apt install podman`, `dnf install podman`).

**WSL2**: Docker Desktop's WSL2 integration makes `docker` available inside WSL2. Podman can be installed natively inside WSL2 (`apt install podman`). For best bind-mount performance, keep repos inside the WSL2 filesystem (`${DC_REPOS_DIR:-$HOME/repos}/`) rather than on the Windows mount (`/mnt/c/`).

## Repository layout

```
dev-containers/
├── Containerfiles/
│   ├── Containerfile.base
│   ├── example/
│   │   ├── Containerfile.nodejs        # overlay template example
│   │   ├── Containerfile.golang        # overlay template example
│   │   ├── Containerfile.all           # overlay template example
│   │   └── README.md
│   └── generated/                      # auto-generated composed files (project overlays)
├── lib/
│   ├── common.sh                       # bash 4+ version guard, shared helpers
│   ├── platform.sh                     # OS detection, path helpers
│   └── container-backend.sh            # backend abstraction
├── scripts/
│   ├── dc                               # CLI entry point
│   ├── dc-complete.bash                 # bash tab completion
│   ├── setup.sh
│   ├── compose-containerfile.sh
│   ├── new-container.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── shell.sh
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
- secrets: ~/.config/dev-containers/<project>
- per-project config: ~/.config/dev-containers/<project>/config (backend, image, ports, resource limits, secrets paths)
- global config: ~/.config/dev-containers/config
- global overlays root: `DC_OVERLAYS_DIR` (typically `~/.config/dev-containers/overlays`)

## Three-source model (repo, team overlays, user overlays)

Keep these sources separate:

1. **dev-containers repo** (`Containerfiles/base + Containerfiles/example`, scripts, docs)
2. **team overlays source** (files synced into `$DC_OVERLAYS_DIR/team`)
3. **user overlays source** (files synced into `$DC_OVERLAYS_DIR/user`)

This separation avoids coupling team customization with personal customization and keeps layering deterministic.

Recommended flow:

- keep `$DC_OVERLAYS_DIR/team` as a git checkout of a private team overlays repository and update with `git pull`
- keep `$DC_OVERLAYS_DIR/user` as a git checkout of your personal overlays repository and update with `git pull`
- keep the public `dev-containers` repository focused on base image definition and reference templates under `Containerfiles/example/`

Example setup:

```
git clone git@github.com:YOUR-ORG/dev-container-team-overlays.git "$DC_OVERLAYS_DIR/team"
git clone git@github.com:YOUR-USER/dev-container-user-overlays.git "$DC_OVERLAYS_DIR/user"
```

Then keep overlays current:

```bash
git -C "$DC_OVERLAYS_DIR/team" pull --ff-only
git -C "$DC_OVERLAYS_DIR/user" pull --ff-only
```

## Initial setup

**Important**: `setup.sh` builds `dev-base` into the selected backend's image store. Each container backend maintains its own separate image store. If you want to use multiple backends, you must run `setup.sh` once per backend:

```
CONTAINER_BACKEND=docker scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
```

Images built on one backend are not visible to another. `dc new` checks for `dev-base:latest` on the active backend and fails early if setup has not been run for that backend.

`setup.sh` also bootstraps global overlay configuration and directories:

- `~/.config/dev-containers/config` with `DC_OVERLAYS_DIR`
- `$DC_OVERLAYS_DIR/team`
- `$DC_OVERLAYS_DIR/user`

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
cd ~/dev-containers
chmod +x scripts/*.sh scripts/dc
scripts/setup.sh
```

4. Reload your shell profile:

```
source ~/.bashrc    # Linux, WSL2
source ~/.bash_profile    # macOS
```

Optional: force backend during setup:

```
CONTAINER_BACKEND=podman scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
```

## Setup of a new repo

Use dc new (alias), not direct script invocation.

Base-only example (no scopes needed — base image plus `Containerfile.all` if present):

```
dc new myapp 3000:3000
```

Single-scope examples (scope names match `Containerfile.<scope>` in your overlay dirs):

```
dc new myapp-frontend nodejs 3000:3000 5173:5173
dc new myapp-backend golang 8080:8080 9000:9000
dc new work-api golang --repo-path ~/code/company/api 8080:8080
```

Monorepo with multiple overlay scopes and multiple ports:

```
dc new myapp-monorepo nodejs,golang 3000:3000 5173:5173 8080:8080 9000:9000
```

Auto overlays example (`team/all`, `user/all`, plus scope-specific files when present):

```
dc new myapp-monorepo nodejs,golang 3000:3000 8080:8080
```

With resource limits:

```
dc new myapp-backend golang --cpus 2 --memory 4g 8080:8080
```

What scope combinations mean:

- `<scope>` -> include `Containerfile.<scope>` overlay files from team/user dirs
- `<scope1>,<scope2>` -> include both scopes in canonical order (all first, then listed order)
- (no scope) -> base image only, plus `Containerfile.all` when it exists
- auto overlays -> loaded from `$DC_OVERLAYS_DIR/team` and `$DC_OVERLAYS_DIR/user`


Overlay contract:

- Treated as Dockerfile fragments layered on top of `dev-base`
- `FROM` and `CMD` are ignored during composition
- `COPY` and `ADD` are not allowed (to avoid external build-context coupling)

Starter file note:

- `Containerfiles/example/Containerfile.all` is a reference template.
- Copy it into `$DC_OVERLAYS_DIR/team` or `$DC_OVERLAYS_DIR/user`, then customize.

After dc new:

1. Edit ~/.config/dev-containers/<name>/github-token
2. Add ~/.config/dev-containers/<name>/ssh_key.pub as GitHub Deploy Key
3. Clone repo(s) into ${DC_REPOS_DIR:-$HOME/repos}/<name>

Port mapping notes:

- Format is host-port:container-port
- Multiple mappings are supported in one dc new command
- Example: 3000:3000 5173:5173 8080:8080

## CPU and memory limits

All five backends support per-container CPU and memory limits. Set them at creation time or change them in the config file and rebuild.

Set limits at creation:

```
dc new myapp nodejs --cpus 2 --memory 4g 3000:3000
```

Omit scope for a base-only project with resource limits:

```
dc new myapp --cpus 2 --memory 4g 3000:3000
```

Omit both flags to use backend defaults (typically unrestricted).

Change limits on an existing project:

1. Edit `~/.config/dev-containers/<name>/config`
2. Update `CONTAINER_CPUS` and/or `CONTAINER_MEMORY`
3. Run `dc rebuild-container <name>`

Resource limits are applied at container creation time. Changes to the config file take effect only after `dc rebuild-container` — `dc start` simply starts the existing container with its existing limits.

Config keys:

- `CONTAINER_CPUS` — number of CPUs (e.g. `2`, `1.5`). Empty = backend default.
- `CONTAINER_MEMORY` — memory limit with suffix (e.g. `4g`, `512m`). Empty = backend default.

All backends use the same flag syntax (`--cpus`, `--memory`). No backend-specific configuration is needed.

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
dc new myapp nodejs --hide node_modules 3000:3000
dc new monorepo nodejs,golang \
  --hide node_modules \
  --hide apps/web/node_modules,apps/api/node_modules \
  --hide .cache/go/mod,.cache/go/build \
  3000:3000 8080:8080
```

### How it works

- Each hidden path gets a deterministic named volume (`dc-hide-<project>-<hash>`) mounted at `/workspace/<path>`.
- After container start, dc ensures the hidden mount points are writable by the `dev` user (root `mkdir`/`chown` fallback applied across all backends).
- Hidden paths are persisted in the project config (`CONTAINER_HIDDEN_PATHS`) and automatically remounted on `dc rebuild-container`.
- **`dc rebuild-container` removes hidden volumes by default** for a clean slate (fresh dependency install, no stale caches). Use `--keep-hidden-volumes` to preserve them.
- For Docker-compatible backends, hidden mounts are also added to the generated `devcontainer.json` so VS Code Dev Containers uses the same layout.

### Overlay integration

Scope-specific overlays can build on hidden volumes. For example, the Node.js overlay (`Containerfile.nodejs`) includes an entrypoint that:

- detects a hidden `node_modules` volume
- runs `npm ci` (if a lockfile exists) or `npm install` automatically on container start
- writes a hash sentinel so deps are only re-installed when `package.json` or `package-lock.json` changes
- fails soft by default; set `DC_NODE_INSTALL_STRICT=1` to make install errors fatal

This means you get fast, correct dependency sync without any `node_modules` files touching your host.

### Cleaning up hidden volumes

Hidden volumes are removed automatically during `dc rebuild-container` (default behavior) so the rebuilt container starts clean. To reclaim space from orphaned volumes left behind by deleted projects:

```
dc clean --hidden-volumes --dry-run    # preview what would be removed
dc clean --hidden-volumes              # remove orphan hidden volumes
dc clean --hidden-volumes myproject    # scope to one project
```

Only `dc-hide-*` managed volumes that no longer correspond to an active project config are removed.

## Monorepo and multi-repo patterns

Monorepo:

- One container, one workspace tree (example: ${DC_REPOS_DIR:-$HOME/repos}/myapp-monorepo)
- Can combine scopes with dc new ... `<scope1>,<scope2>` ...

Multi-repo with separate trust boundaries:

- Separate containers (frontend/backend) with separate credentials

Single-container multi-repo workspace:

- Put all repos under one host folder for that container
- Example: ${DC_REPOS_DIR:-$HOME/repos}/project-fe/frontend-app, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/shared-ui, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/api-client
- All appear in container under /workspace

## VS Code behavior by backend

docker/orbstack/colima/podman backends:

- dc new generates ${DC_REPOS_DIR:-$HOME/repos}/<project>/.devcontainer/devcontainer.json
- For multi-scope and/or overlay projects, it points to a generated composed Containerfile
- Existing devcontainer.json is not overwritten
- To attach VS Code to the exact same running container as dc shell, use: Dev Containers: Attach to Running Container... and choose <project>
- dc new and dc rebuild-container also seed VS Code attached-container **named** config (`workspaceFolder=/workspace`) for that container name, so attach behavior stays consistent across image rebuilds/re-tags (existing named config is preserved)
- Dev Containers: Reopen in Container may create a separate `vsc-*` container for editor workflows

apple backend:

- dc new generates ${DC_REPOS_DIR:-$HOME/repos}/<project>/.vscode/settings.json
- Integrated terminal profile routes through dc shell
- Existing settings.json is not overwritten

VS Code is optional. Alias-based shell workflow is always supported.

## Daily usage example without VS Code Dev Containers

```
# status and lifecycle
dc status
dc start myapp-monorepo

# shell into the container
dc shell myapp-monorepo
cd /workspace

# run frontend and backend commands as needed
npm run dev
go test ./...

# one-shot command
dc shell myapp-monorepo "go run ./cmd/server"

# stop when done
dc stop myapp-monorepo
```

## Daily usage example with VS Code Dev Containers

For docker/orbstack/colima/podman backends:

1. Open project folder:

```
code ${DC_REPOS_DIR:-$HOME/repos}/myapp-monorepo
```

2. Run: Dev Containers: Reopen in Container
3. Use integrated terminals and editor as usual
4. Use dc commands for lifecycle/recovery:

```
dc status
dc rebuild-container myapp-monorepo
```

For apple backend, use normal local folder + generated terminal profile instead of Dev Containers extension.

## Rebuild and incident recovery

Rebuild container (hidden volumes removed by default for a clean slate):

```
dc rebuild-container myapp-monorepo
```

Rebuild and rotate SSH key:

```
dc rebuild-container myapp-monorepo --rotate-keys
```

Rebuild while preserving hidden volumes (skip dependency re-install):

```
dc rebuild-container myapp-monorepo --keep-hidden-volumes
```

For incident recovery (e.g. suspected supply-chain compromise), always rebuild **without** `--keep-hidden-volumes` so hidden volumes like `node_modules` and build caches are destroyed and reinstalled from scratch. Combining `--rotate-keys` with `--keep-hidden-volumes` triggers a loud warning.

## Rebuilding after Containerfile changes

If you change `Containerfile.base`, rebuild managed images first, then recreate containers:

```
dc rebuild-image all
dc rebuild-container myapp-monorepo
```

If you change overlay Containerfiles, rebuild managed images then recreate containers:

```
dc rebuild-image all
dc rebuild-container myapp-monorepo
```

`dc rebuild-image all` rebuilds the shared base image and all derived images selected by configured project scopes.

`dc rebuild-container` re-derives the image for that project and recreates only the container.

If you changed multiple Containerfiles and want everything refreshed:

```
dc rebuild-image all
dc rebuild-container myapp-monorepo
```

Notes:

- `dc rebuild-image` is backend-agnostic (apple/colima/docker/orbstack/podman via `CONTAINER_BACKEND` detection/override).
- `dc rebuild-image all` rebuilds `dev-base` and all configured derived images.
- `dc rebuild-container <project>` never rebuilds images. If the required image is missing, it fails and instructs you to run `dc rebuild-image all`.

## Cleaning old dev-container images

To clean managed dev-container images:

```
dc clean
```

Preview only:

```
dc clean --dry-run
```

Safety and cleanup scope:

- `dc clean` is backend-agnostic and uses the active backend (apple/colima/docker/orbstack/podman).
- It targets managed image repositories (`dev-base` and `dev-img-<hash>`) discovered from current project configs and backend image state.
- For expected managed repos, it preserves `:latest` and removes non-latest tags.
- For orphan managed repos, it removes all tags (including `:latest`).
- It does not remove unrelated images (for example VS Code `vsc-*` images).
- If a tag is still referenced by a container, removal may fail and is reported (no force delete).

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
dc install myapp ~/.dotfiles
```

Copies the dotfiles directory into the running container and executes its `install.sh`. Safe to re-run — idempotent if your install script is. This works with all backends and is the only option for the apple/container backend since it doesn't use the Dev Containers extension.

### What goes where

- Shared essentials → `Containerfile.base`
- Overlay examples (copy-first templates) → `Containerfiles/example/` (`Containerfile.all`, `Containerfile.nodejs`, `Containerfile.golang`, and any others you add)
- Preferred day-to-day tools → user overlay Containerfile(s) layered during `dc new`/`dc rebuild-image`
- Project secrets (PAT, SSH key, .npmrc) → `~/.config/dev-containers/<name>/`
- Personal preferences (git identity, vim, shell) → your dotfiles repo

### Starter dotfiles

See `templates/dotfiles/` in this repo for a ready-to-fork example.

## Troubleshooting

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
CONTAINER_BACKEND=podman dc new myapp nodejs 3000:3000
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

- update ~/.config/dev-containers/<name>/config
- run dc rebuild-container <name>

SSH auth issues:

- verify ~/.config/dev-containers/<name>/ssh_key and github-token
- restart with dc start or recreate with dc rebuild-container

Podman on macOS not starting:

```
podman machine start
```

## Smoke tests

Run the lightweight command smoke suite (requires a configured backend and at least one sample project where applicable):

```
tests/smoke.sh
```

Optional backend override:

```
CONTAINER_BACKEND=podman tests/smoke.sh
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

Note: `dc new` configures podman containers with `host.docker.internal` as an alias, so either hostname works with podman.

For this to work, your PostgreSQL instance must allow it:

- listen on an address reachable from the container runtime
- allow container network clients in pg_hba.conf
- keep auth strict (password/scram), and avoid opening broad CIDRs unnecessarily

If you install PostgreSQL client in your overlay Containerfile, verify with:

```
dc shell <name> "psql --version"
```
