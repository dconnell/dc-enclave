# dev-containers

Isolated development containers for macOS, Linux, and WSL2 with one shared Bash codebase and five supported backends:

- apple/container (macOS)
- Docker Desktop (macOS, Linux, WSL2)
- OrbStack (macOS)
- Colima (macOS, Linux)
- Podman (macOS, Linux, WSL2)

## Goal

**dev-containers** standardizes per-project containerized development environments from a shared Bash codebase. After one-time setup, `dc new` creates an isolated workspace for any repo while letting each developer use their preferred backend, tools, and dotfiles through overlay Containerfiles. Teams share the same base and runtime definitions, and projects can optionally keep separate credentials and runtime state. If an environment is compromised or drifts, you can regenerate it quickly with `dc rebuild`, then audit repos and rotate access tokens.

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

Each project container is set up with its own credentials and runtime state so projects stay independent:

- Per-project GitHub PAT — store a fine-grained, repo-scoped token (no admin) in `~/.config/dev-containers/<name>/github-token`
- Per-project SSH deploy key — add a dedicated key pair under `~/.config/dev-containers/<name>/`
- Per-project .npmrc — place a Node-specific config alongside the other secrets for Node projects
- Host-mounted workspace — code lives at `${DC_REPOS_DIR:-$HOME/repos}/<project>` on your machine and is bind-mounted to `/workspace` inside the container

If a container's runtime state is ever suspect, `dc rebuild` replaces the container from a known-good image without touching your host repos.

## Command reference

The day-to-day interface is the `dc` command with subcommands:

- dc new <name> <type[,type|overlay-path...]> [host:container ...]: create a new isolated container project
- dc new <name> <type[,type|overlay-path...]> [--repo-path <path>] [--cpus <N>] [--memory <val>] [host:container ...]: with resource limits
- dc new <name> <type[,type...]> [--repo-path <path>] [--overlay-containerfile <file> ...] [host:container ...]: with overlay files (repeat flag for multiple)
- dc status: show overall status and per-project details
- dc start [name]: start one project or all configured projects
- dc stop [name]: stop one project or all configured projects
- dc shell <name> [command]: open shell or run one command inside project container
- dc rebuild <name> [--rotate-keys]: destroy and recreate container from known-good image
- dc rebuild-image [all|base|nodejs|golang]: rebuild shared images (project-scoped overlay images are rebuilt by `dc rebuild`)
- dc clean [--dry-run]: remove old dev-container image tags while keeping latest
- dc install <name> <path-to-dotfiles>: install or update dotfiles in a running container
- dc help: show usage information

All subcommands dispatch to scripts under `scripts/`.

## Why dev-containers?

If you are already comfortable with Docker, Podman, or apple/container CLIs, `dc` still saves work by orchestrating repetitive setup and recovery steps consistently across projects and machines.

What `dc` adds beyond raw backend commands:

- project bootstrap from shared base/runtime definitions plus optional overlay Containerfiles
- persisted per-project configuration in `~/.config/dev-containers/<name>/config`
- consistent mounts, ports, and resource limit handling across backends
- optional per-project credential layout for PAT/SSH key/.npmrc with repeatable rebuild flows
- one-command rebuild and key-rotation workflows for incident response

The table below intentionally focuses on the high-leverage commands where `dc` saves the most effort. It is not a complete mapping of every subcommand. Docker, OrbStack, and Colima are grouped because they share the Docker CLI.

| `dc` command | docker / orbstack / colima | podman | apple/container |
|---|---|---|---|
| `dc new myapp nodejs 3000:3000` | Compose Containerfile layers, run `docker build`, `docker create` (mounts/ports/limits), and `docker start`; then set up project config, keys, and editor files | Same flow with `podman` | Same flow with `container` |
| `dc new ...` (with overlay) | Merge runtime and overlay fragments (composition rules), then build/create/start | Same flow | Same flow |
| `dc rebuild myapp` | `docker rm -f myapp`, then recreate with the original `docker create` flags and `docker start` | Same flow with `podman` | `container delete myapp`, then recreate and start |
| `dc rebuild myapp --rotate-keys` | Rebuild flow plus SSH key regeneration and deploy-key rotation | Same flow | Same flow |
| `dc clean` | `docker image ls` + remove non-`latest` tags for managed repos | Same flow with `podman image ls/rm` | Same flow with `container image ls/rm` |
| `dc install myapp ~/.dotfiles` | Stream dotfiles via `tar` + `docker exec`, run `install.sh`, then remove temp files | Same flow with `podman` | Same flow with `container exec` |

`dc new`, `dc rebuild`, and `dc rebuild --rotate-keys` are the biggest differentiators: repeatable orchestration for container creation, recovery, and security response without retyping fragile backend-specific command sequences. `dc clean` and `dc install` reduce ongoing maintenance overhead once projects are up and running.

## Common Tools Included In Base Image

The base image is intentionally minimal and shared across runtime types. It includes essentials only:

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
│   ├── Containerfile.nodejs
│   ├── Containerfile.golang
│   └── generated/                      # auto-generated composed files (multi-runtime/project overlays)
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
│   ├── rebuild.sh
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

## Initial setup

**Important**: `setup.sh` builds base images (dev-base, dev-nodejs, dev-golang) into the selected backend's image store. Each container backend maintains its own separate image store. If you want to use multiple backends, you must run `setup.sh` once per backend:

```
CONTAINER_BACKEND=docker scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
```

Images built on one backend are not visible to another. `dc new` will check that the required images exist on the active backend and fail early if setup has not been run for that backend.

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

Single runtime examples:

```
dc new myapp-frontend nodejs 3000:3000 5173:5173
dc new myapp-backend golang 8080:8080 9000:9000
dc new work-api golang --repo-path ~/code/company/api 8080:8080
```

Monorepo with multiple runtimes and multiple ports:

```
dc new myapp-monorepo nodejs,golang 3000:3000 5173:5173 8080:8080 9000:9000
```

Overlay example (preferred tools baked at image build time):

```
dc new myapp-monorepo nodejs,golang,../../path/to/Containerfile.username 3000:3000 8080:8080
```

Starter overlay included in this repo:

```
dc new myapp-monorepo nodejs,golang,Containerfiles/Containerfile.user 3000:3000 8080:8080
```

Equivalent explicit flag form:

```
dc new myapp-monorepo nodejs,golang --overlay-containerfile ../../path/to/Containerfile.username 3000:3000 8080:8080
```

With resource limits:

```
dc new myapp-backend golang --cpus 2 --memory 4g 8080:8080
```

What type combinations mean:

- nodejs -> use Node.js runtime image
- golang -> use Go runtime image
- nodejs,golang -> generate a project-scoped composed image from both runtime Containerfiles
- any overlay path token -> include that user overlay fragment in the composed project image

Overlay contract (phase 1):

- Treated as Dockerfile fragments layered after runtime fragments
- `FROM` and `CMD` are ignored during composition
- `COPY` and `ADD` are not allowed (to avoid external build-context coupling)

Starter file note:

- `Containerfiles/Containerfile.user` is provided as a default starting point with common convenience tools.
- Copy and customize it for your own workflow.

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

Omit both flags to use backend defaults (typically unrestricted).

Change limits on an existing project:

1. Edit `~/.config/dev-containers/<name>/config`
2. Update `CONTAINER_CPUS` and/or `CONTAINER_MEMORY`
3. Run `dc rebuild <name>`

Resource limits are applied at container creation time. Changes to the config file take effect only after `dc rebuild` — `dc start` simply starts the existing container with its existing limits.

Config keys:

- `CONTAINER_CPUS` — number of CPUs (e.g. `2`, `1.5`). Empty = backend default.
- `CONTAINER_MEMORY` — memory limit with suffix (e.g. `4g`, `512m`). Empty = backend default.

All backends use the same flag syntax (`--cpus`, `--memory`). No backend-specific configuration is needed.

## Monorepo and multi-repo patterns

Monorepo:

- One container, one workspace tree (example: ${DC_REPOS_DIR:-$HOME/repos}/myapp-monorepo)
- Can combine runtimes with dc new ... nodejs,golang ...

Multi-repo with separate trust boundaries:

- Separate containers (frontend/backend) with separate credentials

Single-container multi-repo workspace:

- Put all repos under one host folder for that container
- Example: ${DC_REPOS_DIR:-$HOME/repos}/project-fe/frontend-app, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/shared-ui, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/api-client
- All appear in container under /workspace

## VS Code behavior by backend

docker/orbstack/colima/podman backends:

- dc new generates ${DC_REPOS_DIR:-$HOME/repos}/<project>/.devcontainer/devcontainer.json
- For multi-runtime and/or overlay projects, it points to a generated composed Containerfile
- Existing devcontainer.json is not overwritten
- To attach VS Code to the exact same running container as dc shell, use: Dev Containers: Attach to Running Container... and choose <project>
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
dc rebuild myapp-monorepo
```

For apple backend, use normal local folder + generated terminal profile instead of Dev Containers extension.

## Rebuild and incident recovery

Rebuild container:

```
dc rebuild myapp-monorepo
```

Rebuild and rotate SSH key:

```
dc rebuild myapp-monorepo --rotate-keys
```

## Rebuilding after Containerfile changes

If you change `Containerfile.base`, the image must be rebuilt before `dc rebuild` will pick up the update:

```
dc rebuild-image base
dc rebuild myapp-monorepo
```

If you change `Containerfile.nodejs` or `Containerfile.golang`, rebuild the runtime image and then recreate the container:

```
dc rebuild-image nodejs   # or: dc rebuild-image golang
dc rebuild myapp-monorepo
```

If your project uses overlay Containerfiles, update the overlay file and run:

```
dc rebuild myapp-monorepo
```

`dc rebuild` recomposes and rebuilds project-scoped overlay images before recreating the container.

If you changed multiple Containerfiles and want everything refreshed:

```
dc rebuild-image all
dc rebuild myapp-monorepo
```

Notes:

- `dc rebuild-image` is backend-agnostic (apple/colima/docker/orbstack/podman via `CONTAINER_BACKEND` detection/override).
- It rebuilds shared base/runtime images and legacy shared combined runtime images.
- Project-scoped overlay images are rebuilt by `dc rebuild <project>` so each project uses current overlay files.

## Cleaning old dev-container images

To remove old tags from managed dev-container images while preserving each `<repo>:latest`:

```
dc clean
```

Preview only:

```
dc clean --dry-run
```

Safety and scope:

- `dc clean` is backend-agnostic and uses the active backend (apple/colima/docker/orbstack/podman).
- It only targets managed image repositories that match the dev-container naming pattern (`dev-*`) discovered from built-ins and `~/.config/dev-containers/*/config`.
- It preserves all `:latest` tags and removes only other tags for those managed repos.
- It does not remove unrelated images (for example VS Code `vsc-*` images).
- If an old tag is still referenced by a container, it is skipped (no force delete).

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
- Runtime guarantees (Node/Go/etc.) → runtime Containerfiles (`Containerfile.nodejs`, `Containerfile.golang`, ...)
- Preferred day-to-day tools → user overlay Containerfile(s) layered during `dc new`/`dc rebuild`
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
- run dc rebuild <name>

SSH auth issues:

- verify ~/.config/dev-containers/<name>/ssh_key and github-token
- restart with dc start or recreate with dc rebuild

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
