# Example Containerfiles

This directory contains reference-only overlay templates you can copy into your
global overlay namespaces (`$DC_TEAM_DIR/overlays` or `$DC_USER_DIR/overlays`).

These files are never auto-layered directly from the repository.

Typical overlay workflow:

1. Run `scripts/setup.sh` to create `$DC_TEAM_DIR/overlays` and `$DC_USER_DIR/overlays`.
2. Copy starter overlay fragments from this directory into one of those namespaces.
3. Edit them for your team/personal workflow.

## Extension manifests

Editor extensions are declared separately from overlay `Containerfile.*` layers.
Copy these starter manifests into your team/user extension roots:

```
$DC_TEAM_DIR/extensions/vscode/
$DC_USER_DIR/extensions/vscode/
```

Templates shipped here:

- `extensions/vscode/all.txt`
- `extensions/vscode/nodejs.txt`

Example bootstrap flow:

```bash
mkdir -p "$DC_USER_DIR/extensions/vscode"
cp Containerfiles/example/extensions/vscode/*.txt "$DC_USER_DIR/extensions/vscode/"
dce config sync-vscode <project>
```

Use `dce extensions diff <project>` to inspect runtime drift and
`dce extensions capture` to curate additions back into manifests.

Supported auto-layer filenames in team/user namespaces:

- `Containerfile.all`
- `Containerfile.<scope>` (any scope name you choose)

## Overlays at a glance

Each language overlay installs a toolchain, its de-facto package manager, and a
dependency-sync hook that mirrors `Containerfile.nodejs`. Pair the overlay
with the listed `--hide` paths so generated/native artifacts stay off the host
bind mount.

| Scope | Toolchain (install method) | Package manager | Sync command | `--hide` paths | Strict env | Safe-mode env |
|---|---|---|---|---|---|---|
| `nodejs` | apt (Ubuntu archive) | npm | `npm ci` / `npm install` | `node_modules` | `DC_NODE_INSTALL_STRICT=1` | `DC_NODE_IGNORE_SCRIPTS=1` |
| `golang` | tarball + SHA256 verify | Go modules | `go mod download` | `.cache/go/mod,.cache/go/build` | `DC_GO_INSTALL_STRICT=1` | n/a (fetch runs no code) |
| `rust` | rustup-init + SHA256 verify | cargo | `cargo fetch` / `--locked` | `target` | `DC_RUST_INSTALL_STRICT=1` | n/a (fetch runs no code) |
| `dotnet` | apt (Ubuntu `main`) | NuGet (`dotnet`) | `dotnet restore` / `--locked-mode` | `.nuget` | `DC_DOTNET_INSTALL_STRICT=1` | n/a (restore runs no code) |
| `python` | apt + uv tarball (SHA256 verify) | uv | `uv sync` / `--frozen` | `.venv,.cache/uv` | `DC_PYTHON_INSTALL_STRICT=1` | `DC_PYTHON_IGNORE_SCRIPTS=1` |

Example:

```
dce new myapp python --hide .venv,.cache/uv 8000:8000
dce new svc rust --hide target 8080:8080
```

## Dependency-sync hooks

Each language overlay installs a sync hook (`dce-<lang>-entrypoint.sh`) under
`/home/dev/.local/bin`. The overlays intentionally do **not** declare
`ENTRYPOINT`/`CMD` themselves — the composed image owns a single chained
entrypoint (`scripts/compose-containerfile.sh` emits it) that runs every
`dce-*-entrypoint.sh` hook on container start, then `exec`s the long-running
CMD. This is what lets a multi-language container (`dce new app golang,rust,…`)
sync *every* ecosystem rather than only the last one.

Each hook shares the same shape:

- **Skips** cleanly (logs and returns) when the language manifest is absent, so
  the same overlay works in a repo that doesn't use that language.
- **Locked vs unlocked**: uses the reproducible command when a lockfile is
  present (`npm ci`, `cargo fetch --locked`, `dotnet restore --locked-mode`,
  `uv sync --frozen`), otherwise the unlocked variant.
- **Hashes** the manifest(s) + toolchain version into a marker file inside the
  hidden volume, so deps are only re-installed when something actually changes.
- **Fails soft by default**: a broken install logs a warning and returns, so the
  chain continues and the container stays running. Set
  `DC_<LANG>_INSTALL_STRICT=1` to make a hook exit non-zero on install failure —
  the chained entrypoint has `set -e`, so that aborts startup and the container
  does not run with broken dependencies.
- **Logs** the exact command it runs, for audit/incident review.

## Supply-chain posture

These templates avoid remote-script execution (no `curl | bash`). Every remote
artifact is either installed from the signed Ubuntu archive or downloaded pinned
and checksum-verified before use. Specifics:

- **nodejs** — Node.js/npm from the Ubuntu archive via `apt`, not a NodeSource
  setup script. The version tracks the Ubuntu 24.04 package. Pin a downloaded
  Node binary tarball (verify its checksum) in your own overlay for a specific
  Node line.
- **golang** — Go tarball from go.dev verified against a pinned `GO_SHA256_*`
  before extraction. Multi-arch (`TARGETARCH`); both `GO_SHA256_ARM64` and
  `GO_SHA256_AMD64` are pinned. Bump `GO_VERSION` and update both checksums or
  the build fails fast.
- **rust** — rustup installed from a pinned `rustup-init` binary
  (`static.rust-lang.org`) verified against `RUSTUP_SHA256_*` before execution
  (not the `curl | sh` installer). rustup then downloads the default toolchain
  from signed rust-lang infrastructure and verifies it against its manifest.
  Multi-arch; both checksums pinned.
- **dotnet** — `dotnet-sdk-8.0` from the Ubuntu 24.04 `main` archive via `apt`
  (signed), not Microsoft's `dotnet-install.sh`. apt resolves arm64/amd64
  automatically. Pin a Microsoft tarball (verified checksum) in your own overlay
  for a newer SDK than the archive carries.
- **python** — Python 3.12 from the Ubuntu archive via `apt`; `uv` installed from
  a pinned GitHub release tarball verified against `UV_SHA256_*` (not the uv
  `curl | sh` installer). Multi-arch; both checksums pinned.
- **all** — does not install opencode automatically. Opt in explicitly in your
  own overlay (review the official installer, or install a pinned release
  artifact and verify its checksum).

## Trusted vs untrusted overlays

Dependency install can execute code. Whether it does depends on the ecosystem:

- **nodejs** — `npm ci`/`npm install` runs package lifecycle scripts
  (`preinstall`, `install`, `postinstall`, `prepare`, …) **by design**. An
  untrusted `package.json` (or a transitive dependency) can therefore run
  arbitrary code at container start.
- **python** — installing wheels does not run code, but `uv sync` will build
  source distributions via PEP 517 backends (`setup.py`) when no wheel is
  available — the same class of risk as npm lifecycle scripts.
- **golang / rust / dotnet** — the sync command only *resolves and downloads*;
  it does not execute fetched code. `go mod download`, `cargo fetch`, and
  `dotnet restore` are script-free at install time. (Compilation later runs
  `go generate`, `build.rs`, and MSBuild targets respectively — but that happens
  when *you* build, not on start.)

Treat any overlay and its dependency set as **untrusted until reviewed**.

| Situation | Recommended |
|---|---|
| Your own / team-reviewed repo, committed lockfile | Default sync behavior is fine. |
| Untrusted repo or unfamiliar dependency tree (nodejs/python) | Set the safe-mode env so no install-time code runs (see below). |
| First-time evaluation of an unfamiliar overlay | Safe mode + ephemeral container, no secrets mounted. |

### Safe evaluation recipe

For nodejs or python, disable install-time code execution by setting the
overlay's safe-mode env when creating/starting the container:

```
# nodejs: npm install/ci runs with --ignore-scripts
dce new myapp nodejs --hide node_modules 3000:3000
DC_NODE_IGNORE_SCRIPTS=1 dce start myapp

# python: uv sync runs with --no-build (wheel-only)
dce new myapp python --hide .venv,.cache/uv 8000:8000
DC_PYTHON_IGNORE_SCRIPTS=1 dce start myapp
```

Caveats:

- `--ignore-scripts` (npm) still installs everything but skips hooks; packages
  that require a lifecycle step to build native addons will be broken until you
  rebuild them manually (`npm rebuild`).
- `--no-build` (uv) refuses packages with no matching wheel; the install fails
  instead of executing build code. This is the intended fail-closed behavior.

Additional hardening for genuinely untrusted inputs: run in an ephemeral
container, mount no credentials, require HTTPS registries, and prefer committed
lockfiles. Each sync hook always logs which command it ran (`running: …`), so
the startup log shows whether an install (and thus potential script execution)
occurred.

## Troubleshooting

- **A package is broken after `--ignore-scripts` / `--no-build`** — that package
  needed its lifecycle/build step. Re-run without the safe-mode env in a reviewed
  context, or rebuild the single package (`npm rebuild <pkg>`; for Python, ensure
  a wheel is available or build consciously).
- **`npm ci` fails with a lockfile/manifest mismatch** — `npm ci` requires
  `package-lock.json` to be in sync with `package.json`. Re-run `npm install`
  once to refresh the lockfile, then commit it.
- **`cargo fetch --locked` / `dotnet restore --locked-mode` / `uv sync --frozen`
  fails** — the lockfile is out of sync with the manifest. Regenerate it
  (`cargo update`, `dotnet restore`, `uv sync`) and commit it; the locked command
  is intentionally strict.
- **Deps reinstall on every start** — the hash marker lives inside the hidden
  volume; if you rebuild *without* `--keep-hidden-volumes` (the default) the
  volume is intentionally wiped for a clean slate, so a fresh install on the next
  start is expected.
- **Install error is silently ignored** — that's the soft-fail default. Set
  `DC_<LANG>_INSTALL_STRICT=1` to surface install failures immediately.
