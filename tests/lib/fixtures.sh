#!/usr/bin/env bash
# Fixtures for the watchdog tests: throwaway memory stores and script runners.

ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}
WATCHDOG_SH="$ROOT/scripts/memory-watchdog.sh"
WATCHDOG_PS1="$ROOT/scripts/memory-watchdog.ps1"

# A store the watchdog accepts: a directory that is a git repo.
new_store(){
  MEM=$(mktemp -d "${TMPDIR:-/tmp}/adrenaline-test.XXXXXX")
  git -C "$MEM" init -q
  git -C "$MEM" symbolic-ref HEAD refs/heads/main
  LOG="$MEM/.watchdog.log"
  HEART="$MEM/.watchdog.heartbeat"
  FULLMARK="$MEM/.watchdog.lastfullscan"
}

# A directory that is NOT a git repo.
new_bare_dir(){
  MEM=$(mktemp -d "${TMPDIR:-/tmp}/adrenaline-test.XXXXXX")
}

cleanup_store(){
  [ -n "${MEM:-}" ] && [ -d "$MEM" ] && rm -rf "$MEM"
  [ -n "${REMOTE:-}" ] && [ -d "$REMOTE" ] && rm -rf "$REMOTE"
  return 0
}

write_file(){ # relpath content
  mkdir -p "$(dirname "$MEM/$1")"
  printf '%s\n' "$2" > "$MEM/$1"
}

commit_all(){ # message
  git -C "$MEM" add -A
  git -C "$MEM" -c user.name=test -c user.email=test@local commit -q -m "${1:-fixture}"
}

add_remote(){ # creates a pushable bare remote named origin
  REMOTE=$(mktemp -d "${TMPDIR:-/tmp}/adrenaline-remote.XXXXXX")
  git init -q --bare "$REMOTE"
  git -C "$MEM" remote add origin "$REMOTE"
}

add_broken_remote(){
  git -C "$MEM" remote add origin "$MEM/does-not-exist.git"
}

# Marks the weekly full sweep as just done, so the next run is incremental.
mark_full_scan_now(){ date +%s > "$FULLMARK"; }

# Marks the weekly full sweep as `$1` days old.
mark_full_scan_days_ago(){ echo $(( $(date +%s) - $1 * 86400 )) > "$FULLMARK"; }

# Runs the watchdog against $MEM. Sets OUTPUT (stdout+stderr) and STATUS.
run_watchdog(){
  OUTPUT=$(ADRENALINE_HOME="$MEM" ADRENALINE_NTFY_TOPIC="${NTFY_TOPIC:-}" \
    bash "$WATCHDOG_SH" "$@" 2>&1)
  STATUS=$?
  return 0
}

# Runs the watchdog with ADRENALINE_HOME unset and HOME pointed at $1.
run_watchdog_with_home(){ # fakehome [args...]
  local home=$1; shift
  OUTPUT=$(env -u ADRENALINE_HOME HOME="$home" ADRENALINE_NTFY_TOPIC="${NTFY_TOPIC:-}" \
    bash "$WATCHDOG_SH" "$@" 2>&1)
  STATUS=$?
  return 0
}
