# Isolation and security


Each project container runs with its own credentials and container state, so projects stay independent. The credentials below are **optional hardening** — the container runs fine without any of them. `dce new` generates the SSH keypair and creates placeholder/template files for the rest, then prints a checklist for completing the ones you want.

- Per-project SSH deploy key (generated) — `dce new` creates a dedicated keypair at `~/.config/dc-enclave/projects/<name>/ssh_key` and prints the `.pub`. Add it as a deploy key on your git host to use it; skip if you don't need repo write from inside the container.
- Per-project git token / PAT (optional) — put a fine-grained, repo-scoped token (no admin) in the project's token file (`github-token` for `--git-host github`, `gitlab-token` for `--git-host gitlab`; GitHub is the default). A non-placeholder token becomes the container's active git auth.
  - `dce new`/`start`/`shell`/`editor`/`install`/`rebuild-container` set `credential.helper store`, seed `~/.git-credentials` as `https://<https-user>:<token>@<host>` (`x-access-token` for GitHub, `oauth2` for GitLab), and rewrite `git@<host>:` URLs to HTTPS so `git pull` works without changing your repo's `origin`.
  - The token is also exported as the provider's env var inside `dce shell` (`GITHUB_TOKEN` / `GITLAB_TOKEN`), and crosses the host/container boundary through a stdin pipe, never host argv.
  - **PAT wins over the SSH deploy key** when both are present. With only the deploy key, git routes to SSH instead.
  - **VS Code Source Control wiring (GitHub PAT only).** `dce new`/`start`/`shell`/`editor`/`rebuild-container` write `github.gitAuthentication: false` into the container's VS Code Server machine settings (`~/.vscode-server/data/Machine/settings.json`), and `dce config sync-vscode` writes the same key into the generated `devcontainer.json`. VS Code's Source Control panel (pull/push/sync) then defers to git's credential helper — the PAT in `~/.git-credentials` — instead of prompting through the GitHub extension's OAuth flow.
    - GitLab has no equivalent VS Code conflict, so no setting is emitted for it.
    - Under ssh/none auth, the key is omitted from both files, leaving VS Code's default (interactive OAuth) as a fallback.
  - **Attach mode.** Under PAT auth, `dce editor` syncs VS Code's attached-container named config with a Git `remoteEnv` override (`credential.helper = ""` then `store`) so editor/terminal Git uses the PAT-backed `~/.git-credentials` instead of VS Code's host-credential forwarding helper.
- Per-project .npmrc (optional) — a template is created at `~/.config/dc-enclave/projects/<name>/.npmrc`; edit it for projects that use npm. It is mounted read-only at `/home/dev/.npmrc`.
- Host-mounted workspace (read-write) — code lives in one or more host repos listed by `REPO_PATHS` and is bind-mounted under `/workspace/<repo-name>` inside the container, so processes in the container can read and write the project repos. Everything on the host outside those mounts (home directory, shell history, global credentials) is out of reach.

These credentials are injected by `dce` itself — at `dce new`, and re-applied by `dce start`, `dce shell`, `dce editor`, `dce install`, and `dce rebuild-container`. A VS Code-initiated rebuild bypasses dce entirely, so **always rebuild via `dce`** (never VS Code's *Rebuild Container*) or the SSH key, PAT git auth, `.npmrc`, and attach-mode Git override won't be present and `git pull` / private-package installs will fail. See [rebuild and recover](../how-to/rebuild-and-recover.md).

If a container's state is ever suspect, `dce rebuild-container` replaces the container from a known-good image without touching your host repos.

### The same host repo in multiple projects

Repo paths must be unique and non-overlapping **within** a project, but the same canonical host repo path is allowed in **different** projects — by design, with no locking, reservation, or coordination. Both containers bind-mount the same directory, so they operate on one checkout: tracked files, untracked files, branch state, and `.git` metadata are shared, and an edit or commit made from one project is immediately visible in the other.

Even when a repo is shared, credentials (SSH deploy key, git token, `.npmrc`), hidden volumes created by `--hide`, and the managed `/workspace/.cache` volume stay project-scoped. They belong to each project's container, so two projects sharing a repo remain independent trust zones for everything outside that repo's bind mount.

### VS Code remote development can reach your host

When VS Code is attached to a container, a workspace extension inside the container can open a terminal **on your host** (`workbench.action.terminal.newLocal`) and run commands in it — arbitrary code execution as your user. Microsoft treats this as by-design, and `dce` can't fix it (the command runs host-side, outside anything `dce` manages), so it's a manual tradeoff: **stock VS Code leaves your host reachable; [VSCodium blocks the command by default](https://github.com/VSCodium/vscodium/pull/2487)** ([original report](https://github.com/VSCodium/vscodium/issues/2480)). The block stops a host terminal being *opened*; one already open could still be typed into, so keep host terminals closed. See [VS Code behavior](../reference/backends.md#host-hardening-against-remote-dev-rce).

### Containers can reach your host's loopback by name

On every backend, a container can reach services listening on the host's `127.0.0.1` by the name `host.docker.internal` (see [reach a service on the host](../how-to/reach-host-services.md)) — with one runtime exception: docker on plain Linux without Docker Desktop, and rootless podman on Linux, cannot reach host *loopback-only* listeners this way (see [backends](../reference/backends.md#reaching-the-host-from-a-container)). This is a runtime property, not a per-project dce setting — dce does not gate it, and cannot scope it per port. The apple backend now matches the docker-family posture by default. The implication is worth stating plainly: anything running in the container can talk to **every** host loopback port — a local database, a personal API, a browser's remote-debugging port — so treat your host's loopback services as exposed to sandboxed code.

### Credential injection is explicit on restore and rotation

Credential injection follows a forensics-safe rule. `dce start`, `dce shell`, and
`dce install` only write credentials when they are **missing** — they never
overwrite an existing SSH deploy key or `~/.git-credentials` — so a restored or
otherwise-suspect container keeps its credential state available for inspection.
A normal `dce rebuild-container` injects current credentials (fresh container),
but a `--from-snap` restore injects **nothing** by default: the rebuilt container
keeps exactly what the snapshot baked. Opt in explicitly with `--inject-creds`
(force-inject the current SSH key and git token, overwriting any present) or
`--rotate-keys` (regenerate the SSH deploy key as part of incident response). To
push a just-rotated host token into a running container without a rebuild, use
`dce rotate-token` (state-preserving, idempotent). `dce doctor` surfaces token
drift non-destructively — comparison is hash-only and the token is never printed.

### Git host providers

The git host a project authenticates against is chosen at `dce new` time with
`--git-host` (default `github`); supported: `github`, `gitlab`. Everything that
differs per host — token file name, placeholder sentinel, HTTPS credential
username, env-var name, SSH host-key pin, deploy-key guidance — lives in one
provider registry (`lib/git-host.sh`), so the auth code is host-agnostic. The
choice is read-only after create. Self-hosted hosts are not yet supported
(their SSH keys can't be pinned at build time); see
[add a git host](../how-to/add-git-host.md).

### SSH host-key pinning

Each supported host's SSH host keys are **pinned in the base image**
(`Containerfiles/ssh/<provider>_known_hosts`), not learned at runtime. The base
image sets `StrictHostKeyChecking yes` for each pinned host and points its
`UserKnownHostsFile` at the pinned file, so an unknown or mismatched host key
fails closed instead of being silently trusted on first contact. `dce new`,
`dce start`, and `dce rebuild-container` only inject your deploy key — they no
longer run `ssh-keyscan`.

Rotating a pin (e.g. when a host changes a key) is a deliberate, reviewed change:

1. Re-verify the new keys against three independent channels — see
   [add a git host](../how-to/add-git-host.md) ("Pinning a host's SSH keys").
2. Update `Containerfiles/ssh/<provider>_known_hosts` **and** the matching
   `FP_*` constants in `tests/lint/security-ssh-host-trust.sh` in the same change.
3. `dce rebuild-image base` then `dce rebuild-container <name>` to pick up the
   new pin.

The `tests/lint/security-ssh-host-trust.sh` guard is data-driven over the
provider registry: for each known host it blocks a wrong/poisoned pin (asserts
the pinned fingerprints match the host's published values) and fails if
`accept-new` or a runtime `ssh-keyscan <host>` is reintroduced.

### Snapshots and injected credentials

`dce snapshot` commits a container's writable layer to a tagged, shareable
image. The injected credentials that live in that layer — the SSH deploy key
(`~/.ssh/id_ed25519`) and, under PAT auth, `~/.git-credentials` — are scrubbed
before the commit so they are never baked into the snapshot image. (The
read-only bind-mounted `.npmrc` is a bind mount, so it is excluded from the
commit regardless.) After the commit, `dce snapshot` re-seeds the credentials
into the still-running container so `git pull` / `ssh` keep working.

Because every backend's `exec` needs a running container, the scrub runs while
the container is still up; the writable layer survives stop/start, so removing
the files before the stop still yields a credential-free committed image. A
container that was already stopped is started transiently for the scrub and left
stopped again afterward — its credentials are re-injected by the next
`dce start`.

Each snapshot image carries a `dce.snapshot.cred_scrub=ok|failed` label. A scrub
that did not complete cleanly is `failed` and is called out with a WARNING —
treat such a snapshot as potentially credential-bearing. Even with a clean
scrub, snapshot images are shareable artifacts that contain your code and
config, so treat them as sensitive and avoid exporting or sharing them unless
you intend to.
