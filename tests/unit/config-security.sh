#!/usr/bin/env bash
# shellcheck disable=SC2016
# This file deliberately writes literal $/backtick command-substitution payloads
# into configs to prove they are treated as data, never executed.
# =============================================================================
# tests/unit/config-security.sh - M1 regression coverage.
#
# Proves that config content is treated as data, not an execution surface:
#   - cpus/memory input validation,
#   - robust serialization (escaping) of persisted values,
#   - hardened project-config loader (rejects payloads, accepts valid configs),
#   - schema-v2 repo model (REPO_NAMES/REPO_PATHS) and its failure modes,
#   - targeted rejection of legacy single-repo (REPOS_DIR) configs,
#   - safe global-config parsing (no source/eval during completion/setup).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

pass() {
  echo "PASS: $*"
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK" /tmp/m1-*-pwn 2>/dev/null || true' EXIT
chmod 700 "$WORK"

# Write a valid schema-v2 project config (quoted scalar assignments + array
# lines), used as a baseline that the loader must accept. cpus/memory are
# optional/empty by default.
write_valid_config() {
  local file="$1"
  local cpus="${2:-}"
  local mem="${3:-}"
  local dir=""
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  chmod 700 "$dir"
  {
    echo '# DC Enclave config'
    echo 'CONTAINER_PROJECT="testproj"'
    echo 'CONTAINER_OVERLAY_SCOPES=""'
    echo 'CONTAINER_IMAGE="dce-base:latest"'
    echo 'CONTAINER_BACKEND="docker"'
    echo "CONTAINER_CPUS=\"$cpus\""
    echo "CONTAINER_MEMORY=\"$mem\""
    echo 'CONFIG_SCHEMA_VERSION="2"'
    echo 'REPO_NAMES=(testproj)'
    echo "REPO_PATHS=($WORK/repos/testproj)"
    echo "SECRET_DIR=\"$WORK/secret\""
    echo "SSH_KEY_PATH=\"$WORK/secret/ssh_key\""
    echo "TOKEN_FILE=\"$WORK/secret/github-token\""
    echo "NPMRC_PATH=\"$WORK/secret/.npmrc\""
    echo 'PORTS=()'
    echo 'CONTAINER_HIDDEN_PATHS=()'
  } > "$file"
  chmod 600 "$file"
}

# Write a schema-v2 config with caller-supplied repo names and paths.
# Usage: write_v2_config FILE name1 [name2 ...] -- /path/one [/path/two ...]
# Everything before "--" lands in REPO_NAMES, everything after in REPO_PATHS,
# so malformed lists (length mismatch, empty) can be written deliberately.
write_v2_config() {
  local file="$1"
  shift
  local -a v2_names=() v2_paths=()
  local in_paths=0
  local arg=""
  for arg in "$@"; do
    if [[ "$arg" == "--" ]]; then
      in_paths=1
      continue
    fi
    if [[ "$in_paths" -eq 0 ]]; then
      v2_names+=("$arg")
    else
      v2_paths+=("$arg")
    fi
  done
  local dir=""
  dir="$(dirname "$file")"
  mkdir -p "$dir"
  chmod 700 "$dir"
  {
    echo '# DC Enclave config'
    echo 'CONTAINER_PROJECT="testproj"'
    echo 'CONTAINER_BACKEND="docker"'
    echo 'CONTAINER_IMAGE="dce-base:latest"'
    echo 'CONFIG_SCHEMA_VERSION="2"'
    printf 'REPO_NAMES=(%s)\n' "${v2_names[*]}"
    printf 'REPO_PATHS=(%s)\n' "${v2_paths[*]}"
    echo 'PORTS=()'
    echo 'CONTAINER_HIDDEN_PATHS=()'
  } > "$file"
  chmod 600 "$file"
}

# Assert the loader rejects a config: runs it in a subshell (the loader may
# dce_die on line-shape violations) and fails the test if the load succeeds.
expect_load_fail() {
  local desc="$1"
  local file="$2"
  if ( dce_load_project_config "$file" ) >/dev/null 2>&1; then
    fail "loader must reject $desc"
  fi
}

# --- cpus validator -----------------------------------------------------------
dce_validate_cpus_value "" || fail "empty cpus should be valid (means default)"
dce_validate_cpus_value "1" 2>/dev/null || fail "cpus '1' should be valid"
dce_validate_cpus_value "2" 2>/dev/null || fail "cpus '2' should be valid"
dce_validate_cpus_value "1.5" 2>/dev/null || fail "cpus '1.5' should be valid"
dce_validate_cpus_value "0.25" 2>/dev/null || fail "cpus '0.25' should be valid"
dce_validate_cpus_value "0" 2>/dev/null && fail "cpus '0' should be invalid"
dce_validate_cpus_value "-1" 2>/dev/null && fail "negative cpus should be invalid"
dce_validate_cpus_value "1e5" 2>/dev/null && fail "exponent cpus should be invalid"
dce_validate_cpus_value "1.5.2" 2>/dev/null && fail "multi-dot cpus should be invalid"
dce_validate_cpus_value '1 core' 2>/dev/null && fail "whitespace cpus should be invalid"
dce_validate_cpus_value '$(touch x)' 2>/dev/null && fail "command-subst cpus should be invalid"
dce_validate_cpus_value '2;rm' 2>/dev/null && fail "metachar cpus should be invalid"

# --- memory validator ---------------------------------------------------------
dce_validate_memory_value "" || fail "empty memory should be valid (means default)"
dce_validate_memory_value "512m" 2>/dev/null || fail "memory '512m' should be valid"
dce_validate_memory_value "4g" 2>/dev/null || fail "memory '4g' should be valid"
dce_validate_memory_value "1024" 2>/dev/null || fail "memory '1024' should be valid"
dce_validate_memory_value "100K" 2>/dev/null || fail "memory '100K' should be valid"
dce_validate_memory_value "0" 2>/dev/null && fail "memory '0' should be invalid"
dce_validate_memory_value "-4g" 2>/dev/null && fail "negative memory should be invalid"
dce_validate_memory_value "4t" 2>/dev/null && fail "unsupported suffix '4t' should be invalid"
dce_validate_memory_value "4gb" 2>/dev/null && fail "double-letter '4gb' should be invalid"
dce_validate_memory_value '$(touch x)' 2>/dev/null && fail "command-subst memory should be invalid"

pass "cpus/memory validators"

# --- serializer ---------------------------------------------------------------
# Backslash first, then quote, $, and backtick must all be escaped.
got="$(dce_escape_config_value 'a$b`c"d\e')" || fail "serializer failed"
expected='a\$b\`c\"d\\e'
[[ "$got" == "$expected" ]] || fail "serializer escape mismatch (got '$got', expected '$expected')"

# Control characters (incl. tab/newline) must be rejected, never silently emitted.
dce_escape_config_value $'a\tb' 2>/dev/null && fail "tab control char should be rejected"
dce_escape_config_value $'a\nb' 2>/dev/null && fail "newline control char should be rejected"

pass "config value serializer"

# --- escaped payload is inert when loaded -------------------------------------
# A serialized value containing $/backtick must round-trip as literal data and
# must NEVER execute during the load.
PAYLOAD='/tmp/foo$(touch /tmp/m1-esc-pwn)`touch /tmp/m1-esc-pwn2`bar'
rm -f /tmp/m1-esc-pwn /tmp/m1-esc-pwn2
ESC="$(dce_escape_config_value "$PAYLOAD")" || fail "escape payload failed"

cfg_esc="$WORK/escproj/config"
mkdir -p "$(dirname "$cfg_esc")"
chmod 700 "$(dirname "$cfg_esc")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'CONFIG_SCHEMA_VERSION="2"'
  echo 'REPO_NAMES=(testproj)'
  echo "REPO_PATHS=($WORK/repos/testproj)"
  echo "SECRET_DIR=\"$ESC\""
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_esc"
chmod 600 "$cfg_esc"

# Load in current shell so we can inspect the round-tripped variable. This call
# is expected to succeed, so dce_die (which would exit) must not fire.
dce_load_project_config "$cfg_esc"
[[ ! -e /tmp/m1-esc-pwn ]] || fail "escaped payload \$(...) executed during load"
[[ ! -e /tmp/m1-esc-pwn2 ]] || fail "escaped backtick payload executed during load"
[[ "${SECRET_DIR:-}" == "$PAYLOAD" ]] || fail "escaped value must round-trip (got '${SECRET_DIR:-}')"

pass "escaped values are inert and round-trip"

# --- malicious (unescaped) config line rejected before sourcing ---------------
rm -f /tmp/m1-malicious-pwn
cfg_mal="$WORK/malproj/config"
mkdir -p "$(dirname "$cfg_mal")"
chmod 700 "$(dirname "$cfg_mal")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'CONTAINER_CPUS="$(touch /tmp/m1-malicious-pwn)"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_mal"
chmod 600 "$cfg_mal"

if ( dce_load_project_config "$cfg_mal" ) >/dev/null 2>&1; then
  fail "loader must reject unescaped command substitution in config"
fi
[[ ! -e /tmp/m1-malicious-pwn ]] || fail "malicious line executed before rejection"

pass "malicious config line rejected before sourcing"

# --- non-assignment shell syntax rejected -------------------------------------
cfg_inject="$WORK/injectproj/config"
mkdir -p "$(dirname "$cfg_inject")"
chmod 700 "$(dirname "$cfg_inject")"
{
  echo 'CONTAINER_PROJECT="testproj"; rm -f /tmp/nope #'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_inject"
chmod 600 "$cfg_inject"
if ( dce_load_project_config "$cfg_inject" ) >/dev/null 2>&1; then
  fail "loader must reject trailing shell syntax after assignment"
fi

pass "non-assignment shell syntax rejected"

# --- unknown key rejected -----------------------------------------------------
cfg_unknown="$WORK/unknownproj/config"
mkdir -p "$(dirname "$cfg_unknown")"
chmod 700 "$(dirname "$cfg_unknown")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'EVIL_KEY="whatever"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_unknown"
chmod 600 "$cfg_unknown"
if ( dce_load_project_config "$cfg_unknown" ) >/dev/null 2>&1; then
  fail "loader must reject unknown config keys"
fi

pass "unknown config key rejected"

# --- symlinked config rejected ------------------------------------------------
cfg_link="$WORK/linkproj/config"
mkdir -p "$(dirname "$cfg_link")"
chmod 700 "$(dirname "$cfg_link")"
write_valid_config "$WORK/real_config"
ln -s "$WORK/real_config" "$cfg_link"
if ( dce_load_project_config "$cfg_link" ) >/dev/null 2>&1; then
  fail "loader must refuse to load a config via symlink"
fi

pass "symlinked config rejected"

# --- group/other-writable config rejected -------------------------------------
cfg_world="$WORK/worldproj/config"
mkdir -p "$(dirname "$cfg_world")"
chmod 700 "$(dirname "$cfg_world")"
write_valid_config "$cfg_world"
chmod 666 "$cfg_world"
if ( dce_load_project_config "$cfg_world" ) >/dev/null 2>&1; then
  fail "loader must reject group/other-writable config"
fi

pass "group/other-writable config rejected"

# --- invalid persisted cpus/memory rejected at load ---------------------------
cfg_badcpus="$WORK/badcpusproj/config"
write_valid_config "$cfg_badcpus" "not-a-number" ""
if ( dce_load_project_config "$cfg_badcpus" ) >/dev/null 2>&1; then
  fail "loader must reject invalid persisted CONTAINER_CPUS"
fi

cfg_badmem="$WORK/badmemproj/config"
write_valid_config "$cfg_badmem" "" "999z"
if ( dce_load_project_config "$cfg_badmem" ) >/dev/null 2>&1; then
  fail "loader must reject invalid persisted CONTAINER_MEMORY"
fi

pass "invalid persisted resource values rejected at load"

# --- valid schema-v2 config continues to load ----------------------------------
cfg_ok="$WORK/okproj/config"
write_valid_config "$cfg_ok" "2" "4g"
dce_load_project_config "$cfg_ok"
[[ "${CONFIG_SCHEMA_VERSION:-}" == "2" ]] || fail "schema-v2 config: version not loaded"
[[ "${CONTAINER_CPUS:-}" == "2" ]] || fail "schema-v2 config: cpus not loaded"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "schema-v2 config: memory not loaded"
[[ "${CONTAINER_BACKEND:-}" == "docker" ]] || fail "schema-v2 config: backend not loaded"
[[ "${REPO_NAMES[0]:-}" == "testproj" ]] || fail "schema-v2 config: REPO_NAMES not loaded"
[[ "${REPO_PATHS[0]:-}" == "$WORK/repos/testproj" ]] || fail "schema-v2 config: REPO_PATHS not loaded"

pass "valid schema-v2 config loads"

# --- valid schema-v2 config with multiple repos loads ---------------------------
cfg_multi="$WORK/multiproj/config"
write_v2_config "$cfg_multi" web api -- "$WORK/repos/web" "$WORK/src/company-api"
dce_load_project_config "$cfg_multi"
[[ "${CONFIG_SCHEMA_VERSION:-}" == "2" ]] || fail "multi-repo: schema version not loaded"
[[ "${REPO_NAMES[0]:-}" == "web" && "${REPO_NAMES[1]:-}" == "api" ]] \
  || fail "multi-repo: REPO_NAMES wrong (got ${REPO_NAMES[*]:-})"
[[ "${REPO_PATHS[0]:-}" == "$WORK/repos/web" && "${REPO_PATHS[1]:-}" == "$WORK/src/company-api" ]] \
  || fail "multi-repo: REPO_PATHS wrong (got ${REPO_PATHS[*]:-})"

# Reloading a one-repo config must not leak the prior load's array elements.
dce_load_project_config "$cfg_ok"
[[ ${#REPO_NAMES[@]} -eq 1 ]] || fail "repo arrays must reset across loads (got ${#REPO_NAMES[@]} entries)"
[[ ${#REPO_PATHS[@]} -eq 1 ]] || fail "repo path arrays must reset across loads (got ${#REPO_PATHS[@]} entries)"

pass "multi-repo schema-v2 config loads; arrays reset across loads"

# --- shared repo name/path validators ------------------------------------------
dce_validate_repo_name "web" 2>/dev/null || fail "repo name 'web' should be valid"
dce_validate_repo_name "App_2.x-web" 2>/dev/null || fail "repo name 'App_2.x-web' should be valid"
dce_validate_repo_name "" 2>/dev/null && fail "empty repo name should be invalid"
dce_validate_repo_name ".cache" 2>/dev/null && fail "reserved repo name '.cache' should be invalid"
dce_validate_repo_name "-lead" 2>/dev/null && fail "dash-leading repo name should be invalid"
dce_validate_repo_name "bad name" 2>/dev/null && fail "repo name with space should be invalid"
dce_validate_repo_name "bad/slash" 2>/dev/null && fail "repo name with slash should be invalid"

dce_validate_repo_path "/abs/repo" 2>/dev/null || fail "absolute repo path should be valid"
dce_validate_repo_path "relative/repo" 2>/dev/null && fail "relative repo path should be invalid"
dce_validate_repo_path "" 2>/dev/null && fail "empty repo path should be invalid"
dce_validate_repo_path $'/tmp/a\tb' 2>/dev/null && fail "tab in repo path should be invalid"
dce_validate_repo_path $'/tmp/a\nb' 2>/dev/null && fail "newline in repo path should be invalid"

# Canonical form trims trailing slashes so '/a/b' and '/a/b/' compare equal.
[[ "$(dce_repo_path_canonical '/a/b/')" == "/a/b" ]] || fail "canonical path should trim trailing slash"

# Canonical form collapses lexical aliases (duplicate slashes, '.' and '..')
# with NO filesystem access, so duplicate/overlap detection catches string
# aliases of the same directory before anything is created.
[[ "$(dce_repo_path_canonical '/a//b')" == "/a/b" ]] || fail "canonical path should collapse duplicate slashes"
[[ "$(dce_repo_path_canonical '/a/./b')" == "/a/b" ]] || fail "canonical path should drop '.' segments"
[[ "$(dce_repo_path_canonical '/a/b/../c')" == "/a/c" ]] || fail "canonical path should resolve '..' lexically"
[[ "$(dce_repo_path_canonical '/a/b///./')" == "/a/b" ]] || fail "canonical path should collapse mixed aliases"
[[ "$(dce_repo_path_canonical '/..')" == "/" ]] || fail "canonical path should clamp '..' above root at /"
[[ "$(dce_repo_path_canonical '/a/../..')" == "/" ]] || fail "canonical path should clamp deep '..' runs at /"
[[ "$(dce_repo_path_canonical '/')" == "/" ]] || fail "canonical path should keep the root as /"

# The host root and the user's home are never valid bind-mount repo sources:
# they would expose everything under them inside the container.
dce_validate_repo_path "/" 2>/dev/null && fail "canonical '/' repo path should be invalid"
dce_validate_repo_path "//" 2>/dev/null && fail "'//' (canonical '/') repo path should be invalid"
dce_validate_repo_path "/a/.." 2>/dev/null && fail "path canonicalizing to '/' should be invalid"
dce_validate_repo_path "$HOME" 2>/dev/null && fail "canonical \$HOME repo path should be invalid"
dce_validate_repo_path "$HOME/" 2>/dev/null && fail "trailing-slash \$HOME repo path should be invalid"
dce_validate_repo_path "$HOME/./" 2>/dev/null && fail "lexical alias of \$HOME should be invalid"
dce_validate_repo_path "/home/other" 2>/dev/null || fail "non-HOME absolute repo path should stay valid"

pass "repo name/path validators"

# --- v2 loader failure modes ----------------------------------------------------
# Mismatched REPO_NAMES/REPO_PATHS lengths.
cfg_len="$WORK/lenproj/config"
write_v2_config "$cfg_len" web api -- "$WORK/repos/web"
expect_load_fail "mismatched REPO_NAMES/REPO_PATHS lengths" "$cfg_len"
len_err="$( ( dce_load_project_config "$cfg_len" ) 2>&1 >/dev/null || true )"
printf '%s' "$len_err" | grep -q 'REPO_NAMES' || fail "length-mismatch error should name REPO_NAMES (got: $len_err)"
printf '%s' "$len_err" | grep -q 'REPO_PATHS' || fail "length-mismatch error should name REPO_PATHS (got: $len_err)"

# Empty repo lists.
cfg_empty="$WORK/emptyproj/config"
write_v2_config "$cfg_empty" --
expect_load_fail "an empty repo list" "$cfg_empty"

# Duplicate repo names.
cfg_dupname="$WORK/dupnameproj/config"
write_v2_config "$cfg_dupname" web web -- "$WORK/repos/one" "$WORK/repos/two"
expect_load_fail "duplicate repo names" "$cfg_dupname"

# Reserved repo name (.cache) even though the path list is otherwise valid.
cfg_reserved="$WORK/reservedproj/config"
write_v2_config "$cfg_reserved" .cache -- "$WORK/repos/cache"
expect_load_fail "the reserved repo name '.cache'" "$cfg_reserved"

# Repo name grammar (same conservative identifier pattern as project names).
cfg_badname="$WORK/badnameproj/config"
write_v2_config "$cfg_badname" "bad name" -- "$WORK/repos/bad"
expect_load_fail "an invalid repo name" "$cfg_badname"

# Duplicate canonical paths: a trailing slash is the same canonical path.
cfg_duppath="$WORK/duppathproj/config"
write_v2_config "$cfg_duppath" web api -- "$WORK/repos/web" "$WORK/repos/web/"
expect_load_fail "duplicate canonical repo paths" "$cfg_duppath"

# Overlapping/nested canonical paths, parent listed first and last.
cfg_nested="$WORK/nestedproj/config"
write_v2_config "$cfg_nested" app ui -- "$WORK/repos/app" "$WORK/repos/app/packages/ui"
expect_load_fail "nested repo paths (parent listed first)" "$cfg_nested"
cfg_nested2="$WORK/nested2proj/config"
write_v2_config "$cfg_nested2" ui app -- "$WORK/repos/app/packages/ui" "$WORK/repos/app"
expect_load_fail "nested repo paths (parent listed last)" "$cfg_nested2"

# Relative repo path.
cfg_rel="$WORK/relproj/config"
write_v2_config "$cfg_rel" web -- "repos/web"
expect_load_fail "a relative repo path" "$cfg_rel"

# Canonical '/' as a repo path (the whole host root must never be mounted).
cfg_root="$WORK/rootproj/config"
write_v2_config "$cfg_root" web -- "/"
expect_load_fail "the canonical '/' repo path" "$cfg_root"

# Canonical $HOME as a repo path (the whole home must never be mounted).
cfg_home="$WORK/homeproj/config"
write_v2_config "$cfg_home" web -- "$HOME"
expect_load_fail "the canonical \$HOME repo path" "$cfg_home"

# A lexical alias of an existing entry (duplicate slashes / '.' segments) must
# trip duplicate detection without touching the filesystem.
cfg_alias="$WORK/aliasproj/config"
write_v2_config "$cfg_alias" web api -- "$WORK/repos/web" "$WORK/repos/./web"
expect_load_fail "a duplicate lexical-alias repo path" "$cfg_alias"

# Control characters in a repo path. A raw \001 (not tab/newline) is used so the
# byte survives array parsing instead of word-splitting into a bogus second
# element, which would fail for the wrong reason (length mismatch).
cfg_cntrl="$WORK/cntrlproj/config"
write_v2_config "$cfg_cntrl" web -- "$(printf '/tmp/bad\001path')"
expect_load_fail "a control-character repo path" "$cfg_cntrl"

pass "schema-v2 failure modes rejected"

# --- legacy REPOS_DIR config rejected with explicit branch pointer --------------
cfg_legacy="$WORK/legacyproj/config"
mkdir -p "$(dirname "$cfg_legacy")"
chmod 700 "$(dirname "$cfg_legacy")"
{
  echo 'CONTAINER_PROJECT="oldproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'REPOS_DIR="/tmp/repos/oldproj"'
  echo 'SECRET_DIR="/tmp/secret"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_legacy"
chmod 600 "$cfg_legacy"
expect_load_fail "a legacy single-repo (REPOS_DIR) config" "$cfg_legacy"
legacy_err="$( ( dce_load_project_config "$cfg_legacy" ) 2>&1 >/dev/null || true )"
printf '%s' "$legacy_err" | grep -q 'legacy-single-repo' \
  || fail "legacy REPOS_DIR error must point to the legacy-single-repo branch (got: $legacy_err)"

pass "legacy REPOS_DIR config rejected with legacy-single-repo pointer"

# --- legacy REPOS_DIR key rejected even when its value is empty ------------------
# Presence of the retired key is the legacy signal, not its value: a hand-edited
# or truncated config with REPOS_DIR="" must get the same targeted
# legacy-single-repo guidance, not load as a schema-v2 config.
cfg_legacy_empty="$WORK/legacyemptyproj/config"
mkdir -p "$(dirname "$cfg_legacy_empty")"
chmod 700 "$(dirname "$cfg_legacy_empty")"
{
  echo 'CONTAINER_PROJECT="oldproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'CONFIG_SCHEMA_VERSION="2"'
  echo 'REPOS_DIR=""'
  echo 'REPO_NAMES=(oldproj)'
  echo "REPO_PATHS=($WORK/repos/oldproj)"
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_legacy_empty"
chmod 600 "$cfg_legacy_empty"
if ( dce_load_project_config "$cfg_legacy_empty" ) >/dev/null 2>&1; then
  fail "loader must reject a config carrying an empty REPOS_DIR key"
fi
legacy_empty_err="$( ( dce_load_project_config "$cfg_legacy_empty" ) 2>&1 >/dev/null || true )"
printf '%s' "$legacy_empty_err" | grep -q 'legacy-single-repo' \
  || fail "empty REPOS_DIR error must point to the legacy-single-repo branch (got: $legacy_empty_err)"

pass "legacy REPOS_DIR=\"\" config rejected with legacy-single-repo pointer"

# --- repos root / ancestor repo paths rejected in persisted configs ----------------
export DC_REPOS_DIR="$WORK/repos"
cfg_rootpath="$WORK/rootpathproj/config"
write_v2_config "$cfg_rootpath" web -- "$WORK/repos"
if ( dce_load_project_config "$cfg_rootpath" ) >/dev/null 2>&1; then
  fail "loader must reject a repo path equal to the default repos root"
fi
rootpath_err="$( ( dce_load_project_config "$cfg_rootpath" ) 2>&1 >/dev/null || true )"
printf '%s' "$rootpath_err" | grep -qi 'repos root' \
  || fail "repos-root config rejection should explain the broad-mount rule (got: $rootpath_err)"

cfg_ancestorpath="$WORK/ancestorpathproj/config"
write_v2_config "$cfg_ancestorpath" web -- "$WORK"
if ( dce_load_project_config "$cfg_ancestorpath" ) >/dev/null 2>&1; then
  fail "loader must reject a repo path that is an ancestor of the default repos root"
fi
ancestorpath_err="$( ( dce_load_project_config "$cfg_ancestorpath" ) 2>&1 >/dev/null || true )"
printf '%s' "$ancestorpath_err" | grep -qi 'parent of it' \
  || fail "ancestor-path config rejection should explain the broad-mount rule (got: $ancestorpath_err)"

pass "persisted configs reject repos-root and ancestor repo paths"

# --- missing or unsupported CONFIG_SCHEMA_VERSION rejected ----------------------
cfg_nover="$WORK/noverproj/config"
mkdir -p "$(dirname "$cfg_nover")"
chmod 700 "$(dirname "$cfg_nover")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'REPO_NAMES=(web)'
  echo "REPO_PATHS=($WORK/repos/web)"
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_nover"
chmod 600 "$cfg_nover"
expect_load_fail "a config without CONFIG_SCHEMA_VERSION" "$cfg_nover"

cfg_badver="$WORK/badverproj/config"
write_v2_config "$cfg_badver" web -- "$WORK/repos/web"
dce_set_config_key "$cfg_badver" CONFIG_SCHEMA_VERSION "1"
expect_load_fail "an unsupported CONFIG_SCHEMA_VERSION" "$cfg_badver"

pass "missing/unsupported CONFIG_SCHEMA_VERSION rejected"

# --- valid config with ports + hidden paths loads ----------------------------
cfg_ports="$WORK/portsproj/config"
mkdir -p "$(dirname "$cfg_ports")"
chmod 700 "$(dirname "$cfg_ports")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'CONFIG_SCHEMA_VERSION="2"'
  echo 'REPO_NAMES=(portsproj)'
  echo "REPO_PATHS=($WORK/repos/portsproj)"
  echo 'PORTS=(5173:5173 8080)'
  echo 'CONTAINER_HIDDEN_PATHS=(node_modules apps/web/node_modules)'
} > "$cfg_ports"
chmod 600 "$cfg_ports"
dce_load_project_config "$cfg_ports"
[[ "${PORTS[0]:-}" == "5173:5173" ]] || fail "ports not loaded"
[[ "${CONTAINER_HIDDEN_PATHS[1]:-}" == "apps/web/node_modules" ]] || fail "hidden paths not loaded"

pass "valid config with ports/hidden paths loads"

# --- omitted optional scalars do not leak across loads -----------------------
cfg_opt_a="$WORK/optaproj/config"
write_valid_config "$cfg_opt_a" "2" "4g"
{
  echo 'CONTAINER_GIT_HOST="gitlab"'
} >> "$cfg_opt_a"
chmod 600 "$cfg_opt_a"
dce_load_project_config "$cfg_opt_a"
[[ "${CONTAINER_CPUS:-}" == "2" ]] || fail "optional scalar setup: cpus"
[[ "${CONTAINER_MEMORY:-}" == "4g" ]] || fail "optional scalar setup: memory"
[[ "${CONTAINER_GIT_HOST:-}" == "gitlab" ]] || fail "optional scalar setup: git host"

cfg_opt_b="$WORK/optbproj/config"
mkdir -p "$(dirname "$cfg_opt_b")"
chmod 700 "$(dirname "$cfg_opt_b")"
{
  echo 'CONTAINER_PROJECT="testproj"'
  echo 'CONTAINER_BACKEND="docker"'
  echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'CONFIG_SCHEMA_VERSION="2"'
  echo 'REPO_NAMES=(optbproj)'
  echo 'REPO_PATHS=(/tmp/repos/optbproj)'
  echo 'SECRET_DIR="/tmp/secret"'
  echo 'SSH_KEY_PATH="/tmp/secret/ssh_key"'
  echo 'TOKEN_FILE="/tmp/secret/github-token"'
  echo 'NPMRC_PATH="/tmp/secret/.npmrc"'
  echo 'PORTS=()'
  echo 'CONTAINER_HIDDEN_PATHS=()'
} > "$cfg_opt_b"
chmod 600 "$cfg_opt_b"
dce_load_project_config "$cfg_opt_b"
[[ -z "${CONTAINER_CPUS:-}" ]] || fail "omitted CONTAINER_CPUS must reset across loads"
[[ -z "${CONTAINER_MEMORY:-}" ]] || fail "omitted CONTAINER_MEMORY must reset across loads"
[[ -z "${CONTAINER_GIT_HOST:-}" ]] || fail "omitted CONTAINER_GIT_HOST must reset across loads"

pass "omitted optional scalars reset across config loads"

# --- safe global-config scalar extraction (no execution) ----------------------
rm -f /tmp/m1-global-pwn
gcfg="$WORK/globalconfig"
{
  echo '# global config'
  echo 'DC_TEAM_DIR="/tmp/team-root"'
  echo 'DC_USER_DIR="/tmp/user-root"'
  echo 'OTHER="$(touch /tmp/m1-global-pwn)"'
} > "$gcfg"
got="$(dce_config_extract_scalar "$gcfg" DC_TEAM_DIR)" || fail "global extract failed"
[[ "$got" == "/tmp/team-root" ]] || fail "global extract mismatch (got '$got')"
[[ ! -e /tmp/m1-global-pwn ]] || fail "global extract must not execute config"

pass "global config parsed without execution"

# --- dce-complete parses overlays dir without executing config -----------------
rm -f /tmp/m1-complete-pwn
gccfg="$WORK/complete-global-config"
{
  echo '# global config'
  echo 'DC_TEAM_DIR="/tmp/safe-team"'
  echo 'DC_USER_DIR="/tmp/safe-user"'
  echo 'EVIL="$(touch /tmp/m1-complete-pwn)"'
} > "$gccfg"
# shellcheck source=/dev/null
source "$ROOT_DIR/scripts/dce-complete.bash"
got="$(_dce_read_team_dir "$gccfg")" || fail "dce-complete team root parse failed"
[[ "$got" == "/tmp/safe-team" ]] || fail "dce-complete team root mismatch (got '$got')"
[[ ! -e /tmp/m1-complete-pwn ]] || fail "dce-complete must not execute config code"

pass "dce-complete parses global config without execution"

echo ""
echo "All M1 config-security checks passed."
