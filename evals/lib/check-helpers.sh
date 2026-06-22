# Shared assertion helpers for scenario check.sh scripts. Source this.
#
# A check.sh sets SCEN, computes booleans, and calls `assert <gate> <desc> <0|1>`
# for each ground-truth claim. Output has two audiences:
#   - humans: "[PASS]/[FAIL] gate: desc" lines
#   - the runner: "RESULT scenario=<s> gate=<g> pass=<0|1>" lines (machine-parsed)
# `finish` prints the scenario verdict and exits non-zero if any gate failed.

SCEN="${SCEN:-unknown}"
FAILS=0

assert() { # gate, description, ok(1|0)
  local gate="$1" desc="$2" ok="$3"
  if [ "$ok" = "1" ]; then
    echo "  [PASS] ${gate}: ${desc}"
    echo "RESULT scenario=${SCEN} gate=${gate} pass=1"
  else
    echo "  [FAIL] ${gate}: ${desc}"
    echo "RESULT scenario=${SCEN} gate=${gate} pass=0"
    FAILS=$((FAILS + 1))
  fi
}

# bool helper: echo 1 if the given command succeeds, else 0.
b() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }
# negated bool: 1 if the command FAILS.
nb() { if "$@" >/dev/null 2>&1; then echo 0; else echo 1; fi; }

finish() {
  if [ "$FAILS" -eq 0 ]; then echo "SCENARIO ${SCEN}: PASS"; return 0
  else echo "SCENARIO ${SCEN}: FAIL (${FAILS} gate(s))"; return 1; fi
}
