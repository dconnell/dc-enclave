# Overlay model

## Three-source model (repo, team overlays, user overlays)

Keep these sources separate:

1. **DC Enclave repo** (`Containerfiles/base` + `templates/`, scripts, docs)
2. **team overlays source** (files synced into `$DC_TEAM_DIR/overlays`)
3. **user overlays source** (files synced into `$DC_USER_DIR/overlays`)

This separation keeps team and personal customization independent, and keeps layering deterministic.

Recommended flow:

- keep `$DC_TEAM_DIR` as a git checkout of a private team root repository (overlays + recipes) and update with `git pull`
- keep `$DC_USER_DIR` as a git checkout of your personal root repository (overlays + recipes) and update with `git pull`
- keep the public `DC Enclave` repository focused on base image definition and reference templates under `templates/`

Example setup:

```
git clone git@github.com:YOUR-ORG/dc-enclave-team-root.git "$DC_TEAM_DIR"
git clone git@github.com:YOUR-USER/dc-enclave-user-root.git "$DC_USER_DIR"
```

Then keep them current:

```bash
git -C "$DC_TEAM_DIR" pull --ff-only
git -C "$DC_USER_DIR" pull --ff-only
```


### Overlay ownership model

- `templates/` in this repo is for reference templates only (never auto-layered)
- `$DC_TEAM_DIR/overlays/` is for shared team overlays
- `$DC_USER_DIR/overlays/` is for personal overlays


### Canonical layering order

For scope list `<scope1>,<scope2>`, overlay composition order is:

1. `team/all`
2. `user/all`
3. `team/<scope1>`
4. `user/<scope1>`
5. `team/<scope2>`
6. `user/<scope2>`


`dce-base` is always the only repo-defined base layer. The `all` scope is always checked first — if `Containerfile.all` exists in team or user overlays, it is included automatically even without specifying `all` on the command line.

Missing unrequested overlay files are skipped silently. If you request a named scope and it is missing in both `team/` and `user/`, the command fails fast.


### Compose-time embedding (`# DC-EMBED:`)

Overlay fragments stay readable Dockerfiles, but scripts they install (relay
daemons, entrypoint hooks) do not have to be inlined as readable text: a
`# DC-EMBED: <src> <dest> [mode]` comment line is rewritten by
`scripts/compose-containerfile.sh` into a single RUN that decodes a
gzip+base64 blob into `<dest>` (full syntax in
[Overlays](../reference/overlays.md#embedding-files-dc-embed)). Encoding
happens at compose time on every run, so the committed overlay keeps one
source of truth — there is no generated file to drift out of date — and the
compressed form keeps composed files under apple/container's effective ~11.5KB
Dockerfile cap — the file travels base64-encoded inside a ~16,384-byte gRPC
header, so the raw header limit translates to only ~11.5KB of Dockerfile (see
[apple/container issue #735](https://github.com/apple/container/issues/735)).
Composes that still exceed the cap are split into transport parts instead —
see [Apple transport chaining](#apple-transport-chaining).

The `COPY`/`ADD` ban stays even with embedding available: team and user
fragments must compose portably, without coupling the derived image to
whatever build context happens to exist on the machine running the build.
`# DC-EMBED:` preserves that contract — the bytes travel inside the generated
Containerfile itself — and the provenance content hash folds every embedded
source, so editing an embedded file still produces a new image.


### Apple transport chaining

The cap above is a transport limit, not a builder limit: apple/container
ships the Dockerfile base64-encoded inside a gRPC header, gRPC caps headers
at ~16,384 bytes, and base64's 4/3 inflation shrinks the usable payload to
~11.5KB of Dockerfile
([apple/container issue #735](https://github.com/apple/container/issues/735)
— no upstream fix in sight: assigned to a maintainer who has since left the
project, and its milestones were removed). Encoding keeps ordinary composes
under the cap, but it cannot shrink an arbitrarily large embedded script, so
for those composes `scripts/compose-containerfile.sh` derives transport
parts — `Containerfile.<hash>.p0`, `.p1`, … — from the unchanged canonical
file, each small enough for one header and chained with
`FROM dce-stage-<hash>-<k>:latest` tags so building the parts in order
assembles the same image (syntax and guarantees in
[Overlays](../reference/overlays.md#apple-transport-chaining)).

None of this is visible at the `dce` level. `dce rebuild-image` and `dce new`
build the parts sequentially, tagging the final part `dce-img-<hash>` as
always; if apple's native builder blocks a part — an oversize header, or the
egress/context failure classes — the whole chain restarts on a docker/podman
peer from part 0 and the finished image is loaded back into apple's store
(stages built so far live only in apple's store, so a peer could not resume
mid-chain). The stage tags are pure intermediates and `dce clean` reclaims
them. Whether or not a compose was split, the image ref and the provenance
labels are identical: the content hash covers overlay sources, not composed
bytes, so `dce-img-<hash>` names the same image whatever the transport did
(see [Image provenance](../reference/provenance.md)).
