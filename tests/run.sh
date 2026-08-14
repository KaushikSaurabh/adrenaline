#!/usr/bin/env bash
# Runs every tests/*_test.sh suite (or just the ones named on the command line).
# Requires only bash + git.
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

suites=("$@")
if [ ${#suites[@]} -eq 0 ]; then suites=("$DIR"/*_test.sh); fi

failed=0
for suite in "${suites[@]}"; do
  bash "$suite" || failed=$((failed + 1))
done

if [ "$failed" -gt 0 ]; then
  printf '%s suite(s) failed\n' "$failed"
  exit 1
fi
printf 'all suites passed\n'
