# adrenaline

A lean **markdown + git** memory system for Claude Code. Durable facts with real
integrity guards, `ripgrep` retrieval, and a self-checkpointing watchdog. No vector
database, no server, no daemon, no lock-in — just files you own.

## Why another memory plugin?

Most agent-memory tools (vector DBs, knowledge graphs) are heavy and, at a solo
operator's scale, over-engineered. And most *append* — they never forget, so they
rot into polite contradictions. adrenaline is different on two axes:

- **It's just files.** One fact per human-named markdown file + a one-line index.
  Readable in any editor, greppable, diffable, versioned by git. Retrieval is
  `ripgrep` (models are good at file search; a plain filesystem beat vector memory
  in Letta's 2026 benchmark at this scale).
- **It has integrity guards most memory tools lack:**
  - **supersede-sweep** — a corrected fact is superseded in place AND every sibling
    that repeats the old claim is reconciled, so the store never contradicts itself.
  - **poisoning gate** — only *source-backed* facts become durable; the model's own
    inferences wait in a holding pen (`_UNCERTAIN.md`) for human confirmation.
  - **secret-reject** — credential shapes are refused before they can be committed
    or pushed (the watchdog re-scans on every commit).

## How it works (three tiers)

- **Front** — the live session + an ephemeral scratch.
- **Middle** — two subagents: a **retriever** (`ripgrep`, returns raw lines not
  summaries) and a **consolidator** (recall-first capture at session end), plus the
  **`/wrap`** command that runs the end-of-session ritual.
- **Backend** — the durable markdown store, git-synced, human-browsable.

A **watchdog** (scheduled) reconciles: secret-scan (incremental every run, full
sweep at most weekly) → commit → push → consistency check → heartbeat → notify on
issues. It never runs `claude` (headless `claude -p` hangs on Windows Git-Bash).

Full design: [`UNIFIED-SYSTEM.md`](./UNIFIED-SYSTEM.md). Learn interactively via the
bundled **`adrenaline`** skill.

## Install

```
/plugin marketplace add KaushikSaurabh/adrenaline
/plugin install adrenaline
```

## Configure

- **`ADRENALINE_HOME`** — your memory store directory (default `~/.adrenaline`).
  Create + init it once: `mkdir -p ~/.adrenaline && git -C ~/.adrenaline init`.
- **`ADRENALINE_NTFY_TOPIC`** — optional [ntfy](https://ntfy.sh) topic for watchdog
  phone alerts. An ntfy.sh topic is a shared secret at best: anyone who knows the
  name can subscribe, so alerts carry file names only, never file contents. Use an
  unguessable topic (`[A-Za-z0-9_-]` only; other characters are refused).
- **`ADRENALINE_NTFY_TOKEN`** — optional ntfy access token, sent as a bearer token so
  a protected topic can be used instead of a public one.

## Use

- Facts accrue as you work. Run **`/wrap`** at session end to capture durable
  learnings and checkpoint.
- The `memory-retriever` subagent grounds tasks in prior facts; the
  `memory-consolidator` writes them (recall-first, deduped, scoped, secret-safe).
- Schedule the watchdog to auto-checkpoint and back up to a git remote:
  - Windows: `scripts/memory-watchdog.ps1` (`-ShowArm` prints the scheduled-task command)
  - macOS/Linux: `scripts/memory-watchdog.sh` (add to cron/launchd)

## Fact schema

```yaml
---
name: <kebab-slug>
description: <one line, used for recall>
metadata:
  type: user | feedback | project | reference
  kind: fact | decision | preference | lesson | runbook | context
  status: active | superseded | rejected
  scope: global | <group> | <group>/<item>
  source: <where it came from>
  updated: YYYY-MM-DD
  supersedes: [<slug>, ...]
  volatile: false
---
```

Supersede by appending old text under `## Superseded (date)` — never silent-delete.

## Platforms

Watchdog ships for Windows (`memory-watchdog.ps1`) and macOS/Linux
(`memory-watchdog.sh`, bash 3.2+). Tested on Windows + Git-Bash; macOS unverified.

## License

MIT © Saurabh Kaushik
