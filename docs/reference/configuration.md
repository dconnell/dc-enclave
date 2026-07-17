# Configuration


`setup.sh` bootstraps global configuration in:

```
~/.config/dce-enclave/config
```

Required keys:

```bash
DC_TEAM_DIR="$HOME/.config/dce-enclave/team"
DC_USER_DIR="$HOME/.config/dce-enclave/user"
```

`dce new`, `dce rebuild-image`, and `dce rebuild-container` load `DC_TEAM_DIR` and `DC_USER_DIR` from this config file. If the global config file is missing, either root is unset, or a root does not exist, the command fails fast with remediation guidance.

Each root is an independent directory (each may be its own git repo) holding two namespaces:

```
$DC_TEAM_DIR/                      # team root (optional git repo)
  overlays/                        # image overlay Containerfile fragments
  ├── Containerfile.all            # auto-layered when it exists
  └── Containerfile.<scope>        # any scope name you define
  container-recipes/               # shareable dce new recipe files
  └── <name>                       # filename is the container name
$DC_USER_DIR/                      # user root (optional git repo)
  overlays/
  ├── Containerfile.all
  └── Containerfile.<scope>
  container-recipes/
  └── <name>
```

`setup.sh` creates both roots and their `overlays/` and `container-recipes/` subdirectories (+ starter READMEs).


## Container recipes

`dce new <name>` auto-loads recipes by container name from:

- `$DC_TEAM_DIR/container-recipes/<name>`
- `$DC_USER_DIR/container-recipes/<name>`

Recipe files are plain `key=value` lines. Supported keys:

- `scopes`
- `cpus`
- `memory`
- `hide` (repeatable)
- `sync` (`0` or `1`) — opts the project into a [synced workspace](../how-to/sync-workspace.md)
- `sync-ignore` (repeatable) — Mutagen ignore paths; only meaningful with `sync=1`
- `network` (repeatable)
- `ip`
- `repo-path`
- `port` (repeatable)

Merge and override rules:

- user recipe overrides team recipe per key
- list keys (`hide`, `sync-ignore`, `network`, `port`) replace as a whole (not union)
- CLI args override recipe values for that run

`sync=1` and `hide` are mutually exclusive in the merged result (recipe + CLI).
If both are present, `dce new` fails fast and asks you to use `sync-ignore`
under `sync` instead.

### `repo-path` trust boundary

Recipes are untrusted input, so `repo-path` is the one key that is **not** applied
verbatim. An auto-loaded recipe cannot silently widen the host bind mount:

- A recipe-sourced `repo-path` that resolves **outside** the default repos dir
  (`$DC_REPOS_DIR` or `~/repos`) asks for confirmation before it is mounted
  read-write as `/workspace`. `--yes`/`-y` honors it and prints a visible notice.
- A recipe-sourced `repo-path` that resolves to `/`, your home directory, the
  repos root, or a parent of it is **rejected** outright (too broad to expose),
  as is any value containing characters that are unsafe in a bind-mount source.
- A recipe-sourced `repo-path` **inside** the default repos dir needs no
  confirmation.
- CLI `--repo-path` is the power-user escape hatch and is **never** gated.

You can load one explicit recipe file with `--config <path>`.

You can also persist the CLI-supplied recipe keys from a `dce new` run:

- `--save-team` writes `$DC_TEAM_DIR/container-recipes/<name>`
- `--save-user` writes `$DC_USER_DIR/container-recipes/<name>`
- pass both to write both files

Saved recipes include only keys explicitly supplied on that CLI invocation (not
values inherited from an existing team/user recipe).

Example:

```bash
dce new api nodejs,golang --cpus 2 --memory 4g --hide node_modules 3000:3000 --save-team
dce new api --cpus 3 --hide .cache --save-user
```

## Project config keys

Each project's config lives at `~/.config/dce-enclave/<name>/config` and is
written by `dce new`. The hardened loader rejects unknown keys, unsafe shell
syntax, and out-of-contract value combinations. The sync-related keys are:

- `CONTAINER_SYNC` — `0` (default) or `1`. Persisted from `--sync`; `dce
  rebuild-container` reads it so a synced project stays synced across rebuild.
- `CONTAINER_SYNC_IGNORE_PATHS` — array of Mutagen ignore paths, persisted from
  `--sync-ignore`.

The loader rejects a config carrying `CONTAINER_SYNC=1` alongside a non-empty
`CONTAINER_HIDDEN_PATHS`: `--sync` and `--hide` are mutually exclusive (under
`--sync`, exclude generated paths with `CONTAINER_SYNC_IGNORE_PATHS`). See
[sync workspace](../how-to/sync-workspace.md).


