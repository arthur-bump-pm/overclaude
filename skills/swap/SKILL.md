---
name: swap
description: "Claude account management: switch accounts (hot-swap all sessions), account/usage dashboard, revive a dead account token safely (relogin), add an account, auto/instant swap settings, artifact search, kit health check. Use ONLY when the user explicitly asks for one of these in their own words (e.g. 'swap me to work', 'my work account says relogin', 'check my setup')."
argument-hint: "[account] [handoff|restart|now|force] | add | relogin <account> | auto [on|off|status|instant on|off] [threshold N] [model X] | artifacts [words] [account X] | doctor [fix]"
allowed-tools: Bash(cswap *), Bash(swap-guard *), Bash(overclaude doctor), Bash(overclaude doctor *), Bash(bash *doctor.sh*)
---

GATE — read before acting. If this skill was invoked by you (the model) rather than typed by the user, first verify the user explicitly asked, in their own words in this conversation, for this account action (switch, relogin, add, auto/instant settings, artifacts search, doctor). Never invoke it on your own initiative — not after a usage-limit error (the instant-swap hook handles that) and not to "help" mid-task. If explicit consent is missing, STOP and ask. A dead account token is ALWAYS fixed with `swap-guard login <N>` (the relogin section) — never a plain `/login`, which kills the live account's token.

# /swap — Claude account switcher

## Context (auto-collected)

- Accounts and token health: !`cswap list --json`
- Other live sessions: !`swap-guard sessions`

## Parsing $ARGUMENTS

<!-- SHARED:RESERVED-WORDS BEGIN -->
Treat `$ARGUMENTS` as a token SET, not positions. Reserved keywords — `add`, `handoff`, `restart`, `now`, `force`, `status`, `cancel`, `history`, `restore`, `auto`, `doctor`, `relogin`, `artifacts` — are flags/subcommands wherever they appear; the first non-reserved token is the target account (slot number, email, or alias). An account aliased to a reserved word stays reachable via slot number or email — error messages must say so. Ignore redundant reserved tokens, with a brief note.
<!-- SHARED:RESERVED-WORDS END -->

Example: `/swap work handoff` ≡ `/swap handoff work`.

## Grammar

| Command | Effect | Guards |
|---|---|---|
| `/swap` | dashboard (accounts, usage, token health, live-session table); never switches | — |
| `/swap <target>` | hot-swap, session continues (default, ~90% of uses) | preflight |
| `/swap <target> force` | hot-swap bypassing busy guard | health gate only |
| `/swap <target> handoff [now] [force]` | delegate to `/handoff <target>`: preflight → package (+ artifact snapshot) → switch → flag + exit instructions | preflight |
| `/swap <target> restart [now] [force]` | preflight → switch → flag `{mode:"restart", sessionId}` → exit → wrapper `--resume <id>` | preflight |
| `/swap add` | register a new account without touching the live login (`swap-guard login --new`) | — |
| `/swap relogin <target>` | revive a dead token without killing the live account's (`swap-guard login <target>`) | browser sign-in |
| `/swap auto [on\|off\|status] [threshold N] [model X]` | busy-aware auto-switching LaunchAgent (opt-in) | defers proactive switches while sessions are busy |
| `/swap auto instant [on\|off]` | instant swap the moment a usage cap stops a session (default on) | dead/disabled/API-key accounts never targeted |
| `/swap artifacts [words] [account X]` | search every artifact you published, with its owning account | — |
| `/swap doctor [fix]` | health check of the whole kit, with fixes; `fix` applies the safe ones | — |
| `/handoff ...` | same-account handoff, `status`, `cancel`, `history`, `restore` — owned by the handoff skill, never duplicated here | — |

Edge rulings:
- `/swap <target> now` without `handoff`/`restart` → error: `now` only modifies handoff/restart.
- `/swap handoff` (no target) → error: "did you mean /handoff? For an account aliased 'handoff' use slot number/email."
- `auto` present → the remaining tokens are auto arguments (`on`/`off`/`status`/`instant`, `threshold <50-99.9>`, `model <names>`), never a target.
- `doctor` present → the only other meaningful token is `fix`; nothing after `doctor` is ever a target.
- `artifacts` present → the remaining tokens are search words (and `account <X>`), never a target.
- `relogin` takes the target account as its argument; it never switches.
- Target is already the active account → cswap returns reason `already-active`; report the no-op, do nothing else.
- Flag mode vocabulary matches the command names exactly: `{"mode":"handoff"}` and `{"mode":"restart","sessionId":...}` — never "fresh"/"resume" or other synonyms.

## Preflight recipe (byte-identical copy lives in the handoff skill)

<!-- SHARED:PREFLIGHT-RECIPE BEGIN -->
1. Run `swap-guard preflight <target>` and read `.verdict` from its JSON output.
2. If `unknown-target` → report `.detail` and stop. If `relogin-required` → REFUSE to switch; give the recovery recipe: `/swap relogin <N>` (runs `swap-guard login <N>`: saves the live account's token first, signs in inside a throwaway profile, registers slot N), then retry. Never suggest a plain `/login` + `cswap add`: signing in over the live account overwrites its newest token before cswap saved it, which kills the live account next. If `busy` and the `force` token was NOT given → STOP and show the `.busy` table (pid, sessionId, cwd, kind, entrypoint, status; missing status means possibly-busy); tell the user to re-run with `force` to override.
3. If `ok` (or `busy` overridden by `force`) → run `cswap switch <target> --json`, then report `.reason` and every entry of `.warnings[]` to the user.
<!-- SHARED:PREFLIGHT-RECIPE END -->

## `/swap` — dashboard

Render from the auto-collected context above, then stop. Never switch from the dashboard.
- Accounts table: slot number, alias, email, active marker, usageStatus/token health.
- Live-session table: pid, sessionId (first 8 chars), cwd, kind, entrypoint, status (missing status → show "unknown (possibly busy)").

## `/swap <target>` — hot-swap (default)

Run the preflight recipe. On a successful switch, confirm with exactly this shape, filled from the switch JSON and the sessions table:

> Switched <from> → <to> (slot <N>, <email>). reason: <reason>; warnings: <warnings[] or "none">.
> Blast radius: this flips ALL <count> live Claude Code sessions on this machine (every session in the table above) within ~30 s. Statusline updates within ~10 s; rate-limit bars lag until the new account serves a response.

The blast-radius line is mandatory in every hot-swap confirmation.

## `/swap <target> handoff [now] [force]`

1. INVOKE the handoff skill WITH the target, passing `now`/`force` through (`/handoff <target> [now] [force]`). It runs preflight steps 1–2, packages (including the artifact snapshot, which must happen while still on the owning account), THEN switches.
2. Do not run the preflight, switch, package, flag, or exit instructions yourself — that logic lives ONLY in the handoff skill.

## `/swap <target> restart [now] [force]`

1. Run the preflight recipe.
2. After a successful switch, get your own sessionId: `swap-guard whoami` → `.sessionId`.
3. Run `swap-guard flag '{"mode":"restart","sessionId":"<sessionId>"}'` with the actual id substituted.
4. Tell the user: exit with Ctrl+D — the shell wrapper relaunches `claude --resume <sessionId>` on the new account with full context (flag honored only in the same directory, within 300 s).
5. `now` token: run `swap-guard schedule-kill <pid>` (pid from `swap-guard whoami`). If it errors (v1 stub), say phase-2 is not enabled and fall back to the Ctrl+D instruction.

## `/swap auto [on|off|status] [threshold N] [model X]`

Opt-in background auto-switching: a LaunchAgent runs `swap-guard auto tick` every 3 min. Each tick asks `cswap auto` for a dry-run decision; a PROACTIVE switch (nearing the threshold) is deferred while any live session is busy, an AT-LIMIT switch proceeds (the account is stalled anyway), dead-token targets are skipped, and cswap's cooldown applies. (cswap's "failover" for unreadable usage needs 3 consecutive failures inside one long-running process, so the per-tick agent does not fail over.) Install validates the arguments and runs a probe tick that never switches; a bad value is refused up front. A macOS notification announces each switch.
- `on` → confirm the blast radius first ("switches flip ALL live sessions"), then run `swap-guard auto install` with `--threshold N` (if omitted, cswap's own threshold applies — 90 unless changed in cswap's settings) and `--model X` if given (suggest `--model Fable` when the scoped bucket is the usual wall). Report the JSON.
- `off` → `swap-guard auto uninstall`.
- `status` (default) → `swap-guard auto status`; render loaded yes/no and the recent ticks (ts, action, reason) as a table.
Note: a session paused at a usage limit does NOT resume by itself after a background switch — the user sends any message and it goes through on the new account.

### Instant swap (`/swap auto instant [on|off]`)
Independent of the LaunchAgent and ON by default: a StopFailure hook (`swap-guard ratelimit`) fires the moment a usage CAP stops a session ("You've reached your Fable limit"), picks the other account with the most room on that window (dead, disabled and API-key accounts are never targets), switches, sends a notification, and wakes the stopped session to continue (asyncRewake; each session at most once per 10 min, so a still-capped account cannot loop). A transient 429 throttle never swaps. Sessions that hit the cap together share one swap.
- `instant on` / `instant off` → `swap-guard auto instant on|off`; `instant` alone → `swap-guard auto instant status`.
- Recent instant-swap events appear in `swap-guard auto status` (entries with `"source":"ratelimit"`).

## `/swap doctor [fix]`

Run `overclaude doctor` (fallback: `bash "$(overclaude path)/doctor.sh"`). Relay the [FAIL]/[warn] lines with their fixes; offer to run any fix that is a plain command. With `fix`: run `overclaude doctor --fix` — it reinstalls drifted/missing kit files and hooks, reloads a stopped auto-swap agent, then re-checks. It cannot re-login dead tokens from here (that needs a browser): relay its `swap-guard login <N>` lines as `/swap relogin <N>` suggestions.

## `/swap relogin <target>` — revive a dead token safely

Why this exists: refresh tokens rotate and are single-use. A plain `/login` while another account is live overwrites that live account's newest token before cswap saved it, so the live account dies the next time it is polled — re-logging one account kills the other.

1. Tell the user a browser window will open and they must sign in as `<target>`'s email (from the accounts context).
2. Run `swap-guard login <target>` with a 10-minute Bash timeout. It saves the live account's token (`cswap add`), signs in inside a throwaway `CLAUDE_CONFIG_DIR` (the live login is never touched), checks the signed-in email, registers the slot, re-anchors cswap on the live account, and deletes the throwaway profile and its keychain item.
3. Report the JSON. Errors (nothing about the live account changed in any of them): `wrong-account` → the user signed in with a different email; `target-is-live` → the dead account IS the live one: `/login` inside Claude Code, then `cswap add`; `cswap-add-cancelled` → cswap wanted a y/N confirmation (usually an organization change) that only a terminal can answer — relay `.detail`, which names the exact command to run in a terminal (there the prompt reaches the user); `cswap-list-failed` → relay the detail; `ambiguous-target` → ask for the slot number; `unknown-target` → show the accounts table; `capture-failed` → the LIVE account's own token could not be saved, so nothing else was attempted — run `cswap list` to see why (often the live account itself needs `/login` + `cswap add`); `login-failed` → the browser sign-in did not complete, retry; `cswap-add-failed` → relay `.detail`; `cswap-not-found` / `claude-not-found` → run `overclaude doctor`. On success with `reanchored: false`, relay `.detail` (cswap may show the wrong active account until `cswap add` runs). If the command cannot open a browser from here, tell the user to run `swap-guard login <target>` in any terminal.

## `/swap add` — register a new account

1. Tell the user a browser window will open for the NEW account's sign-in. No `/logout` is needed and live sessions are unaffected.
2. Run `swap-guard login --new` with a 10-minute Bash timeout (same throwaway-profile flow as relogin; registers the next free slot and returns it as `.slot`). Errors as in relogin step 3.
3. `cswap alias <.slot> <name>` — optional; do not use a reserved word (`add`, `handoff`, `restart`, `now`, `force`, `status`, `cancel`, `history`, `restore`, `auto`, `doctor`, `relogin`, `artifacts`).

## `/swap artifacts [words] [account X]`

Run `swap-guard artifacts find <words>` (add `--account X` when given). Render a table: title, owner (the account that created it; `lastPublishedBy` if different), updated, URL, saved source (yes/no), and `republishedAs` when set. It returns the newest 20 matches — if there are 20, say more may exist and suggest narrower words. Entries with `inferredOwner: true` were backfilled from old transcripts — say the owner is inferred. If the list is empty and the user expects older artifacts, offer `swap-guard artifacts index` (one-time backfill from past transcripts).

## VS Code sessions

If `swap-guard whoami` reports `.entrypoint == "claude-vscode"`:
- Hot-swap works normally — the only fully-working mode in VS Code.
- `handoff`/`restart` degrade: there is no shell wrapper, so have the handoff skill write the package but NO flag, then tell the user: "handoff written — reload the VS Code window manually; the new session loads it automatically." For verbatim context instead, the user can run `claude --resume <sessionId>` in a terminal.

## Panic recipes

- Active account hard-limited (this session cannot complete even the /swap turn): tell the user to run `swap <target>` (shell alias for `cswap switch`) in ANY terminal; all live sessions adopt the new credential within ~30 s.
- Target token dead (preflight `relogin-required`): `/swap relogin <N>` (or `swap-guard login <N>` in a terminal), then retry the swap. Never a plain `/login`.
