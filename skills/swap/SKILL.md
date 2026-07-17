---
name: swap
description: "Switch between Claude accounts from inside Claude Code: hot-swap the live session (default), show the accounts + live-sessions dashboard, or carry work onto the new account via handoff/restart modes; also guides adding a new account."
argument-hint: "[account] [handoff|restart|now|force] | add"
disable-model-invocation: true
allowed-tools: Bash(cswap *), Bash(swap-guard *)
---

# /swap — Claude account switcher

## Context (auto-collected)

- Accounts and token health: !`cswap list --json`
- Other live sessions: !`swap-guard sessions`

## Parsing $ARGUMENTS

<!-- SHARED:RESERVED-WORDS BEGIN -->
Treat `$ARGUMENTS` as a token SET, not positions. Reserved keywords — `add`, `handoff`, `restart`, `now`, `force`, `status`, `cancel` — are flags/subcommands wherever they appear; the first non-reserved token is the target account (slot number, email, or alias). An account aliased to a reserved word stays reachable via slot number or email — error messages must say so. Ignore redundant reserved tokens, with a brief note.
<!-- SHARED:RESERVED-WORDS END -->

Example: `/swap work handoff` ≡ `/swap handoff work`.

## Grammar

| Command | Effect | Guards |
|---|---|---|
| `/swap` | dashboard (accounts, usage, token health, live-session table); never switches | — |
| `/swap <target>` | hot-swap, session continues (default, ~90% of uses) | preflight |
| `/swap <target> force` | hot-swap bypassing busy guard | health gate only |
| `/swap <target> handoff [now] [force]` | preflight → switch → invoke the handoff skill (package + flag + exit instructions) | preflight |
| `/swap <target> restart [now] [force]` | preflight → switch → flag `{mode:"restart", sessionId}` → exit → wrapper `--resume <id>` | preflight |
| `/swap add` | guided registration of a new account | /logout blast-radius warning |
| `/handoff ...` | same-account handoff, `status`, `cancel` — owned by the handoff skill, never duplicated here | — |

Edge rulings:
- `/swap <target> now` without `handoff`/`restart` → error: `now` only modifies handoff/restart.
- `/swap handoff` (no target) → error: "did you mean /handoff? For an account aliased 'handoff' use slot number/email."
- Target is already the active account → cswap returns reason `already-active`; report the no-op, do nothing else.
- Flag mode vocabulary matches the command names exactly: `{"mode":"handoff"}` and `{"mode":"restart","sessionId":...}` — never "fresh"/"resume" or other synonyms.

## Preflight recipe (byte-identical copy lives in the handoff skill)

<!-- SHARED:PREFLIGHT-RECIPE BEGIN -->
1. Run `swap-guard preflight <target>` and read `.verdict` from its JSON output.
2. If `unknown-target` → report `.detail` and stop. If `relogin-required` → REFUSE to switch; give the recovery recipe: run `/login` as the target account, then `cswap add --slot <N>` to refresh that slot's token, then retry. If `busy` and the `force` token was NOT given → STOP and show the `.busy` table (pid, sessionId, cwd, kind, entrypoint, status; missing status means possibly-busy); tell the user to re-run with `force` to override.
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

1. Run the preflight recipe (`force` applies to its busy step).
2. After a successful switch, INVOKE the handoff skill with no target, passing `now` through if present.
3. Do not write the package, flag, or exit instructions yourself — that logic lives ONLY in the handoff skill.

## `/swap <target> restart [now] [force]`

1. Run the preflight recipe.
2. After a successful switch, get your own sessionId: `swap-guard whoami` → `.sessionId`.
3. Run `swap-guard flag '{"mode":"restart","sessionId":"<sessionId>"}'` with the actual id substituted.
4. Tell the user: exit with Ctrl+D — the shell wrapper relaunches `claude --resume <sessionId>` on the new account with full context (flag honored only in the same directory, within 300 s).
5. `now` token: run `swap-guard schedule-kill <pid>` (pid from `swap-guard whoami`). If it errors (v1 stub), say phase-2 is not enabled and fall back to the Ctrl+D instruction.

## `/swap add` — register a new account

Warn FIRST and get explicit confirmation: `/logout` invalidates the shared credential for ALL live Claude Code sessions on this machine — do it at an idle moment.

1. Note the currently active slot `<back>` (from the accounts context) so you can return to it.
2. `/logout`.
3. `/login` — the user signs in as the NEW account.
4. `cswap add --json` — registers the new credential in the next free slot `<N>`.
5. `cswap alias <N> <name>` — optional; do not use a reserved word (`add`, `handoff`, `restart`, `now`, `force`, `status`, `cancel`).
6. `cswap switch <back> --json` — return to the original account, or skip to stay on the new one.

## VS Code sessions

If `swap-guard whoami` reports `.entrypoint == "claude-vscode"`:
- Hot-swap works normally — the only fully-working mode in VS Code.
- `handoff`/`restart` degrade: there is no shell wrapper, so have the handoff skill write the package but NO flag, then tell the user: "handoff written — reload the VS Code window manually; the new session loads it automatically." For verbatim context instead, the user can run `claude --resume <sessionId>` in a terminal.

## Panic recipes

- Active account hard-limited (this session cannot complete even the /swap turn): tell the user to run `swap <target>` (shell alias for `cswap switch`) in ANY terminal; all live sessions adopt the new credential within ~30 s.
- Target token dead (preflight `relogin-required`): `/login` as the target account, then `cswap add --slot <N>`, then retry the swap.
