# Reach a service on the host from inside a container

Servers running on your host — a local API, a dev server, a browser's remote-debugging port — usually listen on `127.0.0.1` only, so they are invisible from a container's network. Every dce container, on every backend, has one name for your host that makes them reachable:

```
host.docker.internal
```

Use it like any other hostname, with whatever port the service listens on. It covers **all ports at once** — there is no per-port mapping to configure — and it works on already-running containers: the name is (re-)applied at every dce entry point (see [backends](../reference/backends.md) for the full list) and survives restarts.

One caveat up front: docker on plain Linux/WSL2 without Docker Desktop, and rootless podman on Linux, cannot reach host *loopback-only* listeners this way — that is a runtime limitation, not a dce setting (see [backends: reaching the host](../reference/backends.md#reaching-the-host-from-a-container) for the details).

## The recipe

From inside the container:

```
curl http://host.docker.internal:<port>/
```

Where the name comes from per backend — docker/orbstack/colima provide it natively; podman provides `host.containers.internal`, which dce aliases to `host.docker.internal` at create so one name works everywhere; apple/container via dce's host integration. Details: [backends](../reference/backends.md).

## Worked example: Chrome's remote debugging port

Run Chrome on your host with remote debugging enabled (it listens on `127.0.0.1` only):

```
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=61519
```

Then from inside any dce container:

```
curl http://host.docker.internal:61519/json
```

**apple backend:** the same recipe works, but only after the one-time host-global bootstrap (`sudo container system dns create host.container.internal --localhost 203.0.113.113`). If you haven't run it yet, `dce new` and `dce doctor` will tell you — see [backends: host integration](../reference/backends.md).

## Gotcha: Chrome rejects non-localhost `Host` headers

Chrome's DevTools HTTP endpoint applies DNS-rebinding protection: it rejects requests whose `Host` header is neither `localhost` nor a raw IP, and `host.docker.internal` is neither. If a CDP client fails against the name, switch to the raw IP of the same path:

- **apple backend** — the synthetic IP is fixed: `curl http://203.0.113.113:61519/json`
- **docker-family backends** (docker/orbstack/colima, podman) — resolve the name, then use the address it returned:

```
dce exec <project> getent hosts host.docker.internal
# → e.g. 192.168.215.2 host.docker.internal
curl http://192.168.215.2:61519/json
```

Other services without this Host-header check work fine over the name itself.

## See also

- [Connect to host PostgreSQL](connect-host-postgres.md) — the same name, applied to a database connection string.
- [Backends: host integration](../reference/backends.md) — the apple/bootstrap details and per-backend name origins.
- [Troubleshooting: hostname doesn't resolve inside my container](../troubleshooting.md#hostname-doesnt-resolve-inside-my-container) — for custom (non-host) names.
