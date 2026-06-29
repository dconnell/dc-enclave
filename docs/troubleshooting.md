# Troubleshooting

Run `dce doctor` first. It runs read-only preflight checks across the host environment and every detected backend (or one backend / one project if given) and prints a pass/fail per subsystem — bash version, global config and overlay root, backend CLI presence, runtime reachability, Colima context/runtime drift, and a per-backend `dce-base:latest`. It never starts or mutates anything and exits nonzero if anything fails, so it pinpoints drift (Colima context drifted, Podman machine stopped, stale dce-base, wrong bash) in one shot.

```
dce doctor              # all detected backends + host checks
dce doctor colima       # one backend
dce doctor myapp        # one project + its backend
```

Bash version too old — macOS ships bash 3.2 by default; Linux and WSL2 distros already ship bash 4+:

```
bash --version
brew install bash          # macOS
```

No backend detected:

- install apple/container, Docker Desktop, OrbStack, Colima, or Podman
- rerun scripts/setup.sh

Need specific backend:

```
CONTAINER_BACKEND=apple scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
CONTAINER_BACKEND=podman dce new myapp nodejs 3000:3000
```

Colima backend issues:

```
# start Colima with the required runtime
colima start --runtime docker

# ensure Docker CLI is using Colima context
docker context use colima

# verify status and runtime
colima status
```

devcontainer.json or settings.json not overwritten:

- expected behavior to avoid clobbering local config
- on Docker-compatible projects, `dce new` / `dce rebuild-container` print a
  drift notice when managed fields diverge from config (scopes/hide/networks/ports)
- reconcile on demand with:

```
dce config sync-vscode <name>
dce config sync-vscode <name> --dry-run   # preview only
```

Changed ports or resource limits:

- update ~/.config/dce-enclave/<name>/config
- run dce rebuild-container <name>

SSH auth issues:

- verify ~/.config/dce-enclave/<name>/ssh_key and the git-host token file (github-token / gitlab-token)
- restart with dce start or recreate with dce rebuild-container

Podman on macOS not starting:

```
podman machine start
```
