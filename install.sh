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
#   memory/working-set*.md is git-ignored (per-session and volatile), while
#   ledger.md and archive.md stay committed and shared. archive.md is given a
#   `union` merge driver so its append-only entries from parallel branches merge
#   without conflicts. See "Parallel development" in README.md.

set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

LOCAL=0
CHECK=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --local) LOCAL=1 ;;
    --check) CHECK=1 ;;
    -*) echo "error: unknown flag: $arg" >&2; exit 1 ;;
    *) TARGET="$arg" ;;
  esac
done

if [[ -z "${TARGET}" ]]; then
  echo "usage: ./install.sh [--local] [--check] /path/to/target/project" >&2
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
STATE="${HOOKS_DIR}/.agent-memory-kit.json"   # install state: version + managed hooks
KIT_VERSION="$(cat "${KIT_DIR}/VERSION" 2>/dev/null || echo "unknown")"
HOOKS=(checkpoint.sh recall.sh memory-metrics.sh mem guard-archive.sh)

state_version() { # echo the version recorded in the target's state file, else empty
  [[ -f "${STATE}" ]] || { echo ""; return; }
  python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('version',''))" "${STATE}" 2>/dev/null || echo ""
}

# --check: report installed vs available and exit, mutating nothing.
if [[ "${CHECK}" -eq 1 ]]; then
  installed="$(state_version)"; [[ -z "${installed}" ]] && installed="(not installed)"
  echo "agent-memory-kit: installed=${installed}  available=${KIT_VERSION}  (${TARGET})"
  if [[ "${installed}" == "${KIT_VERSION}" ]]; then
    echo "up to date"
  else
    echo "update available — re-run: ./install.sh ${TARGET}"
  fi
  exit 0
fi

mkdir -p "${HOOKS_DIR}" "${MEM_DIR}"
OLD_VERSION="$(state_version)"

# --- Hooks (always refreshed; they carry no project state) -------------------
for h in "${HOOKS[@]}"; do
  cp "${KIT_DIR}/hooks/${h}" "${HOOKS_DIR}/${h}"
  chmod +x "${HOOKS_DIR}/${h}"
  echo "installed: ${HOOKS_DIR}/${h}"
done

# --- Prune hooks a prior version placed but the current one no longer ships ---
# Manifest-driven, so only kit-managed files are removed (never the user's own
# hooks). REMOVED also drives settings-group pruning in the merge step below.
REMOVED="$(python3 - "${STATE}" "${HOOKS_DIR}" "${HOOKS[@]}" <<'PY'
import json, os, sys
state_path, hooks_dir, current = sys.argv[1], sys.argv[2], set(sys.argv[3:])
old = []
if os.path.exists(state_path):
    try: old = json.load(open(state_path)).get("hooks", [])
    except Exception: old = []
removed = [h for h in old if h not in current]
for h in removed:
    p = os.path.join(hooks_dir, h)
    if os.path.isfile(p):
        os.remove(p)
print(" ".join(removed))
PY
)"
[[ -n "${REMOVED}" ]] && echo "pruned removed hooks: ${REMOVED}"

# --- Config (never clobber an edited one) ------------------------------------
if [[ ! -f "${HOOKS_DIR}/checkpoint.config.sh" ]]; then
  cp "${KIT_DIR}/hooks/checkpoint.config.example.sh" "${HOOKS_DIR}/checkpoint.config.sh"
  echo "installed: ${HOOKS_DIR}/checkpoint.config.sh  (edit this)"
else
  echo "kept existing: ${HOOKS_DIR}/checkpoint.config.sh"
  # An active CHECKPOINT_FILE= line pins one fixed working set and disables the
  # per-session isolation (pre-0.5.0 configs set it). Warn; do not auto-edit a
  # config the user may have customized.
  if grep -qE '^[[:space:]]*(export[[:space:]]+)?CHECKPOINT_FILE=' "${HOOKS_DIR}/checkpoint.config.sh"; then
    echo "WARNING: ${HOOKS_DIR}/checkpoint.config.sh sets CHECKPOINT_FILE, which pins one" >&2
    echo "         working set for all sessions and disables per-session isolation (new in" >&2
    echo "         0.5.0). Comment that line out to let sessions get separate working sets." >&2
  fi
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
python3 - "${KIT_DIR}/templates/settings.snippet.json" "${SETTINGS}" "${REMOVED}" <<'PY'
import json, sys, os

snippet_path, settings_path = sys.argv[1], sys.argv[2]
removed_hooks = sys.argv[3].split() if len(sys.argv) > 3 and sys.argv[3].strip() else []

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

# Prune hook groups that invoke a kit hook this version removed, so the wiring
# does not dangle after a hook is dropped or renamed.
pruned = 0
if removed_hooks:
    def refs_removed(group):
        for h in group.get("hooks", []):
            cmd = h.get("command", "")
            if any(f".claude/hooks/{r}" in cmd for r in removed_hooks):
                return True
        return False
    for event in list(hooks.keys()):
        before = len(hooks[event])
        hooks[event] = [g for g in hooks[event] if not refs_removed(g)]
        pruned += before - len(hooks[event])
        if not hooks[event]:
            del hooks[event]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

msg = f"settings: wired {added} new hook group(s)" if added else "settings: already wired, no change"
if pruned:
    msg += f", pruned {pruned} stale group(s)"
print(f"{msg} ({settings_path})")
PY

# --- Record install state (version + managed hooks) for future updates -------
python3 - "${STATE}" "${KIT_VERSION}" "${HOOKS[@]}" <<'PY'
import json, sys
json.dump({"version": sys.argv[2], "hooks": list(sys.argv[3:])}, open(sys.argv[1], "w"), indent=2)
open(sys.argv[1], "a").write("\n")
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
  if grep -qE '^memory/working-set\*?\.md$' "${TARGET}/.gitignore" 2>/dev/null \
     || grep -qxF "memory/archive.md merge=union" "${TARGET}/.gitattributes" 2>/dev/null; then
    echo "WARNING: shared-mode git config (.gitignore / .gitattributes from a prior default" >&2
    echo "         install) is present in the tree. --local keeps memory personal; remove" >&2
    echo "         those lines if you do not want them committed." >&2
  fi
fi

# --- Shared mode: split the git treatment of the memory tiers ----------------
# working-set*.md is volatile and per-session (each session writes its own "Now"
# file, keyed by session id, so concurrent efforts never collide); committing it
# would churn merge diffs, so it is git-ignored. ledger.md and archive.md are shared
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
    if add_line "${TARGET}/.gitignore" "memory/working-set*.md"; then
      echo "git-ignored (shared): memory/working-set*.md  (per-session, volatile)"
    else
      echo "git-ignore already excludes memory/working-set*.md"
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
# Pin the verify to the legacy (no-session) file and require a real timestamped
# marker, not the seed template's "(none yet)" placeholder, so this genuinely
# proves the hook wrote — even when install runs inside a Claude session (which
# would otherwise route the write to a per-session working-set.<id>.md).
if CHECKPOINT_PROJECT_DIR="${TARGET}" CHECKPOINT_FORCE=1 CHECKPOINT_FILE="" CLAUDE_CODE_SESSION_ID="" MEM_SESSION_ID="" "${HOOKS_DIR}/checkpoint.sh" >/dev/null 2>&1 \
   && grep -qE '<!-- checkpoint [0-9]{4}-' "${MEM_DIR}/working-set.md"; then
  echo "verified: checkpoint hook wrote the auto block to ${MEM_DIR}/working-set.md"
else
  echo "WARNING: checkpoint hook did not produce an auto block; check ${HOOKS_DIR}/checkpoint.sh manually" >&2
fi

# --- Version delta ------------------------------------------------------------
if [[ -z "${OLD_VERSION}" ]]; then
  echo "installed: agent-memory-kit ${KIT_VERSION}"
elif [[ "${OLD_VERSION}" == "${KIT_VERSION}" ]]; then
  echo "reinstalled: agent-memory-kit ${KIT_VERSION}"
else
  echo "updated: agent-memory-kit ${OLD_VERSION} -> ${KIT_VERSION}"
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

Memory sharing: working-set*.md is git-ignored (per-session, isolated even within
one checkout); ledger.md and archive.md are committed and shared (archive set to
union-merge). Worktrees still isolate cleanly — see "Parallel development" in README.

Design rationale and the tier/gate model: see MEMORY-MODEL.md.
EOF
fi
