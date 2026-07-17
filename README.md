# overclaude

**Claude Code, overclocked.** A portable kit that turns a stock Claude Code install into a multi-account, context-aware, model-routed setup: hot-swap between Claude accounts without leaving your session, hand off to a fresh session before context fills up, watch every usage meter in the statusline, and route multi-agent workflow subagents to the right model tier automatically.

Clone it, run the installer, register your accounts — same setup on any Mac.

```
Fable 5 (high) | myproject (master*) | 3 sessions | 👤 work [1/2]
ctx [████░░░░░░] 42% | 5h [███████░░░] 71% | week [██░░░░░░░░] 18% | Fable [███████░░░] 73%
```

## Features

### `/swap` — hot account switching
Switch which Claude account serves your sessions **without restarting anything**. Every live Claude Code session on the machine (CLI, VS Code, background) adopts the new credential within ~30 seconds, mid-conversation, full context preserved. Hit a rate limit on one account? `/swap work` and keep typing.

- `/swap` — dashboard: accounts, aliases, token health, per-account 5h/7d/scoped usage, live-session table
- `/swap <target>` — hot-swap (guarded: refuses if another session is mid-task, unless you `force`)
- `/swap <target> handoff` — switch accounts AND continue in a fresh session with packaged context
- `/swap <target> restart` — rare escape hatch for model-entitlement mismatches or wedged auth
- `/swap add` — guided registration of a new account

A busy-session preflight protects you from yanking credentials out from under an active session. Sessions too old to report status are judged by transcript activity instead of being assumed busy.

### `/handoff` — context-threshold session handoff
When a session's context crosses **60% / 75% / 85%**, Claude offers a handoff: it packages goals, state, decisions, files touched, and next steps into a structured document, then a fresh session auto-loads it via a SessionStart hook. You lose the token bloat, not the thread. Works same-account (`/handoff`) or combined with an account switch (`/swap <target> handoff`). Also: `/handoff status`, `/handoff cancel`.

### Instrumented statusline
Two lines, everything you actually check: model + effort, folder (git branch, dirty marker), live session count, active account `[slot/total]`, then four 10-char meters — **context window, 5-hour limit, weekly limit, and your model-scoped (Fable) bucket** — green/yellow/red at 50/80%. The statusline is also the data spine: it publishes each session's context % to a relay file the threshold hooks read.

### `ULTRACODE.md` — model routing for multi-agent workflows
A policy document loaded into every session that teaches the orchestrator to route workflow subagents by task: haiku/sonnet for bulk scouting and finding, opus for verification and judging, the top tier reserved for final synthesis and tie-breaks. Core rule: *spend the scarce model only where judgment is the bottleneck, never where volume is.* Includes a routing table, hard floors that never get downgraded, escalation rules, and a pre-dispatch lint.

## Requirements

- macOS (scripts use BSD `stat -f`, `shasum`), zsh
- `jq`, `git`, `pipx`
- [Claude Code](https://claude.com/claude-code) — tested on 2.1.212; the session-registry `status` field needs ~2.1.211+
- Claude subscription accounts (Max-style) — the rate-limit meters read subscription usage buckets

The credential-switching engine, **cswap**, ships with the kit (`vendor/claude_swap-0.21.0.tar.gz`) and is installed automatically by `install.sh` via pipx — no separate install step. See [Credits](#credits).

## Install

```bash
git clone https://github.com/arthur-bump-pm/overclaude.git
cd overclaude
./install.sh
```

The installer is **idempotent and conservative**: every modified file gets a timestamped backup, your existing `settings.json` content (other hooks, permissions) is preserved by a jq merge, an existing statusLine is never overwritten (you get instructions instead), and re-running is a no-op.

The installer also sets up cswap from the bundled copy if it isn't on the machine yet (needs `pipx`; Python dependencies are resolved from PyPI).

Post-install:

1. Register accounts: `cswap add` (repeat per account), then alias them: `cswap alias 1 work`, `cswap alias 2 personal`
2. Open a new shell (or `source ~/.zshrc`)
3. Start a **new** Claude Code session — hooks and statusline load at session start
4. Verify: `swap-guard whoami` prints your session JSON; the statusline shows `👤 <alias> [n/N]` and four meters

## Components

| File | Installs to | What it does |
|---|---|---|
| `bin/swap-guard` | `~/.local/bin/` | State/guard engine: `whoami`, live-session table, busy-preflight for swaps, per-directory handoff state, relay status |
| `skills/swap/SKILL.md` | `~/.claude/skills/swap/` | The `/swap` skill: dashboard, guarded hot-swap, handoff/restart modes, account registration |
| `skills/handoff/SKILL.md` | `~/.claude/skills/handoff/` | The `/handoff` skill: context packaging, relaunch flags, status/cancel |
| `hooks/handoff-inject.sh` | `~/.claude/hooks/` | SessionStart: auto-loads a pending handoff package into the new session (10-min TTL, per-directory) |
| `hooks/ctx-watch.sh` | `~/.claude/hooks/` | UserPromptSubmit: fires the 60/75/85% handoff offers, with re-arm hysteresis |
| `hooks/ctx-notify.sh` | `~/.claude/hooks/` | Stop: threshold banner notifications |
| `statusline/statusline-command.sh` | `~/.claude/statusline-command.sh` | Renders the statusline; publishes the context relay the hooks depend on |
| `claude/ULTRACODE.md` | `~/.claude/` + import in `CLAUDE.md` | Model/effort routing policy for multi-agent workflows |
| `settings/settings-fragment.json` | merged into `~/.claude/settings.json` | 3 hook groups, statusLine block, 2 permission allows |
| `shell/zshrc-snippet.sh` | appended to `~/.zshrc` (markers) | `claude()` wrapper honoring handoff/restart relaunch flags, `swap` alias, PATH guard |
| `vendor/claude_swap-*.tar.gz` | pipx-installed if `cswap` absent | The bundled credential-switching engine (see [Credits](#credits)) |

## Behaviors & caveats — read these

- **A swap flips ALL live Claude Code sessions on the machine** within ~30s. It's the shared keychain credential, not per-terminal.
- **Hooks load at session start.** Sessions already running at install time won't offer handoffs until restarted; a plain hot-swap works everywhere immediately.
- **The kit's statusline is a hard dependency for the handoff offers** — it publishes the context relay that `ctx-watch`/`ctx-notify` read. If the installer skipped it because you already had a statusLine, either switch (`.statusLine.command` → `bash ~/.claude/statusline-command.sh`) or merge the relay block into your own script; otherwise threshold prompts silently never fire.
- The **Fable/scoped meter reads cswap's cache**, refreshed whenever cswap runs (any `/swap` dashboard, switch, or `cswap list`) — it can lag between invocations. The 5h/week meters describe the account that served the last response, so they lag ~1 turn right after a swap; the 👤 segment is always current.
- Statusless legacy clients (older VS Code extension builds) are judged busy/idle by **transcript mtime** (2-min window) during swap preflight.
- **claude.ai connectors (Gmail/Drive/…) are per-account server-side** — they don't follow a swap.
- Context thresholds re-arm if usage drops 10 points below the fired threshold; Claude Code's auto-compact (~92%) remains the backstop.
- The `swap` shell alias (`cswap switch`) works from any terminal even when sessions are hard rate-limited — the panic path when a session can't complete its own `/swap` turn.

## Keeping the repo in sync with your live setup

Improve your live setup (statusline tweaks, skill edits, ULTRACODE changes), then:

```bash
./sync.sh            # live files -> repo, scrub-check, show diff, commit, push
./sync.sh --dry-run  # just show what would change
```

`sync.sh` copies the live files back into the repo layout, extracts your current zshrc block, **aborts if the diff contains personal data** (usernames, emails, `/Users/...` paths), and only then commits and pushes. On other machines: `git pull && ./install.sh` (no-ops everything unchanged).

`settings/settings-fragment.json` is curated by hand — if you add hooks or permissions the kit should ship, edit the fragment directly.

## Uninstall

```bash
./uninstall.sh
```

Removes installed files, deletes the zshrc block, removes the `@ULTRACODE.md` import, and strips exactly the kit's entries from `settings.json` (your other settings survive; everything edited is backed up first). Runtime state in `~/.claude-swap-backup/` (cswap credentials/cache, handoff archives) is deliberately left — delete it manually for a clean slate. cswap itself, if the installer set it up, is removed with `pipx uninstall claude-swap`.

## Credits

The account-switching engine bundled in `vendor/` is **[claude-swap](https://github.com/realiti4/claude-swap)** by [Onur Cetinkol](https://github.com/realiti4) (MIT license), vendored unmodified at v0.21.0 from [PyPI](https://pypi.org/project/claude-swap/). overclaude's swap/handoff layer, statusline, hooks, and routing policy are built around it — cswap does the hard, careful work of credential storage, keychain switching, OAuth refresh, and usage polling. Go star it.

## License

MIT — see [LICENSE](LICENSE). The vendored claude-swap package retains its own MIT license and copyright (Onur Cetinkol).
