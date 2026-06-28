# Repository layout

```
dce-enclave/
├── Containerfiles/
│   ├── Containerfile.base
│   ├── ssh/
│   │   └── github_known_hosts         # pinned, three-channel-verified GitHub SSH host keys
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
│   ├── common.sh                       # bash 4+ version guard, shared helpers
│   ├── platform.sh                     # OS/shell detection, profile helpers
│   ├── complete-data.sh                # shared completion discovery (bash + zsh)
│   ├── container-backend.sh            # backend abstraction
│   └── vscode.sh                       # VS Code attach-config seeding
├── scripts/
│   ├── dce                               # CLI entry point
│   ├── dce-complete.bash                 # bash tab completion
│   ├── _dce                              # native zsh tab completion
│   ├── setup.sh
│   ├── help.sh                          # per-command help text (dce help <command>)
│   ├── compose-containerfile.sh
│   ├── new-container.sh
│   ├── start.sh
│   ├── stop.sh
│   ├── shell.sh
│   ├── logs.sh
│   ├── exec.sh
│   ├── restart.sh
│   ├── rm.sh
│   ├── status.sh
│   ├── rebuild-container.sh
│   ├── rebuild-image.sh
│   ├── install-dotfiles.sh
│   ├── clean.sh
│   └── list.sh
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

