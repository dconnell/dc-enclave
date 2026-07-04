# Overlays

## Base image tools


The base image is intentionally minimal and shared across all scope selections. It includes essentials only:

- git
- curl
- wget
- openssh-client
- ca-certificates
- gnupg
- zsh
- procps
- sudo
- tzdata (IANA timezone database — needed to resolve `TZ`; see [Timezone syncing](../how-to/set-timezone.md))

The base image also includes default shell setup for `dev` with `alias ll='ls -la'`.

Preferred day-to-day tools (for example `tree`, `rg`, `fzf`, `psql`, custom CLIs) should be layered through a user overlay Containerfile. Personal shell/editor/git preferences remain in dotfiles.


## Overlay contract

- Treated as Dockerfile fragments layered on top of `dce-base`
- `FROM` and `CMD` are ignored during composition
- `COPY` and `ADD` are not allowed (to avoid external build-context coupling)

## Editor extension manifests

Editor extensions are declared in manifests (not image layers):

```
$DC_TEAM_DIR/extensions/<editor>/<scope>.txt
$DC_USER_DIR/extensions/<editor>/<scope>.txt
```

v1 editor namespace is `vscode`, so typical files are:

- `extensions/vscode/all.txt`
- `extensions/vscode/nodejs.txt`

Manifest format:

- one extension ID (`publisher.name`) per line
- blank lines and `#` comments allowed

Layering matches overlay scopes:

- `all` is auto-prepended when present
- then each effective project scope
- team file before user file per scope
- merged output is de-duplicated and order-preserving

Why manifests (not `Containerfile.<scope>`): VS Code extensions install via
`customizations.<editor>.extensions` in `devcontainer.json` when VS Code opens
the container. The `code` CLI is not available at image build time, so image-
baked `RUN code --install-extension ...` is not a viable path.

Use `dce extensions ...` to inspect/capture, and `dce config sync-vscode <name>`
to reconcile managed `devcontainer.json` fields.


## Install-on-start behavior

Scope-specific overlays can build on hidden volumes. The Node.js overlay
(`Containerfile.nodejs`) includes an entrypoint that:

- detects a hidden `node_modules` volume
- runs `npm ci` (if a lockfile exists) or `npm install` automatically on container start
- writes a hash sentinel so deps are only re-installed when `package.json` or `package-lock.json` changes
- fails soft by default; set `DC_NODE_INSTALL_STRICT=1` to make install errors fatal

The `golang`, `rust`, `dotnet`, and `python` example overlays follow the same
shape with their own package manager (`go mod download`, `cargo fetch`,
`dotnet restore`, `uv sync`) and a matching `DC_<LANG>_INSTALL_STRICT=1` env.
See `Containerfiles/example/README.md` for each overlay's `--hide` paths and
sync command.

This means you get fast, correct dependency sync without any `node_modules` files touching your host.

> **Install-on-start can run code (security).** For `nodejs` and `python`, the
> sync step can execute lifecycle/build scripts (`npm` hooks; uv/PEP 517 source
> builds) — so an untrusted dependency can run code at container start. The
> `golang`/`rust`/`dotnet` sync steps only download and do not run fetched code.
> For untrusted inputs, disable install-time code with `DC_NODE_IGNORE_SCRIPTS=1`
> or `DC_PYTHON_IGNORE_SCRIPTS=1`. See the *Trusted vs untrusted overlays*
> section in `Containerfiles/example/README.md`.
