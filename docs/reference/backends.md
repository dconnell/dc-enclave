# Backends

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

### Synced workspace (`--sync`) support

[`--sync`](../how-to/sync-workspace.md) replaces the `/workspace` bind mount with
a Mutagen-synced named volume for native-ext4 speed on large repos. It is
supported on the docker-family backends (docker/orbstack/colima) and
**unsupported on apple/container and podman**:

| Backend | `--sync` | Mutagen transport |
| --- | --- | --- |
| docker | yes | docker |
| orbstack | yes | docker |
| colima | yes | docker |
| podman | **no** — fails fast. Mutagen has no podman transport, and the docker-transport bridge to a podman-machine VM is blocked by SSH host-key verification (the socket lives inside the VM). Use [`--hide`](../how-to/hide-generated-paths.md), or docker/orbstack/colima for `--sync`. | — |
| apple | **no** — fails fast (use [`--hide`](../how-to/hide-generated-paths.md)) | — |

On a native Linux host with no VM, bind mounts are already native-speed, so
`--sync` there is pure overhead — it is a VM-backend feature.


### Platform-specific notes

**macOS + Colima**: Install with `brew install colima docker`, then run `colima start --runtime docker`. Colima usually auto-activates its Docker context; if needed, run `docker context use colima`.

**Linux + Colima**: Install Colima and Docker CLI, then run `colima start --runtime docker`. Ensure virtualization support is available (for example KVM access where required by your distro setup).

**macOS + Podman**: Podman runs in a VM on macOS. Run `podman machine start` before using DC Enclave, or let `setup.sh` start it for you.

**Linux + Podman**: Podman runs rootless with no daemon. Works out of the box on most distros (`apt install podman`, `dnf install podman`).

**WSL2**: Docker Desktop's WSL2 integration makes `docker` available inside WSL2. Podman can be installed natively inside WSL2 (`apt install podman`). For best bind-mount performance, keep repos inside the WSL2 filesystem (`${DC_REPOS_DIR:-$HOME/repos}/`) rather than on the Windows mount (`/mnt/c/`).


## VS Code behavior by backend

docker/orbstack/colima/podman backends:

> **Use "Attach to Running Container", not "Reopen in Container".** `dce new` creates and starts your container (`dce-<name>`); that is the container `dce shell` uses. **Dev Containers: Attach to Running Container...** attaches VS Code to that exact container. **Dev Containers: Reopen in Container** — and the popup shown when you open the folder — instead builds a *separate* editor container (`vsc-*`) that `dce` does not manage and that will not share runtime state with `dce shell`. A stray `vsc-*` container is the sign you took the Reopen path. Likewise, when you need a fresh filesystem, run **`dce rebuild-container`** — not VS Code's *Rebuild Container* — since only the dce path re-injects your SSH deploy key, GitHub PAT git auth, and `.npmrc` (see [rebuild and recover](../how-to/rebuild-and-recover.md)).

- `dce new` generates `${DC_REPOS_DIR:-$HOME/repos}/<project>/.devcontainer/devcontainer.json`
- For multi-scope and/or overlay projects, it points to a generated composed Containerfile
- Existing `devcontainer.json` is not overwritten
- `dce new` / `dce rebuild-container` detect drift in managed fields
  (scopes/hidden-paths/networks/ports/extensions) and print a one-line notice with the
  diff when an existing file diverges
- `dce config sync-vscode <name>` rewrites those managed fields on demand
  (use `--dry-run` to preview); user fields are preserved
- When a GitHub PAT is configured, the generated `devcontainer.json` also sets
  `customizations.vscode.settings."github.gitAuthentication": false` so VS Code's
  Source Control panel (pull/push/sync) uses the PAT in `~/.git-credentials`
  instead of prompting via the GitHub extension's OAuth flow. (GitLab has no
  equivalent VS Code conflict, so no setting is emitted for it.) The setting is
  omitted for ssh/none auth; run `dce config sync-vscode <name>` after filling
  in the token to update an existing file.
- `dce new` and `dce rebuild-container` also seed VS Code attached-container **named** config (`workspaceFolder=/workspace`) for that container name, so attach behavior stays consistent across image rebuilds/re-tags (existing named config is preserved)
- `dce editor <name>` is the CLI shortcut for **Dev Containers: Attach to Running Container...**: it starts the container if needed, launches VS Code attached to `/workspace`, and syncs the attached-container named config's managed fields. Under PAT auth that named config carries a Git `remoteEnv` override (`credential.helper = ""`, then `store`) so attached terminals/UI use the container's PAT-backed `~/.git-credentials` instead of VS Code's host-credential forwarding helper. Use `--editor vscode-insiders` for Insiders, or set `DCE_EDITOR` / `$VISUAL` / `$EDITOR`. Run `dce help editor` for full precedence and discovery rules.
- Runtime extension drift is surfaced via `dce doctor <project>` (informational),
  `dce extensions diff <project>` (focused), and a pre-destroy warning from
  `dce rebuild-container` when undeclared installed extensions would be lost.
- If the host PAT has changed since the container last saw it, `dce editor` preserves the existing container token (same only-if-missing policy as `dce shell` / `dce start`) and warns; run `dce rotate-token <name>` to push the current PAT into the running container.

### Host hardening against remote-dev RCE

When VS Code is attached, a workspace extension in the container can open a terminal on your host and run commands in it (see [Isolation and security](../explanation/isolation-and-security.md#vs-code-remote-development-can-reach-your-host)). There's no container-side fix — it's a property of the host VS Code client. **[VSCodium](https://github.com/VSCodium/vscodium/pull/2487)** blocks the command by default ([discussion](https://github.com/VSCodium/vscodium/issues/2480)); **stock VS Code** does not, and exposes your host whenever you attach to a container running untrusted code. Choose VSCodium, or accept the exposure.

apple backend:

- dce new generates ${DC_REPOS_DIR:-$HOME/repos}/<project>/.vscode/settings.json
- Integrated terminal profile routes through dce shell
- Existing settings.json is not overwritten
- `dce editor` **refuses** on apple: apple/container is not Docker-API compatible, so the VS Code Dev Containers extension cannot attach. Open the host repo folder with your editor directly; the seeded terminal profile still routes shell tabs through `dce shell`.

VS Code is optional. Alias-based shell workflow is always supported.
