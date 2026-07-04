# Manage editor extensions

Declare editor extensions in manifests so every rebuild/open converges to the
same set for a project scope, instead of relying on ad-hoc installs in a running
container.

## Manifest layout

Extension manifests live outside overlays, namespaced by editor and scope:

```
$DC_TEAM_DIR/extensions/vscode/<scope>.txt
$DC_USER_DIR/extensions/vscode/<scope>.txt
```

Format is plain text, one extension ID per line (`publisher.name`). Blank lines
and `#` comments are allowed.

Example (`$DC_USER_DIR/extensions/vscode/nodejs.txt`):

```text
# node projects
dbaeumer.vscode-eslint
esbenp.prettier-vscode
```

Layering follows the same model as overlays:

- `all` (if present) is prepended automatically
- then each effective project scope
- team file before user file per scope
- first occurrence wins (de-duplicated, order-preserving)

## Inspect current state

Show declared set (manifest resolution):

```bash
dce extensions show myapp
dce extensions show myapp --format json
```

List runtime state in the running container:

```bash
dce extensions list myapp
```

List host VS Code extensions:

```bash
dce extensions host
```

Show runtime drift both directions:

```bash
dce extensions diff myapp
```

- installed in container but not declared (`container \ declared`)
- declared but currently not installed (`declared \ container`)

When runtime prerequisites are missing (container stopped, apple backend,
`code` CLI absent in-container), `diff` prints a clean `SKIP` message.

## Capture extensions into manifests

Capture selected IDs into one scope (curated/default flow):

```bash
dce extensions capture myapp --scope nodejs esbenp.prettier-vscode dbaeumer.vscode-eslint
```

Capture the full installed runtime set (migration helper):

```bash
dce extensions capture myapp --scope all --all
```

Notes:

- `capture` accepts either explicit IDs **or** `--all` (not both)
- default target is user manifests; pass `--team` for team manifests
- scope names use the same validator as `dce config set ... scopes=...`
- merges preserve existing file text/comments and append new IDs sorted

## Seed and sync devcontainer.json

`dce new` seeds `.devcontainer/devcontainer.json` with
`customizations.vscode.extensions` when manifests resolve non-empty.

`dce config sync-vscode <name>` is the single writer for managed fields.

```bash
dce config sync-vscode myapp
dce config sync-vscode myapp --dry-run
```

Policy:

- pre-adoption (no effective manifests): existing extensions array is preserved
- post-adoption (any effective manifest exists):
  `customizations.vscode.extensions` is fully managed from manifests

## Install on attach (`dce editor`)

VS Code's attached-container open (the `vscode-remote://attached-container+…`
URI `dce editor` uses) does **not** reliably process
`customizations.vscode.extensions` — unlike "Reopen in Container", it skips the
customizations install step. So `dce editor` enforces convergence itself:
before launch it resolves the declared set, lists what is installed in the
container, and runs `code-server --install-extension` for each
declared-but-missing id.

This is idempotent and advisory:

- pre-adoption (no manifests) and first-ever opens (VS Code Server not yet
  injected → no in-container `code-server`) are skipped; re-run `dce editor`
  after the first open and convergence runs.
- per-id install failures are reported but never block the launch; the next
  `dce editor` retries.

You do not call anything extra — just `dce editor <project>` after the manifests
are synced.

## Rebuild behavior and migration recipe

Rebuild wipes container filesystem state (`~/.vscode-server` included):

- declared extensions survive via devcontainer declaration + `dce editor`
  attach-mode enforcement (and native customizations handling on "Reopen in
  Container")
- undeclared runtime installs are lost by design

Before first adoption/sync on an existing project:

```bash
dce extensions capture myapp --scope all --all
dce config sync-vscode myapp
```

During ongoing use, run `dce extensions diff myapp` and capture undeclared
runtime additions before `dce rebuild-container`.
