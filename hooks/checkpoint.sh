#!/usr/bin/env bash
# Pre-compaction checkpoint hook (portable).
#
# Writes a deterministic, machine-readable checkpoint block to a durable
# memory file so an agent can re-orient instantly after Claude Code compacts
# the conversation. The block is the "known-good starting point" the recovery
# protocol (see templates/CLAUDE.protocol.md) tells the agent to read first.
#
# Design notes:
#   - Cheap: a few shell calls, gated by a rate limit. Safe to fire often.
#   - Idempotent: REPLACES the previous auto-checkpoint block in place rather
#     than appending, so the file never grows and "latest state" is unambiguous.
#   - Structural only: captures orientation (time, git, optional status output),
#     never semantic analysis. Narrative stays the agent's responsibility.
#
# Wire it to a PostToolUse matcher in .claude/settings.json. See README.md.
#
# Configuration (env vars, or an adjacent checkpoint.config.sh — see example):
#   CHECKPOINT_PROJECT_DIR     Project root.        Default: git root, else cwd.
#   CHECKPOINT_FILE            Tier-1 working-set file. Default: <root>/memory/working-set.md
#   CHECKPOINT_STATE_CMD       Command whose stdout becomes the "state" lines.
#                              e.g. "uv run python tools/status.py --oneline"
#   CHECKPOINT_STATE_MAX_LINES Truncate state output to N lines. Default: 12.
#   CHECKPOINT_RATE_SECONDS    Min seconds between writes. Default: 10.
#   CHECKPOINT_FORCE           If "1", ignore the rate limit and always write.
#                              Set this on the PreCompact wiring: the checkpoint
#                              that fires right before context loss is the one
#                              you least want the limiter to skip.

set -uo pipefail

# --- Load optional adjacent config -------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
[[ -f "${SCRIPT_DIR}/checkpoint.config.sh" ]] && source "${SCRIPT_DIR}/checkpoint.config.sh"

# --- Resolve configuration ---------------------------------------------------
PROJECT_DIR="${CHECKPOINT_PROJECT_DIR:-$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null || pwd)}"
CHECKPOINT_FILE="${CHECKPOINT_FILE:-${PROJECT_DIR}/memory/working-set.md}"
STATE_CMD="${CHECKPOINT_STATE_CMD:-}"
STATE_MAX_LINES="${CHECKPOINT_STATE_MAX_LINES:-12}"
RATE_SECONDS="${CHECKPOINT_RATE_SECONDS:-10}"

# --- Rate limiting (per project) ---------------------------------------------
# CHECKPOINT_FORCE=1 bypasses the limit entirely — used by the PreCompact wiring,
# where skipping the write would defeat the whole purpose.
KEY=$(printf '%s' "${PROJECT_DIR}" | cksum | cut -d' ' -f1)
RATE_FILE="${TMPDIR:-/tmp}/precompact-checkpoint-${KEY}.last"
NOW=$(date +%s)
if [[ "${CHECKPOINT_FORCE:-0}" != "1" && -f "${RATE_FILE}" ]]; then
  LAST=$(cat "${RATE_FILE}" 2>/dev/null || echo 0)
  if (( NOW - LAST < RATE_SECONDS )); then
    exit 0
  fi
fi
echo "${NOW}" > "${RATE_FILE}"

# --- Gather structural state -------------------------------------------------
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

GIT_BRANCH=$(git -C "${PROJECT_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "-")
GIT_SHA=$(git -C "${PROJECT_DIR}" rev-parse --short HEAD 2>/dev/null || echo "-")
if git -C "${PROJECT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "${PROJECT_DIR}" diff --quiet 2>/dev/null && git -C "${PROJECT_DIR}" diff --cached --quiet 2>/dev/null; then
    GIT_DIRTY="clean"
  else
    GIT_DIRTY="uncommitted changes"
  fi
else
  GIT_DIRTY="not a git repo"
fi

# Optional project-specific state command. Failures are swallowed: a checkpoint
# with git orientation alone is still useful, and a broken status tool must
# never block the hook.
STATE_BLOCK=""
if [[ -n "${STATE_CMD}" ]]; then
  STATE_OUT=$(cd "${PROJECT_DIR}" && eval "${STATE_CMD}" 2>/dev/null | head -n "${STATE_MAX_LINES}" || true)
  if [[ -n "${STATE_OUT}" ]]; then
    STATE_BLOCK=$'\n```\n'"${STATE_OUT}"$'\n```\n'
  fi
fi

CHECKPOINT="<!-- checkpoint ${TIMESTAMP} -->
## Checkpoint (auto)

| Field | Value |
|-------|-------|
| Time | ${TIMESTAMP} |
| Branch | \`${GIT_BRANCH}\` @ \`${GIT_SHA}\` (${GIT_DIRTY}) |
${STATE_BLOCK}"

# --- Write checkpoint: replace existing block, or create the file ------------
mkdir -p "$(dirname "${CHECKPOINT_FILE}")"

if [[ -f "${CHECKPOINT_FILE}" ]]; then
  CHECKPOINT_FILE="${CHECKPOINT_FILE}" CHECKPOINT_BLOCK="${CHECKPOINT}" python3 - <<'PY'
import os, re

path = os.environ["CHECKPOINT_FILE"]
checkpoint = os.environ["CHECKPOINT_BLOCK"].strip()

with open(path) as f:
    content = f.read()

# Remove the old auto-checkpoint block (marker through the next "## " or EOF).
content = re.sub(
    r'<!-- checkpoint[^\n]*\n## Checkpoint \(auto\)\n.*?(?=\n## |\Z)',
    '',
    content,
    flags=re.DOTALL,
).strip()

# Insert the fresh checkpoint right after the first H1, else at the top.
lines = content.split('\n')
insert_at = 0
for i, line in enumerate(lines):
    if line.startswith('# '):
        insert_at = i + 1
        break

out = '\n'.join(lines[:insert_at]) + '\n\n' + checkpoint + '\n\n' + '\n'.join(lines[insert_at:]).lstrip('\n')
with open(path, 'w') as f:
    f.write(out.rstrip() + '\n')
PY
else
  cat > "${CHECKPOINT_FILE}" <<NOTES_EOF
# Working Notes

${CHECKPOINT}

## Context

(No semantic context captured yet. The agent appends bug descriptions,
hypotheses, and decisions below; the checkpoint block above is regenerated
automatically and should not be hand-edited.)
NOTES_EOF
fi

exit 0
