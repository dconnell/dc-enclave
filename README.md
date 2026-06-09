# dev-containers

Isolated development containers for macOS with one shared shell-script codebase and three supported backends:

- apple/container
- Docker Desktop
- OrbStack (docker CLI path)

## Isolation design

Each project container is set up with its own credentials and runtime state so projects stay independent:

- Per-project GitHub PAT — store a fine-grained, repo-scoped token (no admin) in `~/.config/dev-containers/<name>/github-token`
- Per-project SSH deploy key — add a dedicated key pair under `~/.config/dev-containers/<name>/`
- Per-project .npmrc — place a Node-specific config alongside the other secrets for Node projects
- Host-mounted workspace — code lives at `~/repos/<project>` on your machine and is bind-mounted to `/workspace` inside the container

If a container's runtime state is ever suspect, `dc rebuild` replaces the container from a known-good image without touching your host repos.

## Command reference

The day-to-day interface is the `dc` command with subcommands:

- dc new <name> <type[,type...]> [host:container ...]: create a new isolated container project
- dc status: show overall status and per-project details
- dc start [name]: start one project or all configured projects
- dc stop [name]: stop one project or all configured projects
- dc shell <name> [command]: open shell or run one command inside project container
- dc rebuild <name> [--rotate-keys]: destroy and recreate container from known-good image
- dc rebuild-image [all|base|nodejs|golang]: rebuild images used by projects
- dc clean [--dry-run]: remove old dev-container image tags while keeping latest
- dc install <name> <path-to-dotfiles>: install or update dotfiles in a running container
- dc help: show usage information

All subcommands dispatch to scripts under `scripts/`.

## Common Unix tools included in base image

The base image now includes common CLI tools used in local shell workflows, including:

- tree
- tmux
- rsync
- ripgrep (rg)
- fzf
- less
- unzip / zip
- lsof
- net-tools
- iproute2
- iputils-ping
- dnsutils
- PostgreSQL client (psql)

The base image also includes a default user shell setup for `dev` with `alias ll='ls -la'`. Personal preferences (editor config, git identity, shell aliases) are managed via per-user dotfiles — see the **Personal configuration (dotfiles)** section below.

You can verify inside a container with:

```
dc shell <name> "tree --version && rg --version && psql --version"
```

## Backend selection

Set CONTAINER_BACKEND to one of:

- apple
- docker
- orbstack

If not set, detection order is:

1. docker context name contains orbstack
2. apple/container CLI available
3. docker CLI available

Selected backend is stored per project in projects/<name>/config.

## Repository layout

```
dev-containers/
├── Containerfiles/
│   ├── Containerfile.base
│   ├── Containerfile.nodejs
│   ├── Containerfile.golang
│   └── generated/                      # auto-generated for multi-runtime images
├── lib/
│   └── container-backend.sh
├── scripts/
│   ├── dc                               # CLI entry point
│   ├── setup.sh
│   ├── new-container.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── shell.sh
│   ├── status.sh
│   ├── rebuild.sh
│   ├── rebuild-image.sh
│   ├── install-dotfiles.sh
│   └── clean.sh
├── templates/
│   └── dotfiles/                       # starter dotfiles repo (fork for personal config)
└── projects/
    └── <name>/config
```

Host-side paths:

- code: ~/repos/<project>
- secrets: ~/.config/dev-containers/<project>
- per-project config: <repo>/projects/<project>/config

## Initial setup

1. Ensure one backend is installed and running:

- apple/container, or
- Docker Desktop, or
- OrbStack

2. Initialize repository and aliases:

```
cd ~/dev-containers
chmod +x scripts/*.sh
scripts/setup.sh
source ~/.zshrc
```

Optional: force backend during setup:

```
CONTAINER_BACKEND=orbstack scripts/setup.sh
```

Optional: pin PostgreSQL client major to match Postgres.app/server major:

```
POSTGRES_CLIENT_MAJOR=17 scripts/setup.sh
```

## Setup of a new repo

Use dc new (alias), not direct script invocation.

Single runtime examples:

```
dc new myapp-frontend nodejs 3000:3000 5173:5173
dc new myapp-backend golang 8080:8080 9000:9000
```

Monorepo with multiple runtimes and multiple ports:

```
dc new myapp-monorepo nodejs,golang 3000:3000 5173:5173 8080:8080 9000:9000
```

What type combinations mean:

- nodejs -> use Node.js runtime image
- golang -> use Go runtime image
- nodejs,golang -> generate and build a combined image from both Containerfiles

After dc new:

1. Edit ~/.config/dev-containers/<name>/github-token
2. Add ~/.config/dev-containers/<name>/ssh_key.pub as GitHub Deploy Key
3. Clone repo(s) into ~/repos/<name>

Port mapping notes:

- Format is host-port:container-port
- Multiple mappings are supported in one dc new command
- Example: 3000:3000 5173:5173 8080:8080

## Monorepo and multi-repo patterns

Monorepo:

- One container, one workspace tree (example: ~/repos/myapp-monorepo)
- Can combine runtimes with dc new ... nodejs,golang ...

Multi-repo with separate trust boundaries:

- Separate containers (frontend/backend) with separate credentials

Single-container multi-repo workspace:

- Put all repos under one host folder for that container
- Example: ~/repos/project-fe/frontend-app, ~/repos/project-fe/shared-ui, ~/repos/project-fe/api-client
- All appear in container under /workspace

## VS Code behavior by backend

docker/orbstack backend:

- dc new generates ~/repos/<project>/.devcontainer/devcontainer.json
- For multi-runtime types, it points to generated combined Containerfile
- Existing devcontainer.json is not overwritten
- To attach VS Code to the exact same running container as dc shell, use: Dev Containers: Attach to Running Container... and choose <project>
- Dev Containers: Reopen in Container may create a separate `vsc-*` container for editor workflows

apple backend:

- dc new generates ~/repos/<project>/.vscode/settings.json
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

For docker/orbstack backends:

1. Open project folder:

```
code ~/repos/myapp-monorepo
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

If you changed multiple Containerfiles and want everything refreshed:

```
dc rebuild-image all
dc rebuild myapp-monorepo
```

Notes:

- `dc rebuild-image` is backend-agnostic (apple/docker/orbstack via `CONTAINER_BACKEND` detection/override).
- For multi-runtime projects (`nodejs,golang`), it also regenerates/rebuilds affected combined images from `projects/*/config` and `Containerfiles/generated`.

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

- `dc clean` is backend-agnostic and uses the active backend (apple/docker/orbstack).
- It only targets managed image repositories that match the dev-container naming pattern (`dev-*`) discovered from built-ins and `projects/*/config`.
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

Copies the dotfiles directory into the running container and executes its `install.sh`. Safe to re-run — idempotent if your install script is. This works with all backends (apple, docker, orbstack) and is the only option for the apple/container backend since it doesn't use the Dev Containers extension.

### What goes where

- Shared tooling (CLI tools, runtimes) → Containerfiles (baked into image)
- Project secrets (PAT, SSH key, .npmrc) → `~/.config/dev-containers/<name>/`
- Personal preferences (git identity, vim, shell) → your dotfiles repo

### Starter dotfiles

See `templates/dotfiles/` in this repo for a ready-to-fork example.

## Troubleshooting

No backend detected:

- install apple/container, Docker Desktop, or OrbStack
- rerun scripts/setup.sh

Need specific backend:

```
CONTAINER_BACKEND=apple scripts/setup.sh
CONTAINER_BACKEND=docker dc new myapp nodejs 3000:3000
```

devcontainer.json or settings.json not overwritten:

- expected behavior to avoid clobbering local config
- update file manually if needed

Changed ports:

- update projects/<name>/config
- run dc rebuild <name>

SSH auth issues:

- verify ~/.config/dev-containers/<name>/ssh_key and github-token
- restart with dc start or recreate with dc rebuild

## Connecting to host PostgreSQL securely

You do not need SSH tunneling for normal local development. A normal connection string is enough.

For docker/orbstack backends, use host.docker.internal as host:

```
postgresql://<user>:<password>@host.docker.internal:5432/<db>
```

For this to work, your PostgreSQL instance must allow it:

- listen on an address reachable from the container runtime
- allow container network clients in pg_hba.conf
- keep auth strict (password/scram), and avoid opening broad CIDRs unnecessarily

If you want version parity with Postgres.app, set POSTGRES_CLIENT_MAJOR during setup as shown above, then verify with:

```
dc shell <name> "psql --version"
```
