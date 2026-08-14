---
name: adrenaline
description: Explains and operates the adrenaline markdown+git memory system - when to consult memory, how to capture durable learnings, the integrity guards (supersede-sweep, poisoning gate, secret-reject), and the watchdog. Use when the user asks how adrenaline works, how to set it up, or how to operate it.
---

# adrenaline memory system

adrenaline is a memory for Claude Code that is **just markdown files in a git repo** —
no vector database, no server, no daemon. Facts are human-named, greppable, diffable,
and yours. What makes it more than a folder of notes is its **integrity layer**.

## Store layout
- `${ADRENALINE_HOME:-~/.adrenaline}/` — one fact per markdown file (human-named slug).
- `MEMORY.md` — the small HOT index, injected each session (identity + behavioral rules + active work; kept lean, watchdog alerts past ~16KB).
- `_INDEX.md` — the FULL index (not injected); the retriever greps it + the fact files. New facts go into `_INDEX.md` always, `MEMORY.md` only if behavioral/active.
- `_UNCERTAIN.md` — holding pen for unconfirmed inferences (the poisoning gate).

## The three tiers
- **Front:** the live session.
- **Middle (broker):** the `memory-retriever` subagent (reads: `ripgrep`, returns raw
  matched lines — never summaries, so no fact is dropped) and the `memory-consolidator`
  (writes: recall-first capture). The `/wrap` command runs the session-exit ritual.
- **Backend:** the durable markdown store, git-synced.

## Consult-first
Before a non-trivial task, ground in prior facts. The hot index (`MEMORY.md`) is
pre-loaded, so act on it directly when it covers the task; only invoke the retriever
when the needed value is ABSENT from the index. Don't spawn a retriever to re-fetch
what's already in context.

## Capture (run `/wrap` at session end)
The parent session (which saw the conversation) distills durable learnings itself:
1. Keep only a preference/correction, a decision + rationale, a non-obvious fact, or a
   reusable pattern. Drop work-log noise.
2. Dedup: update-in-place or supersede-append (old text under `## Superseded (date)`,
   never a duplicate, never a silent delete).
3. **Sweep:** after superseding a claim, grep the store for its keywords and reconcile
   every sibling — the store must never contradict itself.
4. **Poisoning gate:** only source-backed facts promote; inferences go to `_UNCERTAIN.md`.
5. **Secret-reject:** never write a credential value.
Then the watchdog secret-scans, commits, and pushes.

## The watchdog
`scripts/memory-watchdog.{ps1,sh}` — scheduled, pure git/fs/notify (never runs
`claude`). Secret-scan is incremental every run, full sweep at most weekly, driven by
the shared `scripts/secret-patterns.txt` (both platforms; override with
`ADRENALINE_SECRET_PATTERNS`) — no patterns, no run. Commits,
pushes to a remote (offsite backup), checks consistency, alerts via ntfy on real
issues (secret / push-fail), and treats the uncertain backlog as a reminder, not an
alarm.

## Setup checklist
1. `mkdir -p ~/.adrenaline && git -C ~/.adrenaline init` (or set `ADRENALINE_HOME`).
2. Add a git remote (a **private** repo — the store holds your facts) for offsite backup.
3. Optional: `ADRENALINE_NTFY_TOPIC` for phone alerts.
4. Schedule the watchdog (`-ShowArm` on Windows; cron/launchd on macOS/Linux).

## Design rationale (why these choices)
- Markdown+git = maximal interoperability, human-browsable, no lock-in; `ripgrep`
  beats vector search at a solo operator's scale.
- Supersede-append + sweep = the store can *forget and correct*, not just accumulate.
- Poisoning gate = one bad inference can't silently poison every future session.
- Watchdog never calls `claude` = avoids the Windows headless-hang; consolidation
  stays in-session where the context actually is.
