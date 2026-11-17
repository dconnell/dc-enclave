# Image provenance


Each derived image (`dce-img-*`) is rebuilt in place and `:latest` is overwritten on every rebuild by design, so to answer *"what state were my overlay repos in when this image was built?"* DC Enclave records provenance. Projects reference that image via their `dce-<project>` alias tag, but build events always record the canonical `dce-img-*` ref (restore events instead record the `dce-snap-*` snapshot they restored from) — it describes the built image, not a project's view of it:

- **OCI labels on the image** — `docker image inspect <img>` / `podman image inspect <img>` show `dce.team.git_commit`, `dce.user.git_commit`, `dce.team.content_hash`, `dce.content.hash`, `dce.base.id`, `dce.scopes`, `dce.built.utc`, and `org.opencontainers.image.revision`. Per overlay source (`team/`, `user/`) the git HEAD commit is recorded when that directory is a git checkout; a content fingerprint of the layered files is always recorded. The fingerprint (the v2 scheme) also folds the hash of every `# DC-EMBED:` source file each fragment references into that side's hash, so editing an embedded file changes the fingerprint even when the fragment itself is untouched (see [Overlays](overlays.md)).
- **A per-project log** — `~/.config/dc-enclave/projects/<name>/provenance.jsonl` (JSON Lines, owner-only) appends one entry per distinct image state, so the history survives the `:latest` overwrite. It is written when a derived image is actually built (`dce new`, `dce rebuild-image`), not on a plain `dce rebuild-container` (which does not build) or base-only projects. Snapshot/restore events also append their own entries (`action: "snapshot"` / `"restore"`) so the log distinguishes images that came from a `dce snapshot` rather than a scope-derived build.

Provenance is compose-variant independent: the v2 content hash covers the
overlay sources (fragments and every `# DC-EMBED:` source file), not the
composed bytes, so the `dce-img-<hash>` ref is identical whichever
`--backend` variant composed it (see
[Overlays](overlays.md#backend-variants---backend)). When apple transport
chaining splits a compose into `Containerfile.<hash>.pN` parts
([Overlays](overlays.md#apple-transport-chaining)), the full provenance
ARG/LABEL block is emitted only in the final part; the
`dce-stage-<hash>-<n>` stage tags the intermediate parts build under are
pure build intermediates, not provenance — they never appear in
`dce provenance` output or the provenance log.

Read it back with:

```
dce provenance myapp                 # current build's provenance (pretty)
dce provenance myapp --history       # full timeline as a table
dce status                           # one-line provenance summary per project
```

To reproduce a build for debugging: read the `team`/`user` commit from `dce provenance`, check it out in the corresponding root (`git -C "$DC_TEAM_DIR" checkout <sha>` or `git -C "$DC_USER_DIR" checkout <sha>`), then `dce rebuild-image all && dce rebuild-container <name>`. An overlay source not under git shows only its content fingerprint — no commit to check out, but the fingerprint still tells you whether your current files match that build.

`git_dirty: true` (label / log) means the image includes uncommitted overlay edits at build time.
