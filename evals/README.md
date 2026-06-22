# Eval zoo

A small set of scenario fixtures with deterministic ground-truth checkers, for
measuring the **semantic layer** (agent behavior under the memory protocol). The
mechanical layer is unit-tested elsewhere; these evals measure what a real agent
does, which is stochastic, so results are pass-rates over repeated runs, not
pass/fail.

Each scenario seeds a fresh project (memory tiers + code + a task), an agent
resumes on the shared `prompt.txt`, and the scenario's `check.sh` scores the
result against fixed ground truth. A scenario fully passes only if the agent does
the right thing **and** avoids the wrong things.

## Scenarios

| # | Name | Exercises | Crisp? |
|---|------|-----------|--------|
| 01 | recall-override | recall (non-obvious archived decision beats the generic default), promote, demote, immutability | crisp |
| 02 | forget-gate | demote the stale entries, keep the live ones, immutability, do the task | crisp |
| 03 | no-op-control | negative control: no pressure / nothing stale → must NOT over-demote or junk-promote | crisp |
| 04 | dead-end | do not reopen an approach the ledger records as abandoned | crisp (proxy on "uses html.parser / no tag regex") |
| 05 | reconcile | continue uncommitted in-flight work rather than restarting | proxy (continuity heuristics) |

Gates are of two kinds. **Action gates** (recall, demote, task, …) fail on an
un-acted project, so they measure "did the agent do the work." **Guard gates**
(immutability, keep-live, no-spurious-demote, …) pass on an un-acted project,
so they measure "did the agent avoid breaking something." A scenario-level pass
needs both kinds, which is why a do-nothing agent fails every scenario.

## Running

There is **no auto-runner that invokes an agent for you**, by design. Driving an
agent over these scenarios means letting it run shell commands (the memory tools
use Bash), which requires a permission decision that depends entirely on *your*
environment. A script with a permission-bypass default would be a footgun for
anyone who ran it without realizing, so the kit ships the safe pieces and leaves
the agent invocation to you, on purpose.

Three steps per run:

1. **Build a scenario** (safe — just writes files into a fresh dir):
   ```bash
   scenarios/02-forget-gate/setup.sh _work/02-forget-gate/run-1
   ```
2. **Run your agent** on the shared prompt against that dir, with the permission
   posture *you* choose. The agent executes shell commands, so do this where
   you're willing to let it: a container, VM, or throwaway checkout, **not** your
   primary working tree. Substitute the path into the prompt and feed it to your
   agent however you invoke it:
   ```bash
   prompt=$(sed "s#PROJECT_DIR#$PWD/_work/02-forget-gate/run-1#g" prompt.txt)
   # then run YOUR agent on it, in YOUR sandbox, with YOUR permission settings.
   ```
   Note: tool-dependent scenarios (01, 02, 04) need the agent to actually run the
   `mem` / `recall.sh` Bash tools. A normal headless agent will pause for approval
   on those; bypassing approvals is reasonable **only** inside a sandbox, and is a
   choice you make deliberately, not a default this kit makes for you.
3. **Score** (safe — no agent, no permission flags):
   ```bash
   scenarios/02-forget-gate/check.sh _work/02-forget-gate/run-1   # one run
   ./score.sh _work                                               # aggregate many
   ```

`score.sh` only reads project dirs and runs the deterministic checkers; it never
invokes an agent. `BASELINE.md` records a snapshot and exactly how those numbers
were produced.

## Adding a scenario

Create `scenarios/NN-name/{setup.sh,check.sh}`. `setup.sh <dir>` builds a fresh
project (install the kit, seed memory + code + task, fire one checkpoint).
`check.sh <dir>` sources `lib/check-helpers.sh`, sets `SCEN`, and calls
`assert <gate> <desc> <0|1>` per ground-truth claim, then `finish`. Keep ground
truth mechanical; prefer crisp checks, and label proxies as such.
