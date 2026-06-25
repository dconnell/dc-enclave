# Getting started

## Initial setup

**Important**: `setup.sh` builds `dce-base` into the selected backend's image store. Each container backend maintains its own separate image store. If you want to use multiple backends, you must run `setup.sh` once per backend:

```
CONTAINER_BACKEND=docker scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
```

Images built on one backend are not visible to another. `dce new` checks for `dce-base:latest` on the active backend and fails early if setup has not been run for that backend.

`setup.sh` also bootstraps global configuration and directories:

- `~/.config/dce-enclave/config` with `DC_TEAM_DIR` and `DC_USER_DIR`
- `$DC_TEAM_DIR/overlays` and `$DC_TEAM_DIR/container-recipes`
- `$DC_USER_DIR/overlays` and `$DC_USER_DIR/container-recipes`

1. Ensure Bash 4+ is installed:

```
bash --version
```

macOS users: if version is 3.x, run `brew install bash`. Linux and WSL2 distros already ship bash 4+.

2. Ensure one backend is installed and running:

- apple/container (macOS), or
- Docker Desktop (macOS, Linux, WSL2), or
- OrbStack (macOS), or
- Colima (macOS, Linux), or
- Podman (macOS, Linux, WSL2)

3. Initialize repository and aliases:

```
cd ~/dce-enclave
chmod +x scripts/*.sh scripts/dce
scripts/setup.sh
```

4. Reload your shell profile (setup detects your login shell via `$SHELL` and writes to the right file):

```
source ~/.zshrc         # if your shell is zsh (macOS default)
source ~/.bashrc        # Linux/WSL2 bash
source ~/.bash_profile  # macOS bash
```

Optional: force backend during setup:

```
CONTAINER_BACKEND=podman scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
```

### Shell completion

`setup.sh` wires tab completion for `dce` into whichever shell your `$SHELL` points at:

- **zsh** — setup defines `dce` as a shell function (`dce() { '<repo>/scripts/dce' "$@"; }`) and removes the legacy managed alias line, so `dce` cannot be shadowed by another PATH command. Native completion (`scripts/_dce`, a real `#compdef dce` function) is autoloaded by adding `scripts/` to `fpath` and bound to `dce` with `compdef _dce dce`.
- **bash** — `scripts/dce-complete.bash` is sourced. Setup writes to `~/.bash_profile` on macOS or `~/.bashrc` elsewhere.

Both front-ends share one discovery layer (`lib/complete-data.sh`), including the hardened global-config parser, so project/scope lists and security guarantees are identical across shells. If you previously bridged the bash completion into zsh by hand, re-running `setup.sh` removes that stale line in favor of native zsh completion.

Completion covers each command's real argument grammar, e.g. `dce start`/`dce stop` complete multiple project names (excluding ones already typed), `dce rebuild-container` offers `--rotate-keys`/`--keep-hidden-volumes`/`--yes`, and `dce install` completes a dotfiles directory after the project.


## Set up a project

Use `dce new` (shell command), not direct script invocation.

Base-only example (no scopes needed — base image plus `Containerfile.all` if present):

```
dce new myapp 3000:3000
```

Single-scope examples (scope names match `Containerfile.<scope>` in your overlay dirs):

```
dce new myapp-frontend nodejs 3000:3000 5173:5173
dce new myapp-backend golang 8080:8080 9000:9000
dce new work-api golang --repo-path ~/code/company/api 8080:8080
```

Monorepo with multiple overlay scopes and multiple ports:

```
dce new myapp-monorepo nodejs,golang 3000:3000 5173:5173 8080:8080 9000:9000
```

Auto overlays example (`team/all`, `user/all`, plus scope-specific files when present):

```
dce new myapp-monorepo nodejs,golang 3000:3000 8080:8080
```

With resource limits:

```
dce new myapp-backend golang --cpus 2 --memory 4g 8080:8080
```

What scope combinations mean:

- `<scope>` -> include `Containerfile.<scope>` overlay files from team/user dirs
- `<scope1>,<scope2>` -> include both scopes in canonical order (all first, then listed order)
- (no scope) -> base image only, plus `Containerfile.all` when it exists
- auto overlays -> loaded from `$DC_TEAM_DIR/overlays` and `$DC_USER_DIR/overlays`



> See the [overlay contract](../reference/overlays.md#overlay-contract) for the rules overlay fragments must follow (`FROM`/`CMD` ignored, no `COPY`/`ADD`).

Starter file note:

- `Containerfiles/example/Containerfile.all` is a reference template.
- Copy it into `$DC_TEAM_DIR/overlays` or `$DC_USER_DIR/overlays`, then customize.

After dce new:

1. Edit ~/.config/dce-enclave/<name>/github-token
2. Add ~/.config/dce-enclave/<name>/ssh_key.pub as GitHub Deploy Key
3. Clone repo(s) into ${DC_REPOS_DIR:-$HOME/repos}/<name>

Port mapping notes:

- Format is host-port:container-port
- Multiple mappings are supported in one dce new command
- Example: 3000:3000 5173:5173 8080:8080

