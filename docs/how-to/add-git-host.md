# Add a git host

DC Enclave authenticates against a git host (GitHub, GitLab) using a per-project
token (PAT) and/or an SSH deploy key. Each host's specifics — token placeholder,
HTTPS credential username, env-var name, SSH host-key pin — live in one provider
registry (`lib/git-host.sh`); the auth code is host-agnostic and reads through
that registry. Adding a host is therefore mostly data, not code.

This guide covers two things:

1. **Using a supported host** (`dce new --git-host gitlab`) — the operator path.
2. **Pinning a host's SSH keys** — the contributor path, required whenever a new
   host is added to the registry or an existing host rotates a key. This is the
   procedure the registry + base image + regression test are built around.

## Using a supported host

Pick the host at create time. The default is `github`:

```bash
# GitHub (default) — identical to omitting the flag
dce new myapp nodejs 3000:3000 --git-host github

# GitLab
dce new myapp nodejs 3000:3000 --git-host gitlab
```

The flag selects, for that project: the token file name (`github-token` /
`gitlab-token`), the placeholder sentinel it's seeded with, the HTTPS credential
username used in `~/.git-credentials`, the SSH host-key pin applied, and the env
var the token is exported as inside `dce shell` (`GITHUB_TOKEN` / `GITLAB_TOKEN`).

To complete setup, edit the token file and (optionally) add the deploy key:

```
~/.config/dce-enclave/<name>/
  github-token   or   gitlab-token    # replace the sentinel with your token
  ssh_key.pub                         # add as a deploy key on your host
```

The host is **read-only after create** (`dce config` will not change it). To
switch hosts, re-run `dce new` under a new project name.

> **Self-hosted hosts.** Only the SaaS hosts (`github.com`, `gitlab.com`) are
> supported today — their SSH host keys are pinned in the base image (see below).
> A self-hosted GitLab/Gitea instance has an operator-chosen hostname whose keys
> cannot be pinned at image-build time, so it is out of scope until a
> host-override + operator-supplied known_hosts path lands.

## Pinning a host's SSH keys (contributors)

Every supported host gets its SSH host keys **pinned at image-build time** and
verified against multiple independent channels before pinning — never learned at
runtime via `ssh-keyscan`, never accepted via `StrictHostKeyChecking accept-new`.
Both of those are unattended trust decisions that accept whatever key the
network presents, i.e. exactly the TOFU behavior pinning exists to eliminate.

The regression guard `tests/lint/security-ssh-host-trust.sh` is **data-driven
over the provider registry**: for each known host it asserts the pin exists,
covers all three key types, matches that host's published fingerprints, and that
no runtime `ssh-keyscan` or `accept-new` is present.

### The procedure (same for every host)

1. **Gather the host's public SSH host keys from ≥3 independent channels** and
   confirm they agree. Independence is what defeats a single-channel MITM:
   - **Channel A — live key over SSH:** `ssh-keyscan <host>` from a trusted
     network (gives the raw key bytes).
   - **Channel B — hoster's machine-readable source over HTTPS**
     (provider-specific; see per-host notes below).
   - **Channel C — hoster's human-readable docs over a *separate* TLS cert**
     (the published-fingerprints page).
   If any channel disagrees, **stop** — do not pin.
2. **Pin all three key types** (`ssh-ed25519`, `ecdsa-sha2-nistp256`,
   `ssh-rsa`). Pinning one algorithm means a single rotation breaks
   connectivity; pinning all three leaves the others working.
3. **Write the pin file** `Containerfiles/ssh/<provider>_known_hosts` with one
   `<host> <ktype> <base64>` line per key type, and a header comment naming the
   channels, the verified SHA256 fingerprints, the source, and a
   `Last verified:` date. Mirror the existing `github_known_hosts` /
   `gitlab_known_hosts` headers exactly.
4. **Record the same fingerprints as constants** in
   `tests/lint/security-ssh-host-trust.sh` (e.g. `FP_<PROVIDER>_<KTYPE>`). The
   test computes each pinned key's fingerprint and asserts it matches; a
   poisoned or stale pin fails closed. Updating the constants IS the rotation
   action.
5. **Register the provider** in `lib/git-host.sh`:
   `dce_git_host_is_known`, `dce_git_host_known_providers`, and every
   `dce_git_host_field` `case` (one line each).
6. **Wire the pin into the base image**
   (`Containerfiles/Containerfile.base`): `COPY` the pin file to
   `/etc/ssh/ssh_known_hosts.<provider>`, and add a `Host <host>` block to the
   dev user's `~/.ssh/config` with `StrictHostKeyChecking yes` +
   `UserKnownHostsFile /etc/ssh/ssh_known_hosts.<provider>`.
7. **No runtime trust.** Never add `ssh-keyscan <host>` to `scripts/`; never use
   `StrictHostKeyChecking accept-new` in the base image. The guard asserts both.

### Per-host notes

The *procedure* is identical for every host; only the channel-B source and the
doc URLs differ.

| host | Channel A | Channel B (HTTPS, machine-readable) | Channel C (HTTPS docs, separate cert) |
|---|---|---|---|
| **github.com** | `ssh-keyscan github.com` | `https://api.github.com/meta` → `ssh_keys` + `ssh_key_fingerprints` | `docs.github.com/.../githubs-ssh-key-fingerprints` |
| **gitlab.com** | `ssh-keyscan gitlab.com` | _(no meta-style endpoint)_ | `docs.gitlab.com/ee/user/gitlab_com/#ssh-host-keys-fingerprints` (+ `docs.gitlab.com/ee/user/ssh.html`) |

> **GitLab channel-B note.** Unlike GitHub, GitLab does not expose an
> authenticated API endpoint that returns `gitlab.com`'s raw SSH host keys. The
> practical 3-channel set for GitLab is therefore: **(A)** live `ssh-keyscan`,
> **(C1)** the fingerprints page on `docs.gitlab.com`, and **(C2)** a *second*
> GitLab doc page on a different path. Record the exact channels used in the
> pin-file header. This asymmetry vs GitHub is why the procedure is written down
> rather than assumed.

### Rotating a pinned key

When a host rotates a key (rare; GitHub last rotated RSA in 2023), for the
affected provider:

1. Re-run the procedure above for the new key against the current channels.
2. Update **both** in the same change: the pin file
   (`Containerfiles/ssh/<provider>_known_hosts`) **and** the `FP_*` constants
   for that provider in `tests/lint/security-ssh-host-trust.sh`. The test fails
   if only one is updated — that is the guard.
3. `dce rebuild-image base` then `dce rebuild-container <name>` for projects on
   that host.

### Verifying your work

```bash
tests/lint/security-ssh-host-trust.sh
```

A passing run means every known host's pin exists, covers all three key types,
matches its published fingerprints, and that no runtime TOFU was reintroduced.
