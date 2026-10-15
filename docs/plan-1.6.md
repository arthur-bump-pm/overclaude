# overclaude 1.6 plan — use every account well, and re-login without friction

Status: ✅ Part A released as 1.6.0 on 2026-10-14 (plan written the same day). Part B (worker re-login and the job queue) moved to 1.7: it waits until there are real worker Macs to test on.

Two goals:

1. **No usage goes to waste.** Know when your accounts will run out at the pace you're going, and which account to use first so its weekly allowance doesn't reset unused.
2. **Re-login takes one click.** The sign-in page opens in the browser profile that belongs to that account.

Several ideas here were prompted by [claude-cockpit](https://github.com/christianjohnston-ai/claude-cockpit) (MIT). As with 1.5, nothing is copied: each is rebuilt in overclaude's own way, on top of what claude-swap already provides.

## What this rests on (checked 2026-10-14)

| Fact | Source |
|---|---|
| cswap's usage cache (`~/.claude-swap-backup/cache/usage.json`) holds every account's last good 5-hour, weekly and per-model (`scoped`, e.g. Fable) percentages and reset times. Reading it needs no network and no token. | the file (schemaVersion 2) |
| `cswap list --json` adds a pace projection to each account's weekly and per-model windows (`expectedPct`, `projectedExhaustionAt`, `willLastToReset`), and `cswap auto --strategy consume-first` switches to the account whose week resets soonest. | cswap 0.26 `--help`, `pace.py` |
| Claude Code opens URLs with `$BROWSER <url>` when `BROWSER` is set, else `open <url>`. `claude auth login` goes through it (tested: a stub `BROWSER` got exactly one argument, the claude.com sign-in URL). | 2.1.299 binary; local test |
| Chrome lists its profiles in `~/Library/Application Support/Google/Chrome/Local State` (`profile.info_cache`: directory → display name and signed-in Google address). `open -na "Google Chrome" --args --profile-directory=<dir> <url>` opens a URL in that profile. | Chrome |
| A usage window starts at an account's first message. A one-word `claude -p` reply costs a negligible share of the window. `--setting-sources ""`, `--settings '{"disableAllHooks":true}'`, `--strict-mcp-config`, `--no-session-persistence` all exist in 2.1.299. | `claude --help` |

## Ground rules (unchanged from 1.5)

- Never copy a login between machines; never automate the consent page (opening the right profile is fine; clicking Approve stays with you).
- Tokens never appear on screen, in a file, a log or a process list.
- Anything that spends usage on its own is opt-in and off by default.

## Part A — this Mac

### A1. Run-out forecast and "use this account first"

`swap-guard forecast [--text]`, `/swap forecast`, a statusline hint.

- Reads cswap's usage cache (no network, no token), plus `sequence.json` and the login end dates for which accounts count: disabled, dead and ending logins don't. The cache's last good numbers can be old (cswap's own list hides stale ones); the forecast checks `schemaVersion`, shows each account's data age, and an account whose week already reset counts as empty.
- Pace = usage across all accounts over the last week (the sum of each account's weekly percentage, over the longest elapsed window), in "% of one account-week per hour". An estimate, said as such.
- Simulates the next 7 days in 15-minute steps: use the account with room whose week resets soonest; each account refills at its reset. Reports when you would run out (or that you last the week), and how much room each account will lose unused at its reset.
- The hint names the account to use first: the one with room that resets soonest. When room would expire unused, it says so ("personal: 100% left, resets in 1h 36m — use it first"). It points at `swap-guard auto install --strategy consume-first` to make this automatic.
- The same simulation for the Fable (per-model) limit.
- Statusline: on an inactive account's line, `⏳ use first` when it has at least 30% room left and its week resets within 24 h and before the active account's. On line 2, `⚠ accounts out ~Sat 14:00` when the forecast runs out within 24 h. A render only reads the forecast cache, refreshed in the background at most every 5 minutes.

### A2. Start an idle account's 5-hour window early (opt-in)

`swap-guard prewarm on|off|status|tick [--dry-run]`, `/swap auto prewarm on|off`.

- Runs inside the keepalive tick (no new background job): for each account that is not active, has no 5-hour window running, has weekly room left (under 90%), whose login isn't ending, and wasn't pinged in the last 5 hours, send one tiny message so its 5-hour clock starts. When you switch to it later, its window resets sooner.
- Uses the account's long-lived token (`swap-guard token add`), handed over the way `swap-guard token run` does it (the `CLAUDE_CODE_OAUTH_TOKEN` environment variable, never argv), never its login: no switching, no credential copying. Accounts without a token are listed in `status` with the command to add one.
- The message: `claude -p "Reply with only the word: ok" --model haiku` from an empty private folder (so no CLAUDE.md is read), with all settings, hooks, MCP servers and session saving turned off, 60-second timeout. Output is discarded; only ok/failed is logged.
- The tick checks the opt-in marker before anything else. Long-lived tokens are still marked experimental (not yet run against a real sign-in); A2 is too, until that first real `token add` works.

### A3. Re-login in the right Chrome profile

`swap-guard browser list | set <account> <profile> | clear <account>`; used by `swap-guard login N` and `/swap relogin`.

- `login N` picks the Chrome profile for that account: your saved choice first (only the profile's folder name is saved), else the profile signed in to the same Google address. `browser list` shows profiles and their Google addresses on screen; addresses are never logged or saved. The opener lives in the login's private temporary folder, with the profile name quoted. It points `BROWSER` at a two-line opener for that profile, so the sign-in page opens there, and says which profile it used. No match (or no Chrome): the default browser, as before.
- Nothing about the consent page is automated.

### A4. Smaller items ✅

- `scrub.sh --self-test` (proves the gate still catches a planted path, email and username) and `scrub.sh --history` (scans every commit), plus an optional pre-push hook.
- 1.5 leftovers: `SWAP_NO_FLEET_SWAP` as a remembered setting instead of an environment variable (`swap-guard fleet auto on|off`).

### A5. Artifacts after an account change (1.6.1) ✅

Artifacts belong to the account that published them. After any switch, each session is told once (instant-swap wake, or its next prompt) which artifacts it published stay on the old account; nothing is copied up front. It republishes one on the new account from the saved source, and links old → new, only when it needs to change it. `swap-guard artifacts carry` / `/swap artifacts carry` lists or copies them all. Other sessions' artifacts are never touched.

## Part B — worker Macs (moved to 1.7; waits for real Macs)

- **Re-login on a worker** (`swap-guard login N --host <mac>`): the worker prints the sign-in link, you open it here, the code is pasted back over SSH. Needs test S4 from the 1.5 plan on a real worker.
- **Job queue**: hand a headless task to whichever Mac has room (`overclaude job add|list|logs`), running on that Mac's long-lived token.
- Confirm on real Macs: fleet status/swap, `remote`, `/handoff <mac>`, and that a background session survives the SSH connection closing (S6).

## Will not do

- A full-screen dashboard: the statusline and `/swap` cover it.
- A config folder per account: claude-swap's model makes it unnecessary.
- Scraping `/usage` from a Claude session: the usage cache is direct and needs no session.
