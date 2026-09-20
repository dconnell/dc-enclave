#!/usr/bin/env bash
# =============================================================================
# help.sh - Display help summary or detailed help for a specific command
# =============================================================================
set -euo pipefail

# Resolve real script dir (follows symlinks) and repo root, then load the shared
# helpers so DC_VERSION is available to the summary output.
_src="${BASH_SOURCE[0]}"
while [[ -L "$_src" ]]; do
  _dir="$(cd -P "$(dirname "$_src")" && pwd)"
  _src="$(readlink "$_src")"
  [[ "$_src" != /* ]] && _src="$_dir/$_src"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_src")" && pwd)"
unset _src _dir
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/common.sh"

COMMAND="${1:-}"

_show_summary() {
  echo "DC Enclave version $DC_VERSION"
  echo ""
  echo "Usage: dce <command> [args]"
  echo ""
  echo "Commands:"
  echo "  new <name> [scope[,scope...]] [flags] [port|host:container ...]"
  echo "                                                    Create a new isolated container project"
  echo "  start [name ...]                                  Start one or more projects, or all"
  echo "  stop [name ...]                                   Stop one or more projects, or all"
  echo "  list                                              List containers and status"
  echo "  status                                            Show overall status and per-project details"
  echo "  shell <name> [command]                            Interactive shell/command; seeds git token as provider env var (zsh -ic)"
  echo "  logs <name> [-f|--follow] [--tail N]              Fetch container log stream"
  echo "  editor [--editor <id>] <name>                     Launch your editor attached to the running container (/workspace)"
  echo "  extensions <list|host|available|show|diff|capture> [<name>] [--scope <s>] [--editor <id>]"
  echo "                                                    Inspect, compare, and capture editor extensions"
  echo "  exec [--root] <name> <command...>                 Raw one-shot in a running container; no token (docker-exec style)"
  echo "  restart [name ...]                                Restart one or more projects, or all"
  echo "  rm <name> [--yes] [--keep-config] [--keep-volumes]"
  echo "                                                    Remove a project (container, volumes, snapshots, config)"
  echo "  rebuild-container <name> [--rotate-keys] [--inject-creds] [--keep-hidden-volumes] [--yes]"
  echo "                                                    Destroy and recreate container"
  echo "  rebuild-container <name> --from-snap <label>     Recreate from a snapshot"
  echo "  rebuild-image [all|base]                          Rebuild managed images"
  echo "  snapshot <name> [<label>] [--exclude-volumes] [--yes]   Snapshot container FS + hidden volumes"
  echo "  snapshots list [<name>]                           List snapshots (with sizes)"
  echo "  provenance <name> [--history|--all]               Show image provenance (overlay commits + build state)"
  echo "  clean [--dry-run] [--hidden-volumes [name]] [--snapshots [name]]"
  echo "                                                    Reclaim image tags, hidden volumes, or snapshots"
  echo "  doctor [backend|project]                          Run preflight checks and report pass/fail"
  echo "  network <create|ls|members|rm|add|remove> ...     Manage private networks between containers"
  echo "  install <name> <path>                             Install dotfiles"
  echo "  rotate-token <name>                              Push the current git token into a container (state-preserving)"
  echo "  config <show|get|set|sync-vscode|ls> ...         Inspect/edit config; sync devcontainer managed fields"
  echo "  version                                           Print version (aliases: --version, -v)"
  echo "  help [command]                                    Show this help or detailed help"
  echo ""
  echo "Run 'dce version' (or 'dce --version' / 'dce -v') to print the version."
  echo "Run 'dce help <command>' for detailed usage of a specific command."
}

_show_help_new() {
  cat <<'EOF'
Usage: dce new <name> [scope[,scope...]] [--cpus <N>] [--memory <val>]
              [--repo-path <path>] [--hide <path[,path...]> ...]
              [--network <name[,name...]>] [--ip <addr>] [--git-host <provider>]
              [--config <path>] [--save-team] [--save-user] [--yes|-y]
              [port|host:container ...]

Description:
  Creates a new isolated dev container: per-project SSH deploy key, git-host
  token placeholder, .npmrc template, and a host directory bind-mounted as
  /workspace. The container is created and started, then wired for editors
  (.devcontainer/devcontainer.json).

  The image is chosen from scopes:
  - No scopes: the shared base image (dce-base:latest).
  - With scopes: a deterministic derived image (dce-img-<hash>:latest),
    composed from team/user overlays -- built if missing, reused if present.
    Overlays live at $DC_TEAM_DIR/overlays/Containerfile.<scope> and
    $DC_USER_DIR/overlays/Containerfile.<scope>; a scope missing from both
    fails fast.

Arguments:
  <name>     Project name (letters, numbers, dot, underscore, hyphen). Must
             not already exist as a config or container.

  <scope>    Optional overlay scopes, comma-separated (e.g. node,postgres).
             If given, must be the FIRST argument after <name> -- before any
             flag or port.

  port       Published port(s); repeatable. Docker-style forms:
               5173          host 5173 -> container 5173
               8080:3000     host 8080 -> container 3000
             A bare port maps the same port on both sides (5173 == 5173:5173).
             Ports may appear anywhere after <name> (and after <scope>).

Options:
  --cpus <N>
             CPU limit (e.g. 2, 1.5).

  --memory <val>
             Memory limit (e.g. 4g, 512m).

  --repo-path <path>
             Host directory to bind-mount as /workspace. Default:
             $DC_REPOS_DIR/<name> (~/repos/<name>).
             CLI --repo-path is unrestricted. A recipe-sourced repo-path is
             gated: values resolving to /, your home, the repos root, or a
             parent of it -- and relative paths that escape the repos root --
             are rejected; absolute paths outside the default repos dir
             prompt for confirmation (--yes honors them with a notice).
             Characters unsafe in a bind-mount source are rejected from any
             source.

  --hide <path[,path...]>
             Keep /workspace-relative paths in named volumes so generated
             files (node_modules, caches) stay off the host. Repeatable.
             Examples:
               --hide node_modules
               --hide apps/web/node_modules,apps/api/node_modules

  --network <name[,name...]>
             Private dce network(s) to join, so peers reach each other by
             name without published ports. Entries are names or name:ip
             (static IPv4); the first entry is the primary. Networks must
             already exist: `dce network create <name>`.
             apple/container: a single network, no static IPs.
             Example: --network myapp,obs

  --ip <addr>
             Static IPv4 for the primary network (e.g. 10.0.0.5); shorthand
             for name:ip on the first --network entry. Not supported on
             apple/container.

  --git-host <provider>
             Git host to authenticate against (default: github). Chooses the
             token file name, placeholder sentinel, credential username, SSH
             host-key pin, and the env var `dce shell` seeds (GITHUB_TOKEN /
             GITLAB_TOKEN). Known providers: github, gitlab. Fixed at create;
             to switch, re-run `dce new`.

  --config <path>
             Load one explicit recipe file (key=value) as this run's
             defaults; name-based recipe lookup is skipped. CLI flags still
             override recipe values.

  --save-team
             Save the CLI-supplied keys from this run as a team recipe at
             $DC_TEAM_DIR/container-recipes/<name>.

  --save-user
             Same as --save-team, written to $DC_USER_DIR/container-recipes/
             <name>. Both flags may be given; recipe-defaulted values are
             never written, only what you passed on the CLI.

  --yes, -y  Skip the recipe repo-path confirmation prompt: the value is
             honored with a visible notice instead. No effect on CLI
             --repo-path or recipe paths inside the default repos dir.

Examples:
  dce new myapp                          base image, no scopes
  dce new myapp node,postgres            scopes -> derived image
  dce new myapp node 5173                publish 5173 (== 5173:5173)
  dce new web node 3000 8080:3000        multiple ports; one remapped
  dce new api nodejs --cpus 2 --memory 4g --hide node_modules 3000 --save-team
  dce new myapp --network myapp --ip 10.0.0.5
  dce new myapp --config ~/.config/dce-enclave/team/container-recipes/api
  dce new myapp node --repo-path ~/code/myapp
  dce new mono nodejs,golang --hide apps/web/node_modules --hide .cache/go/mod

Notes:
  - Requires dce-base:latest on the backend; run scripts/setup.sh first.
  - Config and secrets are stored in ~/.config/dce-enclave/<name>/ with
    restrictive permissions (chmod 600/700).
  - .devcontainer/devcontainer.json is seeded once and never overwritten;
    drift prints a notice -- reconcile with `dce config sync-vscode <name>`.
  - apple/container: DNS is set at create time (override: DCE_DNS); VS Code
    attach is experimental (see `dce help editor`).
  - Create-time choices (cpus, memory, hide, network, ports, scopes) change
    later via `dce config set` + `dce rebuild-container`.
EOF
}

_show_help_start() {
  cat <<'EOF'
Usage: dce start [name ...]

Description:
  Starts one or more dev containers. With no name, starts every configured
  project.

  If the container backend (Docker, Colima, OrbStack, Podman, ...) is not
  running, dce tries to start it and prints guidance if it cannot.

  Starting a stopped container also repairs it: hidden-volume mounts are
  re-verified, the SSH deploy key is re-injected if missing, git
  credentials are re-seeded, and the project's hosts fragment is
  reconciled into /etc/hosts. An already-running container is left
  untouched.

Arguments:
  [name ...]  One or more project names to start. If omitted, all
              configured containers are started.

Examples:
  dce start              Start all containers
  dce start myapp        Start only myapp
  dce start web api db   Start multiple containers

Notes:
  - The project must already exist (created via `dce new`).
  - With multiple names, the first failure stops the run.
  - Run `dce status` afterwards to verify running state.
EOF
}

_show_help_stop() {
  cat <<'EOF'
Usage: dce stop [name ...]

Description:
  Stops one or more dev containers. With no name, stops every configured
  project. Already-stopped containers are reported as such, not treated as
  errors.

  Stopping preserves the container filesystem: `dce start` brings it back
  with no data loss. Nothing is removed -- not the container, images,
  volumes, or config.

Arguments:
  [name ...]  One or more project names to stop. If omitted, all
              configured containers are stopped.

Examples:
  dce stop              Stop all containers
  dce stop myapp        Stop only myapp
  dce stop web api db   Stop multiple containers

Notes:
  - With multiple names, the first failure stops the run.
  - To destroy and recreate a container, use `dce rebuild-container`.
EOF
}

_show_help_status() {
  cat <<'EOF'
Usage: dce status

Description:
  Shows the state of every configured dev container:

  - Per project: running state, backend, image + overlay scopes, resource
    limits, port mappings, networks, hidden paths, workspace mount path,
    SSH key status, and git-host token status (provider-aware: GitHub,
    GitLab, ...). With jq installed, the image's provenance line is shown.
  - Stale containers: projects whose container image predates their
    configured image, with a `dce rebuild-container` hint.
  - Backend system info plus a backend-wide container listing (including
    non-dce containers).

  Ends with a quick-command cheat sheet for common operations.

Arguments:
  (none -- extra arguments are ignored)

Aliases:
  s         dce s is equivalent to dce status

Examples:
  dce status
  dce s

Notes:
  - The default backend must be reachable to show live state. Each project
    may override the backend; those entries degrade gracefully if their
    backend is unreachable.
  - Use `dce list` for a compact summary instead.
EOF
}

_show_help_list() {
  cat <<'EOF'
Usage: dce list

Description:
  Compact one-line-per-project overview. Five columns:

    NAME     project name (one line per configured project)
    STATUS   running | stopped | missing (no container) | unknown
    BACKEND  container backend for the project
    SCOPES   overlay scopes (blank for base image)
    WARN     STALE when the container image predates the configured image

Arguments:
  (none)

Aliases:
  ls        dce ls is equivalent to dce list

Examples:
  dce list
  dce ls

Notes:
  - Requires a reachable container backend.
  - Lists projects with a config under ~/.config/dce-enclave/, running or
    not -- it does not enumerate raw backend containers.
  - STALE means drift is proven: rebuild with `dce rebuild-container`.
EOF
}

_show_help_shell() {
  cat <<'EOF'
Usage: dce shell <name> [command]

Description:
  Opens an interactive zsh inside a dev container (started automatically if
  stopped). The prompt is prefixed with the project name.

  With a command, runs it non-interactively and exits. The command is
  executed via `zsh -ic`, so aliases and interactive shell config are
  loaded. Multiple words are joined into a single command string -- quote
  compound commands:

      dce shell myapp "npm install && npm run dev"

  If the project's git token is set (non-placeholder), it is exported into
  the shell as the provider's env var: GITHUB_TOKEN for github,
  GITLAB_TOKEN for gitlab.

Arguments:
  <name>     Project name. Must already exist.

  [command]  Optional command to run instead of opening an interactive
             shell. If it begins with '-', separate it from the project
             with `--`: dce shell myapp -- -flag.

Examples:
  dce shell myapp                         Interactive zsh session
  dce shell myapp "git pull"              One command, then exit
  dce shell myapp "npm install && npm run dev"

Notes:
  - A stopped container is started automatically.
  - /workspace is the host repos dir, bind-mounted.
  - For a raw, scriptable exec with NO token and NO zsh wrapping
    (docker-exec style, args passed verbatim), use `dce exec` -- the
    container must already be running. See: dce help exec.
EOF
}

_show_help_editor() {
  cat <<'EOF'
Usage: dce editor [--editor <id>] <name>

Description:
  Launches your editor attached to a running dev container at /workspace --
  the editor counterpart of `dce shell`. A stopped container is started
  automatically (same preflight as `dce shell`).

  On Docker-compatible backends (docker/orbstack/colima/podman) this is the
  CLI equivalent of VS Code's "Dev Containers: Attach to Running
  Container..." command: it points your editor at the exact container dce
  manages. On apple/container it uses VS Code Dev Containers' EXPERIMENTAL
  apple-container attach (enable "Dev Containers: Experimental: Apple
  Container Support" -- dev.containers.experimentalAppleContainerSupport --
  first; macOS only).

  With PAT auth, `dce editor` also syncs VS Code's attached-container named
  config so editor/terminal git uses the container's PAT-backed
  ~/.git-credentials instead of VS Code's host-credential forwarding. This
  is attach-mode state, separate from `dce config sync-vscode` (which
  manages .devcontainer/devcontainer.json only).

Editor selection (first match wins):
  --editor <id>     Explicit one-shot override (also --editor=<id>).
  $DCE_EDITOR       Per-shell environment variable.
  DCE_EDITOR        Key in ~/.config/dce-enclave/config.
  $VISUAL           Standard full-screen-editor env var.
  $EDITOR           Standard line-editor env var (often terminal-only).
  (default)         vscode

  Known ids: vscode, vscode-insiders (aliases: code, code-insiders).
  Unknown --editor / $DCE_EDITOR / global DCE_EDITOR values are a hard
  error; unknown $VISUAL / $EDITOR values are warned and skipped (those
  vars are shared with many other tools).

Editor binary discovery:
  - DCE_EDITOR_BIN: used verbatim, overriding all discovery.
  - Otherwise: PATH lookup, then macOS .app bundle fallback for VS Code.
  - On WSL2 the Windows binary (code.exe) is preferred; `code` is the
    fallback.

Arguments:
  <name>     Project name. Must already exist.

Options:
  --editor <id>
             Override the resolved editor for this invocation only.

Examples:
  dce editor myapp                       Default editor, attached to myapp
  dce editor --editor vscode-insiders myapp
  DCE_EDITOR=vscode dce editor myapp     Use VS Code for this shell

Notes:
  - The VS Code "Dev Containers" extension must be installed for attach;
    scripts/setup.sh warns if it is missing.
  - If the host PAT changed since the container last saw it, the existing
    container token is preserved (same policy as `dce shell`/`dce start`)
    with a warning; push the current token with `dce rotate-token <name>`.
  - macOS: `code` is not on PATH by default -- run VS Code's "Install
    'code' command in PATH" once, or set DCE_EDITOR_BIN.
  - Why attach (not "Reopen in Container") is the right path:
    docs/reference/backends.md.
EOF
}

_show_help_extensions() {
  cat <<'EOF'
Usage: dce extensions <list|host|available|show|diff|capture> [<project>] [ids...]
               [--editor <id>] [--format ids|json|manifest]
               [--scope <scope>] [--user|--team] [--all]

Description:
  Inspects, compares, and captures editor extensions against per-scope
  manifests. Extensions are declared one ID per line ('#' comments and
  blank lines allowed) under:

    $DC_TEAM_DIR/extensions/<editor>/<scope>.txt   (layered first per scope)
    $DC_USER_DIR/extensions/<editor>/<scope>.txt   (layered second per scope)

  Layering mirrors the overlay scope model: "all" is auto-prepended when
  present, then each effective scope, team-then-user, first occurrence
  wins on duplicates.

  `dce new` seeds the merged set into .devcontainer/devcontainer.json
  (customizations.<editor>.extensions) and `dce config sync-vscode`
  re-syncs it, so VS Code installs the declared set on open.

  v1 supports the vscode editor only. Container-derived subcommands need a
  RUNNING container (no auto-start) that VS Code has attached to at least
  once (the `code` CLI must be present inside). list/available/capture
  fail fast when it is not; `diff` instead prints a SKIP line and exits 0
  WITHOUT showing a diff. Start the container (and attach VS Code once)
  to get an actual comparison.

Subcommands:
  list <project>      Extensions installed in the project's container.
  host                Extensions installed on the host editor.
  available <project> Host minus container -- the greyed-out set VS Code
                      shows with an "Install in Dev Container" button
                      (approximate; VS Code filters by extensionKind).
  show <project>      Merged effective manifest set for the project's
                      scopes (what sync will write).
  diff <project>      Runtime drift in both directions:
                      installed-but-undeclared (capture these before a
                      rebuild) and declared-but-uninstalled (converges
                      automatically on editor open).
  capture <project> --scope <scope> (--all | <id>...) [--user|--team]
                      Merge extension IDs into a manifest. Selective by
                      default (explicit IDs); --all snapshots the
                      container's full installed set (the migration
                      helper). Never bulk-dumps host extensions -- the
                      manifest is curated, not a host mirror.

Options:
  --editor <id>               Editor id (default: vscode; alias: code).
  --format ids|json|manifest  Output format for list/host/available/show
                              (default: ids). diff is always human-readable.
  --scope <scope>             Target scope for capture (validated name).
  --user | --team             Manifest root for capture (default: --user;
                              mutually exclusive).
  --all                       capture: snapshot the full container install
                              set (mutually exclusive with explicit ids).

Examples:
  dce extensions show myapp
  dce extensions list myapp --format json
  dce extensions available myapp
  dce extensions diff myapp
  dce extensions capture myapp --scope nodejs esbenp.prettier-vscode
  dce extensions capture myapp --scope all --all

Migration recipe (adopt manifests without losing current extensions):
  dce extensions capture myapp --scope all --all
  dce config sync-vscode myapp

Notes:
  - Declared extensions survive `dce rebuild-container` (reinstalled when
    the rebuilt container is opened); UNDECLARED extensions are lost on
    rebuild -- `dce extensions diff` shows them, and rebuild-container
    warns before destroying them.
  - `dce config sync-vscode` fully-manages the extensions array once any
    manifest exists; before adoption it leaves a hand-curated array
    untouched (migration guard).
  - Drift surfaces in `dce doctor <project>` and `dce extensions diff`,
    and as a pre-destroy warning from `dce rebuild-container`.
  - `diff` exits 0 on SKIP, so a script cannot tell "no drift" from "not
    checked" by exit code alone -- inspect the output.
EOF
}

_show_help_logs() {
  cat <<'EOF'
Usage: dce logs <name> [-f|--follow] [--tail N]

Description:
  Fetches a container's stdout/stderr log stream: entrypoint output,
  startup banners, the Node overlay's npm-install sentinel,
  credential-injection messages from `dce start`, and crash output --
  none of which is visible from an interactive shell or an attached
  editor terminal.

  Works on stopped containers, so a container that failed to start can be
  diagnosed after the fact.

Arguments:
  <name>     Project name. Must already exist.

Options:
  -f, --follow
             Follow the output (stream new lines until interrupted).

  --tail N   Show only the last N lines (non-negative integer). Also
             accepted as --tail=N.

Examples:
  dce logs myapp                       Full log stream, once
  dce logs myapp --tail 100            Last 100 lines
  dce logs myapp -f                    Follow live output
  dce logs myapp --follow --tail 50    Last 50 lines, then follow

Notes:
  - Both flags work on every backend (apple/container maps --tail to its
    native -n).
  - For container state rather than logs: `dce status` / `dce list`.
EOF
}

_show_help_exec() {
  cat <<'EOF'
Usage: dce exec [--root] <name> <command...>

Description:
  Runs a single command in a running container, docker-exec style: args
  are passed through verbatim, executed as the dev user, with no
  git-token seeding and no zsh wrapping.

  A TTY is allocated only when both stdin and stdout are interactive, so
  piped output is never corrupted:

      dce exec myapp cat /etc/os-release | grep PRETTY
      dce exec myapp top            # interactive -> gets a TTY

Arguments:
  <name>        Project name. Must already be running (`dce start` first).

  <command...>  Command and args, verbatim (args beginning with '-'
                arrive untouched).

Options:
  --root        Run as uid 0, non-interactively, without a TTY -- for
                permission debugging (chown, system package installs).
                Maps to the same root-exec path rebuild-container uses.
                Must come before the project name.

Examples:
  dce exec myapp whoami
  dce exec myapp node -v
  dce exec myapp ls -la /workspace
  dce exec --root myapp chown -R dev:dev /workspace/build

Notes:
  - No auto-start: the container must be running.
  - `--` is not a separator here (unlike `dce shell`).
  - For token-seeded or alias-dependent one-shots, use `dce shell`.
  - For a root interactive session, use `dce shell` and then `sudo`.
EOF
}

_show_help_restart() {
  cat <<'EOF'
Usage: dce restart [name ...]

Description:
  Restarts one or more dev containers: stop, then start. With no name,
  restarts every configured project.

  Because it reuses the proven per-project flows, a restart also
  re-verifies hidden-volume mounts (important on backends like OrbStack)
  and re-injects the SSH key if missing -- the same repairs `dce start`
  performs.

Arguments:
  [name ...]  One or more project names to restart. If omitted, all
              configured containers are restarted.

Examples:
  dce restart              Restart all containers
  dce restart myapp        Restart only myapp
  dce restart web api db   Restart multiple containers

Notes:
  - Preserves the container filesystem (no rebuild). To recreate from the
    image, use `dce rebuild-container`.
EOF
}

_show_help_rm() {
  cat <<'EOF'
Usage: dce rm <name> [--yes|-y] [--keep-config] [--keep-volumes]

Description:
  Removes a dev container project. Default is a full teardown, in order:

    1. stop the container if running, then delete it
    2. remove every managed hidden volume (dce-hide-*)
    3. remove snapshot artifacts (dce-snap-* images, dce-snapvol-*
       volumes, manifests) -- these follow --keep-volumes
    4. remove the per-project config + secrets directory
       (~/.config/dce-enclave/<name>): SSH key, git token, .npmrc

  Your host code directory ($REPOS_DIR) is NEVER touched by this command.

  Destructive: prompts for confirmation (type 'yes') unless --yes is
  given. If the backend is unreachable, container/volume/snapshot removal
  is skipped with a warning but config removal still proceeds (unless
  --keep-config).

Options:
  --yes, -y       Skip the confirmation prompt.

  --keep-config   Preserve the config + secrets directory. Only the
                  container and hidden volumes are removed.

  --keep-volumes  Preserve managed hidden volumes AND snapshots. Only the
                  container and config + secrets are removed.

Arguments:
  <name>     Project name.

Examples:
  dce rm myapp                       Remove everything (prompts to confirm)
  dce rm myapp --yes                 Remove everything without prompting
  dce rm myapp --keep-config         Keep config/secrets
  dce rm myapp --keep-volumes        Keep hidden volumes + snapshots

Notes:
  - Host code at $REPOS_DIR is preserved; remove it manually if no longer
    needed:  rm -rf "${DC_REPOS_DIR:-$HOME/repos}/<name>"
  - The generated .devcontainer/devcontainer.json lives under $REPOS_DIR
    and is likewise preserved.
  - To recreate a removed project: `dce new <name> [scope] ...`.
  - To wipe only the container filesystem while keeping config and code:
    `dce rebuild-container <name>`.
EOF
}

_show_help_rebuild_container() {
  cat <<'EOF'
Usage: dce rebuild-container <name> [--rotate-keys] [--inject-creds]
              [--keep-hidden-volumes] [--yes|-y] [--from-snap <label>]

Description:
  Destroys a container and recreates it from its image. The host workspace
  (repos directory) is preserved -- only the container filesystem is
  wiped.

  Safety checks run BEFORE destruction: the required image must exist
  (else the command fails and points you at `dce rebuild-image all`),
  network membership is validated, and a warning lists any
  installed-but-undeclared editor extensions that will be lost.

  This command does not build images. It re-derives the image from current
  overlay state and project scopes, updates config if needed, then
  recreates the container from that image. Afterwards hidden mounts are
  re-verified and credentials re-injected (the same wiring as `dce new`).

  Hidden volumes (node_modules, caches) are removed by default for a
  clean slate; --keep-hidden-volumes preserves them across rebuilds.

  --from-snap <label> switches the image source to a saved snapshot
  (dce-snap-<slug>-<label>:latest, created by `dce snapshot`; slug =
  lowercased project name, non-alphanumerics collapsed to '-', truncated
  to 24 chars). Scope derivation and the CONTAINER_IMAGE
  config rewrite are skipped: the snapshot is a one-off restore source,
  never the project's configured image. Hidden volumes are ALWAYS isolated
  on restore: each is mounted from its snapshot volume (populated where
  captured, empty otherwise) while the live originals stay untouched --
  --keep-hidden-volumes has no effect here. After a restore the container
  reads "stale" in `dce list`/`dce status` until the next normal rebuild;
  that is correct (it genuinely diverges from its configured image).

  A bare restore does NOT inject credentials: the rebuilt container keeps
  exactly what the snapshot baked (nothing, for a scrubbed snapshot). Pass
  --inject-creds to force the current SSH deploy key and git token in, or
  --rotate-keys to regenerate the SSH key as incident response. Inspect a
  suspect snapshot WITHOUT these flags so its credential state survives.

Arguments:
  <name>     Project name. Must already exist.

Options:
  --rotate-keys
              Regenerate the SSH deploy key before recreating. The old key
              is backed up, the new public key is printed for you to add
              to the git host, and the command pauses (Enter) while you
              do. NOTE: --yes does not skip this pause.

  --inject-creds
              Inject the current SSH deploy key and git token,
              overwriting anything already present. Always in effect for
              a normal rebuild and for --rotate-keys; it matters only
              with --from-snap, where a bare restore injects nothing. The
              token write is idempotent (rewritten only when it differs).

  --keep-hidden-volumes
              Preserve existing hidden volumes instead of removing them.
              WARNING: combined with --rotate-keys this produces a loud
              warning -- key rotation implies incident response, where
              preserving volumes may be unsafe.

  --from-snap <label>
              Recreate from the snapshot dce-snap-<slug>-<label>:latest
              instead of the scope-derived image. The snapshot must exist
              (`dce snapshots list <name>`). See Description for volume
              isolation and credential semantics.

  --yes, -y   Skip the confirmation prompt. The destruction/recreation
              proceeds exactly as in the interactive path.

Examples:
  dce rebuild-container myapp
  dce rebuild-container myapp --keep-hidden-volumes
  dce rebuild-container myapp --rotate-keys
  dce rebuild-container myapp --from-snap 20250101-120000
  dce rebuild-container myapp --from-snap suspect --yes
  dce rebuild-container myapp --from-snap suspect --inject-creds

Notes:
  - DESTRUCTIVE to the container filesystem: uncommitted work inside the
    container is lost. Commit or push from the host repos dir first.
  - You will be prompted to type 'yes' to confirm before destruction
    (use --yes/-y to skip, e.g. for automation).
  - Re-apply dotfiles after rebuild with `dce install <name> <path>`.
  - Existing .devcontainer/devcontainer.json is preserved; a non-fatal
    drift notice prints when managed fields diverge -- reconcile with
    `dce config sync-vscode <name>`.
  - Snapshots capture the image plus the container's writable layer and,
    by default, clone each hidden volume (`dce snapshot <name> [<label>]`,
    --exclude-volumes for a filesystem-only snapshot).
EOF
}

_show_help_rebuild_image() {
  cat <<'EOF'
Usage: dce rebuild-image [all|base]

Description:
  Rebuilds managed images on the active backend (starting the backend if
  it is down):

    all   dce-base:latest plus every derived image currently selected by
          configured projects (scans project configs, dedupes). Default.
    base  dce-base:latest only.

Arguments:
  [all|base]  Scope of the rebuild (default: all).

Examples:
  dce rebuild-image
  dce rebuild-image all
  dce rebuild-image base

Notes:
  - Derived-image builds require buildx.
  - Builds are logged to each affected project's provenance log
    (`dce provenance <name>`).
  - After rebuilding images, run `dce rebuild-container <name>` for each
    container you want recreated.
EOF
}

_show_help_provenance() {
  cat <<'EOF'
Usage: dce provenance <project> [--history|--all]

Description:
  Shows the provenance of a project's current image: the team and user
  overlay state that produced it. For each overlay side (team/, user/) it
  reports the git HEAD commit (when that directory is a git checkout) and
  a content fingerprint of the layered files (always available), plus the
  base image id, scope list, DC Enclave version, and build time.

  This answers "what state were my overlay repos in when this image was
  built?" without archaeology: check out the reported commit in the
  overlay repo and rebuild to reproduce the build.

  The same data is stamped on the image as OCI labels
  (dce.team.git_commit, dce.content.hash, ...), so it is also available
  via `docker image inspect` / `podman image inspect`.

Source:
  The append-only log ~/.config/dce-enclave/<project>/provenance.jsonl.
  Events are appended by `dce new` and `dce rebuild-image` (image builds),
  `dce snapshot` (snapshot events), and `dce rebuild-container
  --from-snap` (restore events). Identical rebuilds are deduped, so the
  history is not a literal build count.

Arguments:
  <project>  Project name. Must already exist.

Options:
  --history, --all
              Print every recorded event as a table (oldest first)
              instead of just the current one.

Output:
  Pretty-printed when jq is installed; otherwise the raw JSONL line(s)
  print, so jq is never a hard requirement.

Examples:
  dce provenance myapp                 Current image's provenance
  dce provenance myapp --history       Full event timeline

Notes:
  - Projects created before provenance logging existed have no log; the
    command says so and names the commands that record one.
  - git_dirty: true means the image includes uncommitted overlay edits.
  - A side whose directory is not a git repo shows only its content
    fingerprint (content:<hash>) -- no commit to check out, but the
    fingerprint still tells you whether current files match that build.
EOF
}

_show_help_clean() {
  cat <<'EOF'
Usage: dce clean [--dry-run]

       dce clean [--dry-run] [--hidden-volumes [name]]

       dce clean [--dry-run] [--snapshots [name]]

Description:
  Reclaims backend storage. The default mode targets managed image tags;
  two opt-in modes target other object kinds. Starts the backend if it is
  down.

  Image tags (default):
  - Expected managed repos (dce-base + currently configured derived
    repos): keep latest, remove other tags.
  - Orphan managed repos (no longer expected): remove all tags, including
    latest.

  Hidden volumes (--hidden-volumes):
  - Remove orphan managed hidden volumes (dce-hide-* no longer referenced
    by an active project config). Optional [name] scopes to one project.

  Snapshots (--snapshots):
  - Remove dce-snap-* snapshot images AND their dce-snapvol-* volumes
    (created by `dce snapshot`). Optional [name] scopes to one project's
    snapshots. Default `dce clean` NEVER touches snapshots -- only this
    flag reclaims them.

Options:
  --dry-run   Show what would be removed without deleting. Image sizes
              are previewed; snapshot volumes are listed without sizes.

  --hidden-volumes
              Operate on orphan hidden volumes instead of managed image
              tags. Optional trailing project name narrows to one project.

  --snapshots
              Operate on snapshot images + snapshot volumes instead of
              managed image tags. Optional trailing project name narrows
              to one project.

  --hidden-volumes and --snapshots are mutually exclusive.

Examples:
  dce clean --dry-run
  dce clean
  dce clean --hidden-volumes --dry-run
  dce clean --hidden-volumes myproject
  dce clean --snapshots --dry-run
  dce clean --snapshots myproject

Notes:
  - Managed image repos are dce-base and dce-img-<16-hex>.
  - Images currently in use may fail to remove; those failures are
    reported.
EOF
}

_show_help_config() {
  cat <<'EOF'
Usage: dce config <subcommand> [args]

       dce config show <name>
       dce config get  <name> <key>
       dce config set  <name> <key>=<value>
       dce config set  <name> <key> <value>
       dce config sync-vscode <name> [--dry-run]
       dce config ls

Description:
  Inspects and edits a project's config file
  (~/.config/dce-enclave/<name>/config) without leaving the CLI. The file
  stays the source of truth; this is a thin, validating wrapper.
  show/get/set/ls need NO container backend, so they work even when no
  runtime is running.

  `sync-vscode` is the one carved-out subcommand: it rewrites the MANAGED
  fields in the project's .devcontainer/devcontainer.json (outside the
  config file), preserving user edits. It makes no backend call either,
  but requires jq and loads global config to re-derive the managed
  dockerfile path. It does NOT manage VS Code's attached-container named
  config; `dce editor` syncs that attach-mode state automatically on
  launch.

  Only user-input keys are writable. Identity/derived/path keys (project,
  backend, image, repos) are read-only: `set` rejects them so this
  surface can never desync the container from its managed state. Change
  those by recreating or rebuilding the project.

  Every value is validated with the same validators `dce new` and
  `dce rebuild-container` use; every write goes through the hardened
  config helpers and is then reloaded to prove the file still loads
  before success is reported.

Subcommands:
  show <name>               Print a grouped, human-readable view of the
                            config.
  get  <name> <key>         Print one value. Scalars print the value
                            (empty = unset); arrays print one element per
                            line. Exit 0 even when unset, so it is
                            scriptable.
  set  <name> <key>=<value> Validate, atomically write, then reload to
                            prove the file still loads. Arrays take a
                            comma-separated value. Both `key=value` and
                            `key value` forms work.
  sync-vscode <name>         Rewrite MANAGED devcontainer fields
                            (build, mounts/runArgs/forwardPorts, TZ) to
                            match current config, preserving user keys.
                            Also re-syncs the extensions array once
                            extension manifests exist (see
                            `dce help extensions`). `--dry-run` previews
                            drift without writing.
  ls                        List projects that have a config (no backend
                            needed).

Keys:
  Writable (set/get):
    cpus        CPU limit, e.g. 2 or 1.5. Empty = backend default.
    memory      Memory limit, e.g. 4g or 512m. Empty = backend default.
    scopes      Overlay scopes, comma-separated (e.g. nodejs,golang).
    ports       Port mappings, comma-separated (e.g. 3000:3000,8080).
    hide        Hidden /workspace paths, comma-separated (e.g. node_modules,.cache).
    networks    Networks, comma-separated; each is name or name:ip.
  Read-only (get only): project, backend, image, repos.

Examples:
  dce config show myapp
  dce config get myapp memory
  dce config set myapp cpus=4
  dce config set myapp memory 8g
  dce config set myapp scopes=nodejs,golang
  dce config set myapp ports=3000:3000,8080
  dce config set myapp cpus=                     # clear -> backend default
  dce config sync-vscode myapp
  dce config sync-vscode myapp --dry-run
  dce config ls

Notes:
  - Changes to cpus, memory, scopes, ports, hide, or networks take effect
    only after `dce rebuild-container <name>` (resource limits and mounts
    are applied at container creation time). A successful `set` prints a
    reminder.
  - `dce new` / `dce rebuild-container` never overwrite an existing
    .devcontainer/devcontainer.json; they print a drift notice when its
    managed fields diverge from current config. Use
    `dce config sync-vscode <name>` to reconcile on demand.
  - To create or remove a project (rather than edit its config), use
    `dce new` or `dce rm`. To change the image or backend, recreate the
    project.
  - Config file permissions (mode 600) are preserved across every edit.
EOF
}

_show_help_network() {
  cat <<'EOF'
Usage: dce network <create|ls|list|members|rm|add|remove> ...

Description:
  Manages private networks that let dce containers talk to each other
  without publishing any port to the host. Linking is explicit:
  containers are isolated by default and reach peers only when placed on
  the same network on purpose.

  Create a network, then attach containers to it:
    dce network create myapp
    dce new myapp-db --network myapp
    dce new myapp-web --network myapp
    # myapp-web now reaches myapp-db by name (no port published)

Addressing:
  Containers on the same network resolve each other by project name.
    - docker / orbstack / colima / podman: bare name (e.g. myapp-db)
    - apple/container: <name>.test (e.g. myapp-db.test); macOS 26+
  Static IPs are opt-in and supported on Docker-compatible backends only.

Subcommands:
  create <name> [--subnet <cidr>] [--subnet-v6 <cidr>]
                              Create a private network (idempotent: an
                              existing network is kept). Subnets are
                              auto-allocated unless given.

  ls | list                   List networks and their dce members.

  members <name>              Show which projects are on a network.

  rm <name> [--force]         Remove a network. Refuses while any project
                              config still references it; --force
                              disconnects member containers first
                              (Docker-compatible only) and warns that
                              their configs still reference the network.

  add <name> <project> [--ip <addr>]
                              Attach an existing container to a network
                              and record it in the project config (so
                              rebuilds re-attach). Idempotent; a repeated
                              add updates the pinned IP.
                              Docker-compatible backends only.

  remove <name> <project>     Detach a container from a network and drop
                              it from the project config. A non-member is
                              a no-op. Docker-compatible backends only.

Examples:
  dce network create myapp
  dce network ls
  dce network members myapp
  dce network add myapp api --ip 10.0.0.5
  dce network remove myapp api
  dce network rm myapp

Notes:
  - Networks are backend (daemon) objects; `dce network ls` lists them.
  - apple/container: attach with --network at `dce new` time only -- live
    add/remove and static IPs are unsupported, and a container may join a
    single network.
  - Containers with no --network are not linked to any dce peer.
EOF
}

_show_help_install() {
  cat <<'EOF'
Usage: dce install <name> <path>

Description:
  Applies personal config inside a container: copies a dotfiles directory
  into the container, runs its install.sh as the dev user, then removes
  the temporary copy. Afterwards git credentials are re-wired and the
  hosts fragment reconciled.

Arguments:
  <name>   Project name. Must already exist and be running
           (`dce start <name>` first).

  <path>   Path to your dotfiles directory on the host. It must contain
           an install.sh script (it is made executable inside the
           container). Relative paths and ~ are resolved automatically.

Examples:
  dce install myapp ~/dotfiles
  dce install myapp ~/.config/zsh
  dce install myapp ../my-dotfiles-repo

Notes:
  - Re-run after any rebuild to reapply your personal config.
  - If install.sh fails, the temporary copy inside the container is not
    cleaned up (it lives under /tmp).
EOF
}

_show_help_rotate_token() {
  cat <<'EOF'
Usage: dce rotate-token <name>

Description:
  Pushes the project's current host git token (PAT) into its container,
  refreshing ~/.git-credentials without a rebuild. Run it right after
  editing the host token file
  (~/.config/dce-enclave/<name>/<host>-token).

  State-preserving: packages, caches, and running processes are untouched
  (unlike `dce rebuild-container`, which destroys and recreates). The
  write is forceful -- a stale or compromised value is overwritten -- but
  happens only when the value differs, so re-running with no change is a
  no-op. The token never appears in host argv; it crosses via a stdin
  pipe.

  Under ssh or none auth there is no PAT to push: the command says so and
  exits 0 without touching the container.

Arguments:
  <name>     Project name. Must already exist. A stopped container is
             started automatically (the token can only be written into a
             running container).

Related:
  - SSH deploy-key rotation is a different operation:
      dce rebuild-container <name> --rotate-keys
    (regenerates the keypair; rebuild-bound, for incident response).
  - Force-inject current credentials into a restored snapshot:
      dce rebuild-container <name> --from-snap <label> --inject-creds
  - Check for token drift without changing anything:
      dce doctor <name>

Examples:
  dce rotate-token myapp
EOF
}

_show_help_doctor() {
  cat <<'EOF'
Usage: dce doctor [backend|project]

Description:
  Read-only preflight checks with pass/fail per subsystem: one diagnosis
  instead of assembling one from `dce status` plus tribal knowledge.

  doctor NEVER starts or mutates anything (unlike setup.sh it will not
  run `colima start`, `podman machine start`, etc.); it inspects and
  prints the exact command to run for each failure.

  Host checks (bash version, global config, overlay roots, buildx) run in
  every scope. The exit code is nonzero if any check fails, so doctor is
  CI- and preflight-friendly: `dce doctor && dce start` only proceeds
  when healthy.

Scope:
  (none)        Every detected backend CLI, plus host checks. Each backend
                gets its own section (CLI / runtime / Colima-specific /
                dce-base checks).
  <backend>     One of: apple, docker, orbstack, colima, podman.
  <project>     A configured project name: that project's backend plus
                project state -- config loads, image present, secrets
                set, git-token drift, devcontainer.json drift, extension
                drift, and container state (informational: a stopped
                project is normal and never a failure).

Arguments:
  [backend|project]
                A known backend name selects that backend; any other name
                is treated as a project (it must have a config under
                ~/.config/dce-enclave/<name>/config). Unknown names error.

Examples:
  dce doctor              All detected backends + host environment
  dce doctor colima       Only the Colima backend
  dce doctor myapp        The myapp project and its backend

Notes:
  - Read-only: no daemon/machine is started, nothing is written.
  - Per-backend image stores are independent; a missing dce-base is
    reported per backend (run CONTAINER_BACKEND=<b> scripts/setup.sh to
    build it there).
EOF
}

_show_help_snapshot() {
  cat <<'EOF'
Usage: dce snapshot <project> [<label>]

       dce snapshot <project> <label> --exclude-volumes
       dce snapshot <project> <label> --exclude-volume <path[,path...]>
       dce snapshot rm <project> <label>
       dce snapshots list [<project>]

       Options: [--yes|-y]

Description:
  A snapshot commits a project container's filesystem to a tagged image
  (dce-snap-<slug>-<label>:latest; slug = project name lowercased,
  non-alphanumerics collapsed to '-', truncated to 24 chars). It is an
  independent operation you can run at any time -- before a risky change,
  before a rebuild, or to preserve a state. Restoring is opt-in via
  `dce rebuild-container --from-snap`.

  Before committing, credentials are SCRUBBED from the writable layer
  (~/.ssh/id_ed25519, ~/.git-credentials); a scrub failure warns that the
  image may still contain credentials. A stopped container is started
  just long enough to scrub, then left stopped; a running container is
  restarted (also after a failed commit).

  By default each hidden volume (node_modules, caches) is also cloned
  into a snapshot-specific volume; the source is mounted READ-ONLY during
  the copy, so the live volume can never be corrupted. The bind-mounted
  repo is never captured. On restore, hidden volumes are ALWAYS isolated:
  each comes back populated (if captured) or EMPTY (if excluded / the
  copy failed / the path was added after the snapshot); the live
  originals are never reused or touched.

  Two workflows share one mechanism:
  - Restore a known-good state: snapshot before you experiment; if it
    breaks, rebuild clean and restore with `dce rebuild-container
    --from-snap`.
  - Preserve a suspect state for forensics: snapshot the suspect
    container, rebuild clean, and inspect the snapshot image later.

Arguments:
  <project>   Project name. Must already exist; its container must exist
              on the backend.

  [<label>]   Snapshot label. Defaults to a sortable UTC timestamp
              (YYYYmmdd-HHMMSS). Charset: [A-Za-z0-9_.-]. Refuses to
              overwrite an existing label.

Options:
  --exclude-volumes
              Skip ALL volume capture (filesystem image only). Excluded
              volumes come back EMPTY on restore -- never silently reused
              from the live volumes. No confirmation prompt.

  --exclude-volume <path[,path...]>
              Exclude specific hidden volumes only (repeatable,
              comma-separated); the rest are captured. Unknown paths are
              warned and ignored. Useful for "everything except the huge
              node_modules".

  --yes, -y   Skip the volume-copy confirmation prompt (for scripting).
              The snapshot proceeds exactly as in the interactive path.

Subcommands:
  snapshot rm <project> <label>
              Remove one snapshot image, its captured volumes, and its
              manifest.

  snapshots list [<project>]
              List snapshots sorted by label, descending (default
              timestamp labels read newest-first), with project, size,
              volumes captured, UTC time, and base image. Snapshots whose
              project config is gone are marked (orphan). Optional
              <project> scopes to that project.

Examples:
  dce snapshot myapp                                    # prompt, then capture all
  dce snapshot myapp before-rust-upgrade --yes
  dce snapshot myapp quick-config --exclude-volumes
  dce snapshot myapp deps-but-no-nm --exclude-volume node_modules
  dce snapshots list
  dce snapshots list myapp
  dce snapshot rm myapp before-rust-upgrade
  dce rebuild-container myapp --from-snap before-rust-upgrade
  dce clean --snapshots myapp --dry-run

Notes:
  - Because copying volumes is slow / disk-heavy, the command lists the
    volumes to copy and asks for confirmation first (type 'yes').
  - A failed volume copy does NOT abort the snapshot: that path is
    restored empty with a WARNING.
  - Snapshots live in the active backend's local image store only; they
    are not pushed to a registry.
  - `--from-snap` is a one-off restore: it never rewrites CONTAINER_IMAGE.
  - Reclaim disk with `dce clean --snapshots [<project>]` (default
    `dce clean` ignores snapshots and snapshot volumes).
EOF
}

_show_help_help() {
  cat <<'EOF'
Usage: dce help [command]

Description:
  Displays help information. With no argument, shows a summary of all
  available commands. With a command name, shows detailed usage
  information for that command including arguments, options, examples,
  and notes.

Arguments:
  [command]   Optional command name to show detailed help for. One of:
              new, start, stop, status, list, shell, logs, editor,
              extensions, exec, restart, rm, rebuild-container,
              rebuild-image, snapshot, provenance, clean, config,
              doctor, network, install, rotate-token, version, help

              Aliases resolve too: s (status), ls (list), net (network),
              snapshots (snapshot).

Examples:
  dce help
  dce help install
  dce help rebuild-container

Notes:
  - Running 'dce' with no arguments also shows the summary.
  - An unknown command name is an error (exit 1).
EOF
}

_show_help_version() {
  cat <<'EOF'
Usage: dce version

Description:
  Prints the DC Enclave version and exits.

Aliases:
  --version   same as 'dce version'
  -v          same as 'dce version'

Examples:
  dce version
  dce --version
  dce -v

Notes:
  - The version string is the single source of truth in lib/common.sh (DC_VERSION).
  - It is bumped in the same commit that tags a release (e.g. git tag v0.2.0).
EOF
}

if [[ -z "$COMMAND" ]]; then
  _show_summary
  exit 0
fi

case "$COMMAND" in
  new)                _show_help_new ;;
  start)              _show_help_start ;;
  stop)               _show_help_stop ;;
  status|s)           _show_help_status ;;
  list|ls)            _show_help_list ;;
  shell)              _show_help_shell ;;
  logs)               _show_help_logs ;;
  editor)             _show_help_editor ;;
  extensions)         _show_help_extensions ;;
  exec)               _show_help_exec ;;
  restart)            _show_help_restart ;;
  rm)                 _show_help_rm ;;
  rebuild-container)  _show_help_rebuild_container ;;
  rebuild-image)      _show_help_rebuild_image ;;
  snapshot|snapshots) _show_help_snapshot ;;
  provenance)         _show_help_provenance ;;
  clean)              _show_help_clean ;;
  config)             _show_help_config ;;
  doctor)             _show_help_doctor ;;
  network|net)        _show_help_network ;;
  install)            _show_help_install ;;
  rotate-token)       _show_help_rotate_token ;;
  version|--version|-v) _show_help_version ;;
  help|--help|-h)     _show_help_help ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'dce help' for a list of available commands."
    exit 1
    ;;
esac
