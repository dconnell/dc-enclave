#!/usr/bin/env bash
# =============================================================================
# tests/lint/templates.sh - Policy checks over templates/ (copy-and-modify
# starters). Nothing under templates/ is used directly by dce, so these checks
# guard the contract the copies must keep holding after a user edits them:
#
#   1. Every example overlay composes: for each Containerfile.* under
#      templates/overlays/ and templates/patterns/*/, the file is installed
#      into a throwaway team root as Containerfile.<scope> and run through
#      scripts/compose-containerfile.sh. Asserts exit 0 (no COPY/ADD, valid
#      scope name) and that the fragment actually appears in the composed
#      output (matched inside its "overlay:auto:team/<scope>" marker block).
#      Hermeticity: dce_load_global_config deliberately unsets DC_TEAM_DIR /
#      DC_USER_DIR before parsing ~/.config/dc-enclave/config, so env-var
#      overrides cannot work; each compose runs under a temp HOME with a
#      crafted global config pointing at temp team/user roots (same mechanism
#      as tests/contract/compose-layering.sh).
#   2. Recipe validity: every file under templates/container-recipes/ and
#      templates/patterns/*/ that is not a Containerfile.*, README*, or
#      dotfile must parse with dce_recipe_parse_file — the same fail-closed
#      parser/validators `dce new --config` uses. Scope names in templates are
#      only syntax-checked here (existence lives in the user's roots).
#   3. Extension manifest grammar: non-blank, non-comment lines in
#      templates/extensions/vscode/*.txt are publisher.name identifiers
#      (editor extensions are synced from these manifests verbatim).
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMPLATES="$ROOT_DIR/templates"
COMPOSE="$ROOT_DIR/scripts/compose-containerfile.sh"

passes=0
fails=0
fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
pass() { echo "PASS: $*"; passes=$((passes + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# first_content_line FILE : echo the first line that survives compose's
# emit_fragment stripping (leading FROM on line 1, any CMD/ENTRYPOINT) plus
# blanks/comments — i.e. a line that must appear in the composed output.
first_content_line() {
  awk '
    NR == 1 && toupper($1) == "FROM" { next }
    toupper($1) == "CMD" || toupper($1) == "ENTRYPOINT" { next }
    /^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
    { print; exit }
  ' "$1"
}

# --- (1) compose-check every example overlay ---------------------------------
compose_targets=()
for cf in "$TEMPLATES"/overlays/Containerfile.*; do
  [[ -f "$cf" ]] && compose_targets+=("$cf")
done
if [[ -d "$TEMPLATES/patterns" ]]; then
  for dir in "$TEMPLATES"/patterns/*/; do
    [[ -d "$dir" ]] || continue
    for cf in "$dir"Containerfile.*; do
      [[ -f "$cf" ]] && compose_targets+=("$cf")
    done
  done
fi

if [[ ${#compose_targets[@]} -eq 0 ]]; then
  fail "compose-check: no example overlays found under templates/overlays/ or templates/patterns/*/"
fi

n=0
for cf in "${compose_targets[@]}"; do
  n=$((n + 1))
  rel="${cf#"$TEMPLATES"/}"
  scope="${cf##*/Containerfile.}"

  # Throwaway HOME whose global config points both roots at temp dirs; the
  # file under test is the ONLY overlay in that team root, so the composed
  # output must contain exactly its scope fragment.
  t="$WORK/compose-$n"
  mkdir -p "$t/home/.config/dc-enclave" "$t/root/team/overlays" "$t/root/user/overlays"
  {
    printf 'DC_TEAM_DIR="%s"\n' "$t/root/team"
    printf 'DC_USER_DIR="%s"\n' "$t/root/user"
  } > "$t/home/.config/dc-enclave/config"
  cp "$cf" "$t/root/team/overlays/Containerfile.$scope"

  if ! HOME="$t/home" bash "$COMPOSE" "$t/out.Containerfile" "$scope" \
      >"$t/compose.stdout" 2>"$t/compose.stderr"; then
    fail "compose-check: $rel (scope '$scope' failed to compose: $(tail -n1 "$t/compose.stderr"))"
    continue
  fi

  probe="$(first_content_line "$cf")"
  if [[ -z "$probe" ]]; then
    fail "compose-check: $rel (no composable content line to assert)"
    continue
  fi

  # Assert inside the team/<scope> marker block so a probe like "USER dev"
  # cannot false-pass against compose's own bookend lines.
  begin="# --- begin overlay:auto:team/$scope ---"
  end="# --- end overlay:auto:team/$scope ---"
  fragment="$(awk -v b="$begin" -v e="$end" '$0 == b { f = 1; next } $0 == e { f = 0 } f' "$t/out.Containerfile")"
  if [[ -z "$fragment" ]]; then
    fail "compose-check: $rel (no $begin block in composed output)"
  elif grep -Fq -- "$probe" <<<"$fragment"; then
    pass "compose-check: $rel composes and emits its fragment"
  else
    fail "compose-check: $rel (fragment emitted but probe line missing: $probe)"
  fi
done

# --- (2) recipe validity ------------------------------------------------------
# dce_recipe_parse_file (lib/recipe.sh) is the exact parser `dce new` runs over
# recipe files; it rejects unknown keys, malformed lines, and invalid values.
# shellcheck disable=SC1091  # lib includes, runtime-resolved paths
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/network.sh"
# shellcheck disable=SC1091  # lib include, runtime-resolved path
source "$ROOT_DIR/lib/recipe.sh"

recipe_dirs=("$TEMPLATES/container-recipes")
if [[ -d "$TEMPLATES/patterns" ]]; then
  for dir in "$TEMPLATES"/patterns/*/; do
    [[ -d "$dir" ]] && recipe_dirs+=("$dir")
  done
fi

recipe_candidates=()
while IFS= read -r rf; do
  recipe_candidates+=("$rf")
done < <(find "${recipe_dirs[@]}" -maxdepth 1 -type f | sort)

if [[ ${#recipe_candidates[@]} -eq 0 ]]; then
  fail "recipe validity: no recipe candidates found (expected at least templates/container-recipes/*)"
fi

for rf in "${recipe_candidates[@]}"; do
  base="$(basename "$rf")"
  case "$base" in
    Containerfile.*|README*|.*) continue ;;  # overlays/README/dotfiles are not recipes
  esac
  rel="${rf#"$TEMPLATES"/}"
  if dce_recipe_parse_file single "$rf" >"$WORK/recipe.out" 2>"$WORK/recipe.err"; then
    pass "recipe validity: $rel parses"
  else
    fail "recipe validity: $rel does not parse ($(head -n1 "$WORK/recipe.err"))"
  fi
done

# --- (3) extension manifest grammar -------------------------------------------
# Every non-blank, non-comment line must be a publisher.name identifier;
# `dce extensions` syncs these lines into editor manifests verbatim.
manifest_re='^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9][A-Za-z0-9.-]*$'

shopt -s nullglob
manifests=("$TEMPLATES"/extensions/vscode/*.txt)
shopt -u nullglob

if [[ ${#manifests[@]} -eq 0 ]]; then
  fail "manifest grammar: no templates/extensions/vscode/*.txt manifests found"
fi

for mf in "${manifests[@]}"; do
  rel="${mf#"$TEMPLATES"/}"
  bad=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ $manifest_re ]]; then
      fail "manifest grammar: $rel: line does not match publisher.name: '$line'"
      bad=1
    fi
  done < "$mf"
  [[ "$bad" -eq 0 ]] && pass "manifest grammar: $rel"
done

echo ""
echo "templates.sh: $passes passed, $fails failed"
[[ "$fails" -eq 0 ]] || exit 1
exit 0
