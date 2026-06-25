# Set the timezone


Each container mirrors its developer's host timezone, so timestamps (`date`, logs, build output) match the local machine. This is applied per-container at creation time — the timezone is **not** baked into the shared image, because a team may span multiple timezones and every developer should see their own.

On `dce new` and `dce rebuild-container`, the host zone is detected and passed to the container as `--env TZ=<zone>`:

1. If `$TZ` is set in your shell, that value is used (must be a clean IANA name like `America/New_York`).
2. Otherwise the zone is read from `/etc/localtime` (works on macOS and Linux hosts).
3. If neither yields a clean value, `--env TZ` is omitted and the container keeps the image default (UTC).

Override the detected zone for a single command:

```
TZ=Europe/Berlin dce new myapp nodejs 3000:3000
```

For the base image to resolve a named zone, it ships the IANA timezone database (`tzdata`). This installs only the global database — it does **not** select a zone — so it stays timezone-neutral and safe to share across the team. Picking up `tzdata` after an upgrade requires rebuilding the base image:

```
dce rebuild-image base
dce rebuild-container <name>
```

On Docker-compatible backends, `dce new` also writes the detected `TZ` into the generated `.devcontainer/devcontainer.json` (`containerEnv`), so a VS Code "Reopen in Container" build lands on the same timezone as the `dce`-created container.

