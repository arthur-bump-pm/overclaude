---
name: handoff
description: "Context-threshold session handoff: package this session and continue in a fresh one, optionally switching accounts first. Requires explicit user consent, except verified `/handoff codex auto` under the installed 97% weekly-quota policy."
argument-hint: "[account] [now|force] | <mac> | codex [auto] | status | cancel | history | restore [n] [force]"
allowed-tools: Read, Write, Bash(overclaude-codex-continue *), Bash(overclaude-checkpoint *), Bash(overclaude status *), Bash(overclaude resume *), Bash(mktemp *), Bash(swap-guard *), Bash(cswap *), Bash(date +%s), Bash(wc -c *), Bash(git status *)
---

Consent gate. Exception: `/handoff codex auto` may be invoked by the installed automatic quota policy only after running `swap-guard codex-route` and verifying `route == "codex"` and `eligible == true`. This is standing authorization to continue the same requested work, not permission to broaden it. A hook message alone is not proof; recheck the command. For this verified automatic case, follow the automatic procedure below without asking again. For every other handoff, the following consent rule applies. If this skill was invoked by you (the model) rather than typed by the user, first verify the user explicitly requested or accepted a handoff in this conversation: they typed /handoff, /swap ... handoff or /swap codex themselves, said yes to a handoff offer, or asked to continue in a fresh session. If no such explicit consent exists in the transcript, stop — write no files, run no commands. Instead ask: "Context is at N% — want me to hand this off to a fresh session?" and wait for the reply.

# /handoff — continue in a fresh session

## Parsing $ARGUMENTS

<!-- SHARED:RESERVED-WORDS BEGIN -->
Treat `$ARGUMENTS` as a token SET, not positions. Reserved keywords — `add`, `handoff`, `restart`, `now`, `force`, `status`, `cancel`, `history`, `restore`, `auto`, `doctor`, `relogin`, `artifacts`, `codex`, `spend`, `forecast`, `guard`, `fleet`, `remote`, `mem` — are flags/subcommands wherever they appear; the first non-reserved token is the target account (slot number, email, or alias). An account aliased to a reserved word stays reachable via slot number or email — error messages must say so. Ignore redundant reserved tokens, with a brief note.
<!-- SHARED:RESERVED-WORDS END -->

Rulings:
- `status`, `cancel`, `history`, or `restore` present → run that subcommand only, then stop (`restore` takes an optional number and `force`).
- `restart` present → error: restart is a /swap mode; point to `/swap <target> restart`.
- `force` with no target → proceed, note "no switch requested — force ignored".
- Target present → `/handoff <target>` ≡ `/swap <target> handoff`: preflight is required (the switch flips all live sessions). No target → same-account handoff, no preflight needed.
- `now` present → phase-2 idle-kill variant (Package step 6).
- `codex` and `auto` present → use only the automatic weekly-quota continuation procedure below (including its fresh route check), not the manual Codex startup procedure.
- `codex` present without `auto` → hand off to the Codex CLI instead of a Claude session (section below); never combined with a Claude account target.
- Another Mac: `remote <mac>` always means a Mac. A bare target that is in `swap-guard fleet list` is a Mac too, unless `swap-guard preflight <target>` also knows it as an account (verdict other than `unknown-target`) — then ask "the Mac or the account?" and wait. A Mac handoff switches no account (that Mac runs on its own login) and never combines with `codex`, `now` or an account target.
- Flag mode vocabulary is exactly `{"mode":"handoff"}` — never "fresh" or other synonyms.

## `/handoff codex` — continue in Codex

For when every Claude account is out (or the user just wants Codex): the package goes where overcodex's Codex SessionStart hook loads it (same header, same 10-minute window). No account switch, no flag.

1. `swap-guard codex-ready` → if `.ready` is false, report `.detail` and stop (missing Codex CLI, overcodex not installed in that Codex home, or that Codex account at its limit).
2. Package steps 1 and 2b as usual (the artifact snapshot gives Codex local source files to read). Overwrite guard: if `swap-guard codex-ready` reports `.pending` with `ageSec` under 600, warn "a Codex handoff is already pending here (<N> min ago) — proceeding replaces it" and STOP until the user confirms. If `.limitsKnown` is false, say Codex's limits are unknown (no recent Codex session) and continue.
3. P = `swap-guard path codex-handoff`. Write the package to P with the same header line and template. Add this as the first line of `## Gotchas`: "Continuing in Codex CLI from a Claude Code session: Claude-only tools (Artifact publishing, Workflow, claude.ai connectors, /swap) are not available here. Artifact sources are the local files listed under Artifacts; republish them from Claude later." Keep the same ~8,000-byte budget.
4. Tell the user: exit this session, then in the SAME directory within 10 minutes run `codex "Continue from the handoff package."` — overcodex injects the package at startup. To come back to Claude later, type `$handoff-claude` in Codex — it writes a package this kit's SessionStart hook loads (overcodex 0.3+).

## `/handoff codex auto` — automatic weekly-quota continuation

This policy uses Claude first. The parent session checks `swap-guard codex-route`; only a verified `route: "codex", eligible: true` permits this procedure. At least two enabled Claude subscription accounts must each have decision-trusted, unexpired weekly usage at or above 97%. A reading is trusted for 180 seconds, or for at most 660 seconds while a successful vendor-scheduled poll is still pending with no recorded fetch error. Missing or untrusted usage is not exhaustion: refresh with `cswap list` and recheck once. If Claude has room, continue there using `/swap` preflight rules (an account switch still needs the user's request or the installed auto-swap); never force a busy/global credential switch. API-key and explicitly disabled accounts do not count. Codex must be logged in in the selected home and have no known unexpired exhausted window. Unknown Codex limits are disclosed and launch is attempted once; failures preserve the package.

1. Finish the current atomic step. Collect running agents' results and stop their writers before transferring ownership. Do not start another batch. Record unfinished jobs and exact resume points. Subagents return to their parent and never launch this procedure. Save a durable `/checkpoint` from the collected state before transfer when the checkpoint helper is available; include its returned ID in the handoff. A checkpoint does not start another session or replace this outbox package, and its history is independent of the ten-minute handoff TTL.
2. Run `swap-guard artifacts` and retain the manifest and saved local sources. Preserve any previously established approvals and constraints. Do not export account-only data without authorization.
3. Write a dedicated outbox file using `mktemp "${TMPDIR:-/tmp}/overclaude-codex-package.XXXXXX"`. Do **not** overwrite a pending startup handoff. Use the exact header below with the current absolute working directory and current epoch. Keep it under 16,000 bytes, ideally 8,000; write `None` for Files touched or Work in flight when empty; Goal, Current state, Next steps, Validation, and Codex execution plan must contain concrete guidance. Never include credentials or raw chat transcripts.

```markdown
<!-- handoff cwd="<absolute current directory>" created="<epoch>" -->
# Claude → Codex continuation — <concrete goal>
## Goal
Original request, acceptance criteria, scope, and user constraints.
## Current state
Completed work and evidence; remaining work; branch and dirty working tree.
## Decisions + rationale
Settled choices and their reasons, including rejected approaches worth retaining.
## Files touched
Exact paths and purpose; distinguish existing user edits from this session's edits.
## Work in flight
Agent results, stopped jobs, partial operations, blockers, exact resume points.
## Next steps
Ordered, concrete actions and expected outputs; preserve the original objective.
## Validation
Commands already run and actual results; required checks still outstanding.
## Codex execution plan
Task complexity and why; independent workstreams, dependencies, ownership, verification floors.
## Gotchas
Risks, known failures, approval boundaries, unavailable Claude-only tools.
## Artifacts
Manifest path, saved local sources, URLs and owners, or None.
## Session chain
Source session/transcript path if known; no more than the last three sessions.
```

4. Set complexity to `standard` for ordinary engineering; `complex` for difficult architecture, concurrency, security, migrations, or unresolved contradictions. Run `overclaude-codex-continue --package <path> --complexity <standard|complex> --dry-run` and inspect the selected Codex home/model/effort. The runner checks the destination's model catalog; it uses that home's configured default when no compatible catalog exists rather than guessing support. Report the destination and any unknown quota/model status briefly.
5. Run the same command without `--dry-run`. This runs `codex exec` with the full package on stdin and workspace-write sandbox, preserving a session and durable package/results. **Wait for it; Claude and its subagents must not edit concurrently.** Do not add bypass flags. If a task requires approval unavailable in a noninteractive run, Codex must report the blocker and preserve progress.
6. Inspect the returned run manifest and, when present, `final_message`. Relay Codex's actual result and validation evidence. A `finished` process is not a verified goal; missing final output must be reported. Use `overclaude status --run <saved-run> --json` for later inspection. On failure, report the saved run directory and error; do not automatically retry, duplicate work, claim completion, or silently switch accounts. If the user explicitly asks to resume, use `overclaude resume --run <saved-run> --dry-run` to validate the exact recorded session, then the same command without `--dry-run`. If identity or configuration checks refuse it, report the refusal; do not bypass it with `--last` or change accounts. Before any resumed action, reconcile partial operations and check whether external effects already happened. A live pending handoff blocks automatic launch until resolved.

The execution plan must tell Codex to read project AGENTS.md and use installed `$ultracode` when available. Complex tasks with independent streams should use native subagents with bounded objectives and disjoint ownership. Discover registered roles rather than assuming they exist: scout for inventory, worker for bounded implementation, independent reviewer for correctness/security, judge only for disputed evidence. Use the lowest-cost capable role while preserving verification floors. For each stage record its owner, expected artifact, objective checks, and independent audit verdict with evidence and limitations. Fix audit findings and rerun affected checks before advancing. Small sequential tasks stay serial. Preserve artifacts and evidence across the handoff; Claude-only tools need an explicit available replacement or a reported blocker.

At safe audited stage boundaries, save a checkpoint using `overclaude-checkpoint save --session <actual-id-or-unknown>`. Send a JSON object on stdin with the string keys `Goal`, `Current state`, `Decisions`, `Validation`, `Next steps`, `Work in flight`, and `Artifacts`. Record evidence and unfinished operations, not raw transcripts or secrets. Use explicit `unknown` provenance when the actual session ID is unavailable. Collect workers before claiming a consistent snapshot; never automatically commit or stash to create a checkpoint. If quota stops work before another save, only the last saved snapshot is available.

## `/handoff <mac>` — continue on another Mac

The package travels to a Mac registered with `overclaude fleet add`, together with the command that starts a background Claude session there with Remote Control; the user then drives it from claude.ai/code or the Claude app. This session stays as it is.

1. Package steps 1 and 2b as usual. Run `git status -sb`: if there are uncommitted or unpushed changes (or the branch has no upstream), tell the user the other Mac only sees what is pushed (and pulled there), and STOP until they say to go ahead (they may want to commit and push first). Not a git repo → just say the other Mac needs its own copy of this folder's files, and continue.
2. P = `swap-guard path remote-handoff` (an outbox; this Mac's own hook never loads it). Write the package to P with the same header line (this Mac's cwd; the other Mac rewrites it to its folder) and template, same ~8,000-byte budget. Add this as the first line of `## Gotchas`: "Continuing on <mac> from another Mac: files listed here (Files touched, artifact sources) are that Mac's paths; this Mac has only what was pushed to the repo — git pull first. Reach artifacts by their URLs."
3. Run `swap-guard remote handoff <mac>` (add `--dir <folder>` only when the user names the folder on that Mac; by default it is the same folder relative to home). Report `name` and `next`. If `injector` is false, say that Mac lacks overclaude's startup hook, so the session reads the package because its first message tells it to (`package` is the copy there).
4. Errors — relay `fix`: `pending-exists` → another handoff reached that folder there within 10 minutes; ask, then re-run with `--force`. `no-dir` → that folder doesn't exist there; ask for `--dir`. `untrusted` → the folder needs a one-time trust prompt there. `failed` → usually no `/login` login there. `unreachable` → SSH (Remote Login, `ssh-copy-id`). `timeout` → it may have started: run `swap-guard remote list <mac> --text`; if the session is not listed, re-run the same command (the same package may replace itself there). `stale-package` → the outbox is over an hour old: write the package again (step 2). On launch errors nothing is left pending there and the outbox stays here, so a retry needs no rewrite; after a successful start the outbox is removed.

## `/handoff status`

Run `swap-guard status`; render: context pct (null → "no relay yet"), thresholds fired/bannered, pending handoff path + age for this cwd (`.pendingHandoff`, `.pendingAgeSec`), newest archive path (`.latestArchive`). Doubles as the pipeline debug probe.

## `/handoff cancel`

Run `swap-guard cancel`; report exactly what it says was removed (pending package and/or flag for this cwd).

## `/handoff history`

Run `swap-guard history` (add `--all` if the user asks for every directory). Render a numbered table: n, title, archived time (local), expired yes/no, size. Empty → "no archived handoffs for this directory".

## `/handoff restore [n] [force]`

Recovers a package that expired (10-min TTL) or was injected into a session the user abandoned. Run `swap-guard restore [n]` (default n=1 = newest for this cwd; append `--force` only if the user gave `force`). Numbers refer to the THIS-directory listing; if the user picked from a `history --all` listing, restore by that entry's `.path` instead. Any pending package being replaced is moved to the archive first (`.replacedArchivedTo`) — mention it. On success it re-arms the package as this cwd's pending handoff with a fresh timestamp — then do Package steps 4–5 (flag + Ctrl+D instruction; VS Code: no flag, reload the window). On `.error`: `pending-exists` → say a live package is pending and offer `/handoff restore <n> force`; `cwd-mismatch` → tell the user to `cd` to `.packageCwd` first; `not-found` → show `/handoff history`; `malformed-header` → that archive's first line is damaged, so the injector would never load it — pick another entry or open the file and copy what is needed by hand.

## Switching (`/handoff <target> [now] [force]`)

Run recipe steps 1–2 first (the verdict gate). Run step 3 (the actual `cswap switch`) only after Package step 3 — the artifact snapshot and any db export must happen while this session is still on the account that owns those artifacts; the switch flips this session's credentials within ~30s.

<!-- SHARED:PREFLIGHT-RECIPE BEGIN -->
1. Run `swap-guard preflight <target>` and read `.verdict` from its JSON output.
2. If `unknown-target` → report `.detail` and stop. If `relogin-required` → refuse to switch (this includes a login past its end date); give the recovery recipe: `/swap relogin <N>` (runs `swap-guard login <N>`: saves the live account's token first, signs in inside a throwaway profile, registers slot N), then retry. Never suggest a plain `/login` + `cswap add`: signing in over the live account overwrites its newest token before cswap saved it, which kills the live account next. If `busy` and the `force` token was NOT given → stop and show the `.busy` table (pid, sessionId, cwd, kind, entrypoint, status; missing status means possibly-busy); tell the user to re-run with `force` to override. If `login-ending` → refuse to switch: the target's login ends within hours (`.detail` says when), so sessions moved there would stop then; relay `.detail` — renew first with `/swap relogin <N>`, then retry. `force` never overrides it.
3. If `ok` (or `busy` overridden by `force`) → run `cswap switch <target> --json`, then report `.reason` and every entry of `.warnings[]` to the user.
<!-- SHARED:PREFLIGHT-RECIPE END -->

## Package

1. Facts: `swap-guard whoami` → `.pid`, `.sessionId`, `.cwd`, `.entrypoint` (on error, use `$PWD` as cwd). `swap-guard path handoff` → target path P. `date +%s` → created.
2. Overwrite guard: `swap-guard status` → if `.pendingHandoff` is non-null and `.pendingAgeSec` < 600, warn: "another handoff pending for this cwd (<N> min ago) — proceeding replaces it" and STOP until the user confirms.
2b. Artifacts: run `swap-guard artifacts`. It reads this session's transcript (plus subagent/workflow transcripts), copies every published/touched artifact's source into `~/.claude-swap-backup/handoff-artifacts/<sessionId>/<artifact_id>/` (the scratchpad is session-scoped /tmp and dies with the session), and prints a manifest (`.account` = active account at collection time, `.artifacts[]` with `url`, `title`, `owner` (the account that published it, from the artifact registry; null if it predates the registry → assume `.account`), `saved`, `savedFiles`, `capabilities`). `saved: null` → source already gone; say so in the package. If switching to a DIFFERENT account:
   - Same link across accounts: artifacts are owned by the account that published them, and the new account can update one in place only if the owner shared it with edit access. For each still-in-play artifact whose owner is not the target account, tell the user once (optional, one click each, before or after the switch): "To keep <title> editable at the same link, open <url> → Share → Can edit → <target email>." Do not wait for an answer; note `share: asked` on that artifact's package line.
   - If an artifact has a `db` capability, ask the user whether to export its rows first; if yes, read them with ArtifactData now and write them as JSON next to `saved` (the new account cannot read them later).
3. Write the package to P with the Write tool. Line 1 of the file must be exactly this comment — first line, no blank line before it, `cwd` = the absolute cwd from step 1, `created` = the epoch integer from step 1:

```markdown
<!-- handoff cwd="<abs-cwd>" created="<epoch-int>" -->
# Handoff — <one-line goal>

## Goal
## Current state
## Decisions + rationale
## Files touched
## Work in flight
## Next steps
## Gotchas
## Artifacts
## Session chain
```

Fill every section from this conversation — concise and decision-dense; a summary, not a transcript. SIZE BUDGET: keep the whole package under ~8,000 bytes (≈8,000 English characters; Korean/CJK is ~3 bytes per character, so ≈2,700). Claude Code caps injected hook output at 10,000 characters; handoff-inject prints an over-budget package section by section in template order until the budget runs out, then points the next session at the full file — so the later sections (Gotchas, Artifacts, Session chain) are the ones that get deferred. Check with `wc -c <P>` after writing and tighten if over. Files touched: absolute paths. Artifacts (omit the section if the manifest is empty; list at most ~5 still-in-play artifacts individually and point to the manifest for the rest — the manifest, not the package, is the complete record): first line `Manifest: <manifest path> — owner: <.account>`, then one line per artifact `- <title> — <url> — owner: <owner> — source: <saved or "lost"> [— share: asked] [— db rows: <export path>]`, then this rule verbatim: "Next session: when work touches an artifact, first try to keep its link — Artifact read on its url: if the result says you are a writer (owner, or shared with edit access), update in place (publish with `url`). Otherwise republish from the saved source as a NEW artifact (re-import exported db rows with ArtifactData), run `swap-guard artifacts link <old-url> <new-url>` so the registry knows the copy, and give the user the new link. `swap-guard artifacts find <words>` finds any artifact published from this machine, with its owner and saved source." Work in flight: anything half-done, with exact resume points. Session chain rules: if this session itself began with "## Handoff from previous session (loaded by handoff-inject)", copy that package's Session chain entries first; append one line for THIS session: `<sessionId> — <transcript path if known, else "unknown"> — <YYYY-MM-DD>`; keep only the last 3 entries.

3b. If a target was given: run recipe step 3 now (`cswap switch <target> --json`, report `.reason` + `.warnings[]`).
4. Flag: run `swap-guard flag '{"mode":"handoff"}'` (it fills cwd and created). Skip this step in VS Code (below).
5. Tell the user: "Press Ctrl+D — the wrapper opens a fresh session with the handoff preloaded." Injection requires the same directory and happens only within 10 minutes; after that the package is archived as expired.
6. `now` token: phase-2 idle-kill is not built yet (`swap-guard schedule-kill` is a stub); say so and give the Ctrl+D instruction in step 5.

## VS Code degradation

If `.entrypoint == "claude-vscode"`: write the package (steps 1–3) but not the flag; tell the user to reload the VS Code window manually — the SessionStart injector loads the package in the new window's session.

## ctx-watch interplay

- The statusline relays context % after each turn. At thresholds 60/75/85, ctx-watch (UserPromptSubmit) injects a `[context-watch]` note telling you to OFFER /handoff after finishing the user's request, and ctx-notify (Stop) shows the passive banner `context N% — /handoff available`. These are prompts to make an offer — never consent; the GATE above governs.
- If the user declines or ignores an offer, drop the subject; the machinery re-fires only at the next threshold, and re-arms when context falls 10+ points below the last fired threshold (e.g. after a compact).
- ctx-watch skips prompts starting with `/handoff` or `/swap`, so running this skill never perturbs threshold state.
- Auto-compact at ~92% stays untouched as the last-resort backstop.
