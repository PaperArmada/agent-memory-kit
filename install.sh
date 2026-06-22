#!/usr/bin/env bash
# Installer for the tiered agent-memory kit.
#
# Copies the hooks, seeds the memory tier files, and wires the hooks into the
# target's .claude/settings.json (idempotent deep-merge — never clobbers existing
# settings or duplicates a hook). Existing memory/config files are never
# overwritten.
#
# Usage:
#   ./install.sh [--local] /path/to/target/project
#
#   --local   Treat this as a shared repo where the memory tooling should stay
#             personal and uncommitted: also writes the memory protocol to
#             CLAUDE.local.md (auto-loaded, first-party local-override file) and
#             adds memory/, .claude/hooks/, and CLAUDE.local.md to the repo's
#             local git exclude (worktree-safe). Without --local, the protocol
#             paste into the shared CLAUDE.md is left as a printed manual step,
#             since that placement is a judgment call.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    -*) echo "error: unknown flag: $arg" >&2; exit 1 ;;
    *) TARGET="$arg" ;;
  esac
done

if [[ -z "${TARGET}" ]]; then
  echo "usage: ./install.sh [--local] /path/to/target/project" >&2
  exit 1
fi
if [[ ! -d "${TARGET}" ]]; then
  echo "error: target directory does not exist: ${TARGET}" >&2
  exit 1
fi
TARGET="$(cd "${TARGET}" && pwd)"

HOOKS_DIR="${TARGET}/.claude/hooks"
MEM_DIR="${TARGET}/memory"
SETTINGS="${TARGET}/.claude/settings.json"
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

# --- Wire the hooks into settings.json (idempotent deep-merge) ----------------
# Reads the canonical hook wiring from templates/settings.snippet.json, strips
# documentation (_-prefixed) keys and the optional domain-trigger example, and
# merges the result into the target settings.json. Re-running never duplicates a
# hook (dedupe by event + matcher + command set) and never touches unrelated
# settings. python3 is a stated kit requirement.
python3 - "${KIT_DIR}/templates/settings.snippet.json" "${SETTINGS}" <<'PY'
import json, sys, os

snippet_path, settings_path = sys.argv[1], sys.argv[2]

with open(snippet_path) as f:
    snippet = json.load(f)

def strip(obj):
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in obj.items() if not k.startswith("_")}
    if isinstance(obj, list):
        return [strip(v) for v in obj]
    return obj

desired = strip(snippet).get("hooks", {})

settings = {}
if os.path.exists(settings_path):
    with open(settings_path) as f:
        text = f.read().strip()
    settings = json.loads(text) if text else {}

hooks = settings.setdefault("hooks", {})

def sig(group):
    cmds = tuple(sorted(h.get("command", "") for h in group.get("hooks", [])))
    return (group.get("matcher", ""), cmds)

added = 0
for event, groups in desired.items():
    tgt = hooks.setdefault(event, [])
    existing = {sig(g) for g in tgt}
    for g in groups:
        if sig(g) not in existing:
            tgt.append(g)
            existing.add(sig(g))
            added += 1

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"settings: wired {added} new hook group(s) into {settings_path}"
      if added else f"settings: already wired, no change ({settings_path})")
PY

# --- Local mode: keep the tooling personal and uncommitted -------------------
if [[ "${LOCAL}" -eq 1 ]]; then
  CLAUDE_LOCAL="${TARGET}/CLAUDE.local.md"
  if [[ ! -f "${CLAUDE_LOCAL}" ]]; then
    {
      echo "# Local agent instructions (personal, not committed)"
      echo
      echo "Loaded alongside the committed CLAUDE.md. Carries the pre-compaction"
      echo "memory protocol (precompact-checkpoint-kit) for this project."
      echo
      # Strip the template's leading HTML paste-comment, fill the status command.
      sed '1,/-->/d' "${KIT_DIR}/templates/CLAUDE.protocol.md" \
        | sed 's|\[your status command\]|git status --short \&\& git log --oneline -5|'
    } > "${CLAUDE_LOCAL}"
    echo "wrote: ${CLAUDE_LOCAL}  (auto-loaded; personal)"
  else
    echo "kept existing: ${CLAUDE_LOCAL}"
  fi

  # Add to the repo's LOCAL exclude (not the committed .gitignore). Worktree-safe:
  # in a worktree, .git is a file and info/exclude lives in the common git dir, so
  # resolve the real path via git rather than assuming .git/info/exclude.
  if git -C "${TARGET}" rev-parse --git-dir >/dev/null 2>&1; then
    EX="$(cd "${TARGET}" && git rev-parse --git-path info/exclude)"
    case "${EX}" in /*) : ;; *) EX="${TARGET}/${EX}" ;; esac
    mkdir -p "$(dirname "${EX}")"
    for p in "memory/" ".claude/hooks/" ".claude/settings.json" "CLAUDE.local.md"; do
      grep -qxF "${p}" "${EX}" 2>/dev/null || echo "${p}" >> "${EX}"
    done
    echo "excluded (local): memory/, .claude/hooks/, .claude/settings.json, CLAUDE.local.md -> ${EX}"
  else
    echo "note: ${TARGET} is not a git repo; skipped local git-exclude step"
  fi
fi

# --- Verify the write path once, so we don't just assume it works ------------
if CHECKPOINT_PROJECT_DIR="${TARGET}" CHECKPOINT_FORCE=1 "${HOOKS_DIR}/checkpoint.sh" >/dev/null 2>&1 \
   && grep -q "Checkpoint (auto)" "${MEM_DIR}/working-set.md"; then
  echo "verified: checkpoint hook wrote the auto block to ${MEM_DIR}/working-set.md"
else
  echo "WARNING: checkpoint hook did not produce an auto block; check ${HOOKS_DIR}/checkpoint.sh manually" >&2
fi

# --- Remaining manual step ----------------------------------------------------
if [[ "${LOCAL}" -eq 1 ]]; then
  cat <<EOF

Done (local mode). Hooks wired, protocol in CLAUDE.local.md, tooling git-excluded.
CLAUDE.local.md auto-loads from your NEXT session (memory files load at start).
Tune ${HOOKS_DIR}/checkpoint.config.sh if you want a custom status command.
EOF
else
  cat <<EOF

Hooks wired and write path verified. One manual step remains (placement is a
judgment call, so it isn't auto-applied):

  Add the memory protocol. Paste templates/CLAUDE.protocol.md into
  ${TARGET}/CLAUDE.md and fill in your status command. For a SHARED repo where
  the protocol should stay personal, re-run with --local to put it in
  CLAUDE.local.md and git-exclude the tooling instead.

Design rationale and the tier/gate model: see MEMORY-MODEL.md.
EOF
fi
