#!/usr/bin/env bash
# =============================================================================
# help.sh - Display help summary or detailed help for a specific command
# =============================================================================
set -euo pipefail

COMMAND="${1:-}"

_show_summary() {
  echo "Usage: dc <command> [args]"
  echo ""
  echo "Commands:"
  echo "  new <name> [scope[,scope...]] [host:container ...]"
  echo "                                                    Create new project"
  echo "  new <name> [scope[,scope...]] [--repo-path <path>]"
  echo "       [--cpus <N>] [--memory <val>] [--hide <path[,path...]> ...] [host:container ...]"
  echo "                                                    With resource limits"
  echo "  start [name]                                      Start project(s)"
  echo "  stop [name]                                       Stop project(s)"
  echo "  list                                              List containers and status"
  echo "  status                                            Show detailed status"
  echo "  shell <name> [cmd]                                Open shell or run command"
  echo "  rebuild-container <name> [--rotate-keys] [--keep-hidden-volumes]"
  echo "                                                    Destroy and recreate container"
  echo "  rebuild-image [all|base]                          Rebuild managed images"
  echo "  clean [--dry-run] [--hidden-volumes [name]]       Remove old/orphan image tags or orphan hidden volumes"
  echo "  install <name> <path>                             Install dotfiles"
  echo "  help [command]                                    Show this help or detailed help"
  echo ""
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
  - Backend (Docker, Colima, OrbStack, Podman, apple/container)
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
              WARNING: combining this with --rotate-keys will produce a
              loud warning, since key rotation implies incident response
              where preserving volumes may be unsafe.

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
             new, start, stop, status, list, shell, rebuild-container,
             rebuild-image, clean, install, help

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
  rebuild-container)  _show_help_rebuild_container ;;
  rebuild-image)      _show_help_rebuild_image ;;
  clean)              _show_help_clean ;;
  install)            _show_help_install ;;
  help|--help|-h)     _show_help_help ;;
  *)
    echo "Unknown command: $COMMAND"
    echo "Run 'dc help' for a list of available commands."
    exit 1
    ;;
esac
