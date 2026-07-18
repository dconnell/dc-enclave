# DC Enclave

A thin wrapper of readable Bash 4+ scripts that turns any container runtime into a one-command isolated dev environment. Spin one up, shell in from the terminal or open it in VS Code, and run your code and AI agents inside a sandbox you can wipe and rebuild in seconds.

You bring the runtime — apple/container, Docker Desktop, OrbStack, Colima, or Podman, on macOS, Linux\*, and WSL2\*. DC Enclave handles bootstrap, per-project credentials, rebuilds, and recovery with the same `dce` commands everywhere.

> **\* Platform support:** I develop and manually test on macOS. Linux and WSL2 are covered by the integration suite in CI (Ubuntu 24.04 and Windows/WSL2 runners, against real Docker, Podman, and Colima backends). If you hit something on Linux or Windows that looks platform-specific, please open an issue.

## Why

Every developer now runs tools that execute code on their machine — AI agents in VS Code extensions, TUI runners like Claude Code, OpenCode, or Pi launched from the terminal, build scripts, and dependency installers whose post-install hooks can run more or less anything. On the host, that code runs with your user privileges: it can read your global credentials, write outside the project, and leave state that survives the session. The container is the boundary; DC Enclave is the one-command, backend-agnostic way to spin it up — and to throw it away and rebuild safely when something goes wrong.

- **Whatever runs in the container, stays in the container.** Processes and state you create inside run only there. Your project repo is bind-mounted read-write at `/workspace` (so your editor and builds can read and write it), but everything outside that mount — your home directory, shell history, and global credentials — stays out of reach.
- **Each project is its own trust zone.** A container for project A holds only what you've put in it; project B is invisible to it.
- **A bad session is one command to undo.** `dce rebuild-container <name>` destroys the container filesystem and recreates it from a known-good image — and `dce snapshot <name>` / `dce rebuild-container <name> --from-snap <label>` give you a rollback point first.
- **Your checkout survives every rebuild.** Your repo lives on the host and bind-mounts in read-write; destroying or rebuilding the container leaves your checkout exactly where it was. The opt-in [`--sync`](docs/how-to/sync-workspace.md) workspace (for large repos where the bind mount is too slow on macOS/WSL2) preserves this by design — host stays canonical.

For the full rationale and a comparison against raw Docker/Podman, see [why DC Enclave](docs/explanation/why-dce.md).

## Quick start

```bash
# one-time: clone the repo, build the base image, and wire up the `dce` command
git clone https://github.com/dconnell/dc-enclave.git ~/dc-enclave
cd ~/dc-enclave
scripts/setup.sh

# create an isolated container for a repo
dce new myapp nodejs 3000:3000

# shell in from the terminal
dce shell myapp

# or open your editor attached to the running container (VS Code by default)
dce editor myapp

# manual VS Code path: Dev Containers: Attach to Running Container... and pick `myapp`
#   (do not use "Reopen in Container" — it builds a SEPARATE editor container; see note below)
```

> **BuildKit requirement.** dce builds images with BuildKit, so the `buildx`
> plugin must be present (`docker buildx version`). It ships with Docker Desktop
> and Docker CE. If you install Docker via Ubuntu's `docker.io` package on
> WSL2/Ubuntu, install `buildx` separately
> (`sudo apt-get install docker-buildx-plugin` from Docker's apt repo, or
> download from <https://github.com/docker/buildx/releases>). `scripts/setup.sh`
> verifies this and prints the fix if it's missing.

You now have a container named `myapp` running your chosen toolchain, your repo bind-mounted at `/workspace`, your per-project credentials injected, and a generated `devcontainer.json` so VS Code can open the project.

> **VS Code — attach, don't reopen.**
> 
> `dce new` already created and started your `myapp` container — that's the container `dce shell` and `dce editor` use.
> 
> - **To edit inside it:** Run `dce editor myapp` (or manually **Dev Containers: Attach to Running Container...** and pick `myapp`)
> - **Do not use Reopen in Container** (the popup shown when you open the folder) — it builds a *separate* editor container (`vsc-*`) that `dce` does not manage, won't share runtime state with `dce shell`, and bypasses dce's credential injection
> 
> For the full picture, see [VS Code behavior](docs/reference/backends.md#vs-code-behavior-by-backend) and [rebuild and recover](docs/how-to/rebuild-and-recover.md).

The generated `devcontainer.json` follows the [dev container spec](https://containers.dev), so other spec-compliant clients (Codespaces, etc.) can attach too — only VS Code Dev Containers is tested.

`dce new` also generates a per-project SSH keypair and creates placeholder files for a git-host token (GitHub PAT by default; use `--git-host gitlab` for GitLab) and `.npmrc` under `~/.config/dce-enclave/<name>/`. Completing them is optional hardening — see [isolation and security](docs/explanation/isolation-and-security.md).

## Documentation

The full manual lives in [`docs/`](docs/README.md). Common destinations:

| I want to… | Go to |
|---|---|
| Install `dce` and create my first container | [getting started](docs/tutorials/getting-started.md) |
| See the day-to-day command loop | [daily workflow](docs/how-to/daily-workflow.md) |
| See every command and flag | [command reference](docs/reference/commands.md) · [flags](docs/reference/flags.md) |
| Change CPU / memory or timezone | [manage resources](docs/how-to/manage-resources.md) · [timezone](docs/how-to/set-timezone.md) |
| Get a large repo performing well in a VM | [sync workspace](docs/how-to/sync-workspace.md) (`--sync`) |
| Rebuild / recover from a bad state | [rebuild and recover](docs/how-to/rebuild-and-recover.md) |
| Save a container state and roll back | [snapshot and rollback](docs/how-to/snapshot-and-rollback.md) |
| Understand the security model | [isolation and security](docs/explanation/isolation-and-security.md) |
| Fix something | [troubleshooting](docs/troubleshooting.md) |

For the full list of how-to guides, reference docs, and design notes, see [docs/README.md](docs/README.md).
