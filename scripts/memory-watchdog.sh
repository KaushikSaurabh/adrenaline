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
#          ADRENALINE_NTFY_TOKEN (optional ntfy access token)
# Schedule it via cron (Linux) or launchd (macOS). Add to cron with e.g.:
#   @reboot bash /path/to/memory-watchdog.sh   (or an hourly entry)

set -uo pipefail
MEMDIR="${ADRENALINE_HOME:-$HOME/.adrenaline}"
NTFY="${ADRENALINE_NTFY_TOPIC:-}"
NTFY_TOKEN="${ADRENALINE_NTFY_TOKEN:-}"
DRY="${1:-}"
LOG="$MEMDIR/.watchdog.log"
HEART="$MEMDIR/.watchdog.heartbeat"
FULLMARK="$MEMDIR/.watchdog.lastfullscan"

log(){ printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" | tee -a "$LOG"; }
notify(){
  if [ -z "$NTFY" ]; then log "NOTIFY (no topic set): $1 - $2"; return; fi
  # ntfy topics are unauthenticated by default: anyone who knows the topic can read
  # it, so notifications carry file names only, never file contents.
  case "$NTFY" in
    *[!A-Za-z0-9_-]*|'') log "NOTIFY (invalid ADRENALINE_NTFY_TOPIC, refusing to call ntfy): $1 - $2"; return;;
  esac
  if [ -n "$NTFY_TOKEN" ]; then
    curl -s --proto '=https' --max-time 10 -H "Authorization: Bearer $NTFY_TOKEN" -H "Title: $1" -H "Priority: high" --data-binary "$2" "https://ntfy.sh/$NTFY" >/dev/null 2>&1 || true
  else
    curl -s --proto '=https' --max-time 10 -H "Title: $1" -H "Priority: high" --data-binary "$2" "https://ntfy.sh/$NTFY" >/dev/null 2>&1 || true
  fi
}

[ -d "$MEMDIR/.git" ] || { echo "adrenaline: no git repo at $MEMDIR (run: git -C \"$MEMDIR\" init)"; exit 1; }
cd "$MEMDIR" || exit 1
umask 077   # log/heartbeat/marker may name memory files - keep them owner-only
log "=== watchdog start (dry=${DRY:-no}) ==="

PATTERNS='github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|glpat-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}|(sk|rk)_(live|test)_[0-9A-Za-z]{16,}|A(KIA|SIA)[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|GOCSPX-[0-9A-Za-z_-]{20,}|xox[baprse]-[A-Za-z0-9-]{10,}|xapp-[0-9]-[A-Za-z0-9-]{10,}|npm_[A-Za-z0-9]{36}|hf_[A-Za-z0-9]{30,}|dop_v1_[a-f0-9]{64}|SG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{10,}[.][A-Za-z0-9_-]{6,}|[Aa]uthorization: *(Bearer|Basic) +[A-Za-z0-9._~+/=-]{16,}|-----BEGIN [A-Z ]*PRIVATE KEY-----'

# --- 1. secret scan: incremental every run, full sweep at most weekly ---
fulldue=1
if [ -f "$FULLMARK" ]; then
  last=$(cat "$FULLMARK" 2>/dev/null || echo 0); now=$(date +%s)
  case "$last" in ''|*[!0-9]*) last=0;; esac
  [ "$last" -le "$now" ] || last=0                      # future-dated marker must not skip the sweep
  [ $(( (now - last) / 86400 )) -ge 7 ] || fulldue=0
fi
# NUL-delimited + core.quotePath=false + -uall: paths with spaces/quotes/non-ASCII
# bytes stay verbatim and untracked directories are expanded to their files, so no
# file that `git add -A` is about to commit can slip past the scan unseen.
scanlist(){
  if [ "$fulldue" = 1 ]; then
    git -c core.quotePath=false ls-files -z
    git -c core.quotePath=false ls-files -z --others --exclude-standard
  else
    git -c core.quotePath=false status --porcelain -z -uall | while IFS= read -r -d '' entry; do
      case "${entry:0:2}" in R*|C*) IFS= read -r -d '' _orig || true;; esac   # rename/copy: consume the source path
      printf '%s\0' "${entry:3}"
    done
  fi
}
if [ "$fulldue" = 1 ]; then mode="full sweep"; else mode="incremental"; fi
hits=""; count=0
while IFS= read -r -d '' f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  case "$f" in
    .git/*|*/.git/*) continue;;
    .watchdog.*|*/.watchdog.*) continue;;
    memory-watchdog.sh|memory-watchdog.ps1|*/memory-watchdog.sh|*/memory-watchdog.ps1) continue;;
  esac
  count=$((count + 1))
  if grep -Eq "$PATTERNS" "$f" 2>/dev/null; then hits="$hits $f"; fi
done < <(scanlist)
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
idx=$(grep -cE '^[[:space:]]*-[[:space:]]*\[' "$idxfile" 2>/dev/null || echo 0)
log "facts=$facts index($idxfile)=$idx"
# MEMORY.md is the HOT injected index - guard its size (auto-memory cap ~25KB)
if [ -f MEMORY.md ]; then memkb=$(( $(wc -c < MEMORY.md) / 1024 )); log "hot MEMORY.md = ${memkb}KB"; [ "$memkb" -gt 16 ] && notify "adrenaline: MEMORY.md near cap" "hot index ${memkb}KB (cap ~25KB) - split cold entries into _INDEX.md"; fi
unc=$(grep -cE '^[[:space:]]*-[[:space:]]*\[' _UNCERTAIN.md 2>/dev/null || echo 0)
[ "$unc" -ge 3 ] && notify "adrenaline: uncertain backlog" "$unc inferred facts to triage"

# --- 5. heartbeat ---
[ "$DRY" != "--dry" ] && date '+%Y-%m-%dT%H:%M:%S%z' > "$HEART"
log "=== watchdog done ==="
