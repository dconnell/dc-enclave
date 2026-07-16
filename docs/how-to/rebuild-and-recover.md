# Rebuild and recover

> **Always rebuild with `dce`, never VS Code's *Rebuild Container*** (or *Reopen in Container*). `dce rebuild-container` / `dce rebuild-image` are the only rebuild paths that re-inject your per-project credentials — SSH deploy key, git-host token auth (`~/.git-credentials` + the `insteadOf` rewrite), and the read-only `.npmrc` bind — and re-establish hidden volumes. A VS Code-initiated rebuild creates a container `dce` does not manage and **skips all of it**: `git pull`, private-package installs, and SSH auth will silently fail inside that container. To edit in VS Code, attach to the running `dce` container instead (*Dev Containers: Attach to Running Container...*). See [VS Code behavior](../reference/backends.md#vs-code-behavior-by-backend).

## Rebuild and incident recovery

Rebuild container (hidden volumes removed by default for a clean slate):

```
dce rebuild-container myapp-monorepo
```

Rebuild and rotate SSH key:

```
dce rebuild-container myapp-monorepo --rotate-keys
```

Rebuild while preserving hidden volumes (skip dependency re-install):

```
dce rebuild-container myapp-monorepo --keep-hidden-volumes
```

Rebuild without prompting (scripted incident response / automation):

```
dce rebuild-container myapp-monorepo --yes
```

For incident recovery (e.g. suspected supply-chain compromise), always rebuild **without** `--keep-hidden-volumes` so hidden volumes like `node_modules` and build caches are destroyed and reinstalled from scratch. When the project has hidden paths configured, combining `--rotate-keys` with `--keep-hidden-volumes` triggers a loud warning (key rotation implies incident response, where preserving volumes may be unsafe).

### Synced workspaces (`--sync`)

For a project created with [`--sync`](sync-workspace.md), rebuild keeps the
data-loss-free property by design:

- The sync volume (`dce-sync-<slug>-<12hex>`) is **always preserved** across rebuild
  (never in the clean-slate removal path) — there is no `--keep-*` flag for it,
  and destroying it would force a multi-minute full re-sync.
- A `mutagen sync flush` drains pending container→host changes **before** the
  container is destroyed, so no edit is lost to sync lag.
- Incident-response clean-slate still applies to `--sync-ignore` dirs (e.g.
  `node_modules`): wipe them in-container (`rm -rf node_modules`) and the
  install-on-start hook repopulates them.

```
dce rebuild-container myapp --sync                          # no-op if already synced
dce rebuild-container myapp --sync --sync-ignore node_modules,dist   # refresh ignore set
```

On Docker-compatible backends, rebuild preserves any existing
`.devcontainer/devcontainer.json` (never overwritten). If managed fields in that
file drift from current config (scopes/hide/networks/ports), rebuild prints a
non-fatal notice; reconcile on demand with:

```
dce config sync-vscode <name>
dce config sync-vscode <name> --dry-run
```


## Rotate credentials

Three distinct operations cover credential changes; pick by what changed:

- **You edited the host git token** (`~/.config/dce-enclave/<name>/<host>-token`) and
  want the running container to use it, without losing container state (packages,
  caches, running processes):

  ```
  dce rotate-token myapp-monorepo
  ```

  This force-pushes the current PAT into the container's `~/.git-credentials`
  (overwriting a stale value; a no-op when it already matches) and re-wires git
  auth. It is state-preserving — no rebuild. Verify with `dce doctor <name>`,
  which reports token drift non-destructively.

- **You need a fresh SSH deploy key** (suspected key compromise): regenerate it as
  part of a rebuild:

  ```
  dce rebuild-container myapp-monorepo --rotate-keys
  ```

  The old key is backed up and the new `.pub` is printed for you to add to your
  git host. This is rebuild-bound (the container is destroyed and recreated) and
  injects the new key plus the current token.

- **You restored a snapshot and want to use it** (`--from-snap`): a bare restore
  does **not** inject credentials, so a possibly-suspect snapshot's credential
  state is preserved for inspection. To use the restored snapshot with your
  current credentials:

  ```
  dce rebuild-container myapp-monorepo --from-snap <label> --inject-creds
  ```

  `--inject-creds` force-injects the current SSH key and git token, overwriting
  any credentials baked into the snapshot. (`--rotate-keys` also injects, after
  regenerating the SSH key.)

Under `ssh`/`none` auth there is no PAT, so `dce rotate-token` is a no-op; SSH
deploy-key rotation remains `--rotate-keys`.


## Rebuilding after Containerfile changes

If you change `Containerfile.base`, rebuild managed images first, then recreate containers:

```
dce rebuild-image all
dce rebuild-container myapp-monorepo
```

If you change overlay Containerfiles, rebuild managed images then recreate containers:

```
dce rebuild-image all
dce rebuild-container myapp-monorepo
```

`dce rebuild-image all` rebuilds the shared base image and all derived images selected by configured project scopes.

`dce rebuild-container` re-derives the image for that project and recreates only the container.

If you changed multiple Containerfiles and want everything refreshed:

```
dce rebuild-image all
dce rebuild-container myapp-monorepo
```

Notes:

- `dce rebuild-image` is backend-agnostic (apple/colima/docker/orbstack/podman via `CONTAINER_BACKEND` detection/override).
- `dce rebuild-image all` rebuilds `dce-base` and all configured derived images.
- `dce rebuild-container <project>` never rebuilds images. If the required image is missing, it fails and instructs you to run `dce rebuild-image all`.


## Cleaning old DC Enclave images

To clean managed DC Enclave images:

```
dce clean
```

Preview only:

```
dce clean --dry-run
```

Safety and cleanup scope:

- `dce clean` is backend-agnostic and uses the active backend (apple/colima/docker/orbstack/podman).
- It targets managed image repositories (`dce-base` and `dce-img-<hash>`) discovered from current project configs and backend image state.
- For expected managed repos, it preserves `:latest` and removes non-latest tags.
- For orphan managed repos, it removes all tags (including `:latest`).
- It does not remove unrelated images (for example VS Code `vsc-*` images).
- If a tag is still referenced by a container, removal may fail and is reported (no force delete).


## Removing a project

`dce rm` removes a dev container project outright. By default it performs a full teardown:

1. stops the container if it is running, then deletes it
2. removes every managed hidden volume (`dce-hide-<project>-<hash>`); for synced projects, terminates the Mutagen session and removes the sync volume (`dce-sync-<slug>-<12hex>`)
3. removes the per-project config + secrets directory (`~/.config/dce-enclave/<name>`), including the SSH key, GitHub token, and `.npmrc`

```
dce rm myapp                       # remove everything (prompts to confirm)
dce rm myapp --yes                 # remove everything without prompting
dce rm myapp --keep-config         # remove container + volumes, keep config/secrets
dce rm myapp --keep-volumes        # remove container + config/secrets, keep volumes
```

Safety notes:

- **Your host code is never touched.** The repo directory at `${DC_REPOS_DIR:-$HOME/repos}/<name>` (including the generated `.devcontainer/devcontainer.json`) is preserved. Remove it manually if it is no longer needed:
  ```
  rm -rf "${DC_REPOS_DIR:-$HOME/repos}/myapp"
  ```
- `dce rm` is destructive and prompts for confirmation (type `yes`) unless `--yes`/`-y` is given.
- The project name is validated and the secrets directory's real path is checked to reside under the DC Enclave config root, so a symlinked project directory cannot redirect deletion elsewhere.
- If the backend is unreachable, container/volume removal is skipped with a warning, but the config + secrets are still removed (unless `--keep-config`).
- To wipe only the container filesystem while keeping config and code, use `dce rebuild-container <name>` instead.
