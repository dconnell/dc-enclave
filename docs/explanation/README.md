# Explanation

Background and design reasoning — read top to bottom to understand the why.

- [Why DC Enclave](why-dce.md) — the value of a hard container boundary, and how `dce` compares to raw Docker/Podman.
- [Design principles](design-principles.md) — the principles the tool is built on.
- [Isolation and security](isolation-and-security.md) — per-project credentials, the credential-injection lifecycle, git-host pinning, the VS Code remote-RCE caveat, and how snapshots scrub secrets.
- [Overlay model](overlay-model.md) — the three-source model, overlay ownership, and canonical layering order.
