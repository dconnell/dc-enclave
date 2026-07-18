# Install a container backend

DC Enclave drives one of five container runtimes. Pick one and have it running before `scripts/setup.sh`. For backend capabilities, detection order, and the support policy, see [backends](../reference/backends.md).

## apple/container (macOS)

apple/container ships with macOS 26+. Start the system daemon:

```
container system start
```

`scripts/setup.sh` will start it for you if it isn't running.

## Docker Desktop (macOS, Linux, WSL2)

Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) and launch it. Bundles the `buildx` plugin dce needs.

## OrbStack (macOS)

Install [OrbStack](https://orbstack.dev/) and launch it. Presents itself as a Docker context named `orbstack`.

## Colima

**macOS:** `brew install colima docker`, then:

```
colima start --runtime docker
```

Colima usually auto-activates its Docker context; if needed, run `docker context use colima`. DC Enclave requires the Docker runtime on Colima — if Colima is running with a non-Docker runtime (e.g. containerd), switch back before using dce.

**Linux:** Install Colima and the Docker CLI, then `colima start --runtime docker`. Ensure virtualization support is available (for example KVM access where your distro requires it).

## Podman

**macOS:** Podman runs in a VM. Run `podman machine start` before using dce, or let `scripts/setup.sh` start it for you.

**Linux:** Podman runs rootless with no daemon. Works out of the box on most distros:

```
apt install podman    # Debian/Ubuntu
dnf install podman    # Fedora
```

**WSL2:** Install natively inside WSL2 (`apt install podman`).

## WSL2 notes

Docker Desktop's WSL2 integration makes `docker` available inside WSL2 and bundles the `buildx` plugin dce needs. If you instead use Ubuntu's `docker.io` package directly inside WSL2, also install the `buildx` plugin — dce builds with BuildKit (`DOCKER_BUILDKIT=1`) and `docker.io` ships no buildx:

```
sudo apt-get install docker-buildx-plugin   # Docker apt repo (Linux/WSL2)
```

`docker-buildx-plugin` is in Docker's official apt repo (not Ubuntu's) — add that repo first, or download the binary from <https://github.com/docker/buildx/releases>.

For best bind-mount performance, keep repos inside the WSL2 filesystem (`${DC_REPOS_DIR:-$HOME/repos}/`) rather than on the Windows mount (`/mnt/c/`).
