#!/bin/sh
set -eu

log() { printf '%s\n' "[playwright-server] $*"; }

# One headless Chromium per flavor. Chromium ignores --remote-debugging-
# address and binds DevTools to loopback only (IPv4 or IPv6 per run); the
# relay below re-exposes the port on 0.0.0.0. The browser listens on a
# PRIVATE loopback port (external + 10000) so the relay's wildcard bind can
# never collide with it -- relaying into its own listener would otherwise
# self-loop. --remote-allow-origins=* is required for WS upgrades from
# network peers (Chromium rejects cross-origin DevTools clients otherwise).
# The dce private network is the access boundary (ports are never
# published to the host). A dedicated user-data-dir is required for remote
# debugging on modern Chromium and keeps state disposable in /tmp.
launch() { # <browser-root> <external-port> <flavor>
  # Layout differs by arch: chrome-linux (amd64) vs chrome-linux-arm64 (arm64).
  bin="$(echo "$1"/chromium-*/chrome-linux*/chrome)"
  if [ ! -x "$bin" ]; then
    log "ERROR: no chromium binary under $1"
    exit 1
  fi
  internal_port="$(($2 + 10000))"
  nohup "$bin" \
    --headless=new \
    --remote-debugging-port="$internal_port" \
    --remote-debugging-address=0.0.0.0 \
    --remote-allow-origins='*' \
    --no-sandbox \
    --disable-dev-shm-usage \
    --user-data-dir="/tmp/playwright-profile-$3" \
    >"/tmp/playwright-$3.log" 2>&1 &
  log "started $3 on internal port $internal_port (log: /tmp/playwright-$3.log)"
}

# TCP relay 0.0.0.0:<port> -> loopback:<port+10000> (see dce-cdp-relay.js).
relay() { # <port>
  internal_port="$(($1 + 10000))"
  nohup node /home/dev/.local/bin/dce-cdp-relay.js "$1" "$internal_port" \
    >"/tmp/playwright-relay-$1.log" 2>&1 &
  log "relay 0.0.0.0:$1 -> 127.0.0.1/::1:$internal_port (log: /tmp/playwright-relay-$1.log)"
}

launch /ms-playwright-stable 9300 stable
launch /ms-playwright-canary 9301 canary
relay 9300
relay 9301
log "ready: stable=:9300 canary=:9301"
