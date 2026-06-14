# Example Containerfiles

This directory contains reference-only overlay templates you can copy into your
global overlay namespaces.

These files are never auto-layered directly from the repository.

Typical overlay workflow:

1. Run `scripts/setup.sh` to create `$DC_OVERLAYS_DIR/team` and `$DC_OVERLAYS_DIR/user`.
2. Copy starter overlay fragments from this directory into one of those namespaces.
3. Edit them for your team/personal workflow.

Supported auto-layer filenames in team/user namespaces:

- `Containerfile.all`
- `Containerfile.<scope>` (any scope name you choose)
