# tests

Unit tests for the watchdog — the only executable code in the plugin. No test
framework, no network: just `bash` + `git`.

```
bash tests/run.sh                          # everything
bash tests/watchdog_bash_test.sh           # one suite
```

Each test gets a throwaway git-backed memory store (`ADRENALINE_HOME` points at a
`mktemp -d`) and runs `scripts/memory-watchdog.sh` against it, asserting on the
log output, exit status, and the resulting git/filesystem state.

- `watchdog_bash_test.sh` — behaviour of every stage: preconditions, scan mode
  selection (incremental vs weekly full sweep), commit, push, consistency
  counters, cap/backlog warnings, heartbeat, and `--dry` no-write guarantees.
- `secret_patterns_test.sh` — one test per credential shape the gate must
  refuse, near-miss cases it must accept, and parity between the bash and
  PowerShell pattern lists.
- `lib/assert.sh`, `lib/fixtures.sh` — harness (`run_tests`, assertions) and
  store fixtures.

Writing a test: add a `test_*` function to a `*_test.sh` file; `setup` builds a
fresh store, `teardown` removes it, and each test runs in its own subshell so a
failed assertion aborts only that test.
