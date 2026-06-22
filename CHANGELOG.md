# Changelog

All notable changes to the pre-compaction memory kit. Versioning is [SemVer](https://semver.org).
Pre-1.0 (`0.y.z`): the layout, protocol, and tool surface may change between minor versions.

## 0.1.0 — 2026-06-20

First tagged version. The mechanical layer is execution-verified on Linux; the
semantic layer has a baseline eval suite (see `evals/BASELINE.md`).

### Tiers and gates
- Three-tier memory: working-set (volatile), ledger (consolidated), archive
  (append-only, immutable). Promote / demote / recall as the three gates.
- `checkpoint.sh`: structural auto block, idempotent replace, forced on PreCompact.
- `recall.sh`: flat-file output gate (no-indexer fallback), comment-aware.
- `memory-metrics.sh`: forget-gate pressure signal; honors `LEDGER_SOFT_MAX`.

### Forget-gate enforcement (added after dogfooding found prose insufficient)
- `mem gc-scan`: lists ledger entries whose file Refs no longer exist.
- `mem demote <id>`: append-only move ledger → archive; the only sanctioned
  archive write path.
- `guard-archive.sh`: PreToolUse guard blocking direct edits to `archive.md`
  (fail-open on malformed input).
- Protocol: mandatory recall when the working-set hypothesis flags uncertainty.

### Known limitations
- Not yet run inside a live Claude Code session firing real PreCompact/Stop/
  SessionEnd events; event semantics are from docs.
- macOS support is statically reviewed, not executed (see README portability note).
- Recall reliability is improved but not guaranteed (judgment-driven); see
  `evals/BASELINE.md`.
