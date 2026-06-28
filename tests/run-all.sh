#!/usr/bin/env bash
# =============================================================================
# tests/run-all.sh - Thin compatibility wrapper around the unit suite.
#
# The fast/stubbed tests now live under tests/unit/. This wrapper keeps the
# historical `tests/run-all.sh` entrypoint working for one release so existing
# contributor muscle memory, CI invocations, and docs keep working. New callers
# should invoke tests/unit/run-all.sh directly.
#
# Real-backend integration tests live under tests/integration/run-all.sh and
# are NEVER run from here (they create/remove real containers).
#
# Usage:
#   tests/run-all.sh          # forwards to tests/unit/run-all.sh
#   tests/run-all.sh -v       # verbose
# =============================================================================
set -euo pipefail

_unit_runner="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/unit/run-all.sh"
if [[ ! -f "$_unit_runner" ]]; then
  echo "ERROR: unit runner not found at $_unit_runner" >&2
  exit 1
fi
exec "$_unit_runner" "$@"
