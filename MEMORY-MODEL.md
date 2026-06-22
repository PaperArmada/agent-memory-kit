# Tiered Agent Memory: Design Foundation

## What this is

A design for durable, actively-maintained agent memory that complements (does not replace) Claude Code's lossy compaction summaries. It extends the checkpoint hook in this kit from a structural snapshot into a small memory *system* with explicit write, forget, and recall rules.

The problem it solves: a compaction summary is a lossy compression of a *conversation*. It reliably loses the load-bearing semantics for long-term coherency: why a decision was made, what approaches were tried and abandoned, what invariants hold. This design moves that content out of the conversation and into files governed by rules, so it survives compaction and accumulates coherently across sessions.

## The one constraint that shapes everything

**A hook cannot synthesize semantic content.** A hook is a shell command; distilling "the live hypothesis is X" requires a model turn, which a hook cannot summon. Therefore:

- Semantic memory can only be written *by the agent, during a turn*.
- The crash case (kill, SIGKILL, power loss) cannot be captured at the moment it happens. SessionEnd hooks are best-effort and run nothing on a hard kill.
- The only defense against crash loss is **frequency**: consolidate often and cheaply so the last persisted state is always recent. You do not reconstruct memory at the moment of loss; you ensure it was current a moment before.

This is the LSTM intuition: you never recover the cell state at power-off, you keep updating it so its last value is good.

## Three tiers, three gates

Memory is split by volatility. Each tier has a different write rule and lifetime. The three LSTM gates become three mechanical moves between tiers.

| Tier | File | Volatility | Owner | Bound |
|---|---|---|---|---|
| **Working set** | `memory/working-set.md` | seconds | agent, replace-in-place | small, never grows |
| **Ledger** | `memory/ledger.md` | per-decision | agent, consolidated | small, GC'd by demotion |
| **Archive** | `memory/archive.md` | permanent | append-only | unbounded |

Plus the **structural auto block** at the top of `working-set.md`: machine-written by the checkpoint hook (time, git, status, memory-pressure signal). It is the cheap "where," not the "why," and is never hand-edited.

### Input gate — promote (working-set → ledger)

Not everything earns long-term storage. One general test, applied by the agent at consolidation time, not an enumerated schema:

> Would a cold-start agent with no context make a *worse decision* without this fact?

Things that pass: decisions and their rationale, approaches tried and abandoned (with why), invariants and constraints, open questions. Things that fail: play-by-play narration, restating the current diff, anything obvious and trivially re-derivable from the repo. Failed items stay in the working set and are overwritten there.

### Forget gate — demote (ledger → archive)

Garbage collection is **demotion, not deletion**. A ledger entry that is superseded, refers to code that no longer exists, or has gone unreferenced across several consolidations, moves to the archive. It is preserved (still searchable) but no longer auto-loaded.

GC is a reflective pass the agent runs, because "still load-bearing?" is a judgment. Decay (time since referenced, surfaced as a count in the auto block) is only a cheap *prior* that tells the agent *when* to run the pass, not *what* to evict.

### Output gate — recall (archive → context, scoped)

The archive (`memory/archive.md`) is a *curated* store: each entry was once a ledger fact (it passed the salience gate) and was later demoted. It is small and high-signal relative to its size, and it grows without bound *because it is never loaded wholesale*. Recall is query-scoped, two-mode:

- **No indexer:** `recall.sh "<terms>"` greps `archive.md` (and the ledger) and returns whole matching entries. Always available.
- **Indexer present:** the same archive is additionally reachable by semantic search.

**Not to be confused with the raw session transcript.** The archive is curated, distilled facts; the transcript is every turn verbatim. They are different things at different granularities. When an indexer is present it also exposes the transcript (`search_turns`) as a *deeper, out-of-band fallback*: the ground-truth record to consult only when even the curated archive lacks a specific detail. That transcript is not a tier this kit manages; it exists whether or not the kit is installed. The kit owns the curated `archive.md`; the transcript sits below it as a last resort.

This is what resolves the "no unbounded memory without GC" objection: GC pressure exists *only* on the always-loaded hot tiers. The cold store is exempt because the output gate, not deletion, is what keeps it from flooding context.

**The archive is append-only and immutable.** Demotion *appends*; it never rewrites. Existing archive entries are never edited, never pruned, never corrected in place (a correction is a new entry that supersedes an old one by id). This is deliberate: the archive is the record of what was actually believed and when, and it is the substrate a future learning loop would train on. Editing or pruning it taints that signal. Unbounded growth is the intended cost of an untainted record, and it is affordable precisely because nothing here is auto-loaded.

## Why GC pressure lands only on the hot tier

The thing you do not want unbounded is *what you pay for every turn* (auto-loaded context). That is the working set and ledger, both kept small by overwrite and demotion. The thing that is fine to keep forever is a store you only touch by query. Separating the two by an output gate lets each have the property it needs: the hot tier is bounded, the cold tier is durable.

## On self-adaptation and the Bitter Lesson (honest scope)

The aim is to avoid hand-enumerating "capture fields X, Y, Z" and instead give the memory a single general objective and let a capable model maintain it:

> Keep the minimal set of facts that maximizes a cold-start agent's coherency. Evict (demote) the rest.

The agent shapes its own ledger categories against that objective, so the file's structure adapts to the project rather than being fixed by us. The seed scaffolds are deliberately under-specified for this reason.

What this is **not**: learned adaptation. There is no reward signal and no cross-session training loop, so a flat file cannot *learn* what to retain. It executes general judgment, which is Bitter-Lesson-adjacent (general method over hand-crafted taxonomy) but not the same thing. True need-anticipating adaptation would require an outer loop over the indexed history, scoring which retained facts actually got used on later cold starts and adjusting the retention objective. That is a separate, later layer built on the archive, not a property a file gives for free. Keeping the schema minimal and the judgment general is what keeps this design on the right side of the lesson until that loop exists.

## Lifecycle summary

1. **Every meaningful step:** agent overwrites the working set (current task, live hypothesis, next step, blockers). Cheap, frequent. This is what bounds crash loss.
2. **At decision/task boundaries (PreCompact reminds, cannot force):** consolidate. Apply the input gate. Promote salient items to the ledger.
3. **When the auto block reports ledger pressure:** run the forget-gate pass. Demote stale entries to the archive.
4. **On resume (session start / post-compaction):** read the auto block, then the working set, then the relevant ledger entries. Recall from the archive by query only when a specific lost detail is needed.

The hook guarantees step 1's structural envelope is always fresh and reminds at step 2. Steps 1-3's semantic content and step 4's reading are agent acts, by design, because nothing else can perform them.
