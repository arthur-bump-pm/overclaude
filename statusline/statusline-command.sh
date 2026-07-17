#!/usr/bin/env bash
# Claude Code status line - two-line layout
#
# Line 1: model (effort) | dir (branch*) | N sessions | account
# Line 2: ctx bar | 5h bar | week bar | Fable bar  (10-char bars, one line)
#
# Fable 5 (high) | myproject (master*) | 3 sessions | 👤 work [1/2]
# ctx [████░░░░░░] 42% | 5h [███████░░░] 71% | week [██░░░░░░░░] 18% | Fable [███████░░░] 73%

input=$(cat)

model_name=$(echo "$input" | jq -r '.model.display_name // "Claude"')
effort_level=$(echo "$input" | jq -r '.effort.level // empty')

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')

# --- Context window usage ---
# Prefer the pre-calculated used_percentage; fall back to 100 - remaining_percentage;
# leave empty (renders as "n/a") if neither is available (e.g. before first API response).
ctx_used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -z "$ctx_used" ] || [ "$ctx_used" = "null" ]; then
  ctx_remaining=$(echo "$input" | jq -r '.context_window.remaining_percentage // empty')
  if [ -n "$ctx_remaining" ] && [ "$ctx_remaining" != "null" ]; then
    ctx_used=$(awk -v r="$ctx_remaining" 'BEGIN { printf "%.4f", 100 - r }')
  fi
fi

# --- Handoff context relay (claude-swap integration) ---
# Publish this session's context usage to ~/.claude-swap-backup/ctx/<session_id>.json
# so the ctx-watch/ctx-notify hooks can see it (hooks get no context_window data).
# Zero stdout/stderr, atomic write, never affects rendering. NEVER calls cswap.
relay_session_id=$(echo "$input" | jq -r '.session_id // empty' 2>/dev/null) || relay_session_id=""
if [ -n "$relay_session_id" ] && [ -n "$ctx_used" ] && [ "$ctx_used" != "null" ]; then
  case "$relay_session_id" in
    */* | *..*) : ;; # unsafe as a filename: skip
    *)
      case "$ctx_used" in
        '' | *[!0-9.]* | *.*.* | .* | *.) : ;; # not a plain JSON number: skip
        *)
          relay_dir="$HOME/.claude-swap-backup/ctx"
          {
            mkdir -p "$relay_dir" &&
              printf '{"pct":%s,"ts":%s}' "$ctx_used" "$(date +%s)" \
                > "$relay_dir/$relay_session_id.json.tmp.$$" &&
              mv "$relay_dir/$relay_session_id.json.tmp.$$" "$relay_dir/$relay_session_id.json"
            # Keep the live session's .state mtime fresh too: it is only written on
            # threshold transitions, so without this it could age past the prune
            # window while the session is still alive (resetting hysteresis).
            [ -f "$relay_dir/$relay_session_id.state" ] && touch "$relay_dir/$relay_session_id.state"
            # Age-based prune: only when the dir grows past 50 entries, and only
            # files idle >2 days (live relays are rewritten every ~10s, never hit).
            [ "$(ls "$relay_dir" 2>/dev/null | wc -l)" -gt 50 ] &&
              find "$relay_dir" \( -name '*.json' -o -name '*.state' \) -mtime +2 -delete
          } >/dev/null 2>&1 || true
          ;;
      esac
      ;;
  esac
fi

# --- Claude.ai subscription rate limits (only present for subscribers after first API response) ---
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')

# --- Scoped "Fable" bucket (cswap cache; statusline stdin carries no scoped limits) ---
# Read-only: sequence.json .activeAccountNumber -> cache/usage.json
# .accounts[<n>].lastGood.scoped[name=="Fable"].pct. NEVER calls cswap
# (token-refresh side effects). Missing/corrupt anywhere -> empty -> "n/a" bar.
fable_pct=""
fable_seq="${SWAP_SEQ_JSON:-$HOME/.claude-swap-backup/sequence.json}"
fable_cache="${SWAP_USAGE_JSON:-$HOME/.claude-swap-backup/cache/usage.json}"
if command -v jq >/dev/null 2>&1 && [ -r "$fable_seq" ] && [ -r "$fable_cache" ]; then
  fable_slot=$(jq -r '(.activeAccountNumber // empty) | tostring' "$fable_seq" 2>/dev/null) || fable_slot=""
  if [ -n "$fable_slot" ] && [ "$fable_slot" != "null" ]; then
    fable_pct=$(jq -r --arg n "$fable_slot" \
      '.accounts[$n].lastGood.scoped[]? | select(.name == "Fable") | .pct // empty' \
      "$fable_cache" 2>/dev/null | head -n1) || fable_pct=""
    [ "$fable_pct" = "null" ] && fable_pct=""
  fi
fi

# ANSI styles
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

BAR_WIDTH=10

# render_bar <label> <percentage-or-empty>  -- prints inline, no trailing newline
render_bar() {
  local label="$1"
  local pct="$2"

  if [ -z "$pct" ] || [ "$pct" = "null" ]; then
    local empty_bar=""
    [ "$BAR_WIDTH" -gt 0 ] && empty_bar=$(printf '░%.0s' $(seq 1 "$BAR_WIDTH"))
    printf "%s%s [%s] n/a%s" "$DIM" "$label" "$empty_bar" "$RESET"
    return
  fi

  local pct_int
  pct_int=$(awk -v p="$pct" 'BEGIN {
    v = int(p + 0.5);
    if (v < 0) v = 0;
    if (v > 100) v = 100;
    print v
  }')

  local color="$GREEN"
  if [ "$pct_int" -ge 80 ]; then
    color="$RED"
  elif [ "$pct_int" -ge 50 ]; then
    color="$YELLOW"
  fi

  local filled=$(( pct_int * BAR_WIDTH / 100 ))
  local empty=$(( BAR_WIDTH - filled ))

  local filled_bar=""
  local empty_bar=""
  [ "$filled" -gt 0 ] && filled_bar=$(printf '█%.0s' $(seq 1 "$filled"))
  [ "$empty" -gt 0 ] && empty_bar=$(printf '░%.0s' $(seq 1 "$empty"))

  printf "%s [%s%s%s%s] %d%%" "$label" "$color" "$filled_bar" "$empty_bar" "$RESET" "$pct_int"
}

# --- cswap account segment (claude-swap integration) ---
# Primary source: ~/.claude-swap-backup/sequence.json .activeAccountNumber
#   -> "👤 <alias-or-email-localpart> [<n>/<total>]"
# Cross-check ~/.claude.json .oauthAccount.emailAddress: mismatch -> "👤 <email> ?"
# sequence.json missing/corrupt -> "👤 <email>"; no email either / no jq -> empty.
# NEVER calls cswap (token-refresh side effects). Test hooks (unset in production):
# SWAP_CLAUDE_JSON / SWAP_SEQ_JSON.
swap_account_segment() {
  local claude_json="${SWAP_CLAUDE_JSON:-$HOME/.claude.json}"
  local seq_json="${SWAP_SEQ_JSON:-$HOME/.claude-swap-backup/sequence.json}"
  local email="" slot="" acct_email="" acct_alias="" total="" label=""

  command -v jq >/dev/null 2>&1 || return 0        # no jq: emit nothing

  # claude.json email: cross-check source and fallback rendering
  if [ -r "$claude_json" ]; then
    email=$(jq -r '.oauthAccount.emailAddress // empty' "$claude_json" 2>/dev/null) || email=""
  fi

  # Primary: activeAccountNumber from sequence.json
  if [ -r "$seq_json" ]; then
    local resolved
    resolved=$(jq -r '
      ((.activeAccountNumber // empty) | tostring) as $n
      | (.accounts // {}) as $a
      | ($a | length) as $total
      | $a[$n] as $acct
      | if $acct == null then empty
        else "\($n)\t\($acct.email // "")\t\($acct.alias // "" | tostring)\t\($total)"
        end
    ' "$seq_json" 2>/dev/null) || resolved=""
    if [ -n "$resolved" ]; then
      slot=$(printf '%s' "$resolved" | cut -f1)
      acct_email=$(printf '%s' "$resolved" | cut -f2)
      acct_alias=$(printf '%s' "$resolved" | cut -f3)
      total=$(printf '%s' "$resolved" | cut -f4)
      [ "$acct_alias" = "null" ] && acct_alias=""
    fi
  fi

  if [ -n "$slot" ] && [ -n "$acct_email" ] && [ -n "$total" ]; then
    # Cross-check: live login vs sequence.json's idea of the active account
    if [ -n "$email" ] && [ "$email" != "$acct_email" ]; then
      printf '👤 %s ?' "$email"
      return 0
    fi
    label="$acct_alias"
    [ -n "$label" ] || label="${acct_email%%@*}"
    printf '👤 %s [%s/%s]' "$label" "$slot" "$total"
    return 0
  fi

  # Fallback: sequence.json missing/corrupt/unusable -> email only, else nothing
  [ -n "$email" ] || return 0
  printf '👤 %s' "$email"
}
# --- end cswap account segment ---

# --- Line 1: model (effort) | dir (branch*) | N sessions | account ---

model_seg="$model_name"
if [ -n "$effort_level" ] && [ "$effort_level" != "null" ]; then
  model_seg="$model_name ($effort_level)"
fi

# Directory segment shows just the folder name ("myproject", not "~/Documents/myproject");
# plain "~" when the session is at $HOME itself.
if [ "$cwd" = "$HOME" ]; then
  dir="~"
else
  dir="${cwd##*/}"
fi
segment_dir="$dir"
if [ -n "$cwd" ] && git -C "$cwd" --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" --no-optional-locks branch --show-current 2>/dev/null)
  if [ -z "$branch" ]; then
    branch=$(git -C "$cwd" --no-optional-locks rev-parse --short HEAD 2>/dev/null)
  fi
  if [ -n "$branch" ]; then
    dirty=""
    if [ -n "$(git -C "$cwd" --no-optional-locks status --porcelain 2>/dev/null)" ]; then
      dirty="*"
    fi
    segment_dir="$dir ($branch$dirty)"
  fi
fi

# Count live Claude Code CLI processes (macOS pgrep exact-name match).
# Fall back to 1 if pgrep is unavailable or matches nothing (this session exists).
session_count=0
if command -v pgrep >/dev/null 2>&1; then
  session_count=$(pgrep -x claude 2>/dev/null | wc -l | tr -d '[:space:]')
fi
case "$session_count" in
  ''|*[!0-9]*) session_count=0 ;;
esac
if [ "$session_count" -lt 1 ]; then
  session_count=1
fi
if [ "$session_count" -eq 1 ]; then
  session_word="session"
else
  session_word="sessions"
fi
segment_sessions="$session_count $session_word"

line1="${BOLD}${model_seg}${RESET} | ${BOLD}${segment_dir}${RESET} | ${BOLD}${segment_sessions}${RESET}"

account_seg=$(swap_account_segment 2>/dev/null) || account_seg=""
if [ -n "$account_seg" ]; then
  line1="$line1 | ${BOLD}${account_seg}${RESET}"
fi

# --- Line 2: usage bars, all on one line ---
line2="$(render_bar "ctx" "$ctx_used") | $(render_bar "5h" "$five_hour") | $(render_bar "week" "$seven_day") | $(render_bar "Fable" "$fable_pct")"

printf "%s\n" "$line1"
printf "%s\n" "$line2"
