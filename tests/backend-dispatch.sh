#!/usr/bin/env bash
# =============================================================================
# tests/backend-dispatch.sh - Dispatch matrix for lib/container-backend.sh.
#
# Every backend_* function is a `case` over {apple, docker, orbstack, colima,
# podman}. The per-backend argv divergences (apple `container exec --uid 0` vs
# docker `<cli> exec -u 0`; apple `container delete` vs docker `<cli> rm -f`;
# apple `container volume delete` vs `<cli> volume rm`; podman's extra
# `--add-host host.docker.internal=host-gateway`) are exactly where silent
# regressions hide. This pins each function's argv per backend.
#
# Approach: install stub `docker`/`container`/`podman` on a private PATH so each
# logs `CALL <argv>`; set DEV_CONTAINERS_BACKEND + _DC_CLI directly to exercise
# dispatch WITHOUT triggering auto-detection or context pinning (separate
# concerns). Detection noise (docker `context show`, re-issued by backend_cli
# for colima) is filtered from the comparison.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/container-backend.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

LOG="$WORK/calls.log"
export DC_STUB_LOG="$LOG"

# ---------------------------------------------------------------------------
# Stub CLIs: one script installed under three names. Always logs the argv;
# answers the few read subcommands the dispatch paths issue.
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/_backend_stub" <<'STUB'
#!/usr/bin/env bash
_log="${DC_STUB_LOG:?}"
# Log the resolved command name + argv so assertions can pin the full shape
# (the stub is installed under the docker/container/podman names).
printf 'CALL %s %s\n' "$(basename "$0")" "$*" >> "$_log"
case "$(basename "$0")" in
  docker)
    # backend_cli re-checks the context for colima; answer with a colima name.
    if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then
      printf 'colima\n'
    fi
    ;;
  podman)
    # _backend_podman_supports_host_gateway probes `podman create --help`.
    if [[ "${1:-}" == "create" && "${2:-}" == "--help" ]]; then
      [[ "${DC_STUB_PODMAN_HOST_GW:-0}" == "1" ]] && printf 'host-gateway\n'
    fi
    ;;
  container) : ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/_backend_stub"
cp "$STUB_DIR/_backend_stub" "$STUB_DIR/docker"
cp "$STUB_DIR/_backend_stub" "$STUB_DIR/container"
cp "$STUB_DIR/_backend_stub" "$STUB_DIR/podman"
export PATH="$STUB_DIR:$PATH"

# Compare the set of distinct CALL lines (sans detection noise) to the expected
# set. Variadic: pass one expected line per remaining arg.
expect_logged() {
  local label="$1"; shift
  local got want
  got="$(grep '^CALL ' "$LOG" | grep -v 'context show' | sort -u)"
  want="$(printf 'CALL %s\n' "$@" | sort -u)"
  if [[ "$got" == "$want" ]]; then
    pass "$label"
  else
    fail "$label
-- expected:
$want
-- got:
$got"
  fi
}

# Expected dispatch argv per (backend, bin, func). Divergent apple shapes are
# explicit; uniform ones use $bin (== _DC_CLI, == the dispatched binary for
# every backend since apple also drives `container`).
dispatch_expected() {
  local backend="$1" bin="$2" func="$3"
  local s=""
  case "$func" in
    build_image)      s="$bin build --tag img:latest --file /tmp/cf /ctx" ;;
    image_exists)     s="$bin image ls --format {{.Repository}}:{{.Tag}}" ;;
    image_id)
      [[ "$backend" == apple ]] && s="container image inspect img:latest --format {{.ID}}" \
                                 || s="$bin image inspect img:latest --format {{.Id}}" ;;
    list_images)      s="$bin image ls --format {{.Repository}}\t{{.Tag}}\t{{.ID}}" ;;
    remove_image)     s="$bin image rm img:1" ;;
    list_volumes)
      [[ "$backend" == apple ]] && s="container volume list --format json" || s="$bin volume ls --format {{.Name}}" ;;
    remove_volume)
      [[ "$backend" == apple ]] && s="container volume delete vol1"        || s="$bin volume rm vol1" ;;
    list_running)     s="$bin ps" ;;
    list_all)         s="$bin ps -a" ;;
    exists)
      [[ "$backend" == apple ]] && s="container ps -a"                      || s="$bin ps -a --format {{.Names}}" ;;
    is_running)
      [[ "$backend" == apple ]] && s="container ps"                         || s="$bin ps --format {{.Names}}" ;;
    create)           s="$bin create --name myproj --volume src:dst img:latest" ;;
    start)            s="$bin start myproj" ;;
    stop)             s="$bin stop myproj" ;;
    logs)
      # apple/container exposes line count as -n <n> (it has no --tail), so the
      # backend_logs translation must emit -n there; docker-family keeps --tail.
      [[ "$backend" == apple ]] && s="container logs -f -n 50 myproj" \
                                 || s="$bin logs -f --tail 50 myproj" ;;
    delete)
      [[ "$backend" == apple ]] && s="container delete myproj"              || s="$bin rm -f myproj" ;;
    exec)             s="$bin exec myproj whoami" ;;
    exec_as_root)
      [[ "$backend" == apple ]] && s="container exec --uid 0 myproj whoami" || s="$bin exec -u 0 myproj whoami" ;;
    exec_stdin)       s="$bin exec -i myproj whoami" ;;
    exec_interactive) s="$bin exec -it --env K=V myproj whoami" ;;
    *) fail "dispatch_expected: unknown func $func" ;;
  esac
  printf '%s\n' "$s"
}

# Invoke backend_<func> with fixed sample args.
call_func() {
  case "$1" in
    build_image)      backend_build_image img:latest /tmp/cf /ctx ;;
    image_exists)     backend_image_exists img:latest ;;
    image_id)         backend_image_id img:latest ;;
    list_images)      backend_list_images ;;
    remove_image)     backend_remove_image img:1 ;;
    list_volumes)     backend_list_volumes ;;
    remove_volume)    backend_remove_volume vol1 ;;
    list_running)     backend_list_running ;;
    list_all)         backend_list_all ;;
    exists)           backend_exists myproj ;;
    is_running)       backend_is_running myproj ;;
    create)           backend_create myproj img:latest --volume src:dst ;;
    start)            backend_start myproj ;;
    stop)             backend_stop myproj ;;
    logs)             backend_logs myproj true 50 ;;
    delete)           backend_delete myproj ;;
    exec)             backend_exec myproj whoami ;;
    exec_as_root)     backend_exec_as_root myproj whoami ;;
    exec_stdin)       backend_exec_stdin myproj whoami ;;
    exec_interactive) backend_exec_interactive myproj --env K=V -- whoami ;;
    *) fail "call_func: unknown func $1" ;;
  esac
}

FUNCS=(build_image image_exists image_id list_images remove_image list_volumes remove_volume \
       list_running list_all exists is_running create start stop logs delete \
       exec exec_as_root exec_stdin exec_interactive)

# ---------------------------------------------------------------------------
# Matrix: every backend x every dispatch function.
# ---------------------------------------------------------------------------
for spec in "apple container" "docker docker" "orbstack docker" "colima docker" "podman podman"; do
  read -r backend bin <<< "$spec"
  DEV_CONTAINERS_BACKEND="$backend"
  _DC_CLI="$bin"
  _DC_PODMAN_HOST_GATEWAY_SUPPORTED=""
  _DC_PODMAN_HOST_GATEWAY_WARNED=0

  for func in "${FUNCS[@]}"; do
    # podman create is exercised separately (host-gateway branch).
    [[ "$func" == create && "$backend" == podman ]] && continue
    : > "$LOG"
    call_func "$func" >/dev/null 2>&1 </dev/null || true
    expect_logged "$backend / $func" "$(dispatch_expected "$backend" "$bin" "$func")"
  done
done

# ---------------------------------------------------------------------------
# podman create: host-gateway alias applied only when supported (+ probe call).
# ---------------------------------------------------------------------------
DEV_CONTAINERS_BACKEND=podman; _DC_CLI=podman
export DC_STUB_PODMAN_HOST_GW=1
_DC_PODMAN_HOST_GATEWAY_SUPPORTED=""; _DC_PODMAN_HOST_GATEWAY_WARNED=0
: > "$LOG"
backend_create myproj img:latest --volume src:dst >/dev/null 2>&1 </dev/null || true
expect_logged "podman / create (host-gateway supported)" \
  "podman create --help" \
  "podman create --name myproj --volume src:dst --add-host host.docker.internal=host-gateway img:latest"

# Unsupported: no --add-host, and the one-time warning path is taken.
export DC_STUB_PODMAN_HOST_GW=0
_DC_PODMAN_HOST_GATEWAY_SUPPORTED=""; _DC_PODMAN_HOST_GATEWAY_WARNED=0
: > "$LOG"
backend_create myproj img:latest --volume src:dst >/dev/null 2>&1 </dev/null || true
expect_logged "podman / create (host-gateway unsupported)" \
  "podman create --help" \
  "podman create --name myproj --volume src:dst img:latest"

# ---------------------------------------------------------------------------
# backend_exec_interactive: args before "--" are exec options, after are cmd.
# (Already covered in the matrix; this restates it loudly as a regression trap
# because the "--" split is easy to break.)
# ---------------------------------------------------------------------------
DEV_CONTAINERS_BACKEND=docker; _DC_CLI=docker
: > "$LOG"
backend_exec_interactive myproj --env FOO=bar --env BAZ=qux -- run-server arg1 \
  >/dev/null 2>&1 </dev/null || true
expect_logged "docker / exec_interactive (-- option/cmd split)" \
  "docker exec -it --env FOO=bar --env BAZ=qux myproj run-server arg1"

# ---------------------------------------------------------------------------
# Network management dispatch: pins the per-backend argv divergence for
# network create/list/rm/connect/disconnect. apple uses `delete` (not `rm`),
# resolves peers as `<name>.test`, and CANNOT live-attach/detach -- those two
# must return non-zero WITHOUT invoking the CLI (no CALL line).
# ---------------------------------------------------------------------------
network_dispatch_expected() {
  local backend="$1" bin="$2" func="$3"
  case "$func" in
    network_create)
      [[ "$backend" == apple ]] && s="container network create mynet --subnet 10.0.0.0/24" \
                                || s="$bin network create mynet --subnet 10.0.0.0/24" ;;
    network_list)
      [[ "$backend" == apple ]] && s="container network list" \
                                || s="$bin network ls --format {{.Name}}" ;;
    network_rm)
      [[ "$backend" == apple ]] && s="container network delete mynet" \
                                || s="$bin network rm mynet" ;;
    network_connect)    s="$bin network connect --ip 10.0.0.5 mynet myproj" ;;
    network_disconnect) s="$bin network disconnect mynet myproj" ;;
    *) fail "network_dispatch_expected: unknown func $func" ;;
  esac
  printf '%s\n' "$s"
}

network_call_func() {
  case "$1" in
    network_create)     backend_network_create mynet --subnet 10.0.0.0/24 ;;
    network_list)       backend_network_list ;;
    network_rm)         backend_network_rm mynet ;;
    network_connect)    backend_network_connect mynet myproj --ip 10.0.0.5 ;;
    network_disconnect) backend_network_disconnect mynet myproj ;;
    *) fail "network_call_func: unknown func $1" ;;
  esac
}

for spec in "apple container" "docker docker" "orbstack docker" "colima docker" "podman podman"; do
  read -r backend bin <<< "$spec"
  # shellcheck disable=SC2034
  # Read by the backend dispatch code under test (selects the backend).
  DEV_CONTAINERS_BACKEND="$backend"
  _DC_CLI="$bin"
  _DC_PODMAN_HOST_GATEWAY_WARNED=0

  for func in network_create network_list network_rm network_connect network_disconnect; do
    # apple live-attach/detach are unsupported: no CLI call, must return non-zero.
    if [[ "$backend" == apple && ( "$func" == network_connect || "$func" == network_disconnect ) ]]; then
      : > "$LOG"
      if network_call_func "$func" >/dev/null 2>&1 </dev/null; then
        fail "$backend / $func: unsupported op must return non-zero"
      fi
      if [[ -s "$LOG" ]]; then
        fail "$backend / $func: unsupported op must not invoke the CLI
$(cat "$LOG")"
      fi
      pass "$backend / $func: refused without invoking CLI"
      continue
    fi
    : > "$LOG"
    network_call_func "$func" >/dev/null 2>&1 </dev/null || true
    expect_logged "$backend / $func" "$(network_dispatch_expected "$backend" "$bin" "$func")"
  done
done

echo ""
echo "All backend dispatch matrix checks passed."
