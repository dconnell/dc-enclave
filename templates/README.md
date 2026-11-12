# Templates

Everything in this directory is **copy-and-modify** starter material. Nothing
under `templates/` is used directly by `dce`: overlays, manifests, and recipes
are only read from your global config roots (`$DC_TEAM_DIR` / `$DC_USER_DIR`),
and the dotfiles become yours only after they live in their own repo.

## Singles: one file to copy

| Want | Copy from | Lands at |
|---|---|---|
| A language/tool overlay (auto-layered `Containerfile.<scope>`) | `overlays/Containerfile.<scope>` | `$DC_TEAM_DIR/overlays/Containerfile.<scope>` or `$DC_USER_DIR/overlays/Containerfile.<scope>` |
| An editor extension manifest (per-scope `publisher.name` list) | `extensions/vscode/<name>.txt` | `$DC_TEAM_DIR/extensions/vscode/<name>.txt` or `$DC_USER_DIR/extensions/vscode/<name>.txt` |
| A container recipe (key=value defaults a `dce new <name>` auto-loads) | `container-recipes/<name>` | `$DC_TEAM_DIR/container-recipes/<name>` or `$DC_USER_DIR/container-recipes/<name>` |

Dotfiles are the exception to copy-in-place: `dotfiles/` is a ready-to-fork
starter repo — copy it to its own permanent location (e.g. `~/.dotfiles` or
your GitHub dotfiles repo) and point VS Code / `dce install` at it. See
`dotfiles/README.md` and `docs/how-to/set-up-dotfiles.md`.

## Patterns: multi-file compositions

A pattern is a small set of files that only make sense together (overlays +
recipe, maybe a network). Copy the whole pattern's files to the destinations in
its README:

| Pattern | Description |
|---|---|
| [`shared-browser/`](patterns/shared-browser/README.md) | Shared headless browser host: two pinned Chromium flavors with CDP endpoints behind a relay; project containers attach via a thin `playwright-client` scope. |

## Overlay details

Per-overlay details table (toolchains, package managers, `--hide` paths,
strict/safe-mode env): see [`overlays/README.md`](overlays/README.md).
