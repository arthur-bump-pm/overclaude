---
name: handoff
description: "Context-threshold session handoff: package this session and continue in a fresh one, optionally switching accounts first. The model may invoke this skill ONLY after explicit user consent in the conversation."
argument-hint: "[account] [now|force] | status | cancel | history | restore [n] [force]"
allowed-tools: Write, Bash(swap-guard *), Bash(cswap *), Bash(date +%s), Bash(wc -c *)
---

GATE — read before acting. If this skill was invoked by you (the model) rather than typed by the user, first verify the user explicitly requested or accepted a handoff in this conversation: they typed /handoff or /swap ... handoff themselves, said yes to a handoff offer, or asked to continue in a fresh session. If no such explicit consent exists in the transcript, STOP — write no files, run no commands. Instead ask: "Context is at N% — want me to hand this off to a fresh session?" and wait for the reply.

# /handoff — continue in a fresh session

## Parsing $ARGUMENTS

<!-- SHARED:RESERVED-WORDS BEGIN -->
Treat `$ARGUMENTS` as a token SET, not positions. Reserved keywords — `add`, `handoff`, `restart`, `now`, `force`, `status`, `cancel`, `history`, `restore`, `auto`, `doctor`, `relogin`, `artifacts` — are flags/subcommands wherever they appear; the first non-reserved token is the target account (slot number, email, or alias). An account aliased to a reserved word stays reachable via slot number or email — error messages must say so. Ignore redundant reserved tokens, with a brief note.
<!-- SHARED:RESERVED-WORDS END -->

Rulings:
- `status`, `cancel`, `history`, or `restore` present → run that subcommand only, then stop (`restore` takes an optional number and `force`).
- `restart` present → error: restart is a /swap mode; point to `/swap <target> restart`.
- `force` with no target → proceed, note "no switch requested — force ignored".
- Target present → `/handoff <target>` ≡ `/swap <target> handoff`: preflight is MANDATORY (the switch flips ALL live sessions). No target → same-account handoff, no preflight needed.
- `now` present → phase-2 idle-kill variant (Package step 6).
- Flag mode vocabulary is exactly `{"mode":"handoff"}` — never "fresh" or other synonyms.

## `/handoff status`

Run `swap-guard status`; render: context pct (null → "no relay yet"), thresholds fired/bannered, pending handoff path + age for this cwd (`.pendingHandoff`, `.pendingAgeSec`), newest archive path (`.latestArchive`). Doubles as the pipeline debug probe.

## `/handoff cancel`

Run `swap-guard cancel`; report exactly what it says was removed (pending package and/or flag for this cwd).

## `/handoff history`

Run `swap-guard history` (add `--all` if the user asks for every directory). Render a numbered table: n, title, archived time (local), expired yes/no, size. Empty → "no archived handoffs for this directory".

## `/handoff restore [n] [force]`

Recovers a package that expired (10-min TTL) or was injected into a session the user abandoned. Run `swap-guard restore [n]` (default n=1 = newest for this cwd; append `--force` only if the user gave `force`). Numbers refer to the THIS-directory listing; if the user picked from a `history --all` listing, restore by that entry's `.path` instead. Any pending package being replaced is moved to the archive first (`.replacedArchivedTo`) — mention it. On success it re-arms the package as this cwd's pending handoff with a fresh timestamp — then do Package steps 4–5 (flag + Ctrl+D instruction; VS Code: no flag, reload the window). On `.error`: `pending-exists` → say a live package is pending and offer `/handoff restore <n> force`; `cwd-mismatch` → tell the user to `cd` to `.packageCwd` first; `not-found` → show `/handoff history`; `malformed-header` → that archive's first line is damaged, so the injector would never load it — pick another entry or open the file and copy what is needed by hand.

## Switching (`/handoff <target> [now] [force]`)

Run recipe steps 1–2 NOW (the verdict gate). Run step 3 (the actual `cswap switch`) only AFTER Package step 3 — the artifact snapshot and any db export must happen while this session is still on the account that owns those artifacts; the switch flips this session's credentials within ~30s.

<!-- SHARED:PREFLIGHT-RECIPE BEGIN -->
1. Run `swap-guard preflight <target>` and read `.verdict` from its JSON output.
2. If `unknown-target` → report `.detail` and stop. If `relogin-required` → REFUSE to switch; give the recovery recipe: `/swap relogin <N>` (runs `swap-guard login <N>`: saves the live account's token first, signs in inside a throwaway profile, registers slot N), then retry. Never suggest a plain `/login` + `cswap add`: signing in over the live account overwrites its newest token before cswap saved it, which kills the live account next. If `busy` and the `force` token was NOT given → STOP and show the `.busy` table (pid, sessionId, cwd, kind, entrypoint, status; missing status means possibly-busy); tell the user to re-run with `force` to override.
3. If `ok` (or `busy` overridden by `force`) → run `cswap switch <target> --json`, then report `.reason` and every entry of `.warnings[]` to the user.
<!-- SHARED:PREFLIGHT-RECIPE END -->

## Package

1. Facts: `swap-guard whoami` → `.pid`, `.sessionId`, `.cwd`, `.entrypoint` (on error, use `$PWD` as cwd). `swap-guard path handoff` → target path P. `date +%s` → created.
2. Overwrite guard: `swap-guard status` → if `.pendingHandoff` is non-null and `.pendingAgeSec` < 600, warn: "another handoff pending for this cwd (<N> min ago) — proceeding replaces it" and STOP until the user confirms.
2b. Artifacts: run `swap-guard artifacts`. It reads this session's transcript (plus subagent/workflow transcripts), copies every published/touched artifact's source into `~/.claude-swap-backup/handoff-artifacts/<sessionId>/<artifact_id>/` (the scratchpad is session-scoped /tmp and dies with the session), and prints a manifest (`.account` = active account at collection time, `.artifacts[]` with `url`, `title`, `owner` (the account that published it, from the artifact registry; null if it predates the registry → assume `.account`), `saved`, `savedFiles`, `capabilities`). `saved: null` → source already gone; say so in the package. If switching to a DIFFERENT account:
   - Same link across accounts: artifacts are owned by the account that published them, and the new account can update one in place only if the owner shared it with edit access. For each still-in-play artifact whose owner is not the target account, tell the user once (optional, one click each, before or after the switch): "To keep <title> editable at the same link, open <url> → Share → Can edit → <target email>." Do not wait for an answer; note `share: asked` on that artifact's package line.
   - If an artifact has a `db` capability, ask the user whether to export its rows first; if yes, read them with ArtifactData now and write them as JSON next to `saved` (the new account cannot read them later).
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
## Artifacts
## Session chain
```

Fill every section from this conversation — concise and decision-dense; a summary, not a transcript. SIZE BUDGET: keep the whole package under ~8,000 bytes (≈8,000 English characters; Korean/CJK is ~3 bytes per character, so ≈2,700). Claude Code caps injected hook output at 10,000 characters; handoff-inject prints an over-budget package section by section in template order until the budget runs out, then points the next session at the full file — so the later sections (Gotchas, Artifacts, Session chain) are the ones that get deferred. Check with `wc -c <P>` after writing and tighten if over. Files touched: absolute paths. Artifacts (omit the section if the manifest is empty; list at most ~5 still-in-play artifacts individually and point to the manifest for the rest — the manifest, not the package, is the complete record): first line `Manifest: <manifest path> — owner: <.account>`, then one line per artifact `- <title> — <url> — owner: <owner> — source: <saved or "lost"> [— share: asked] [— db rows: <export path>]`, then this rule verbatim: "Next session: when work touches an artifact, first try to keep its link — Artifact read on its url: if the result says you are a writer (owner, or shared with edit access), update in place (publish with `url`). Otherwise republish from the saved source as a NEW artifact (re-import exported db rows with ArtifactData), run `swap-guard artifacts link <old-url> <new-url>` so the registry knows the copy, and give the user the new link. `swap-guard artifacts find <words>` finds any artifact published from this machine, with its owner and saved source." Work in flight: anything half-done, with exact resume points. Session chain rules: if this session itself began with "## Handoff from previous session (loaded by handoff-inject)", copy that package's Session chain entries first; append one line for THIS session: `<sessionId> — <transcript path if known, else "unknown"> — <YYYY-MM-DD>`; keep only the last 3 entries.

3b. If a target was given: run recipe step 3 now (`cswap switch <target> --json`, report `.reason` + `.warnings[]`).
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
