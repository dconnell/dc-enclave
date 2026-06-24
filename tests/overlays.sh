#!/usr/bin/env bash
# =============================================================================
# tests/overlays.sh - Guards for the per-language example overlays and their
# install-on-start trust and safe-mode conventions.
#
# These are static, build-time conventions enforced on the repo-owned example
# overlays in Containerfiles/example/. They complement tests/supply-chain.sh
# (which guards against curl|bash and base-image tag drift) by asserting the
# structural shape that the example overlays require:
#
#   1. One example overlay exists per supported language.
#   2. Toolchain overlays that download an artifact (golang/rust/python) are
#      multi-arch (TARGETARCH + both arm64 and amd64 pinned SHA256 build-args)
#      and never ship a placeholder checksum.
#   3. Every language overlay installs a dependency-sync hook that:
#        - is NOT declared as ENTRYPOINT itself (the composed image owns a
#          single chained ENTRYPOINT; see scripts/compose-containerfile.sh), so
#          multiple language overlays compose without clobbering each other,
#        - reads a DC_<LANG>_INSTALL_STRICT env for hard-fail mode,
#        - emits a startup line stating script-execution status,
#      and the two overlays whose install step can run fetched code (nodejs via
#      npm lifecycle scripts, python via PEP 517 build hooks) additionally read
#      a DC_<LANG>_IGNORE_SCRIPTS safe-mode env.
#   4. The example README documents the trusted-vs-untrusted matrix, the safe
#      evaluation recipe, and per-overlay --hide paths.
#   5. scripts/compose-containerfile.sh strips per-overlay ENTRYPOINT lines and
#      emits exactly one chained ENTRYPOINT runner over dce-*-entrypoint.sh.
#
# Entrypoint scripts are embedded in their Containerfile via a heredoc, so the
# convention tokens are grepped directly against the Containerfile text.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EX="$ROOT_DIR/Containerfiles/example"

passes=0
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; passes=$((passes + 1)); }

# assert_file PATTERN FILE : exit-0 if grep -E PATTERN matches FILE.
assert_file() {
  local label="$1" pattern="$2" file="$3"
  if [[ ! -f "$file" ]]; then
    fail "$label (missing file: $file)"
    return
  fi
  if grep -Eq "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label (pattern /$pattern/ not in $(basename "$file"))"
  fi
}

# assert_absent PATTERN FILE : pass if grep -E PATTERN does NOT match FILE.
assert_absent() {
  local label="$1" pattern="$2" file="$3"
  if [[ ! -f "$file" ]]; then
    fail "$label (missing file: $file)"
    return
  fi
  if grep -Eq "$pattern" "$file"; then
    fail "$label (unexpected /$pattern/ in $(basename "$file"))"
  else
    pass "$label"
  fi
}

# Per-overlay expectations. Fields:
#   scope | entrypoint script | STRICT env | IGNORE_SCRIPTS env (or "")
declare -a OVERLAYS=(
  "nodejs|dce-node-entrypoint.sh|DC_NODE_INSTALL_STRICT|DC_NODE_IGNORE_SCRIPTS"
  "golang|dce-go-entrypoint.sh|DC_GO_INSTALL_STRICT|"
  "rust|dce-rust-entrypoint.sh|DC_RUST_INSTALL_STRICT|"
  "dotnet|dce-dotnet-entrypoint.sh|DC_DOTNET_INSTALL_STRICT|"
  "python|dce-python-entrypoint.sh|DC_PYTHON_INSTALL_STRICT|DC_PYTHON_IGNORE_SCRIPTS"
)

# Toolchain overlays that must be multi-arch with pinned per-arch checksums.
#   scope | checksum-arg stem | version arg
declare -a ARCH_OVERLAYS=(
  "golang|GO_SHA256|GO_VERSION"
  "rust|RUSTUP_SHA256|RUSTUP_VERSION"
  "python|UV_SHA256|UV_VERSION"
)

# --- (1) one overlay per language exists --------------------------------------
for row in "${OVERLAYS[@]}"; do
  IFS='|' read -r scope _ _ _ <<<"$row"
  cf="$EX/Containerfile.$scope"
  if [[ -f "$cf" ]]; then pass "overlay exists: $scope"; else fail "overlay exists: $scope (missing $cf)"; fi
done

# --- (2) multi-arch + real checksums on downloaded toolchains -----------------
sha256_re='[0-9a-f]{64}'
for row in "${ARCH_OVERLAYS[@]}"; do
  IFS='|' read -r scope stem _ <<<"$row"
  cf="$EX/Containerfile.$scope"
  [[ -f "$cf" ]] || { fail "multi-arch: $scope (no file)"; continue; }

  if grep -Eq '^[[:space:]]*ARG[[:space:]]+TARGETARCH' "$cf"; then
    pass "multi-arch: $scope uses TARGETARCH"
  else
    fail "multi-arch: $scope must declare 'ARG TARGETARCH'"
  fi

  for arch in ARM64 AMD64; do
    # ARG line declaring the checksum with a 64-hex default value (no placeholder).
    if grep -Eq "^[[:space:]]*ARG[[:space:]]+${stem}_${arch}=${sha256_re}" "$cf"; then
      pass "checksum: $scope ${stem}_${arch} pinned"
    else
      fail "checksum: $scope ${stem}_${arch} missing or not a 64-hex pin (got: $(grep -E "${stem}_${arch}" "$cf" | head -1))"
    fi
  done
done

# --- (3) entrypoint conventions (shape shared by convention with Node) --------
for row in "${OVERLAYS[@]}"; do
  IFS='|' read -r scope script strict ignore <<<"$row"
  cf="$EX/Containerfile.$scope"
  [[ -f "$cf" ]] || { fail "entrypoint: $scope (no file)"; continue; }

  base="$scope overlay ($script)"
  assert_file "$base: writes sync hook" "cat > /home/dev/.local/bin/${script}" "$cf"
  assert_absent "$base: no per-overlay ENTRYPOINT" '^[[:space:]]*ENTRYPOINT[[:space:]]' "$cf"
  assert_file "$base: strict env"  "\b${strict}\b" "$cf"
  # Every entrypoint states script-execution status at install time.
  assert_file "$base: script-execution status line" "(script execution|script execution)" "$cf"

  if [[ -n "$ignore" ]]; then
    assert_file "$base: ignore-scripts safe-mode env" "\b${ignore}\b" "$cf"
  fi
done

# --- (4) compose owns a single chained ENTRYPOINT -----------------------------
COMPOSE="$ROOT_DIR/scripts/compose-containerfile.sh"
# shellcheck disable=SC2016  # literal awk pattern ($1 is awk's, not expanded here)
assert_file "compose: strips per-overlay ENTRYPOINT" 'toupper\(\$1\) == "ENTRYPOINT"' "$COMPOSE"
assert_file "compose: emits runner ENTRYPOINT" '/home/dev/.local/bin/dce-entrypoint' "$COMPOSE"
assert_file "compose: runner chains dce-*-entrypoint.sh" 'dce-\*-entrypoint\.sh' "$COMPOSE"

# --- (5) example README: trust matrix + safe recipe + hide paths --------------
readme="$EX/README.md"
assert_file "example README: trusted-vs-untrusted matrix" "[Tt]rust" "$readme"
assert_file "example README: safe-mode recipe" "IGNORE_SCRIPTS|ignore-scripts" "$readme"
for scope in nodejs golang rust dotnet python; do
  assert_file "example README: supply-chain note for $scope" "$scope" "$readme"
done

echo ""
echo "overlays.sh: $passes passed, $fails failed"
[[ "$fails" -eq 0 ]] || exit 1
exit 0
