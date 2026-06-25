# Running the test suite


Run every test file in `tests/` with a single pass/fail summary (no fail-fast, so you see every failure in one run):

```
tests/run-all.sh
tests/run-all.sh -v   # stream each file's output live
```

The suite includes `tests/shellcheck.sh`, a static-analysis pass over every Bash
script in the repo. ShellCheck is optional at runtime: when installed, any
finding fails the suite; when absent, the run still passes but prints one
`WARN:` line per script (surfaced under the `-> PASS:` line) with the install
link. Install it to silence the warnings and enable the checks:

```
brew install shellcheck        # macOS
# https://github.com/koalaman/shellcheck
```

`tests/smoke.sh` is the lightweight command smoke suite. Help, version, and security-guard checks always run; `dce list`, `dce status`, and `dce clean` checks run when a backend is reachable and are otherwise skipped:

```
tests/smoke.sh
```

Optional backend override:

```
CONTAINER_BACKEND=podman tests/run-all.sh
CONTAINER_BACKEND=colima tests/smoke.sh
```

