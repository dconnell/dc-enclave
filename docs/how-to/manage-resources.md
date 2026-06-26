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

```
dce config set <name> cpus=4
dce config set <name> memory=8g
dce rebuild-container <name>
```

Clear a limit back to the backend default by setting it empty:

```
dce config set <name> cpus=
```

`dce config` is a thin, validating wrapper over the config file — it stays the source of truth. Use `dce config show <name>` to inspect the current values and `dce config get <name> memory` to read one value for scripting. (You can still edit `~/.config/dce-enclave/<name>/config` by hand, but `dce config set` validates before it writes.)

Resource limits are applied at container creation time. Changes take effect only after `dce rebuild-container <name>` — `dce start` simply starts the existing container with its existing limits. `dce config set` prints a reminder.

Config keys:

- `CONTAINER_CPUS` — number of CPUs (e.g. `2`, `1.5`). Empty = backend default.
- `CONTAINER_MEMORY` — memory limit with suffix (e.g. `4g`, `512m`). Empty = backend default.

All backends use the same flag syntax (`--cpus`, `--memory`). No backend-specific configuration is needed.

