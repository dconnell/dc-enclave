# Repository layout

```
dce-enclave/
├── Containerfiles/
│   ├── Containerfile.base
│   ├── ssh/
│   │   ├── github_known_hosts        # pinned, three-channel-verified GitHub SSH host keys
│   │   └── gitlab_known_hosts        # pinned, three-channel-verified GitLab SSH host keys
│   ├── example/
│   │   ├── Containerfile.nodejs        # overlay template example
│   │   ├── Containerfile.golang        # overlay template example
│   │   ├── Containerfile.rust          # overlay template example
│   │   ├── Containerfile.dotnet        # overlay template example
│   │   ├── Containerfile.python        # overlay template example
│   │   ├── Containerfile.all           # overlay template example
│   │   └── README.md
│   └── generated/                      # auto-generated composed files (project overlays)
├── lib/
│   ├── common.sh                       # facade: bash 4+ guard + include guard + loads common/*.sh + git-host.sh
│   ├── common/                         # shared helpers, split by concern (sourced via common.sh)
│   │   ├── core.sh                     #   die/warn, join_by, resolve_path, sha256_*, project_slug
│   │   ├── timezone.sh                 #   host IANA timezone resolution
│   │   ├── global-config.sh            #   team/user root paths + global config load
│   │   ├── scopes.sh                   #   overlay scope validation + image-ref derivation
│   │   ├── hidden-volumes.sh           #   hidden-path normalization + volume lifecycle
│   │   ├── git-credentials.sh          #   token/PAT/SSH insteadOf wiring + VS Code machine setting
│   │   ├── snapshots.sh                #   snapshot image/volume naming + manifests
│   │   ├── image-provenance.sh         #   provenance hashing, JSON escaping, JSONL logging
│   │   ├── sync.sh                     #   synced-workspace (--sync) volume + Mutagen lifecycle
│   │   └── config.sh                   #   project config schema, validators, hardened load/write
│   ├── platform.sh                     # OS/shell detection, profile helpers
│   ├── complete-data.sh                # shared completion discovery (bash + zsh)
│   ├── container-backend.sh            # backend abstraction (apple/docker/orbstack/colima/podman)
│   ├── devcontainer.sh                 # managed .devcontainer/devcontainer.json helpers
│   ├── editor.sh                       # editor registry + cross-platform launcher
│   ├── extensions.sh                   # editor extension manifest registry + resolution
│   ├── git-host.sh                     # git host provider registry (github/gitlab)
│   ├── network.sh                      # private-network orchestration for dce-managed containers
│   ├── recipe.sh                       # untrusted container recipe parsing and merge helpers
│   └── vscode.sh                       # VS Code "attach to running container" config helpers
├── scripts/
│   ├── dce                             # CLI entry point / subcommand dispatcher
│   ├── dce-complete.bash               # bash tab completion
│   ├── _dce                            # native zsh tab completion
│   ├── setup.sh                        # one-time installer (wires `dce` into the shell profile)
│   ├── help.sh                         # per-command help text (dce help <command>)
│   ├── compose-containerfile.sh        # overlay composition -> composed Containerfile
│   ├── new-container.sh                # `dce new` project bootstrap
│   ├── start.sh / stop.sh / restart.sh # container lifecycle
│   ├── shell.sh                        # `dce shell` (exec an interactive shell in the container)
│   ├── exec.sh                         # `dce exec` (run a one-shot command in the container)
│   ├── logs.sh                         # `dce logs` (stream container stdout/stderr)
│   ├── status.sh                       # `dce status` (per-project runtime state)
│   ├── list.sh                         # `dce list` (enumerate managed projects)
│   ├── rm.sh                           # `dce rm` (remove a project + its volumes/images)
│   ├── clean.sh                        # `dce clean` (sweep stale images/volumes across projects)
│   ├── config.sh                       # `dce config` (read/edit project config)
│   ├── doctor.sh                       # `dce doctor` (environment + drift diagnostics)
│   ├── editor.sh                       # `dce editor` (launch a configured editor attached to the container)
│   ├── extensions.sh                   # `dce extensions` (sync declared VS Code extensions)
│   ├── network.sh                      # `dce network` (create/connect private networks)
│   ├── rebuild-container.sh            # `dce rebuild-container` (recreate container, keep image)
│   ├── rebuild-image.sh                # `dce rebuild-image` (rebuild the composed image)
│   ├── install-dotfiles.sh             # `dce install-dotfiles` (seed dotfiles into a container)
│   ├── rotate-token.sh                 # `dce rotate-token` (refresh PAT / regenerate SSH deploy key)
│   ├── snapshot.sh                     # `dce snapshot` / `dce restore` (image + volume snapshots)
│   └── provenance.sh                   # `dce provenance` (read a project's provenance log)
├── templates/
│   └── dotfiles/                       # starter dotfiles repo (fork for personal config)
├── tests/
│   ├── unit/                           # pure host-side helper unit tests (lib/*.sh, in-process)
│   ├── contract/                       # stubbed-backend functional/contract tests (fake docker/container/podman)
│   ├── lint/                           # static analysis + policy guards (shellcheck, supply-chain, overlays)
│   ├── integration/                    # real-backend end-to-end suite
│   ├── run-all.sh                      # aggregator over the three fast tiers (unit + contract + lint)
│   └── smoke.sh                        # lightweight command-surface smoke checks
```

Host-side paths:

- code: ${DC_REPOS_DIR:-$HOME/repos}/<project>
- secrets: ~/.config/dce-enclave/<project>
- per-project config: ~/.config/dce-enclave/<project>/config (backend, image, ports, resource limits, secrets paths)
- global config: ~/.config/dce-enclave/config
- team root: `DC_TEAM_DIR` (typically `~/.config/dce-enclave/team`) — holds `overlays/` and `container-recipes/`
- user root: `DC_USER_DIR` (typically `~/.config/dce-enclave/user`) — holds `overlays/` and `container-recipes/`

