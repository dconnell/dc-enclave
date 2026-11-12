# Shared browser host pattern

## What this is

A shared headless browser host for agents. One dumb container runs two pinned
Chromium flavors (stable + canary lines) with CDP endpoints on ports 9300/9301
behind a small TCP relay; any project container gets browser automation via a
thin client scope.

Browsers live outside project containers on purpose: memory is centralized in
one place, and project images stay lean (no browser binaries, no `install-deps`
layer per project).

## Files and where they land

| File | Destination | Notes |
|---|---|---|
| `Containerfile.playwright` | `$DC_USER_DIR/overlays/` | Browser host overlay; auto-applies to the `playwright` scope. |
| `Containerfile.playwright-client` | `$DC_USER_DIR/overlays/` | Thin client overlay; auto-applies to the `playwright-client` scope. |
| `playwright` | `$DC_USER_DIR/container-recipes/` | Recipe. The filename IS the container name — `dce new playwright` reads it. |

## Instantiate

```
cp Containerfile.playwright Containerfile.playwright-client "$DC_USER_DIR/overlays/"
cp playwright "$DC_USER_DIR/container-recipes/"
dce network create playwright
dce new playwright          # recipe auto-applies: scopes, network, memory=8g
# clients:
dce new <name> nodejs,playwright-client --network playwright
# existing containers join later:
dce network add playwright <name>
```

After adding overlays, `dce rebuild-image all` bakes them into derived images.
The MCP entries (opencode or otherwise) point at `http://playwright:9300`
(stable) or `http://playwright:9301` (canary).

## OpenCode MCP configuration

With the browser host running and the client container on the `playwright`
network, configure the MCP client. For OpenCode, merge this into
`opencode.json` (global or project):

```jsonc
"mcp": {
    "servers": {
      "playwright": {
        "type": "local",
        "command": ["npx", "--prefer-offline", "-y", "@playwright/mcp@0.0.84", "--cdp-endpoint", "http://playwright:9300", "--isolated"]
      },
      "playwright-canary": {
        "type": "local",
        "command": ["npx", "--prefer-offline", "-y", "@playwright/mcp@0.0.84", "--cdp-endpoint", "http://playwright:9301", "--isolated"]
      }
    }
  }
```

- port 9300 = the stable Chromium flavor, 9301 = the canary flavor; pick either or both
- `--prefer-offline` starts from the npx cache the `playwright-client` overlay pre-warms at build time (falls back to the network on a cache miss)
- `--isolated` gives each MCP session its own in-memory browser context, so concurrent agents don't share tabs or profile state
- `--cdp-endpoint` — connect to the shared headless browsers in the `playwright` container instead of launching a local one
- the pin must match the client overlay's prewarmed version for offline starts

## Ops notes

- Endpoints self-heal: an entrypoint hook relaunches both browsers and relays
  on every container start, so `dce restart` and `dce rebuild-container` bring
  the CDP ports back without manual steps.
- Browser updates: bump the two playwright pins (stable + canary) in
  `Containerfile.playwright` and rebuild.
- Size the recipe `memory=` for peak concurrent sessions — every client tab
  shares this one container's budget.

## Security model

The browser container is deliberately credential-free: no repos, no git token,
no dotfiles install. A compromised browser owns nothing. The private network is
the access boundary — only containers explicitly joined to the `playwright`
network can reach the CDP endpoints, and the ports are never published to the
host. See `docs/how-to/connect-private-networks.md`.
