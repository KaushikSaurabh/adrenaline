# adrenaline — design

A memory for Claude Code built on one idea: **plain markdown in a git repo is the
most interoperable, durable, lock-in-free substrate there is.** Everything else is a
thin layer over files you own. This document is the design; the runnable pieces are
the agents, the `/wrap` command, and the watchdog.

Governing laws:
1. **One owner per fact.** A fact lives in exactly one human-named file; others link.
2. **The store must forget.** Facts supersede (append old under a heading, never silent-delete).
3. **Load nothing until the task needs it.**
4. **Automation fails loud, never silent.**
5. **Consult memory first.**

## Three tiers

| Tier | What | Temperature |
|------|------|-------------|
| **Front** | live session + ephemeral scratch | hot |
| **Middle (broker)** | `memory-retriever` (in) + `memory-consolidator` (out) subagents; `/wrap` command | warm |
| **Backend** | durable owner-per-fact markdown, git-synced | cold |

Store dir = `${ADRENALINE_HOME:-~/.adrenaline}`. `MEMORY.md` is the small HOT index (injected each session, kept lean) and `_INDEX.md` is the FULL index (not injected, retriever greps it);
`_UNCERTAIN.md` is the inference holding pen.

## Fact schema

```yaml
---
name: <kebab-slug>
description: <one line, for recall>
metadata:
  type: user | feedback | project | reference
  kind: fact | decision | preference | lesson | runbook | context
  status: active | superseded | rejected      # retriever shows only active
  scope: global | <group> | <group>/<item>    # prevents cross-scope leakage
  source: <provenance: a user utterance or a file>
  updated: YYYY-MM-DD
  supersedes: [<slug>, ...]
  volatile: false                              # true + ttl for perishable state
---
```

**Supersede by appending**, not deleting: move the old text under a
`## Superseded (YYYY-MM-DD)` heading and write the new version above. Keeps the
rationale and audit trail; git already timestamps it.

## Capture (`/wrap` at session end)

The **parent session** (which actually saw the conversation) distills — the
consolidator subagent runs blind, so it's only delegated to with explicit candidates.
Two passes, recall-first: over-capture, then prune to the four keepers (preference/
correction, decision + rationale, non-obvious fact, reusable pattern); drop work-log
noise. Then, per keeper:

- **Semantic dedup:** find the nearest existing fact; update-in-place or supersede.
- **Sweep:** after superseding a claim, grep the whole store for its keywords and
  reconcile every sibling — 0 stale hits, so the store never contradicts itself.
- **Poisoning gate:** only source-backed facts promote on first sight; the model's own
  inferences go to `_UNCERTAIN.md` and wait for human confirmation.
- **Secret-reject:** never write a credential value.

## Retrieval — ripgrep, no index

`ripgrep` over the markdown: no vector DB, no rebuild, no staleness. At a solo
operator's scale (hundreds of small files) it's sub-10ms and always current, and
models are post-trained for file search (a filesystem beat vector memory in Letta's
2026 benchmark). The **retriever subagent** returns raw matched lines + paths, never a
summary, so it can't silently drop the fact you needed. The hot index (`MEMORY.md`) is
your first consult; the retriever fires only when the needed value is absent from it.
FTS5/vectors are measure-first additions if grep ever gets noisy — not a default.

## Sync & integrity — git is truth

- **One serialized committer** (the watchdog); parallel writers don't each commit.
- **Push fast-forward-only, never `--force`.** Conflicts abort + alert, never
  auto-merge into markdown.
- **Secret-scan** on every commit (incremental every run, full sweep at most weekly).
  The incremental pass covers exactly what `git add -A` is about to commit — NUL-delimited
  paths, `core.quotePath=false`, untracked directories expanded (`-uall`) — so a file can
  never be committed unscanned because its name or its parent directory was unparseable.
- **Backup = a git remote** (use a *private* repo — the store holds your facts).

## Reliability — the watchdog

A scheduled reconciler, pure git/filesystem/notify. It **never runs `claude`**
(headless `claude -p` hangs on Windows Git-Bash), so consolidation stays in-session.
It secret-scans, commits, pushes, checks consistency (facts vs index), heartbeats, and
alerts via ntfy only on actionable events (secret / push-fail); the uncertain backlog
is a reminder, not an alarm.

## Rejected on purpose
- **Vector DB / knowledge graph** — heavy, lock-in, and over-engineered at this scale;
  grep wins. Add a hybrid layer only if measured need appears.
- **A memory daemon / stateful server** — a fourth moving part; files + a scheduled
  script suffice.
- **Blind subagent consolidation** — it can't see the session; the parent distills.
- **Append-only capture** — rots into contradictions; supersede + sweep instead.
