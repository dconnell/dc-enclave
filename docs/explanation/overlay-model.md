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
compressed form keeps composed files small enough for apple/container's
16,384-byte Dockerfile cap.

The `COPY`/`ADD` ban stays even with embedding available: team and user
fragments must compose portably, without coupling the derived image to
whatever build context happens to exist on the machine running the build.
`# DC-EMBED:` preserves that contract — the bytes travel inside the generated
Containerfile itself — and the provenance content hash folds every embedded
source, so editing an embedded file still produces a new image.
