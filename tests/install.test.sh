#!/usr/bin/env bash
# Mechanical regression test for install.sh.
#
# Covers the parts that are easy to break silently: the idempotent settings.json
# deep-merge (no clobber, no duplicate hooks), --local artifacts (CLAUDE.local.md
# + worktree-safe git exclude), default-mode behavior, and the write-path verify.
#
# Self-contained: creates throwaway projects under a temp dir and cleans up.
# Exits non-zero on the first failed assertion. Requires bash, git, python3.
#
#   tests/install.test.sh

set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${KIT_DIR}/install.sh"
WORK="$(mktemp -d)"
trap 'cd /; rm -rf "${WORK}"' EXIT

PASS=0
FAIL=0
ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# settings.json helper: count hook groups under an event, or list events.
jq_events() { python3 -c "import json,sys;print(' '.join(json.load(open(sys.argv[1])).get('hooks',{})))" "$1"; }
jq_groups() { python3 -c "import json,sys;print(len(json.load(open(sys.argv[1])).get('hooks',{}).get(sys.argv[2],[])))" "$1" "$2"; }
jq_has()    { python3 -c "import json,sys;print('yes' if sys.argv[2] in json.load(open(sys.argv[1])) else 'no')" "$1" "$2"; }

echo "== test 1: default mode, fresh project =="
T1="${WORK}/t1"; mkdir -p "${T1}"
bash "${INSTALL}" "${T1}" >/dev/null 2>&1
S1="${T1}/.claude/settings.json"
check "settings.json created"                 "[ -f '${S1}' ]"
check "all four hook events wired"            "[ \"\$(jq_events '${S1}')\" = 'PreToolUse PreCompact SessionEnd Stop' ]"
check "memory tiers seeded"                   "[ -f '${T1}/memory/working-set.md' ] && [ -f '${T1}/memory/ledger.md' ] && [ -f '${T1}/memory/archive.md' ]"
check "write path verified (auto block)"      "grep -q 'Checkpoint (auto)' '${T1}/memory/working-set.md'"
check "default mode does NOT write CLAUDE.local.md" "[ ! -f '${T1}/CLAUDE.local.md' ]"

echo "== test 2: --local merges into existing settings without clobber/dupe =="
T2="${WORK}/t2"; mkdir -p "${T2}/.claude"
( cd "${T2}" && git init -q )
cat > "${T2}/.claude/settings.json" <<'JSON'
{
  "permissions": {"allow": ["Bash"]},
  "hooks": {"Stop": [{"matcher": "", "hooks": [{"type": "command", "command": ".claude/hooks/checkpoint.sh"}]}]}
}
JSON
bash "${INSTALL}" --local "${T2}" >/dev/null 2>&1
S2="${T2}/.claude/settings.json"
check "unrelated 'permissions' key preserved" "[ \"\$(jq_has '${S2}' permissions)\" = 'yes' ]"
check "pre-existing Stop hook not duplicated"  "[ \"\$(jq_groups '${S2}' Stop)\" = '1' ]"
check "PreCompact added"                       "[ \"\$(jq_groups '${S2}' PreCompact)\" = '1' ]"
check "CLAUDE.local.md written"                "[ -f '${T2}/CLAUDE.local.md' ]"
check "status command filled in protocol"      "grep -q 'git status --short && git log --oneline -5' '${T2}/CLAUDE.local.md'"
EX2="$(cd "${T2}" && git rev-parse --git-path info/exclude)"; case "${EX2}" in /*) : ;; *) EX2="${T2}/${EX2}";; esac
check "memory/ added to local git-exclude"     "grep -qxF 'memory/' '${EX2}'"
check "CLAUDE.local.md added to git-exclude"   "grep -qxF 'CLAUDE.local.md' '${EX2}'"

echo "== test 3: idempotency (re-run adds nothing) =="
bash "${INSTALL}" --local "${T2}" >/dev/null 2>&1
check "Stop still single group after re-run"   "[ \"\$(jq_groups '${S2}' Stop)\" = '1' ]"
check "PreCompact still single group"          "[ \"\$(jq_groups '${S2}' PreCompact)\" = '1' ]"
EXLINES="$(grep -cxF 'memory/' "${EX2}")"
check "exclude entry not duplicated"           "[ \"\${EXLINES}\" = '1' ]"

echo "== test 4: --local on a git worktree resolves the common-dir exclude =="
T4="${WORK}/t4"; mkdir -p "${T4}"
# --no-verify so a global commit-msg hook (e.g. commitlint) can't block setup.
( cd "${T4}" && git init -q && git commit -q --no-verify --allow-empty -m init && git worktree add -q wt >/dev/null 2>&1 )
bash "${INSTALL}" --local "${T4}/wt" >/dev/null 2>&1
EX4="$(cd "${T4}/wt" && git rev-parse --git-path info/exclude)"; case "${EX4}" in /*) : ;; *) EX4="${T4}/wt/${EX4}";; esac
check "worktree exclude path resolved + written" "[ -f '${EX4}' ] && grep -qxF '.claude/hooks/' '${EX4}'"
check "worktree CLAUDE.local.md written"          "[ -f '${T4}/wt/CLAUDE.local.md' ]"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
