# Changelog

All notable changes to the pre-compaction memory kit. Versioning is [SemVer](https://semver.org).
Pre-1.0 (`0.y.z`): the layout, protocol, and tool surface may change between minor versions.

## 0.4.0 — 2026-06-23

Update story for existing consumers: versioned, self-cleaning re-install.

### Added
- `install.sh` records the installed version and the set of hooks it manages in
  `.claude/hooks/.agent-memory-kit.json`, and prints a delta on re-run
  (`installed: … 0.4.0` / `reinstalled: …` / `updated: 0.3.0 -> 0.4.0`).
- Re-install now **prunes** hooks a prior version placed but the current one no
  longer ships, plus their settings.json hook groups (manifest-driven, so only
  kit-managed files are touched — never the user's own hooks/wiring).
- `install.sh --check <project>`: report installed-vs-available version and
  whether an update is due, mutating nothing (does not even create directories).
- README "Updating" section: pull a tag, re-run `install.sh`; `--check` to see
  drift; releases are tagged with CHANGELOG notes.
- `tests/install.test.sh`: version-state stamp + delta, `--check` (installed and
  uninstalled), and prune-on-update (stale hook file + its settings group
  removed, current hooks preserved).

## 0.3.0 — 2026-06-23

Parallel-development support: the memory tiers now have distinct, explicit git
treatment so multiple efforts can work the same project without clobbering.

### Added
- Default-mode install splits the tiers' git treatment: `memory/working-set.md`
  is git-ignored (per-effort, volatile), while `memory/ledger.md` and
  `memory/archive.md` stay committed and shared. `memory/archive.md` is set to a
  `union` merge in `.gitattributes`, so its append-only entries from parallel
  branches merge with no conflict (verified end-to-end). Both edits are
  idempotent; `--local` mode does not add them (all of memory/ stays personal).
- README "Parallel development (worktrees)" section and a MEMORY-MODEL "Sharing
  and parallel efforts" section: one worktree per feature, working-set
  per-effort, ledger/archive shared and merged, git as concurrency control,
  same-directory sessions called out as unsafe.
- Installer detects and *warns* (never auto-mutates git state) when a prior-mode
  or pre-existing state would make its messages untrue: an already-tracked
  `memory/working-set.md` (the ignore line would be inert), shared tiers ignored
  by a leftover `--local` exclude (they would not commit), and shared-mode git
  config left behind when switching to `--local`. The clean happy path stays
  silent.
- `tests/install.test.sh` covers the new git treatment (ignore, union attribute,
  idempotency), that `--local` omits the shared-mode entries, and the three
  conflict-detection warnings (default↔--local switches, pre-tracked working-set).

### Docs
- Clarified that `union` merge keeps both sides *verbatim* (no dedup or semantic
  reconcile), that a fresh worktree's `working-set.md` is created by the hook on
  first fire (not provided by git), and that the installer commits nothing, the
  user must commit `.gitignore`/`.gitattributes`/`ledger.md`/`archive.md` to
  actually share them.

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
