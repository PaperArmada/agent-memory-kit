#!/usr/bin/env bash
# Installer for the tiered agent-memory kit.
#
# Copies the hooks and seeds the memory tier files into a target project, then
# prints the two manual steps that need a human decision (wiring settings.json
# and pasting the protocol into CLAUDE.md). Existing files are never clobbered.
#
# Usage:
#   ./install.sh /path/to/target/project

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${1:-}"

if [[ -z "${TARGET}" ]]; then
  echo "usage: ./install.sh /path/to/target/project" >&2
  exit 1
fi
if [[ ! -d "${TARGET}" ]]; then
  echo "error: target directory does not exist: ${TARGET}" >&2
  exit 1
fi

HOOKS_DIR="${TARGET}/.claude/hooks"
MEM_DIR="${TARGET}/memory"
mkdir -p "${HOOKS_DIR}" "${MEM_DIR}"

# --- Hooks (always refreshed; they carry no project state) -------------------
for h in checkpoint.sh recall.sh memory-metrics.sh mem guard-archive.sh; do
  cp "${KIT_DIR}/hooks/${h}" "${HOOKS_DIR}/${h}"
  chmod +x "${HOOKS_DIR}/${h}"
  echo "installed: ${HOOKS_DIR}/${h}"
done

# --- Config (never clobber an edited one) ------------------------------------
if [[ ! -f "${HOOKS_DIR}/checkpoint.config.sh" ]]; then
  cp "${KIT_DIR}/hooks/checkpoint.config.example.sh" "${HOOKS_DIR}/checkpoint.config.sh"
  echo "installed: ${HOOKS_DIR}/checkpoint.config.sh  (edit this)"
else
  echo "kept existing: ${HOOKS_DIR}/checkpoint.config.sh"
fi

# --- Memory tier seeds (never clobber real memory) ---------------------------
for m in working-set.md ledger.md archive.md; do
  if [[ ! -f "${MEM_DIR}/${m}" ]]; then
    cp "${KIT_DIR}/templates/memory/${m}" "${MEM_DIR}/${m}"
    echo "seeded: ${MEM_DIR}/${m}"
  else
    echo "kept existing: ${MEM_DIR}/${m}"
  fi
done

cat <<EOF

Two manual steps remain (both need your judgment, so they aren't auto-applied):

  1. Wire the hooks. Merge templates/settings.snippet.json into
     ${TARGET}/.claude/settings.json. PreCompact + SessionEnd(other) + Stop.

  2. Add the memory protocol. Paste templates/CLAUDE.protocol.md into
     ${TARGET}/CLAUDE.md and fill in your status command.

Then sanity-check the write path:

  CHECKPOINT_PROJECT_DIR="${TARGET}" ${HOOKS_DIR}/checkpoint.sh
  # Confirm the "## Checkpoint (auto)" block (with a memory-pressure line)
  # appears at the top of ${MEM_DIR}/working-set.md.

Design rationale and the tier/gate model: see MEMORY-MODEL.md.
EOF
