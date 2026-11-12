#!/usr/bin/env bash
# =============================================================================
# tests/lint/overlays.sh - Guards for the per-language example overlays and their
# install-on-start trust and safe-mode conventions.
#
# These are static, build-time conventions enforced on the repo-owned example
# overlays in templates/overlays/. They complement tests/lint/supply-chain.sh
# (which guards against curl|bash and base-image tag drift) by asserting the
# structural shape that the example overlays require:
#
#   1. One example overlay exists per supported language.
#   2. Toolchain overlays that download an artifact (golang/rust/python) are
#      multi-arch (TARGETARCH + both arm64 and amd64 pinned SHA256 build-args)
#      and never ship a placeholder checksum. Overlays that download via a
#      build-time shell case instead of ARG lines (nodejs, plus the tool
#      overlays opencode/herdr) get the same per-arch discipline: two distinct
#      fixed-width hex pins (64-hex sha256, 128-hex sha512 for opencode) that
#      are actually consumed by a checksum verify, both container arch
#      branches, a versioned (never mutable-latest) URL pinning ONE version
#      across all URLs, and a curl -fsSL fetch.
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

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EX="$ROOT_DIR/templates/overlays"

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

# logical_lines FILE : collapse backslash continuations into one logical line
# and drop comment/blank lines -- the executed text of a RUN block. Same
# normalization as tests/lint/supply-chain.sh; used by checks that must match
# across continuation joins and that comment prose must not satisfy.
logical_lines() {
  awk '
    {
      buf = buf $0
      if (buf ~ /\\$/) {
        sub(/\\$/, "", buf)
        buf = buf " "
        next
      }
      out = buf; buf = ""
      sub(/^[ \t]+/, "", out)
      if (out != "" && substr(out, 1, 1) != "#") print out
    }
    END {
      if (buf != "") {
        sub(/^[ \t]+/, "", buf)
        if (buf != "" && substr(buf, 1, 1) != "#") print buf
      }
    }
  ' "$1"
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

# --- (2b) pinned-download discipline (nodejs / opencode / herdr) ---------------
# These overlays download a release artifact via a build-time shell `case` on
# `uname -m`, so the ARG-shape checks in (2) do not apply. Enforce the same
# discipline for each: all per-arch pins must be complete fixed-width hex
# digests and the two must differ (identical pins would mean one arch is
# verifying against the other's digest -- a silently wrong artifact accepted),
# the pinned digest must actually be CONSUMED by a checksum verify, both
# container arch branches must be handled (a missing branch aborts the build
# on that host instead of skipping verification), every fetch URL must pin a
# version (never a mutable "latest" path), ALL versioned URLs must reference
# the same single version, and the fetch must be a fail-fast, silent,
# location-following curl.
#
# Rows are `~`-separated (the regex columns contain `|` alternation):
#   file ~ pin stem ~ digest hex width ~ versioned-URL regex ~
#   version-extraction regex ~ digest-verify regex (matched on logical
#   lines) ~ arch-pair regex ("" = n/a; opencode's npm URL pairs two
#   cli-linux-<arch> segments that must agree)
declare -a PINNED_DOWNLOADS=(
  'Containerfile.nodejs~SUM~64~nodejs\.org/dist/v[0-9]+\.[0-9]+\.[0-9]+/~node-v[0-9]+\.[0-9]+\.[0-9]+-~\$\{SUM\}[^|]*\|[[:space:]]*sha256sum -c -~'
  'Containerfile.opencode~OC_SUM~128~registry\.npmjs\.org/@opencode/cli-linux-(arm64|x64)/-/cli-linux-(arm64|x64)-[0-9]+\.[0-9]+\.[0-9]+\.tgz~cli-linux-(arm64|x64)-[0-9]+\.[0-9]+\.[0-9]+\.tgz~\$\{OC_SUM\}[^|]*\|[[:space:]]*sha512sum -c -~cli-linux-(arm64|x64)/-/cli-linux-(arm64|x64)-'
  'Containerfile.herdr~HERDR_SUM~64~github\.com/herdrdev/herdr/releases/download/v[0-9]+\.[0-9]+\.[0-9]+/herdr-linux-(aarch64|x86_64)~v[0-9]+\.[0-9]+\.[0-9]+/herdr-linux-~\$\{HERDR_SUM\}[^|]*\|[[:space:]]*sha256sum -c -~'
)

for row in "${PINNED_DOWNLOADS[@]}"; do
  IFS='~' read -r cf_name stem width url_re ver_re verify_re pair_re <<<"$row"
  cf="$EX/$cf_name"
  tool="${cf_name#Containerfile.}"
  if [[ ! -f "$cf" ]]; then
    fail "pinned-download guard: missing $cf"
    continue
  fi

  # Every <STEM>= occurrence must be a complete fixed-width hex pin (no
  # truncated/placeholder digest).
  pin_offenders="$(grep -Eo "${stem}=[0-9a-f]*" "$cf" | grep -Ev "^${stem}=[0-9a-f]{${width}}$" || true)"
  if [[ -n "$pin_offenders" ]]; then
    fail "checksum: $tool incomplete/placeholder ${stem} pin(s): $(printf '%s ' "$pin_offenders")"
  else
    pass "checksum: $tool all ${stem} pins are complete ${width}-hex digests"
  fi

  # Exactly two DISTINCT pins: one per arch; identical pins would mean one
  # arch is verifying against the other's digest (silently wrong artifact
  # accepted).
  pin_count="$(grep -Eo "${stem}=[0-9a-f]{${width}}" "$cf" | sort -u | wc -l | tr -d ' ')"
  if [[ "$pin_count" -eq 2 ]]; then
    pass "checksum: $tool has two distinct per-arch ${stem} pins"
  else
    fail "checksum: $tool needs exactly two distinct ${width}-hex ${stem} pins (got: $pin_count)"
  fi

  # The pin must be CONSUMED by a checksum verify: a digest that never feeds
  # sha256sum/sha512sum -c - is decoration, not protection. Matched against
  # non-comment logical lines so a comment mention cannot false-pass.
  if logical_lines "$cf" | grep -Eq "$verify_re"; then
    pass "checksum: $tool pin is consumed by a checksum verify"
  else
    fail "checksum: $tool pin is never verified; expected: echo \"\${${stem}}  <artifact>\" | sha*-sum -c -"
  fi

  # Both container arches handled by the case (missing branch = unsupported
  # arch aborted at build time on that host).
  for branch in aarch64 x86_64; do
    if grep -Eq "^([[:space:]]*)?${branch}\)" "$cf"; then
      pass "multi-arch: $tool handles $branch"
    else
      fail "multi-arch: $tool is missing its '$branch)' case branch"
    fi
  done

  # Version-pinned download URL (never the mutable latest tree).
  if grep -Eq "$url_re" "$cf"; then
    pass "supply-chain: $tool download URL pins a version"
  else
    fail "supply-chain: $tool download URL must pin a versioned release path"
  fi

  # All versioned URLs must reference the SAME single version: bumping one
  # arch's URL alone would mix artifact generations across arches.
  versions="$(grep -Eo "$ver_re" "$cf" | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | sort -u || true)"
  ver_count="$(printf '%s\n' "$versions" | grep -c . || true)"
  if [[ "$ver_count" -eq 1 ]]; then
    pass "supply-chain: $tool URLs pin exactly one version (${versions})"
  else
    fail "supply-chain: $tool URLs must pin exactly one version (got $ver_count: $(printf '%s ' "$versions"))"
  fi

  # No mutable "latest" inside any fetch URL, double- or single-quoted.
  # Comment prose may reference a latest metadata endpoint as the bump
  # source; URLs may not use it.
  if grep -Eo "[\"']https://[^\"']+['\"]" "$cf" | grep -q 'latest'; then
    fail "supply-chain: $tool fetch URL must not use a mutable latest path"
  else
    pass "supply-chain: $tool fetch URLs avoid latest"
  fi

  # opencode's npm URL embeds the arch twice (registry path and tarball
  # name); a mismatch would fetch one arch's package and verify it as the
  # other. Extract each pair and require the two segments to agree.
  if [[ -n "$pair_re" ]]; then
    pair_mismatch="$(grep -Eo "$pair_re" "$cf" \
      | sed -E 's#^cli-linux-(arm64|x64)/-/cli-linux-(arm64|x64)-$#\1 \2#' \
      | awk '$1 != $2 { print }' || true)"
    if [[ -n "$pair_mismatch" ]]; then
      fail "supply-chain: $tool URL arch segments disagree (path vs tarball): $(printf '%s | ' "$pair_mismatch")"
    else
      pass "supply-chain: $tool URL arch segments agree (path arch == tarball arch)"
    fi
  fi

  # Fail-fast, quiet, redirect-following fetch (matches repo curl conventions).
  if grep -Eq 'curl -fsSL' "$cf"; then
    pass "supply-chain: $tool fetch uses curl -fsSL"
  else
    fail "supply-chain: $tool fetch must use curl -fsSL (fail-fast, no progress, follow redirects)"
  fi
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
