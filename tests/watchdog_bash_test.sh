#!/usr/bin/env bash
# Unit tests for scripts/memory-watchdog.sh
set -uo pipefail
DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$DIR/lib/assert.sh"
. "$DIR/lib/fixtures.sh"

setup(){ new_store; }
teardown(){ cleanup_store; }

# --- preconditions -----------------------------------------------------------

test_refuses_directory_without_git_repo(){
  cleanup_store; new_bare_dir
  run_watchdog
  assert_status 1 "$STATUS"
  assert_contains "$OUTPUT" "no git repo at $MEM"
}

test_defaults_memdir_to_home_dot_adrenaline(){
  local fake_home
  fake_home=$(mktemp -d "${TMPDIR:-/tmp}/adrenaline-home.XXXXXX")
  run_watchdog_with_home "$fake_home"
  assert_status 1 "$STATUS"
  assert_contains "$OUTPUT" "$fake_home/.adrenaline"
  rm -rf "$fake_home"
}

test_logs_to_watchdog_log_in_store(){
  run_watchdog
  assert_status 0 "$STATUS"
  assert_file "$LOG"
  assert_contains "$(cat "$LOG")" "watchdog done" "log file"
}

# --- secret scan -------------------------------------------------------------

test_aborts_on_secret_in_tracked_file(){
  write_file fact.md "token AKIAIOSFODNN7EXAMPLE here"
  commit_all
  run_watchdog
  assert_status 2 "$STATUS"
  assert_contains "$OUTPUT" "SECRET SCAN FAILED"
  assert_contains "$OUTPUT" "abort (secrets present)"
  assert_contains "$OUTPUT" "NOTIFY (no topic set)"
}

test_aborts_on_secret_in_untracked_file(){
  write_file leak.md "ghp_abcdefghijklmnopqrstuvwxyz0123"
  run_watchdog
  assert_status 2 "$STATUS"
  assert_contains "$OUTPUT" "leak.md"
}

test_secret_abort_skips_commit_and_heartbeat(){
  write_file leak.md "AKIAIOSFODNN7EXAMPLE"
  run_watchdog
  assert_status 2 "$STATUS"
  assert_no_file "$HEART" "heartbeat"
  assert_equals "" "$(git -C "$MEM" log --oneline 2>/dev/null)" "commit log"
}

test_clean_store_reports_scan_mode_and_file_count(){
  write_file a.md "plain fact"
  write_file b.md "another fact"
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "secret scan clean (full sweep, 2 files)"
}

test_incremental_scan_only_looks_at_changed_files(){
  write_file old.md "AKIAIOSFODNN7EXAMPLE"
  commit_all
  mark_full_scan_now
  run_watchdog
  # committed-but-unchanged file is out of scope for an incremental scan
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "secret scan clean (incremental, 0 files)"
}

test_incremental_scan_catches_changed_file(){
  write_file fact.md "plain fact"
  commit_all
  mark_full_scan_now
  write_file fact.md "now with sk-abcdefghijklmnopqrstuvwx"
  run_watchdog
  assert_status 2 "$STATUS"
  assert_contains "$OUTPUT" "fact.md"
}

test_full_sweep_when_marker_is_stale(){
  mark_full_scan_days_ago 8
  write_file old.md "plain fact"
  commit_all
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "secret scan clean (full sweep, 1 files)"
}

test_full_sweep_scans_unchanged_tracked_files(){
  mark_full_scan_days_ago 8
  write_file old.md "AKIAIOSFODNN7EXAMPLE"
  commit_all
  run_watchdog
  assert_status 2 "$STATUS"
  assert_contains "$OUTPUT" "old.md"
}

test_full_sweep_when_marker_is_corrupt(){
  printf 'not-a-timestamp\n' > "$FULLMARK"
  write_file old.md "plain fact"
  commit_all
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "full sweep"
}

test_full_sweep_marker_written_only_on_real_runs(){
  run_watchdog --dry
  assert_no_file "$FULLMARK" "full-scan marker after dry run"
  run_watchdog
  assert_file "$FULLMARK" "full-scan marker after real run"
}

test_scan_ignores_watchdog_own_files(){
  write_file .watchdog.notes "AKIAIOSFODNN7EXAMPLE"
  write_file memory-watchdog.sh "AKIAIOSFODNN7EXAMPLE"
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "secret scan clean"
}

test_scan_ignores_git_internals(){
  printf 'AKIAIOSFODNN7EXAMPLE\n' > "$MEM/.git/description"
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "secret scan clean"
}

test_notifies_ntfy_topic_when_configured(){
  # no network in tests: assert we take the curl branch, not the log branch
  NTFY_TOPIC=adrenaline-test
  write_file leak.md "AKIAIOSFODNN7EXAMPLE"
  run_watchdog
  assert_status 2 "$STATUS"
  assert_not_contains "$OUTPUT" "NOTIFY (no topic set)"
}

# --- commit ------------------------------------------------------------------

test_commits_working_tree_changes(){
  write_file fact.md "durable fact"
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "committed"
  assert_not_contains "$(git -C "$MEM" status --porcelain)" "fact.md" "working tree after commit"
  assert_contains "$(git -C "$MEM" log -1 --name-only --pretty='%an <%ae> %s')" "watchdog <watchdog@local> watchdog: memory commit" "commit metadata"
  assert_contains "$(git -C "$MEM" log -1 --name-only --pretty=)" "fact.md" "committed files"
}

test_reports_nothing_to_commit_on_clean_tree(){
  write_file fact.md "durable fact"
  write_file .gitignore ".watchdog.*"
  commit_all
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "nothing to commit"
}

test_dry_run_makes_no_writes(){
  write_file fact.md "durable fact"
  run_watchdog --dry
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "DRYRUN would commit"
  assert_contains "$OUTPUT" "dry=--dry"
  assert_no_file "$HEART" "heartbeat"
  assert_contains "$(git -C "$MEM" status --porcelain)" "fact.md" "working tree after dry run"
}

# --- push --------------------------------------------------------------------

test_skips_push_without_remote(){
  run_watchdog
  assert_contains "$OUTPUT" "no remote configured - local only"
}

test_pushes_to_origin_when_remote_exists(){
  write_file fact.md "durable fact"
  add_remote
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "pushed -> origin"
  assert_equals "$(git -C "$MEM" rev-parse HEAD)" "$(git -C "$REMOTE" rev-parse refs/heads/main)" "pushed commit"
}

test_reports_push_failure_without_aborting(){
  write_file fact.md "durable fact"
  add_broken_remote
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "push FAILED"
  assert_contains "$OUTPUT" "watchdog done"
}

test_dry_run_does_not_push(){
  write_file fact.md "durable fact"
  add_remote
  run_watchdog --dry
  assert_status 0 "$STATUS"
  assert_not_contains "$OUTPUT" "pushed -> origin"
}

# --- consistency + backlog ---------------------------------------------------

test_counts_facts_excluding_index_files(){
  write_file fact-one.md "a"
  write_file fact-two.md "b"
  write_file MEMORY.md "- [fact-one]"
  write_file _UNCERTAIN.md "- [maybe]"
  write_file README.md "docs"
  write_file _INDEX.md "- [fact-one]
- [fact-two]"
  run_watchdog
  assert_contains "$OUTPUT" "facts=2 index(_INDEX.md)=2"
}

test_uses_memory_md_as_index_when_no_index_file(){
  write_file fact-one.md "a"
  write_file MEMORY.md "- [fact-one](fact-one.md)
not an entry"
  run_watchdog
  assert_contains "$OUTPUT" "facts=1 index(MEMORY.md)=1"
}

test_reports_zero_index_entries_when_index_missing(){
  run_watchdog
  assert_status 0 "$STATUS"
  assert_contains "$OUTPUT" "facts=0 index(MEMORY.md)=0"
}

test_reports_hot_index_size(){
  write_file MEMORY.md "- [fact](fact.md)"
  run_watchdog
  assert_contains "$OUTPUT" "hot MEMORY.md = 0KB"
}

test_warns_when_hot_index_nears_cap(){
  # >16KB of index entries
  awk 'BEGIN{ for(i=0;i<400;i++) print "- [fact-" i "](fact-" i ".md) padding padding padding" }' > "$MEM/MEMORY.md"
  run_watchdog
  assert_contains "$OUTPUT" "MEMORY.md near cap"
  assert_contains "$OUTPUT" "split cold entries into _INDEX.md"
}

test_no_cap_warning_for_small_hot_index(){
  write_file MEMORY.md "- [fact](fact.md)"
  run_watchdog
  assert_not_contains "$OUTPUT" "near cap"
}

test_warns_on_uncertain_backlog_of_three_or_more(){
  write_file _UNCERTAIN.md "- [guess one]
- [guess two]
- [guess three]"
  run_watchdog
  assert_contains "$OUTPUT" "uncertain backlog"
  assert_contains "$OUTPUT" "3 inferred facts to triage"
}

test_no_warning_for_small_uncertain_backlog(){
  write_file _UNCERTAIN.md "- [guess one]
- [guess two]"
  run_watchdog
  assert_not_contains "$OUTPUT" "uncertain backlog"
}

# --- heartbeat ---------------------------------------------------------------

test_writes_heartbeat_on_real_run(){
  run_watchdog
  assert_file "$HEART"
  assert_contains "$(cat "$HEART")" "$(date '+%Y-%m-%d')" "heartbeat timestamp"
}

run_tests
