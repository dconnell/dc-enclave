# DC Enclave

A thin wrapper of readable Bash 4+ scripts that turns any container runtime into a one-command isolated dev environment. Spin one up, shell in from the terminal or open it in VS Code, and run your code and AI agents inside a sandbox you can wipe and rebuild in seconds.

You bring the runtime — apple/container, Docker Desktop, OrbStack, Colima, or Podman, on macOS, Linux\*, and WSL2\*. DC Enclave handles bootstrap, per-project credentials, rebuilds, and recovery with the same `dce` commands everywhere.

> **\* Platform support:** Only macOS has been tested so far. Linux validation is planned soon. WSL2 is currently untested and there is no Windows environment on hand to verify it; feedback from anyone running DC Enclave on either platform would be especially welcome.

## Why

Every developer now runs tools that execute code on their machine — AI agents in VS Code extensions, TUI runners like Claude Code, OpenCode, or Pi launched from the terminal, build scripts, and dependency installers whose post-install hooks can run more or less anything. On the host, that code runs with your user privileges: it can read your global credentials, write outside the project, and leave state that survives the session. The container is the boundary; DC Enclave is the one-command, backend-agnostic way to spin it up — and to throw it away and rebuild safely when something goes wrong.

- **Whatever runs in the container, stays in the container.** Processes and state you create inside run only there. Your project repo is bind-mounted read-write at `/workspace` (so your editor and builds can read and write it), but everything outside that mount — your home directory, shell history, and global credentials — stays out of reach.
- **Each project is its own trust zone.** A container for project A holds only what you've put in it; project B is invisible to it.
- **A bad session is one command to undo.** `dce rebuild-container <name>` destroys the container filesystem and recreates it from a known-good image — and `dce snapshot <name>` / `dce rebuild-container <name> --from-snap <label>` give you a rollback point first.
- **Your checkout survives every rebuild.** Your repo lives on the host and bind-mounts in read-write; destroying or rebuilding the container leaves your checkout exactly where it was. The opt-in [`--sync`](docs/how-to/sync-workspace.md) workspace (for large repos where the bind mount is too slow on macOS/WSL2) preserves this by design — host stays canonical.

For the full rationale and a comparison against raw Docker/Podman, see [why DC Enclave](docs/explanation/why-dce.md).

## Quick start

```bash
# one-time: build the base image and wire up the `dce` command
scripts/setup.sh

# create an isolated container for a repo
dce new myapp nodejs 3000:3000

# shell in from the terminal
dce shell myapp

# or open your editor attached to the running container (VS Code by default)
dce editor myapp

# manual VS Code path: Dev Containers: Attach to Running Container... and pick `myapp`
#   (avoid "Reopen in Container" — it builds a SEPARATE editor container; see note below)
```

> **BuildKit requirement.** dce builds images with BuildKit, so the `buildx`
> plugin must be present (`docker buildx version`). It ships with Docker Desktop
> and Docker CE; on WSL2/Ubuntu `docker.io` install it separately
> (`sudo apt-get install docker-buildx-plugin` from Docker's apt repo, or
> download from <https://github.com/docker/buildx/releases>). `scripts/setup.sh`
> verifies this and prints the fix if it's missing.

You now have a container named `myapp` running your chosen toolchain, your repo bind-mounted at `/workspace`, your per-project credentials injected, and a generated `devcontainer.json` so VS Code can open the project.

> **VS Code — attach, don't reopen.** `dce new` already created and started the `myapp` container; that is the container `dce shell` / `dce editor` use. To edit inside it, run `dce editor myapp` (or manually **Dev Containers: Attach to Running Container...** and pick `myapp`). Do **not** use **Reopen in Container** (the popup shown when you open the folder) — it builds a *separate* editor container (`vsc-*`) that `dce` does not manage and that will not share runtime state with `dce shell`. When you need a fresh filesystem, rebuild with `dce rebuild-container` — VS Code's *Rebuild Container* bypasses dce's credential injection (SSH key, GitHub PAT git auth, `.npmrc`). For PAT auth, `dce editor` also syncs VS Code's attached-container named config so attached terminals/UI use the container's PAT-backed `~/.git-credentials` instead of VS Code's host-credential forwarding helper. If you edit the token file later, run `dce rotate-token <name>` to push the new PAT into the container. See [VS Code behavior](docs/reference/backends.md#vs-code-behavior-by-backend) and [rebuild and recover](docs/how-to/rebuild-and-recover.md).

The generated `devcontainer.json` follows the [dev container spec](https://containers.dev), so other spec-compliant clients (Codespaces, etc.) can attach too — only VS Code Dev Containers is tested.

`dce new` also generates a per-project SSH keypair and creates placeholder files for a git-host token (GitHub PAT by default; use `--git-host gitlab` for GitLab) and `.npmrc` under `~/.config/dce-enclave/<name>/`. Completing them is optional hardening — see [the isolation model](docs/explanation/isolation-and-security.md).

## Documentation

The full manual lives in [`docs/`](docs/README.md). Common destinations:

| I want to… | Go to |
|---|---|
| Install and create my first container | [getting started](docs/tutorials/getting-started.md) |
| See every command and flag | [command reference](docs/reference/commands.md) · [flags](docs/reference/flags.md) |
| Change CPU/memory or timezone | [manage resources](docs/how-to/manage-resources.md) · [timezone](docs/how-to/set-timezone.md) |
| Make a large repo performant on macOS/WSL2 | [sync workspace](docs/how-to/sync-workspace.md) (`--sync`) |
| Save a container state and roll back | [snapshot & rollback](docs/how-to/snapshot-and-rollback.md) |
| Understand the security model | [isolation & security](docs/explanation/isolation-and-security.md) |
| Fix something | [troubleshooting](docs/troubleshooting.md) |
