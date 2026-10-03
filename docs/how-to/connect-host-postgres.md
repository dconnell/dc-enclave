# Connect to host PostgreSQL

You do not need SSH tunneling for normal local development. A normal connection string is enough.

For docker/orbstack/colima backends, use `host.docker.internal` as host:

```
postgresql://<user>:<password>@host.docker.internal:5432/<db>
```

For podman backend, use `host.containers.internal`:

```
postgresql://<user>:<password>@host.containers.internal:5432/<db>
```

Note: `dce new` configures podman containers with `host.docker.internal` as an alias, so either hostname works with podman.

The apple backend works too, via the same `host.docker.internal` name as the docker family:

```
postgresql://<user>:<password>@host.docker.internal:5432/<db>
```

One prerequisite: apple/container's one-time host integration bootstrap must have been run on the host (`dce new` and `dce doctor` will tell you if it hasn't) — see [backends: host integration](../reference/backends.md). The general recipe, with a worked example and a known DevTools gotcha, is in [reach a service on the host](reach-host-services.md).

For this to work, your PostgreSQL instance must allow it:

- listen on an address reachable from the container runtime
- allow container network clients in pg_hba.conf
- keep auth strict (password/scram), and avoid opening broad CIDRs unnecessarily

If you install PostgreSQL client in your overlay Containerfile, verify with:

```
dce shell <name> "psql --version"
```

