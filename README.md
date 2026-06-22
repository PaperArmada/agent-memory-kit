# Pre-Compaction Memory Kit

A small, portable system that gives Claude Code sessions a durable, actively-maintained memory that complements (does not replace) the lossy summary produced at compaction. When Claude Code compacts a long conversation it swaps the transcript for a summary, and the summary loses the load-bearing semantics: which hypothesis was live, why a decision was made, what was tried and abandoned. This kit moves that content into files governed by explicit write, forget, and recall rules, so it survives compaction and accumulates coherently across sessions.

The full design and rationale are in **MEMORY-MODEL.md**. This README is the operational guide.

## The two halves

1. **A checkpoint hook** (`hooks/checkpoint.sh`) writes a machine-readable **Checkpoint (auto)** block (time, git position, status output, memory pressure) into the working-set file. Cheap, rate-limited, idempotent, and forced right before compaction. This is the structural envelope, the "where," and it is the only part a hook can produce.
2. **A memory protocol** (`templates/CLAUDE.protocol.md`) pasted into `CLAUDE.md` governs the semantic content: the agent overwrites the working set each step, promotes durable facts to the ledger, demotes stale ones to the archive, and reads it all back on resume. This is the "why," and only the agent can produce it.

The hook keeps the envelope fresh; the protocol keeps the content alive. Install both.

## The model in brief

Three tiers by volatility, three gates as three moves. See MEMORY-MODEL.md for the full treatment.

| Tier | File | Lifetime | Kept small by |
|---|---|---|---|
| Working set | `memory/working-set.md` | seconds | overwrite in place |
| Ledger | `memory/ledger.md` | per-decision | demotion (forget gate) |
| Archive | `memory/archive.md` | permanent, immutable | nothing: never auto-loaded |

- **Promote** (working-set → ledger): salient facts only. Test: would a cold-start agent decide worse without it?
- **Demote** (ledger → archive): the forget gate. Stale entries move to the archive; they are never deleted.
- **Recall** (archive → context): scoped query only (`recall.sh` grep, or the indexer if present). The archive can grow without bound because this gate, not deletion, keeps it out of context.

The archive is an append-only, immutable record of *curated* facts (demoted ledger entries), not the raw session transcript. It is the substrate a future learning loop would train on, so it is never edited or pruned. When an indexer is present, the raw transcript is available as a deeper, out-of-band fallback (`search_turns`) for details the curated archive doesn't hold; that transcript is not a tier this kit manages.

## What's in the box

```
precompact-checkpoint-kit/
├── README.md
├── MEMORY-MODEL.md                     # the design: tiers, gates, honest limits
├── install.sh                          # deploys hooks + seeds memory tiers
├── hooks/
│   ├── checkpoint.sh                   # structural auto block (the write side)
│   ├── recall.sh                       # flat-file output gate (no-indexer fallback)
│   ├── memory-metrics.sh               # forget-gate pressure signal for the auto block
│   ├── mem                             # forget-gate tools: gc-scan + append-only demote
│   ├── guard-archive.sh                # PreToolUse guard: blocks direct archive edits
│   └── checkpoint.config.example.sh    # the knobs, documented
└── templates/
    ├── settings.snippet.json           # how to wire the hooks
    ├── CLAUDE.protocol.md              # the memory protocol to paste into CLAUDE.md
    └── memory/                         # seed scaffolds (under-specified on purpose)
        ├── working-set.md
        ├── ledger.md
        └── archive.md
```

## Install

```bash
./install.sh /path/to/your/project
```

Copies the three hooks and a config into `<project>/.claude/hooks/`, seeds `<project>/memory/` with the three tier files (never clobbering existing ones), and prints the two manual steps:

1. **Wire the hooks.** Merge `templates/settings.snippet.json` into `<project>/.claude/settings.json` (PreCompact + SessionEnd + Stop).
2. **Add the protocol.** Paste `templates/CLAUDE.protocol.md` into `<project>/CLAUDE.md` and fill in your status command.

Then verify the write path (don't assume, check the file):

```bash
CHECKPOINT_PROJECT_DIR=/path/to/your/project /path/to/your/project/.claude/hooks/checkpoint.sh
# Confirm a "## Checkpoint (auto)" block with a memory-pressure line is at the
# top of memory/working-set.md.
```

## Configure

Edit `<project>/.claude/hooks/checkpoint.config.sh`. All settings are optional.

| Setting | Default | Purpose |
|---|---|---|
| `CHECKPOINT_FILE` | `<root>/memory/working-set.md` | Tier-1 file the protocol reads first. |
| `CHECKPOINT_STATE_CMD` | `.claude/hooks/memory-metrics.sh` | stdout embedded in the block. Default surfaces ledger pressure; append your own status command after it. Fast and offline only (runs in the blocking PreCompact window). |
| `CHECKPOINT_STATE_MAX_LINES` | `12` | Truncate that output so the block stays small. |
| `CHECKPOINT_PROJECT_DIR` | git root, else cwd | Override for subdir/worktree runs. |
| `CHECKPOINT_RATE_SECONDS` | `10` | Minimum gap between writes (heartbeat only). |
| `CHECKPOINT_FORCE` | `0` | `1` ignores the rate limit. Set on PreCompact/SessionEnd so the critical write is never skipped. |
| `LEDGER_SOFT_MAX` | `20` | Ledger entry count above which the auto block nudges a GC pass. |

## Choosing the trigger

`settings.snippet.json` wires three generally-available events. None need project-specific tooling:

- **`PreCompact` (primary).** Fires synchronously before both automatic and manual (`/compact`) compaction, the exact moment context is lost. Wired with `CHECKPOINT_FORCE=1`. It blocks compaction until it returns, so keep `CHECKPOINT_STATE_CMD` fast.
- **`SessionEnd` matcher `other` (crash backup).** Catches abnormal termination, where PreCompact never fires. Best-effort: a hard kill or power loss runs nothing.
- **`Stop` (heartbeat).** Fires once per agent turn, keeping the working set fresh so PreCompact always has recent state. Uses the rate limit, not force.

**Loop safety:** the Stop command must stay non-blocking (`checkpoint.sh` always exits 0). Never point a Stop hook at a command that exits 2 or returns `decision: block` to force the agent to "consolidate," that re-triggers the turn and loops. Consolidation is driven by the protocol inside normal turns, never by a blocking hook.

**Optional domain trigger.** If your project drives a state machine, also checkpoint on that transition for higher signal. The snippet has a disabled `PostToolUse` example to rename. Most projects won't need it.

**Recovery nudge.** A `PostCompact` event fires after compaction and can inject a reminder to run the protocol. Not wired by default (the `CLAUDE.md` protocol covers it), but it's the hook to reach for if the agent skips re-orientation.

## The maintenance loop

The hook guarantees the structure is fresh; you and the agent (per the protocol) keep the content alive:

1. **Every meaningful step:** overwrite the working set's "Now" section. This is what bounds crash loss, so write often.
2. **At decision/task boundaries:** promote durable facts to the ledger (input gate).
3. **When the auto block reports ledger pressure:** run `mem gc-scan` to find entries whose Refs no longer exist, then `mem demote <id>` to move stale ones to the archive (append-only). A `PreToolUse` guard blocks any direct edit to `archive.md`, so the immutable record can't be corrupted even by mistake.
4. **On resume:** read the auto block, then the working set, then relevant ledger entries. Query the archive only for a specific lost detail.

## Requirements

`bash` (3.2+), `git`, `python3`, `awk`, and standard coreutils. No packages to install.

> Status: **v0.1.0**, pre-1.0 (SemVer): layout, protocol, and tool surface may change between minor versions. The mechanical layer is execution-verified on Linux; the semantic layer has a baseline eval suite in [`evals/BASELINE.md`](evals/BASELINE.md).

### Portability (macOS / BSD): statically reviewed, not yet run

The scripts were reviewed line-by-line against BSD/macOS tool behavior but have only been *executed* on Linux (WSL2). Findings:

- **`stat`** is the one real GNU/BSD divergence (`stat -c %Y` vs `stat -f %m`); `memory-metrics.sh` already handles it with an explicit fallback.
- **`awk`** uses only POSIX features (`index`, `split` with a regex separator, `tolower`, `ENVIRON`, user functions). No gawk extensions, so macOS's BSD `awk` is fine.
- **`cksum` / `date -u` / `head -n` / `cut` / `mktemp -d`** all have the BSD forms the scripts use. `cksum` only derives a temp-file name, so even a differing checksum is harmless.
- **bash 3.2** (macOS's default `/bin/bash`): no 4.0+ syntax is used, and the one empty-array-under-`set -u` edge is guarded by a length check before the array is expanded.
- **`python3`** does the in-place block replacement and is *not* preinstalled on a bare macOS. Install it first (`xcode-select --install`, or Homebrew Python).

**Residual risk:** this is review, not a run. The most likely surprise is bash 3.2 array / `set -u` behavior (reasoned through, not executed on 3.2), followed by a missing `python3` on a fresh Mac. For ground truth, run the scripts once on a Mac and confirm a checkpoint block appears in `memory/working-set.md`; nothing here substitutes for that.

## License

MIT. See [LICENSE](LICENSE).
