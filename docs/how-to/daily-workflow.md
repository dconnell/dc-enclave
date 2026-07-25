# Daily workflow

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

> **Attach, don't reopen.** `dce new` created and started your container — that's the one `dce shell` and `dce editor` use. To edit inside it, run `dce editor <project>` (or **Dev Containers: Attach to Running Container...**). **Reopen in Container** (the popup shown when you open the folder) instead builds a *separate* editor container (`vsc-*`) that `dce` does not manage. See [VS Code behavior](../reference/backends.md#vs-code-behavior-by-backend) for the full picture.

1. Launch your editor attached to the running container:

   ```
   dce editor myapp-monorepo
   ```

   `dce editor` is the CLI shortcut for *Dev Containers: Attach to Running Container...*. It starts the container if needed, then launches VS Code (by default) attached to `/workspace`. Under PAT auth it also syncs VS Code's attached-container named config so editor/terminal Git uses the container's PAT-backed `~/.git-credentials` rather than VS Code's host-credential forwarding helper. If you changed the token file on the host, run `dce rotate-token <project>` to push the new PAT into the running container. Use `--editor vscode-insiders` for Insiders, or set `DCE_EDITOR` / `$VISUAL` / `$EDITOR`. Run `dce help editor` for the full precedence and discovery rules.

   Manual fallback (same effect): Command Palette → **Dev Containers: Attach to Running Container...** → pick your project.

2. Use integrated terminals and editor as usual
3. Use dce commands for lifecycle/recovery:

```
dce status
dce rebuild-container myapp-monorepo
```

For apple backend, `dce editor` launches VS Code via the experimental apple-container attach path: enable **Dev Containers: Experimental: Apple Container Support** (`dev.containers.experimentalAppleContainerSupport`) in VS Code settings first, or the attach will not resolve. The `dce new`-seeded `.vscode/settings.json` terminal profile is also available as an alternative workflow (open the host repo folder; terminals route through `dce shell`).
