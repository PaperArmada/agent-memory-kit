# Changelog

All notable changes to the pre-compaction memory kit. Versioning is [SemVer](https://semver.org).
Pre-1.0 (`0.y.z`): the layout, protocol, and tool surface may change between minor versions.

## 0.8.0 — 2026-06-27

Robustness fix: a session's memory no longer splits when the session is launched
from a directory whose git root differs from where the agent actually works
(most sharply, a non-git container holding several git sub-repos).

### Fixed
- A Claude Code session is anchored to its launch directory, and the checkpoint
  hook resolves from there, but the agent may `cd` into a sub-repo to work, so
  its `mem ws-path` resolves to a different root. The two writers then diverged:
  the agent wrote its narrative ("Now") to the sub-repo's working set while the
  hook wrote empty, branch-`-` auto-checkpoints to the launch dir, and the
  PreCompact snapshot landed in the empty file. The hook cannot see the agent's
  transient working directory, so `mem` now records the git root it organically
  resolves as a per-session breadcrumb (under `XDG_CACHE_HOME`, keyed by session
  id), and the hook follows it (`mem ws-dir`) before resolving. Both writers land
  in the same working-set file, and the hook's checkpoint reports the sub-repo's
  real branch/sha instead of `-`. The breadcrumb is recorded only for override-
  free git resolutions, so the hook's own call cannot poison it; the common
  single-repo case is unchanged (breadcrumb equals launch dir). Known behavior:
  a session that works across multiple sub-repos leaves its checkpoints following
  the most-recently-resolved one; and two sessions whose ids share the first
  8 hex chars (already collided on working-set filename) now also share a
  breadcrumb, so one may follow the other's work dir (≈1-in-4-billion).

### Added
- `mem ws-dir` prints the work tree the session last resolved (empty if none);
  `mem ws-gc` also prunes stale session breadcrumbs by `WS_TTL_DAYS`.
- `tests/mem.test.sh`: breadcrumb recording (organic git only), override non-
  poisoning, non-git fallback records nothing, stale-breadcrumb is ignored, and
  ws-gc breadcrumb pruning. `tests/robustness.sh`: a container-launch-split
  scenario, verified to flip UNSAFE without the hook's breadcrumb follow.

## 0.7.0 — 2026-06-27

Robustness fix: per-project hook wiring is now resilient to the working directory
Claude Code runs a hook from.

### Fixed
- Per-project installs wired hooks with a bare relative path
  (`.claude/hooks/checkpoint.sh`). Claude Code does not guarantee a hook runs from
  the project root, and `CLAUDE_PROJECT_DIR` is not reliably set, so a hook fired
  from another directory (e.g. `$HOME`) failed with
  `checkpoint.sh: not found` and silently skipped the checkpoint. Installs now
  wire `cd "${CLAUDE_PROJECT_DIR:-<project>}" && …`, which resolves the hook from
  the project root regardless of the runtime cwd and keeps memory anchored to that
  project. Re-running the installer **migrates** older relative wiring in place
  (removes the stale group, adds the robust one) instead of leaving a duplicate
  that fires from the wrong directory. A user's own (non-kit) hooks are untouched.
  (`--global` already wired absolute paths and is unaffected.)

### Added
- `tests/install.test.sh`: migration + cwd-robustness coverage — old relative
  wiring is replaced not duplicated, the wired command succeeds when run from an
  unrelated directory, and unrelated user hooks survive a re-install.

## 0.6.0 — 2026-06-25

Global install: leverage the kit across every project automatically, with no
per-project setup, while keeping memory local.

### Added
- `install.sh --global` installs the hooks into `~/.claude/hooks`, wires them
  into `~/.claude/settings.json` with absolute command paths (idempotent
  deep-merge), writes the memory protocol into `~/.claude/CLAUDE.md` as a marked
  managed block, and ignores the volatile tier via the global git ignore
  (`~/.config/git/ignore`). Every session in any git project then gets the memory
  hooks and protocol automatically — existing projects, new repos, and worktrees
  created mid-session. Memory stays LOCAL: nothing is committed.
- The hooks now resolve the project from the session's working directory (not the
  script's location), so one global copy serves every project. A new
  `CHECKPOINT_REQUIRE_GIT` guard (set by the global config) confines writes to git
  work trees, so a global hook never creates `memory/` in an arbitrary directory
  such as `$HOME`. Per-project installs are unaffected — the guard is off there,
  and they still work in non-git projects.
- `tests/global.test.sh`: sandboxed (fake `HOME`) coverage of the global wiring,
  absolute commands, the git-only write guard, cwd resolution (including
  subdir → repo root), the managed protocol block, the global ignore,
  idempotency on re-run, and `--global --check`.

### Changed
- `install.sh --check` reports global scope when passed `--global`.
- `--global` and `--local` are mutually exclusive (explicit error).

## 0.5.0 — 2026-06-25

Robustness pass driven by reproducing realistic "antithetical usage" failures:
same-directory concurrency clobbering the working set, and ref-less garbage
accumulating in the auto-loaded ledger unseen. Both are now hardened defaults,
verified by deterministic reproductions, not process the user has to follow.

### Added
- **Per-session working set.** Each session writes its own
  `memory/working-set.<id>.md`, keyed by `CLAUDE_CODE_SESSION_ID`, so two efforts
  in one checkout no longer overwrite each other's "Now". The checkpoint hook and
  `mem ws-path` derive the same path with no coordination; outside a session (id
  unset) the legacy `memory/working-set.md` is used, so non-session behavior is
  unchanged.
- `mem ws-path` (this session's file, created on first use), `mem ws-latest` (the
  most-recently-touched working set, for a resume to read), and `mem ws-gc`
  (prune working-set files older than `WS_TTL_DAYS`, always keeping the latest and
  the current session's).
- **Forget gate now sees ref-less garbage.** `mem gc-scan` also nominates entries
  marked `superseded:*` and "stale" ones (no live code anchor, older than
  `LEDGER_STALE_DAYS` (30) by entry date, and cross-linked by no `[[id]]`).
  `invariant` and active `open-question` entries are never nominated.
- `tests/mem.test.sh`: per-session path derivation, `ws-latest`/`ws-gc`, and the
  gc-scan nomination/protection rules (including that invariants and active
  open-questions are protected).
- `tests/robustness.sh`: reproduces same-directory clobber and ledger-garbage
  against the *installed* kit and reports SAFE/UNSAFE per scenario (`--strict`
  exits non-zero on any UNSAFE), plus positive controls (worktree isolation,
  non-git project) and a measured parallel-branch ledger merge.

### Changed
- Default-mode install git-ignores `memory/working-set*.md` (the per-session glob)
  rather than the single `memory/working-set.md`.
- The example config no longer pins `CHECKPOINT_FILE`; left unset, the hook
  resolves the per-session path via `mem ws-path`. **Upgraders:** a pre-0.5.0
  `checkpoint.config.sh` still sets `CHECKPOINT_FILE`, which disables isolation;
  re-running `install.sh` now warns when it detects this (it never edits your
  config) — comment that line out to enable per-session working sets.
- `memory-metrics.sh` ages the most-recent session working set (per-session files
  share one directory). Accumulation of session files is observed on demand with
  `mem ws-gc`, not nagged in the auto block every checkpoint.
- Install's write-path verify is pinned to the legacy file and now requires a real
  timestamped checkpoint marker (not the seed template's placeholder), so it can't
  false-pass when the hook routes a write to a per-session file.
- `templates/CLAUDE.protocol.md` directs the agent to its working set via
  `mem ws-path` (write) and `mem ws-latest` (resume read), and documents the
  broader gc-scan candidate rules and protections.

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
