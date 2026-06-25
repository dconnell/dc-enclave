# Manage CPU and memory


All five backends support per-container CPU and memory limits. Set them at creation time or change them in the config file and rebuild.

Set limits at creation:

```
dce new myapp nodejs --cpus 2 --memory 4g 3000:3000
```

Omit scope for a base-only project with resource limits:

```
dce new myapp --cpus 2 --memory 4g 3000:3000
```

Omit both flags to use backend defaults (typically unrestricted).

Change limits on an existing project:

1. Edit `~/.config/dce-enclave/<name>/config`
2. Update `CONTAINER_CPUS` and/or `CONTAINER_MEMORY`
3. Run `dce rebuild-container <name>`

Resource limits are applied at container creation time. Changes to the config file take effect only after `dce rebuild-container` — `dce start` simply starts the existing container with its existing limits.

Config keys:

- `CONTAINER_CPUS` — number of CPUs (e.g. `2`, `1.5`). Empty = backend default.
- `CONTAINER_MEMORY` — memory limit with suffix (e.g. `4g`, `512m`). Empty = backend default.

All backends use the same flag syntax (`--cpus`, `--memory`). No backend-specific configuration is needed.

