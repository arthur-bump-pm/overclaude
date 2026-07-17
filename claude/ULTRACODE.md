# ULTRACODE.md — Model & Effort Routing

## 1. Core principle
Spend fable only where judgment is the bottleneck, never where volume is: fable draws from a separate, much smaller rate-limit bucket, and omitting `opts.model` silently inherits it — every un-annotated `agent()` call is a fable spend.
Explicit down-routing is your default posture, not an optimization.
Route each agent by one question: "if this agent is quietly wrong, who catches it?" — a downstream agent means you may downgrade; nobody means top tier.

## 2. Routing table
| Task class | Model | Effort | Why |
|---|---|---|---|
| Scouting / file-listing | haiku | low | mechanical |
| Bulk code reading / fact extraction | haiku (sonnet if dense) | low | extraction |
| Mechanical transforms (rename, dedup, format) | haiku | low | deterministic |
| Classify / extract into fixed `schema` | sonnet | low | ambiguity |
| Finder sweeps (bug / perf) | sonnet | medium | recall |
| Security sweeps | opus | high | asymmetry |
| Implementation edits (well-scoped) | sonnet | medium | authorship |
| Implementation edits (cross-cutting / tricky) | opus | high | judgment |
| Adversarial verification / refutation votes | opus | high | precision |
| Judge panel voters | opus | high | arbitration |
| Judge chair / tie-break adjudicator | fable | xhigh | terminal |
| Completeness critics | opus | high | gaps |
| Final synthesis | fable (omit `model`) | xhigh | unrecoverable |

Pairing rules:
- Effort amplifies capability; it never substitutes. haiku@xhigh loses to sonnet@medium on judgment work; never pair xhigh with a fan-out stage.
- Multiply tier by fan-out width BEFORE picking a model — fine at width 3 is a budget event at width 20. Any `parallel()` wider than ~5 gets an explicit haiku/sonnet.
- Buy recall with width (more cheap finders over disjoint files); buy precision with tier (one strong verifier). Upstream misses get caught downstream; a false CONFIRM does not.
- Width unknown until runtime? Route for the upper end of plausible width.

## 3. Hard guardrails

Never downgrade (floors, not targets):
- Final synthesis, and ANY output the user sees without a downstream agent re-check: fable, never below opus. The trust boundary sets the floor, not the stage label.
- Adversarial verification, judge panels, security verdicts, completeness critics: opus floor. A false CONFIRM ends scrutiny — nothing checks the checker.
- Subtle-correctness verdicts (concurrency, auth/crypto, money math, data-loss migrations): fable. "Looks correct" and "is correct" diverge most here.

Escalation rule (what makes cheap-first safe):
- Give every finder/verifier a `schema` requiring `verdict` / `confidence` / `evidence`. Empty evidence IS low confidence, whatever number the agent reports.
- Re-run once at a higher tier on: confidence < 0.7, UNSURE, empty/malformed output, or contradiction between parallel agents.
- A CONFIRM/REFUTE split among voters escalates to one fable adjudicator — never majority-vote or average it; the split itself signals the question is hard.
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
  fs => agent(`Adversarially verify each finding; cite evidence; drop false positives`,
          { model: 'opus', effort: 'high', schema: verdictSchema,
            label: 'verify (opus/high)' })                 // narrow + strong: precision
);
// contested verdicts only — one strong judge beats five weak votes
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
3. Verifiers, judges, and synthesis are at their floors — even under budget pressure.
4. Every downgraded trusted-adjacent stage has a wired escalation trigger (confidence / UNSURE / contradiction → higher-tier re-run).
5. `label` and `phase()` names embed the model tag (e.g. `verify (opus/high)`) — the user never opens the script to learn a stage ran on fable.

## 6. Scope
The same table binds the Agent tool's `model` param for one-off dispatches outside Workflow scripts: a lone bulk-reading agent is still a haiku job; a lone terminal judgment still earns opus or an intentional fable inheritance.
The absence of a `pipeline()`/`parallel()` wrapper does not relax the discipline.
