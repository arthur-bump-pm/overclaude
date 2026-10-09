#!/usr/bin/env bash
# Claude Code status line - two-line layout
#
# Line 1: model (effort) | dir (branch*) | N sessions | account ↻ weekly reset
# Line 2: ctx bar | 5h bar | week bar | Fable bar  (10-char bars, one line)
# Line 3+: one compact line per OTHER cswap account (limits + weekly reset)
#
# Fable 5 (high) | myproject (master*) | 3 sessions | 👤 work [1/2] ↻ Thu Oct 9 23:59 (1d 6h)
# ctx [████░░░░░░] 42% | 5h [███████░░░] 71% | week [██░░░░░░░░] 18% | Fable [███████░░░] 73%
# ↳ personal [2] 5h 10% · week 85% · Fable 100% ↻ Thu Oct 9 17:59 (1d 1h)

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

# --- Usage meters: 5h / week / scoped "Fable" ---
# Primary source: cswap's usage cache for the ACTIVE account. stdin's
# rate_limits describe whichever account served this session's LAST response —
# wrong right after a swap and frozen in idle sessions. The cache is
# per-account-correct the moment a swap lands, and the debounced async
# refresher below keeps it <= ~5 min old whenever any statusline is rendering.
# stdin values remain the fallback when the cache is missing/corrupt.
five_hour=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
seven_day=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
fable_pct=""
usage_age=""
week_reset_epoch=""
fable_seq="${SWAP_SEQ_JSON:-$HOME/.claude-swap-backup/sequence.json}"
fable_cache="${SWAP_USAGE_JSON:-$HOME/.claude-swap-backup/cache/usage.json}"
if command -v jq >/dev/null 2>&1 && [ -r "$fable_seq" ] && [ -r "$fable_cache" ]; then
  fable_slot=$(jq -r '(.activeAccountNumber // empty) | tostring' "$fable_seq" 2>/dev/null) || fable_slot=""
  if [ -n "$fable_slot" ] && [ "$fable_slot" != "null" ]; then
    cache_vals=$(jq -r --arg n "$fable_slot" '
      .accounts[$n].lastGood as $g
      | [(($g.five_hour.pct // "") | tostring),
         (($g.seven_day.pct // "") | tostring),
         ((first($g.scoped[]? | select(.name == "Fable") | .pct) // "") | tostring),
         (($g.seven_day.resets_at // "")
            | if type == "string" and test("(Z|\\+00:00)$")
              then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
                    | try (fromdateiso8601 | floor | tostring) catch "")
              else "" end)]
      | join("\t")' "$fable_cache" 2>/dev/null) || cache_vals=""
    c5=$(printf '%s' "$cache_vals" | cut -f1)
    c7=$(printf '%s' "$cache_vals" | cut -f2)
    cf=$(printf '%s' "$cache_vals" | cut -f3)
    week_reset_epoch=$(printf '%s' "$cache_vals" | cut -f4)
    # Cache wins when it has a value: per-account-correct beats per-response-stale.
    case "$c5" in ''|null) : ;; *) five_hour="$c5" ;; esac
    case "$c7" in ''|null) : ;; *) seven_day="$c7" ;; esac
    case "$cf" in ''|null) : ;; *) fable_pct="$cf" ;; esac
    cache_mtime=$(stat -f %m "$fable_cache" 2>/dev/null)
    case "$cache_mtime" in ''|*[!0-9]*) : ;; *) usage_age=$(( $(date +%s) - cache_mtime )) ;; esac
  fi
fi

# Weekly reset fallback: stdin's rate_limits.seven_day.resets_at (epoch seconds).
if [ -z "$week_reset_epoch" ]; then
  week_reset_epoch=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty | if type == "number" then floor | tostring else empty end' 2>/dev/null) || week_reset_epoch=""
fi

# --- Debounced async usage refresh ---
# If the cache is older than 300s, kick ONE detached `cswap list --json`
# (side effect: it refetches + rewrites the usage cache). The RENDER path
# still never waits on cswap: the call is backgrounded, and the lock file is a
# pure RATE-LIMITER — touched at spawn, never removed, aged out after 60s — so
# a persistently-failing refresh (network down) attempts at most once a minute
# instead of every render. Concurrent same-second spawns are tolerated (cswap
# serializes on its own .usage.lock). SWAP_NO_REFRESH=1 disables (tests).
if [ -z "${SWAP_NO_REFRESH:-}" ] && command -v cswap >/dev/null 2>&1; then
  if [ -z "$usage_age" ] || [ "$usage_age" -gt 300 ]; then
    refresh_lock="${SWAP_REFRESH_LOCK:-$HOME/.claude-swap-backup/cache/.statusline-refresh.lock}"
    lock_m=$(stat -f %m "$refresh_lock" 2>/dev/null || echo 0)
    case "$lock_m" in ''|*[!0-9]*) lock_m=0 ;; esac
    if [ $(( $(date +%s) - lock_m )) -gt 60 ]; then
      mkdir -p "$(dirname "$refresh_lock")" 2>/dev/null
      touch "$refresh_lock" 2>/dev/null
      ( cswap list --json >/dev/null 2>&1 ) >/dev/null 2>&1 &
    fi
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

# --- Weekly reset segment: "↻ Thu Oct 9 23:59 (1d 6h)" in local time ---
# Appended to the account segment. A reset time already in the past means the
# cached numbers predate the reset (refresh pending / token dead): dim marker.
week_reset_segment() {
  local e="$week_reset_epoch" now left d h m when
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  left=$(( e - now ))
  if [ "$left" -le 0 ]; then
    printf '%s↻ week reset — refreshing%s' "$DIM" "$RESET"
    return 0
  fi
  when=$(date -r "$e" '+%a %b %-d %H:%M' 2>/dev/null) || return 0
  d=$(( left / 86400 )); h=$(( left % 86400 / 3600 )); m=$(( left % 3600 / 60 ))
  if [ "$d" -gt 0 ]; then left="${d}d ${h}h"
  elif [ "$h" -gt 0 ]; then left="${h}h ${m}m"
  else left="${m}m"; fi
  printf '↻ %s %s(%s)%s' "$when" "$DIM" "$left" "$RESET"
}

# --- Line 3: the OTHER accounts' limits (one line each; omitted with 1 account) ---
# "↳ personal [1] 5h 10% · week 85% · Fable 100% ↻ Thu Oct 9 17:59 (1d 1h)"
# Same cswap cache as the meters. An inactive account consumes nothing, so a
# window whose reset time has passed is genuinely back at 0% — shown as such.
# Dead token (cswap lastError invalid_grant / auth strikes) -> "⚠ relogin".
# Cached numbers older than 15 min get a dim "(Nm old)".
# fmt_pct <pct> -> colored integer percentage (same thresholds as the bars)
fmt_pct() {
  local v
  v=$(awk -v p="$1" 'BEGIN { v = int(p + 0.5); if (v < 0) v = 0; if (v > 100) v = 100; print v }')
  if [ "$v" -ge 80 ]; then printf '%s%d%%%s' "$RED" "$v" "$RESET"
  elif [ "$v" -ge 50 ]; then printf '%s%d%%%s' "$YELLOW" "$v" "$RESET"
  else printf '%s%d%%%s' "$GREEN" "$v" "$RESET"; fi
}
# fmt_left <seconds> -> "1d 6h" / "3h 12m" / "8m"
fmt_left() {
  local l="$1" d h m
  d=$(( l / 86400 )); h=$(( l % 86400 / 3600 )); m=$(( l % 3600 / 60 ))
  if [ "$d" -gt 0 ]; then printf '%dd %dh' "$d" "$h"
  elif [ "$h" -gt 0 ]; then printf '%dh %dm' "$h" "$m"
  else printf '%dm' "$m"; fi
}
other_accounts_lines() {
  local seq_json="${SWAP_SEQ_JSON:-$HOME/.claude-swap-backup/sequence.json}"
  local cache="${SWAP_USAGE_JSON:-$HOME/.claude-swap-backup/cache/usage.json}"
  local now rows label slot p5 r5 p7 r7 pf rf dead fetched seg part out=""
  command -v jq >/dev/null 2>&1 && [ -r "$seq_json" ] || return 0
  [ -r "$cache" ] || cache=/dev/null
  now=$(date +%s)
  rows=$(jq -r -n --slurpfile s "$seq_json" --slurpfile c "$cache" '
    def ep: if type == "string" and test("(Z|\\+00:00)$")
            then (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
                  | try (fromdateiso8601 | floor | tostring) catch "")
            else "" end;
    def s: if . == null then "" else tostring end;
    ($s[0] // {}) as $seq | (($c[0] // {}).accounts // {}) as $acc
    | (($seq.activeAccountNumber // "") | tostring) as $active
    | ($seq.sequence // ($seq.accounts // {} | keys | map(tonumber? // .)))[]
    | tostring as $n
    | select($n != $active)
    | ($seq.accounts[$n] // {}) as $a | ($acc[$n] // {}) as $u | ($u.lastGood // {}) as $g
    | (first($g.scoped[]? | select(.name == "Fable")) // {}) as $f
    | [ (($a.alias // "") | s | if . == "" then (($a.email // "?") | split("@")[0]) else . end),
        $n,
        ($g.five_hour.pct | s), ($g.five_hour.resets_at | ep),
        ($g.seven_day.pct | s), ($g.seven_day.resets_at | ep),
        ($f.pct | s), ($f.resets_at | ep),
        (if ($u.lastError // "") == "invalid_grant" or (($u.authDeadStrikes // 0) > 0) then "1" else "" end),
        ($u.fetchedAt // "" | s | sub("\\..*"; "")) ]
    | join("\u001f")' 2>/dev/null) || return 0
  [ -n "$rows" ] || return 0
  # \x1f, not tab: read collapses consecutive whitespace delimiters (empty fields).
  while IFS=$'\x1f' read -r label slot p5 r5 p7 r7 pf rf dead fetched; do
    [ -n "$slot" ] || continue
    seg="↳ ${BOLD}${label}${RESET} [${slot}]"
    # window <name> <pct> <reset-epoch>: passed reset -> 0% (inactive = unused)
    for part in "5h|$p5|$r5" "week|$p7|$r7" "Fable|$pf|$rf"; do
      local nm="${part%%|*}" rest="${part#*|}" pc re
      pc="${rest%%|*}"; re="${rest#*|}"
      case "$re" in ''|*[!0-9]*) : ;; *) [ "$re" -le "$now" ] && pc=0 ;; esac
      if [ -z "$pc" ] || [ "$pc" = "null" ]; then
        seg="$seg ${DIM}${nm} n/a${RESET}"
      else
        seg="$seg ${nm} $(fmt_pct "$pc")"
      fi
      [ "$nm" = "Fable" ] || seg="$seg ·"
    done
    case "$r7" in
      ''|*[!0-9]*) : ;;
      *) if [ "$r7" -gt "$now" ]; then
           seg="$seg ↻ $(date -r "$r7" '+%a %b %-d %H:%M') ${DIM}($(fmt_left $(( r7 - now ))))${RESET}"
         fi ;;
    esac
    [ -n "$dead" ] && seg="$seg ${RED}⚠ relogin${RESET}"
    case "$fetched" in
      ''|*[!0-9]*) [ -z "$p7$p5" ] && seg="$seg ${DIM}(no usage data)${RESET}" ;;
      *) [ $(( now - fetched )) -gt 900 ] && seg="$seg ${DIM}($(fmt_left $(( now - fetched ))) old)${RESET}" ;;
    esac
    out="${out}${seg}"$'\n'
  done <<< "$rows"
  printf '%s' "$out"
}

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
  reset_seg=$(week_reset_segment 2>/dev/null) || reset_seg=""
  [ -n "$reset_seg" ] && line1="$line1 ${reset_seg}"
fi

# --- Line 2: usage bars, all on one line ---
line2="$(render_bar "ctx" "$ctx_used") | $(render_bar "5h" "$five_hour") | $(render_bar "week" "$seven_day") | $(render_bar "Fable" "$fable_pct")"
# Honest-staleness marker: if the usage cache is >10 min old despite the
# refresher (cswap gone, network down), say so instead of showing stale
# numbers as if they were live.
if [ -n "$usage_age" ] && [ "$usage_age" -gt 600 ]; then
  line2="$line2 ${DIM}(usage $((usage_age / 60))m old)${RESET}"
fi

printf "%s\n" "$line1"
printf "%s\n" "$line2"
# SWAP_HIDE_OTHERS=1 hides the other-accounts line(s).
if [ -z "${SWAP_HIDE_OTHERS:-}" ]; then
  others=$(other_accounts_lines 2>/dev/null) || others=""
  [ -n "$others" ] && printf "%s\n" "$others"
fi

# Update badge: a newer overclaude is on PyPI. The check itself runs in the
# background at most once a day (swap-guard version-check); a render only reads
# its cache, so the statusline never waits on the network.
update_line() {
  local st="$HOME/.claude-swap-backup" cache kit latest checked now lock sg="$HOME/.local/bin/swap-guard"
  [ -z "${OVERCLAUDE_NO_UPDATE_CHECK:-}" ] && command -v jq >/dev/null 2>&1 || return 0
  cache="$st/cache/latest-version.json"
  kit=$(cat "$st/kit-version" 2>/dev/null); [ -n "$kit" ] || return 0
  now=$(date +%s)
  checked=$(jq -r '.checkedAt // 0' "$cache" 2>/dev/null)
  case "$checked" in ''|*[!0-9]*) checked=0 ;; esac
  if [ $(( now - checked )) -ge 86400 ] && [ -z "${SWAP_NO_REFRESH:-}" ] && [ -x "$sg" ]; then
    lock="$st/cache/version-check.lock"
    # One background check per 5 minutes at most, however many sessions render.
    if [ -z "$(find "$lock" -mmin -5 2>/dev/null)" ]; then
      mkdir -p "$st/cache" && touch "$lock" && ( "$sg" version-check >/dev/null 2>&1 & )
    fi
  fi
  latest=$(jq -r '.version // empty' "$cache" 2>/dev/null)
  [ -n "$latest" ] && [ "$latest" != "$kit" ] || return 0
  [ "$(printf '%s\n%s\n' "$kit" "$latest" | sort -V | tail -1)" = "$latest" ] || return 0
  if command -v overclaude >/dev/null 2>&1; then
    printf '%s⬆ overclaude %s available · overclaude update%s\n' "$DIM" "$latest" "$RESET"
  else   # a git checkout install has no CLI
    printf '%s⬆ overclaude %s available · git pull && ./install.sh%s\n' "$DIM" "$latest" "$RESET"
  fi
}
upd=$(update_line 2>/dev/null) || upd=""
[ -n "$upd" ] && printf "%s\n" "$upd"
exit 0
