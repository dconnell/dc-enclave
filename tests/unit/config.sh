#!/usr/bin/env bash
# shellcheck disable=SC2016
# This file deliberately writes literal $(...) payloads to prove they are
# rejected as data, never executed.
# =============================================================================
# tests/config.sh - `dce config` command family behavior.
#
# Exercises the thin validating wrapper over the per-project config file:
#   show / get / set / ls. Verifies round-trips, per-key validation rejection,
#   read-only-key rejection, the "rebuild to apply" notice, project discovery,
#   and that every successful set leaves a loadable, mode-600 file behind.
#
# The command is backend-free and global-config-free: it touches only the
# project config under $HOME/.config/dce-enclave/<name>/config, so the test
# points $HOME at a temp tree and never needs a container runtime.
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
trap 'rm -rf "$WORK" 2>/dev/null || true' EXIT
chmod 700 "$WORK"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"

# Invoke the command under test with $HOME pointed at the temp tree.
dce_config() {
  (HOME="$FAKE_HOME" bash "$ROOT_DIR/scripts/config.sh" "$@")
}

mode_is() {
  local file="$1" want="$2"
  [[ -n "$(find "$file" -maxdepth 0 -perm "$want" -print 2>/dev/null)" ]]
}

# Write a loadable project config at the canonical path (mode 600 / dir 700).
write_project_config() {
  local project="$1"
  local dir="$FAKE_HOME/.config/dce-enclave/$project"
  mkdir -p "$dir"
  chmod 700 "$dir"
  {
    echo '# DC Enclave config'
    echo "CONTAINER_PROJECT=\"$project\""
    echo 'CONTAINER_BACKEND="docker"'
    echo 'CONTAINER_IMAGE="dce-base:latest"'
    echo 'CONTAINER_CPUS=""'
    echo 'CONTAINER_MEMORY=""'
    echo 'CONTAINER_OVERLAY_SCOPES=""'
    echo 'PORTS=()'
    echo 'CONTAINER_HIDDEN_PATHS=()'
    echo 'CONTAINER_NETWORKS=()'
  } > "$dir/config"
  chmod 600 "$dir/config"
}

config_path() {
  printf '%s/.config/dce-enclave/%s/config\n' "$FAKE_HOME" "$1"
}

# ============================================================================
# show
# ============================================================================
write_project_config showproj
out="$(dce_config show showproj)" || fail "show exited non-zero on valid project"
printf '%s\n' "$out" | grep -q 'Project: showproj' || fail "show missing Project line"
printf '%s\n' "$out" | grep -q 'Backend: docker' || fail "show missing Backend line"
printf '%s\n' "$out" | grep -q 'Image:.*dce-base:latest' || fail "show missing Image line"
printf '%s\n' "$out" | grep -qi 'cpu' || fail "show missing resources section"

pass "config show prints identity + resource sections"

# ============================================================================
# get (scalar, array, read-only, unset, unknown)
# ============================================================================
write_project_config getproj
# read-only key
[[ "$(dce_config get getproj backend)" == "docker" ]] || fail "get backend wrong"

# unknown key -> exit 1
if dce_config get getproj boguskey >/dev/null 2>&1; then
  fail "get of unknown key must fail"
fi
pass "config get: read-only + unknown-key handling"

# ============================================================================
# set: scalar equals form + round-trip + mode + notice
# ============================================================================
write_project_config setproj
cfg="$(config_path setproj)"

out="$(dce_config set setproj cpus=4)" || fail "set cpus=4 exited non-zero"
printf '%s\n' "$out" | grep -q "Updated 'cpus'" || fail "set missing Updated notice"
printf '%s\n' "$out" | grep -q "rebuild-container setproj" || fail "set missing rebuild hint"
mode_is "$cfg" 600 || fail "set must preserve mode 600"
[[ "$(dce_config get setproj cpus)" == "4" ]] || fail "set cpus did not round-trip"
# reload proves the file is still valid end-to-end
( HOME="$FAKE_HOME" bash -c 'source "$1"; dce_load_project_config "$2"' _ "$ROOT_DIR/lib/common.sh" "$cfg" ) \
  || fail "config file unloadable after set"
pass "set scalar (equals form): round-trip + mode + notice"

# ============================================================================
# set: scalar space form
# ============================================================================
write_project_config setproj2
dce_config set setproj2 memory 8g >/dev/null || fail "set memory (space form) exited non-zero"
[[ "$(dce_config get setproj2 memory)" == "8g" ]] || fail "space-form set memory wrong"
pass "set scalar (space form)"

# ============================================================================
# set: invalid values rejected, file unchanged
# ============================================================================
write_project_config badproj
cfg="$(config_path badproj)"
before="$(cat "$cfg")"
if dce_config set badproj cpus=0 >/dev/null 2>&1; then fail "cpus=0 must be rejected"; fi
if dce_config set badproj cpus=-1 >/dev/null 2>&1; then fail "cpus=-1 must be rejected"; fi
if dce_config set badproj cpus=1e5 >/dev/null 2>&1; then fail "cpus=1e5 must be rejected"; fi
if dce_config set badproj memory=4t >/dev/null 2>&1; then fail "memory=4t must be rejected"; fi
if dce_config set badproj memory=4gb >/dev/null 2>&1; then fail "memory=4gb must be rejected"; fi
if dce_config set badproj 'cpus=$(rm -rf /)' >/dev/null 2>&1; then fail "metachar cpus must be rejected"; fi
[[ "$(cat "$cfg")" == "$before" ]] || fail "rejected set must not mutate the file"
pass "invalid scalar values rejected, file unchanged"

# ============================================================================
# set: clear to default (empty value)
# ============================================================================
write_project_config clrproj
dce_config set clrproj cpus=2 >/dev/null
dce_config set clrproj cpus= >/dev/null || fail "clear cpus= exited non-zero"
val="$(dce_config get clrproj cpus)"
[[ -z "$val" ]] || fail "cpus= should clear to empty (got '$val')"
pass "set to empty clears (backend default)"

# ============================================================================
# set: scopes CSV normalizes (case/whitespace/dedup)
# ============================================================================
write_project_config scopeproj
dce_config set scopeproj scopes='NodeJS, golang, nodejs' >/dev/null \
  || fail "set scopes exited non-zero"
[[ "$(dce_config get scopeproj scopes)" == "nodejs,golang" ]] \
  || fail "scopes not normalized (got '$(dce_config get scopeproj scopes)')"
# invalid scope name rejected
if dce_config set scopeproj 'scopes=BAD NAME!' >/dev/null 2>&1; then fail "bad scope must reject"; fi
pass "set scopes normalizes and validates"

# ============================================================================
# set: array ports (CSV) + get (one per line) + empty
# ============================================================================
write_project_config portproj
dce_config set portproj 'ports=3000:3000,8080' >/dev/null || fail "set ports exited non-zero"
mapfile -t got < <(dce_config get portproj ports)
[[ "${got[0]:-}" == "3000:3000" && "${got[1]:-}" == "8080" ]] \
  || fail "ports array wrong (got ${got[*]:-})"
# invalid port rejected
if dce_config set portproj 'ports=notaport' >/dev/null 2>&1; then fail "bad port must reject"; fi
# clear array
dce_config set portproj 'ports=' >/dev/null || fail "clear ports exited non-zero"
mapfile -t got < <(dce_config get portproj ports)
[[ ${#got[@]} -eq 0 ]] || fail "ports= should yield empty array (got ${#got[@]})"
pass "set/get ports array + validation + clear"

# ============================================================================
# set: array hide + networks (name and name:ip)
# ============================================================================
write_project_config netproj
dce_config set netproj 'hide=node_modules,.cache' >/dev/null || fail "set hide exited non-zero"
mapfile -t got < <(dce_config get netproj hide)
[[ "${got[0]:-}" == "node_modules" && "${got[1]:-}" == ".cache" ]] \
  || fail "hide array wrong (got ${got[*]:-})"

dce_config set netproj 'networks=appnet,dbnet:10.0.0.5' >/dev/null \
  || fail "set networks exited non-zero"
mapfile -t got < <(dce_config get netproj networks)
[[ "${got[0]:-}" == "appnet" && "${got[1]:-}" == "dbnet:10.0.0.5" ]] \
  || fail "networks array wrong (got ${got[*]:-})"
# invalid network name and bad IP rejected
if dce_config set netproj 'networks=BAD NET' >/dev/null 2>&1; then fail "bad network name must reject"; fi
if dce_config set netproj 'networks=ok:999.999.999.999' >/dev/null 2>&1; then fail "bad network IP must reject"; fi
pass "set/get hide + networks arrays + validation"

# ============================================================================
# set: read-only key rejected, unknown key rejected
# ============================================================================
write_project_config roproj
if dce_config set roproj 'image=evil:latest' >/dev/null 2>&1; then
  fail "set of read-only key 'image' must be rejected"
fi
if dce_config set roproj 'project=other' >/dev/null 2>&1; then
  fail "set of read-only key 'project' must be rejected"
fi
errout="$(dce_config set roproj 'bogus=1' 2>&1 >/dev/null || true)"
printf '%s' "$errout" | grep -qi 'valid key\|unknown key\|cpus' \
  || fail "unknown-key error should list valid keys (got: $errout)"
pass "read-only and unknown keys rejected"

# ============================================================================
# ls: lists configured projects, backend-free
# ============================================================================
write_project_config ls-a
write_project_config ls-b
mapfile -t listed < <(dce_config ls 2>/dev/null)
found_a=0; found_b=0
for n in "${listed[@]}"; do [[ "$n" == "ls-a" ]] && found_a=1; [[ "$n" == "ls-b" ]] && found_b=1; done
[[ $found_a -eq 1 && $found_b -eq 1 ]] || fail "ls must list configured projects (got ${listed[*]:-})"
pass "config ls lists configured projects"

# ============================================================================
# project not found
# ============================================================================
if dce_config show does-not-exist >/dev/null 2>&1; then
  fail "show on missing project must fail"
fi
if dce_config get does-not-exist cpus >/dev/null 2>&1; then
  fail "get on missing project must fail"
fi
pass "missing project rejected"

echo ""
echo "All dce config checks passed."
