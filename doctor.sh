#!/bin/bash
# doctor.sh — overclaude health check. READ-ONLY: diagnoses the live install and
# prints the exact fix for each problem; never changes anything.
# macOS /bin/bash 3.2 compatible. Exit 0 = healthy (warnings allowed), 1 = a check failed.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
LOCALBIN="$HOME/.local/bin"
STATE_ROOT="$HOME/.claude-swap-backup"
SETTINGS="$CLAUDE_DIR/settings.json"
BEGIN_MARKER='# --- claude-swap integration (begin) ---'

FAILS=0
WARNS=0
ok()   { echo "  [ok]   $1"; }
warn() { WARNS=$((WARNS + 1)); echo "  [warn] $1"; [ -n "${2:-}" ] && echo "         fix: $2"; }
fail() { FAILS=$((FAILS + 1)); echo "  [FAIL] $1"; [ -n "${2:-}" ] && echo "         fix: $2"; }

echo "== overclaude doctor =="

# ---------------------------------------------------------------------------
echo "-- dependencies --"
if command -v jq >/dev/null 2>&1; then ok "jq $(jq --version 2>/dev/null)"; else fail "jq not found" "brew install jq"; fi

VEND_VER=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$SCRIPT_DIR/vendor/claude-swap/pyproject.toml" 2>/dev/null | head -1)
CSWAP_BIN=$(command -v cswap 2>/dev/null || { [ -x "$LOCALBIN/cswap" ] && echo "$LOCALBIN/cswap"; })
if [ -z "$CSWAP_BIN" ]; then
  fail "cswap not found" "overclaude install   (installs the bundled copy)"
else
  CSWAP_VER=$("$CSWAP_BIN" --version 2>/dev/null | awk '{print $NF}')
  if [ -n "$VEND_VER" ] && [ -n "$CSWAP_VER" ] && [ "$CSWAP_VER" != "$VEND_VER" ] &&
     [ "$(printf '%s\n%s\n' "$CSWAP_VER" "$VEND_VER" | sort -V | head -1)" = "$CSWAP_VER" ]; then
    warn "cswap $CSWAP_VER is older than the bundled $VEND_VER (the kit is tested against $VEND_VER)" "overclaude install"
  else
    ok "cswap ${CSWAP_VER:-?} (bundled: ${VEND_VER:-?})"
  fi
fi

if command -v claude >/dev/null 2>&1; then
  CC_VER=$(claude --version 2>/dev/null | awk '{print $1}')
  ok "Claude Code ${CC_VER:-?}"
else
  warn "claude CLI not on PATH (fine if you only use the desktop/IDE app)"
fi

case ":$PATH:" in
  *":$LOCALBIN:"*) ok "$LOCALBIN is on PATH" ;;
  *) warn "$LOCALBIN is not on PATH — swap-guard won't resolve in new shells" "add  export PATH=\"\$HOME/.local/bin:\$PATH\"  to ~/.zshrc" ;;
esac

# ---------------------------------------------------------------------------
echo "-- kit files (live vs this package) --"
check_file() { # check_file <payload-rel> <live-path>
  local src="$SCRIPT_DIR/$1" dst="$2"
  if [ ! -f "$dst" ]; then
    fail "missing: $dst" "overclaude install"
  elif [ -f "$src" ] && ! cmp -s "$src" "$dst"; then
    if [ "$dst" -nt "$src" ]; then
      warn "differs (live is newer — local edits?): $dst" "keep them, or restore with: overclaude install"
    else
      warn "differs (live is older): $dst" "overclaude install"
    fi
  else
    ok "$dst"
  fi
}
check_file bin/swap-guard                   "$LOCALBIN/swap-guard"
check_file skills/swap/SKILL.md             "$CLAUDE_DIR/skills/swap/SKILL.md"
check_file skills/handoff/SKILL.md          "$CLAUDE_DIR/skills/handoff/SKILL.md"
check_file hooks/handoff-inject.sh          "$CLAUDE_DIR/hooks/handoff-inject.sh"
check_file hooks/ctx-watch.sh               "$CLAUDE_DIR/hooks/ctx-watch.sh"
check_file hooks/ctx-notify.sh              "$CLAUDE_DIR/hooks/ctx-notify.sh"
check_file statusline/statusline-command.sh "$CLAUDE_DIR/statusline-command.sh"
check_file claude/ULTRACODE.md              "$CLAUDE_DIR/ULTRACODE.md"

# ---------------------------------------------------------------------------
echo "-- settings.json --"
if [ ! -f "$SETTINGS" ]; then
  fail "no $SETTINGS" "overclaude install"
elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
  fail "$SETTINGS is not valid JSON — Claude Code ignores it" "fix the syntax (backups: $SETTINGS.bak-*)"
else
  for pair in "SessionStart:handoff-inject.sh" "UserPromptSubmit:ctx-watch.sh" "Stop:ctx-notify.sh"; do
    ev="${pair%%:*}"; hk="${pair#*:}"
    if jq -e --arg ev "$ev" --arg hk "$hk" '[.hooks[$ev][]?.hooks[]?.command // ""] | any(contains($hk))' "$SETTINGS" >/dev/null 2>&1; then
      ok "$ev hook → $hk"
    else
      fail "$ev hook for $hk is not registered" "overclaude install"
    fi
  done
  sl=$(jq -r '.statusLine.command // ""' "$SETTINGS" 2>/dev/null)
  case "$sl" in
    *statusline-command.sh*) ok "statusLine → overclaude statusline" ;;
    "") fail "no statusLine configured — context offers can't fire without its relay" "overclaude install" ;;
    *) warn "statusLine is a different script ($sl) — handoff offers need the overclaude relay" "point statusLine.command at: bash ~/.claude/statusline-command.sh" ;;
  esac
fi

if [ -f "$CLAUDE_DIR/CLAUDE.md" ] && grep -qxF '@ULTRACODE.md' "$CLAUDE_DIR/CLAUDE.md"; then
  ok "CLAUDE.md imports @ULTRACODE.md"
else
  warn "CLAUDE.md does not import @ULTRACODE.md (model-routing policy not loaded)" "overclaude install"
fi

if [ -f "$HOME/.zshrc" ] && grep -qF "$BEGIN_MARKER" "$HOME/.zshrc"; then
  ok "~/.zshrc has the claude() relaunch wrapper"
else
  warn "~/.zshrc lacks the claude() wrapper — handoff can't relaunch after Ctrl+D" "overclaude install"
fi

# ---------------------------------------------------------------------------
echo "-- accounts --"
if [ -n "$CSWAP_BIN" ] && command -v jq >/dev/null 2>&1; then
  list=$("$CSWAP_BIN" list --json 2>/dev/null)
  if [ -z "$list" ] || ! printf '%s' "$list" | jq -e . >/dev/null 2>&1; then
    fail "cswap list --json failed" "run: cswap list   (to see the error)"
  else
    n=$(printf '%s' "$list" | jq '.accounts | length')
    if [ "$n" -eq 0 ]; then
      warn "no accounts registered" "cswap add   (while logged in), then cswap alias 1 work"
    fi
    printf '%s' "$list" | jq -r '.accounts[] | [(.number|tostring), (.alias // ""), (.email // ""), (.usageStatus // "")] | @tsv' |
    while IFS=$'\t' read -r num alias email us; do
      label="${alias:-${email%%@*}}"
      case "$(printf '%s' "$us" | tr '[:upper:]' '[:lower:]')" in
        *login*|*quarantin*|*expired*|*invalid*|*revoked*)
          echo "  [warn] account $num ($label): token dead ($us)"
          echo "         fix: /login as $email inside Claude Code, then: cswap add --slot $num" ;;
        *) echo "  [ok]   account $num ($label): ${us:-ok}" ;;
      esac
    done
    # The pipe ran in a subshell; recount dead tokens for the summary.
    dead=$(printf '%s' "$list" | jq '[.accounts[] | (.usageStatus // "" | ascii_downcase) | select(test("login|quarantin|expired|invalid|revoked"))] | length')
    WARNS=$((WARNS + dead))
    if command -v claude >/dev/null 2>&1; then
      live_email=$(claude auth status 2>/dev/null | jq -r '.email // empty' 2>/dev/null)
      act_email=$(jq -r '(.activeAccountNumber|tostring) as $n | .accounts[$n].email // empty' "$STATE_ROOT/sequence.json" 2>/dev/null)
      if [ -n "$live_email" ] && [ -n "$act_email" ]; then
        if [ "$live_email" = "$act_email" ]; then
          ok "logged-in account matches cswap's active slot ($live_email)"
        else
          warn "Claude Code is logged in as $live_email but cswap's active slot is $act_email" "cswap switch <slot>   (or /swap <alias>) to re-sync"
        fi
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
echo "-- live sessions --"
if [ -d "$CLAUDE_DIR/sessions" ] && [ -f "$SETTINGS" ]; then
  set_m=$(stat -f %m "$SETTINGS" 2>/dev/null || echo 0)
  hook_m=$(stat -f %m "$CLAUDE_DIR/hooks/handoff-inject.sh" 2>/dev/null || echo 0)
  [ "$hook_m" -gt "$set_m" ] && set_m="$hook_m"
  stale=0; live=0
  for f in "$CLAUDE_DIR"/sessions/*.json; do
    [ -f "$f" ] || continue
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    live=$((live + 1))
    started=$(jq -r '(.startedAt // 0) / 1000 | floor' "$f" 2>/dev/null)
    case "$started" in ''|*[!0-9]*) continue ;; esac
    [ "$started" -lt "$set_m" ] && stale=$((stale + 1))
  done
  if [ "$stale" -gt 0 ]; then
    warn "$stale of $live live session(s) started before the hooks were last installed — they run the old hooks" "restart those sessions (hot-swap still works in them)"
  else
    ok "$live live session(s), all started after the last hook install"
  fi
fi

# ---------------------------------------------------------------------------
echo "-- statusline render --"
if [ -f "$CLAUDE_DIR/statusline-command.sh" ]; then
  out=$(echo '{"model":{"display_name":"doctor"},"workspace":{"current_dir":"'"$HOME"'"},"context_window":{"used_percentage":1}}' |
        SWAP_NO_REFRESH=1 bash "$CLAUDE_DIR/statusline-command.sh" 2>&1); rc=$?
  lines=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  if [ "$rc" -eq 0 ] && [ "$lines" -ge 2 ]; then ok "renders ($lines lines)"; else fail "statusline exited $rc / $lines line(s)" "bash -x ~/.claude/statusline-command.sh < /dev/null"; fi
fi

# ---------------------------------------------------------------------------
echo "-- state --"
if [ -d "$STATE_ROOT" ]; then
  arch=$(ls "$STATE_ROOT/handoff-archive" 2>/dev/null | wc -l | tr -d ' ')
  pend=$(ls "$STATE_ROOT"/handoff-pending-*.md 2>/dev/null | wc -l | tr -d ' ')
  art=$(du -sh "$STATE_ROOT/handoff-artifacts" 2>/dev/null | awk '{print $1}')
  ok "state dir: $arch archived handoff(s), $pend pending, artifact snapshots ${art:-0B}"
  cache="$STATE_ROOT/cache/usage.json"
  if [ -f "$cache" ]; then
    age=$(( $(date +%s) - $(stat -f %m "$cache") ))
    if [ "$age" -gt 1800 ]; then warn "usage cache is $((age / 60)) min old — meters are stale" "cswap list   (refreshes it; check network/tokens if it stays old)"; else ok "usage cache fresh ($((age / 60)) min)"; fi
  fi
else
  warn "no $STATE_ROOT yet" "cswap add"
fi
if [ -f "$HOME/Library/LaunchAgents/com.overclaude.autoswap.plist" ]; then
  if launchctl print "gui/$(id -u)/com.overclaude.autoswap" >/dev/null 2>&1; then
    last=$(tail -n 1 "$STATE_ROOT/auto.log" 2>/dev/null | jq -r '"\(.ts) \(.action)\(if .reason then " (" + (.reason|tostring) + ")" else "" end)"' 2>/dev/null)
    ok "auto-swap agent loaded${last:+ — last tick: $last}"
  else
    warn "auto-swap plist exists but the agent is not loaded" "swap-guard auto install   (or: swap-guard auto uninstall)"
  fi
else
  ok "auto-swap agent not installed (optional: swap-guard auto install)"
fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "doctor: $FAILS failure(s), $WARNS warning(s)."
  exit 1
fi
echo "doctor: healthy${WARNS:+ — $WARNS warning(s)}."
exit 0
