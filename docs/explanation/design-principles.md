# Design principles


- **The orchestrator has no install footprint.** `dce` is pure Bash 4+ — no Node runtime, no Python, no `npm install -g`, no Homebrew formula. The tool that manages your sandboxes is just shell scripts running on the Bash every Unix already ships. Nothing outside your containers needs a package manager, so nothing outside your containers needs patching, pinning, or CVE auditing. Clone, run `setup.sh`, done.
- **Per-project isolation by default.** Each container gets its own credentials, hidden volumes, and (optionally) its own network. Projects can't see each other unless you explicitly link them.
- **Rebuildable, not stateful.** Containers are disposable; your code and config are not. Everything that matters lives on the host or in version-controlled overlay files; the container is regenerated from them on demand.
- **Reproducible by provenance.** Every built image records the overlay commits and content fingerprints that produced it, so you can answer "what state were my overlays in when this image was built?" without archaeology.
- **Fail-closed on trust.** Host keys pinned in-image, no runtime `ssh-keyscan`, no `accept-new`. A poisoned pin is caught by a test, not by a breach.

