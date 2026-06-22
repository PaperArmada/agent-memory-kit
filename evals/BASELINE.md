# Eval baseline — v0.1.0

Snapshot of the semantic layer's measured behavior, for regressing future changes
against. Numbers are pass-rates over repeated agent runs (behavior is stochastic),
scored by the deterministic `check.sh` per scenario.

## Methodology

- **Date:** 2026-06-20. **Kit version:** 0.1.0.
- **Scenarios × runs:** 5 × 3 = 15 agent runs.
- **Agent:** Claude Code general-purpose subagents on the session model (Opus
  4.x), each given the shared `prompt.txt` on a freshly built scenario project.
  These numbers were produced by driving the agents directly through the
  orchestrator (full tool access), then scoring with `check.sh`. Expect modest
  drift across models, effort settings, and how you invoke the agent.
- **Scoring:** deterministic `check.sh`; agent self-reports were ignored. Each
  checker was validated to fail on an un-acted project and pass on a correct
  solution before use. One checker false-negative (S1 recall tripping on a
  comment that *named* `yaml.safe_load`) was found and fixed during scoring;
  numbers below reflect the fixed checker.

## Scenario-level (all gates pass), n=3

| Scenario | Pass rate |
|---|---|
| 01-recall-override | **1/3** |
| 02-forget-gate | 3/3 |
| 03-no-op-control | 3/3 |
| 04-dead-end | 3/3 |
| 05-reconcile | 3/3 |

**13/15 runs fully passed; 44/45 gate-checks passed.**

## Per-gate, n=3

| Scenario | Gate | Rate |
|---|---|---|
| 01-recall-override | recall | 3/3 |
| 01-recall-override | promote | 3/3 |
| 01-recall-override | **demote** | **1/3** |
| 01-recall-override | immutability | 3/3 |
| 02-forget-gate | demote-stale | 3/3 |
| 02-forget-gate | keep-live | 3/3 |
| 02-forget-gate | immutability | 3/3 |
| 02-forget-gate | task | 3/3 |
| 03-no-op-control | no-spurious-demote | 3/3 |
| 03-no-op-control | keep-live | 3/3 |
| 03-no-op-control | no-junk-promote | 3/3 |
| 03-no-op-control | task | 3/3 |
| 04-dead-end | avoid-deadend | 3/3 |
| 04-dead-end | follow-record | 3/3 |
| 04-dead-end | task | 3/3 |
| 05-reconcile | continuity | 3/3 |
| 05-reconcile | completed | 3/3 |

## The one weak spot: forget-gate as a side-chore

Every failure traces to a single behavior. In S1 the headline task is implementing
YAML support; the stale ledger entry (E03) is incidental. In 2 of 3 runs the agent
**detected** E03 as stale (it said so explicitly) but **deferred** demoting it to
"a future session," because its attention was on the task. Run-2 did the demote and
passed.

Contrast S2, where clearing stale entries *is* the main event: demotion was 3/3.
So the weakness is not detection (agents/`gc-scan` find stale entries) nor mechanics
(`mem demote` works whenever invoked) — it is **prioritization**: the forget-gate is
under-run when it competes with a primary task. That is the obvious first target for
the next refinement (e.g., have the protocol run the forget-gate *before* the task
when the auto block flags pressure), and this suite will show whether it moves.

Everything else is solid at this sample size: recall (with the mandatory-uncertainty
rule), promotion judgment, dead-end avoidance, in-flight reconciliation, and the
guard gates (no over-demotion, no junk promotion, no archive mutation) all 3/3.

## Caveats

- **n=3 is small.** A 3/3 is consistent with a true rate meaningfully below 100%;
  a 1/3 has a wide interval. Treat these as coarse. Raise `-n` for tighter bounds.
- Behavior is **stochastic** and model/effort/front-end dependent.
- Not a **live-compaction** test (hooks were exercised directly, not fired by a real
  PreCompact/Stop event).
- S4/S5 use **proxy** checks (see `README.md`).

## Reproduce

Per `evals/README.md` ("Running"): build each scenario with its `setup.sh`, run
your agent on `prompt.txt` against the dir (in a sandbox, with the permission
posture you choose), then aggregate with `./score.sh _work`. There is no
auto-runner; invoking the agent is deliberately left to you.
