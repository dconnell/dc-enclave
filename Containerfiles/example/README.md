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

## Supply-chain notes

These templates avoid remote-script execution (no `curl | bash`). Specifics:

- **Containerfile.nodejs** installs Node.js from the Ubuntu archive via `apt`,
  not from a NodeSource setup script. The version therefore tracks the Ubuntu
  24.04 package rather than the Node LTS line. If you need a specific Node
  version, pin a downloaded Node binary tarball (verify its checksum) in your
  own overlay.
- **Containerfile.golang** downloads the Go tarball and verifies it against a
  pinned `GO_SHA256_ARM64` checksum before extracting. When you bump
  `GO_VERSION`, update `GO_SHA256_ARM64` to the matching published checksum or
  the build fails fast.
- **Containerfile.all** does not install opencode automatically. To use it, opt
  in explicitly in your own overlay (review the official installer, or install
  a pinned release artifact and verify its checksum).
