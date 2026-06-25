# Isolation and security


Each project container runs with its own credentials and container state, so projects stay independent. The credentials below are **optional hardening** — the container runs fine without any of them. `dce new` generates the SSH keypair and creates placeholder/template files for the rest, then prints a checklist steering you through completing the ones you want.

- Per-project SSH deploy key (generated) — `dce new` creates a dedicated keypair at `~/.config/dce-enclave/<name>/ssh_key` and prints the `.pub`. Add it as a GitHub deploy key to use it; skip if you don't need repo write from inside the container.
- Per-project GitHub PAT (optional) — drop a fine-grained, repo-scoped token (no admin) into `~/.config/dce-enclave/<name>/github-token`. `dce shell` injects it as `GITHUB_TOKEN` only when the file is non-empty.
- Per-project .npmrc (optional) — a template is created at `~/.config/dce-enclave/<name>/.npmrc`; edit it for projects that use npm. It is mounted read-only at `/home/dev/.npmrc`.
- Host-mounted workspace — code lives at `${DC_REPOS_DIR:-$HOME/repos}/<project>` on your machine and is bind-mounted to `/workspace` inside the container.

If a container's state is ever suspect, `dce rebuild-container` replaces the container from a known-good image without touching your host repos.

### GitHub SSH host key pinning

GitHub's SSH host keys are **pinned in the base image** (`Containerfiles/ssh/github_known_hosts`), not learned at runtime. The base image sets `StrictHostKeyChecking yes` for `github.com` and points its `UserKnownHostsFile` at the pinned file, so an unknown or mismatched host key fails closed instead of being silently trusted on first contact. `dce new`, `dce start`, and `dce rebuild-container` only inject your deploy key — they no longer run `ssh-keyscan`.

Rotating the pin (e.g. when GitHub changes a key) is a deliberate, reviewed change:

1. Re-verify the new keys against three independent channels — see `plans/security/m4.md` ("Verification channels").
2. Update `Containerfiles/ssh/github_known_hosts` **and** the `FP_*` constants in `tests/security-ssh-host-trust.sh` in the same change.
3. `dce rebuild-image base` then `dce rebuild-container <name>` to pick up the new pin.

The `tests/security-ssh-host-trust.sh` guard blocks a wrong/poisoned pin (it asserts the pinned fingerprints match GitHub's published values) and fails if `accept-new` or runtime `ssh-keyscan github.com` is reintroduced.

