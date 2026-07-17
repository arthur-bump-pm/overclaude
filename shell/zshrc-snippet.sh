# --- claude-swap integration (begin) ---
# swap-guard is installed to ~/.local/bin — ensure it is on PATH.
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
alias swap='cswap switch'
claude() {
  command claude "$@"
  local rc=$?
  local f
  f=$(swap-guard path flag --cwd "$PWD" 2>/dev/null) || return $rc
  while [ -f "$f" ]; do
    local mode sid created fcwd now
    mode=$(jq -r '.mode // empty' "$f" 2>/dev/null)
    sid=$(jq -r '.sessionId // empty' "$f" 2>/dev/null)
    created=$(jq -r '.created // 0' "$f" 2>/dev/null)
    fcwd=$(jq -r '.cwd // empty' "$f" 2>/dev/null)
    rm -f "$f"
    case "$created" in ''|*[!0-9]*) created=0 ;; esac
    now=$(date +%s)
    if [ "$fcwd" != "$PWD" ] || [ $((now - created)) -gt 300 ]; then
      echo "claude-swap: ignoring stale relaunch flag (cwd/TTL mismatch): $f" >&2
      break
    fi
    case "$mode" in
      restart) [ -n "$sid" ] || break; command claude --resume "$sid" ;;
      handoff) command claude ;;
      *) break ;;
    esac
  done
  return $rc
}
# --- claude-swap integration (end) ---
