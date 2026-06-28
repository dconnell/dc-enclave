#!/usr/bin/env bash
# =============================================================================
# tests/integration/lib/matrix.sh - Data-driven flag matrix engine.
#
# The single source of truth for flag coverage is tests/integration/matrix/
# flags.tsv (one row per case). This engine reads that TSV and executes every
# row that applies to a given backend, so "independent flags + pairwise combos
# + backend-specific expected failures" are DATA, not bespoke scripts.
#
# flags.tsv columns (tab-separated; no literal tabs inside a field):
#   case_id        short id unique within the matrix (names the case row)
#   backend_scope  all | docker_family | apple | docker | orbstack | colima |
#                  podman | or a comma-list (e.g. docker,podman)
#   command        the dce subcommand under test (new, rm, logs, ...)
#   args           args after the project name; may contain flags + values.
#                  The token $PROJECT is substituted with the case's project
#                  name. For command=new, args are the `dce new` flags/positionals
#                  and $PROJECT is the project name.
#                  The token $NET is substituted with a unique network name.
#   expected_exit  expected exit code (0 = success, non-zero = expected fail)
#   assertions     ;-separated substring checks against combined output. Each
#                  must appear; prefix with ! to assert ABSENCE. Empty = none.
#
# Execution model (per row):
#   - A fresh project is created with `dce new $PROJECT` (baseline, no scopes).
#   - If command == new: that baseline create is skipped; the row IS the create.
#   - The command is run; exit code + assertions decide PASS/FAIL.
#   - The project is registered so it_run_case + the finalizer remove it.
# =============================================================================
if [[ -n "${_IT_MATRIX_SH_LOADED:-}" ]]; then return 0; fi
declare -gr _IT_MATRIX_SH_LOADED=1

# True (return 0) if a matrix row's backend_scope applies to <backend>.
it_matrix_applies() {  # <scope> <backend>
  local scope="$1" backend="$2"
  case "$scope" in
    all) return 0 ;;
    docker_family)
      [[ "$backend" == docker || "$backend" == orbstack || "$backend" == colima || "$backend" == podman ]]
      return $?
      ;;
    *) ;;
  esac
  # Comma-list of explicit backends.
  local s
  local IFS=','
  for s in $scope; do
    [[ "$s" == "$backend" ]] && return 0
  done
  return 1
}

# Assert one matrix assertion substring against output. `needle` may be prefixed
# with ! to require ABSENCE. Pure predicate: returns nonzero on miss, never
# records (the caller decides + records via it_case_fail).
it_matrix_check() {  # <needle> <output>
  local needle="$1" out="$2" negate=0
  if [[ "$needle" == !* ]]; then
    negate=1
    needle="${needle#!}"
    needle="${needle#"${needle%%[![:space:]]*}"}"
  fi
  if [[ $negate -eq 0 ]]; then
    [[ "$out" == *"$needle"* ]]
    return $?
  fi
  [[ "$out" != *"$needle"* ]]
}

# Run ONE matrix row for <backend>. Signature matches what it_run_case passes a
# case fn: `<fn> <backend> <case_id> <extra...>`. We pack the row fields as
# extras. Substitutes $PROJECT / $NET, sets up the baseline project, runs the
# command, and checks exit + assertions.
_it_matrix_row_fn() {  # <backend> <case_id> <scope> <command> <args> <exp_exit> <assertions>
  local backend="$1" case_id="$2" scope="$3" command="$4" args="$5" exp_exit="$6" assertions="${7:-}"
  local project net="" label
  project="$(it_project_name "$backend" "$case_id")"
  label="$(it_snap_label "$case_id")"
  # $NET is only resolved when referenced so networks aren't created needlessly.
  # The literal token $NET is matched (never expanded); SC2016 is intentional.
  # shellcheck disable=SC2016
  if [[ "$args" == *'$NET'* || "$command" == network ]]; then
    net="$(it_network_name "$backend" "$case_id")"
  fi
  args="${args//\$PROJECT/$project}"
  args="${args//\$NET/$net}"
  args="${args//\$LABEL/$label}"

  # Baseline fixture: every command except `new` needs an existing project.
  if [[ "$command" != "new" ]]; then
    if ! it_dce "$backend" "$case_id" new "$project" >/dev/null; then
      it_case_fail "setup: dce new (baseline) failed for $project"
      return 1
    fi
    it_register_project "$project" "$backend"
    # Commands that need the container RUNNING.
    case "$command" in
      logs|exec|shell|snapshot)
        it_dce "$backend" "$case_id" start "$project" >/dev/null || true
        ;;
    esac
  fi

  # Run the command under test. args is an argv STRING: intentional word-split
  # (flags + values become separate args). `new` consumes its own args; others
  # take the project name first when their arg template uses $PROJECT.
  local rc out=""
  case "$command" in
    new)
      # shellcheck disable=SC2086  # intentional split: args is an argv string
      out="$(it_dce_capture "$backend" "$case_id" new $args)" && rc=0 || rc=$?
      # A successful create registers the project for cleanup. Register even on
      # expected-fail (defensive: some expected-fail rows still partial-create).
      [[ $rc -eq 0 ]] && it_register_project "$project" "$backend"
      ;;
    *)
      # shellcheck disable=SC2086  # intentional split: args is an argv string
      out="$(it_dce_capture "$backend" "$case_id" $command $args)" && rc=0 || rc=$?
      ;;
  esac

  # Exit-code expectation.
  if [[ "$rc" -ne "$exp_exit" ]]; then
    it_case_fail "exit=$rc (expected $exp_exit) for 'dce $command $args'"
    return 1
  fi

  # Assertion checks: ;-separated; each substring must appear (! prefix = absence).
  if [[ -n "$assertions" ]]; then
    local asserts=() a
    IFS=';' read -ra asserts <<< "$assertions"
    for a in "${asserts[@]}"; do
      a="${a#"${a%%[![:space:]]*}"}"
      a="${a%"${a##*[![:space:]]}"}"
      [[ -n "$a" ]] || continue
      if ! it_matrix_check "$a" "$out"; then
        it_case_fail "assertion '$a' failed for 'dce $command $args'"
        return 1
      fi
    done
  fi

  return 0
}

# Run every applicable row in <tsv> for <backend> through it_run_case.
it_matrix_run_file() {  # <backend> <tsv-path>
  local backend="$1" tsv="$2" case_id scope command args exp asserts
  while IFS=$'\t' read -r case_id scope command args exp asserts; do
    # Skip header + comments + blank lines.
    case "$case_id" in ''|'#'*|case_id) continue ;; esac
    [[ -n "$case_id" ]] || continue
    it_matrix_applies "$scope" "$backend" || continue
    it_run_case "$backend" "$case_id" _it_matrix_row_fn "$scope" "$command" "$args" "${exp:-0}" "$asserts"
  done < "$tsv"
}
