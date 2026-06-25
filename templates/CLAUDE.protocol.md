<!--
  Paste this section into your project's CLAUDE.md. It is the agent-facing half
  of the tiered memory system (see MEMORY-MODEL.md for the design). The hook
  keeps the structural envelope fresh; this protocol governs the semantic
  content, which only the agent can write or read. Edit the bracketed parts.
-->

## Memory Protocol (MANDATORY)

Three memory files complement the lossy compaction summary. Maintain them as a
continuous discipline, not a chore at session end.

- your **working set** — what you're doing *right now*. Overwrite in place. It is
  **per-session**: get your file with `WS=$(.claude/hooks/mem ws-path)` and write
  to `$WS`. Two concurrent sessions in one checkout get separate files, so they
  never overwrite each other.
- `memory/ledger.md` — durable decisions, dead-ends, invariants, open questions.
- `memory/archive.md` (or the indexer) — cold store of demoted entries.

### On resume (session start AND after every compaction)

Before any work:

1. Run the status command and read it: `[your status command]`.
2. Read the most recent working set: `cat "$(.claude/hooks/mem ws-latest)"`. The
   **Checkpoint (auto)** block is the last machine-written position (time, git,
   memory pressure); the **Now** section is the last live state. Trust these over
   the summary if they disagree. (`ws-latest` may be a prior effort's file; write
   your own with `mem ws-path`.)
3. Skim `memory/ledger.md` for decisions and abandoned approaches relevant to the
   task. Do not reopen a dead-end recorded there. If the Now hypothesis flags any
   uncertainty about a choice, that is a recall trigger (see Recall below): query
   the archive before acting on it.
4. Reconcile against the live repo (`git status`, `git diff`) if the auto block
   says there are uncommitted changes.

Do not start work until this is done.

### While working (this is what bounds crash loss)

- After each meaningful step, **overwrite** your working set (`$WS` from
  `mem ws-path`) → Now: task, live hypothesis, next step, blockers. Cheap and
  frequent. A mechanical failure
  (crashed tool, dropped network) loses only what happened since the last write,
  so write often.
- When a decision crystallizes or you abandon an approach, **promote** it to
  `memory/ledger.md` in the entry format documented there. Input-gate test:
  *would a cold-start agent decide worse without this?* If no, leave it in the
  working set to be overwritten.

### Garbage collection (forget gate)

When the auto block reports ledger pressure (entry count over the soft max), run
a forget-gate pass:

1. Run `.claude/hooks/mem gc-scan`. It lists demote candidates by mechanical
   test: file Refs gone, status marked `superseded`, or stale (no live code
   anchor, older than the staleness window, and cross-linked by nothing).
   Invariants and active open-questions are never nominated — they are protected.
2. For each candidate (plus any entry you judge no longer load-bearing), demote
   it: `.claude/hooks/mem demote <id>`. That moves the entry to
   `memory/archive.md`, appended verbatim, and drops it from the ledger.

**Never edit `memory/archive.md` by hand** — it is an append-only, immutable
record, and a hook blocks direct writes to it. `mem demote` is the only way to
add to it. To correct a fact, append a *new* ledger entry that supersedes the old
one by id; leave the archived original exactly as written. The judgment of *what*
to demote stays yours; the stale-Ref scan and the immutable move are the tool's.

### Recall (output gate)

**Recall is mandatory when you are uncertain.** Before making any implementation
choice that the **Now** section's Live hypothesis flags as uncertain or undecided
(phrases like "unsure which", "need to decide", "not sure how to"), you MUST run
recall on that topic *before* acting. The archive often holds a prior,
non-obvious decision that overrides the generic default; skipping recall is how
you silently re-make a settled mistake. Do not fall back to the obvious default
until recall has returned nothing.

To recover a specific lost detail, query the curated archive; never load it
wholesale.

- `.claude/hooks/recall.sh "<terms>"` returns whole matching entries from
  `memory/archive.md` and the ledger. Always available.
- If the auto-indexer is present, the same archive is also reachable by semantic
  search.

If even the curated archive lacks the detail, and an indexer is present, fall
back to the raw session transcript (`search_turns(...)`) as a last resort. That
transcript is the verbatim record, not part of this kit's managed memory.

### What the hook does and does not do

`.claude/hooks/checkpoint.sh` rewrites only the **Checkpoint (auto)** block, on
each meaningful event and forced right before compaction. It captures structure,
never semantics: it cannot write your hypothesis or consolidate your ledger.
Those are yours. The hook guarantees the envelope is current; you guarantee the
content is.
