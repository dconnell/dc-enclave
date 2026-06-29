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

> **Attach, don't reopen.** `dce new` created and started your container — that is the container `dce shell` and `dce editor` use. To edit inside it, run `dce editor <project>` (or manually use **Dev Containers: Attach to Running Container...**). **Reopen in Container** (the popup shown when you open the folder) instead builds a *separate* editor container (`vsc-*`) that `dce` does not manage and that won't share runtime state with `dce shell`. See [VS Code behavior](../reference/backends.md#vs-code-behavior-by-backend).

1. Launch your editor attached to the running container:

   ```
   dce editor myapp-monorepo
   ```

   `dce editor` is the CLI shortcut for *Dev Containers: Attach to Running Container...*. It starts the container if needed, then launches VS Code (by default) attached to `/workspace`. Use `--editor vscode-insiders` for Insiders, or set `DCE_EDITOR` / `$VISUAL` / `$EDITOR`. Run `dce help editor` for the full precedence and discovery rules.

   Manual fallback (same effect): Command Palette → **Dev Containers: Attach to Running Container...** → pick your project.

2. Use integrated terminals and editor as usual
3. Use dce commands for lifecycle/recovery:

```
dce status
dce rebuild-container myapp-monorepo
```

For apple backend, `dce editor` refuses (apple/container is not Docker-API compatible, so the Dev Containers extension cannot attach). Open the host repo folder with your editor directly; the `dce new`-seeded `.vscode/settings.json` terminal profile still routes shell tabs through `dce shell`.

