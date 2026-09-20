#!/usr/bin/env bash
# =============================================================================
# tests/contract/host-entries.sh - Per-project /etc/hosts WIRING contract.
#
# The library logic (normalize / reconcile script / driver no-op + failure
# modes) is pinned in depth by tests/unit/container-hosts.sh with stubbed
# backend_* functions. This file pins the contract at the wiring level, driving
# the REAL scripts through stubbed docker/container/podman CLIs:
#
#   scaffold  -> `dce new` creates the hosts template comment-only, mode 644,
#                at ~/.config/dce-enclave/<project>/hosts -- and re-running
#                creation never overwrites a user-seeded fragment
#   no-op     -> `dce start` / `dce shell` with NO fragment issue zero
#                hosts-related exec traffic (no /tmp/.dce-hosts staging, no
#                managed-block markers in any argv); other legitimate calls
#                may exist, so the assertion is scoped to hosts payloads
#   apply     -> `dce start` with a fragment first wires git credentials, then
#                (a) stages the NORMALIZED entries via a root stdin exec at
#                /tmp/.dce-hosts, and (b) reconciles via a root exec whose
#                script targets /etc/hosts between the dce-enclave markers
#   ordering  -> static pin: every entry script calls
#                dce_ensure_container_hosts after dce_ensure_git_credentials
#
# The real daemon is never contacted: stateful stub CLIs log every call --
# capturing stdin on -i execs so the staged fragment payload is assertable --
# and answer the read predicates from controlled files under a fake HOME.
# Per-backend argv divergence for the root stdin primitive is pinned separately
# in tests/contract/backend-dispatch.sh.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
chmod 700 "$WORK"

# ---------------------------------------------------------------------------
# Fake HOME + global config + nodejs-scope overlays.
# ---------------------------------------------------------------------------
export HOME="$WORK/home"
DC_ROOT="$HOME/.config/dce-enclave"
TEAM_DIR="$DC_ROOT/team"
USER_DIR="$DC_ROOT/user"
mkdir -p "$TEAM_DIR/overlays" "$USER_DIR/overlays"
{
  printf 'DC_TEAM_DIR="%s"\n' "$TEAM_DIR"
  printf 'DC_USER_DIR="%s"\n' "$USER_DIR"
} > "$DC_ROOT/config"
printf 'RUN echo TEAM-NODEJS\n' > "$TEAM_DIR/overlays/Containerfile.nodejs"
printf 'RUN echo USER-NODEJS\n' > "$USER_DIR/overlays/Containerfile.nodejs"

# ---------------------------------------------------------------------------
# Stub CLIs (docker/container/podman): log every call, keep container state in
# files, capture stdin on -i execs (hosts staging crosses via a pipe), and
# answer the read predicates the flows exercise.
# ---------------------------------------------------------------------------
STUB_DIR="$WORK/bin"
mkdir -p "$STUB_DIR"
LOG="$WORK/calls.log"
IMAGES="$WORK/images.lst"
RUNNING="$WORK/running.lst"      # names currently "running", one per line
CONTAINERS="$WORK/containers.lst"  # names that exist (any state)
: > "$LOG"
printf 'dce-base:latest\n' > "$IMAGES"
: > "$RUNNING"
: > "$CONTAINERS"

cat > "$STUB_DIR/_cli" <<'STUB'
#!/usr/bin/env bash
# Generic backend stub: logs each call; answers image ls / images / ps /
# context show from controlled files; `start` flips the name into the running
# list; -i execs get their stdin captured into the log (between STDIN>>>/<<<
# markers, each line prefixed "STDIN| ") so streamed payloads are assertable.
_log="${DC_STUB_LOG:?}"
_imgs="${DC_STUB_IMAGES:-}"
_run="${DC_STUB_RUNNING:?}"
_ctrs="${DC_STUB_CONTAINERS:?}"
me="$(basename "$0")"
printf 'CALL %s %s\n' "$me" "$*" >> "$_log"

_drain_stdin=false
for _a in "$@"; do
  case "$_a" in
    -i|--interactive|-i*|-it) _drain_stdin=true ;;
  esac
done

if [[ "${1:-}" == "image" && "${2:-}" == "ls" ]] || [[ "${1:-}" == "images" ]]; then
  [[ -f "$_imgs" ]] && cat "$_imgs"
  exit 0
fi

case "$me" in
  docker)
    if [[ "${1:-}" == "context" && "${2:-}" == "show" ]]; then printf 'colima\n'; fi
    if [[ "${1:-}" == "ps" ]]; then
      any=""
      for _a in "$@"; do [[ "$_a" == "-a" ]] && any=1; done
      if [[ -n "$any" ]]; then
        [[ -f "$_ctrs" ]] && cat "$_ctrs"
      else
        [[ -f "$_run" ]] && cat "$_run"
      fi
      exit 0
    fi
    ;;
esac

case "${1:-}" in
  start)
    _name="${@: -1}"
    grep -qxF -- "$_name" "$_run" 2>/dev/null || printf '%s\n' "$_name" >> "$_run"
    exit 0
    ;;
esac

if $_drain_stdin; then
  printf 'STDIN>>>\n' >> "$_log"
  sed 's/^/STDIN| /' >> "$_log"
  printf 'STDIN<<<\n' >> "$_log"
fi
exit 0
STUB
chmod +x "$STUB_DIR/_cli"
cp "$STUB_DIR/_cli" "$STUB_DIR/docker"
cp "$STUB_DIR/_cli" "$STUB_DIR/container"
cp "$STUB_DIR/_cli" "$STUB_DIR/podman"

ORIG_PATH="$PATH"
BACKEND=docker

# Run a host script under the stub environment (fresh process per run).
# DC_REPOS_DIR is pinned so ambient env cannot redirect the host workspace out
# of the fake HOME; TZ is pinned for deterministic create argv.
run_script() {
  HOME="$WORK/home" \
  DC_REPOS_DIR="$WORK/home/repos" \
  TZ="America/New_York" \
  DC_STUB_LOG="$LOG" DC_STUB_IMAGES="$IMAGES" \
  DC_STUB_RUNNING="$RUNNING" DC_STUB_CONTAINERS="$CONTAINERS" \
  PATH="$STUB_DIR:$ORIG_PATH" \
  CONTAINER_BACKEND="$BACKEND" \
  bash "$@"
}

# Portable octal mode (GNU stat -c first, BSD stat -f second).
_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

# Build a minimal project config + register the container as existing, and
# optionally as already running. No SSH key, no token file: git auth resolves
# to "none", keeping the flows' call surface small and predictable.
make_project() {  # <project> [running]
  local project="$1"
  local running="${2:-}"
  local cfg_dir="$DC_ROOT/$project"
  local repos="$WORK/home/repos/$project"
  mkdir -p "$cfg_dir" "$repos"
  chmod 700 "$cfg_dir"
  cat > "$cfg_dir/config" <<CFG
CONTAINER_PROJECT="$project"
CONTAINER_BACKEND="docker"
CONTAINER_IMAGE="dce-base:latest"
REPOS_DIR="$repos"
SECRET_DIR="$cfg_dir"
PORTS=()
CONTAINER_HIDDEN_PATHS=()
CONTAINER_NETWORKS=()
CFG
  chmod 600 "$cfg_dir/config"
  grep -qxF -- "$project" "$CONTAINERS" 2>/dev/null \
    || printf '%s\n' "$project" >> "$CONTAINERS"
  if [[ "$running" == "running" ]]; then
    grep -qxF -- "$project" "$RUNNING" 2>/dev/null \
      || printf '%s\n' "$project" >> "$RUNNING"
  fi
}

# Both hosts-related argv shapes must be absent for no-fragment flows. Scoped
# to hosts payloads on purpose: legitimate non-hosts as-root calls may exist.
assert_no_hosts_traffic() {  # <label>
  if grep -qF '/tmp/.dce-hosts' "$LOG"; then
    fail "$1: hosts staging traffic observed without a fragment
$(grep -F '/tmp/.dce-hosts' "$LOG")"
  fi
  if grep -qF 'dce-enclave hosts (managed)' "$LOG"; then
    fail "$1: managed-block marker reached a container argv without a fragment
$(grep -F 'dce-enclave hosts (managed)' "$LOG")"
  fi
}

# ===========================================================================
# Section 1 - scaffold: `dce new` creates the template; re-create never
# overwrites a user-seeded fragment.
# ===========================================================================
SPROJ="scaffoldproj"
: > "$LOG"
if ! run_script "$ROOT_DIR/scripts/new-container.sh" "$SPROJ" nodejs \
    >"$WORK/new1.out" 2>"$WORK/new1.err"; then
  fail "dce new (scaffold) exited non-zero
-- stderr:$(cat "$WORK/new1.err")"
fi

HOSTS_FILE="$DC_ROOT/$SPROJ/hosts"
[[ -f "$HOSTS_FILE" ]] || fail "scaffold: hosts template missing at $HOSTS_FILE"
[[ "$(_mode "$HOSTS_FILE")" == "644" ]] \
  || fail "scaffold: template must be 644 (got $(_mode "$HOSTS_FILE")): a scaffold, not a secret"
[[ -s "$HOSTS_FILE" ]] || fail "scaffold: template is empty (expected the comment-only guide)"
non_comment="$(grep -cvE '^[[:space:]]*(#|$)' "$HOSTS_FILE" || true)"
[[ "$non_comment" -eq 0 ]] \
  || fail "scaffold: template must be comment-only ($non_comment non-comment lines)"
grep -Fq 'hosts template' "$WORK/new1.out" \
  || fail "scaffold: creation output does not mention the hosts template"
pass "scaffold: dce new creates a comment-only 644 hosts template"

# Never-overwrite: seed a real entry, then re-run the creation logic. `dce new`
# refuses to run over an existing config, so simulate the re-create by removing
# ONLY the config (and the stub's container-exists record); the scaffold path
# keys off the hosts file alone and must leave it byte-identical.
SEEDED="$WORK/seeded.hosts"
{
  printf '# my corp entries\n'
  printf '10.9.9.9 preserve-me.internal alias.internal\n'
} > "$SEEDED"
cp "$SEEDED" "$HOSTS_FILE"
chmod 644 "$HOSTS_FILE"
rm -f "$DC_ROOT/$SPROJ/config"
: > "$CONTAINERS"
: > "$LOG"
if ! run_script "$ROOT_DIR/scripts/new-container.sh" "$SPROJ" nodejs \
    >"$WORK/new2.out" 2>"$WORK/new2.err"; then
  fail "dce new (re-create) exited non-zero
-- stderr:$(cat "$WORK/new2.err")"
fi
cmp -s "$SEEDED" "$HOSTS_FILE" \
  || fail "scaffold: re-create overwrote or edited a user-seeded hosts fragment"
[[ "$(_mode "$HOSTS_FILE")" == "644" ]] || fail "scaffold: re-create changed the fragment mode"
# Reachability: the re-create must still reach the scaffold path (same marker
# the first-run assertion checks), not just skip touching the fragment.
grep -Fq 'hosts template' "$WORK/new2.out" \
  || fail "scaffold: re-create output does not mention the hosts template"
pass "scaffold: re-running creation preserves a user-seeded fragment verbatim"

# ===========================================================================
# Section 2 - no-op wiring: no fragment -> zero hosts-related traffic.
# ===========================================================================
# `dce start`: the container must start (wiring runs post-start only).
make_project "nofrag" ""
: > "$LOG"
if ! run_script "$ROOT_DIR/scripts/start.sh" "nofrag" \
    >"$WORK/s2.out" 2>"$WORK/s2.err"; then
  fail "start (no fragment) exited non-zero
-- stderr:$(cat "$WORK/s2.err")"
fi
# Sanity: the flow reached the wiring point (credentials wired, start done).
grep -Fq 'git config --global' "$LOG" \
  || fail "no-op/start: flow did not reach the entry wiring (no git config calls)"
grep -Fq 'nofrag - started' "$WORK/s2.out" \
  || fail "no-op/start: flow did not complete"
assert_no_hosts_traffic "no-op/start"
pass "no-op wiring: dce start without a fragment issues zero hosts exec calls"

# `dce shell` command mode: container pre-marked running so shell.sh enters
# directly (otherwise it delegates to start.sh, already covered above).
make_project "nofragsh" running
: > "$LOG"
if ! run_script "$ROOT_DIR/scripts/shell.sh" "nofragsh" "echo hi" \
    >"$WORK/s2b.out" 2>"$WORK/s2b.err"; then
  fail "shell (no fragment) exited non-zero
-- stderr:$(cat "$WORK/s2b.err")"
fi
grep -Fq 'zsh -ic echo hi' "$LOG" \
  || fail "no-op/shell: command never reached the container
$(grep '^CALL' "$LOG")"
assert_no_hosts_traffic "no-op/shell"
pass "no-op wiring: dce shell command mode without a fragment issues zero hosts calls"

# ===========================================================================
# Section 3 - apply wiring: a fragment flows through `dce start` as (a) a root
# stdin exec staging the normalized entries at /tmp/.dce-hosts, then (b) a root
# exec whose script reconciles /etc/hosts between the managed markers.
# ===========================================================================
APPLY_PROJ="hostproj"
make_project "$APPLY_PROJ" ""
printf '# corp registry\n\n10.0.0.5 registry.corp.internal\n' > "$DC_ROOT/$APPLY_PROJ/hosts"
: > "$LOG"
if ! run_script "$ROOT_DIR/scripts/start.sh" "$APPLY_PROJ" \
    >"$WORK/s3.out" 2>"$WORK/s3.err"; then
  fail "start (apply) exited non-zero
-- stderr:$(cat "$WORK/s3.err")"
fi
grep -Fq "$APPLY_PROJ - started" "$WORK/s3.out" \
  || fail "apply: flow did not complete"

# Exactly the two hosts calls, in the docker-family root shapes.
stage_calls="$(grep -cF "exec -i -u 0 $APPLY_PROJ" "$LOG" || true)"
[[ "$stage_calls" -eq 1 ]] \
  || fail "apply: expected exactly one root stdin staging exec (got $stage_calls)
$(grep '^CALL' "$LOG")"
recon_calls="$(grep -cE "^CALL docker exec -u 0 $APPLY_PROJ" "$LOG" || true)"
[[ "$recon_calls" -eq 1 ]] \
  || fail "apply: expected exactly one root reconcile exec (got $recon_calls)
$(grep '^CALL' "$LOG")"

# (a) Staging pins the exact docker-family argv (whole-line match, so a changed
# staging path or uid flag cannot substring-match its way through); the stdin
# payload must be the NORMALIZED fragment (comments/blanks stripped host-side,
# entry verbatim).
STAGE_LINE="CALL docker exec -i -u 0 $APPLY_PROJ sh -c cat > /tmp/.dce-hosts && chmod 600 /tmp/.dce-hosts"
grep -Fxq "$STAGE_LINE" "$LOG" \
  || fail "apply: staging exec argv shape wrong (expected exact line: $STAGE_LINE)
$(grep '^CALL' "$LOG")"
staged_payload="$(awk -v line="$STAGE_LINE" '
  $0 == line { ingest=1 }
  ingest && /^STDIN[|] / { sub(/^STDIN[|] /, ""); print; next }
  ingest && /^STDIN</ { exit }
' "$LOG")"
[[ "$staged_payload" == "10.0.0.5 registry.corp.internal" ]] \
  || fail "apply: staged payload is not the normalized fragment (got: $staged_payload)"

# (b) The reconcile exec's script targets /etc/hosts, consumes the staged
# fragment, and carries both managed-block markers.
recon_payload="$(awk '
  /^CALL docker exec -u 0 hostproj sh -c/ { inpay=1; next }
  inpay && /^CALL / { inpay=0 }
  inpay { print }
' "$LOG")"
grep -Fq "TARGET='/etc/hosts'" <<<"$recon_payload" \
  || fail "apply: reconcile script does not target /etc/hosts"
grep -Fq "FRAG='/tmp/.dce-hosts'" <<<"$recon_payload" \
  || fail "apply: reconcile script does not consume the staged fragment"
grep -Fq '# >>> dce-enclave hosts (managed) >>>' <<<"$recon_payload" \
  || fail "apply: reconcile script missing the BEGIN marker"
grep -Fq '# <<< dce-enclave hosts (managed) <<<' <<<"$recon_payload" \
  || fail "apply: reconcile script missing the END marker"

# Ordering: the hosts staging follows the git-credentials wiring in the same
# flow (the dynamic half of the Section 4 static pin).
creds_ln="$(grep -n 'git config --global' "$LOG" | head -n1 | cut -d: -f1)" || true
stage_ln="$(grep -nF "CALL docker exec -i -u 0 $APPLY_PROJ" "$LOG" | head -n1 | cut -d: -f1)" || true
[[ -n "$creds_ln" && -n "$stage_ln" ]] \
  || fail "apply: could not locate credentials/staging lines in the log"
[[ "$stage_ln" -gt "$creds_ln" ]] \
  || fail "apply: hosts staging must follow the git-credentials wiring"
pass "apply: dce start stages the normalized fragment via root stdin exec, then reconciles /etc/hosts between the markers (after credentials)"

# ===========================================================================
# Section 4 - lifecycle ordering pin (static): every entry script reconciles
# hosts immediately after wiring git credentials. Covers the sites the harness
# cannot drive end-to-end (rebuild, snapshot, install-dotfiles, editor, new).
# ===========================================================================
ENTRY_SCRIPTS=(shell editor start new-container rebuild-container snapshot install-dotfiles)
for name in "${ENTRY_SCRIPTS[@]}"; do
  src="$ROOT_DIR/scripts/$name.sh"
  [[ -f "$src" ]] || fail "ordering: $src missing"
  cred_ln="$(grep -nE '^[[:space:]]*dce_ensure_git_credentials' "$src" | head -n1 | cut -d: -f1)"
  hosts_ln="$(grep -nE '^[[:space:]]*dce_ensure_container_hosts' "$src" | head -n1 | cut -d: -f1)"
  [[ -n "$cred_ln" ]] \
    || fail "ordering: $name.sh does not call dce_ensure_git_credentials"
  [[ -n "$hosts_ln" ]] \
    || fail "ordering: $name.sh does not call dce_ensure_container_hosts"
  [[ "$hosts_ln" -gt "$cred_ln" ]] \
    || fail "ordering: $name.sh must call dce_ensure_container_hosts AFTER dce_ensure_git_credentials (creds@$cred_ln, hosts@$hosts_ln)"
done
pass "ordering: all ${#ENTRY_SCRIPTS[@]} entry scripts call dce_ensure_container_hosts after dce_ensure_git_credentials"

echo ""
echo "All host-entries contract checks passed."
