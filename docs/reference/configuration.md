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
- `network` (repeatable)
- `ip`
- `repo-path`
- `port` (repeatable)

Merge and override rules:

- user recipe overrides team recipe per key
- list keys (`hide`, `network`, `port`) replace as a whole (not union)
- CLI args override recipe values for that run

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

