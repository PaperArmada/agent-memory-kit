#!/usr/bin/env bash
# robustness.sh — reproduce realistic "antithetical usage" failures of the kit.
#
# Unlike install.test.sh (mechanical regression) and evals/ (LLM-judgment), this
# harness reproduces, deterministically and against the REAL installed kit, the
# ways heterogeneous use defeats the kit's intent WITHOUT any misbehavior by the
# user or agent. Each scenario states a target invariant and reports whether the
# current default upholds it (SAFE) or violates it (UNSAFE). The UNSAFE ones are
# the hardening targets; after a default is hardened, its scenario flips to SAFE
# and can move into the regression suite.
#
#   tests/robustness.sh            # diagnostic: report SAFE/UNSAFE, always exit 0
#   tests/robustness.sh --strict   # exit non-zero if any invariant is UNSAFE (CI gate)
#
# Self-contained: throwaway projects under a temp dir, cleaned up. bash/git/python3.

set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${KIT_DIR}/install.sh"
WORK="$(mktemp -d)"
trap 'cd /; rm -rf "${WORK}"' EXIT

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

UNSAFE=0
SAFE=0
INFO=0
declare -a ROWS

# verdict <name> <safe|unsafe|info> <detail>
verdict() {
  local name="$1" v="$2" detail="$3"
  case "${v}" in
    safe)   SAFE=$((SAFE+1));   printf '  \033[32mSAFE  \033[0m %-28s %s\n' "${name}" "${detail}";;
    unsafe) UNSAFE=$((UNSAFE+1)); printf '  \033[31mUNSAFE\033[0m %-28s %s\n' "${name}" "${detail}";;
    info)   INFO=$((INFO+1));   printf '  \033[33mINFO  \033[0m %-28s %s\n' "${name}" "${detail}";;
  esac
  ROWS+=("${v}|${name}|${detail}")
}

install_kit() { bash "${INSTALL}" "$1" >/dev/null 2>&1; }

# Author a working-set "Now" block the way an effort's agent would (overwrite-in-
# place; this tier is volatile by design). Markers are greppable.
author_working_set() { # <file> <task> <hypothesis-marker> <next-marker>
  cat > "$1" <<EOF
# Working Set

<!-- checkpoint (none yet) -->
## Checkpoint (auto)

## Now

**Task:** $2
**Live hypothesis:** $3
**Next step:** $4
**Blocked on:** nothing
EOF
}

# Append N ref-less ledger entries (decisions/dead-ends with no file Refs) — the
# kind that consolidations produce constantly and that carry no path to verify.
append_refless_entries() { # <ledger> <count>
  local f="$1" n="$2" i
  for ((i = 1; i <= n; i++)); do
    if (( i % 2 == 0 )); then
      # ref-less via a non-file ref (a tag / cross-link)
      cat >> "${f}" <<EOF

### deadend-${i} · dead-end · 2026-01-01 · active
**Claim:** approach ${i} was abandoned because the state machine deadlocked.
**Why:** kept here so we do not retry it.
**Refs:** #design-thread-${i}
EOF
    else
      # ref-less via no Refs line at all
      cat >> "${f}" <<EOF

### decision-${i} · decision · 2026-01-01 · active
**Claim:** we chose option ${i} for the rollout ordering.
**Why:** discussed live; no code anchor.
EOF
    fi
  done
}

echo "== reproduction harness: antithetical usage vs current defaults =="
echo

# ---------------------------------------------------------------------------
# Scenario 1: same-directory concurrency clobbers the working set.
# Two efforts in ONE checkout share a single memory/working-set.md. The second
# effort's volatile overwrite destroys the first effort's in-flight state, which
# was never promoted to the ledger. Target invariant: a concurrent effort must
# not silently destroy another effort's recoverable state.
# ---------------------------------------------------------------------------
S1="${WORK}/s1"; mkdir -p "${S1}"; ( cd "${S1}" && git init -q )
install_kit "${S1}"
MEM="${S1}/.claude/hooks/mem"
SIDA="aaaaaaaa-1111-2222-3333-444444444444"   # effort A's session
SIDB="bbbbbbbb-1111-2222-3333-444444444444"   # effort B's session, SAME checkout

# Effort A: get its per-session working set and record its in-flight state.
WSA="$( CHECKPOINT_PROJECT_DIR="${S1}" CLAUDE_CODE_SESSION_ID="${SIDA}" python3 "${MEM}" ws-path )"
author_working_set "${WSA}" "refactor token cache" "HYP_A_cache_key_collision" "NEXT_A_add_regression_test"
CHECKPOINT_PROJECT_DIR="${S1}" CLAUDE_CODE_SESSION_ID="${SIDA}" CHECKPOINT_FORCE=1 bash "${S1}/.claude/hooks/checkpoint.sh" >/dev/null 2>&1

# Effort B begins concurrently in the SAME checkout (different session).
WSB="$( CHECKPOINT_PROJECT_DIR="${S1}" CLAUDE_CODE_SESSION_ID="${SIDB}" python3 "${MEM}" ws-path )"
author_working_set "${WSB}" "triage MR #42 flaky test" "HYP_B_race_in_setup" "NEXT_B_add_retry"
CHECKPOINT_PROJECT_DIR="${S1}" CLAUDE_CODE_SESSION_ID="${SIDB}" CHECKPOINT_FORCE=1 bash "${S1}/.claude/hooks/checkpoint.sh" >/dev/null 2>&1

# Isolation holds only if: the two sessions resolved DIFFERENT files, the hook
# wrote a real checkpoint into EACH session's own file (not a shared legacy
# fallback, which would let this pass while actually clobbering), and each file
# carries its own effort's hypothesis.
if [[ "${WSA}" != "${WSB}" ]] \
   && grep -qE '<!-- checkpoint [0-9]{4}-' "${WSA}" && grep -qE '<!-- checkpoint [0-9]{4}-' "${WSB}" \
   && grep -q HYP_A_cache_key_collision "${WSA}" && grep -q HYP_B_race_in_setup "${WSB}" \
   && ! grep -q HYP_B_race_in_setup "${WSA}"; then
  verdict "concurrent-clobber" safe "two sessions in one checkout keep separate working sets; hook wrote into each; both survive"
else
  verdict "concurrent-clobber" unsafe "effort A's working set destroyed by effort B (same checkout); never promoted, unrecoverable"
fi

# ---------------------------------------------------------------------------
# Scenario 2 (positive control): worktrees isolate the working set.
# The same two efforts, but effort B runs in a git worktree (separate working
# tree → its own memory/working-set.md). Expectation: both survive. This frames
# Scenario 1 as specifically a SAME-directory problem.
# ---------------------------------------------------------------------------
S2="${WORK}/s2"; mkdir -p "${S2}"
( cd "${S2}" && git init -q && git commit -q --no-verify --allow-empty -m init && git worktree add -q wt >/dev/null 2>&1 )
install_kit "${S2}"
author_working_set "${S2}/memory/working-set.md" "effort A" "HYP_A_main" "NEXT_A"
mkdir -p "${S2}/wt/memory"
author_working_set "${S2}/wt/memory/working-set.md" "effort B" "HYP_B_worktree" "NEXT_B"
if grep -q HYP_A_main "${S2}/memory/working-set.md" && grep -q HYP_B_worktree "${S2}/wt/memory/working-set.md"; then
  verdict "worktree-isolation" safe "separate working trees keep separate working sets (expected)"
else
  verdict "worktree-isolation" unsafe "worktrees did not isolate working sets"
fi

# ---------------------------------------------------------------------------
# Scenario 3: ref-less ledger garbage is invisible to the relief tooling.
# The auto-loaded tier fills with decisions/dead-ends that carry no file Refs.
# memory-metrics flags the pressure, but `mem gc-scan` only nominates entries
# whose file Refs all vanished, so it reports zero candidates while the hot tier
# bloats. Target invariant: ref-less bloat has a non-judgment path to relief.
# ---------------------------------------------------------------------------
S3="${WORK}/s3"; mkdir -p "${S3}"; ( cd "${S3}" && git init -q )
install_kit "${S3}"
LEDGER3="${S3}/memory/ledger.md"
append_refless_entries "${LEDGER3}" 30

METRICS3="$( cd "${S3}" && bash .claude/hooks/memory-metrics.sh 2>/dev/null )"
# Fixed "now" so the staleness window is deterministic regardless of run date.
GC3="$( CHECKPOINT_PROJECT_DIR="${S3}" MEM_NOW=2026-06-25 python3 "${S3}/.claude/hooks/mem" gc-scan 2>/dev/null )"

pressure_flagged=0
grep -q 'consolidate/GC' <<<"${METRICS3}" && pressure_flagged=1
gc_candidates=0
# "no demote candidates: ..." means none; the positive output starts "demote
# candidates (...)". Match the positive case without tripping on the negative.
if ! grep -q 'no demote candidates' <<<"${GC3}" && grep -q 'demote candidates' <<<"${GC3}"; then
  gc_candidates=1
fi

if (( gc_candidates == 1 )); then
  verdict "ledger-garbage" safe "gc-scan surfaces ref-less stale entries for relief"
else
  verdict "ledger-garbage" unsafe "30 ref-less entries over soft-max; metrics pressure=${pressure_flagged}, but gc-scan finds 0 candidates — no mechanical relief path"
fi

# ---------------------------------------------------------------------------
# Scenario 4: parallel-branch ledger merge (measure-only).
# Two branches each append a ledger entry, then merge. archive.md is union (no
# conflict by design); ledger.md is not. A conflict here is git-VISIBLE friction,
# not silent loss — recorded to decide whether ledger should also union.
# ---------------------------------------------------------------------------
S4="${WORK}/s4"; mkdir -p "${S4}"; ( cd "${S4}" && git init -q )
install_kit "${S4}"
(
  cd "${S4}"
  git add -A >/dev/null 2>&1
  git -c core.hooksPath=/dev/null commit -q --no-verify -m base >/dev/null 2>&1
  git checkout -q -b branchX
  printf '\n### x1 · decision · 2026-06-02 · active\n**Claim:** X.\n' >> memory/ledger.md
  printf '\n### x1 · decision · 2026-06-02 · active\n**Claim:** X-archived.\n' >> memory/archive.md
  git -c core.hooksPath=/dev/null commit -qam x --no-verify >/dev/null 2>&1
  git checkout -q master 2>/dev/null || git checkout -q main 2>/dev/null
  git checkout -q -b branchY
  printf '\n### y1 · decision · 2026-06-02 · active\n**Claim:** Y.\n' >> memory/ledger.md
  printf '\n### y1 · decision · 2026-06-02 · active\n**Claim:** Y-archived.\n' >> memory/archive.md
  git -c core.hooksPath=/dev/null commit -qam y --no-verify >/dev/null 2>&1
)
MERGE4="$( cd "${S4}" && git -c core.hooksPath=/dev/null merge --no-edit branchX 2>&1 )"
ledger_conflict=0; archive_conflict=0
grep -q 'CONFLICT.*ledger.md' <<<"${MERGE4}" && ledger_conflict=1
grep -q 'CONFLICT.*archive.md' <<<"${MERGE4}" && archive_conflict=1
verdict "parallel-ledger-merge" info "ledger conflict=${ledger_conflict} (git-visible) · archive union conflict=${archive_conflict} (design: should be 0)"

# ---------------------------------------------------------------------------
# Scenario 5: non-git project still functions (measure-only).
# A consumer installs into a directory that is not a git repo. The checkpoint
# hook should still produce a usable working set (git fields just read "-").
# ---------------------------------------------------------------------------
S5="${WORK}/s5"; mkdir -p "${S5}"   # deliberately NOT a git repo
install_kit "${S5}"
CHECKPOINT_PROJECT_DIR="${S5}" CHECKPOINT_FORCE=1 bash "${S5}/.claude/hooks/checkpoint.sh" >/dev/null 2>&1
if grep -q 'Checkpoint (auto)' "${S5}/memory/working-set.md" 2>/dev/null; then
  verdict "non-git-project" safe "checkpoint writes a usable working set without git"
else
  verdict "non-git-project" unsafe "checkpoint did not produce a working set in a non-git project"
fi

echo
echo "summary: ${SAFE} safe · ${UNSAFE} unsafe (hardening targets) · ${INFO} info"
echo
if (( UNSAFE > 0 )); then
  echo "hardening targets:"
  for r in "${ROWS[@]}"; do
    IFS='|' read -r v name detail <<<"${r}"
    [[ "${v}" == "unsafe" ]] && echo "  - ${name}: ${detail}"
  done
fi

if (( STRICT == 1 )); then
  exit "$(( UNSAFE > 0 ? 1 : 0 ))"
fi
exit 0
