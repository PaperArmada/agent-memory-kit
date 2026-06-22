# Changelog

All notable changes to the pre-compaction memory kit. Versioning is [SemVer](https://semver.org).
Pre-1.0 (`0.y.z`): the layout, protocol, and tool surface may change between minor versions.

## 0.2.0 — 2026-06-23

Installer now does the mechanical wiring instead of printing it as manual steps.

### Added
- `install.sh` auto-wires the hooks into `<project>/.claude/settings.json` by
  idempotent deep-merge: never clobbers existing settings, never duplicates a
  hook (dedupe by event + matcher + command set). Re-running is a no-op.
- `install.sh --local`: personal install for a shared repo. Writes the protocol
  to `CLAUDE.local.md` (auto-loaded local override) with the status command
  pre-filled, and adds the tooling paths to the repo's *local* git exclude
  (`.git/info/exclude`) instead of the committed `.gitignore`. Worktree-safe:
  resolves the exclude via `git rev-parse --git-path` since `.git` is a file,
  not a dir, in a worktree.
- Installer verifies the write path itself (fires the hook, confirms the auto
  block landed) instead of leaving it as a manual check.
- `tests/install.test.sh`: mechanical regression test for the merge, no-clobber,
  dedupe, idempotency, `--local` artifacts, and worktree exclude resolution.

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
