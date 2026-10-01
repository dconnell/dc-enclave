#!/usr/bin/env bash
# =============================================================================
# tests/integration/cases/install.sh - `dce install` real-container effect.
#
# `dce install <name> <path>` streams a dotfiles directory (containing an
# executable install.sh) into the RUNNING container and runs install.sh as the
# dev user. Two cases:
#   install-effect - baseline: install.sh actually takes effect inside the
#                    container (marker written to the dev home).
#   install-token  - after the token file is filled (fake-but-real-shaped PAT),
#                    install.sh sees the provider token env var (GITHUB_TOKEN)
#                    AND ~/.git-credentials is already wired when it runs --
#                    both must happen BEFORE the user's install.sh.
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

_it_install_token() {  # <backend> <case_id>
  local b="$1" c="$2" p dotfiles token_file out rc
  # new already starts the container; install requires it running.
  p="$(it_project_name "$b" "$c")"
  it_dce "$b" "$c" new "$p" >/dev/null || { it_case_fail "dce new (install-token) failed"; return 1; }
  it_register_project "$p" "$b"

  # Simulate the user completing setup after `dce new`: fill the placeholder
  # token file with a fake-but-real-shaped PAT. dce_read_git_token skips
  # comments and the ghp_REPLACE_ME sentinel, so any non-comment non-sentinel
  # value selects PAT auth. Path mirrors cases/lifecycle.sh: the harness
  # exports HOME (the isolated run-workspace home, or the real one on
  # colima/podman) and dce resolves per-project secrets under
  # $HOME/.config/dc-enclave/projects/<project>/<provider>-token.
  token_file="$HOME/.config/dc-enclave/projects/$p/github-token"
  [[ -f "$token_file" ]] \
    || { it_case_fail "dce new did not create token file at $token_file"; return 1; }
  printf 'ghp_it_fake_token_%s\n' "$c" > "$token_file"
  chmod 600 "$token_file"

  # Fixture dotfiles dir with an executable install.sh that records what it saw
  # INSIDE the container: whether the provider token env var was exported into
  # its process and whether git credentials were already wired when it ran.
  dotfiles="$IT_ROOT_WS/$c.dotfiles"
  mkdir -p "$dotfiles"
  cat > "$dotfiles/install.sh" <<'EOF'
#!/usr/bin/env sh
if [ -n "$GITHUB_TOKEN" ]; then
  echo "env-set" > "$HOME/.dce-it-marker-env"
else
  echo "env-missing" > "$HOME/.dce-it-marker-env"
fi
if [ -f "$HOME/.git-credentials" ]; then
  echo "cred-present" > "$HOME/.dce-it-marker-cred"
else
  echo "cred-missing" > "$HOME/.dce-it-marker-cred"
fi
EOF
  chmod +x "$dotfiles/install.sh"

  it_dce "$b" "$c" install "$p" "$dotfiles" >/dev/null \
    || { it_case_fail "dce install (token) exited non-zero"; return 1; }

  out="$(it_dce_capture "$b" "$c" exec "$p" cat /home/dev/.dce-it-marker-env)" && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"env-set"* ]] \
    || { it_case_fail "GITHUB_TOKEN not exported to install.sh (marker: ${out:-<none>})"; return 1; }

  out="$(it_dce_capture "$b" "$c" exec "$p" cat /home/dev/.dce-it-marker-cred)" && rc=0 || rc=$?
  [[ $rc -eq 0 && "$out" == *"cred-present"* ]] \
    || { it_case_fail "$HOME/.git-credentials not seeded before install.sh (marker: ${out:-<none>})"; return 1; }
  return 0
}

it_cases_install() {  # <backend>
  it_run_case "$1" "install-effect" _it_install_effect
  it_run_case "$1" "install-token" _it_install_token
}
