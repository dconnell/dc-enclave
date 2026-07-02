# Isolation and security


Each project container runs with its own credentials and container state, so projects stay independent. The credentials below are **optional hardening** — the container runs fine without any of them. `dce new` generates the SSH keypair and creates placeholder/template files for the rest, then prints a checklist steering you through completing the ones you want.

- Per-project SSH deploy key (generated) — `dce new` creates a dedicated keypair at `~/.config/dce-enclave/<name>/ssh_key` and prints the `.pub`. Add it as a deploy key on your git host to use it; skip if you don't need repo write from inside the container.
- Per-project git token / PAT (optional) — drop a fine-grained, repo-scoped token (no admin) into the project's token file (`github-token` for `--git-host github`, `gitlab-token` for `--git-host gitlab`; GitHub is the default). A non-placeholder token is the container's active git auth: `dce new`/`start`/`shell`/`editor`/`install`/`rebuild-container` set `credential.helper store`, seed `~/.git-credentials` (as `https://<https-user>:<token>@<host>` — `x-access-token` for GitHub, `oauth2` for GitLab), and rewrite `git@<host>:` URLs to HTTPS so `git pull` works without changing your repo's `origin`. In attach mode, `dce editor` also syncs VS Code's attached-container named config with a PAT-only Git `remoteEnv` override so editor/terminal Git ignores VS Code's host-credential forwarding helper and uses the PAT-backed `~/.git-credentials` instead. The token also stays available as the provider's env var inside `dce shell` (`GITHUB_TOKEN` / `GITLAB_TOKEN`). **PAT wins over the SSH deploy key** when both are present; with only the deploy key, git routes to SSH instead. The token crosses the host/container boundary through a stdin pipe, never host argv. For GitHub, `github.gitAuthentication: false` is also written both to the generated `devcontainer.json` (via `dce config sync-vscode`) and directly into the container's VS Code Server machine settings (`~/.vscode-server/data/Machine/settings.json`, via `dce start`/`shell`/`editor`/`rebuild-container`) so VS Code's Source Control panel (pull/push/sync) defers to git's credential helper — the PAT in `~/.git-credentials` — instead of prompting you to sign in via the GitHub extension's OAuth flow. GitLab has no equivalent VS Code conflict, so no setting is emitted there. Both are omitted for ssh/none auth so VS Code's default (interactive OAuth) remains as a fallback.
- Per-project .npmrc (optional) — a template is created at `~/.config/dce-enclave/<name>/.npmrc`; edit it for projects that use npm. It is mounted read-only at `/home/dev/.npmrc`.
- Host-mounted workspace (read-write) — code lives at `${DC_REPOS_DIR:-$HOME/repos}/<project>` on your machine and is bind-mounted to `/workspace` inside the container, so processes in the container can read and write the project. Everything on the host outside this mount (home directory, shell history, global credentials) is out of reach.

These credentials are injected by `dce` itself — at `dce new`, and re-applied by `dce start`, `dce shell`, `dce editor`, `dce install`, and `dce rebuild-container`. A VS Code-initiated rebuild bypasses dce entirely, so **always rebuild via `dce`** (never VS Code's *Rebuild Container*) or the SSH key, PAT git auth, `.npmrc`, and attach-mode Git override won't be present and `git pull` / private-package installs will fail. See [rebuild and recover](../how-to/rebuild-and-recover.md).

If a container's state is ever suspect, `dce rebuild-container` replaces the container from a known-good image without touching your host repos.

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
(theirs SSH keys can't be pinned at build time); see
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
