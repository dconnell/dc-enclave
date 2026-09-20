# Map custom hostnames inside a container

A hostname you alias in your **host** `/etc/hosts` — a corporate registry, an internal service, a VM on your LAN — does not automatically resolve inside containers. `/etc/hosts` is per-machine, and container runtimes regenerate the container's copy at every start from their own state; host-only aliases are not part of it. (OrbStack follows the macOS resolver and usually picks host aliases up; apple/container, Docker, Colima, and Podman do not.)

dce gives each project its own hosts fragment and reconciles it into that container's `/etc/hosts` as root:

```
~/.config/dce-enclave/<project>/hosts
```

## The file

`dce new` scaffolds a comment-only template (a scaffold, not a secret — it is not overwritten on re-create). Fill in entries in hosts(5) format, one per line:

```
10.0.0.5   internal.corp registry.internal
```

- Full-line comments (`#`) and blank lines are ignored; a trailing `# comment` on an entry line is fine.
- A line without at least an IP and a hostname is skipped with a warning — it never reaches the container.
- CRLF line endings are tolerated.
- The file is per-project: it only affects this project's containers.
- No file means no-op — projects created before this feature behave exactly as before.

To remove entries, empty the file (or comment the lines out); the next entry point drops the whole managed block. Deleting the file instead leaves whatever the container already has until its next restart.

## When it applies

Every command that creates, starts, or attaches you to a container reconciles the fragment first:

- `dce new` — first boot
- `dce start` (and `dce restart`, which goes through it) — after the runtime has regenerated `/etc/hosts`
- `dce shell` and `dce editor` — also when entering an already-running container
- `dce install` — after dotfiles install
- `dce rebuild-container` — alongside credential injection
- `dce snapshot` — after the container restarts at the end of the commit

`dce exec` does **not** reconcile: it is meant for scripted/agent one-shots where per-call latency matters, and the entries are already in place from the commands above.

Reconciliation is best-effort by design: if it fails, dce prints a warning and the shell/editor/start proceeds anyway — a hosts hiccup never blocks container entry.

## Why reconcile, not append once

Because runtimes regenerate `/etc/hosts` at every container start, an entry appended once would vanish on the next restart. dce instead maintains a managed block inside the file, delimited by:

```
# >>> dce-enclave hosts (managed) >>>
10.0.0.5   internal.corp registry.internal
# <<< dce-enclave hosts (managed) <<<
```

At each entry point the block is stripped and rewritten from the current fragment. Two consequences:

- Edits on the host converge into the container on the next `dce shell` / `dce editor` (both reconcile on entry) or `dce restart`; `dce start` reconciles only when it actually starts the container — on an already-running one it no-ops.
- Manual edits you make inside the container *outside* the block survive reconciliation.

## Precedence

The managed block is appended **last**, and the resolver uses the **first** match for a name. Runtime-managed entries — `localhost`, the container's own hostname — therefore always win. You cannot override them from the fragment; it is for *additional* names.

## Workflow

1. Edit `~/.config/dce-enclave/<project>/hosts` on the host.
2. Land the edits: enter with `dce shell` / `dce editor` (both reconcile on entry), or run `dce restart`. Plain `dce start <project>` only reconciles when it actually starts the container; on an already-running one it no-ops.
3. Verify inside the container:

```
dce exec <project> getent hosts internal.corp
```

## Many hostnames? Use DCE_DNS instead

A hosts fragment does not scale to dozens of internal hostnames and goes stale when addresses change. For that case, point the container at your corporate resolvers instead with the `DCE_DNS` env var — set at create time only (`dce new` / `dce rebuild-container`). See [flags](../reference/flags.md) and [backends](../reference/backends.md).

## See also

- [Troubleshooting: hostname doesn't resolve inside my container](../troubleshooting.md#hostname-doesnt-resolve-inside-my-container)
- [Backends: container DNS](../reference/backends.md) — apple/container's resolver and the `DCE_DNS` override.
