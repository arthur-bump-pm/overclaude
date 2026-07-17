---
name: handoff
description: "Context-threshold session handoff: package this session and continue in a fresh one, optionally switching accounts first. The model may invoke this skill ONLY after explicit user consent in the conversation."
argument-hint: "[account] [now|force] | status | cancel"
allowed-tools: Write, Bash(swap-guard *), Bash(cswap *)
---

GATE — read before acting. If this skill was invoked by you (the model) rather than typed by the user, first verify the user explicitly requested or accepted a handoff in this conversation: they typed /handoff or /swap ... handoff themselves, said yes to a handoff offer, or asked to continue in a fresh session. If no such explicit consent exists in the transcript, STOP — write no files, run no commands. Instead ask: "Context is at N% — want me to hand this off to a fresh session?" and wait for the reply.

# /handoff — continue in a fresh session

## Parsing $ARGUMENTS

<!-- SHARED:RESERVED-WORDS BEGIN -->
Treat `$ARGUMENTS` as a token SET, not positions. Reserved keywords — `add`, `handoff`, `restart`, `now`, `force`, `status`, `cancel` — are flags/subcommands wherever they appear; the first non-reserved token is the target account (slot number, email, or alias). An account aliased to a reserved word stays reachable via slot number or email — error messages must say so. Ignore redundant reserved tokens, with a brief note.
<!-- SHARED:RESERVED-WORDS END -->

Rulings:
- `status` or `cancel` present → run that subcommand only, then stop.
- `restart` present → error: restart is a /swap mode; point to `/swap <target> restart`.
- `force` with no target → proceed, note "no switch requested — force ignored".
- Target present → `/handoff <target>` ≡ `/swap <target> handoff`: preflight is MANDATORY (the switch flips ALL live sessions). No target → same-account handoff, no preflight needed.
- `now` present → phase-2 idle-kill variant (Package step 6).
- Flag mode vocabulary is exactly `{"mode":"handoff"}` — never "fresh" or other synonyms.

## `/handoff status`

Run `swap-guard status`; render: context pct (null → "no relay yet"), thresholds fired/bannered, pending handoff path + age for this cwd (`.pendingHandoff`, `.pendingAgeSec`), newest archive path (`.latestArchive`). Doubles as the pipeline debug probe.

## `/handoff cancel`

Run `swap-guard cancel`; report exactly what it says was removed (pending package and/or flag for this cwd).

## Switching first (`/handoff <target> [now] [force]`)

Run this recipe, then continue to Package:

<!-- SHARED:PREFLIGHT-RECIPE BEGIN -->
1. Run `swap-guard preflight <target>` and read `.verdict` from its JSON output.
2. If `unknown-target` → report `.detail` and stop. If `relogin-required` → REFUSE to switch; give the recovery recipe: run `/login` as the target account, then `cswap add --slot <N>` to refresh that slot's token, then retry. If `busy` and the `force` token was NOT given → STOP and show the `.busy` table (pid, sessionId, cwd, kind, entrypoint, status; missing status means possibly-busy); tell the user to re-run with `force` to override.
3. If `ok` (or `busy` overridden by `force`) → run `cswap switch <target> --json`, then report `.reason` and every entry of `.warnings[]` to the user.
<!-- SHARED:PREFLIGHT-RECIPE END -->

## Package

1. Facts: `swap-guard whoami` → `.pid`, `.sessionId`, `.cwd`, `.entrypoint` (on error, use `$PWD` as cwd). `swap-guard path handoff` → target path P. `date +%s` → created.
2. Overwrite guard: `swap-guard status` → if `.pendingHandoff` is non-null and `.pendingAgeSec` < 600, warn: "another handoff pending for this cwd (<N> min ago) — proceeding replaces it" and STOP until the user confirms.
3. Write the package to P with the Write tool. Line 1 of the file MUST be exactly this comment — first line, no blank line before it, `cwd` = the absolute cwd from step 1, `created` = the epoch integer from step 1:

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
## Session chain
```

Fill every section from this conversation — concise and decision-dense; a summary, not a transcript. Files touched: absolute paths. Work in flight: anything half-done, with exact resume points. Session chain rules: if this session itself began with "## Handoff from previous session (loaded by handoff-inject)", copy that package's Session chain entries first; append one line for THIS session: `<sessionId> — <transcript path if known, else "unknown"> — <YYYY-MM-DD>`; keep only the last 3 entries.

4. Flag: run `swap-guard flag '{"mode":"handoff"}'` (it fills cwd and created). Skip this step in VS Code (below).
5. Tell the user: "Press Ctrl+D — the wrapper opens a fresh session with the handoff preloaded." Injection requires the same directory and happens only within 10 minutes; after that the package is archived as expired.
6. `now` token: run `swap-guard schedule-kill <pid>` (pid from step 1). If it errors (v1 stub), say phase-2 is not enabled and fall back to the Ctrl+D instruction in step 5.

## VS Code degradation

If `.entrypoint == "claude-vscode"`: write the package (steps 1–3) but NOT the flag; tell the user to reload the VS Code window manually — the SessionStart injector loads the package in the new window's session.

## ctx-watch interplay

- The statusline relays context % after each turn. At thresholds 60/75/85, ctx-watch (UserPromptSubmit) injects a `[context-watch]` note telling you to OFFER /handoff after finishing the user's request, and ctx-notify (Stop) shows the passive banner `context N% — /handoff available`. These are prompts to make an offer — never consent; the GATE above governs.
- If the user declines or ignores an offer, drop the subject; the machinery re-fires only at the next threshold, and re-arms when context falls 10+ points below the last fired threshold (e.g. after a compact).
- ctx-watch skips prompts starting with `/handoff` or `/swap`, so running this skill never perturbs threshold state.
- Auto-compact at ~92% stays untouched as the last-resort backstop.
