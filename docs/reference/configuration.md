# Configuration


`setup.sh` bootstraps global configuration in:

```
~/.config/dc-enclave/config
```

Required keys:

```bash
DC_TEAM_DIR="$HOME/.config/dc-enclave/team"
DC_USER_DIR="$HOME/.config/dc-enclave/user"
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
- `network` (repeatable)
- `ip`
- `repo` (repeatable)
- `port` (repeatable)

Merge and override rules:

- user recipe overrides team recipe per key
- list keys (`hide`, `network`, `port`, `repo`) replace as a whole (not union)
- CLI args override recipe values for that run

### `repo` trust boundary

Repo entries are gated, not applied verbatim, so a recipe (or a stray CLI flag)
cannot silently widen the host bind mount:

- A recipe-sourced `repo=<path>` / `repo=<name>=<path>` entry — or a CLI
  `--repo <path>` / `--repo <name>=<path>` — that resolves **outside** the
  default repos dir (`$DC_REPOS_DIR` or `~/repos`) asks for confirmation before
  it is mounted read-write under `/workspace/<repo-name>`. `--yes`/`-y` honors
  it and prints a visible notice.
- A repo path that resolves to `/`, your home directory, the repos root, or a
  parent of it is **rejected** outright for every repo-entry surface (`dce new`,
  recipe `repo=`, `dce repo add`, or a persisted config). Those paths are too
  broad for the schema-v2 explicit-repo model: they would expose the whole repo
  warehouse or one of its parents instead of one declared checkout. Values with
  characters unsafe in a bind-mount source are also rejected.
- A repo path **inside** the default repos dir needs no confirmation.

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
dce new workspace --repo api=~/code/api --repo web=~/code/web --save-team
```

## Project config keys

Each project's config lives at `~/.config/dc-enclave/<name>/config` and is
written by `dce new`. The hardened loader rejects unknown keys, unsafe shell
syntax, and out-of-contract value combinations.

### Repos and cross-project sharing

A project owns one or more repos (`REPO_NAMES` / `REPO_PATHS`); each is
bind-mounted read-write at `/workspace/<repo-name>` under the project root
`/workspace`. Repo paths must be unique and non-overlapping **within** a
project. The same host repo path may appear in **different** projects by
design. There is no locking or coordination: two projects mounting the same
host repo share one checkout — tracked files, untracked files, branch state,
and `.git` metadata — so an edit or commit from one is immediately visible in
the other. Per-project state stays separate regardless: credentials, hidden
volumes, and the managed `/workspace/.cache` volume are never shared across
projects. See [isolation and security](../explanation/isolation-and-security.md#the-same-host-repo-in-multiple-projects).

### Legacy single-repo configs

Configs written for the original single-repo schema (`REPOS_DIR`) are rejected
by the loader, which prints a pointer to the `legacy-single-repo` branch — it
preserves the old single-repo model unchanged. `main` carries no dual-schema
runtime and no migration tooling.
