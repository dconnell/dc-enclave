#!/usr/bin/env bash
# =============================================================================
# tests/contract/repo.sh - `dce repo` command family behavior.
#
# Backend-free config-mutation coverage for the schema-v2 repo surfaces:
#   - list shows the configured repo set
#   - add accepts <path> and <name>=<path>
#   - remove accepts either repo name or exact path
#   - mutations validate overlap/dup uniqueness within one project only
#   - every mutating command prints the rebuild-container follow-up guidance
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
chmod 700 "$WORK"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

dce_repo_cmd() {
  (HOME="$FAKE_HOME" DC_REPOS_DIR="$FAKE_HOME/repos" bash "$ROOT_DIR/scripts/repo.sh" "$@")
}

dce_repo_cmd_in() {
  local input="$1"
  shift
  (HOME="$FAKE_HOME" DC_REPOS_DIR="$FAKE_HOME/repos" bash "$ROOT_DIR/scripts/repo.sh" "$@" <<< "$input")
}

write_project_config() {
  local project="$1"
  shift
  local dir="$FAKE_HOME/.config/dce-enclave/$project"
  mkdir -p "$dir"
  chmod 700 "$dir"
  {
    echo '# DC Enclave config'
    printf 'CONTAINER_PROJECT="%s"\n' "$project"
    echo 'CONTAINER_BACKEND="docker"'
    echo 'CONTAINER_IMAGE="dce-base:latest"'
    echo 'CONFIG_SCHEMA_VERSION="2"'
    printf 'REPO_NAMES=('; printf ' %q' "$@"; printf ' )\n'
    local name=""
    printf 'REPO_PATHS=(' 
    for name in "$@"; do
      printf ' %q' "$FAKE_HOME/repos/$name"
    done
    printf ' )\n'
    echo 'PORTS=()'
    echo 'CONTAINER_HIDDEN_PATHS=()'
    echo 'CONTAINER_NETWORKS=()'
  } > "$dir/config"
  chmod 600 "$dir/config"
}

load_cfg() {
  local project="$1"
  local cfg="$FAKE_HOME/.config/dce-enclave/$project/config"
  # shellcheck disable=SC2034  # reset-before-load hygiene for globals sourced by the loader
  PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=() REPO_NAMES=() REPO_PATHS=()
  dce_load_project_config "$cfg"
}

# ============================================================================
# list
# ============================================================================
write_project_config listproj web api
out="$(dce_repo_cmd list listproj)" || fail "repo list exited non-zero"
printf '%s\n' "$out" | grep -Fxq "web=$FAKE_HOME/repos/web" || fail "repo list missing web entry"
printf '%s\n' "$out" | grep -Fxq "api=$FAKE_HOME/repos/api" || fail "repo list missing api entry"
pass "repo list shows name=path lines"

# ============================================================================
# add <path>
# ============================================================================
write_project_config addpathproj web
mkdir -p "$FAKE_HOME/repos/tools"
out="$(dce_repo_cmd add addpathproj "$FAKE_HOME/repos/tools")" || fail "repo add <path> exited non-zero"
printf '%s\n' "$out" | grep -qi 'rebuild-container addpathproj' || fail "repo add <path> missing rebuild guidance"
load_cfg addpathproj
expected_tools_path="$(dce_resolve_path "$FAKE_HOME/repos/tools")"
[[ "${REPO_NAMES[1]:-}" == "tools" ]] || fail "repo add <path> should derive basename repo name (got ${REPO_NAMES[*]:-})"
[[ "${REPO_PATHS[1]:-}" == "$expected_tools_path" ]] || fail "repo add <path> should persist the canonical path"
pass "repo add <path> derives basename name and persists"

# ============================================================================
# add <name>=<path>
# ============================================================================
write_project_config addnamedproj web
mkdir -p "$FAKE_HOME/repos/company-api"
out="$(dce_repo_cmd add addnamedproj api="$FAKE_HOME/repos/company-api")" || fail "repo add name=path exited non-zero"
printf '%s\n' "$out" | grep -qi 'rebuild-container addnamedproj' || fail "repo add name=path missing rebuild guidance"
load_cfg addnamedproj
expected_api_path="$(dce_resolve_path "$FAKE_HOME/repos/company-api")"
[[ "${REPO_NAMES[1]:-}" == "api" ]] || fail "repo add name=path should preserve explicit name"
[[ "${REPO_PATHS[1]:-}" == "$expected_api_path" ]] || fail "repo add name=path should persist canonical path"
pass "repo add name=path preserves explicit name"

# ============================================================================
# add creates a missing target directory before writing config
# ============================================================================
# A repo that has not been cloned yet must still get its bind source created
# by dce itself; otherwise a rebuild lets the backend create a root-owned dir.
write_project_config addmkdirproj web
missing_dir="$FAKE_HOME/repos/not-cloned-yet"
rm -rf "$missing_dir"
out="$(dce_repo_cmd add addmkdirproj "$missing_dir")" || fail "repo add with missing target dir exited non-zero"
[[ -d "$missing_dir" ]] || fail "repo add should create the missing target directory"
load_cfg addmkdirproj
expected_missing_path="$(dce_resolve_path "$missing_dir")"
[[ "${REPO_NAMES[1]:-}" == "not-cloned-yet" ]] || fail "repo add with missing dir should derive basename name (got ${REPO_NAMES[*]:-})"
[[ "${REPO_PATHS[1]:-}" == "$expected_missing_path" ]] || fail "repo add with missing dir should persist canonical path"
pass "repo add creates a missing target directory"

# ============================================================================
# add outside default repos root => prompt unless --yes; repos root/ancestor are rejected
# ============================================================================
write_project_config addgateproj web
mkdir -p "$FAKE_HOME/src/extrepo"
out="$(dce_repo_cmd_in $'yes\n' add addgateproj "$FAKE_HOME/src/extrepo")" || fail "repo add outside default root should honor interactive yes"
printf '%s\n' "$out" | grep -qi 'requires confirmation' || fail "repo add outside default root should prompt"
load_cfg addgateproj
expected_extrepo_path="$(dce_resolve_path "$FAKE_HOME/src/extrepo")"
[[ "${REPO_PATHS[1]:-}" == "$expected_extrepo_path" ]] || fail "repo add outside default root should persist the confirmed path"
pass "repo add outside default repos dir prompts and honors interactive yes"

write_project_config addgatedenyproj web
mkdir -p "$FAKE_HOME/src/extrepo-deny"
out="$(dce_repo_cmd_in $'no\n' add addgatedenyproj "$FAKE_HOME/src/extrepo-deny" 2>&1 || true)"
[[ "$out" == *"Aborted."* ]] || fail "repo add deny should abort with a message"
load_cfg addgatedenyproj
[[ ${#REPO_NAMES[@]} -eq 1 && "${REPO_NAMES[0]}" == "web" ]] || fail "repo add denied prompt must not mutate config"
pass "repo add outside default repos dir can be denied"

write_project_config addgateyesproj web
mkdir -p "$FAKE_HOME/src/extrepo-yes"
out="$(HOME="$FAKE_HOME" bash "$ROOT_DIR/scripts/repo.sh" add --yes addgateyesproj "$FAKE_HOME/src/extrepo-yes")" || fail "repo add --yes outside default root should honor the path"
printf '%s\n' "$out" | grep -qi 'honoring repo path' || fail "repo add --yes should print an explicit honoring message"
load_cfg addgateyesproj
expected_extrepo_yes_path="$(dce_resolve_path "$FAKE_HOME/src/extrepo-yes")"
[[ "${REPO_PATHS[1]:-}" == "$expected_extrepo_yes_path" ]] || fail "repo add --yes should persist the outside-root path"
pass "repo add outside default repos dir honored with --yes"

write_project_config addrootrejectproj web
if dce_repo_cmd add addrootrejectproj "$FAKE_HOME/repos" >/dev/null 2>"$WORK/addrootreject.err"; then
  fail "repo add must reject the repos root outright"
fi
grep -qi 'repos root' "$WORK/addrootreject.err" || fail "repo add repos-root rejection should explain the broad-mount rule"
pass "repo add rejects the repos root outright"

write_project_config addancestorrejectproj web
mkdir -p "$WORK/outer/repos"
if HOME="$FAKE_HOME" DC_REPOS_DIR="$WORK/outer/repos" \
   bash "$ROOT_DIR/scripts/repo.sh" add addancestorrejectproj "$WORK/outer" \
   >/dev/null 2>"$WORK/addancestorreject.err"; then
  fail "repo add must reject an ancestor of the repos root outright"
fi
grep -qi 'parent of it' "$WORK/addancestorreject.err" || fail "repo add ancestor rejection should explain the broad-mount rule"
pass "repo add rejects an ancestor of the repos root outright"

# ============================================================================
# remove by name
# ============================================================================
write_project_config rmnameproj web api
out="$(dce_repo_cmd remove rmnameproj api)" || fail "repo remove by name exited non-zero"
printf '%s\n' "$out" | grep -qi 'rebuild-container rmnameproj' || fail "repo remove by name missing rebuild guidance"
load_cfg rmnameproj
[[ "${REPO_NAMES[*]:-}" == "web" ]] || fail "repo remove by name should leave only web (got ${REPO_NAMES[*]:-})"
pass "repo remove by name updates config"

# ============================================================================
# remove by path
# ============================================================================
write_project_config rmpathproj web api
load_cfg rmpathproj
api_path="${REPO_PATHS[1]}"
out="$(dce_repo_cmd remove rmpathproj "$api_path")" || fail "repo remove by path exited non-zero"
printf '%s\n' "$out" | grep -qi 'rebuild-container rmpathproj' || fail "repo remove by path missing rebuild guidance"
load_cfg rmpathproj
[[ "${REPO_NAMES[*]:-}" == "web" ]] || fail "repo remove by path should leave only web (got ${REPO_NAMES[*]:-})"
pass "repo remove by path updates config"

# ============================================================================
# overlap / duplicate rejection within one project
# ============================================================================
write_project_config rejectproj web
load_cfg rejectproj
web_path="${REPO_PATHS[0]}"
mkdir -p "$web_path/packages/ui"
if dce_repo_cmd add rejectproj ui="$web_path/packages/ui" >/dev/null 2>&1; then
  fail "repo add must reject overlapping repo paths within one project"
fi

mkdir -p "$FAKE_HOME/repos/other"
if dce_repo_cmd add rejectproj web="$FAKE_HOME/repos/other" >/dev/null 2>&1; then
  fail "repo add must reject duplicate repo names within one project"
fi
pass "repo add rejects overlap and duplicate names within a project"

# ============================================================================
# same host path in different projects is allowed
# ============================================================================
shared_repo="$FAKE_HOME/shared/repo"
mkdir -p "$shared_repo"
shared_repo="$(dce_resolve_path "$shared_repo")"
write_project_config crossa web
write_project_config crossb web
out="$(HOME="$FAKE_HOME" DC_REPOS_DIR="$FAKE_HOME/repos" bash "$ROOT_DIR/scripts/repo.sh" add --yes crossa shared="$shared_repo")" || fail "cross-project add in first project failed"
out="$(HOME="$FAKE_HOME" DC_REPOS_DIR="$FAKE_HOME/repos" bash "$ROOT_DIR/scripts/repo.sh" add --yes crossb shared="$shared_repo")" || fail "cross-project add in second project failed"
load_cfg crossa
[[ "${REPO_PATHS[1]:-}" == "$shared_repo" ]] || fail "cross-project shared repo missing in first project"
load_cfg crossb
[[ "${REPO_PATHS[1]:-}" == "$shared_repo" ]] || fail "cross-project shared repo missing in second project"
pass "same host repo path is allowed across projects"

echo ""
echo "All dce repo checks passed."
