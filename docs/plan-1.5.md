# overclaude 1.5 plan — logins that stay alive, and a fleet of Macs

Status: 🚧 in progress (plan written 2026-10-12).

Two goals:

1. **Logins never die by accident.** No more surprise "please log in again" on an account you haven't used in a while.
2. **Several Macs work as one setup.** This Mac (the *hub*) can see, start and steer Claude sessions on other Macs (*workers*) over Tailscale. The same accounts can be used on every Mac.

## What this rests on (checked 2026-10-12)

| Fact | Source |
|---|---|
| A normal login (`/login`) holds a short access token (about 8 h) and a refresh token. Each refresh hands back a **new** refresh token, so a login that keeps getting refreshed never expires. A refresh token that is used twice, or copied to a second machine, dies on both. | cswap `oauth.py`; the 1.3 token-death investigation |
| cswap refreshes only **inactive** accounts, and only when their usage is fetched while their access token is expired. The **active** account is refreshed by Claude Code itself, and only while Claude Code is running. Nothing refreshes anything when no session is open. | `vendor/claude-swap/src/claude_swap/oauth.py` (`try_fetch_usage_for_account`) |
| `claude setup-token` gives a **one-year token** for the `CLAUDE_CODE_OAUTH_TOKEN` environment variable. It prints the token and saves it nowhere. It needs a Pro/Max/Team/Enterprise plan. It **can only make model requests**: no Remote Control, no claude.ai connectors, and (inferred) no usage figures. The docs describe no rotation. | code.claude.com/docs/en/authentication |
| `CLAUDE_CODE_OAUTH_TOKEN` takes priority over the keychain login. | same page, "Authentication precedence" |
| Remote Control (`claude --remote-control [name]`, `/rc`, or server mode `claude remote-control --name`) lets claude.ai/code and the phone app drive a session running on a Mac. It **needs a `/login` login** (a setup-token does not work). It stops when that login expires. Over SSH, run it inside tmux/screen. Session names default to `<hostname>-<words>`. | code.claude.com/docs/en/remote-control |
| `claude --bg` starts a session in the background; `claude attach / logs / stop` and `claude agents` manage it. | `claude --help` (2.1.296) |
| The `StopFailure` hook fires when a turn ends on an API error, with `error` = `server_error`, `overloaded`, `rate_limit`, … Its output is **ignored**, so it cannot make Claude retry by itself. `asyncRewake` (a background hook that wakes Claude when it exits 2) exists. Whether it is accepted on `StopFailure` is not documented. | code.claude.com/docs/en/hooks |
| Subscription logins are meant for "ordinary, individual usage". Building a service for other people needs an API key. Personal scripted use of your own setup-token is documented ("for CI pipelines and scripts"). | code.claude.com/docs/en/legal-and-compliance |

## Ground rules

- **Never copy a login between machines.** Every Mac logs in to every account it uses on its own. Usage limits are per account, so they are shared across Macs.
- **Never automate the browser consent page.** A re-login is always a person clicking Approve. overclaude only makes that one click quick, and tells you when it is needed.
- **Your own accounts, your own Macs.** The fleet runs your own work. It is not a way to share an account with other people.
- **Tokens never appear on screen or in a file.** They live in the macOS keychain.

## Phase 0: tests to run before writing code

| # | Question | Why it matters |
|---|---|---|
| S1 | How long does a refresh token last when nothing uses it? Leave a test slot untouched and look at it at 1, 3, 7 and 14 days. | Sets the keepalive interval. Until it is known, refresh every 2 h. |
| S2 | Can `claude setup-token` run with its output going through a filter (`script -q` or a pty) while you still see the browser prompt, and can that filter catch the token? | `swap-guard token add` depends on this. |
| S3 | Does a setup-token answer the usage endpoint? (Expected no.) | Decides whether workers on setup-tokens can report their own usage. |
| S4 | Can a worker log in over SSH? Run `claude` → `/login` in tmux on a worker, open the URL on the hub, paste the code back. | `swap-guard login N --host`. |
| S5 | Does `asyncRewake` work on `StopFailure`? | Auto-resume after server errors. |
| S6 | `claude --bg --remote-control <name>` over SSH: does the session show up in claude.ai/code, and survive the SSH connection closing? | `/remote` can skip tmux if yes. |

## Phase 1: logins that stay alive (this Mac)

**1a. Keepalive job.** `swap-guard keepalive install|uninstall|status` adds a launchd agent that runs every 2 h and fetches usage for every slot. That refreshes every inactive account whose access token has expired, which keeps its refresh token alive. It reuses the launchd plumbing of `swap-guard auto install` (pinned PATH, plutil lint, probe tick before install) and runs nothing else: no auto-swap. `install.sh` offers it, and doctor reports the last tick.

**1b. Idle active account.** The active account is only refreshed while Claude Code runs. If no `claude` process has run for more than about 3 days, the keepalive refreshes the active account too, through cswap's consume gate under the slot lock, and only if `pgrep` still finds no `claude` both before and after. This is the riskiest piece in the release (a race would kill the login). It gets its own test and a fable-level review before it ships, and it can be switched off with `SWAP_KEEPALIVE_ACTIVE=0`.

**1c. Dead-login alert.** When a refresh comes back `invalid_grant` (revoked, or a refresh token used twice), you get one macOS notification per account per day: "work needs a new login — run `swap-guard login 2`". The statusline shows `⚠ login` next to that account until it is fixed. Doctor prints the same.

**1d. Long-lived tokens.** `swap-guard token add N` runs `claude setup-token` for slot N's account, catches the token in the output and stores it in the keychain as `overclaude-token-<slot>`, without ever printing it (depends on S2). `token list` shows slot, account, created date and days left, never the token. `token rm N` removes it. `swap-guard run --token N -- <cmd>` runs a command with `CLAUDE_CODE_OAUTH_TOKEN` set from the keychain. Doctor warns 30 days before a token expires. These tokens are for headless jobs and workers (Phase 5). Interactive sessions keep using `/login` logins, because only those can hot-swap, read usage and use Remote Control.

Tests: `tests/test_keepalive.sh` (stub cswap; refresh only when expired; active account untouched while a `claude` stub runs; alert rate limit), `tests/test_token.sh` (stub `security` and `claude setup-token`; the token never reaches stdout, stderr or logs).

## Phase 2: fleet link and status

- `overclaude fleet add <tailscale-name>`: checks that SSH works without a password and that overclaude is installed on the worker, and records the overclaude version and the accounts logged in there. The list is saved in `~/.claude/overclaude/fleet.json` (host names only, no secrets).
- `overclaude fleet status`: one line per Mac showing online or offline, overclaude version, logged-in accounts, running sessions (`claude agents`), and free memory and CPU load. Hosts are queried in parallel with a 5 s timeout.
- Statusline: an optional `↳ fleet 3 macs · 5 sessions` line, from a cache that a background job refreshes. The statusline never waits on SSH.
- Doctor: `fleet` section (SSH, versions behind the hub, a worker with a dead login).
- Setup per worker, done once by you: `sudo tailscale set --ssh` (or Remote Login with a key), `pipx install overclaude && overclaude install`, then log in to the accounts that Mac should use.

## Phase 3: accounts across the fleet

- **The hub is where usage is read.** Limits are per account, so the hub's cswap figures cover every Mac. Workers do not need to fetch usage, and workers on setup-tokens cannot.
- **Worker re-login from the hub.** `swap-guard login N --host <mac>` starts the login on the worker over SSH, shows you the URL, and passes back the code you paste (depends on S4). A dead login on a worker shows up in `fleet status` and the alert from 1c.
- **Capped account, all Macs.** When an account reaches its limit, the hub tells every worker using it to swap to the account with the most room, preferring the one whose limit resets soonest. `/swap --fleet` does the same by hand. Each worker's swap is still its own cswap: nothing copies logins.
- `fleet status` lists which Mac is on which account.

## Phase 4: remote sessions

- `/remote <mac> [goal]` (and `overclaude remote <mac> [goal]`): starts `claude --remote-control "<mac>-<goal>"` on the worker, using `claude --bg` if S6 passes and tmux otherwise. It is named so it appears in claude.ai/code and the phone app, where you drive it.
- `/handoff <mac>`: writes the handoff package as today, copies it to the worker (`scp`, into the path that the worker's SessionStart hook loads), and starts the remote session. The session picks up where this one left off.
- `overclaude remote list|attach|stop`: thin wrappers over `ssh <mac> claude agents|attach|stop`.
- Requires a `/login` login on the worker (Remote Control does not accept setup-tokens). The keepalive from Phase 1 runs on workers too, so Remote Control sessions do not die from an idle login.

## Phase 5: job queue

- `overclaude job "<prompt>" [--repo <git url or path>] [--mac <name>]`: runs a headless `claude -p` on the Mac with the most room, judged by free memory, running sessions and the hub's usage figures for that Mac's account. It uses that Mac's setup-token for an account with room (from 1d), so it needs no browser and never touches the interactive login.
- Results come back to `~/.claude/overclaude/jobs/<id>/` on the hub (output, exit code, branch or diff). `overclaude job list|logs|cancel`.
- A cap on jobs running at once per account, so a batch cannot eat the week's limit. It is off by default when the account is above its auto-swap threshold.
- This is the phase most likely to slip to 1.6 if Phases 1–4 take longer than expected.

## Phase 6: overcodex (separate release, overcodex 0.4)

- `swap-guard codex-review --host <mac>`: runs the Codex review on a worker.
- Remote Codex session from the hub. Remember that codex-swap is a cold switch, on workers too.

## Smaller items in 1.5

- **Auto-resume after server errors.** A `StopFailure` hook (matcher `server_error|overloaded`) records the failure. If S5 shows `asyncRewake` works there, it waits (30 s, then 2 min, then 5 min; at most 3 tries per session per hour) and wakes Claude with "the last turn failed on a server error — continue". If not, it sends only a notification. Off by default.
- **Instruction-size check in doctor.** Warns when CLAUDE.md and the files it imports exceed a size budget.
- **Loop guard (experimental).** Spots the same tool call failing the same way several times in a row and tells Claude to stop and rethink. Off by default.

## Will not do

- Automating the browser login, or keeping a signed-in browser profile for it.
- Copying or syncing login files between Macs.
- Running jobs for other people on these accounts.

## Release slicing

- **1.5.0**: Phases 1–4 and the smaller items. Phase 1 can ship first as 1.4.1 if a login dies again before 1.5 is ready.
- **1.5.x / 1.6**: Phase 5, depending on how Phases 1–4 go.
- **overcodex 0.4**: Phase 6.

Every phase adds tests to `tests/` (fleet tests use a stub `ssh`), and keeps the release gate and scrub gate unchanged.
