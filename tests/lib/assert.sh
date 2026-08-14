#!/usr/bin/env bash
# Minimal zero-dependency test harness (bash 3.2+).
#
# A test file sources this plus fixtures.sh, defines `test_*` functions and
# optional `setup` / `teardown` hooks, then calls `run_tests`. Each test runs in
# its own subshell, so a failing assertion aborts only that test.

setup(){ :; }
teardown(){ :; }

fail(){ printf '    %s\n' "$*"; exit 1; }

assert_status(){ # expected actual [label]
  [ "$1" = "$2" ] || fail "${3:-exit status}: expected $1, got $2"
}

assert_contains(){ # haystack needle [label]
  case "$1" in
    *"$2"*) ;;
    *) fail "${3:-output} does not contain '$2'
--- actual ---
$1
--------------";;
  esac
}

assert_not_contains(){ # haystack needle [label]
  case "$1" in
    *"$2"*) fail "${3:-output} unexpectedly contains '$2'
--- actual ---
$1
--------------";;
  esac
}

assert_equals(){ # expected actual [label]
  [ "$1" = "$2" ] || fail "${3:-value}: expected '$1', got '$2'"
}

assert_file(){ # path [label]
  [ -f "$1" ] || fail "${2:-file} missing: $1"
}

assert_no_file(){ # path [label]
  [ ! -e "$1" ] || fail "${2:-file} should not exist: $1"
}

run_tests(){
  local suite names name rc passed=0 failed=0
  suite=$(basename "$0")
  names=$(grep -oE '^test_[A-Za-z0-9_]+' "$0")
  printf '%s\n' "== $suite"
  for name in $names; do
    (
      trap teardown EXIT
      setup
      "$name"
    )
    rc=$?
    if [ "$rc" -eq 0 ]; then
      passed=$((passed + 1)); printf '  ok   %s\n' "$name"
    else
      failed=$((failed + 1)); printf '  FAIL %s\n' "$name"
    fi
  done
  printf '   %s passed, %s failed\n\n' "$passed" "$failed"
  [ "$failed" -eq 0 ]
}
