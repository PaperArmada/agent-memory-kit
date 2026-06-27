#!/usr/bin/env bash
# Regression test for hooks/mem: per-session working sets and the age/status-aware
# forget gate. Locks the protections that prevent data loss (invariants and active
# open-questions must never be auto-nominated) and the nomination rules.
#
#   tests/mem.test.sh
#
# Self-contained throwaway project; bash, git, python3.

set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'cd /; rm -rf "${WORK}"' EXIT
# Isolate session breadcrumbs (mem records the resolved git root under
# XDG_CACHE_HOME) so the suite never reads or writes the real ~/.cache.
export XDG_CACHE_HOME="${WORK}/cache"

PASS=0; FAIL=0
ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL+1)); }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

P="${WORK}/p"; mkdir -p "${P}"; ( cd "${P}" && git init -q )
bash "${KIT_DIR}/install.sh" "${P}" >/dev/null 2>&1
MEM="${P}/.claude/hooks/mem"
# Set an exact mtime (seconds since epoch) so ordering tests don't depend on
# filesystem timestamp granularity or wall-clock between two ws-path calls.
setmtime() { python3 -c "import os,sys; t=float(sys.argv[2]); os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
NOW_TS="$(date +%s)"

echo "== per-session working set =="
A="$( CHECKPOINT_PROJECT_DIR="${P}" CLAUDE_CODE_SESSION_ID=aaaaaaaa-x python3 "${MEM}" ws-path )"
B="$( CHECKPOINT_PROJECT_DIR="${P}" CLAUDE_CODE_SESSION_ID=bbbbbbbb-x python3 "${MEM}" ws-path )"
L="$( CHECKPOINT_PROJECT_DIR="${P}" MEM_SESSION_ID= CLAUDE_CODE_SESSION_ID= python3 "${MEM}" ws-path )"
check "distinct session ids -> distinct files"   "[ \"\$(basename '${A}')\" = 'working-set.aaaaaaaa.md' ] && [ \"\$(basename '${B}')\" = 'working-set.bbbbbbbb.md' ]"
check "no session -> legacy working-set.md"      "[ \"\$(basename '${L}')\" = 'working-set.md' ]"
check "ws-path created the session files"         "[ -f '${A}' ] && [ -f '${B}' ]"
# Make B strictly the newest among ALL working sets (incl. the install-seeded
# legacy working-set.md), so the result can't tie at 1-second granularity.
for f in "${P}"/memory/working-set*.md; do setmtime "${f}" "$(( NOW_TS - 120 ))"; done
setmtime "${B}" "${NOW_TS}"
check "ws-latest returns most-recently-touched"   "[ \"\$( CHECKPOINT_PROJECT_DIR='${P}' python3 '${MEM}' ws-latest )\" = '${B}' ]"

echo "== ws-gc prunes stale, keeps latest + current =="
OLD="${P}/memory/working-set.deadbeef.md"; cp "${A}" "${OLD}"
setmtime "${OLD}" "$(( NOW_TS - 40*86400 ))"; setmtime "${A}" "${NOW_TS}"; setmtime "${B}" "${NOW_TS}"
CHECKPOINT_PROJECT_DIR="${P}" CLAUDE_CODE_SESSION_ID=bbbbbbbb-x python3 "${MEM}" ws-gc >/dev/null 2>&1
check "stale session file pruned"                 "[ ! -f '${OLD}' ]"
check "current + latest session files kept"       "[ -f '${A}' ] && [ -f '${B}' ]"

echo "== forget gate: nominations and protections =="
cat > "${P}/memory/ledger.md" <<'EOF'
# Ledger
## Decisions
### stale-old · decision · 2026-01-01 · active
**Claim:** old ref-less decision.
### fresh-new · decision · 2026-06-20 · active
**Claim:** recent ref-less decision.
### dead-ref · decision · 2026-01-01 · active
**Claim:** points at deleted code.
**Refs:** src/gone.py
### live-ref · decision · 2026-01-01 · active
**Claim:** anchored to an existing file.
**Refs:** memory/ledger.md
### old-plan · decision · 2026-01-01 · superseded:new-plan
**Claim:** replaced.
### keeper-old · decision · 2026-01-01 · active
**Claim:** old and ref-less, but another entry cross-links to it.
### selfish · decision · 2026-01-01 · active
**Claim:** old and ref-less, links only to itself [[selfish]].
## Invariants
### inv-1 · invariant · 2026-01-01 · active
**Claim:** must never block the Stop hook; relates to [[keeper-old]].
## Open questions
### oq-1 · open-question · 2026-01-01 · active
**Claim:** still deciding storage format.
EOF
GC="$( CHECKPOINT_PROJECT_DIR="${P}" MEM_NOW=2026-06-25 python3 "${MEM}" gc-scan )"
nominated() { grep -qE "^  $1:" <<<"${GC}"; }
check "stale ref-less decision nominated"         "nominated stale-old"
check "dead file-ref nominated"                   "nominated dead-ref"
check "superseded entry nominated"                "nominated old-plan"
check "fresh entry NOT nominated"                 "! nominated fresh-new"
check "live-anchored entry NOT nominated"         "! nominated live-ref"
check "cross-linked target NOT nominated"         "! nominated keeper-old"
check "self-link does not immunize"               "nominated selfish"
check "invariant protected (never nominated)"     "! nominated inv-1"
check "active open-question protected"            "! nominated oq-1"

echo "== demote moves nominee to archive, drops from ledger =="
CHECKPOINT_PROJECT_DIR="${P}" python3 "${MEM}" demote dead-ref >/dev/null 2>&1
check "demoted entry removed from ledger"          "! grep -q 'dead-ref' '${P}/memory/ledger.md'"
check "demoted entry appended to archive"          "grep -q 'dead-ref' '${P}/memory/archive.md'"

echo "== session breadcrumb (hook follows the agent's work dir) =="
# A real git repo the "agent" cd's into, with NO CHECKPOINT_PROJECT_DIR override:
# this is the organic resolution that should be recorded. Use --no-... so a
# global commit-msg hook (core.hooksPath) can't reject the seed commit.
REPO="${WORK}/repo"; mkdir -p "${REPO}"
( cd "${REPO}" && git init -q && git -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q --allow-empty -m seed )
BC="${WORK}/cache/agent-memory-kit/sessions/cccccccc.dir"
( cd "${REPO}" && CLAUDE_CODE_SESSION_ID=cccccccc-x python3 "${MEM}" ws-path >/dev/null )
check "organic git resolution records a breadcrumb"   "[ -f '${BC}' ]"
check "breadcrumb points at the resolved git root"    "[ \"\$(cat '${BC}')\" = \"\$(cd '${REPO}' && git rev-parse --show-toplevel)\" ]"
check "ws-dir prints the breadcrumb dir"              "[ \"\$( CLAUDE_CODE_SESSION_ID=cccccccc-x python3 '${MEM}' ws-dir )\" = \"\$(cd '${REPO}' && git rev-parse --show-toplevel)\" ]"

# The hook's OWN call passes CHECKPOINT_PROJECT_DIR; it must NOT overwrite the
# breadcrumb with the launch dir (that would re-open the split it exists to close).
( cd "${REPO}" && CHECKPOINT_PROJECT_DIR="${P}" CLAUDE_CODE_SESSION_ID=cccccccc-x python3 "${MEM}" ws-path >/dev/null )
check "override call does NOT poison the breadcrumb"  "[ \"\$(cat '${BC}')\" = \"\$(cd '${REPO}' && git rev-parse --show-toplevel)\" ]"

# A non-git cwd resolves via fallback and must not record anything.
mkdir -p "${WORK}/plain"
( cd "${WORK}/plain" && CLAUDE_CODE_SESSION_ID=dddddddd-x python3 "${MEM}" ws-path >/dev/null )
check "non-git fallback records no breadcrumb"        "[ ! -f '${WORK}/cache/agent-memory-kit/sessions/dddddddd.dir' ]"

# A stale breadcrumb (dir gone) is ignored, not blindly followed.
echo "${WORK}/vanished" > "${WORK}/cache/agent-memory-kit/sessions/eeeeeeee.dir"
check "ws-dir ignores a breadcrumb whose dir is gone" "[ -z \"\$( CLAUDE_CODE_SESSION_ID=eeeeeeee-x python3 '${MEM}' ws-dir )\" ]"

# A breadcrumb dir that still EXISTS but is no longer a git work tree (e.g. .git
# removed after recording) must not be followed — else the hook would steer a
# checkpoint into a non-git directory.
mkdir -p "${WORK}/exgit"
echo "${WORK}/exgit" > "${WORK}/cache/agent-memory-kit/sessions/99999999.dir"
check "ws-dir ignores a now-non-git breadcrumb dir"  "[ -z \"\$( CLAUDE_CODE_SESSION_ID=99999999-x python3 '${MEM}' ws-dir )\" ]"

# ws-gc prunes a stale breadcrumb by TTL while keeping the current session's.
setmtime "${WORK}/cache/agent-memory-kit/sessions/eeeeeeee.dir" "$(( NOW_TS - 30*86400 ))"
( cd "${REPO}" && CLAUDE_CODE_SESSION_ID=cccccccc-x WS_TTL_DAYS=14 python3 "${MEM}" ws-gc >/dev/null )
check "ws-gc prunes a stale breadcrumb"               "[ ! -f '${WORK}/cache/agent-memory-kit/sessions/eeeeeeee.dir' ]"
check "ws-gc keeps the current session's breadcrumb"  "[ -f '${BC}' ]"

echo
echo "passed: ${PASS}  failed: ${FAIL}"
[ "${FAIL}" -eq 0 ]
