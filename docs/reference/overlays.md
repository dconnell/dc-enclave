# Overlays

## Base image tools


The base image is minimal and shared across all scope selections. It includes essentials only:

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
- `FROM` (first line only), `CMD`, and `ENTRYPOINT` lines are ignored during
  composition — except inside heredoc bodies, where they are script data and
  are preserved verbatim
- `COPY` and `ADD` are not allowed (to avoid external build-context coupling)
- `# DC-EMBED:` comment lines embed a file into the image at compose time (see below)
- Composed output is a machine artifact: comment lines and blank lines are
  stripped from fragments at compose time (to help stay under apple/container's
  16,384-byte cap), so keep documentation in the fragment — it stays fully
  readable and is never committed downstream. Heredoc bodies are exempt: a `#`
  inside a heredoc is script content, and every body line (including
  `FROM`/`CMD`/`ENTRYPOINT`-looking lines) is preserved byte-for-byte until the
  terminator. Delimiters may be quoted or bare and may contain letters,
  digits, `.`, `_`, `-` (e.g. `<<'EOF.V2'`, `<<EOF-2`). A heredoc still open at
  the end of a fragment draws a non-fatal compose warning naming the fragment
  and the delimiter — that catches a terminator typo as well as a `<<` that
  was never a heredoc (a bit-shift like `$((1<<2))` or a `<<<` here-string).

## Embedding files: `# DC-EMBED:`

apple/container refuses to build a Dockerfile larger than 16,384 bytes, and
overlay fragments cannot use `COPY`/`ADD` (they must stay free of any external
build context). To ship a script in an overlay — an entrypoint hook, a small
relay, a wrapper — without inlining it as readable text, put a directive
comment line in the fragment:

```
# DC-EMBED: <src> <dest> [mode]
```

- `<src>` is relative to the fragment's own `overlays/` directory (e.g.
  `files/dce-relay.js`, living next to `Containerfile.<scope>`). Absolute paths
  and any `..` component are rejected, the file must exist, and the path must
  still resolve inside the overlays directory when all symlinks are followed
  (a symlinked `files/` entry pointing outside it is rejected) — otherwise
  compose fails with an error naming the fragment and the path.
- `<dest>` is an absolute path inside the image. Keep it to letters, digits and
  `. _ / @ + -`: it is interpolated verbatim into a RUN command.
- `[mode]` is an optional octal permission (e.g. `0755`); the default is
  `0644`.

At compose time each directive is rewritten into a self-contained pair of
lines in the generated Containerfile:

```
# DC-EMBED <src> -> <dest> (compressed; source: <overlays-dir>/<src>)
RUN printf '%s' '<base64>' | base64 -d | gunzip > <dest> && chmod <mode> <dest>
```

The source is compressed with `gzip -n` (no timestamp/name in the header) and
encoded with single-line `base64`, so composing the same overlays twice on the
same machine yields a byte-identical Containerfile. (GNU and BSD `gzip`/`base64`
may produce different bytes for the same input, so byte-for-byte reproducibility
is only claimed for repeated composes on one machine.) The readable source stays
next to the fragment and nothing generated is committed — one source of truth,
no generated-file drift.

Notes:

- The emitted RUN needs `gzip` and `base64` at image build time. `dce-base`
  (ubuntu:24.04) ships both; if the base image ever changes, keep them.
- The destination's parent directory must already exist when the RUN executes
  (add your own `RUN mkdir -p ...` before the directive if needed); the
  directive deliberately does not bundle a `mkdir`.
- Multiple `# DC-EMBED:` lines per fragment are allowed and are emitted in
  file order. Directives are rewritten before comment stripping, so their
  emitted marker comment and decode RUN always survive in the composed file
  even though the directive line itself is a comment in the source.
- Editing a `<src>` file changes the image's provenance content hash (the v2
  hash folds every embedded source, see
  [Provenance](provenance.md)), so a rebuild never reuses a stale image.

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

- detects an empty or absent `node_modules` (regardless of cause)
- runs `npm ci` (if a lockfile exists) or `npm install` automatically on container start
- writes a hash sentinel so deps are only re-installed when `package.json` or `package-lock.json` changes
- fails soft by default; set `DC_NODE_INSTALL_STRICT=1` to make install errors fatal

The trigger fires whenever the target directory is empty or missing — whether
the path is a [`--hide`](../how-to/hide-generated-paths.md) named volume or a
fresh volume.

The `golang`, `rust`, `dotnet`, and `python` example overlays follow the same
shape with their own package manager (`go mod download`, `cargo fetch`,
`dotnet restore`, `uv sync`) and a matching `DC_<LANG>_INSTALL_STRICT=1` env.
See `templates/overlays/README.md` for each overlay's `--hide` paths and
install command.

Dependencies sync quickly and correctly, and no `node_modules` files touch your host.

> **Install-on-start can run code (security).** For `nodejs` and `python`, the
> sync step can execute lifecycle/build scripts (`npm` hooks; uv/PEP 517 source
> builds) — so an untrusted dependency can run code at container start. The
> `golang`/`rust`/`dotnet` sync steps only download and do not run fetched code.
> For untrusted inputs, disable install-time code with `DC_NODE_IGNORE_SCRIPTS=1`
> or `DC_PYTHON_IGNORE_SCRIPTS=1`. See the *Trusted vs untrusted overlays*
> section in `templates/overlays/README.md`.
