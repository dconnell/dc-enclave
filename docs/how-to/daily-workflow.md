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

> **Attach, don't reopen.** `dce new` created and started your container — that is the container `dce shell` uses. To edit inside it, use **Dev Containers: Attach to Running Container...** and pick the project. **Reopen in Container** (the popup shown when you open the folder) instead builds a *separate* editor container (`vsc-*`) that `dce` does not manage and that won't share runtime state with `dce shell`. See [VS Code behavior](../reference/backends.md#vs-code-behavior-by-backend).

1. Attach VS Code to the running container:
   Command Palette → **Dev Containers: Attach to Running Container...** → pick your project

2. Use integrated terminals and editor as usual
3. Use dce commands for lifecycle/recovery:

```
dce status
dce rebuild-container myapp-monorepo
```

For apple backend, use normal local folder + generated terminal profile instead of Dev Containers extension.

