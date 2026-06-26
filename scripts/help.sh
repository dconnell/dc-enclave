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
  echo "  new <name> [scope[,scope...]] [host:container ...]"
  echo "                                                    Create a new isolated container project"
  echo "  new <name> [scope[,scope...]] [--config <path>] [--repo-path <path>]"
  echo "       [--save-team] [--save-user] [--cpus <N>] [--memory <val>]"
  echo "       [--hide <path[,path...]> ...] [host:container ...]"
  echo "                                                    With resource limits"
  echo "  start [name ...]                                  Start one or more projects, or all"
  echo "  stop [name ...]                                   Stop one or more projects, or all"
  echo "  list                                              List containers and status"
  echo "  status                                            Show overall status and per-project details"
  echo "  shell <name> [command]                            Interactive shell/command; seeds GITHUB_TOKEN (zsh -ic)"
  echo "  logs <name> [-f|--follow] [--tail N]              Fetch container log stream"
  echo "  exec [--root] <name> <command...>                 Raw one-shot in a running container; no token (docker-exec style)"
  echo "  restart [name ...]                                Restart one or more projects, or all"
  echo "  rm <name> [--yes] [--keep-config] [--keep-volumes]"
  echo "                                                    Remove a project (container, volumes, snapshots, config)"
  echo "  rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes] [--yes]"
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
  echo "  version                                           Print version (aliases: --version, -v)"
  echo "  help [command]                                    Show this help or detailed help"
  echo ""
  echo "Run 'dce version' (or 'dce --version' / 'dce -v') to print the version."
  echo "Run 'dce help <command>' for detailed usage of a specific command."
}

_show_help_new() {
  cat <<'EOF'
Usage: dce new <name> [scope[,scope...]] [--repo-path <path>]
              [--config <path>]
              [--save-team] [--save-user]
              [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [host:container ...]

Description:
  Creates a new isolated development container with its own SSH keys, GitHub
  token placeholder, .npmrc template, and a dedicated workspace mount.

  Image selection is scope-driven:
  - The shared base image is always dce-base:latest.
  - If effective overlay scopes are present, a deterministic derived image
    (dce-img-<hash>:latest) is selected.
  - If the derived image does not exist, it is composed and built.
  - If it exists, it is reused.

  Effective overlays are loaded only from:
  - $DC_TEAM_DIR/overlays/Containerfile.<scope>
  - $DC_USER_DIR/overlays/Containerfile.<scope>

  Named scopes that do not exist in either team or user overlays fail fast.

Arguments:
  <name>      Project name. Allowed chars: letters, numbers, dot, underscore,
              hyphen. Must not already exist.

  <scope>     Optional overlay scope(s), comma-separated.

Options:
  --config <path>
               Load one explicit container recipe file (key=value) and use it
               as defaults for this run. When set, name-based recipe lookup is
               skipped. CLI flags still override recipe values.

  --repo-path <path>
               Override the default repo mount location. Defaults to
               $DC_REPOS_DIR/<name> or ~/repos/<name>.

  --save-team
               Save only the CLI-supplied recipe keys from this run to
               $DC_TEAM_DIR/container-recipes/<name> in key=value form.
               Recipe-defaulted values are not written.

  --save-user
               Save only the CLI-supplied recipe keys from this run to
               $DC_USER_DIR/container-recipes/<name> in key=value form.
               Recipe-defaulted values are not written.

               You can pass both flags to write both files.

  --cpus <N>  CPU limit for the container (e.g. 2, 1.5). Passed to the backend.

  --memory <val>
               Memory limit for the container (e.g. 4g, 512m). Passed to the
               backend.

  --hide <path[,path...]>
               Keep one or more /workspace-relative paths in a named volume so
               generated files do not appear on the host. May be repeated.
               Examples:
                 --hide node_modules
                 --hide apps/web/node_modules,apps/api/node_modules

  --network <name[,name...]>
               Attach the container to one or more private dce networks so it can
               reach other containers on the same network by name, without
               publishing ports to the host. Each entry is a network name, or
               name:ip to pin a static IPv4. Example: --network myapp,obs

  --ip <addr>  Static IPv4 for the primary (first) network, e.g. 10.0.0.5.
               Equivalent to writing name:ip on the first --network entry. Not
               supported on the apple/container backend.

  host:container
              Port mapping(s) to publish, in Docker syntax. A bare port number
              (e.g. 5173) maps the same port on both host and container. A
              colon-separated pair (e.g. 8080:3000) maps different ports.

Examples:
  dce new myapp
  dce new myapp golang
  dce new myapp node,postgres
  dce new myapp --config ~/.config/dce-enclave/team/container-recipes/api
  dce new api nodejs --cpus 2 --memory 4g --hide node_modules 3000:3000 --save-team
  dce new api --cpus 3 --hide .cache --save-user
  dce new myapp node --repo-path ~/code/myapp
  dce new myapp --cpus 2 --memory 4g --hide node_modules 5173:5173
  dce new monorepo nodejs,golang --hide apps/web/node_modules --hide .cache/go/mod,.cache/go/build

Notes:
  - The base image 'dce-base:latest' must exist. Run scripts/setup.sh first.
  - Config is stored in ~/.config/dce-enclave/<name>/config
  - Secrets (SSH key, GitHub token, .npmrc) are stored alongside the config
    with restrictive permissions (chmod 600/700).
  - For Docker-compatible backends, a .devcontainer/devcontainer.json is
    generated for VS Code Dev Containers integration.
EOF
}

_show_help_start() {
  cat <<'EOF'
Usage: dce start [name ...]

Description:
  Starts one or more dev containers. If no project name is given, all
  configured containers are started.

  If the container backend (Docker, Colima, OrbStack, Podman, etc.) is not
  running, this command attempts to start it and prints guidance if it cannot.

  When a container is started, SSH keys are re-injected if they are missing
  from the container filesystem.

Arguments:
  [name ...]  One or more project names to start. If omitted, all configured
              containers are started.

Examples:
  dce start              Start all containers
  dce start myapp        Start only myapp
  dce start web api db   Start multiple containers

Notes:
  - The project must already exist (created via 'dce new').
  - Run 'dce status' afterwards to verify running state.
EOF
}

_show_help_stop() {
  cat <<'EOF'
Usage: dce stop [name ...]

Description:
  Stops one or more dev containers. If no project name is given, all
  configured containers are stopped.

  Stopping preserves the container filesystem - the container can be restarted
  with 'dce start' without data loss. Use 'dce rebuild-container' to fully
  destroy and recreate a container.

Arguments:
  [name ...]  One or more project names to stop. If omitted, all configured
              containers are stopped.

Examples:
  dce stop              Stop all containers
  dce stop myapp        Stop only myapp
  dce stop web api db   Stop multiple containers

Notes:
  - If a container is already stopped, it is reported as such (no error).
  - Stopping does not remove images or config.
EOF
}

_show_help_status() {
  cat <<'EOF'
Usage: dce status

Description:
  Shows detailed status of all configured dev containers, including:
  - Container name and running state
  - Backend (apple/container, Docker, OrbStack, Colima, Podman)
  - Image and overlay scopes
  - Resource limits (CPU/memory) if set
  - Port mappings
  - Workspace mount path
  - SSH key and GitHub token status

  Ends with a quick-command cheat sheet for common operations.

Arguments:
  (none)

Aliases:
  s         dce s is equivalent to dce status

Examples:
  dce status
  dce s

Notes:
  - Requires a reachable container backend to show live state.
  - Use 'dce list' for a compact summary instead.
EOF
}

_show_help_list() {
  cat <<'EOF'
Usage: dce list

Description:
  Prints a compact one-line-per-container summary showing the container name
  and its running/stopped state. Useful for a quick overview without the
  detail provided by 'dce status'.

Arguments:
  (none)

Aliases:
  ls        dce ls is equivalent to dce list

Examples:
  dce list
  dce ls

Notes:
  - Requires a reachable container backend.
  - Only shows containers managed by DC Enclave (prefixed with 'dce-').
EOF
}

_show_help_shell() {
  cat <<'EOF'
Usage: dce shell <name> [command]

Description:
  Opens an interactive shell inside a dev container. If the container is not
  running, it is started automatically.

  The GITHUB_TOKEN from the project's token file is injected into the shell
  environment (if set). The shell prompt is prefixed with the project name.

  If a command is provided, it is executed non-interactively inside the
  container (via zsh -ic) and the shell exits afterwards.

Arguments:
  <name>     Project/container name. Must already exist.

  [command]  Optional command to run instead of opening an interactive shell.
             The command is executed via 'zsh -ic' so aliases and interactive
             shell config are loaded.

Examples:
  dce shell myapp                         Open an interactive zsh session
  dce shell myapp "git pull"              Run a single command and exit
  dce shell myapp "npm install && npm run dev"

Notes:
  - If the container is stopped, 'dce start' is called automatically.
  - The workspace directory /workspace is mounted from the host repos dir.
  - GITHUB_TOKEN is available if the token file has been filled in.
  - For a raw, scriptable command with NO GITHUB_TOKEN and NO zsh wrapping
    (docker-exec style, args passed verbatim), use 'dce exec' instead. The
    container must already be running for 'dce exec'. See: dce help exec.
EOF
}

_show_help_logs() {
  cat <<'EOF'
Usage: dce logs <name> [-f|--follow] [--tail N]

Description:
  Fetches a container's stdout/stderr log stream from the backend's log
  driver. This is the container process output (entrypoint, startup banners,
  the Node overlay's npm-install sentinel, credential-injection messages from
  `dce start`, and crash output) - none of which is visible from an interactive
  shell or a VS Code terminal attached to the container.

  Works on stopped containers, so a container that failed to start (or exited
  shortly after) can be diagnosed: run `dce logs <name>` after `dce start`
  reports the container is no longer running.

Arguments:
  <name>     Project/container name. Must already exist.

Options:
  -f, --follow
             Follow log output (block, streaming new lines until interrupted).

  --tail N   Show only the last N lines. N must be a non-negative integer.
             May also be given as --tail=N.

Examples:
  dce logs myapp                       Dump the full log stream once
  dce logs myapp --tail 100            Last 100 lines
  dce logs myapp -f                    Follow live output
  dce logs myapp --follow --tail 50    Last 50 lines, then follow

Notes:
  - Both -f/--follow and --tail are supported on every backend (apple/container
    maps --tail to its native -n flag).
  - To see container state rather than logs, use `dce status` or `dce list`.
EOF
}

_show_help_exec() {
  cat <<'EOF'
Usage: dce exec [--root] <name> <command...>

Description:
  Runs a single command in a running container, docker-exec style: the command
  executes directly as the dev user with no GITHUB_TOKEN seeding, no shell
  prompt prefix, and no zsh -ic wrapping.

  A TTY is allocated automatically only when both stdin and stdout are
  interactive, so piped commands are not corrupted:

      dce exec myapp cat /etc/os-release | grep PRETTY
      dce exec myapp top            # interactive -> gets a TTY

  This is distinct from `dce shell <name> "command"`, which wraps the command
  in zsh -ic (loading aliases/interactive config) and seeds GITHUB_TOKEN. Use
  `dce shell` for token-dependent or alias-dependent one-shots; use `dce exec`
  for raw, scriptable commands.

Arguments:
  <name>        Project/container name. Must already be running.

  <command...>  The command and its arguments, passed through verbatim
                (so args beginning with '-' reach the command untouched).

Options:
  --root        Run as uid 0 (root), non-interactively. Useful for permission
                debugging (chown, package installs to system paths). Maps to
                the same root-exec path rebuild-container uses.

Examples:
  dce exec myapp whoami
  dce exec myapp node -v
  dce exec myapp ls -la /workspace
  dce exec --root myapp chown -R dev:dev /workspace/build

Notes:
  - The container must be running. Start it first with `dce start <name>`.
  - --root never allocates a TTY; for a root interactive session, use
    `dce shell <name>` and then `sudo`.
  - For an interactive dev shell, use `dce shell <name>`.
EOF
}

_show_help_restart() {
  cat <<'EOF'
Usage: dce restart [name ...]

Description:
  Restarts one or more dev containers. If no project name is given, all
  configured containers are restarted.

  Implemented as stop -> start, so it reuses the proven per-project flows:
  backend bring-up, hidden-volume re-verification (important on backends like
  OrbStack), and SSH-key re-injection all apply. Functionally equivalent to
  `dce stop <name> && dce start <name>`.

Arguments:
  [name ...]  One or more project names to restart. If omitted, all
              configured containers are restarted.

Examples:
  dce restart              Restart all containers
  dce restart myapp        Restart only myapp
  dce restart web api db   Restart multiple containers

Notes:
  - A stopped container is started; a running container is stopped and started.
  - Restarting preserves the container filesystem (no rebuild). Use
    `dce rebuild-container` to recreate from the image.
EOF
}

_show_help_rm() {
  cat <<'EOF'
Usage: dce rm <name> [--yes|-y] [--keep-config] [--keep-volumes]

Description:
  Removes a dev container project. By default this performs a full teardown:

    1. stops the container if it is running, then deletes it
    2. removes every managed hidden volume (dce-hide-<project>-<hash>)
    3. removes the per-project config + secrets directory
       (~/.config/dce-enclave/<name>), including the SSH key, GitHub token,
       and .npmrc

  Your host code directory ($REPOS_DIR) is NEVER touched by this command.

  This is destructive and prompts for confirmation (type 'yes') unless --yes
  is given.

Options:
  --yes, -y          Skip the confirmation prompt.

  --keep-config      Preserve the config + secrets directory. Only the
                     container and hidden volumes are removed.

  --keep-volumes     Preserve managed hidden volumes. Only the container and
                     config + secrets are removed.

Arguments:
  <name>     Project/container name.

Examples:
  dce rm myapp                       Remove everything (prompts to confirm)
  dce rm myapp --yes                 Remove everything without prompting
  dce rm myapp --keep-config         Remove container + volumes, keep config/secrets
  dce rm myapp --keep-volumes        Remove container + config/secrets, keep volumes

Notes:
  - Host code at $REPOS_DIR is preserved. Remove it manually if no longer
    needed:  rm -rf "${DC_REPOS_DIR:-$HOME/repos}/<name>"
  - The generated .devcontainer/devcontainer.json lives under $REPOS_DIR and is
    likewise preserved.
  - Snapshot artifacts (dce-snap-* images, dce-snapvol-* volumes, and snapshot
    manifests) are reclaimed too -- they follow --keep-volumes: preserved with
    the flag, removed without it (the same lifecycle as hidden volumes).
  - To recreate a removed project, run `dce new <name> [scope] ...` again.
  - To wipe only the container filesystem while keeping config and code, use
    `dce rebuild-container <name>` instead.
EOF
}

_show_help_rebuild_container() {
  cat <<'EOF'
Usage: dce rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes] [--yes|-y]
              [--from-snap <label>]

Description:
  Destroys a container and recreates it from its selected image.
  The host workspace (repos directory) is preserved - only the container
  filesystem is wiped.

  By default, hidden volumes (e.g. node_modules, build caches) are also
  removed so the rebuilt container starts clean. Use --keep-hidden-volumes
  to preserve dependency caches across rebuilds.

  This command does not rebuild images. It re-derives the image from current
  overlay state and project scopes, updates config if needed, and then recreates
  the container from that image.

  If the required image is missing, the command fails before destruction and
  instructs you to run:
    dce rebuild-image all

  --from-snap <label> switches the image source to a saved snapshot
  (dce-snap-<project>-<label>:latest, created by `dce snapshot`). In that mode
  scope derivation and the CONTAINER_IMAGE config rewrite are skipped: the
  snapshot is a one-off restore source, never the project's configured image.
  Hidden volumes are ALWAYS isolated on restore: each is mounted from its
  snapshot volume (populated where captured, empty otherwise), and the live
  originals are left untouched, so --keep-hidden-volumes has no effect here.
  After a restore the container reads "stale" in `dce list`/`dce status` until
  the next normal rebuild -- this is correct (it genuinely diverges from its
  configured image), not an error.

Arguments:
  <name>     Project/container name. Must already exist.

Options:
  --rotate-keys
              Regenerate the SSH deploy key before recreating the container.
              The old key is backed up, and the new public key is printed for
              you to add to GitHub. The command pauses for you to update
              GitHub before continuing.

   --keep-hidden-volumes
                Preserve existing hidden volumes instead of removing them.
                By default, hidden volumes are removed during rebuild for a
                clean slate (dependency re-install, no stale caches).
                WARNING: when the project has hidden paths configured,
                combining this with --rotate-keys produces a loud warning,
                since key rotation implies incident response where
                preserving volumes may be unsafe.

   --from-snap <label>
                Recreate from the snapshot `dce-snap-<name>-<label>:latest`
                instead of the scope-derived image. Bypasses scope derivation
                and does NOT rewrite CONTAINER_IMAGE. The snapshot must exist
                (run `dce snapshots list <name>`). Hidden volumes are ALWAYS
                isolated from the live originals: each comes back populated (if
                the snapshot captured it) or EMPTY with a warning (if the
                snapshot used --exclude-volumes, a copy failed, or the path was
                added after the snapshot). Restore reports each volume
                populated/empty and never reuses the live volumes.

   --yes, -y    Skip the confirmation prompt. Use this for scripted
                incident-response flows. The destruction/recreation still
                proceeds exactly as in the interactive path.

Examples:
  dce rebuild-container myapp
  dce rebuild-container myapp --rotate-keys
  dce rebuild-container myapp --keep-hidden-volumes
  dce rebuild-container myapp --rotate-keys --keep-hidden-volumes
  dce rebuild-container myapp --from-snap 20250101-120000
  dce rebuild-container myapp --yes

Notes:
  - This is DESTRUCTIVE to the container filesystem. Uncommitted work inside
    the container will be lost. Commit or push from the host repos dir first.
  - Your code on the host ($REPOS_DIR) is safe - it is a bind mount.
  - Hidden volumes are removed by default unless --keep-hidden-volumes is set.
  - Re-apply dotfiles after rebuild with 'dce install <name> <path>'.
  - You will be prompted to type 'yes' to confirm before destruction
    (use --yes/-y to skip, e.g. for automation).
  - Snapshots capture the image plus the container's writable layer, and by
    default also clone each hidden volume (run `dce snapshot <name> [<label>]`
    with --exclude-volumes for a filesystem-only snapshot).
EOF
}

_show_help_rebuild_image() {
  cat <<'EOF'
Usage: dce rebuild-image [all|base]

Description:
  Rebuilds managed images for the active backend.

Arguments:
  [all|base]
    all  Rebuild dce-base:latest and all configured derived images
         (default)
    base Rebuild dce-base:latest only

Examples:
  dce rebuild-image
  dce rebuild-image all
  dce rebuild-image base

Notes:
  - Requires a reachable container backend.
  - 'all' scans all project configs and rebuilds every derived image currently
    selected by configured scope sets.
  - After rebuilding images, run 'dce rebuild-container <name>' for containers
    you want to recreate.
EOF
}

_show_help_provenance() {
  cat <<'EOF'
Usage: dce provenance <project> [--history|--all]

Description:
  Shows the provenance of a project's current image: the team and user overlay
  state that produced it. For each overlay source (team/, user/) it reports the
  git HEAD commit (when that directory is a git checkout) and a content
  fingerprint of the layered files (always available), plus the base image id,
  scope list, DC Enclave version, and build time.

  This lets you answer "what state were my overlay repos in when this image was
  built?" without archaeology: read the team/user commit, check it out in the
  overlay repo, and rebuild to reproduce a build for debugging.

  The same data is stamped on the image as OCI labels
  (dce.team.git_commit, dce.content.hash, ...), so it is
  also available via `docker image inspect` / `podman image inspect`.

Source:
  The per-project append-only log ~/.config/dce-enclave/<project>/provenance.jsonl,
  written by `dce new` and `dce rebuild-image` whenever a derived image is built.
  (dce rebuild-container does not build images and so does not log.)

Arguments:
  <project>   Project/container name. Must already exist.

Options:
  --history, --all
              Print every recorded build as a table (oldest first) instead of
              just the current one. Useful to see how the overlay state moved
              over time.

Output:
  Pretty-printed when jq is installed; otherwise the raw JSONL line(s) are
  printed so the command never hard-requires jq.

Examples:
  dce provenance myapp                 Show the current image's provenance
  dce provenance myapp --history       Show the full build timeline

Notes:
  - A project created before provenance logging existed has no log; the command
    says so and tells you which command records one.
  - git_dirty: true means the image includes uncommitted overlay edits.
  - A side whose directory is not a git repo shows only its content fingerprint
    (content:<hash>); there is no commit to check out, but the fingerprint still
    tells you whether your current files match that build.
EOF
}

_show_help_clean() {
  cat <<'EOF'
Usage: dce clean [--dry-run]

       dce clean [--dry-run] [--hidden-volumes [name]]

       dce clean [--dry-run] [--snapshots [name]]

Description:
  Reclaims backend storage. Default mode removes old/orphan managed image tags
  and managed image repos. Two opt-in modes target other object kinds.

  Image-tag mode (default):
  - Expected managed repos (dce-base + currently configured derived repos):
    keep latest, remove non-latest tags.
  - Orphan managed repos (no longer expected): remove all tags, including latest.

  Hidden-volume mode (--hidden-volumes):
  - Removes orphan managed hidden volumes (dce-hide-* no longer referenced by an
    active project config). Optional [name] scopes to one project.

  Snapshot mode (--snapshots):
  - Removes dce-snap-* snapshot images AND their dce-snapvol-* snapshot volumes
    (created by `dce snapshot`). Optional [name] scopes to one project's
    snapshots.
  - Default `dce clean` NEVER touches snapshots; they are only reclaimed with
    this flag. --dry-run previews the sizes that would be freed.

Options:
  --dry-run   Show what would be removed (and how much space) without deleting.

  --hidden-volumes
              Operate on orphan hidden volumes instead of managed image tags.
              Optional trailing project name narrows cleanup to one project.

  --snapshots
              Operate on snapshot images + snapshot volumes instead of managed
              image tags. Optional trailing project name narrows cleanup to one
              project.

  --hidden-volumes and --snapshots are mutually exclusive.

Examples:
  dce clean --dry-run
  dce clean
  dce clean --hidden-volumes --dry-run
  dce clean --hidden-volumes myproject
  dce clean --snapshots --dry-run
  dce clean --snapshots myproject

Notes:
  - Managed repos are dce-base and dce-img-<16hex>.
  - Images currently in use may fail to remove; those failures are reported.
  - Hidden volume cleanup removes only orphan managed hidden volumes.
  - Snapshot cleanup removes dce-snap-* images and their dce-snapvol-* volumes
    (the default sweep ignores both).
  - Requires a reachable container backend.
EOF
}

_show_help_network() {
  cat <<'EOF'
Usage: dce network <create|ls|members|rm|add|remove> ...

Description:
  Manages private networks that let dce containers talk to each other without
  publishing any port to the host. Linking is explicit: containers are isolated
  by default and only reach peers when placed on the same network on purpose.

  Create a network, then attach containers to it:
    dce network create myapp
    dce new myapp-db --network myapp
    dce new myapp-web --network myapp
    # now myapp-web can reach myapp-db by name (no port published)

Addressing:
  Containers on the same network resolve each other by project name.
    - docker / orbstack / colima / podman: bare name (e.g. myapp-db)
    - apple/container: <name>.test (e.g. myapp-db.test); macOS 26+ required.
  Static IPs are opt-in (--ip) and supported on Docker-compatible backends only.

Subcommands:
  create <name> [--subnet <cidr>] [--subnet-v6 <cidr>]
                              Create a private network. The subnet is
                              auto-allocated unless --subnet is given.

  ls | list                   List networks and their dce members.

  members <name>              Show which projects are on a network.

  rm <name> [--force]         Remove a network. Refuses while dce projects still
                              reference it; --force disconnects them first
                              (Docker-compatible backends only) and warns that
                              their configs still reference the network.

  add <name> <project> [--ip <addr>]
                              Attach an existing container to a network and
                              record it in the project config (so rebuilds
                              re-attach). Docker-compatible backends only.

  remove <name> <project>     Detach a container from a network and drop it from
                              the project config. Docker-compatible backends only.

Notes:
  - Networks are daemon objects; use `dce network ls` to see them.
  - On apple/container, use --network at `dce new` time (live add/remove and
    static IPs are not supported); a single network per container.
  - Containers with no --network are not linked to any dce peer.
EOF
}

_show_help_install() {
  cat <<'EOF'
Usage: dce install <name> <path>

Description:
  Copies a dotfiles directory into a running container and executes its
  install.sh script. This is how you apply personal shell, editor, and tool
  configuration inside a container.

  The dotfiles are copied to a temporary directory inside the container,
  install.sh is run, and the temporary directory is cleaned up afterwards.

Arguments:
  <name>   Project/container name. Must already exist and be running.

  <path>   Path to your dotfiles directory on the host. The directory must
           contain an executable install.sh script. Relative paths and ~ are
           resolved automatically.

Examples:
  dce install myapp ~/dotfiles
  dce install myapp ~/.config/zsh
  dce install myapp ../my-dotfiles-repo

Notes:
  - The container must be running. Start it first with 'dce start <name>'.
  - The dotfiles directory must contain an install.sh file.
  - Re-run after any rebuild to reapply your personal config.
  - install.sh runs as the 'dev' user inside the container.
EOF
}

_show_help_doctor() {
  cat <<'EOF'
Usage: dce doctor [backend|project]

Description:
  Runs read-only preflight checks and prints pass/fail per subsystem, so you get
  a single diagnosis instead of assembling one from `dce status` plus tribal
  knowledge. It catches the common drift classes: wrong bash version, missing or
  broken global config / overlay root, a missing backend CLI, an unreachable
  runtime, a stale or missing dce-base image, Colima context drift, a non-docker
  Colima runtime, and (for a project) a broken config, missing image, or missing
  secrets.

  doctor NEVER starts or mutates anything (unlike setup.sh, it will not run
  `colima start`, `podman machine start`, etc.); it only inspects and reports
  the exact command to run for each failure.

  The exit code is nonzero if any check fails, so doctor is CI- and
  preflight-friendly: `dce doctor && dce start` only proceeds when healthy.

Scope:
  (none)        Every detected backend CLI, plus host checks (bash, global
                config, overlays). Each backend gets its own section with
                CLI / runtime / Colima-specific / dce-base checks.
  <backend>     One of: apple, docker, orbstack, colima, podman.
  <project>     A configured project name: checks that project's backend plus
                project-specific state (config loads, image present, secrets
                set, container state).

Arguments:
  [backend|project]
                Optional scope. A known backend name selects that backend; any
                other name is treated as a project (it must have a config under
                ~/.config/dce-enclave/<name>/config). An unknown name errors.

Examples:
  dce doctor              check all detected backends + host environment
  dce doctor colima       check only the Colima backend
  dce doctor myapp        check the myapp project and its backend

Notes:
  - Read-only: no daemon/machine is started and nothing is written.
  - Per-backend image stores are independent; a missing dce-base is reported per
    backend (run CONTAINER_BACKEND=<b> scripts/setup.sh to build it there).
  - Container state for a project is informational only (a stopped project is
    normal) and does not count as a failure.
EOF
}

_show_help_snapshot() {
  cat <<'EOF'
Usage: dce snapshot <project> [<label>]

       dce snapshot rm <project> <label>

       dce snapshots list [<project>]

Description:
  A snapshot commits a project container's filesystem to a tagged image, saving
  a state you can return to later. It is an independent operation you can run at
  any time -- before a risky change, before a rebuild, or simply to preserve a
  state. Restoring one is opt-in via `dce rebuild-container --from-snap`.

  Snapshot semantics: the image plus the container's writable layer is always
  captured, and by default each hidden volume (e.g. node_modules, caches) is
  cloned into a snapshot-specific volume (the source is mounted READ-ONLY during
  the copy, so the live volume can never be corrupted). The bind-mounted repo is
  never captured. Use --exclude-volumes for a filesystem-only snapshot. On
  restore, hidden volumes are ALWAYS isolated: each comes back populated (if
  captured) or EMPTY (if excluded / copy failed / added after the snapshot), and
  the live originals are never reused or touched.

  Two distinct workflows share one mechanism:
  - Restore a known-good state: snapshot before you experiment; if it breaks,
    rebuild clean and restore with `dce rebuild-container --from-snap`.
  - Preserve a suspect state for forensics: snapshot the suspect container,
    then rebuild clean and inspect the snapshot image later.

Subcommands:
  snapshot <project> [<label>]
              Stop -> commit -> restart the project container, producing
              dce-snap-<project>-<label>:latest, AND clone each hidden volume
              (node_modules, caches) into dce-snapvol-<project>-<label>-<hash>.
              The source volume is mounted READ-ONLY during the copy, so the
              live volume can never be corrupted. <label> defaults to a sortable
              timestamp (YYYYmmdd-HHMMSS). Refuses to overwrite an existing
              label. Label charset: [A-Za-z0-9_.-]. A failed volume copy does
              NOT abort the snapshot: the path is restored empty with a WARNING.

              Because copying volumes is slow / disk-heavy, the command lists
              the volumes to copy and asks for confirmation first.

  snapshot <project> <label> --exclude-volumes
              Skip ALL volume capture (filesystem image only). Excluded volumes
              come back EMPTY on restore -- never silently reused from the live
              volumes. No confirmation prompt.

  snapshot <project> <label> --exclude-volume <path[,path...]>
              Exclude specific hidden volumes only (repeatable, comma-separated);
              the rest are captured. Useful for "everything except the huge
              node_modules". Unknown paths are warned and ignored.

  --yes, -y   Skip the confirmation prompt (for scripting). The snapshot still
              proceeds exactly as in the interactive path.

  snapshot rm <project> <label>
              Remove one snapshot image, its captured volumes, and its manifest.

  snapshots list [<project>]
              List snapshots newest-first with project, size, volumes captured,
              UTC time, and the base image the container was running. Optional
              <project> scopes to that project.

Arguments:
  <project>   Project/container name. Must already exist (and for `snapshot`,
              its container must exist on the backend).

  [<label>]   Optional snapshot label. Defaults to a sortable UTC timestamp.

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
  - A snapshot is stop -> commit -> start (a clean commit, and apple/container's
    export, require a stopped container on every backend).
  - Snapshots live in the active backend's local image store only; they are not
    pushed to a registry.
  - `--from-snap` is a one-off restore: it never rewrites CONTAINER_IMAGE.
  - A restore ALWAYS isolates hidden volumes: each comes back populated (if
    captured) or EMPTY with a warning (if excluded, a copy failed, or the path
    was added after the snapshot). The live originals are never reused and never
    touched. Restore reports each volume populated/empty.
  - Reclaim disk with `dce clean --snapshots [<project>]` (default `dce clean`
    ignores snapshots and snapshot volumes).
EOF
}

_show_help_help() {
  cat <<'EOF'
Usage: dce help [command]

Description:
  Displays help information. With no argument, shows a summary of all
  available commands. With a command name, shows detailed usage information
  for that specific command including arguments, options, examples, and notes.

Arguments:
              [command]  Optional command name to show detailed help for. One of:
              new, start, stop, status, list, shell, logs, exec, restart, rm,
              rebuild-container, rebuild-image, snapshot, provenance, clean, doctor, network, install, version, help

Aliases:
  --help     Same as 'dce help'
  -h         Same as 'dce help'

Examples:
  dce help
  dce help install
  dce help rebuild-container

Notes:
  - Running 'dce' with no arguments also shows the summary.
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
  exec)               _show_help_exec ;;
  restart)            _show_help_restart ;;
  rm)                 _show_help_rm ;;
  rebuild-container)  _show_help_rebuild_container ;;
  rebuild-image)      _show_help_rebuild_image ;;
  snapshot|snapshots) _show_help_snapshot ;;
  provenance)         _show_help_provenance ;;
  clean)              _show_help_clean ;;
  doctor)             _show_help_doctor ;;
  network|net)        _show_help_network ;;
  install)            _show_help_install ;;
  version|--version|-v) _show_help_version ;;
  help|--help|-h)     _show_help_help ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'dce help' for a list of available commands."
    exit 1
    ;;
esac
