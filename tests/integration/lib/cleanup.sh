#!/usr/bin/env bash
# =============================================================================
# tests/integration/lib/cleanup.sh - Mandatory cleanup + leak verification.
#
# Two layers, both mandatory:
#   1. Per-case removal: harness.it_run_case runs `dce rm --yes` on every
#      project the case registered, immediately after the case body.
#   2. Global finalizer (it_cleanup, armed as the EXIT/INT/TERM trap): replays
#      `dce rm --yes` for every registered project (idempotent backstop for
#      interrupted runs), runs backend sweeps for snapshots + hidden volumes,
#      drops test networks, removes the temp workspace, and verifies zero
#      leftovers via a prefix scan. Any leftover FAILS the run and exact
#      remediation commands are printed.
#
# it_cleanup is idempotent and re-entrant (guarded by _IT_CLEANUP_RAN), so it is
# safe as a trap body AND as the runner's explicit end-of-run call.
# =============================================================================
if [[ -n "${_IT_CLEANUP_SH_LOADED:-}" ]]; then return 0; fi
declare -gr _IT_CLEANUP_SH_LOADED=1

# container-backend.sh is already loaded via backend-discovery.sh; re-source is
# a guarded no-op. We need backend_use / backend_cli / backend_network_list /
# backend_list_images / backend_list_volumes for the sweeps + leak scan.
# shellcheck disable=SC1091
source "$_IT_LIB_DIR/container-backend.sh" 2>/dev/null || true

# Global leak flag, read by the runner for the final exit code.
IT_LEAKED=0
IT_LEAK_DETAIL=""

# ----- backend listing helpers (subshell-isolated so DOCKER_CONTEXT never leaks) -

# Print every container name on <backend> (one per line), best-effort.
_it_container_names() {  # <backend>
  (
    backend_use "$1" >/dev/null 2>&1 || exit 0
    case "$1" in
      apple) container ls -a -q 2>/dev/null ;;
      *)     "$(backend_cli)" ps -a --format '{{.Names}}' 2>/dev/null ;;
    esac
  )
}

# Print leftover resource lines for ONE backend matching this run's prefixes:
#   <type>\t<name>
# where type ∈ container,network,snapshot-image,snapshot-volume,config-dir.
# Returns nonzero if at least one leftover was found. Best-effort: a backend
# that cannot be queried is skipped (cannot leak-scan an unreachable runtime).
_it_leak_scan_backend() {  # <backend>
  local backend="$1" runid="$IT_RUN_ID" found=0
  local cprefix="test-$backend-$runid-" nprefix="testnet-$backend-$runid-"
  local snapimg="dce-snap-test-$backend-$runid-" snapvol="dce-snapvol-test-$backend-$runid-"

  # Containers (docker-family via --format; apple via awk on column 1).
  local n
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if [[ "$n" == "$cprefix"* ]]; then
      printf 'container\t%s\n' "$n"; found=1
    fi
  done < <(_it_container_names "$backend")

  # Networks (uniform across backends via the lib helper).
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if [[ "$n" == "$nprefix"* ]]; then
      printf 'network\t%s\n' "$n"; found=1
    fi
  done < <(
    backend_use "$backend" >/dev/null 2>&1 && backend_network_list 2>/dev/null
  )

  # Snapshot images + snapshot volumes (repo:tag lines from backend_list_images;
  # volume names from backend_list_volumes). Both are scoped to this run via the
  # project-name token embedded in dce-snap-* / dce-snapvol-*.
  local repo tag vol
  while IFS=$'\t' read -r repo tag _; do
    if [[ "$repo" == "$snapimg"* ]]; then
      printf 'snapshot-image\t%s:%s\n' "$repo" "${tag:-latest}"; found=1
    fi
  done < <(backend_use "$backend" >/dev/null 2>&1 && backend_list_images 2>/dev/null)

  while IFS= read -r vol; do
    [[ -n "$vol" && "$vol" == "$snapvol"* ]] && { printf 'snapshot-volume\t%s\n' "$vol"; found=1; }
  done < <(backend_use "$backend" >/dev/null 2>&1 && backend_list_volumes 2>/dev/null)

  # Project config dirs under the real config root (~/.config/dce-enclave) for
  # test projects of this run. (Phase 1 uses the real config root; phase 2 will
  # isolate via DCE_CONFIG_ROOT.)
  local cfgroot="$HOME/.config/dce-enclave"
  if [[ -d "$cfgroot" ]]; then
    while IFS= read -r d; do
      printf 'config-dir\t%s\n' "$d"; found=1
    done < <(
      # shellcheck disable=SC2010
      # Glob-via-ls is intentional: dir names are controlled (test-<b>-<runid>-).
      ls -1 "$cfgroot" 2>/dev/null | grep "^$cprefix"
    )
  fi

  [[ $found -eq 0 ]] && return 1
  return 0
}

# Print exact remediation commands for the leftovers found on a backend.
_it_print_remediation() {  # <backend>  (reads leftover lines from stdin)
  local backend="$1" type name
  echo "  Remediation for $backend:"
  while IFS=$'\t' read -r type name; do
    case "$type" in
      container)        printf '    CONTAINER_BACKEND=%s %s rm %s --yes\n' "$backend" "$_IT_DCE" "$name" ;;
      network)
        if [[ "$backend" == "apple" ]]; then
          printf '    CONTAINER_BACKEND=%s container network delete %s\n' "$backend" "$name"
        else
          printf '    CONTAINER_BACKEND=%s %s network rm %s --force\n' "$backend" "$_IT_DCE" "$name"
        fi ;;
      snapshot-image|snapshot-volume)
        printf '    CONTAINER_BACKEND=%s %s clean --snapshots --dry-run  # then drop --dry-run\n' "$backend" "$_IT_DCE" ;;
      config-dir)       printf '    rm -rf %s\n' "$name" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Global finalizer (trap body + explicit end-of-run call). Idempotent.
# ---------------------------------------------------------------------------
it_cleanup() {
  [[ "${_IT_CLEANUP_RAN:-0}" -eq 1 ]] && return "${IT_CLEANUP_RC:-0}"
  _IT_CLEANUP_RAN=1

  local log="$IT_ROOT_WS/cleanup.log"

  # 1. Replay `dce rm --yes` for every registered project (idempotent backstop;
  #    per-case rm already handled the normal path). Plain --yes (no keep flags)
  #    so it is the "full removal" pass the contract requires for keep-flag cases.
  if [[ -f "$IT_REGISTRY" ]]; then
    local kind pback pname
    while IFS=$'\t' read -r kind pback pname; do
      [[ "$kind" == "project" ]] || continue
      CONTAINER_BACKEND="$pback" "$_IT_DCE" rm "$pname" --yes >>"$log" 2>&1 || true
    done < "$IT_REGISTRY"
  fi

  # 2. Backend-scoped sweeps for snapshots + hidden volumes per project.
  if [[ -f "$IT_REGISTRY" ]]; then
    local kind pback pname
    while IFS=$'\t' read -r kind pback pname; do
      [[ "$kind" == "project" ]] || continue
      CONTAINER_BACKEND="$pback" "$_IT_DCE" clean --snapshots "$pname" >>"$log" 2>&1 || true
      CONTAINER_BACKEND="$pback" "$_IT_DCE" clean --hidden-volumes "$pname" >>"$log" 2>&1 || true
    done < "$IT_REGISTRY"
  fi

  # 3. Drop test-created networks (docker-family via dce; apple via its CLI).
  if [[ -f "$IT_REGISTRY" ]]; then
    local kind pback pname
    while IFS=$'\t' read -r kind pback pname; do
      [[ "$kind" == "network" ]] || continue
      if [[ "$pback" == "apple" ]]; then
        ( backend_use apple >/dev/null 2>&1 && backend_network_rm "$pname" ) >>"$log" 2>&1 || true
      else
        CONTAINER_BACKEND="$pback" "$_IT_DCE" network rm "$pname" --force >>"$log" 2>&1 || true
      fi
    done < "$IT_REGISTRY"
  fi

  # 4. Leak verification: prefix-scan every selected backend. Collect leftovers
  #    and, on any, mark IT_LEAKED + print exact remediation. Backends that
  #    cannot be queried are skipped (best-effort).
  local backends_file="$IT_ROOT_WS/backends.tsv"
  if [[ -f "$backends_file" ]]; then
    local leftovers b
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      leftovers="$(_it_leak_scan_backend "$b" 2>/dev/null || true)"
      if [[ -n "$leftovers" ]]; then
        IT_LEAKED=1
        echo "[LEAK] leftover test resources on backend: $b" >&2
        _it_print_remediation "$b" <<< "$leftovers" >&2
        IT_LEAK_DETAIL+="$b "
      fi
    done < "$backends_file"
  fi

  # 4b. Synced-workspace leak check (registry-aware). The dce rm replay above
  #     already terminates the Mutagen session + removes the dce-sync volume for
  #     every registered project; this verifies they are actually gone. The
  #     project config is already deleted by that rm, so derive the expected
  #     volume/session name directly from the project name (dce_sync_volume_name
  #     is deterministic). A non-sync project never created that volume, so
  #     checking every registered project cannot false-positive. Volume check
  #     first (cheap, no mutagen); the session check runs only if a volume
  #     leaked. Best-effort: a backend that can't be queried is skipped.
  if [[ -f "$IT_REGISTRY" ]]; then
    local kind pback pname sync_vol sync_session
    while IFS=$'\t' read -r kind pback pname; do
      [[ "$kind" == "project" ]] || continue
      sync_vol="$(dce_sync_volume_name "$pname" 2>/dev/null)" || continue
      if ! ( backend_use "$pback" >/dev/null 2>&1 \
             && backend_list_volumes 2>/dev/null | grep -Fxq "$sync_vol" ); then
        continue   # volume already gone (the normal case, sync or not)
      fi
      IT_LEAKED=1
      echo "[LEAK] leftover sync volume on backend $pback: $sync_vol" >&2
      IT_LEAK_DETAIL+="$pback(sync-volume) "
      if command -v mutagen >/dev/null 2>&1; then
        sync_session="$(dce_sync_session_name "$pname" 2>/dev/null)" || sync_session="$sync_vol"
        if mutagen sync list "$sync_session" >/dev/null 2>&1; then
          echo "[LEAK] leftover mutagen session on backend $pback: $sync_session" >&2
          printf '    CONTAINER_BACKEND=%s mutagen sync terminate %s\n' "$pback" "$sync_session" >&2
        fi
        printf '    CONTAINER_BACKEND=%s %s rm %s --yes   # or: mutagen sync terminate %s && %s volume rm %s\n' \
          "$pback" "$_IT_DCE" "$pname" "$sync_session" "$sync_session" "$sync_vol" >&2
      else
        printf '    CONTAINER_BACKEND=%s %s rm %s --yes   # or: <backend> volume rm %s\n' \
          "$pback" "$_IT_DCE" "$pname" "$sync_vol" >&2
      fi
    done < "$IT_REGISTRY"
  fi

  # 5. Remove temp workspace + per-run artifacts tree unless asked to keep. The
  #    artifacts tree is also kept when the run failed or leaked, so the
  #    failure-pointed log paths still exist for debugging.
  local keep=0
  [[ "${INTEGRATION_KEEP_ARTIFACTS:-0}" == "1" ]] && keep=1
  if [[ $keep -eq 0 ]]; then
    # Detect any failure/leak to retain logs for diagnosis.
    if grep -q $'\tFAIL\t' "$IT_RESULTS" 2>/dev/null || [[ $IT_LEAKED -eq 1 ]]; then
      keep=1
    fi
  fi
  # Temp workspace (/tmp/dce-integration/<runid>) is always removed unless the
  # operator asked to keep artifacts: it only holds repo checkouts + logs that
  # are mirrored under the artifacts tree.
  rm -rf "${IT_ROOT_WS:?}/repos" 2>/dev/null || true
  if [[ $keep -eq 0 ]]; then
    rm -rf "${IT_ROOT_WS:?}" 2>/dev/null || true
    rm -rf "${IT_ARTIFACTS_ROOT:?}/$IT_RUN_ID" 2>/dev/null || true
  else
    echo "[cleanup] retained run workspace + artifacts (INTEGRATION_KEEP_ARTIFACTS or run failed/leaked)" >&2
    echo "  workspace: $IT_ROOT_WS" >&2
    echo "  artifacts: $IT_ARTIFACTS_ROOT/$IT_RUN_ID" >&2
  fi

  IT_CLEANUP_RC=0
  [[ $IT_LEAKED -eq 1 ]] && IT_CLEANUP_RC=2
  return "$IT_CLEANUP_RC"
}
