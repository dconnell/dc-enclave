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
- Composed output is a machine artifact for apple/container: comment lines and
  blank lines are stripped from fragments at compose time in the default
  `--backend apple` variant (to help stay under apple/container's
  ~11.5KB effective cap — see below), so keep documentation in the fragment —
  it stays fully
  readable and is never committed downstream. The readable `--backend docker`/
  `orbstack`/`colima`/`podman` variants (see the DC-EMBED section below)
  preserve fragment comments and blank lines instead. Heredoc bodies are exempt
  from stripping in every variant: a `#`
  inside a heredoc is script content, and every body line (including
  `FROM`/`CMD`/`ENTRYPOINT`-looking lines) is preserved byte-for-byte until the
  terminator. Delimiters may be quoted or bare and may contain letters,
  digits, `.`, `_`, `-` (e.g. `<<'EOF.V2'`, `<<EOF-2`). A heredoc still open at
  the end of a fragment draws a non-fatal compose warning naming the fragment
  and the delimiter — that catches a terminator typo as well as a `<<` that
  was never a heredoc (a bit-shift like `$((1<<2))` or a `<<<` here-string).

## Embedding files: `# DC-EMBED:`

apple/container does not send the raw Dockerfile to its builder: it ships it
base64-encoded inside a gRPC header, and gRPC caps headers at ~16,384 bytes.
base64 inflates by 4/3 (encoded size = ceil(bytes/3)*4), so the *effective*
Dockerfile limit is ~11.5KB, not 16,384 bytes — files up to the raw 16,384-byte
header cap can pass a naive size check yet still fail the real build
([apple/container issue #735](https://github.com/apple/container/issues/735)).
When an apple-mode compose exceeds 11,520 bytes (~15,360 encoded), compose
warns and additionally splits the file into transport parts (see
[Apple transport chaining](#apple-transport-chaining)). Overlay fragments also
cannot use `COPY`/`ADD` (they must
stay free of any external
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

### Backend variants: `--backend`

The encoded form above exists only for apple/container's transport, so compose
accepts an optional `compose-containerfile.sh --backend <name>` flag naming the
build target, with two variants:

- **`apple` (default)** — the encoded/minified form above: DC-EMBED sources
  inlined as gzip+base64 decode RUNs, fragment comments and blank lines
  stripped (the composed file is a machine artifact), and the 11,520-byte
  size guard armed. This is the only form that fits apple/container's
  gRPC-header transport; when a compose still exceeds the guard, it is split
  into transport parts (see
  [Apple transport chaining](#apple-transport-chaining)).
- **`docker`, `orbstack`, `colima`, `podman` (readable)** — these backends
  have no Dockerfile cap, so encoding would only destroy build-error
  readability (errors would point into opaque base64 instead of real lines).
  Each directive is emitted as a verbatim heredoc instead:

  ```
  # DC-EMBED <src> -> <dest> (source: <overlays-dir>/<src>)
  RUN cat > <dest> <<'DCE_EMBED_EOF'
  <the source file, byte-for-byte>
  DCE_EMBED_EOF
  RUN chmod <mode> <dest>
  ```

  Fragment comments and blank lines are preserved, and no size guard runs.
  If a source itself contains a line equal to `DCE_EMBED_EOF`, compose
  deterministically suffices the delimiter (`DCE_EMBED_EOF_2`, then `_3`, …)
  so the heredoc cannot terminate early. The emitted heredoc is always
  well-formed: even a source lacking a trailing newline gets one inserted
  before the terminator, so the terminator always sits on its own line. That
  newline is part of the text, so the dest inside the image then differs from
  the source by exactly one appended trailing newline (encoded apple-mode
  embeds preserve bytes exactly).

Everything else is shared: the FROM (first line)/CMD/ENTRYPOINT strip and the
COPY/ADD ban apply identically in both variants, the provenance labels fold
the embedded sources (mode-independent, so image identity stays comparable),
and both variants are deterministic across repeated composes on one machine.

The flag is optional and omitting it means `apple` — a fail-safe default: the
encoded form is exactly what satisfies apple/container's cap, so a forgotten
flag on a docker-family backend only costs readability, never correctness
(it can never produce an over-cap apple file). Names are matched
case-insensitively, and the CLI entry points (`dce rebuild-image`, `dce new`)
pass the active backend on every compose — the flag matters only when
invoking `compose-containerfile.sh` directly.

### Apple transport chaining

apple/container's transport, not its builder, sets the hard limit: the
Dockerfile travels base64-encoded inside a gRPC header capped at ~16,384
bytes — roughly 11.5KB of Dockerfile once base64's 4/3 inflation is paid
([apple/container issue #735](https://github.com/apple/container/issues/735)).
Encoding keeps most composes under that bound, but it cannot shrink an
arbitrarily large embedded source. When the canonical apple-mode composed
file exceeds 11,520 bytes, compose additionally emits
`Containerfile.<hash>.p0`, `.p1`, … next to it — transport parts, each small
enough for one header:

- The canonical file is left unchanged and remains the single source of
  truth; parts are derived artifacts, re-derived on every compose. Stale
  `.pN` files from earlier composes are pruned in both modes, so an over-cap
  apple compose followed by a readable compose leaves zero part files.
- Part 0 starts `FROM dce-base:latest`; part k starts
  `FROM dce-stage-<hash>-(k-1):latest`, resuming the previous part's stage.
  The provenance ARG/LABEL block and the USER/ENTRYPOINT/CMD trailer are
  emitted only in the final part.
- Splits fall only at instruction boundaries and never inside a heredoc
  body, and packing is deterministic: the same canonical file always yields
  the same parts. A single unit that alone exceeds the cap (e.g. one huge
  DC-EMBED blob) gets a dedicated over-cap part plus a WARN — apple's native
  builder will refuse it; build on a docker/podman peer or split the
  embedded source.
- Readable-mode compose never emits parts.

`dce rebuild-image` and `dce new` build derived images through the chained
path (`backend_build_image_chained` in `lib/container-backend.sh`) whenever
parts exist:

- **apple** — parts build sequentially: part k as
  `dce-stage-<hash>-<k>:latest`, the final part under the canonical
  `dce-img-<hash>` tag carrying the provenance build-args (no other part
  gets build-args). If a part fails natively with an environment/transport
  block (oversize header, egress/context class), the WHOLE chain restarts on
  a docker/podman peer from part 0 — stages built so far exist only in
  apple's image store, invisible to a peer builder, so continuing mid-chain
  could not resolve their chained `FROM` tags — and the final image is
  loaded back into apple's store. A genuine Containerfile error aborts
  instead: it would fail identically on the peer.
- **docker-family/podman** — parts are ignored entirely; the single
  canonical file is built as always (no cap there).
- A broken part sequence (`.p1` missing while `.p2` exists) fails fast
  naming the missing file: the chain would otherwise build FROM an image
  that is never produced.

`dce clean` reclaims `dce-stage-<16hex>-<n>` tags along with the other DC
Enclave image families: stage tags are pure build intermediates, and the
final `dce-img-<hash>` exists independently of them.

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
