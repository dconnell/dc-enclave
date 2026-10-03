#!/usr/bin/env bash
# =============================================================================
# lib/common/container-hosts.sh - Per-project /etc/hosts reconciliation.
#
# Sourced (never executed directly) via lib/common.sh. Reads a project's hosts
# fragment (~/.config/dc-enclave/projects/<project>/hosts) and reconciles it into the
# container's /etc/hosts as a marker-delimited managed block at container entry
# points (dce_ensure_container_hosts is invoked by every entry script: shell,
# editor, start, new, rebuild, snapshot, and install-dotfiles). Backend-aware:
# on the apple/container backend the reconcile also runs
# when the fragment is absent, staging the dce-managed host-gateway line (see
# the constants below) so containers can reach host-loopback services; every
# other backend keeps the fragment-optional strict no-op.
#
# Why reconcile-not-append: container runtimes REGENERATE /etc/hosts on every
# container start, so entries appended once would be lost on the next start --
# and a naive append at every entry point would accumulate duplicates within a
# single container lifetime. Removing the managed block and rewriting it from
# the current fragment makes repeated entry points idempotent and lets host-side
# fragment edits converge into the container.
#
# Why in-place write: Docker-family runtimes bind-mount /etc/hosts into the
# container. Replacing the file (sed -i, mv, write-temp-then-rename) swaps the
# inode, so the write lands on an unmounted orphan and the container's view of
# /etc/hosts never changes. The reconcile script therefore always truncates the
# existing file in place (`cat tmp > /etc/hosts`).
#
# Why buffer-and-recover stripping: a hand-mangled unmatched BEGIN marker must
# degrade to "stale block survives" -- never to silently truncating /etc/hosts.
#
# The fragment crosses the host/container boundary via a stdin pipe into a
# short-lived root sh -c (never via argv), mirroring the credential-handling
# invariant in git-credentials.sh. Depends on core.sh (dce_warn); backend_*
# calls resolve via lib/container-backend.sh.
# =============================================================================

if [[ -n "${_DC_COMMON_CONTAINER_HOSTS_SH_LOADED:-}" ]]; then
  return 0
fi
declare -gr _DC_COMMON_CONTAINER_HOSTS_SH_LOADED=1

# Managed-block markers. The reconciler strips everything between them
# (inclusive) before appending the fresh block; keep the pair in sync.
readonly _DCE_HOSTS_BLOCK_BEGIN='# >>> dc-enclave hosts (managed) >>>'
readonly _DCE_HOSTS_BLOCK_END='# <<< dc-enclave hosts (managed) <<<'

# Host-gateway constants. apple/container (>= 0.9.0) has no built-in
# host.docker.internal; instead, after a one-time admin bootstrap
# (`sudo container system dns create host.container.internal --localhost <ip>`,
# see backend_apple_dns_bootstrap_command) the container system installs a
# packet-filter rule that redirects container-bound traffic to <ip> into the
# macOS host's 127.0.0.1. The redirect is IP-based, so a plain hosts-file entry
# inside the container reaches host-loopback services even though dce passes
# custom --dns at create time (which would bypass DNS resolution of a domain).
#
# The IP is Apple's documented example from TEST-NET-3 (203.0.113.0/24,
# RFC 5737) -- documentation-range addresses are the least likely to collide
# with real networks or reserved ranges in a user's environment. Both names are
# listed on the one line: host.docker.internal gives docker-familiar tooling
# and hardcoded connection strings parity across backends, and
# host.container.internal is the domain the apple bootstrap actually creates.
#
# Exported (-grx) rather than just global: the IP and the apple domain are read
# cross-file by the capability probes in lib/container-backend.sh
# (backend_apple_dns_domain_present / backend_apple_dns_bootstrap_command), and
# ShellCheck analyzes each module in isolation (external-sources=false). As
# with DC_VERSION, exporting documents the cross-cutting intent and silences
# SC2034 without a directive.
declare -grx _DCE_HOSTS_GATEWAY_IP='203.0.113.113'
declare -grx _DCE_HOSTS_GATEWAY_DOCKER_NAME='host.docker.internal'
declare -grx _DCE_HOSTS_GATEWAY_APPLE_NAME='host.container.internal'
# The composed managed entry. File-local by construction: only the driver below
# stages it, and the atoms above stay the single source of truth.
readonly _DCE_HOSTS_GATEWAY_LINE="${_DCE_HOSTS_GATEWAY_IP} ${_DCE_HOSTS_GATEWAY_DOCKER_NAME} ${_DCE_HOSTS_GATEWAY_APPLE_NAME}"

# Internal: echo the project's configured backend (its CONTAINER_BACKEND), or
# an empty string when it cannot be determined -- missing config, invalid
# config, or the key simply absent. Determination goes through the hardened
# loader (dce_load_project_config), never a hand parse, so a config that would
# be rejected anywhere else is rejected here too. Runs in the caller's command
# substitution subshell, so the loader's config globals can never clobber the
# caller's, and any hard failure (dce_die on an unsafe file) degrades to "no
# backend known" instead of aborting container entry. Stderr is swallowed (the
# lib/network.sh scan precedent): this is a capability probe, and entry scripts
# have already surfaced any real config errors by the time they get here.
_dce_hosts_project_backend() {
  local project="$1"
  local config=""
  config="$(dce_project_config_path "$project")"
  [[ -f "$config" ]] || return 0

  if dce_load_project_config "$config" 2>/dev/null; then
    printf '%s\n' "${CONTAINER_BACKEND:-}"
  fi
}

# Echo the normalized entry lines of a hosts fragment file, one per line:
# trailing CR stripped (CRLF-authored fragments), leading/trailing whitespace
# trimmed, full-line comments (first non-blank char '#'), blank and
# whitespace-only lines skipped, and lines with fewer than two whitespace-
# separated fields (IP + at least one hostname) rejected with a dce_warn naming
# the offending line. Trailing inline comments are preserved (legal per
# hosts(5)) and IPv6 addresses pass through untouched. A missing file normalizes
# to nothing; the driver checks for the fragment's existence beforehand.
dce_hosts_normalize() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local line="" trimmed=""
  local -a fields=()
  # The `|| [[ -n "$line" ]]` keeps a final line without a trailing newline.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    # Trim leading whitespace, then trailing (inner ${...} strips first).
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    if [[ -z "$trimmed" || "$trimmed" == "#"* ]]; then
      continue
    fi
    # Default IFS splitting (read without an IFS= prefix) is exactly the
    # whitespace-field count hosts(5) cares about.
    read -r -a fields <<< "$trimmed"
    if [[ ${#fields[@]} -lt 2 ]]; then
      dce_warn "hosts fragment: skipping line without 'IP hostname' fields: $trimmed"
      continue
    fi
    printf '%s\n' "$trimmed"
  done < "$file"
}

# Internal: single-quote a string for safe embedding in the generated sh script
# (Turner's trick: ' -> '\''). Paths under mktemp or /etc never contain quotes,
# but the quoting keeps the generator honest for any future caller.
_dce_hosts_sh_quote() {
  local s="$1"
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

# Internal: echo (as a single string) a POSIX sh script that reconciles the
# dc-enclave managed block inside <target-file> from <fragment-file>. Intended
# to run as root inside the container via `sh -c "$script"`; the fragment path
# is the staged copy (/tmp/.dce-hosts), which the script removes when done.
#
# The script is best-effort by construction: every step tolerates failure and
# it always cleans up its temp files and exits 0, so a reconcile hiccup can
# never break the container entry point that invoked it. Fragment lines are
# re-validated inside the container (defense in depth -- the staged file
# crossed a boundary via stdin) before any of it is allowed near /etc/hosts.
# POSIX sh + coreutils/awk only: the container is Ubuntu-based and the script
# must run under /bin/sh (dash), not bash.
_dce_hosts_reconcile_script() {
  local target="$1"
  local fragment="$2"
  local target_q="" fragment_q=""
  target_q="$(_dce_hosts_sh_quote "$target")"
  fragment_q="$(_dce_hosts_sh_quote "$fragment")"

  # Quoted heredoc: nothing expands while the template is read, so the embedded
  # awk programs' $0 etc. survive verbatim; only the @TARGET@/@FRAG@ sentinel
  # placeholders are substituted afterwards (with quoting applied).
  local script=""
  script="$(cat <<'EOF'
# Reconcile the dc-enclave managed hosts block. Best-effort: any failure still
# cleans up and exits 0 so the container entry point never breaks.
TARGET=@TARGET@
FRAG=@FRAG@
BEG='@BEGIN@'
END='@END@'
SRC="$(mktemp)" || exit 0
OUT="$(mktemp)" || { rm -f "$SRC"; exit 0; }
# Defense in depth: re-validate the fragment inside the container. Keep only
# lines with an IP and at least one hostname; comments, blanks, CRLF and short
# lines are dropped, leading/trailing whitespace trimmed.
awk '
  {
    line = $0
    sub(/\r$/, "", line)
    gsub(/^[[:space:]]+/, "", line)
    gsub(/[[:space:]]+$/, "", line)
    if (line == "") next
    if (substr(line, 1, 1) == "#") next
    if (split(line, parts, /[[:space:]]+/) < 2) next
    print line
  }
' "$FRAG" > "$SRC" 2>/dev/null
# Strip any previously managed block (markers inclusive) from wherever it sits
# in the file; everything outside the markers passes through untouched.
# Why buffer-and-recover: candidate block lines are only dropped once a matching
# END proves they were managed -- an unmatched BEGIN (hand-mangled file)
# restores its buffer at EOF, so recovery degrades to "stale block survives",
# never to silently losing the rest of the file; a stray END outside any block
# is dropped.
awk -v beg="$BEG" -v end="$END" '
  $0 == beg {
    if (inside) { buf[n++] = $0 } else { inside = 1; n = 0 }
    next
  }
  $0 == end { inside = 0; n = 0; next }
  inside { buf[n++] = $0; next }
  { print }
  END { for (i = 0; i < n; i++) print buf[i] }
' "$TARGET" > "$OUT" 2>/dev/null
# Write back IN PLACE: Docker bind-mounts /etc/hosts, so the file's inode must
# survive the write. Replacing the file outright swaps the inode and silently
# detaches the container's bind-mounted view; truncating it keeps the mount
# connected.
cat "$OUT" > "$TARGET" 2>/dev/null
# Append the fresh block only when the fragment yielded at least one entry; an
# empty fragment nets out to just the stale block being removed.
if [ -s "$SRC" ]; then
  printf '%s\n' "$BEG" >> "$TARGET"
  cat "$SRC" >> "$TARGET"
  printf '%s\n' "$END" >> "$TARGET"
fi
rm -f "$SRC" "$OUT" "$FRAG"
exit 0
EOF
)"
  script="${script//@TARGET@/$target_q}"
  script="${script//@FRAG@/$fragment_q}"
  script="${script//@BEGIN@/$_DCE_HOSTS_BLOCK_BEGIN}"
  script="${script//@END@/$_DCE_HOSTS_BLOCK_END}"
  printf '%s\n' "$script"
}

# Reconcile <project>'s hosts fragment into its container's /etc/hosts,
# idempotently. The fragment lives at ~/.config/dc-enclave/projects/<project>/hosts.
#
# Backend-aware gating: the project's backend is resolved from its config (via
# the hardened loader, in a throwaway subshell). For the apple/container backend
# the reconcile runs EVEN IF the fragment is absent, because apple gets no
# built-in host.docker.internal -- dce stages a managed gateway line
# ($_DCE_HOSTS_GATEWAY_LINE) that the container system's packet-filter rule
# redirects into host loopback. For every other backend (or an undeterminable
# backend) a missing fragment is still the strict pre-feature no-op with ZERO
# backend calls. User fragments never see the gateway line unless the backend
# is apple; the line is composed after the user's entries, inside the same
# BEGIN/END block, so the in-container reconcile script needs no changes.
#
# Flow: normalize on the host (invalid lines warn here and never reach the
# container), compose the staged content -- possibly just the gateway line,
# which also refreshes a stale block -- stream it into the container at
# /tmp/.dce-hosts via a root stdin exec, then run the generated reconcile
# script (which re-validates, strips any existing managed block, truncate-writes
# /etc/hosts in place, appends the fresh block, and removes the staging file).
#
# Best-effort by design: this runs inside dce shell/editor/start, so ANY
# backend failure only warns (naming the project, noting that entry continues)
# and returns 0. Silent on success.
dce_ensure_container_hosts() {
  local project="$1"

  # Backend lookup happens BEFORE the fragment gate: "no fragment" no longer
  # implies "no-op" once the backend is apple. The probe is best-effort -- `||
  # true` keeps an unloadable config from aborting entry under set -e -- and an
  # empty result falls through to the exact legacy behavior below.
  local backend=""
  backend="$(_dce_hosts_project_backend "$project" || true)"

  local fragment=""
  fragment="$(dce_project_hosts_file "$project")"

  # Preserved contract: non-apple backends without a fragment keep the exact
  # prior behavior -- a strict no-op with ZERO backend calls.
  if [[ "$backend" != "apple" && ! -f "$fragment" ]]; then
    return 0
  fi

  local normalized=""
  normalized="$(dce_hosts_normalize "$fragment")"

  # apple only: compose the managed gateway line AFTER any user fragment lines,
  # so it lands last inside the same managed block. (Exact string match on the
  # backend is safe: the config loader only accepts canonical backend ids.)
  if [[ "$backend" == "apple" ]]; then
    if [[ -n "$normalized" ]]; then
      normalized+=$'\n'"${_DCE_HOSTS_GATEWAY_LINE}"
    else
      normalized="${_DCE_HOSTS_GATEWAY_LINE}"
    fi
  fi

  # Stage the normalized fragment inside the container; it crosses via stdin,
  # never argv, and lands root-owned/600 so non-root users cannot tamper with
  # what the reconcile step is about to copy into /etc/hosts.
  # shellcheck disable=SC2016
  # sh -c runs in the container; the redirect happens there.
  if ! printf '%s\n' "$normalized" \
    | backend_exec_stdin_as_root "$project" sh -c 'cat > /tmp/.dce-hosts && chmod 600 /tmp/.dce-hosts'; then
    dce_warn "container hosts: could not stage the hosts fragment for project '$project'; container entry continues without hosts reconciliation"
    return 0
  fi

  local script=""
  script="$(_dce_hosts_reconcile_script /etc/hosts /tmp/.dce-hosts)"
  if ! backend_exec_as_root "$project" sh -c "$script"; then
    dce_warn "container hosts: could not reconcile /etc/hosts for project '$project'; container entry continues with a possibly stale hosts block"
    return 0
  fi
}
