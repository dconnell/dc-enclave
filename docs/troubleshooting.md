# Troubleshooting

Run `dce doctor` first. It runs read-only preflight checks across the host environment and every detected backend (or one backend / one project if given) and prints a pass/fail per subsystem: bash version, global config and overlay root, backend CLI presence, runtime reachability, Colima context/runtime drift, and a per-backend `dce-base:latest`.

It never starts or mutates anything. If any check fails, it exits nonzero and shows which one — a drifted Colima context, a stopped Podman machine, a stale dce-base, the wrong bash.

```
dce doctor              # all detected backends + host checks
dce doctor colima       # one backend
dce doctor myapp        # one project + its backend
```

## Symptom quick-reference

| Symptom | Section |
|---|---|
| `dce` command not found after setup | [Bash version too old](#bash-version-too-old) |
| Image build fails with "buildx component is missing" | [BuildKit and buildx plugin missing](#buildkit-and-buildx-plugin-missing) |
| "No backend detected" | [No backend detected](#no-backend-detected) |
| Need to force a specific backend | [Forcing a specific backend](#forcing-a-specific-backend) |
| Colima context or runtime errors | [Colima backend issues](#colima-backend-issues) |
| `devcontainer.json` not updated after a `dce new`/`rebuild` | [`devcontainer.json` or `settings.json` not overwritten](#devcontainerjson-or-settingsjson-not-overwritten) |
| Port or memory change didn't take effect | [Changed ports or resource limits](#changed-ports-or-resource-limits) |
| `git pull` / SSH fails inside the container | [SSH auth issues](#ssh-auth-issues) |
| A name resolves on the host but not inside the container | [Hostname doesn't resolve inside my container](#hostname-doesnt-resolve-inside-my-container) |
| Podman won't start on macOS | [Podman on macOS not starting](#podman-on-macos-not-starting) |

## Bash version too old

macOS ships bash 3.2 by default; Linux and WSL2 distros already ship bash 4+:

```
bash --version
brew install bash          # macOS
```

## BuildKit and buildx plugin missing

dce builds images with BuildKit (its Containerfiles use multi-line heredoc `RUN`s the legacy builder drops), and BuildKit needs the `buildx` plugin. `buildx` ships with Docker Desktop and Docker CE but **not** with Ubuntu's `docker.io` (common on WSL2):

```
docker buildx version                       # verify the plugin
sudo apt-get install docker-buildx-plugin   # Docker apt repo (Linux/WSL2)
```

`docker-buildx-plugin` lives in Docker's official apt repo, not Ubuntu's — add that repo first, or download the binary from <https://github.com/docker/buildx/releases> into `/usr/libexec/docker/cli-plugins/buildx`. `scripts/setup.sh` and `dce doctor` both check for buildx and print this hint.

## No backend detected

- install apple/container, Docker Desktop, OrbStack, Colima, or Podman
- rerun scripts/setup.sh

## apple/container: no DNS / no network inside the container

apple/container's auto-configured resolver (the vmnet gateway) does not forward external DNS, so a fresh container can ping IPs (`8.8.8.8`) but not resolve names (`google.com`) — which surfaces as `getaddrinfo EAI_AGAIN` from `npm`/`git`/`code --install-extension`. dce already passes `--dns 1.1.1.1 --dns 8.8.8.8` at `container create` for apple to fix this. If you still see it:

- the container predates the fix — recreate it: `dce rebuild-container <name>` (DNS is set at create time)
- override the servers: `DCE_DNS=9.9.9.9,149.112.112.112 dce rebuild-container <name>`
- verify: `dce exec <name> getent hosts google.com`

If the container has **no network at all** (can't even ping `8.8.8.8`), a host VPN is likely conflicting with apple/container's vmnet NAT. This is an apple/container networking limitation, not a dce bug. Disconnect the VPN, or investigate a user-defined network (`container create --network <name>[,mac=…][,mtu=…]`).

## Hostname doesn't resolve inside my container

You aliased a name in your **host** `/etc/hosts` (a corporate registry, an internal service) and it works on the host, but `getent hosts` / `curl` inside the container cannot see it.

**Cause:** `/etc/hosts` is per-machine. Container runtimes regenerate the container's `/etc/hosts` at every start from their own state, so host-only aliases are not part of it. (OrbStack follows the macOS resolver and usually picks host aliases up; the other backends don't.)

**Fix:** put the entry in the project's hosts fragment, `~/.config/dce-enclave/<name>/hosts` (`dce new` scaffolds a template). dce reconciles it into the container at the next entry point — `dce start`, `dce shell`, `dce editor`, … — and leaves the rest of `/etc/hosts` alone. See [custom host entries](how-to/custom-host-entries.md), then verify:

```
dce exec <name> getent hosts internal.corp
```

If the name resolves but many internal hostnames are missing, per-host entries stop scaling — point the container at your corporate resolvers instead with `DCE_DNS` (create time only): `DCE_DNS=<ip1,ip2> dce rebuild-container <name>`.

External names (`google.com`) failing on apple/container is a different problem — see [apple/container: no DNS](#applecontainer-no-dns--no-network-inside-the-container) above.

## Forcing a specific backend

```
CONTAINER_BACKEND=apple scripts/setup.sh
CONTAINER_BACKEND=colima scripts/setup.sh
CONTAINER_BACKEND=podman dce new myapp nodejs 3000:3000
```

## Colima backend issues

```
# start Colima with the required runtime
colima start --runtime docker

# ensure Docker CLI is using Colima context
docker context use colima

# verify status and runtime
colima status
```

## `devcontainer.json` or `settings.json` not overwritten

- expected behavior to avoid clobbering local config
- on Docker-compatible projects, `dce new` / `dce rebuild-container` print a
  drift notice when managed fields diverge from config (scopes/hide/networks/ports)
- reconcile on demand with:

```
dce config sync-vscode <name>
dce config sync-vscode <name> --dry-run   # preview only
```

## Changed ports or resource limits

- update ~/.config/dce-enclave/<name>/config
- run dce rebuild-container <name>

## SSH auth issues

- verify ~/.config/dce-enclave/<name>/ssh_key and the git-host token file (github-token / gitlab-token)
- restart with dce start or recreate with dce rebuild-container

## Podman on macOS not starting

```
podman machine start
```
