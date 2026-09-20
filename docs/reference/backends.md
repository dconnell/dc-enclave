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


### Platform-specific notes

For per-platform install commands (Docker Desktop, OrbStack, Colima on macOS/Linux, Podman on macOS/Linux/WSL2, WSL2 buildx plugin), see [install a container backend](../how-to/install-backends.md).


## VS Code behavior by backend

docker/orbstack/colima/podman backends:

> **Use "Attach to Running Container", not "Reopen in Container".**
>
> `dce new` creates and starts your container (`dce-<name>`); that is the container `dce shell` uses. **Dev Containers: Attach to Running Container...** attaches VS Code to that exact container.
>
> **Dev Containers: Reopen in Container** — and the popup shown when you open the folder — instead builds a *separate* editor container (`vsc-*`) that `dce` does not manage. It shares no runtime state with `dce shell`. A stray `vsc-*` container means you took the Reopen path.
>
> When you need a fresh filesystem, run **`dce rebuild-container`**, not VS Code's *Rebuild Container*: only the dce path re-injects your SSH deploy key, GitHub PAT git auth, and `.npmrc` (see [rebuild and recover](../how-to/rebuild-and-recover.md)).

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
- `dce editor <name>` is the CLI shortcut for **Dev Containers: Attach to Running Container...**: it starts the container if needed, launches VS Code attached to `/workspace`, and syncs the attached-container named config's managed fields.
- Under PAT auth that named config carries a Git `remoteEnv` override (`credential.helper = ""`, then `store`), so attached terminals/UI use the container's PAT-backed `~/.git-credentials` instead of VS Code's host-credential forwarding helper.
- Use `--editor vscode-insiders` for Insiders, or set `DCE_EDITOR` / `$VISUAL` / `$EDITOR`. Run `dce help editor` for full precedence and discovery rules.
- Runtime extension drift is surfaced via `dce doctor <project>` (informational),
  `dce extensions diff <project>` (focused), and a pre-destroy warning from
  `dce rebuild-container` when undeclared installed extensions would be lost.
- If the host PAT has changed since the container last saw it, `dce editor` preserves the existing container token (same only-if-missing policy as `dce shell` / `dce start`) and warns; run `dce rotate-token <name>` to push the current PAT into the running container.

### Host hardening against remote-dev RCE

When VS Code is attached, a workspace extension in the container can open a terminal on your host and run commands in it (see [Isolation and security](../explanation/isolation-and-security.md#vs-code-remote-development-can-reach-your-host)). There's no container-side fix — it's a property of the host VS Code client. **[VSCodium](https://github.com/VSCodium/vscodium/pull/2487)** blocks the command by default ([discussion](https://github.com/VSCodium/vscodium/issues/2480)); **stock VS Code** does not, and exposes your host whenever you attach to a container running untrusted code. Choose VSCodium, or accept the exposure.

apple backend:

> **Experimental VS Code Dev Containers support.** VS Code Dev Containers can attach to apple/container behind the `dev.containers.experimentalAppleContainerSupport` setting (macOS only; requires the `container` CLI). It is upstream-experimental and may be rougher than the Docker backends — dce wires it up but does not guarantee parity.

> **Container DNS.** apple/container's auto-configured resolver (the vmnet gateway, e.g. `192.168.64.1`) does not forward external DNS. By default a container can reach IPs but not resolve hostnames, which breaks extension install, `git clone` over https, `npm install`, etc.
>
> dce works around this by passing `--dns 1.1.1.1 --dns 8.8.8.8` at `container create` time for apple projects. Override with the `DCE_DNS` env var (comma-separated IPs; set it empty to opt out). This only takes effect on a fresh `dce new` / `dce rebuild-container` (DNS is set at create time).
>
> **VPN caveat.** When a host VPN is active, apple/container's vmnet NAT may not route through the VPN interface, leaving the container with no network at all (not just no DNS). This is an apple/container networking limitation; dce cannot reconfigure host routing. Disconnect the VPN, or investigate a user-defined network (`container create --network <name>[,mac=…][,mtu=…]`) that routes differently.

- `dce new` generates `${DC_REPOS_DIR:-$HOME/repos}/<project>/.devcontainer/devcontainer.json` (the same Dev Containers config as the Docker backends) plus the VS Code attached-container **named** config (`workspaceFolder=/workspace`)
- `dce new` also seeds a `.vscode/settings.json` terminal profile that routes VS Code terminals through `dce shell` (an alternative workflow for when you open the host folder instead of attaching)
- `dce editor <name>` launches VS Code attached to the apple container at `/workspace` via the experimental `apple-container` URI; enable `dev.containers.experimentalAppleContainerSupport` in VS Code first or the attach will not resolve
- Existing files are not overwritten; `dce config sync-vscode <name>` rewrites managed fields on demand

VS Code is optional. Alias-based shell workflow is always supported.
