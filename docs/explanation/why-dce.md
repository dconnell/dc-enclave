# Why DC Enclave

## Why a container boundary

Every developer now runs tools that touch their whole repo — AI agents in VS Code extensions, TUI runners like Claude Code, OpenCode, or Pi launched from the terminal, build scripts, dependency installers. Left on the host, each one can read your global credentials, mutate files outside the project, and leave state that survives the session. DC Enclave puts a hard boundary around all of it: the container is the boundary, and anything you run inside it stays inside.

- **Whatever runs in the container, stays in the container.** Launch a TUI agent from `dce shell`, or run a VS Code extension from the integrated terminal — both operate inside the same boundary. Your project repo is bind-mounted read-write at `/workspace` (so editors and builds can read and write it), but everything outside that mount — home directory, shell history, and global credentials — stays out of reach. One exception: when VS Code is *attached* to the container, a workspace extension inside it can open a terminal on your host and run commands — stock VS Code allows this, [VSCodium blocks it by default](https://github.com/VSCodium/vscodium/pull/2487) ([discussion](https://github.com/VSCodium/vscodium/issues/2480)). See [isolation and security](isolation-and-security.md#vs-code-remote-development-can-reach-your-host).
- **Each project is its own trust zone.** A container for project A holds only what you've put in it; project B is invisible to it. Link them only when you mean to.
- **A bad session is one command to undo.** `dce rebuild-container <name>` destroys the container filesystem and recreates it from a known-good image. No snapshots to manage, no manual cleanup, no digging through `git reflog`.
- **Trust is pinned, not learned on first use.** GitHub's SSH host keys are baked into the base image and verified by a guard test, so a hijacked network can't silently redirect git traffic.
- **Your checkout survives every rebuild.** Your repo lives on the host and bind-mounts in read-write; destroying the container leaves your checkout exactly where it was. The opt-in [`--sync`](../how-to/sync-workspace.md) workspace keeps this property: the host stays canonical, and a flush drains pending changes before destroy — even though the in-container source then lives in a synced volume.

The container is the undo button. Rebuild it and you're back to a known-good state in under a minute.


## Versus raw Docker, Podman, or apple/container

If you already know your way around Docker, Podman, or apple/container, `dce` still earns its keep. It orchestrates the repetitive setup and recovery steps you'd otherwise retype per project, and keeps them consistent across machines and backends.

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

