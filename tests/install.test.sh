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

echo "== test 5: default mode splits git treatment of the memory tiers =="
T5="${WORK}/t5"; mkdir -p "${T5}"
( cd "${T5}" && git init -q )
bash "${INSTALL}" "${T5}" >/dev/null 2>&1
check "working-set.md git-ignored"          "git -C '${T5}' check-ignore -q memory/working-set.md"
check "per-session working-set git-ignored" "git -C '${T5}' check-ignore -q memory/working-set.aaaaaaaa.md"
check "ledger.md NOT git-ignored"           "! git -C '${T5}' check-ignore -q memory/ledger.md"
check "archive.md NOT git-ignored"          "! git -C '${T5}' check-ignore -q memory/archive.md"
check "archive set to union merge"          "grep -qxF 'memory/archive.md merge=union' '${T5}/.gitattributes'"
bash "${INSTALL}" "${T5}" >/dev/null 2>&1
check "gitignore entry not duplicated"      "[ \"\$(grep -cxF 'memory/working-set*.md' '${T5}/.gitignore')\" = '1' ]"
check "gitattributes entry not duplicated"  "[ \"\$(grep -cxF 'memory/archive.md merge=union' '${T5}/.gitattributes')\" = '1' ]"

echo "== test 6: --local does NOT add the shared-mode git treatment =="
# In --local mode all of memory/ is excluded personally; the committed .gitignore
# / .gitattributes should not gain the shared-mode entries.
check "no committed .gitignore working-set entry" "[ ! -f '${T2}/.gitignore' ] || ! grep -q 'memory/working-set' '${T2}/.gitignore'"
check "no committed union .gitattributes"          "[ ! -f '${T2}/.gitattributes' ] || ! grep -qxF 'memory/archive.md merge=union' '${T2}/.gitattributes'"

echo "== test 7: default->--local warns about leftover shared-mode git config =="
T7="${WORK}/t7"; mkdir -p "${T7}"; ( cd "${T7}" && git init -q )
bash "${INSTALL}" "${T7}" >/dev/null 2>&1               # default adds .gitignore/.gitattributes
OUT7="$(bash "${INSTALL}" --local "${T7}" 2>&1)"        # then switch to --local
check "shared .gitignore entry still present"  "grep -qxF 'memory/working-set*.md' '${T7}/.gitignore'"
check "--local warns about leftover shared config" "printf '%s' \"\${OUT7}\" | grep -q 'shared-mode git config'"

echo "== test 8: pre-tracked working-set is detected (ignore would be inert) =="
T8="${WORK}/t8"; mkdir -p "${T8}/memory"; ( cd "${T8}" && git init -q )
echo "# Working Set" > "${T8}/memory/working-set.md"
( cd "${T8}" && git add memory/working-set.md && git -c core.hooksPath=/dev/null commit -q --no-verify -m ws )
OUT8="$(bash "${INSTALL}" "${T8}" 2>&1)"
check "warns tracked working-set makes ignore inert" "printf '%s' \"\${OUT8}\" | grep -q 'already git-tracked'"

echo "== test 9: --local->default warns shared tiers are still ignored =="
T9="${WORK}/t9"; mkdir -p "${T9}"; ( cd "${T9}" && git init -q )
bash "${INSTALL}" --local "${T9}" >/dev/null 2>&1       # excludes all of memory/
OUT9="$(bash "${INSTALL}" "${T9}" 2>&1)"                # then switch to default
check "warns shared tiers won't commit after --local" "printf '%s' \"\${OUT9}\" | grep -q 'shared memory tiers will NOT commit'"

echo "== test 10: install records version state and prints the delta =="
T10="${WORK}/t10"; mkdir -p "${T10}"; ( cd "${T10}" && git init -q )
OUT10="$(bash "${INSTALL}" "${T10}" 2>&1)"
ST10="${T10}/.claude/hooks/.agent-memory-kit.json"
check "state file written"                "[ -f '${ST10}' ]"
check "state records current version"     "[ \"\$(python3 -c \"import json;print(json.load(open('${ST10}'))['version'])\")\" = \"\$(cat '${KIT_DIR}/VERSION')\" ]"
check "fresh install prints 'installed:'"  "printf '%s' \"\${OUT10}\" | grep -q 'installed: agent-memory-kit'"
OUT10B="$(bash "${INSTALL}" "${T10}" 2>&1)"
check "re-run prints 'reinstalled:'"       "printf '%s' \"\${OUT10B}\" | grep -q 'reinstalled: agent-memory-kit'"

echo "== test 11: --check reports installed vs available without mutating =="
OUT11="$(bash "${INSTALL}" --check "${T10}" 2>&1)"
check "--check reports up to date"         "printf '%s' \"\${OUT11}\" | grep -q 'up to date'"
T11="${WORK}/t11"; mkdir -p "${T11}"
OUT11B="$(bash "${INSTALL}" --check "${T11}" 2>&1)"
check "--check on uninstalled: not installed" "printf '%s' \"\${OUT11B}\" | grep -q 'installed=(not installed)'"
check "--check did not create hooks dir"   "[ ! -d '${T11}/.claude/hooks' ]"

echo "== test 12: update prunes a hook (and its wiring) the new version dropped =="
T12="${WORK}/t12"; mkdir -p "${T12}"; ( cd "${T12}" && git init -q )
bash "${INSTALL}" "${T12}" >/dev/null 2>&1
ST12="${T12}/.claude/hooks/.agent-memory-kit.json"
python3 - "${ST12}" <<'PY'
import json,sys
d=json.load(open(sys.argv[1])); d["version"]="0.0.0"; d["hooks"].append("oldhook.sh")
json.dump(d,open(sys.argv[1],"w"))
PY
echo 'echo x' > "${T12}/.claude/hooks/oldhook.sh"
python3 - "${T12}/.claude/settings.json" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
d["hooks"].setdefault("Stop",[]).append({"matcher":"","hooks":[{"type":"command","command":".claude/hooks/oldhook.sh"}]})
json.dump(d,open(sys.argv[1],"w"))
PY
bash "${INSTALL}" "${T12}" >/dev/null 2>&1
check "stale hook file removed"            "[ ! -f '${T12}/.claude/hooks/oldhook.sh' ]"
check "stale settings group removed"       "! grep -q 'oldhook.sh' '${T12}/.claude/settings.json'"
check "current hooks survive prune"        "[ -f '${T12}/.claude/hooks/checkpoint.sh' ] && [ -f '${T12}/.claude/hooks/mem' ]"

echo "== test 13: config default leaves CHECKPOINT_FILE unset (per-session works) =="
# A fresh config must NOT pin CHECKPOINT_FILE, or the hook would skip mem ws-path
# and write one shared working set for every session (defeating isolation).
CFG13="${T1}/.claude/hooks/checkpoint.config.sh"
check "fresh config does not pin CHECKPOINT_FILE" "! grep -qE '^[[:space:]]*(export[[:space:]]+)?CHECKPOINT_FILE=' '${CFG13}'"
# An existing config that DOES pin it triggers a warning on re-install. Use an
# ABSOLUTE path under the temp project so the sourced value can't redirect any
# write outside the sandbox if something sources the config.
printf 'CHECKPOINT_FILE="%s/memory/ws-pinned.md"\n' "${T1}" >> "${CFG13}"
OUT13="$(bash "${INSTALL}" "${T1}" 2>&1)"
check "re-install warns on pinned CHECKPOINT_FILE"  "printf '%s' \"\${OUT13}\" | grep -q 'disables per-session isolation'"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
