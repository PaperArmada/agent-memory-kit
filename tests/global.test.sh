#!/usr/bin/env bash
# Regression test for `install.sh --global`. Runs entirely inside a throwaway
# HOME/XDG_CONFIG_HOME so it NEVER touches the real ~/.claude. Verifies the
# safety-critical behaviors: absolute hook wiring, the git-only write guard
# (memory/ is never created in non-git dirs), cwd-based project resolution, the
# managed protocol block, the global ignore, and idempotency.
#
#   tests/global.test.sh
#
# Self-contained; bash, git, python3.

set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL="${KIT_DIR}/install.sh"
WORK="$(mktemp -d)"
trap 'cd /; rm -rf "${WORK}"' EXIT
# Isolate session breadcrumbs away from the real ~/.cache.
export XDG_CACHE_HOME="${WORK}/cache"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# Fake home — the global install writes only here.
HOME_DIR="${WORK}/home"; mkdir -p "${HOME_DIR}"
XDG="${HOME_DIR}/.config"
HD="${HOME_DIR}/.claude/hooks"
gi() { HOME="${HOME_DIR}" XDG_CONFIG_HOME="${XDG}" bash "${INSTALL}" --global "$@"; }

echo "== test 1: global install lands in the fake HOME =="
OUT1="$(gi 2>&1)"
check "hooks copied to ~/.claude/hooks"        "[ -f '${HD}/checkpoint.sh' ] && [ -f '${HD}/mem' ]"
check "global config sets CHECKPOINT_REQUIRE_GIT" "grep -q '^CHECKPOINT_REQUIRE_GIT=1' '${HD}/checkpoint.config.sh'"
check "manifest records scope=global"           "[ \"\$(python3 -c \"import json;print(json.load(open('${HD}/.agent-memory-kit.json'))['scope'])\")\" = 'global' ]"
check "prints global completion"                "printf '%s' \"\${OUT1}\" | grep -q 'Global install complete'"
check "does NOT touch a real project tree"      "[ ! -d '${WORK}/memory' ]"

echo "== test 2: settings.json wired with ABSOLUTE commands =="
S="${HOME_DIR}/.claude/settings.json"
check "settings.json created"                   "[ -f '${S}' ]"
check "command path is absolute under fake HOME" "python3 -c \"import json,sys; d=json.load(open('${S}')); cmds=[h['command'] for ev in d.get('hooks',{}).values() for g in ev for h in g['hooks']]; sys.exit(0 if any(c.startswith('${HD}/') for c in cmds) and not any(c.startswith('.claude/') for c in cmds) else 1)\""

echo "== test 3: protocol appended to ~/.claude/CLAUDE.md (managed, absolute) =="
CM="${HOME_DIR}/.claude/CLAUDE.md"
check "managed begin marker present"            "grep -qF 'agent-memory-kit:begin' '${CM}'"
check "protocol uses absolute (quoted) mem path" "grep -qF '\"${HD}/mem\"' '${CM}'"

echo "== test 4: global git-ignore covers the volatile tier =="
check "global ignore has working-set glob"      "grep -qxF 'memory/working-set*.md' '${XDG}/git/ignore'"

echo "== test 5: SAFETY — hook writes nothing in a NON-git dir =="
NOGIT="${WORK}/nogit"; mkdir -p "${NOGIT}"
( cd "${NOGIT}" && CHECKPOINT_FORCE=1 CLAUDE_CODE_SESSION_ID="" MEM_SESSION_ID="" bash "${HD}/checkpoint.sh" >/dev/null 2>&1 )
check "no memory/ created outside a git repo"   "[ ! -e '${NOGIT}/memory' ]"

echo "== test 6: hook writes into the git repo it is run from (cwd resolution) =="
GITP="${WORK}/proj"; mkdir -p "${GITP}"; ( cd "${GITP}" && git init -q )
( cd "${GITP}" && CHECKPOINT_FORCE=1 CLAUDE_CODE_SESSION_ID="" MEM_SESSION_ID="" bash "${HD}/checkpoint.sh" >/dev/null 2>&1 )
check "memory/working-set.md created in repo"   "[ -f '${GITP}/memory/working-set.md' ]"
check "real timestamped checkpoint written"     "grep -qE '<!-- checkpoint [0-9]{4}-' '${GITP}/memory/working-set.md'"
# A subdirectory resolves to the repo root, not the subdir.
mkdir -p "${GITP}/sub/deep"
( cd "${GITP}/sub/deep" && CHECKPOINT_FORCE=1 CLAUDE_CODE_SESSION_ID="" MEM_SESSION_ID="" bash "${HD}/checkpoint.sh" >/dev/null 2>&1 )
check "subdir resolves to repo root (no nested memory/)" "[ ! -e '${GITP}/sub/deep/memory' ]"

echo "== test 7: idempotency — re-run adds nothing =="
gi >/dev/null 2>&1
groups_before_dupe="$(python3 -c "import json;d=json.load(open('${S}'));print(sum(len(v) for v in d['hooks'].values()))")"
gi >/dev/null 2>&1
groups_after="$(python3 -c "import json;d=json.load(open('${S}'));print(sum(len(v) for v in d['hooks'].values()))")"
check "settings hook groups not duplicated"     "[ \"\${groups_before_dupe}\" = \"\${groups_after}\" ]"
check "protocol block not duplicated"           "[ \"\$(grep -cF 'agent-memory-kit:begin' '${CM}')\" = '1' ]"
check "global ignore line not duplicated"       "[ \"\$(grep -cxF 'memory/working-set*.md' '${XDG}/git/ignore')\" = '1' ]"

echo "== test 8: --check reports global scope =="
OUT8="$(HOME="${HOME_DIR}" XDG_CONFIG_HOME="${XDG}" bash "${INSTALL}" --global --check 2>&1)"
check "--check shows global + up to date"        "printf '%s' \"\${OUT8}\" | grep -q 'global' && printf '%s' \"\${OUT8}\" | grep -q 'up to date'"

echo "== test 9: --global and --local are mutually exclusive =="
OUT9="$(HOME="${HOME_DIR}" bash "${INSTALL}" --global --local 2>&1)"; rc=$?
check "rejects --global --local"                 "[ \"\${rc}\" != '0' ] && printf '%s' \"\${OUT9}\" | grep -q 'mutually exclusive'"

echo "== test 10: global ignore honors an existing core.excludesFile =="
CE="${HOME_DIR}/my_global_ignore"
HOME="${HOME_DIR}" git config --global core.excludesFile "${CE}"
HOME="${HOME_DIR}" XDG_CONFIG_HOME="${XDG}" bash "${INSTALL}" --global >/dev/null 2>&1
check "line written to the configured excludes file" "grep -qxF 'memory/working-set*.md' '${CE}'"
RP="${WORK}/anyrepo"; mkdir -p "${RP}/memory"; ( cd "${RP}" && git init -q )
check "git actually ignores the volatile tier"   "HOME='${HOME_DIR}' git -C '${RP}' check-ignore -q memory/working-set.aaaa.md"
HOME="${HOME_DIR}" git config --global --unset core.excludesFile

echo "== test 11: a home path with a space yields a shell-quoted command =="
HS="${WORK}/ho me"; mkdir -p "${HS}"
HOME="${HS}" XDG_CONFIG_HOME="${HS}/.config" bash "${INSTALL}" --global >/dev/null 2>&1
SS="${HS}/.claude/settings.json"
check "spaced hook path is single-quoted in settings" "grep -qF \"'${HS}/.claude/hooks/checkpoint.sh'\" '${SS}'"

echo "== test 12: SAFETY — \$HOME being a git repo does NOT collect memory/ =="
( cd "${HOME_DIR}" && git init -q )
( cd "${HOME_DIR}" && HOME="${HOME_DIR}" CHECKPOINT_FORCE=1 CLAUDE_CODE_SESSION_ID="" MEM_SESSION_ID="" bash "${HD}/checkpoint.sh" >/dev/null 2>&1 )
check "no memory/ created when \$HOME itself is a repo" "[ ! -e '${HOME_DIR}/memory' ]"

echo "== test 13: SAFETY — REQUIRE_GIT guard holds even when a breadcrumb points at \$HOME =="
# A session breadcrumb pointing at $HOME (which test 12 made a git repo) is a
# valid git tree, so the hook WILL follow it — but the REQUIRE_GIT guard must
# still refuse $HOME and write nothing. Confirms the follow cannot escape the guard.
mkdir -p "${WORK}/cache/agent-memory-kit/sessions"
printf '%s\n' "${HOME_DIR}" > "${WORK}/cache/agent-memory-kit/sessions/deadbeef.dir"
SCRATCH="${WORK}/scratch"; mkdir -p "${SCRATCH}"   # fire from an unrelated non-git dir
( cd "${SCRATCH}" && HOME="${HOME_DIR}" CHECKPOINT_FORCE=1 CLAUDE_CODE_SESSION_ID="deadbeef-1111" MEM_SESSION_ID="" bash "${HD}/checkpoint.sh" >/dev/null 2>&1 )
check "breadcrumb to \$HOME does not collect memory/" "[ ! -e '${HOME_DIR}/memory' ]"
check "breadcrumb follow wrote nothing to scratch"    "[ ! -e '${SCRATCH}/memory' ]"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
