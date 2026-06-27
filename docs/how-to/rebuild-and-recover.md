# Rebuild and recover

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

On Docker-compatible backends, rebuild preserves any existing
`.devcontainer/devcontainer.json` (never overwritten). If managed fields in that
file drift from current config (scopes/hide/networks/ports), rebuild prints a
non-fatal notice; reconcile on demand with:

```
dce config sync-vscode <name>
dce config sync-vscode <name> --dry-run
```


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
2. removes every managed hidden volume (`dce-hide-<project>-<hash>`)
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
