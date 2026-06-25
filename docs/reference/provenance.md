# Image provenance


Each derived image (`dce-img-*`) is rebuilt in place and `:latest` is overwritten on every rebuild by design, so to answer *"what state were my overlay repos in when this image was built?"* DC Enclave records provenance:

- **OCI labels on the image** — `docker image inspect <img>` / `podman image inspect <img>` show `dce.team.git_commit`, `dce.user.git_commit`, `dce.team.content_hash`, `dce.content.hash`, `dce.base.id`, `dce.scopes`, `dce.built.utc`, and `org.opencontainers.image.revision`. Per overlay source (`team/`, `user/`) the git HEAD commit is recorded when that directory is a git checkout; a content fingerprint of the layered files is always recorded.
- **A per-project log** — `~/.config/dce-enclave/<name>/provenance.jsonl` (JSON Lines, owner-only) appends one entry per distinct image state, so the history survives the `:latest` overwrite. It is written when a derived image is actually built (`dce new`, `dce rebuild-image`), not on `dce rebuild-container` (which does not build) or base-only projects.

Read it back with:

```
dce provenance myapp                 # current build's provenance (pretty)
dce provenance myapp --history       # full timeline as a table
dce status                           # one-line provenance summary per project
```

To reproduce a build for debugging: read the `team`/`user` commit from `dce provenance`, check it out in the corresponding root (`git -C "$DC_TEAM_DIR" checkout <sha>` or `git -C "$DC_USER_DIR" checkout <sha>`), then `dce rebuild-image all && dce rebuild-container <name>`. A side not under git shows only its content fingerprint — no commit to check out, but the fingerprint still tells you whether your current files match that build.

`git_dirty: true` (label / log) means the image includes uncommitted overlay edits at build time.

