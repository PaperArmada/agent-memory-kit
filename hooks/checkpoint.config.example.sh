# Example checkpoint config. Copy to checkpoint.config.sh (same dir as
# checkpoint.sh) and edit. Anything set here overrides the script defaults.
# The hook sources this file automatically if it exists, so you don't have to
# thread env vars through settings.json.

# Project root. Defaults to the git root, then cwd. Set explicitly if the hook
# may run from a subdirectory or a different worktree.
# CHECKPOINT_PROJECT_DIR="/absolute/path/to/project"

# Tier-1 working-set file: the hook writes its auto block at the top, the agent
# overwrites the "Now" section below it. This is what the protocol reads first.
#
# Leave this UNSET (the default). When unset, the hook resolves a PER-SESSION
# file via `mem ws-path` (memory/working-set.<session-id>.md), so two sessions in
# one checkout never overwrite each other's "Now". Setting it pins ONE fixed file
# for every session and disables that isolation — only do so deliberately.
# CHECKPOINT_FILE="${CHECKPOINT_PROJECT_DIR:-.}/memory/working-set.md"

# Project-specific structural state. stdout is embedded verbatim (truncated to
# CHECKPOINT_STATE_MAX_LINES). Keep it deterministic and fast: no LLM, no network
# (it runs inside the blocking PreCompact window). The memory-metrics line is the
# forget-gate's pressure prior; append your own status command after it.
#
# Examples:
#   CHECKPOINT_STATE_CMD=".claude/hooks/memory-metrics.sh"
#   CHECKPOINT_STATE_CMD=".claude/hooks/memory-metrics.sh; uv run python tools/status.py --oneline"
#   CHECKPOINT_STATE_CMD=".claude/hooks/memory-metrics.sh; git --no-pager log --oneline -2"
CHECKPOINT_STATE_CMD=".claude/hooks/memory-metrics.sh"

# Forget-gate prior: nudge a GC pass when the ledger exceeds this entry count.
# LEDGER_SOFT_MAX=20

# CHECKPOINT_STATE_MAX_LINES=12
# CHECKPOINT_RATE_SECONDS=10
