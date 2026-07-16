# Running the test suite

The suite is split into three **fast** tiers (deterministic, no real daemon) and
a real-backend **integration** tier. They are invoked separately so the fast
suite stays safe to run anywhere, anytime.

| Tier | Directory | What it covers |
|------|-----------|----------------|
| unit | `tests/unit/` | Pure host-side helper unit tests — `lib/*.sh` functions exercised in-process, no backend, no subprocess. |
| contract | `tests/contract/` | Stubbed-backend functional / contract tests — the real `dce` CLI driven through fakes of docker/container/podman across multi-step workflows. `tests/integration/` is what validates that the backend contract assumed here is actually correct. |
| lint | `tests/lint/` | Static analysis / policy guards — shellcheck plus supply-chain and convention greps over committed sources. |
| integration | `tests/integration/` | Real-backend end-to-end (see below). |

## Fast suite (unit + contract + lint)

`tests/run-all.sh` is the aggregator: it runs the three fast tiers in turn with
a per-tier pass/fail summary (no fail-fast, so you see every failure in one run):

```
tests/run-all.sh                 # all three fast tiers
tests/run-all.sh -v              # verbose: stream each file's output live
tests/run-all.sh contract        # a single tier: unit | contract | lint
```

Each tier also has its own discovery runner (`tests/<tier>/run-all.sh`) for
running it in isolation, e.g. `tests/unit/run-all.sh` or `tests/contract/run-all.sh`.

The lint tier includes `tests/lint/shellcheck.sh`, a static-analysis pass over
every Bash script in the repo. ShellCheck is optional at runtime: when
installed, any finding fails the suite; when absent, the run still passes but
prints one `WARN:` line per script (surfaced under the `-> PASS:` line) with the
install link. Install it to silence the warnings and enable the checks:

```
brew install shellcheck        # macOS
apt install shellcheck         # Debian/Ubuntu
dnf install shellcheck         # Fedora
# https://github.com/koalaman/shellcheck
```

`tests/smoke.sh` is the lightweight command smoke suite. Help, version, and
security-guard checks always run; `dce list`, `dce status`, and `dce clean`
checks run when a backend is reachable and are otherwise skipped:

```
tests/smoke.sh
```

Optional backend override (matters for the contract tier and smoke):

```
CONTAINER_BACKEND=podman tests/contract/run-all.sh
CONTAINER_BACKEND=colima tests/smoke.sh
```


## Integration suite (real backends, end-to-end)

`tests/integration/run-all.sh` exercises the full `dce` command surface against
the **real** container runtime(s) detected on the host — no stubs. It creates
real projects (collision-proof names under an isolated `DC_REPOS_DIR`), runs
every command and documented flag, then removes every created project via
`dce rm` and verifies zero leftovers. It is **never** run from the unit suite.

### Prerequisites

- Bash 4+.
- At least one supported backend CLI on PATH (apple/container, Docker,
  OrbStack, Colima, or Podman), reachable (engine running).
- `dce-base:latest` present per backend (the suite rebuilds it automatically if
  missing).
- Must run on the **host**, not inside a container (it needs host runtime
  access; the suite fails fast if it detects `/.dockerenv`).

### Run

```
# all detected backends, full mode (default)
tests/integration/run-all.sh

# preview detected/selected backends + planned cases, with NO side effects
tests/integration/run-all.sh --list

# narrow to specific backends
INTEGRATION_BACKENDS="docker,podman" tests/integration/run-all.sh

# fast sanity: command-surface + install only (one real project per backend)
INTEGRATION_MODE=smoke tests/integration/run-all.sh

# keep temp workspace + logs for debugging (also auto-retained on failure/leak)
INTEGRATION_KEEP_ARTIFACTS=1 tests/integration/run-all.sh
```

### What it covers

Per selected backend: `dce new → start/stop/restart → status/list → shell/exec
→ snapshot (create/list/restore/rm) → rebuild-container (incl. --rotate-keys /
--from-snap) → config (get/set/show/sync-vscode) → provenance → clean →
network (where supported) → rebuild-image base → install`, plus the full
documented **flag matrix** (independent flags, pairwise combos, and backend-
specific expected failures) driven by `tests/integration/matrix/flags.tsv`.

### Output

The run **leads with the backends detected and selected**, then prints each
case's PASS/FAIL, and ends with a **per-backend summary** (passed / failed /
skipped / total). Exit code is non-zero if any case failed or the leak check
found leftover resources. Every `dce` command + exit code is logged to
`tests/integration/artifacts/<runid>/<backend>/<case>.log` (retained on failure
or leak, otherwise cleaned up).

### Coverage guard

`tests/integration/cases/flag-coverage.sh` parses `docs/reference/flags.md` and
fails if any documented long flag is not represented in the matrix
(`matrix/flags.tsv`) or a hand-written case (`cases/*.sh`). Run it standalone:

```
bash tests/integration/cases/flag-coverage.sh
```

(`--save-team` / `--save-user` are deferred to a follow-up that adds
`DCE_CONFIG_ROOT` isolation, so the suite can exercise them without writing into
your real team/user config roots.)

## Emergency cleanup

Every integration run cleans up after itself and a `trap` replays removal even
on interrupt. If a run is killed hard (e.g. `kill -9`) and leaves test
resources behind, the leak check prints exact remediation commands. To sweep
manually, substitute your run id (visible in the run header) and backend:

```
# remove test projects for a run (find them first):
CONTAINER_BACKEND=<backend> scripts/dce list | grep '^test-<backend>-<runid>-'
CONTAINER_BACKEND=<backend> scripts/dce rm '<test-project>' --yes

# drop test networks:
docker network ls | grep 'testnet-<backend>-<runid>-'
docker network rm '<testnet-name>'   # or: container network delete '<name>' (apple)

# reclaim leftover snapshots / hidden volumes for a project:
CONTAINER_BACKEND=<backend> scripts/dce clean --snapshots '<test-project>'
CONTAINER_BACKEND=<backend> scripts/dce clean --hidden-volumes '<test-project>'

# remove orphaned temp workspace + artifacts:
rm -rf /tmp/dce-integration/<runid>
rm -rf tests/integration/artifacts/<runid>
```

### Managed volume families (for anyone extending `dce clean`)

dce manages three named-volume families, each visually grouped with its project
and excluded from the others' sweeps by prefix:

- `dce-hide-<slug>-<12hex>` — hidden volumes (`--hide`)
- `dce-snapvol-<slug>-<label>-<12hex>` — snapshot volumes
- `dce-sync-<slug>-<12hex>` — synced-workspace volume (`--sync`)

`dce clean --hidden-volumes` scopes to the `dce-hide-` prefix and `--snapshots`
to `dce-snapvol-*`; **neither ever touches `dce-sync-*`** (a synced project's
volume is reclaimed only by `dce rm`, which first terminates the Mutagen
session). If you add a new sweep or relax a prefix, preserve this exclusion — a
contract test (`tests/contract/sync-lifecycle.sh`) asserts the sync volume is
not swept by snapshot/hidden-volume cleanup.
