# How-to guides

Step-by-step recipes for specific tasks. Each guide is self-contained.

**Setup**

- [Install a container backend](install-backends.md) — per-platform install commands for Docker Desktop, OrbStack, Colima, Podman, and apple/container.

**Daily use**

- [Daily workflow](daily-workflow.md) — the day-to-day loop, with and without VS Code.
- [Manage CPU and memory](manage-resources.md) — set and change resource limits.
- [Set the timezone](set-timezone.md) — mirror your host zone into containers.

**Performance and large repos**

- [Hide generated paths from the host](hide-generated-paths.md) — keep `node_modules` and caches in container volumes.
- [Sync the workspace onto native ext4](sync-workspace.md) — `--sync` for large repos where the bind mount is too slow on macOS/WSL2.
- [Work with monorepos and multiple repos](work-with-monorepos.md) — single- and multi-container repo layouts.

**Editor and personalization**

- [Manage editor extensions](manage-editor-extensions.md) — declare/capture/sync VS Code extensions by scope.
- [Set up personal dotfiles](set-up-dotfiles.md) — apply your shell/editor/git config inside containers.

**Networking**

- [Connect containers with private networks](connect-private-networks.md) — let containers talk without publishing ports.
- [Connect to host PostgreSQL](connect-host-postgres.md) — reach a host database securely.

**Recovery**

- [Rebuild and recover](rebuild-and-recover.md) — rebuild containers, rotate keys, clean up, remove projects.
- [Snapshot and roll back](snapshot-and-rollback.md) — save a container's filesystem and hidden volumes as a full restore point, and roll back to it after a broken experiment.

**Git and auth**

- [Add a git host](add-git-host.md) — use GitLab/other hosts, and pin SSH host keys.
