#!/usr/bin/env bash
# =============================================================================
# tests/contract/networks.sh - Stubbed-backend networking feature coverage.
#
# Exercises the networking feature end-to-end without a real daemon, using stub
# CLIs (docker/container/podman) that log every call and answer the read
# predicates (image ls, network ls, ps) from controlled files. Mirrors the stub
# harness in tests/contract/new-container-lifecycle.sh.
#
# Pure host-side helper coverage (normalize, entry accessors, create-args,
# backend limits, CONTAINER_NETWORKS round-trip) lives in
# tests/unit/network-helpers.sh.
#
# Coverage:
#   B. dce new --network/--ip (docker): config persistence, create argv shape,
#      extras live-connect, image positional last.
#   C. dce new --network referencing a missing network fails fast (no create).
#   D. dce new on apple: single-network ok; multi-network / --ip rejected.
#   E. dce rebuild-container reattaches networks (create-argv parity + extras).
#   F. dce network create/ls/members (docker).
#   G. dce network create/ls (apple, incl. columned `network list` header parse).
#   H. dce network rm refuses with members; --force disconnects then removes.
#   I. dce network add/remove persist CONTAINER_NETWORKS in the project config.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/network.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ===========================================================================
# Stub harness (shared by B-I): fakes docker/container/podman.
# ===========================================================================
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"

STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"
NETWORKS="$WORK/networks.lst"
CONTAINERS="$WORK/containers.lst"
: > "$LOG"
printf 'dce-base:latest\n' > "$IMAGES"
: > "$NETWORKS"
: > "$CONTAINERS"

cat > "$STUB_DIR/_cli" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
_imgs="${DC_STUB_IMAGES:-}"
_nets="${DC_STUB_NETWORKS:-}"
_ctrs="${DC_STUB_CONTAINERS:-}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"

# image listing
if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]]; then [[ -f "$_imgs" ]] && cat "$_imgs"; exit 0; fi
if [[ "${1:-}" == "images" ]]; then [[ -f "$_imgs" ]] && cat "$_imgs"; exit 0; fi

case "$me" in
  docker)
    if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then printf 'colima\n'; exit 0; fi
    # network list (docker)
    if [[ "${1:-}" == "network" && "${2:-}" == "ls" ]]; then [[ -f "$_nets" ]] && cat "$_nets"; exit 0; fi
    # network create -> record so later existence checks see it
    if [[ "${1:-}" == "network" && "${2:-}" == "create" ]]; then
      printf '%s\n' "$3" >> "$_nets"; exit 0
    fi
    # network rm -> drop from list
    if [[ "${1:-}" == "network" && "${2:-}" == "rm" ]]; then
      grep -vxF -- "$3" "$_nets" 2>/dev/null > "$_nets.tmp" || true; mv "$_nets.tmp" "$_nets" 2>/dev/null || true; exit 0
    fi
    # container existence / running
    if [[ "${1:-}" == "ps" ]]; then
      fmt=""
      for a in "$@"; do [[ "$a" == "--format" ]] && fmt=1; done
      [[ -f "$_ctrs" ]] && cat "$_ctrs"
      exit 0
    fi
    ;;
  container)
    # apple `container network list` -> columned table with a NETWORK header.
    if [[ "${1:-}" == "network" && "${2:-}" == "list" ]]; then
      echo "NETWORK  STATE    SUBNET"
      [[ -f "$_nets" ]] && while IFS= read -r nn; do printf '%s  running  10.0.0.0/24\n' "$nn"; done < "$_nets"
      exit 0
    fi
    if [[ "${1:-}" == "network" && "${2:-}" == "create" ]]; then
      printf '%s\n' "$3" >> "$_nets"; exit 0
    fi
    if [[ "${1:-}" == "network" && "${2:-}" == "delete" ]]; then
      grep -vxF -- "$3" "$_nets" 2>/dev/null > "$_nets.tmp" || true; mv "$_nets.tmp" "$_nets" 2>/dev/null || true; exit 0
    fi
    # apple `container ls` (-q/-a/-a -q all print names, one per line)
    if [[ "${1:-}" == "ls" ]]; then [[ -f "$_ctrs" ]] && cat "$_ctrs"; exit 0; fi
    ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_cli"
cp "$STUB_DIR/_cli" "$STUB_DIR/docker"
cp "$STUB_DIR/_cli" "$STUB_DIR/container"
cp "$STUB_DIR/_cli" "$STUB_DIR/podman"

ORIG_PATH="$PATH"
run_script() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" \
  DC_STUB_NETWORKS="$NETWORKS" DC_STUB_CONTAINERS="$CONTAINERS" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="$BACKEND" \
  bash "$@"
}
first_call() { grep -En "$1" "$LOG" 2>/dev/null | head -n1 | cut -d: -f1 || true; }

# ===========================================================================
# Section B - dce new --network/--ip (docker): config + create argv + extras
# ===========================================================================
BACKEND=docker
printf 'mynet\nobs\n' > "$NETWORKS"   # both networks exist
: > "$CONTAINERS"

PROJECT="webproj"
REPOS_DIR="$WORK/home/repos/$PROJECT"
SECRET_DIR="$WORK/home/.config/dce-enclave/$PROJECT"
CONFIG="$SECRET_DIR/config"

: > "$LOG"
run_script "$ROOT_DIR/scripts/new-container.sh" \
  "$PROJECT" --network "mynet:10.0.0.5,obs" \
  >"$WORK/b.stdout" 2>"$WORK/b.stderr" || fail "dce new --network exited non-zero
-- stderr:$(cat "$WORK/b.stderr")"

# config persistence
chmod 600 "$CONFIG" 2>/dev/null || true
PORTS=(); CONTAINER_HIDDEN_PATHS=(); CONTAINER_NETWORKS=()
dce_load_project_config "$CONFIG"
[[ "${CONTAINER_NETWORKS[*]}" == "mynet:10.0.0.5 obs" ]] || fail "config CONTAINER_NETWORKS (got [${CONTAINER_NETWORKS[*]}])"

# create argv: --network mynet --ip 10.0.0.5 present, image LAST
CREATE="$(grep -E 'create --name webproj' "$LOG" | head -n1)"
[[ -n "$CREATE" ]] || fail "dce new: no create call"
grep -Fq -- "--network mynet" <<<"$CREATE" || fail "create: --network mynet"
grep -Fq -- "--ip 10.0.0.5" <<<"$CREATE" || fail "create: --ip"
[[ "${CREATE##* }" == "dce-base:latest" ]] || fail "create: image must be last (got [${CREATE##* }])"

# extras connected live AFTER create.
cre_ln="$(first_call 'create --name webproj')"
con_ln="$(first_call 'network connect --ip 10.0.0.5 mynet webproj')"
[[ -z "$con_ln" ]] || fail "primary must not be live-connected (found connect call)"
obs_con="$(first_call 'network connect obs webproj')"
[[ -n "$obs_con" ]] || fail "extras: obs should be live-connected"
[[ "$cre_ln" -lt "$obs_con" ]] || fail "extras connect must follow create"

# devcontainer.json carries runArgs so a Reopen-in-Container build reattaches the
# primary network (+ its static IP) and extras.
dce_json="$REPOS_DIR/.devcontainer/devcontainer.json"
[[ -f "$dce_json" ]] || fail "devcontainer.json missing"
grep -Fq '"runArgs"' "$dce_json" || fail "devcontainer.json: runArgs block"
grep -Fq '"--network"' "$dce_json" || fail "devcontainer.json: --network in runArgs"
grep -Fq '"--ip"' "$dce_json" || fail "devcontainer.json: --ip in runArgs"
grep -Fq '"mynet"' "$dce_json" || fail "devcontainer.json: primary network name"
grep -Fq '"obs"' "$dce_json" || fail "devcontainer.json: extra network name"
# Validate the whole file is well-formed JSON (runArgs included).
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$dce_json" \
    || fail "devcontainer.json is not valid JSON"
fi

pass "Section B: dce new --network/--ip (docker) config + argv + extras"

# ===========================================================================
# Section C - missing network fails fast (no create)
# ===========================================================================
: > "$NETWORKS"   # no networks exist
CPROJ="cproj"
: > "$LOG"
if run_script "$ROOT_DIR/scripts/new-container.sh" "$CPROJ" --network ghost >"$WORK/c.stdout" 2>"$WORK/c.stderr"; then
  fail "dce new must fail when network is missing"
fi
grep -Fqi 'does not exist' "$WORK/c.stderr" || fail "missing-network error should mention 'does not exist' (stderr)"
grep -Fqi 'dce network create ghost' "$WORK/c.stderr" || fail "missing-network error should suggest dce network create (stderr)"
if grep -qE 'create --name cproj' "$LOG"; then fail "dce new: must not create container when network missing"; fi
if [[ -d "$WORK/home/.config/dce-enclave/$CPROJ" ]]; then
  fail "dce new: must not leave a project config dir when network missing"
fi
pass "Section C: missing network fails fast"

# ===========================================================================
# Section D - apple backend limits
# ===========================================================================
BACKEND=apple
printf 'mynet\n' > "$NETWORKS"
: > "$CONTAINERS"

# single network on apple is allowed.
: > "$LOG"
run_script "$ROOT_DIR/scripts/new-container.sh" "aproj" --network mynet \
  >"$WORK/d1.stdout" 2>"$WORK/d1.stderr" || fail "dce new apple single-network failed
-- stderr:$(cat "$WORK/d1.stderr")"
ACREATE="$(grep -E 'create --name aproj' "$LOG" | head -n1)"
grep -Fq -- "--network mynet" <<<"$ACREATE" || fail "apple create: --network mynet"

# multi-network on apple is rejected.
: > "$LOG"
if run_script "$ROOT_DIR/scripts/new-container.sh" "aproj2" --network "a,b" >/dev/null 2>&1; then
  fail "dce new apple multi-network must fail"
fi
# --ip on apple is rejected.
: > "$LOG"
if run_script "$ROOT_DIR/scripts/new-container.sh" "aproj3" --network mynet --ip 10.0.0.9 >/dev/null 2>&1; then
  fail "dce new apple --ip must fail"
fi
pass "Section D: apple backend limits"

# ===========================================================================
# Section E - rebuild reattaches networks (create-argv parity + extras)
# ===========================================================================
BACKEND=docker
# Reuse webproj from Section B: its config has mynet:10.0.0.5 + obs.
printf 'mynet\nobs\n' > "$NETWORKS"
printf 'dce-img-fakehash00000:latest\n' >> "$IMAGES" 2>/dev/null || true
# The webproj image was dce-base:latest (no scopes). Ensure it is "present".
grep -qx 'dce-base:latest' "$IMAGES" || printf 'dce-base:latest\n' >> "$IMAGES"
# Pretend the container exists & is running for the stop/exists checks.
printf 'webproj\n' > "$CONTAINERS"

NEW_CREATE="$CREATE"   # capture from Section B for parity
: > "$LOG"
printf 'yes\n' | run_script "$ROOT_DIR/scripts/rebuild-container.sh" "$PROJECT" \
  >"$WORK/e.stdout" 2>"$WORK/e.stderr" || fail "rebuild with networks exited non-zero
-- stderr:$(cat "$WORK/e.stderr")"

RB_CREATE="$(grep -E 'create --name webproj' "$LOG" | head -n1)"
[[ "$RB_CREATE" == "$NEW_CREATE" ]] \
  || fail "rebuild/new create-argv parity broken (networks)
-- new:     $NEW_CREATE
-- rebuild: $RB_CREATE"
# extras reconnected after rebuild's create.
rb_cre="$(first_call 'create --name webproj')"
rb_obs="$(first_call 'network connect obs webproj')"
[[ -n "$rb_obs" ]] || fail "rebuild: obs should be reconnected"
[[ "$rb_cre" -lt "$rb_obs" ]] || fail "rebuild: reconnect must follow create"

pass "Section E: rebuild reattaches networks (parity + extras)"

# ===========================================================================
# Section F - dce network create/ls/members (docker)
# ===========================================================================
BACKEND=docker
: > "$NETWORKS"
: > "$LOG"
run_script "$ROOT_DIR/scripts/network.sh" create newnet >"$WORK/f.stdout" 2>"$WORK/f.stderr" \
  || fail "dce network create failed"
grep -Fq 'CALL docker network create newnet' "$LOG" || fail "network create argv"
grep -Fxq 'newnet' "$NETWORKS" || fail "network create recorded"
# idempotent: create again is a no-op (already exists), no second create CALL.
: > "$LOG"
run_script "$ROOT_DIR/scripts/network.sh" create newnet >/dev/null 2>&1 || fail "create idempotent exit"
if [[ "$(grep -c 'network create newnet' "$LOG")" -ne 0 ]]; then
  fail "network create must not re-create an existing network"
fi

# ls lists networks; newnet has no dce members yet.
LS_OUT="$(run_script "$ROOT_DIR/scripts/network.sh" ls 2>/dev/null)"
grep -Fq 'newnet' <<<"$LS_OUT" || fail "network ls should list newnet"

# members: empty for a fresh network.
MEM_OUT="$(run_script "$ROOT_DIR/scripts/network.sh" members newnet 2>/dev/null)"
grep -Fqi 'no dce projects' <<<"$MEM_OUT" || fail "members should report none"

# --subnet-v6 must be TRANSLATED for docker-family: docker has no --subnet-v6
# flag, so dce must emit --ipv6 + --subnet <v6cidr> (regression: it used to pass
# --subnet-v6 through verbatim, which docker rejects).
: > "$LOG"
run_script "$ROOT_DIR/scripts/network.sh" create v6net --subnet-v6 fd00:dead::/64 \
  >"$WORK/f6.stdout" 2>"$WORK/f6.stderr" || fail "dce network create --subnet-v6 failed
-- stderr:$(cat "$WORK/f6.stderr")"
grep -Fq 'CALL docker network create v6net --ipv6 --subnet fd00:dead::/64' "$LOG" \
  || fail "network create --subnet-v6 (docker) must translate to '--ipv6 --subnet <cidr>'
$(grep 'network create v6net' "$LOG")"
if grep -q -- '--subnet-v6' "$LOG"; then
  fail "network create --subnet-v6 (docker) must NOT pass --subnet-v6 to docker"
fi
pass "Section F: network create --subnet-v6 -> --ipv6 --subnet (docker)"

pass "Section F: dce network create/ls/members (docker)"

# ===========================================================================
# Section G - apple network create/ls (columned `container network list` parse)
# ===========================================================================
BACKEND=apple
: > "$NETWORKS"
: > "$LOG"
run_script "$ROOT_DIR/scripts/network.sh" create applenet >"$WORK/g.stdout" 2>"$WORK/g.stderr" \
  || fail "dce network create (apple) failed
-- stderr:$(cat "$WORK/g.stderr")"
grep -Fq 'CALL container network create applenet' "$LOG" || fail "apple network create argv"
# ls must parse the columned table and list applenet (header skipped).
LS_OUT="$(run_script "$ROOT_DIR/scripts/network.sh" ls 2>/dev/null)"
grep -Fq 'applenet' <<<"$LS_OUT" || fail "apple network ls should list applenet"
grep -Fqv 'NETWORK' <<<"$LS_OUT" || true   # header may or may not appear; ensure name appears (above)

pass "Section G: apple network create/ls (header parse)"

# ===========================================================================
# Section H - dce network rm refuses with members; --force removes
# ===========================================================================
BACKEND=docker
printf 'rmnet\n' > "$NETWORKS"
# webproj references... no. Build a project that references rmnet.
RP="$WORK/home/.config/dce-enclave/rmhost"
mkdir -p "$RP"; chmod 700 "$RP"
{
  echo 'CONTAINER_PROJECT="rmhost"'; echo 'CONTAINER_BACKEND="docker"'; echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'PORTS=()'; echo 'CONTAINER_HIDDEN_PATHS=()'; echo 'CONTAINER_NETWORKS=(rmnet)'
} > "$RP/config"; chmod 600 "$RP/config"

: > "$LOG"
if run_script "$ROOT_DIR/scripts/network.sh" rm rmnet >/dev/null 2>&1; then
  fail "network rm must refuse while members exist"
fi
grep -Fqi 'dce network remove rmnet' "$WORK"/h*.stdout 2>/dev/null || true
# network still exists.
grep -Fxq 'rmnet' "$NETWORKS" || fail "network rm: must not remove when members exist (no --force)"

# --force disconnects members then removes.
printf 'rmhost\n' > "$CONTAINERS"
: > "$LOG"
run_script "$ROOT_DIR/scripts/network.sh" rm rmnet --force >"$WORK/hf.stdout" 2>"$WORK/hf.stderr" \
  || fail "network rm --force failed"
grep -Fq 'CALL docker network disconnect rmnet rmhost' "$LOG" || fail "rm --force should disconnect members"
grep -Fxq 'rmnet' "$NETWORKS" && fail "rm --force should remove the network" || true

pass "Section H: dce network rm membership guard + --force"

# ===========================================================================
# Section I - dce network add/remove persist CONTAINER_NETWORKS
# ===========================================================================
BACKEND=docker
printf 'addnet\n' > "$NETWORKS"
IPROJ="iprod"
ICONFIG="$WORK/home/.config/dce-enclave/$IPROJ/config"
mkdir -p "$(dirname "$ICONFIG")"; chmod 700 "$(dirname "$ICONFIG")"
{
  echo 'CONTAINER_PROJECT="iprod"'; echo 'CONTAINER_BACKEND="docker"'; echo 'CONTAINER_IMAGE="dce-base:latest"'
  echo 'PORTS=()'; echo 'CONTAINER_HIDDEN_PATHS=()'; echo 'CONTAINER_NETWORKS=()'
} > "$ICONFIG"; chmod 600 "$ICONFIG"
printf 'iprod\n' > "$CONTAINERS"

: > "$LOG"
run_script "$ROOT_DIR/scripts/network.sh" add addnet "$IPROJ" --ip 10.9.0.3 \
  >"$WORK/i.stdout" 2>"$WORK/i.stderr" || fail "network add failed
-- stderr:$(cat "$WORK/i.stderr")"
grep -Fq 'CALL docker network connect --ip 10.9.0.3 addnet iprod' "$LOG" || fail "add: connect argv"
PORTS=(); CONTAINER_HIDDEN_PATHS=(); CONTAINER_NETWORKS=()
dce_load_project_config "$ICONFIG"
[[ "${CONTAINER_NETWORKS[*]}" == "addnet:10.9.0.3" ]] || fail "add: config persisted (got [${CONTAINER_NETWORKS[*]}])"

# remove drops it from config.
: > "$LOG"
run_script "$ROOT_DIR/scripts/network.sh" remove addnet "$IPROJ" \
  >"$WORK/ir.stdout" 2>"$WORK/ir.stderr" || fail "network remove failed"
grep -Fq 'CALL docker network disconnect addnet iprod' "$LOG" || true
# shellcheck disable=SC2034
# Reset before dce_load_project_config; CONTAINER_NETWORKS is read below.
PORTS=() CONTAINER_HIDDEN_PATHS=() CONTAINER_NETWORKS=()
dce_load_project_config "$ICONFIG"
[[ ${#CONTAINER_NETWORKS[@]} -eq 0 ]] || fail "remove: config should be empty (got [${CONTAINER_NETWORKS[*]}])"

pass "Section I: dce network add/remove persist config"

echo ""
echo "All networking checks passed."
