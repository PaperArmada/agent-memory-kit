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
# Resolve the project from the SESSION's working directory (where Claude Code runs
# the hook), not the script's location — so a single global install in
# ~/.claude/hooks serves every project. CHECKPOINT_PROJECT_DIR overrides (used by
# the installer and tests).
if [[ -n "${CHECKPOINT_PROJECT_DIR:-}" ]]; then
  PROJECT_DIR="${CHECKPOINT_PROJECT_DIR}"
else
  # The installer wires `cd "${CLAUDE_PROJECT_DIR}"` in front of this hook, so by
  # default we resolve from the session's LAUNCH directory. But the agent may
  # have `cd`'d into a sub-repo to do its work (e.g. the session launched from a
  # non-git container that holds several repos). In that case the agent's
  # `mem ws-path` resolved to the sub-repo and wrote its Now there, while we are
  # still at the launch dir — the session's memory would split across two files.
  # `mem ws-dir` returns the git work tree the agent last resolved (a breadcrumb
  # it leaves on ws-path/ws-latest); follow it so our checkpoint lands in the
  # SAME working-set file. Best-effort: no breadcrumb (the common single-repo
  # case) means no cd and behavior is unchanged.
  BREADCRUMB_DIR="$(python3 "${SCRIPT_DIR}/mem" ws-dir 2>/dev/null || true)"
  if [[ -n "${BREADCRUMB_DIR}" && -d "${BREADCRUMB_DIR}" ]]; then
    cd "${BREADCRUMB_DIR}" 2>/dev/null || true
  fi
  # Resolve from the visible cwd; ignore an inherited GIT_DIR/GIT_WORK_TREE so a
  # directory that exports them cannot steer where memory is written. (Worktrees
  # use a .git file, not these env vars, so this does not affect them.)
  GIT_ROOT="$(unset GIT_DIR GIT_WORK_TREE; git rev-parse --show-toplevel 2>/dev/null || true)"
  # CHECKPOINT_REQUIRE_GIT=1 (set by the global install) confines writes to git
  # work trees, so a global hook never creates memory/ in an arbitrary directory.
  # It ALSO refuses $HOME itself: a dotfiles repo would otherwise make the home
  # directory look like a project and accumulate a memory/ tree there.
  if [[ "${CHECKPOINT_REQUIRE_GIT:-0}" == "1" ]]; then
    HOME_REAL="$(cd "${HOME:-/nonexistent}" 2>/dev/null && pwd -P || printf '%s' "${HOME:-}")"
    if [[ -z "${GIT_ROOT}" || "${GIT_ROOT}" == "${HOME}" || "${GIT_ROOT}" == "${HOME_REAL}" ]]; then
      exit 0
    fi
  fi
  PROJECT_DIR="${GIT_ROOT:-$(pwd)}"
fi
STATE_CMD="${CHECKPOINT_STATE_CMD:-}"
STATE_MAX_LINES="${CHECKPOINT_STATE_MAX_LINES:-12}"
RATE_SECONDS="${CHECKPOINT_RATE_SECONDS:-10}"

# --- Rate limiting (per project) ---------------------------------------------
# CHECKPOINT_FORCE=1 bypasses the limit entirely — used by the PreCompact wiring,
# where skipping the write would defeat the whole purpose.
KEY=$(printf '%s' "${PROJECT_DIR}|${CLAUDE_CODE_SESSION_ID:-}" | cksum | cut -d' ' -f1)
RATE_FILE="${TMPDIR:-/tmp}/precompact-checkpoint-${KEY}.last"
NOW=$(date +%s)
if [[ "${CHECKPOINT_FORCE:-0}" != "1" && -f "${RATE_FILE}" ]]; then
  LAST=$(cat "${RATE_FILE}" 2>/dev/null || echo 0)
  if (( NOW - LAST < RATE_SECONDS )); then
    exit 0
  fi
fi
echo "${NOW}" > "${RATE_FILE}"

# --- Resolve the working-set file (only now that we've committed to writing) --
# Per-session path via `mem` (single source of truth for the session-key logic),
# so two efforts in one checkout never share a file. An explicit CHECKPOINT_FILE
# override wins; outside a session `mem` returns the legacy memory/working-set.md,
# so behavior is unchanged in non-session contexts. Done after the rate gate so
# skipped fires (the common case) cost nothing.
if [[ -z "${CHECKPOINT_FILE:-}" ]]; then
  CHECKPOINT_FILE="$(CHECKPOINT_PROJECT_DIR="${PROJECT_DIR}" python3 "${SCRIPT_DIR}/mem" ws-path 2>/dev/null)"
  [[ -z "${CHECKPOINT_FILE}" ]] && CHECKPOINT_FILE="${PROJECT_DIR}/memory/working-set.md"
fi

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
