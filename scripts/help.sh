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

source "$ROOT_DIR/lib/common.sh"

COMMAND="${1:-}"

_show_summary() {
  echo "dev-containers version $DC_VERSION"
  echo ""
  echo "Usage: dc <command> [args]"
  echo ""
  echo "Commands:"
  echo "  new <name> [scope[,scope...]] [host:container ...]"
  echo "                                                    Create a new isolated container project"
  echo "  new <name> [scope[,scope...]] [--repo-path <path>]"
  echo "       [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [host:container ...]"
  echo "                                                    With resource limits"
  echo "  start [name ...]                                  Start one or more projects, or all"
  echo "  stop [name ...]                                   Stop one or more projects, or all"
  echo "  list                                              List containers and status"
  echo "  status                                            Show overall status and per-project details"
  echo "  shell <name> [command]                            Open shell or run command"
  echo "  logs <name> [-f|--follow] [--tail N]              Fetch container log stream"
  echo "  exec [--root] <name> <command...>                 Run a command in a running container"
  echo "  restart [name ...]                                Restart one or more projects, or all"
  echo "  rm <name> [--yes] [--keep-config] [--keep-volumes]"
  echo "                                                    Remove a project (container, volumes, config)"
  echo "  rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes]"
  echo "                                                    Destroy and recreate container"
  echo "  rebuild-image [all|base]                          Rebuild managed images"
  echo "  clean [--dry-run] [--hidden-volumes [name]]       Remove old/orphan image tags or orphan hidden volumes"
  echo "  network <create|ls|members|rm|add|remove> ...     Manage private networks between containers"
  echo "  install <name> <path>                             Install dotfiles"
  echo "  version                                           Print version (aliases: --version, -v)"
  echo "  help [command]                                    Show this help or detailed help"
  echo ""
  echo "Run 'dc version' (or 'dc --version' / 'dc -v') to print the version."
  echo "Run 'dc help <command>' for detailed usage of a specific command."
}

_show_help_new() {
  cat <<'EOF'
Usage: dc new <name> [scope[,scope...]] [--repo-path <path>]
              [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [host:container ...]

Description:
  Creates a new isolated development container with its own SSH keys, GitHub
  token placeholder, .npmrc template, and a dedicated workspace mount.

  Image selection is scope-driven:
  - The shared base image is always dev-base:latest.
  - If effective overlay scopes are present, a deterministic derived image
    (dev-img-<hash>:latest) is selected.
  - If the derived image does not exist, it is composed and built.
  - If it exists, it is reused.

  Effective overlays are loaded only from:
  - $DC_OVERLAYS_DIR/team/Containerfile.<scope>
  - $DC_OVERLAYS_DIR/user/Containerfile.<scope>

  Named scopes that do not exist in either team or user overlays fail fast.

Arguments:
  <name>      Project name. Allowed chars: letters, numbers, dot, underscore,
              hyphen. Must not already exist.

  <scope>     Optional overlay scope(s), comma-separated.

Options:
  --repo-path <path>
              Override the default repo mount location. Defaults to
              $DC_REPOS_DIR/<name> or ~/repos/<name>.

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
               Attach the container to one or more private dc networks so it can
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
  dc new myapp
  dc new myapp golang
  dc new myapp node,postgres
  dc new myapp node --repo-path ~/code/myapp
  dc new myapp --cpus 2 --memory 4g --hide node_modules 5173:5173
  dc new monorepo nodejs,golang --hide apps/web/node_modules --hide .cache/go/mod,.cache/go/build

Notes:
  - The base image 'dev-base:latest' must exist. Run scripts/setup.sh first.
  - Config is stored in ~/.config/dev-containers/<name>/config
  - Secrets (SSH key, GitHub token, .npmrc) are stored alongside the config
    with restrictive permissions (chmod 600/700).
  - For Docker-compatible backends, a .devcontainer/devcontainer.json is
    generated for VS Code Dev Containers integration.
EOF
}

_show_help_start() {
  cat <<'EOF'
Usage: dc start [name ...]

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
  dc start              Start all containers
  dc start myapp        Start only myapp
  dc start web api db   Start multiple containers

Notes:
  - The project must already exist (created via 'dc new').
  - Run 'dc status' afterwards to verify running state.
EOF
}

_show_help_stop() {
  cat <<'EOF'
Usage: dc stop [name ...]

Description:
  Stops one or more dev containers. If no project name is given, all
  configured containers are stopped.

  Stopping preserves the container filesystem - the container can be restarted
  with 'dc start' without data loss. Use 'dc rebuild-container' to fully
  destroy and recreate a container.

Arguments:
  [name ...]  One or more project names to stop. If omitted, all configured
              containers are stopped.

Examples:
  dc stop              Stop all containers
  dc stop myapp        Stop only myapp
  dc stop web api db   Stop multiple containers

Notes:
  - If a container is already stopped, it is reported as such (no error).
  - Stopping does not remove images or config.
EOF
}

_show_help_status() {
  cat <<'EOF'
Usage: dc status

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
  s         dc s is equivalent to dc status

Examples:
  dc status
  dc s

Notes:
  - Requires a reachable container backend to show live state.
  - Use 'dc list' for a compact summary instead.
EOF
}

_show_help_list() {
  cat <<'EOF'
Usage: dc list

Description:
  Prints a compact one-line-per-container summary showing the container name
  and its running/stopped state. Useful for a quick overview without the
  detail provided by 'dc status'.

Arguments:
  (none)

Aliases:
  ls        dc ls is equivalent to dc list

Examples:
  dc list
  dc ls

Notes:
  - Requires a reachable container backend.
  - Only shows containers managed by dev-containers (prefixed with 'dev-').
EOF
}

_show_help_shell() {
  cat <<'EOF'
Usage: dc shell <name> [command]

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
  dc shell myapp                         Open an interactive zsh session
  dc shell myapp "git pull"              Run a single command and exit
  dc shell myapp "npm install && npm run dev"

Notes:
  - If the container is stopped, 'dc start' is called automatically.
  - The workspace directory /workspace is mounted from the host repos dir.
  - GITHUB_TOKEN is available if the token file has been filled in.
EOF
}

_show_help_logs() {
  cat <<'EOF'
Usage: dc logs <name> [-f|--follow] [--tail N]

Description:
  Fetches a container's stdout/stderr log stream from the backend's log
  driver. This is the container process output (entrypoint, startup banners,
  the Node overlay's npm-install sentinel, credential-injection messages from
  `dc start`, and crash output) - none of which is visible from an interactive
  shell or a VS Code terminal attached to the container.

  Works on stopped containers, so a container that failed to start (or exited
  shortly after) can be diagnosed: run `dc logs <name>` after `dc start`
  reports the container is no longer running.

Arguments:
  <name>     Project/container name. Must already exist.

Options:
  -f, --follow
             Follow log output (block, streaming new lines until interrupted).

  --tail N   Show only the last N lines. N must be a non-negative integer.
             May also be given as --tail=N.

Examples:
  dc logs myapp                       Dump the full log stream once
  dc logs myapp --tail 100            Last 100 lines
  dc logs myapp -f                    Follow live output
  dc logs myapp --follow --tail 50    Last 50 lines, then follow

Notes:
  - Flag support (-f, --tail) depends on the backend version. dev-containers
    targets the latest stable release of each backend.
  - To see container state rather than logs, use `dc status` or `dc list`.
EOF
}

_show_help_exec() {
  cat <<'EOF'
Usage: dc exec [--root] <name> <command...>

Description:
  Runs a single command in a running container, docker-exec style: the command
  executes directly as the dev user with no GITHUB_TOKEN seeding, no shell
  prompt prefix, and no zsh -ic wrapping.

  A TTY is allocated automatically only when both stdin and stdout are
  interactive, so piped commands are not corrupted:

      dc exec myapp cat /etc/os-release | grep PRETTY
      dc exec myapp top            # interactive -> gets a TTY

  This is distinct from `dc shell <name> "command"`, which wraps the command
  in zsh -ic (loading aliases/interactive config) and seeds GITHUB_TOKEN. Use
  `dc shell` for token-dependent or alias-dependent one-shots; use `dc exec`
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
  dc exec myapp whoami
  dc exec myapp node -v
  dc exec myapp ls -la /workspace
  dc exec --root myapp chown -R dev:dev /workspace/build

Notes:
  - The container must be running. Start it first with `dc start <name>`.
  - --root never allocates a TTY; for a root interactive session, use
    `dc shell <name>` and then `sudo`.
  - For an interactive dev shell, use `dc shell <name>`.
EOF
}

_show_help_restart() {
  cat <<'EOF'
Usage: dc restart [name ...]

Description:
  Restarts one or more dev containers. If no project name is given, all
  configured containers are restarted.

  Implemented as stop -> start, so it reuses the proven per-project flows:
  backend bring-up, hidden-volume re-verification (important on backends like
  OrbStack), and SSH-key re-injection all apply. Functionally equivalent to
  `dc stop <name> && dc start <name>`.

Arguments:
  [name ...]  One or more project names to restart. If omitted, all
              configured containers are restarted.

Examples:
  dc restart              Restart all containers
  dc restart myapp        Restart only myapp
  dc restart web api db   Restart multiple containers

Notes:
  - A stopped container is started; a running container is stopped and started.
  - Restarting preserves the container filesystem (no rebuild). Use
    `dc rebuild-container` to recreate from the image.
EOF
}

_show_help_rm() {
  cat <<'EOF'
Usage: dc rm <name> [--yes|-y] [--keep-config] [--keep-volumes]

Description:
  Removes a dev container project. By default this performs a full teardown:

    1. stops the container if it is running, then deletes it
    2. removes every managed hidden volume (dc-hide-<project>-<hash>)
    3. removes the per-project config + secrets directory
       (~/.config/dev-containers/<name>), including the SSH key, GitHub token,
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
  dc rm myapp                       Remove everything (prompts to confirm)
  dc rm myapp --yes                 Remove everything without prompting
  dc rm myapp --keep-config         Remove container + volumes, keep config/secrets
  dc rm myapp --keep-volumes        Remove container + config/secrets, keep volumes

Notes:
  - Host code at $REPOS_DIR is preserved. Remove it manually if no longer
    needed:  rm -rf "${DC_REPOS_DIR:-$HOME/repos}/<name>"
  - The generated .devcontainer/devcontainer.json lives under $REPOS_DIR and is
    likewise preserved.
  - To recreate a removed project, run `dc new <name> [scope] ...` again.
  - To wipe only the container filesystem while keeping config and code, use
    `dc rebuild-container <name>` instead.
EOF
}

_show_help_rebuild_container() {
  cat <<'EOF'
Usage: dc rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes]

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
    dc rebuild-image all

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

Examples:
  dc rebuild-container myapp
  dc rebuild-container myapp --rotate-keys
  dc rebuild-container myapp --keep-hidden-volumes
  dc rebuild-container myapp --rotate-keys --keep-hidden-volumes

Notes:
  - This is DESTRUCTIVE to the container filesystem. Uncommitted work inside
    the container will be lost. Commit or push from the host repos dir first.
  - Your code on the host ($REPOS_DIR) is safe - it is a bind mount.
  - Hidden volumes are removed by default unless --keep-hidden-volumes is set.
  - Re-apply dotfiles after rebuild with 'dc install <name> <path>'.
  - You will be prompted to type 'yes' to confirm before destruction.
EOF
}

_show_help_rebuild_image() {
  cat <<'EOF'
Usage: dc rebuild-image [all|base]

Description:
  Rebuilds managed images for the active backend.

Arguments:
  [all|base]
    all  Rebuild dev-base:latest and all configured derived images
         (default)
    base Rebuild dev-base:latest only

Examples:
  dc rebuild-image
  dc rebuild-image all
  dc rebuild-image base

Notes:
  - Requires a reachable container backend.
  - 'all' scans all project configs and rebuilds every derived image currently
    selected by configured scope sets.
  - After rebuilding images, run 'dc rebuild-container <name>' for containers
    you want to recreate.
EOF
}

_show_help_clean() {
  cat <<'EOF'
Usage: dc clean [--dry-run]

       dc clean [--dry-run] [--hidden-volumes [name]]

Description:
  Cleans managed image tags and orphan managed image repos.

  Hidden volume mode:
  - --hidden-volumes enables orphan hidden-volume cleanup.
  - Optional [name] scopes cleanup to one project.
  - Hidden volume names are managed as dc-hide-<project>-<hash>.

  Rules:
  - Expected managed repos (dev-base + currently configured derived repos):
    keep latest, remove non-latest tags.
  - Orphan managed repos (no longer expected):
    remove all tags, including latest.

Options:
  --dry-run   Show what would be removed without deleting anything.

  --hidden-volumes
              Operate on hidden volumes instead of managed image tags.
              Optional trailing project name narrows cleanup to one project.

Examples:
  dc clean --dry-run
  dc clean
  dc clean --hidden-volumes --dry-run
  dc clean --hidden-volumes myproject

Notes:
  - Managed repos are dev-base and dev-img-<16hex>.
  - Images currently in use may fail to remove; those failures are reported.
  - Hidden volume cleanup removes only orphan managed hidden volumes.
  - Requires a reachable container backend.
EOF
}

_show_help_network() {
  cat <<'EOF'
Usage: dc network <create|ls|members|rm|add|remove> ...

Description:
  Manages private networks that let dc containers talk to each other without
  publishing any port to the host. Linking is explicit: containers are isolated
  by default and only reach peers when placed on the same network on purpose.

  Create a network, then attach containers to it:
    dc network create myapp
    dc new myapp-db --network myapp
    dc new myapp-web --network myapp
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

  ls | list                   List networks and their dc members.

  members <name>              Show which projects are on a network.

  rm <name> [--force]         Remove a network. Refuses while dc projects still
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
  - Networks are daemon objects; use `dc network ls` to see them.
  - On apple/container, use --network at `dc new` time (live add/remove and
    static IPs are not supported); a single network per container.
  - Containers with no --network are not linked to any dc peer.
EOF
}

_show_help_install() {
  cat <<'EOF'
Usage: dc install <name> <path>

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
  dc install myapp ~/dotfiles
  dc install myapp ~/.config/zsh
  dc install myapp ../my-dotfiles-repo

Notes:
  - The container must be running. Start it first with 'dc start <name>'.
  - The dotfiles directory must contain an install.sh file.
  - Re-run after any rebuild to reapply your personal config.
  - install.sh runs as the 'dev' user inside the container.
EOF
}

_show_help_help() {
  cat <<'EOF'
Usage: dc help [command]

Description:
  Displays help information. With no argument, shows a summary of all
  available commands. With a command name, shows detailed usage information
  for that specific command including arguments, options, examples, and notes.

Arguments:
  [command]  Optional command name to show detailed help for. One of:
             new, start, stop, status, list, shell, logs, exec, restart, rm,
             rebuild-container, rebuild-image, clean, network, install, version, help

Aliases:
  --help     Same as 'dc help'
  -h         Same as 'dc help'

Examples:
  dc help
  dc help install
  dc help rebuild-container

Notes:
  - Running 'dc' with no arguments also shows the summary.
EOF
}

_show_help_version() {
  cat <<'EOF'
Usage: dc version

Description:
  Prints the dev-containers version and exits.

Aliases:
  --version   same as 'dc version'
  -v          same as 'dc version'

Examples:
  dc version
  dc --version
  dc -v

Notes:
  - The version string is the single source of truth in lib/common.sh (DC_VERSION).
  - It is bumped in the same commit that tags a release (e.g. git tag v0.1.0).
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
  clean)              _show_help_clean ;;
  network|net)        _show_help_network ;;
  install)            _show_help_install ;;
  version|--version|-v) _show_help_version ;;
  help|--help|-h)     _show_help_help ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'dc help' for a list of available commands."
    exit 1
    ;;
esac
