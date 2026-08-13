---
description: Prepare a clean session exit — extract durable learnings into the adrenaline memory store, reconcile/commit, and report.
---

End-of-session ritual for the adrenaline memory system (spec: the plugin's `UNIFIED-SYSTEM.md`). Store dir: `echo "${ADRENALINE_HOME:-$HOME/.adrenaline}"`.

## 1. Extract learnings — YOU do it, from the session you just had
The consolidator subagent runs BLIND (it cannot see this conversation), so on a normal session it captures nothing or hallucinates. So **YOU, the parent — who actually had this session — do the distillation directly:**

- **Judge first:** did this session produce a durable learning — a preference/correction, a decision + rationale, a non-obvious fact not derivable from code/git, or a reusable pattern? Pure Q&A or trivial edits → nothing to capture; go to step 2.
- For each real learning, apply the rules yourself:
  - ripgrep the store for the nearest existing fact; UPDATE-in-place or supersede-append (old text under `## Superseded (date)`, never a duplicate, never a silent delete);
  - **then SWEEP: grep the store for the superseded claim's keywords and reconcile EVERY sibling — 0 stale hits, or flag them;**
  - poisoning gate: only source-backed facts promote; your inferences go to `_UNCERTAIN.md`;
  - secret-reject: never write a credential value (redact);
  - full schema; keep the index in sync - one-line pointer into `_INDEX.md` (FULL index) always, into `MEMORY.md` (small HOT injected index) ONLY for behavioral rules or active work (keep it lean; watchdog alerts >16KB).
- Only delegate to the `memory-consolidator` subagent for a large isolated sweep, and hand it the candidate learnings + file targets — it can't discover them itself.

## 2. Reconcile + checkpoint
Run the watchdog to secret-scan, commit, and push (if a remote exists):
```
# Windows:  pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/memory-watchdog.ps1"
# macOS/Linux:  bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-watchdog.sh"
```
If it reports a secret, drift, or push failure, surface it — don't bury it.

## 3. Report (outcome-first, terse)
What was written/updated, superseded, parked in `_UNCERTAIN.md`, and the commit hash. Keep it lazy: if nothing durable happened, just checkpoint and say so in one line.
