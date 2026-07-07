#!/usr/bin/env bash
# =============================================================================
# scripts/extensions.sh - `dce extensions`: inspect, compare, and capture
# editor extensions for a project against per-scope manifests.
#
# Extensions are declared in manifests under
#   $DC_TEAM_DIR/extensions/<editor>/<scope>.txt  (layered first per scope)
#   $DC_USER_DIR/extensions/<editor>/<scope>.txt  (layered second per scope)
# and seeded/synced into .devcontainer/devcontainer.json by `dce new` /
# `dce config sync-vscode`. This command is the operational surface for
# bootstrapping those manifests and inspecting runtime vs declared state.
#
# Subcommands:
#   list <project>       extensions installed in the project's container
#   host                 extensions installed on the host editor
#   available <project>  host minus container (greyed-out "Install in container" set)
#   show <project>       merged effective manifest set (what sync writes)
#   diff <project>       runtime drift: installed-vs-declared, both directions
#   capture <project> --scope <s> (--all | <id>...) [--user|--team]
#                        merge IDs into a manifest (selective by default)
#
# v1 supports the vscode editor only. Container-derived ops require a
# Docker-compatible backend + a running container (no auto-start); static ops
# (host/show/capture with explicit IDs) are backend-agnostic. See
# plans/extensions.md.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Bootstrap: resolve script/repo dirs and source the libs. container-backend
# is needed so the dispatch helpers in lib/extensions.sh can call backend_exec.
# ---------------------------------------------------------------------------
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
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/container-backend.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/extensions.sh"

USAGE() {
  cat <<'EOF'
Usage: dce extensions <subcommand> [flags] [<project>] [ids...]

Inspect, compare, and capture editor extensions for a project against per-scope
manifests under $DC_{TEAM,USER}_DIR/extensions/<editor>/<scope>.txt.

Subcommands:
  list <project>              Extensions installed in the project's container.
  host                        Extensions installed on the host editor.
  available <project>         Host minus container (the "Install in Dev Container"
                              set VS Code shows greyed-out).
  show <project>              Merged effective manifest set (what sync writes).
  diff <project>              Runtime drift in both directions: installed but not
                              declared, and declared but not installed.
  capture <project> --scope <scope> (--all | <id>...) [--user|--team]
                              Merge extension IDs into a manifest. Selective by
                              default (explicit IDs); --all snapshots the
                              container's installed set (migration helper).

Flags:
  --editor <id>               Editor id (default: vscode). v1 supports vscode.
  --format ids|manifest|json  Output format for list/host/available/show
                              (default: ids). diff is always human-readable.
  --scope <scope>             Target scope for capture (validated name).
  --user | --team             Manifest root for capture (default: --user).
  --all                       capture: snapshot the full container install set.
  -h, --help                  Show this help.

Container-derived ops (list, available, diff, capture --all) require a
Docker-compatible backend and a running container (they do not auto-start).
Static ops (host, show, capture with explicit IDs) are backend-agnostic.

Examples:
  dce extensions show myapp
  dce extensions list myapp --format json
  dce extensions available myapp
  dce extensions diff myapp
  dce extensions capture myapp --scope nodejs esbenp.prettier-vscode
  dce extensions capture myapp --scope all --all
EOF
}

usage_die() {
  local msg="$1"
  dce_die "$msg
Usage: dce extensions <subcommand> [flags] [<project>] [ids...]"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SUBACTION="${1:-}"
[[ $# -gt 0 ]] && shift

EDITOR_OPT=""
FORMAT="ids"
SCOPE=""
TARGET=""
ALL=false
PROJECT=""
IDS=()
WANT_HELP=false
SET_USER=false
SET_TEAM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --editor)        [[ $# -ge 2 ]] || dce_die "--editor requires a value"; EDITOR_OPT="$2"; shift 2 ;;
    --editor=*)      EDITOR_OPT="${1#--editor=}"; shift ;;
    --format)        [[ $# -ge 2 ]] || dce_die "--format requires a value"; FORMAT="$2"; shift 2 ;;
    --format=*)      FORMAT="${1#--format=}"; shift ;;
    --scope)         [[ $# -ge 2 ]] || dce_die "--scope requires a value"; SCOPE="$2"; shift 2 ;;
    --scope=*)       SCOPE="${1#--scope=}"; shift ;;
    --user)          SET_USER=true; TARGET=user; shift ;;
    --team)          SET_TEAM=true; TARGET=team; shift ;;
    --all)           ALL=true; shift ;;
    -h|--help|help)  WANT_HELP=true; shift ;;
    --*)             usage_die "Unknown option: $1" ;;
    *)
      if [[ -z "$PROJECT" ]]; then
        PROJECT="$1"
      else
        IDS+=("$1")
      fi
      shift
      ;;
  esac
done

if [[ -z "$SUBACTION" ]] || $WANT_HELP; then
  USAGE
  exit 0
fi
# -h/--help/help as the subcommand (e.g. `dce extensions --help`) also shows usage.
case "$SUBACTION" in
  -h|--help|help) USAGE; exit 0 ;;
esac

# --user and --team select the same (single) manifest root; allowing both would
# silently let "last one wins" mask a typo. This semantic validation runs only
# after help handling, so `--help` always exits 0 even with extra flags.
if $SET_USER && $SET_TEAM; then
  dce_die "--user and --team are mutually exclusive (pick one manifest root)."
fi

# Resolve the editor id: default -> normalize -> validate against the
# extension-supported subset (separate from the launcher registry).
if [[ -z "$EDITOR_OPT" ]]; then
  EDITOR="$(dce_ext_default_editor)"
else
  EDITOR="$(dce_ext_normalize_editor "$EDITOR_OPT")"
fi
if ! dce_ext_is_supported "$EDITOR"; then
  dce_die "extension management for editor '$EDITOR' is not supported.
  Supported editors: $(tr '\n' ' ' <<<"$(dce_ext_supported_editors)")"
fi

# ---------------------------------------------------------------------------
# Shared handlers
# ---------------------------------------------------------------------------

# Load a project's config only. Static subcommands (show, capture with explicit
# IDs) must not require backend selection/CLI availability.
_load_project() {
  local project="$1"
  local config="$HOME/.config/dce-enclave/$project/config"
  if [[ ! -f "$config" ]]; then
    dce_die "No config for project '$project'.
       Run 'dce new $project ...' first, or 'dce config ls' for projects."
  fi
  dce_load_project_config "$config"
}

# Resolve and select the project's backend (runtime/container-derived ops only).
_select_backend() {
  backend_use "${CONTAINER_BACKEND:-}"
  ACTIVE_BACKEND="$(backend_name)"
}

# Refuse on apple/container (no Docker API -> editor cannot attach). Assumes the
# project is already loaded.
_refuse_apple() {
  if ! backend_is_docker_compatible "$ACTIVE_BACKEND"; then
    dce_die "'dce extensions $SUBACTION' is unsupported on backend '$ACTIVE_BACKEND'.
       apple/container is not Docker-API compatible, so the editor cannot
       attach and there is no container extension store to read.
       Use a Docker-compatible backend (docker/orbstack/colima/podman)."
  fi
}

_skip_diff() {
  local why="$1"
  echo "SKIP: $why"
  exit 0
}

_reject_unexpected_ids() {
  local cmd="$1"
  if [[ ${#IDS[@]} -gt 0 ]]; then
    dce_die "'dce extensions $cmd' does not accept extra positional arguments: ${IDS[*]}"
  fi
}

# Require the project container to be running. Does NOT auto-start (extension
# ops are read-only snapshots; a stale start decision is left to the user).
_require_running() {
  if ! backend_is_running "$PROJECT"; then
    dce_die "container '$PROJECT' is not running.
       Start it first: dce start $PROJECT"
  fi
}

_load_global() {
  dce_load_global_config
}

# Per-OS hint for a missing host VS Code `code` binary. Mirrors the per-platform
# guidance in lib/editor.sh (dce_editor_launch_attach) so macOS/Linux/WSL2 users
# each see the actionable instruction for their setup.
_host_bin_hint() {
  case "$(platform_os 2>/dev/null || printf unknown)" in
    macos)
      cat <<'EOF'
       On macOS: run VS Code's "Install 'code' command in PATH" command from the
       Command Palette, or set DCE_EDITOR_BIN=/path/to/code.
EOF
      ;;
    wsl2)
      cat <<'EOF'
       On WSL2: ensure 'code.exe' (Windows VS Code) or 'code' (Linux VS Code) is
       on PATH, or set DCE_EDITOR_BIN=/path/to/code.
EOF
      ;;
    *)
      cat <<'EOF'
       Ensure 'code' is on PATH, or set DCE_EDITOR_BIN=/path/to/code.
EOF
      ;;
  esac
}

# Run a resolver and load its newline-delimited stdout into the named array,
# PROPAGATING the resolver's exit status. A bare `mapfile -t X < <(cmd)` would
# swallow cmd's failure (process-substitution exit codes are ignored), silently
# turning a real error (e.g. the container having no `code` CLI because VS Code
# was never attached) into an empty result. Empty stdout -> empty array.
_load_lines() {
  local -n _ll_ref="$1"
  shift
  local _ll_out=""
  _ll_out="$("$@")" || return 1
  _ll_ref=()
  [[ -n "$_ll_out" ]] && mapfile -t _ll_ref <<< "$_ll_out"
  return 0
}

# ---------------------------------------------------------------------------
# Subcommand dispatch
# ---------------------------------------------------------------------------
case "$SUBACTION" in
  # -------------------------------------------------------------------------
  # show: merged effective manifest set (static; backend-agnostic).
  # -------------------------------------------------------------------------
  show)
    [[ -n "$PROJECT" ]] || dce_die "'dce extensions show' requires <project>"
    _reject_unexpected_ids show
    _load_project "$PROJECT"
    _load_global
    SET=()
    if ! _load_lines SET dce_ext_resolve_set "$EDITOR" "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}"; then
      dce_die "could not resolve the extension manifest set for '$PROJECT'."
    fi
    dce_ext_format "$FORMAT" "$EDITOR" "${SET[@]}"
    ;;

  # -------------------------------------------------------------------------
  # list: installed in the container (runtime; docker-only + running).
  # -------------------------------------------------------------------------
  list)
    [[ -n "$PROJECT" ]] || dce_die "'dce extensions list' requires <project>"
    _reject_unexpected_ids list
    _load_project "$PROJECT"
    _select_backend
    _refuse_apple
    _require_running
    INSTALLED=()
    if ! _load_lines INSTALLED dce_ext_list_installed "$EDITOR" "$PROJECT"; then
      dce_die "could not list extensions in '$PROJECT'.
       Could not resolve a VS Code Server 'code' CLI inside the container.
       Attach in VS Code once (Dev Containers: Attach to Running Container),
       then rerun. If already attached, ensure ~/.vscode-server exists for
       the runtime user and contains bin/*/bin/code."
    fi
    dce_ext_format "$FORMAT" "$EDITOR" "${INSTALLED[@]}"
    ;;

  # -------------------------------------------------------------------------
  # host: installed on the host editor (static; no project, no backend).
  # -------------------------------------------------------------------------
  host)
    if [[ -n "$PROJECT" || ${#IDS[@]} -gt 0 ]]; then
      dce_die "'dce extensions host' takes no <project> or positional arguments."
    fi
    if ! tmp_host="$(mktemp)"; then dce_die "mktemp failed"; fi
    trap 'rm -f "$tmp_host"' EXIT
    if ! dce_ext_list_host "$EDITOR" > "$tmp_host" 2>/dev/null; then
      _host_bin_hint >&2
      rm -f "$tmp_host"
      dce_die "host 'code' binary not found."
    fi
    mapfile -t HOST < <(cat "$tmp_host")
    dce_ext_format "$FORMAT" "$EDITOR" "${HOST[@]}"
    ;;

  # -------------------------------------------------------------------------
  # available: host minus container (runtime; docker-only + running).
  # -------------------------------------------------------------------------
  available)
    [[ -n "$PROJECT" ]] || dce_die "'dce extensions available' requires <project>"
    _reject_unexpected_ids available
    _load_project "$PROJECT"
    _select_backend
    _refuse_apple
    _require_running
    INSTALLED=()
    if ! _load_lines INSTALLED dce_ext_list_installed "$EDITOR" "$PROJECT"; then
      dce_die "could not list extensions in '$PROJECT'.
       Could not resolve a VS Code Server 'code' CLI inside the container.
       Attach in VS Code once (Dev Containers: Attach to Running Container),
       then rerun. If already attached, ensure ~/.vscode-server exists for
       the runtime user and contains bin/*/bin/code."
    fi
    # Host list is best-effort; if the host binary is missing, available is
    # meaningless -> surface the same guidance as `host`.
    if ! tmp_avail="$(mktemp)"; then dce_die "mktemp failed"; fi
    if ! dce_ext_list_host "$EDITOR" > "$tmp_avail" 2>/dev/null; then
      _host_bin_hint >&2
      rm -f "$tmp_avail"
      dce_die "host 'code' binary not found; cannot compute available set."
    fi
    mapfile -t AVAIL < <(cat "$tmp_avail" | dce_ext_minus "${INSTALLED[@]}")
    rm -f "$tmp_avail"
    dce_ext_format "$FORMAT" "$EDITOR" "${AVAIL[@]}"
    ;;

  # -------------------------------------------------------------------------
  # diff: runtime drift both directions (runtime; docker-only + running).
  # -------------------------------------------------------------------------
  diff)
    [[ -n "$PROJECT" ]] || dce_die "'dce extensions diff' requires <project>"
    _reject_unexpected_ids diff
    _load_project "$PROJECT"
    # The apple skip is decided by backend TYPE, not by CLI availability, so check
    # docker-compatibility from the loaded config value before _select_backend
    # (which validates the backend CLI is installed). Otherwise an apple project
    # whose `container` CLI is absent dies here instead of skipping cleanly.
    if ! backend_is_docker_compatible "${CONTAINER_BACKEND:-}"; then
      _skip_diff "runtime drift unavailable on backend '${CONTAINER_BACKEND:-(unknown)}' (apple/container has no attach-mode extension store)"
    fi
    _select_backend
    if ! backend_is_running "$PROJECT"; then
      _skip_diff "container '$PROJECT' is not running (start it first to check runtime drift)"
    fi
    _load_global
    DECLARED=()
    if ! _load_lines DECLARED dce_ext_resolve_set "$EDITOR" "$DC_TEAM_DIR" "$DC_USER_DIR" "${CONTAINER_OVERLAY_SCOPES:-}"; then
      dce_die "could not resolve the extension manifest set for '$PROJECT'."
    fi
    INSTALLED=()
    if ! _load_lines INSTALLED dce_ext_list_installed "$EDITOR" "$PROJECT"; then
      _skip_diff "could not resolve a VS Code Server code CLI in '$PROJECT' (attach once in VS Code, then rerun)"
    fi
    # Set math on in-memory arrays: deterministic, so the bare mapfile pattern
    # here is safe (no external command whose failure could be masked).
    mapfile -t UNDECLARED < <(printf '%s\n' "${INSTALLED[@]}" | dce_ext_minus "${DECLARED[@]}")
    mapfile -t MISSING < <(printf '%s\n' "${DECLARED[@]}" | dce_ext_minus "${INSTALLED[@]}")

    echo "Editor: $EDITOR    Project: $PROJECT"
    echo ""
    echo "Installed in container but not declared (run capture to keep them):"
    if [[ ${#UNDECLARED[@]} -gt 0 ]]; then
      for e in "${UNDECLARED[@]}"; do printf '  %s\n' "$e"; done
    else
      echo "  (none)"
    fi
    echo ""
    echo "Declared but not installed (will converge on next editor open):"
    if [[ ${#MISSING[@]} -gt 0 ]]; then
      for e in "${MISSING[@]}"; do printf '  %s\n' "$e"; done
    else
      echo "  (none)"
    fi
    if [[ ${#UNDECLARED[@]} -gt 0 ]]; then
      echo ""
      echo "Tip: capture undeclared extensions before a rebuild, or they will be lost:"
      echo "  dce extensions capture $PROJECT --scope <scope> ${UNDECLARED[*]}"
    fi
    ;;

  # -------------------------------------------------------------------------
  # capture: merge IDs into a manifest (selective default; --all = snapshot).
  # -------------------------------------------------------------------------
  capture)
    [[ -n "$PROJECT" ]] || dce_die "'dce extensions capture' requires <project>"
    [[ -n "$SCOPE" ]] || dce_die "'dce extensions capture' requires --scope <scope>"
    if ! dce_validate_scope_name "$SCOPE"; then
      dce_die "invalid scope name '$SCOPE'.
  Allowed pattern: ^[a-z0-9][a-z0-9._-]*\$"
    fi
    _load_project "$PROJECT"
    _load_global

    if $ALL && [[ ${#IDS[@]} -gt 0 ]]; then
      dce_die "'dce extensions capture' accepts either --all OR explicit <id>..., not both."
    fi

    # Determine the source of IDs: --all reads from the running container;
    # otherwise the explicit positional IDs.
    NEW_IDS=()
    if $ALL; then
      _select_backend
      _refuse_apple
      _require_running
      NEW_IDS=()
      if ! _load_lines NEW_IDS dce_ext_list_installed "$EDITOR" "$PROJECT"; then
        dce_die "could not list extensions in '$PROJECT'.
       Could not resolve a VS Code Server 'code' CLI inside the container.
       Attach in VS Code once (Dev Containers: Attach to Running Container),
       then rerun. If already attached, ensure ~/.vscode-server exists for
       the runtime user and contains bin/*/bin/code."
      fi
    else
      NEW_IDS=("${IDS[@]}")
      if [[ ${#NEW_IDS[@]} -eq 0 ]]; then
        dce_die "'dce extensions capture' needs explicit <id>... or --all.
       (refusing to bulk-dump host extensions; the manifest is curated)"
      fi
    fi

    # Target root: --team selects DC_TEAM_DIR, otherwise DC_USER_DIR.
    if [[ "$TARGET" == "team" ]]; then
      ROOT="$DC_TEAM_DIR"
    else
      ROOT="$DC_USER_DIR"
    fi
    FILE="$(dce_ext_manifest_path "$ROOT" "$EDITOR" "$SCOPE")"
    mkdir -p "$(dirname "$FILE")"

    # Existing IDs in the file (to de-dup against).
    declare -A existing=()
    if [[ -f "$FILE" ]]; then
      while IFS= read -r e; do
        [[ -n "$e" ]] && existing["$e"]=1
      done < <(dce_ext_parse_manifest "$FILE")
    fi

    # Genuinely-new IDs, sorted + de-duped. Reject malformed IDs up front so a
    # typo (space, '#', missing dot) cannot corrupt the manifest.
    add=()
    declare -A seen_new=()
    for id in "${NEW_IDS[@]}"; do
      [[ -n "$id" ]] || continue
      if ! dce_ext_is_valid_id "$id"; then
        dce_die "'$id' is not a valid extension id (expected publisher.name)."
      fi
      [[ -n "${existing[$id]:-}" ]] && continue
      [[ -n "${seen_new[$id]:-}" ]] && continue
      seen_new["$id"]=1
      add+=("$id")
    done

    if [[ ${#add[@]} -eq 0 ]]; then
      echo "No new extensions to add to $FILE"
      echo "(all ${#NEW_IDS[@]} supplied id(s) already present or empty)"
      exit 0
    fi
    mapfile -t add_sorted < <(printf '%s\n' "${add[@]}" | LC_ALL=C sort)

    # Preserve the existing file byte-for-byte; ensure it ends with a newline,
    # then append the new IDs (one per line).
    if [[ -f "$FILE" ]] && [[ -s "$FILE" ]]; then
      # command substitution strips trailing newlines, so a file that already
      # ends in "\n" yields an empty string here.
      last_char="$(tail -c1 "$FILE" || true)"
      [[ -z "$last_char" ]] || printf '\n' >> "$FILE"
    fi
    {
      for id in "${add_sorted[@]}"; do
        printf '%s\n' "$id"
      done
    } >> "$FILE"

    echo "Added ${#add_sorted[@]} extension(s) to $FILE"
    if $ALL; then
      echo "(snapshot of container '$PROJECT' installed set)"
    fi
    echo "Next: dce config sync-vscode $PROJECT"
    ;;

  *)
    echo "Unknown extensions subcommand: $SUBACTION" >&2
    echo "Run 'dce extensions --help' for usage." >&2
    exit 1
    ;;
esac
