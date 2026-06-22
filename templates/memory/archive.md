# Archive

<!--
Cold store (output-gated). Demoted ledger entries land here, in the same
"### <id> · ..." format. CURATED facts, not the raw session transcript. This
file may grow without bound: it is NEVER loaded wholesale. Reach it only by
scoped query:

  - recall.sh "<terms>"  greps this file, returns whole entries. Always works.
  - If an indexer is present, this file is also reachable by semantic search.

The raw session transcript (every turn verbatim) is a SEPARATE, deeper fallback,
reachable via the indexer (search_turns) when present. It is not managed here;
consult it only when this curated archive lacks a needed detail.

Nothing here is auto-loaded into context, so it needs no GC.

IMMUTABLE RECORD. Append on demotion only. Never edit, correct, or prune an
existing entry: a correction is a NEW entry that supersedes an old one by id
(status superseded:<id>). This file is the untainted history of what was
believed and when — the substrate any future learning loop trains on. Tampering
with it destroys that signal. Unbounded growth is intended and affordable: it is
never loaded wholesale.
-->
