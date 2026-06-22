# Ledger

<!--
Long-term memory (LSTM cell state). Consolidated, not narrated. Keep it SMALL:
promote only facts that pass the input gate ("would a cold-start agent decide
worse without this?"), and demote stale entries to memory/archive.md.

Entry format (the recall tooling splits on lines starting with "### "):

### <id> · <kind> · <YYYY-MM-DD> · <status>
**Claim:** one sentence, the durable fact.
**Why:** the rationale a cold reader needs.
**Refs:** file:line, issue id, or other entries [[<id>]].

kind   ∈ decision | dead-end | invariant | open-question
status ∈ active | superseded:<id>

Demotion (forget gate): when an entry is superseded, refers to code that no
longer exists, or has gone unreferenced across several consolidations, MOVE the
whole block to memory/archive.md. Do not delete it. The archive is searchable.
-->

## Decisions

## Invariants

## Open questions

## Abandoned approaches
