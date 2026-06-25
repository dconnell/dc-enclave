# Overlay model

## Three-source model (repo, team overlays, user overlays)

Keep these sources separate:

1. **DC Enclave repo** (`Containerfiles/base + Containerfiles/example`, scripts, docs)
2. **team overlays source** (files synced into `$DC_TEAM_DIR/overlays`)
3. **user overlays source** (files synced into `$DC_USER_DIR/overlays`)

This separation avoids coupling team customization with personal customization and keeps layering deterministic.

Recommended flow:

- keep `$DC_TEAM_DIR` as a git checkout of a private team root repository (overlays + recipes) and update with `git pull`
- keep `$DC_USER_DIR` as a git checkout of your personal root repository (overlays + recipes) and update with `git pull`
- keep the public `DC Enclave` repository focused on base image definition and reference templates under `Containerfiles/example/`

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

- `Containerfiles/example/` in this repo is for reference templates only (never auto-layered)
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
