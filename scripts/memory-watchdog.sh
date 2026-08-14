#!/usr/bin/env bash
# adrenaline memory watchdog (cross-platform: bash 3.2+, macOS/Linux/Git-Bash).
#
# PURE git / filesystem / notify. It never runs `claude` (headless `claude -p`
# hangs on Windows Git-Bash). Consolidation is in-session (the memory-consolidator
# subagent / the /wrap command). This only reconciles what's on disk:
#   secret-scan (incremental every run, full sweep <= weekly) -> commit -> push ->
#   consistency-check -> heartbeat -> notify-on-issue.
#
# Usage:   bash memory-watchdog.sh            # real run
#          bash memory-watchdog.sh --dry       # no writes
# Env:     ADRENALINE_HOME (default ~/.adrenaline), ADRENALINE_NTFY_TOPIC (optional)
# Schedule it via cron (Linux) or launchd (macOS). Add to cron with e.g.:
#   @reboot bash /path/to/memory-watchdog.sh   (or an hourly entry)
#
# Exit codes (the scheduler should surface anything non-zero):
#   0 clean   1 bad usage/setup   2 secret detected (fail closed)
#   3 scan could not complete (fail closed)   4 ran but degraded (commit/push failed)

set -uo pipefail
MEMDIR="${ADRENALINE_HOME:-$HOME/.adrenaline}"
NTFY="${ADRENALINE_NTFY_TOPIC:-}"
DRY="${1:-}"
LOG="$MEMDIR/.watchdog.log"
HEART="$MEMDIR/.watchdog.heartbeat"
FULLMARK="$MEMDIR/.watchdog.lastfullscan"
STATUS=0   # 0 clean, 4 degraded

log(){
  line="$(date '+%Y-%m-%d %H:%M:%S')  $1"
  printf '%s\n' "$line"
  printf '%s\n' "$line" >> "$LOG" 2>/dev/null \
    || printf '%s  WARN log not writable: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$LOG"
}
notify(){
  if [ -n "$NTFY" ]; then
    if ! curl -sS -H "Title: $1" -H "Priority: high" -d "$2" "https://ntfy.sh/$NTFY" >/dev/null 2>"$TMPERR"; then
      log "ntfy delivery FAILED ($1): $(tr '\n' ' ' < "$TMPERR" 2>/dev/null)"
      STATUS=4
    fi
  else log "NOTIFY (no topic set): $1 - $2"; fi
}
# degrade: the run continues but the exit code reports it.
degrade(){ log "$1"; notify "adrenaline: $2" "$1"; STATUS=4; }
# abort: we cannot vouch for the store - never commit/push in that state.
abort(){ log "$1"; notify "adrenaline: $2" "$1"; log "=== abort ($2) ==="; exit "$3"; }

case "$DRY" in
  ''|--dry) ;;
  *) echo "adrenaline: unknown argument '$DRY' (usage: memory-watchdog.sh [--dry])" >&2; exit 1;;
esac

[ -d "$MEMDIR/.git" ] || { echo "adrenaline: no git repo at $MEMDIR (run: git -C \"$MEMDIR\" init)" >&2; exit 1; }
cd "$MEMDIR" || { echo "adrenaline: cannot cd into $MEMDIR" >&2; exit 1; }

TMPERR="$(mktemp "${TMPDIR:-/tmp}/adrenaline-watchdog.XXXXXX")" \
  || { echo "adrenaline: cannot create temp file" >&2; exit 1; }
trap 'rm -f "$TMPERR"' EXIT HUP INT TERM

# git wrapper: stdout in $git_out, stderr in $git_err, exit status returned.
git_out=""; git_err=""
git_try(){
  git_out="$(git "$@" 2>"$TMPERR")"; rc=$?
  git_err="$(tr '\n' ' ' < "$TMPERR" 2>/dev/null)"
  return $rc
}

log "=== watchdog start (dry=${DRY:-no}) ==="

PATTERNS='github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|sk_(live|test)_[0-9A-Za-z]{16,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|GOCSPX-[0-9A-Za-z_-]{20,}|xox[baprse]-[A-Za-z0-9-]{10,}|xapp-[0-9]-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{6,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# --- 1. secret scan: incremental every run, full sweep at most weekly ---
# A scan that cannot enumerate or read its files is NOT a clean scan: it aborts
# (exit 3) rather than letting an unverified store reach a commit or a push.
fulldue=1
if [ -f "$FULLMARK" ]; then
  last=$(cat "$FULLMARK" 2>/dev/null || echo 0); now=$(date +%s)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $(( (now - last) / 86400 )) -ge 7 ] || fulldue=0
fi
if [ "$fulldue" = 1 ]; then
  git_try ls-files || abort "cannot enumerate tracked files: git ls-files failed: $git_err" "scan failed" 3
  filelist="$git_out"
  git_try ls-files --others --exclude-standard || abort "cannot enumerate untracked files: git ls-files failed: $git_err" "scan failed" 3
  filelist="$filelist
$git_out"
  mode="full sweep"
else
  git_try status --porcelain || abort "cannot enumerate changed files: git status failed: $git_err" "scan failed" 3
  filelist=$(printf '%s\n' "$git_out" | sed -e 's/^...//' -e 's/.* -> //' -e 's/"//g')
  mode="incremental"
fi
hits=""; unreadable=""; count=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  case "$f" in .git/*|*.watchdog.*|.watchdog.*|*memory-watchdog.*) continue;; esac
  count=$((count + 1))
  grep -Eq "$PATTERNS" "$f" 2>"$TMPERR"; rc=$?
  case $rc in
    0) hits="$hits $f";;
    1) ;;
    *) unreadable="$unreadable $f";;   # grep >=2 means it could not read the file
  esac
done <<EOF
$filelist
EOF
if [ -n "$hits" ]; then
  abort "SECRET SCAN FAILED - refusing to commit/push:$hits" "SECRET DETECTED" 2
fi
if [ -n "$unreadable" ]; then
  abort "secret scan INCOMPLETE - unreadable files, refusing to commit/push:$unreadable" "scan failed" 3
fi
log "secret scan clean ($mode, $count files)"
if [ "$fulldue" = 1 ] && [ "$DRY" != "--dry" ]; then
  date +%s > "$FULLMARK" 2>/dev/null || degrade "cannot write full-scan marker $FULLMARK" "watchdog write failed"
fi

# --- 2. commit (one serialized committer) ---
committed=1
if git_try status --porcelain; then
  if [ -z "$git_out" ]; then
    log "nothing to commit"
  elif [ "$DRY" = "--dry" ]; then
    log "DRYRUN would commit"
  elif ! git_try add -A; then
    degrade "git add FAILED: $git_err" "commit failed"; committed=0
  elif git_try -c user.name=watchdog -c user.email=watchdog@local commit -q -m "watchdog: memory commit $(date '+%Y-%m-%d %H:%M')"; then
    log "committed"
  else
    degrade "git commit FAILED: $git_err" "commit failed"; committed=0
  fi
else
  degrade "git status FAILED: $git_err" "commit failed"; committed=0
fi

# --- 3. push (fast-forward, never force) if a remote exists ---
if ! git_try remote; then
  degrade "git remote FAILED: $git_err" "push failed"
elif [ -z "$git_out" ]; then
  log "no remote configured - local only"
elif [ "$DRY" = "--dry" ]; then
  log "DRYRUN would push"
elif [ "$committed" = 0 ]; then
  log "skipping push - the commit step failed, HEAD is not the store's current state"
elif git_try push -q origin HEAD; then
  log "pushed -> origin"
else
  degrade "push FAILED: $git_err" "push failed"
fi

# --- 4. consistency + backlog (reminders, not blocking) ---
# grep -c prints 0 and exits 1 on no match, so a bare `|| echo 0` would yield
# "0\n0" and break the later numeric tests: swallow only the exit status.
count_entries(){
  [ -f "$1" ] || { printf '0\n'; return; }
  grep -cE '^[[:space:]]*-[[:space:]]*\[' "$1" 2>/dev/null || true
}
if facts=$(find . -maxdepth 1 -name '*.md' ! -name 'MEMORY.md' ! -name '_UNCERTAIN.md' ! -name 'README.md' ! -name '_INDEX.md' 2>"$TMPERR" | wc -l | tr -d ' '); then
  idxfile=MEMORY.md; [ -f _INDEX.md ] && idxfile=_INDEX.md   # _INDEX = full index when the hot/full split is in use
  [ -f "$idxfile" ] || log "WARN index $idxfile is missing"
  log "facts=$facts index($idxfile)=$(count_entries "$idxfile")"
else
  degrade "cannot count fact files: $(tr '\n' ' ' < "$TMPERR" 2>/dev/null)" "consistency check failed"
fi
# MEMORY.md is the HOT injected index - guard its size (auto-memory cap ~25KB)
if [ -f MEMORY.md ]; then
  if membytes=$(wc -c < MEMORY.md 2>"$TMPERR"); then
    memkb=$(( membytes / 1024 )); log "hot MEMORY.md = ${memkb}KB"
    [ "$memkb" -gt 16 ] && notify "adrenaline: MEMORY.md near cap" "hot index ${memkb}KB (cap ~25KB) - split cold entries into _INDEX.md"
  else
    degrade "cannot size MEMORY.md: $(tr '\n' ' ' < "$TMPERR" 2>/dev/null)" "consistency check failed"
  fi
fi
unc=$(count_entries _UNCERTAIN.md)
[ "$unc" -ge 3 ] && notify "adrenaline: uncertain backlog" "$unc inferred facts to triage"

# --- 5. heartbeat (records the run's verdict, so a degraded run isn't read as healthy) ---
if [ "$DRY" != "--dry" ]; then
  verdict=ok; [ "$STATUS" = 0 ] || verdict=degraded
  printf '%s status=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$verdict" > "$HEART" 2>/dev/null \
    || { log "cannot write heartbeat $HEART"; STATUS=4; }
fi
log "=== watchdog done (status=$STATUS) ==="
exit "$STATUS"
