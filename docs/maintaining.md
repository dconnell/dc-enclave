# Running the test suite

The suite is split into a fast **unit** suite (stubbed runtimes, deterministic)
and a real-backend **integration** suite. They are invoked separately so the
fast suite stays safe to run anywhere, anytime.

## Unit suite (fast, stubbed)

Runs every contract/unit test in `tests/unit/` with a single pass/fail summary
(no fail-fast, so you see every failure in one run):

```
tests/unit/run-all.sh
tests/unit/run-all.sh -v   # stream each file's output live
```

`tests/run-all.sh` is a thin compatibility wrapper around the unit suite, kept
for one release so existing invocations keep working:

```
tests/run-all.sh            # -> tests/unit/run-all.sh
```

The unit suite includes `tests/unit/shellcheck.sh`, a static-analysis pass over
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

Optional backend override (unit + smoke):

```
CONTAINER_BACKEND=podman tests/unit/run-all.sh
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
