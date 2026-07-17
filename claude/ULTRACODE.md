# ULTRACODE.md — Model & Effort Routing (v2, audited 2026-07 against Anthropic multi-agent research, MAST, router-collapse, solve-to-judge-gap literature)

## 1. Core principle
Spend fable only where judgment is the bottleneck, never where volume is: fable draws from a separate, much smaller rate-limit bucket, and omitting `opts.model` silently inherits it — every un-annotated `agent()` call is a fable spend.
Explicit down-routing is your default posture, not an optimization.
Route each agent by one question: "if this agent is quietly wrong, who catches it?" — a downstream check means you may downgrade; nobody means top tier.

## 2. Routing table
| Task class | Model | Effort | Why |
|---|---|---|---|
| Scouting / file-listing | haiku | low | mechanical |
| Bulk code reading / fact extraction | haiku (sonnet if dense) | low | extraction |
| Mechanical transforms (rename, dedup, format) | haiku | low | deterministic |
| Classify / extract into fixed `schema` | haiku (sonnet only if labels are ambiguous) | low | volume |
| Finder sweeps (bug / perf) | sonnet | medium | recall |
| Security sweeps | opus | high | asymmetry |
| Implementation edits (well-scoped) | sonnet | medium | authorship |
| Implementation edits (cross-cutting / tricky) | opus | high | judgment |
| Adversarial verification / refutation | opus | high | precision |
| Judge panel voters (2–3, distinct lenses) | opus | high | decorrelate |
| Judge chair / tie-break adjudicator | fable | xhigh | terminal |
| Completeness critics | opus | high | gaps |
| Final synthesis | fable (omit `model`) | xhigh | unrecoverable |

Pairing rules:
- Effort amplifies capability; it never substitutes — and it is non-monotonic: haiku@xhigh loses to sonnet@medium on judgment work, and overthinking degrades mechanical stages. Never pair xhigh with a fan-out stage.
- Multiply tier by fan-out width BEFORE picking a model — fine at width 3 is a budget event at width 20. Any `parallel()` wider than ~5 gets an explicit haiku/sonnet.
- **Reads parallelize; writes serialize.** `parallel()` is for search/read/test/evaluate over disjoint scope. Never two agents editing the same files or feature concurrently — concurrent writers conflict on unstated decisions. One owner per diff; merge independent reads into a single edit plan.
- Fan-out buys recall on INDEPENDENT scope, not compute on a coupled problem. For one hard, coupled task, escalate tier/effort on a single agent first — same tokens, fewer coordination failures.
- Buy recall with width (more cheap finders over disjoint files); buy precision with tier (one strong verifier). Upstream misses get caught downstream; a false CONFIRM does not.

## 3. Hard guardrails

Never downgrade (floors, not targets):
- Final synthesis, and ANY output the user sees without a downstream check: fable, never below opus. The trust boundary sets the floor, not the stage label.
- Adversarial verification, judge panels, security verdicts, completeness critics: opus floor. A false CONFIRM ends scrutiny — nothing checks the checker.
- Subtle-correctness verdicts (concurrency, auth/crypto, money math, data-loss migrations): fable. "Looks correct" and "is correct" diverge most here.

Verification order (cheapest reliable check first):
- Where the class has an OBJECTIVE check — tests, typecheck, lint, a numeric answer — gate on it via bash BEFORE spending an LLM verifier: cheap generator → deterministic gate → escalate tier only on fail. A passing test outranks an LLM CONFIRM.
- For fuzzy deliverables with no automatic check, verification is NOT easier than generation — buy a stronger generator, not a weak-generator-plus-judge pipeline.
- Verifier prompts get the diff/artifact plus a bare task statement — never the generator's reasoning trace. A clean-context reviewer re-derives from the code and catches what the author's context can't.

Escalation rule (what makes cheap-first safe):
- Give every finder/verifier a `schema` requiring `verdict` / `confidence` / `evidence`. Empty evidence IS low confidence, whatever number the agent reports.
- Re-run once at a HIGHER tier on: confidence < 0.7, UNSURE, empty/malformed output, or contradiction between parallel agents. The escalation target — and any verifier — must be ≥ the generator's tier: a weaker model cannot validate a stronger one's output.
- Escalation has a CEILING as well as floors: if more than ~1 in 4 downgraded stages escalates, the routing was miscalibrated — stop and re-author the script instead of silently running everything at the top tier.
- Panels are 2–3 voters with DISTINCT lenses (correctness / security / does-it-reproduce), never N identical voters — same-model repetition just re-votes the same error. Unanimous → accept; any split → one fable adjudicator; never majority-vote or average a split.
- Still UNSURE at the top tier? Surface it to the user. An honest "unresolved" is correct output; a manufactured verdict is a defect.

Budget pressure (`budget.remaining()` thin, or fable bucket ~75%+ consumed):
- Cut fan-out width and batch more files per agent FIRST; floors are the last thing to fall.
- Treat fable as a read-only reserve: one highest-leverage call only (usually synthesis).
- If the budget cannot cover the fable/opus terminal stages, say so and propose the cut — never silently ship a downgraded final answer.

## 4. Example
```js
pipeline(files,
  f  => agent(`List exports and structure of ${f}`,
          { model: 'haiku', effort: 'low', label: 'scout (haiku/low)' }),
  f  => agent(`Find bugs and perf issues in ${f}`,
          { model: 'sonnet', effort: 'medium', schema: findingSchema,
            label: 'find (sonnet/med)' }),                 // wide + cheap: recall
  fs => agent(`Run the test suite against each finding's claim, then adversarially
          verify only what tests can't decide; cite evidence`,
          { model: 'opus', effort: 'high', schema: verdictSchema,
            label: 'verify (opus/high)' })                 // objective gate first, then tier
);
// contested verdicts only — one strong judge beats re-voting the same error
const ruling = await agent(`Adjudicate the CONFIRM/REFUTE splits`,
  { model: 'fable', effort: 'xhigh', label: 'adjudicate (fable/xhigh)' });
// model omitted DELIBERATELY: terminal stage inherits fable
const report = await agent(`Synthesize the final review, ranked by severity`,
  { effort: 'xhigh', label: 'synthesize (fable/xhigh)' });
```
A workflow that never touches fable is a valid — often good — outcome. Omission of `opts.model` should be rare, counted, and load-bearing.

## 5. Routing lint (pre-flight — fix before dispatch, don't launch and patch)
1. Every `agent()` call has an explicit `model`, or its omission is a deliberate apex spend. More than 2 omissions in one script = under-routing, not an apex-heavy task.
2. No wide/parallel stage runs on opus or inherits fable; bulk stages sit at haiku/sonnet regardless of how the rest is routed.
3. Verifiers, judges, and synthesis are at their floors — even under budget pressure — and no parallel stage contains two writers to the same files.
4. Every downgraded trusted-adjacent stage has a wired escalation trigger (confidence / UNSURE / contradiction → higher-tier re-run), and an objective check gates before any LLM verifier where one exists.
5. Every subagent prompt states an objective + expected output shape + scope boundary vs sibling agents. A bare task label is a defect: sibling agents sharing a fuzzy prompt duplicate and miss work.
6. A pipeline stage is justified only if it accesses information the prior stage couldn't (a new tool call, a test run, an independent read). A stage that reformats or re-derives an upstream conclusion is overhead — collapse it into one higher-effort call.
7. `label` and `phase()` names embed the model tag (e.g. `verify (opus/high)`) — the user never opens the script to learn a stage ran on fable.

## 6. Scope
The same table binds the Agent tool's `model` param for one-off dispatches outside Workflow scripts: a lone bulk-reading agent is still a haiku job; a lone terminal judgment still earns opus or an intentional fable inheritance.
The absence of a `pipeline()`/`parallel()` wrapper does not relax the discipline.
