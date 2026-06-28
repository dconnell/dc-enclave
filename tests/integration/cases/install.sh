#!/usr/bin/env bash
# =============================================================================
# tests/integration/cases/install.sh - `dce install` real-container effect.
#
# `dce install <name> <path>` streams a dotfiles directory (containing an
# executable install.sh) into the RUNNING container and runs install.sh as the
# dev user. This case asserts the install.sh actually took effect inside the
# container (marker file written to the dev home), covering the real install
# path end-to-end.
#
# Entry point:  it_cases_install <backend>
# =============================================================================
set -uo pipefail

_it_install_effect() {  # <backend> <case_id>
  local b="$1" c="$2" p dotfiles out rc
  # new already starts the container; install requires it running.
  p="$(it_project_name "$b" "$c")"
  it_dce "$b" "$c" new "$p" >/dev/null || { it_case_fail "dce new (baseline) failed"; return 1; }
  it_register_project "$p" "$b"

  # Fixture dotfiles dir with an executable install.sh that drops a marker in
  # the dev user's home (persists in the container FS, not a volume).
  dotfiles="$IT_ROOT_WS/$c.dotfiles"
  mkdir -p "$dotfiles"
  cat > "$dotfiles/install.sh" <<'EOF'
#!/usr/bin/env sh
echo "dotfiles-installed" > "$HOME/.dce-it-marker"
EOF
  chmod +x "$dotfiles/install.sh"

  it_dce "$b" "$c" install "$p" "$dotfiles" >/dev/null \
    || { it_case_fail "dce install exited non-zero"; return 1; }

  out="$(it_dce_capture "$b" "$c" exec "$p" cat /home/dev/.dce-it-marker)" && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"dotfiles-installed"* ]] \
    || { it_case_fail "install.sh did not take effect in container (marker missing)"; return 1; }
  return 0
}

it_cases_install() {  # <backend>
  it_run_case "$1" "install-effect" _it_install_effect
}
