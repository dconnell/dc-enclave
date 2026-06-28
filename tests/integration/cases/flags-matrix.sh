#!/usr/bin/env bash
# =============================================================================
# tests/integration/cases/flags-matrix.sh - Drive the data-driven flag matrix.
#
# Thin entry wrapper around lib/matrix.sh's it_matrix_run_file so the runner
# treats the flag matrix like the other case families (one it_cases_* per
# backend). The matrix engine reads tests/integration/matrix/flags.tsv and
# executes every row whose backend_scope applies to <backend>.
#
# Entry point:  it_cases_flags <backend>
# =============================================================================
set -uo pipefail

it_cases_flags() {  # <backend>
  local tsv
  tsv="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../matrix/flags.tsv"
  it_matrix_run_file "$1" "$tsv"
}
