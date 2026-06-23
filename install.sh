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
#
#   Default (shared) mode also splits the git treatment of the memory tiers:
#   memory/working-set.md is git-ignored (per-effort and volatile), while
#   ledger.md and archive.md stay committed and shared. archive.md is given a
#   `union` merge driver so its append-only entries from parallel branches merge
#   without conflicts. See "Parallel development" in README.md.

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

  # Reverse-mode check: shared-mode git config from a prior default install leaks
  # the kit into the committed tree; --local users usually do not want that.
  if grep -qxF "memory/working-set.md" "${TARGET}/.gitignore" 2>/dev/null \
     || grep -qxF "memory/archive.md merge=union" "${TARGET}/.gitattributes" 2>/dev/null; then
    echo "WARNING: shared-mode git config (.gitignore / .gitattributes from a prior default" >&2
    echo "         install) is present in the tree. --local keeps memory personal; remove" >&2
    echo "         those lines if you do not want them committed." >&2
  fi
fi

# --- Shared mode: split the git treatment of the memory tiers ----------------
# working-set.md is volatile and per-effort (each worktree/branch/session has its
# own "Now"); committing it would collide across parallel efforts and churn merge
# diffs, so it is git-ignored. ledger.md and archive.md are shared project memory
# and stay committed. The archive is append-only, so a `union` merge driver
# integrates entries from parallel branches without conflicts (it keeps both
# sides) — that is what lets parallel development merge cleanly. ledger.md keeps
# the default merge (it is small; conflicts are rare and human-resolvable). In
# --local mode all of memory/ is already excluded above, so this is skipped.
if [[ "${LOCAL}" -eq 0 ]]; then
  if git -C "${TARGET}" rev-parse --git-dir >/dev/null 2>&1; then
    add_line() { # file, exact-line  -> 0 if appended, 1 if already present
      local f="$1" line="$2"
      grep -qxF "${line}" "${f}" 2>/dev/null && return 1
      if [[ -s "${f}" && -n "$(tail -c1 "${f}" 2>/dev/null)" ]]; then printf '\n' >> "${f}"; fi
      printf '%s\n' "${line}" >> "${f}"
      return 0
    }
    if add_line "${TARGET}/.gitignore" "memory/working-set.md"; then
      echo "git-ignored (shared): memory/working-set.md  (per-effort)"
    else
      echo "git-ignore already excludes memory/working-set.md"
    fi
    if add_line "${TARGET}/.gitattributes" "memory/archive.md merge=union"; then
      echo "git-attribute (shared): memory/archive.md merge=union  (append-only entries merge without git conflicts)"
    else
      echo "git-attribute already set: memory/archive.md merge=union"
    fi

    # Truthfulness checks — the happy-path messages above assume a clean slate.
    # A .gitignore line is inert on an already-tracked file; and the shared tiers
    # cannot be committed if a broader rule already ignores them (most often a
    # prior `--local` install's info/exclude 'memory/'). Warn instead of silently
    # printing success, but do not auto-mutate the user's git state.
    if git -C "${TARGET}" ls-files --error-unmatch memory/working-set.md >/dev/null 2>&1; then
      echo "WARNING: memory/working-set.md is already git-tracked, so the ignore is inert." >&2
      echo "         Stop committing it:  git -C \"${TARGET}\" rm --cached memory/working-set.md" >&2
    fi
    for shared in memory/ledger.md memory/archive.md; do
      if git -C "${TARGET}" check-ignore -q "${shared}" 2>/dev/null \
         && ! git -C "${TARGET}" ls-files --error-unmatch "${shared}" >/dev/null 2>&1; then
        echo "WARNING: ${shared} is git-ignored by an existing rule and not yet tracked, so the" >&2
        echo "         shared memory tiers will NOT commit (likely a prior '--local' install)." >&2
        echo "         Inspect and remove the rule:  git -C \"${TARGET}\" check-ignore -v ${shared}" >&2
      fi
    done
  else
    echo "note: ${TARGET} is not a git repo; skipped shared-mode git treatment (working-set ignore, archive union-merge)"
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

Memory sharing: working-set.md is git-ignored (per-effort); ledger.md and
archive.md are committed and shared (archive set to union-merge). For parallel
features, use one git worktree per effort — see "Parallel development" in README.

Design rationale and the tier/gate model: see MEMORY-MODEL.md.
EOF
fi
