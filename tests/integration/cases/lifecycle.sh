#!/usr/bin/env bash
# =============================================================================
# tests/integration/cases/lifecycle.sh - Real-backend lifecycle + fixture-heavy
# flag flows that do NOT fit the generic data-driven matrix engine.
#
# Covers the documented flags the matrix leaves to bespoke cases:
#   --config --repo --hide --from-snap --rotate-keys --network --ip --follow
#   network: --subnet --subnet-v6 --force (create/add/remove/rm/members/ls)
# plus the full baseline lifecycle per backend, `rebuild-image base`, and the
# two-repo schema-v2 flow (repo-prefixed hidden volume + persistent managed
# /workspace/.cache across `rebuild-container`).
#
# Every case creates its project(s) via it_dce new + it_register_project, so the
# harness per-case + global finalizer remove them. Networks are registered via
# it_register_network.
#
# Entry point (called by run-all.sh once per selected backend):
#   it_cases_lifecycle <backend>
# =============================================================================
set -uo pipefail

# Create + register a baseline project for <case>; echoes the project name on
# stdout. Returns nonzero (no output) if creation fails so the caller can record.
_it_mkproj() {  # <backend> <case_id>
  local p
  p="$(it_project_name "$1" "$2")"
  if ! it_dce "$1" "$2" new "$p" >/dev/null; then
    return 1
  fi
  it_register_project "$p" "$1"
  printf '%s\n' "$p"
}

# ---------------------------------------------------------------------------
# Full baseline lifecycle: new -> start -> stop -> restart -> status -> list ->
# shell (non-interactive) -> exec. (rm is handled by the harness per-case.)
# ---------------------------------------------------------------------------
_it_lc_full() {  # <backend> <case_id>
  local b="$1" c="$2" p
  p="$(_it_mkproj "$b" "$c")" || { it_case_fail "dce new (baseline) failed"; return 1; }

  it_dce "$b" "$c" start   "$p" >/dev/null || { it_case_fail "start";   return 1; }
  it_dce "$b" "$c" stop    "$p" >/dev/null || { it_case_fail "stop";    return 1; }
  it_dce "$b" "$c" restart "$p" >/dev/null || { it_case_fail "restart"; return 1; }
  it_dce "$b" "$c" status            >/dev/null || { it_case_fail "status"; return 1; }
  it_dce "$b" "$c" list              >/dev/null || { it_case_fail "list";   return 1; }
  # Non-interactive shell + raw exec against the running container.
  it_dce "$b" "$c" shell   "$p" id   >/dev/null || { it_case_fail "shell id"; return 1; }
  it_dce "$b" "$c" exec    "$p" id   >/dev/null || { it_case_fail "exec id";  return 1; }
  return 0
}

# --config: load an explicit recipe file (key=value) as defaults.
_it_lc_new_config() {  # <backend> <case_id>
  local b="$1" c="$2" recipe p out rc
  recipe="$IT_ROOT_WS/$c.recipe"
  printf 'cpus=2\nmemory=512m\n' > "$recipe" || { it_case_fail "could not write recipe fixture"; return 1; }
  p="$(it_project_name "$b" "$c")"
  out="$(it_dce_capture "$b" "$c" new "$p" --config "$recipe")" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "dce new --config exited $rc"; return 1; }
  it_register_project "$p" "$b"
  return 0
}

# --repo: override the repo mount location.
_it_lc_new_repo() {  # <backend> <case_id>
  local b="$1" c="$2" path p out rc repo_name
  path="$IT_REPOS_DIR/$c-repo"
  mkdir -p "$path"
  p="$(it_project_name "$b" "$c")"
  it_dce "$b" "$c" new "$p" --repo "$path" >/dev/null && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "dce new --repo exited $rc"; return 1; }
  it_register_project "$p" "$b"
  repo_name="$(basename "$path")"
  out="$(it_dce_capture "$b" "$c" repo list "$p")" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "repo list after --repo exited $rc"; return 1; }
  [[ "$out" == *"$repo_name=$path"* ]] \
    || { it_case_fail "repo list does not report the explicit --repo path (got: $out)"; return 1; }
  return 0
}

# --repo <name>=<path> (repeatable): a two-repo schema-v2 project. `repo list`
# must report both entries (one `name=path` line per repo), and exec must land
# in the right cwd: with no --repo a multi-repo project defaults to the project
# root /workspace, and --repo <name> cds to that repo's /workspace/<name> mount.
#
# The same project also carries a repo-prefixed hidden volume and proves the
# managed-cache contract on a real backend:
#   --hide web/node_modules -> a dedicated named volume at
#     /workspace/web/node_modules. On a multi-repo project the unprefixed
#     shorthand is ambiguous and MUST be repo-prefixed (normalization rules are
#     pinned by unit/contract tiers; here we prove the real mount + lifecycle).
#   /workspace/.cache       -> the dce-managed volume whose content MUST
#     survive `dce rebuild-container` (default clean rebuild).
# Three markers with different fates across the rebuild discriminate the mount
# kinds: .cache content persists, the user hidden volume gets the documented
# clean-slate wipe and returns as a fresh mount (create/rebuild mount parity),
# and the repo bind keeps showing host state (host-side marker).
#
# Capability gate: named volumes are backend-VM-internal and are asserted on
# EVERY backend. Repo-bind CONTENT flow (host<->container) additionally needs
# the backend VM to share the host repos dir; stock colima only mounts ~ and
# /tmp/colima into its VM, so /tmp test repos are invisible inside the
# container there. That is an environment capability gap, not a dce bug, so
# only the bind-content assertions are skip-gated (two-way probe, actionable
# guidance), and the gate is decided BEFORE the rebuild so the volume/rebuild
# assertions always run -- the skip can never mask them.
_it_lc_new_repos_multi() {  # <backend> <case_id>
  local b="$1" c="$2" web api p out rc bind_shared
  web="$IT_REPOS_DIR/$c-web"
  api="$IT_REPOS_DIR/$c-api"
  mkdir -p "$web" "$api"
  # Host-side repo marker: visible in-container through the bind (where the
  # backend shares the path), and it must still be there after a rebuild
  # (repos are host state, never container FS).
  printf 'repo-bind\n' > "$web/.dce-it-repo-marker"
  p="$(it_project_name "$b" "$c")"
  it_dce "$b" "$c" new "$p" --repo "web=$web" --repo "api=$api" \
    --hide web/node_modules >/dev/null && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "dce new --repo x2 --hide exited $rc"; return 1; }
  it_register_project "$p" "$b"

  # Config layer: both named entries exist for the project, and the hidden
  # path was persisted repo-prefixed.
  out="$(it_dce_capture "$b" "$c" repo list "$p")" && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"web="* && "$out" == *"api="* ]] \
    || { it_case_fail "repo list missing web/api entries (got: $out)"; return 1; }
  out="$(it_dce_capture "$b" "$c" status "$p")" && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"web/node_modules"* ]] \
    || { it_case_fail "status does not report hidden path web/node_modules (got: $out)"; return 1; }

  # Runtime layer: default cwd is the multi-repo root; --repo pins the cwd to
  # that repo's in-container mount.
  it_dce "$b" "$c" start "$p" >/dev/null || { it_case_fail "start"; return 1; }
  out="$(it_dce_capture "$b" "$c" exec "$p" pwd)" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "exec pwd exited $rc (got: $out)"; return 1; }
  printf '%s\n' "$out" | grep -Fxq '/workspace' \
    || { it_case_fail "exec pwd not under /workspace (got: $out)"; return 1; }
  out="$(it_dce_capture "$b" "$c" exec "$p" --repo web pwd)" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "exec --repo web pwd exited $rc (got: $out)"; return 1; }
  printf '%s\n' "$out" | grep -Fxq '/workspace/web' \
    || { it_case_fail "exec --repo web pwd not /workspace/web (got: $out)"; return 1; }
  out="$(it_dce_capture "$b" "$c" exec "$p" --repo api pwd)" && rc=0 || rc=$?
  [[ $rc -eq 0 ]] || { it_case_fail "exec --repo api pwd exited $rc (got: $out)"; return 1; }
  printf '%s\n' "$out" | grep -Fxq '/workspace/api' \
    || { it_case_fail "exec --repo api pwd not /workspace/api (got: $out)"; return 1; }

  # Hidden-volume layer: the repo-prefixed path is a REAL mount point (same
  # findmnt check the product itself runs at create/start) and both in-volume
  # markers seed cleanly. All backend-VM-internal -- no host-sharing needed.
  it_dce "$b" "$c" exec "$p" sh -c 'findmnt -M /workspace/web/node_modules >/dev/null' \
    || { it_case_fail "web/node_modules is not a mount point"; return 1; }
  it_dce "$b" "$c" exec "$p" sh -c 'findmnt -M /workspace/.cache >/dev/null' \
    || { it_case_fail "/workspace/.cache is not a mount point"; return 1; }
  it_dce "$b" "$c" exec "$p" sh -c \
    'printf "hidden-vol\n" > /workspace/web/node_modules/.dce-it-marker' \
    || { it_case_fail "cannot write into web/node_modules hidden volume"; return 1; }
  it_dce "$b" "$c" exec "$p" sh -c \
    'printf "cache-vol\n" > /workspace/.cache/.dce-it-marker' \
    || { it_case_fail "cannot write into managed /workspace/.cache volume"; return 1; }

  # Repo-bind content probe (BOTH directions, pre-rebuild): write through the
  # bind VM->host, and read the host marker host->VM. Decides bind_shared
  # BEFORE the rebuild; the gated assertions below run only when both ways
  # work, so a skip here never masks the volume/rebuild assertions.
  bind_shared=1
  it_dce "$b" "$c" exec "$p" sh -c \
    'printf "vm-probe\n" > /workspace/web/.dce-it-vm-marker' || bind_shared=0
  if [[ $bind_shared -eq 1 && ! -f "$web/.dce-it-vm-marker" ]]; then
    bind_shared=0
  fi
  if [[ $bind_shared -eq 1 ]]; then
    out="$(it_dce_capture "$b" "$c" exec "$p" cat /workspace/web/.dce-it-repo-marker)" \
      && rc=0 || rc=$?
    [[ $rc -eq 0 && "$out" == *"repo-bind"* ]] || bind_shared=0
  fi

  # Rebuild on the live volumes (default clean slate). The recreated container
  # is left running by rebuild-container, so exec works immediately.
  it_dce "$b" "$c" rebuild-container "$p" --yes >/dev/null \
    || { it_case_fail "rebuild-container"; return 1; }

  # The managed /workspace/.cache volume is deliberately preserved...
  out="$(it_dce_capture "$b" "$c" exec "$p" cat /workspace/.cache/.dce-it-marker)" \
    && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"cache-vol"* ]] \
    || { it_case_fail ".cache did not persist across rebuild (got: $out)"; return 1; }
  # ...while user hidden volumes get the documented clean-slate wipe...
  it_dce "$b" "$c" exec "$p" sh -c 'test ! -e /workspace/web/node_modules/.dce-it-marker' \
    || { it_case_fail "hidden volume web/node_modules was NOT wiped by clean rebuild"; return 1; }
  # ...and return as a fresh mount (create/rebuild mount parity).
  it_dce "$b" "$c" exec "$p" sh -c 'findmnt -M /workspace/web/node_modules >/dev/null' \
    || { it_case_fail "web/node_modules not re-mounted after rebuild"; return 1; }

  # Repo-bind content assertions (gated; see the capability-gate comment).
  if [[ $bind_shared -eq 0 ]]; then
    it_case_skip \
      "backend VM does not share the host repos dir ($IT_REPOS_DIR) with the container (bind content invisible in one or both directions); repo-bind content checks skipped -- cwd, hidden-volume and .cache checks all ran. Fix the backend mount config to run them (e.g. colima: add the repos dir to the VM mounts)."
    return 0
  fi
  # ...repo binds are host state: the VM->host marker survives the rebuild on
  # the host, and host content is still visible in the recreated container.
  [[ -f "$web/.dce-it-vm-marker" ]] \
    || { it_case_fail "VM->host bind marker lost after rebuild: $web/.dce-it-vm-marker"; return 1; }
  out="$(it_dce_capture "$b" "$c" exec "$p" cat /workspace/web/.dce-it-repo-marker)" \
    && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"repo-bind"* ]] \
    || { it_case_fail "repo bind web/ lost host marker after rebuild (got: $out)"; return 1; }
  return 0
}

# --follow: bounded follow must not hang. Uses it_timeout so the suite never
# blocks on a -f stream; PASS if it returns within budget (124 = timeout, the
# expected "followed until killed" outcome) or 0.
#
# Budget is backend-aware: podman is daemonless and can be slower to attach a
# follow stream (especially on WSL2), so it gets a larger default. A workflow
# can override per-run via INTEGRATION_LOGS_FOLLOW_TIMEOUT.
_it_lc_logs_follow() {  # <backend> <case_id>
  local b="$1" c="$2" p budget
  p="$(_it_mkproj "$b" "$c")" || { it_case_fail "dce new (baseline) failed"; return 1; }
  budget="${INTEGRATION_LOGS_FOLLOW_TIMEOUT:-}"
  if [[ -z "$budget" ]]; then
    if [[ "$b" == "podman" ]]; then budget=8; else budget=4; fi
  fi
  [[ "$budget" =~ ^[0-9]+$ ]] || budget=4
  # The env assignment must PREFIX it_timeout (not be passed as an arg): the
  # function runs "$@" as a subprocess, so CONTAINER_BACKEND has to be in its
  # environment. 124 = followed until killed (the expected outcome); 0 = the
  # stream closed on its own. Either proves --follow does not hang the suite.
  CONTAINER_BACKEND="$b" it_timeout "$budget" "$_IT_DCE" logs "$p" --follow \
    >"$(it_log_path "$b" "$c")" 2>&1
  local rc=$?
  [[ $rc -eq 124 || $rc -eq 0 ]] || { it_case_fail "logs --follow exited $rc (expected 124/0)"; return 1; }
  return 0
}

# --from-snap + snapshot rm. Ordering matters: restoring FROM a snapshot binds
# the container to that snapshot image, which blocks `snapshot rm` (docker won't
# remove an image a running container references). So rm an UNBOUND snapshot
# first (proves snapshot rm works), then create+list+restore a second one. The
# restore-bound snapshot is reclaimed by `dce rm` at teardown (it removes the
# container first, unbinding the image).
_it_lc_snapshot_restore() {  # <backend> <case_id>
  local b="$1" c="$2" p l1 l2 out rc
  p="$(_it_mkproj "$b" "$c")" || { it_case_fail "dce new (baseline) failed"; return 1; }
  l1="$(it_snap_label "$c"-rm)"
  l2="$(it_snap_label "$c"-restore)"

  # Create + immediately remove an UNBOUND snapshot (nothing references it yet).
  it_dce "$b" "$c" snapshot "$p" "$l1" --yes >/dev/null \
    || { it_case_fail "snapshot create"; return 1; }
  it_dce "$b" "$c" snapshot rm "$p" "$l1" >/dev/null \
    || { it_case_fail "snapshot rm (unbound)"; return 1; }

  # Create a second snapshot; snapshots list <project> must mention it.
  it_dce "$b" "$c" snapshot "$p" "$l2" --yes >/dev/null \
    || { it_case_fail "snapshot create (2)"; return 1; }
  out="$(it_dce_capture "$b" "$c" snapshots list "$p")" && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"$l2"* ]] || { it_case_fail "snapshots list missing label '$l2'"; return 1; }

  # Restore (destroy prompt skipped via --yes). Do NOT rm $l2 here -- the
  # container now references it; cleanup reclaims it after removing the container.
  it_dce "$b" "$c" rebuild-container "$p" --from-snap "$l2" --yes >/dev/null \
    || { it_case_fail "rebuild-container --from-snap"; return 1; }
  return 0
}

# --rotate-keys: old key backed up, new key generated. The rotate-key pause
# prompt needs an Enter on stdin even under --yes, so it_dce_in feeds one.
_it_lc_rebuild_rotate_keys() {  # <backend> <case_id>
  local b="$1" c="$2" p pub_before pub_after secret
  p="$(_it_mkproj "$b" "$c")" || { it_case_fail "dce new (baseline) failed"; return 1; }
  secret="$HOME/.config/dc-enclave/projects/$p/ssh_key.pub"
  [[ -f "$secret" ]] || { it_case_fail "no ssh_key.pub for $p"; return 1; }
  pub_before="$(cat "$secret")"

  # Single Enter satisfies the rotate-key pause; --yes already skipped destroy.
  it_dce_in "$b" "$c" $'\n' rebuild-container "$p" --rotate-keys --yes >/dev/null \
    || { it_case_fail "rebuild-container --rotate-keys"; return 1; }

  pub_after="$(cat "$secret" 2>/dev/null || true)"
  [[ "$pub_before" != "$pub_after" && -n "$pub_after" ]] \
    || { it_case_fail "SSH key did not rotate"; return 1; }
  return 0
}

# rebuild-image base: rebuild dce-base:latest (shared, idempotent). NOT `all` --
# `all` rebuilds every derived image across user projects and is deferred to
# phase 2 (DCE_CONFIG_ROOT), per the plan.
_it_lc_rebuild_image_base() {  # <backend> <case_id>
  local b="$1" c="$2"
  it_dce "$b" "$c" rebuild-image base >/dev/null \
    || { it_case_fail "rebuild-image base"; return 1; }
  return 0
}

# config set/get roundtrip (deeper than the matrix's independent config rows).
_it_lc_config_roundtrip() {  # <backend> <case_id>
  local b="$1" c="$2" p out rc
  p="$(_it_mkproj "$b" "$c")" || { it_case_fail "dce new (baseline) failed"; return 1; }

  it_dce "$b" "$c" config set "$p" cpus=2 >/dev/null \
    || { it_case_fail "config set cpus=2"; return 1; }
  out="$(it_dce_capture "$b" "$c" config get "$p" cpus)" && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"2"* ]] || { it_case_fail "config get cpus not '2' (got: $out)"; return 1; }
  it_dce "$b" "$c" config show "$p" >/dev/null \
    || { it_case_fail "config show"; return 1; }
  return 0
}

# network lifecycle (docker-family only): create (--subnet) -> ls -> attach at
# create via --network name:ip -> members -> add/remove/rm --force.
# (--subnet-v6 is exercised by _it_lc_network_subnet_v6_gap; it is NOT used here
# because the product currently passes it straight through to docker, which has
# no such flag -- see that case for the documented gap.)
_it_lc_network_lifecycle() {  # <backend> <case_id>
  local b="$1" c="$2" net p1 p2
  # Rootless podman cannot live-attach a running container to a user-defined
  # network with a static IP: `podman network connect --ip` fails with "pasta is
  # not supported: invalid network mode" (a pasta-netns limitation, not a dce
  # bug). Static IP at create time works; only the live `network add --ip` step
  # in this case is unsupported, so skip the whole case on podman rather than
  # weaken it. (docker/colima/orbstack run it in full.)
  if [[ "$b" == "podman" ]]; then
    it_case_skip "rootless podman: live network attach with --ip is unsupported (pasta netns limitation)"
    return 0
  fi
  net="$(it_network_name "$b" "$c")"
  # Unusual subnet to reduce the chance of colliding with a host network.
  it_dce "$b" "$c" network create "$net" --subnet 10.200.0.0/24 \
    >/dev/null || { it_case_fail "network create --subnet"; return 1; }
  it_register_network "$net" "$b"

  it_dce "$b" "$c" network ls >/dev/null || { it_case_fail "network ls"; return 1; }

  # First project pinned to a static IP at create time (name:ip form).
  p1="$(it_project_name "$b" "$c"-p1)"
  it_dce "$b" "$c" new "$p1" --network "$net":10.200.0.5 >/dev/null \
    || { it_case_fail "dce new --network name:ip"; return 1; }
  it_register_project "$p1" "$b"

  it_dce "$b" "$c" network members "$net" >/dev/null \
    || { it_case_fail "network members"; return 1; }

  # Second project live-attached via `network add --ip`, then detached.
  p2="$(it_project_name "$b" "$c"-p2)"
  it_dce "$b" "$c" new "$p2" >/dev/null || { it_case_fail "dce new p2"; return 1; }
  it_register_project "$p2" "$b"
  it_dce "$b" "$c" network add "$net" "$p2" --ip 10.200.0.6 >/dev/null \
    || { it_case_fail "network add --ip"; return 1; }
  it_dce "$b" "$c" network remove "$net" "$p2" >/dev/null \
    || { it_case_fail "network remove"; return 1; }

  # rm --force while members exist (p1 is still a member).
  it_dce "$b" "$c" network rm "$net" --force >/dev/null \
    || { it_case_fail "network rm --force"; return 1; }
  return 0
}

# apple/container: --ip is unsupported and network live-attach (add/remove) is
# refused. `dce new --network <net> --ip <addr>` must fail on apple.
_it_lc_network_apple_unsupported() {  # <backend> <case_id>
  local b="$1" c="$2" net p rc
  net="$(it_network_name "$b" "$c")"
  # apple supports network create (sets networks at create time).
  it_dce "$b" "$c" network create "$net" >/dev/null \
    || { it_case_fail "apple network create"; return 1; }
  it_register_network "$net" "$b"

  p="$(it_project_name "$b" "$c")"
  it_dce "$b" "$c" new "$p" --network "$net" --ip 10.200.0.5 >/dev/null && rc=0 || rc=$?
  [[ $rc -ne 0 ]] || { it_case_fail "apple: --ip should be unsupported (got exit 0)"; return 1; }
  return 0
}

it_cases_lifecycle() {  # <backend>
  local b="$1"
  it_run_case "$b" "lifecycle-full"         _it_lc_full
  it_run_case "$b" "new-config"             _it_lc_new_config
  it_run_case "$b" "new-repo"               _it_lc_new_repo
  it_run_case "$b" "new-repos-multi"        _it_lc_new_repos_multi
  it_run_case "$b" "logs-follow"            _it_lc_logs_follow
  it_run_case "$b" "snapshot-restore"       _it_lc_snapshot_restore
  it_run_case "$b" "rebuild-rotate-keys"    _it_lc_rebuild_rotate_keys
  it_run_case "$b" "rebuild-image-base"     _it_lc_rebuild_image_base
  it_run_case "$b" "config-roundtrip"       _it_lc_config_roundtrip

  if [[ "$b" == "apple" ]]; then
    it_run_case "$b" "network-apple-unsupported" _it_lc_network_apple_unsupported
  else
    it_run_case "$b" "network-lifecycle"     _it_lc_network_lifecycle
    it_run_case "$b" "network-subnet-v6"     _it_lc_network_subnet_v6
  fi
}

# Asserts DOCUMENTED `--subnet-v6` support (docs/reference/flags.md +
# scripts/network.sh usage). Expects success: scripts/network.sh translates
# `--subnet-v6 <cidr>` into `docker network create --ipv6 --subnet <v6cidr>`
# (docker-family has no --subnet-v6 flag). Translation correctness is pinned by
# the stubbed contract test (tests/contract/networks.sh Section F); this case
# confirms it against a REAL backend.
#
# Capability-gated, not a hard failure: some docker-family backends disable IPv6
# by default at the engine level (OrbStack ships with IPv6 off -- enable it in
# OrbStack settings or set `"ipv6": true` in the engine config). When the v6
# create fails but a plain (non-v6) network create succeeds on the same backend,
# the gap is a backend IPv6 capability, not a dce regression, so the case SKIPs
# with actionable guidance. A failure of the plain create too is a real bug ->
# FAIL.
_it_lc_network_subnet_v6() {  # <backend> <case_id>
  local b="$1" c="$2" net probe rc probe_rc
  net="$(it_network_name "$b" "$c")"
  it_dce "$b" "$c" network create "$net" --subnet-v6 fd00:dead::/64 >/dev/null && rc=0 || rc=$?
  if [[ $rc -eq 0 ]]; then
    it_register_network "$net" "$b"
    return 0
  fi

  # v6 create failed. Distinguish a backend IPv6-capability gap (skip) from a
  # real regression (fail) by attempting a plain IPv4 network create on the same
  # backend: if plain works, the backend is healthy and the gap is IPv6-specific.
  probe="$(it_network_name "$b" "$c")-probe"
  it_dce "$b" "$c" network create "$probe" --subnet 10.201.0.0/24 >/dev/null && probe_rc=0 || probe_rc=$?
  if [[ $probe_rc -eq 0 ]]; then
    it_dce "$b" "$c" network rm "$probe" --force >/dev/null 2>&1 || true
    it_case_skip "backend does not support IPv6 networks by default (create --subnet-v6 failed but plain create succeeded); on OrbStack, enable IPv6 in settings or set \"ipv6\": true in the engine config"
    return 0
  fi
  it_case_fail "network create --subnet-v6 exited $rc AND plain create also failed ($probe_rc) -- backend unhealthy"
  return 1
}
