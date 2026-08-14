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
# Env:     ADRENALINE_HOME (default ~/.adrenaline), ADRENALINE_NTFY_TOPIC (optional),
#          ADRENALINE_SECRET_PATTERNS (default ./secret-patterns.txt, shared with the ps1)
# Schedule it via cron (Linux) or launchd (macOS). Add to cron with e.g.:
#   @reboot bash /path/to/memory-watchdog.sh   (or an hourly entry)

set -uo pipefail
SCRIPTDIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
MEMDIR="${ADRENALINE_HOME:-$HOME/.adrenaline}"
NTFY="${ADRENALINE_NTFY_TOPIC:-}"
DRY="${1:-}"
LOG="$MEMDIR/.watchdog.log"
HEART="$MEMDIR/.watchdog.heartbeat"
FULLMARK="$MEMDIR/.watchdog.lastfullscan"
PATFILE="${ADRENALINE_SECRET_PATTERNS:-$SCRIPTDIR/secret-patterns.txt}"

log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG"; }
notify(){
  if [ -n "$NTFY" ]; then curl -s -H "Title: $1" -H "Priority: high" -d "$2" "https://ntfy.sh/$NTFY" >/dev/null 2>&1 || true
  else log "NOTIFY (no topic set): $1 - $2"; fi
}
# shared secret-reject patterns, joined into one ERE alternation
secret_pattern(){ grep -Ev '^[[:space:]]*(#|$)' "$PATFILE" | tr -d '\r' | paste -sd '|' -; }
# a file the scanner should read: exists, and is not git internals or watchdog's own files
scannable(){
  case "$1" in .git/*|*/.git/*|*.watchdog.*|.watchdog.*|*memory-watchdog.*|*secret-patterns.txt) return 1;; esac
  [ -f "$1" ]
}
# index/backlog pointers are markdown list links: '- [slug](...)'
count_pointers(){ grep -cE '^[[:space:]]*-[[:space:]]*\[' "$1" 2>/dev/null || echo 0; }

[ -d "$MEMDIR/.git" ] || { echo "adrenaline: no git repo at $MEMDIR (run: git -C \"$MEMDIR\" init)"; exit 1; }
cd "$MEMDIR" || exit 1
log "=== watchdog start (dry=${DRY:-no}) ==="

[ -f "$PATFILE" ] || { log "no secret-pattern file at $PATFILE"; notify "adrenaline: watchdog misconfigured" "missing secret patterns: $PATFILE"; log "=== abort (cannot secret-scan) ==="; exit 3; }
PATTERNS=$(secret_pattern)
[ -n "$PATTERNS" ] || { log "secret-pattern file $PATFILE is empty"; notify "adrenaline: watchdog misconfigured" "empty secret patterns: $PATFILE"; log "=== abort (cannot secret-scan) ==="; exit 3; }

# --- 1. secret scan: incremental every run, full sweep at most weekly ---
fulldue=1
if [ -f "$FULLMARK" ]; then
  last=$(cat "$FULLMARK" 2>/dev/null || echo 0); now=$(date +%s)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ $(( (now - last) / 86400 )) -ge 7 ] || fulldue=0
fi
if [ "$fulldue" = 1 ]; then
  filelist=$( { git ls-files; git ls-files --others --exclude-standard; } )
  mode="full sweep"
else
  filelist=$(git status --porcelain | sed -e 's/^...//' -e 's/.* -> //' -e 's/"//g')
  mode="incremental"
fi
hits=""; count=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  scannable "$f" || continue
  count=$((count + 1))
  if grep -Eq "$PATTERNS" "$f" 2>/dev/null; then hits="$hits $f"; fi
done <<EOF
$filelist
EOF
if [ -n "$hits" ]; then
  log "SECRET SCAN FAILED - refusing to commit/push:$hits"
  notify "adrenaline: SECRET DETECTED" "refusing to commit:$hits"
  log "=== abort (secrets present) ==="; exit 2
fi
log "secret scan clean ($mode, $count files)"
[ "$fulldue" = 1 ] && [ "$DRY" != "--dry" ] && date +%s > "$FULLMARK"

# --- 2. commit (one serialized committer) ---
if [ -n "$(git status --porcelain)" ]; then
  if [ "$DRY" = "--dry" ]; then log "DRYRUN would commit"; else
    git add -A
    git -c user.name=watchdog -c user.email=watchdog@local commit -q -m "watchdog: memory commit $(date '+%Y-%m-%d %H:%M')" && log "committed"
  fi
else log "nothing to commit"; fi

# --- 3. push (fast-forward, never force) if a remote exists ---
if git remote | grep -q .; then
  if [ "$DRY" != "--dry" ]; then
    if git push -q origin HEAD 2>/dev/null; then log "pushed -> origin"; else log "push FAILED"; notify "adrenaline: push failed" "origin push failed"; fi
  fi
else log "no remote configured - local only"; fi

# --- 4. consistency + backlog (reminders, not blocking) ---
facts=$(find . -maxdepth 1 -name '*.md' ! -name 'MEMORY.md' ! -name '_UNCERTAIN.md' ! -name 'README.md' ! -name '_INDEX.md' 2>/dev/null | wc -l | tr -d ' ')
idxfile=MEMORY.md; [ -f _INDEX.md ] && idxfile=_INDEX.md   # _INDEX = full index when the hot/full split is in use
idx=$(count_pointers "$idxfile")
log "facts=$facts index($idxfile)=$idx"
# MEMORY.md is the HOT injected index - guard its size (auto-memory cap ~25KB)
if [ -f MEMORY.md ]; then memkb=$(( $(wc -c < MEMORY.md) / 1024 )); log "hot MEMORY.md = ${memkb}KB"; [ "$memkb" -gt 16 ] && notify "adrenaline: MEMORY.md near cap" "hot index ${memkb}KB (cap ~25KB) - split cold entries into _INDEX.md"; fi
unc=$(count_pointers _UNCERTAIN.md)
[ "$unc" -ge 3 ] && notify "adrenaline: uncertain backlog" "$unc inferred facts to triage"

# --- 5. heartbeat ---
[ "$DRY" != "--dry" ] && date '+%Y-%m-%dT%H:%M:%S%z' > "$HEART"
log "=== watchdog done ==="
