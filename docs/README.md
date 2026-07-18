# DC Enclave documentation

The manual for DC Enclave, organized by what you're trying to do.

> **In a hurry?** Something broken or suspect? Jump to [rebuild and recover](how-to/rebuild-and-recover.md), [snapshot and rollback](how-to/snapshot-and-rollback.md), or [troubleshooting](troubleshooting.md). Run `dce doctor` first — it pinpoints drift in one shot.

## I want to…

| Task | Where |
|---|---|
| Install `dce` and create my first container | [getting started](tutorials/getting-started.md) |
| See every command | [command reference](reference/commands.md) |
| Look up a flag | [flag reference](reference/flags.md) |
| Change CPU / memory | [manage resources](how-to/manage-resources.md) |
| Set the timezone | [set the timezone](how-to/set-timezone.md) |
| Keep `node_modules` off my host | [hide generated paths](how-to/hide-generated-paths.md) |
| Get a large repo performing well in a VM | [sync workspace](how-to/sync-workspace.md) (`--sync`) |
| Manage VS Code extensions declaratively | [manage editor extensions](how-to/manage-editor-extensions.md) |
| Connect two containers privately | [private networks](how-to/connect-private-networks.md) |
| Reach my host Postgres | [connect to host PostgreSQL](how-to/connect-host-postgres.md) |
| Rebuild / recover from a bad state | [rebuild and recover](how-to/rebuild-and-recover.md) |
| Save a container state and roll back | [snapshot and rollback](how-to/snapshot-and-rollback.md) |
| Add tools to the image | [overlays](reference/overlays.md) |
| Pick or configure a backend | [backends](reference/backends.md) |
| Understand the security model | [isolation and security](explanation/isolation-and-security.md) |
| Fix something that's broken | [troubleshooting](troubleshooting.md) |

## Browse by type

**[Tutorials](tutorials/getting-started.md)** — learn the basics, end to end.

**How-to guides** — step-by-step recipes for specific tasks. See the [full list organized by theme](how-to/README.md).

**Reference** — look things up:
[concepts and glossary](reference/concepts.md) · [commands](reference/commands.md) · [flags](reference/flags.md) · [configuration](reference/configuration.md) · [overlays](reference/overlays.md) · [backends](reference/backends.md) · [provenance](reference/provenance.md) · [repository layout](reference/repository-layout.md)

**Explanation** — understand the design:
[why DC Enclave](explanation/why-dce.md) · [design principles](explanation/design-principles.md) · [isolation and security](explanation/isolation-and-security.md) · [overlay model](explanation/overlay-model.md)

Also: [troubleshooting](troubleshooting.md) · [running the test suite](maintaining.md) (for contributors).
