# Connect containers with private networks

## Private networks between containers

By default dce containers are isolated: they cannot reach each other. To let two
containers talk (e.g. an app and its database) **without publishing any port to
the host**, create a private network and attach both containers to it on purpose:

```
dce network create myapp
dce new myapp-db  --network myapp
dce new myapp-web --network myapp
# myapp-web can now reach myapp-db by name; no -p port publishing required
```

Linking is explicit — a container is only reachable from peers that share one of
its networks. Containers created without `--network` are not dce-linked to anyone.

### Addressing (peer names)

Containers on the same network resolve each other by **project name**:

- docker / orbstack / colima / podman: the bare name, e.g. `myapp-db`
- apple/container: `<name>.test`, e.g. `myapp-db.test` (requires macOS 26+)

So inside `myapp-web`, point your app at the hostname `myapp-db` (docker) or
`myapp-db.test` (apple/container).

### Static IPs (optional)

Names are usually all you need. For apps that hardcode an address, pin a static
IPv4 on the primary network:

```
dce new myapp-db --network myapp --ip 10.0.0.10
# or equivalently: --network myapp:10.0.0.10
```

Static IPs are supported on Docker-compatible backends only (not apple/container).

### Managing networks

```
dce network ls                       # list networks + their dce members
dce network members myapp            # which projects are on a network
dce network add myapp myapp-web --ip 10.0.0.20   # attach an existing container
dce network remove myapp myapp-web   # detach a container
dce network rm myapp                 # remove (refuses while members exist)
```

`dce network add`/`remove` keep the project config in sync, so the membership
survives `dce rebuild-container`. On apple/container, attach networks at
`dce new` time (live add/remove and static IPs are not supported, and a container
may join a single network).

### Security note

Putting containers on a shared network widens their east-west reach — but only
to the projects explicitly placed on that same network, and only over the network
(no shared filesystem, PID, or IPC namespace). For the local single-user dev
model this is strictly safer than the alternative of publishing dev databases on
the host.
