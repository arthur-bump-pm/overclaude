#!/bin/bash
# install.sh / uninstall.sh in a throwaway $HOME: every fragment hook lands, the user's
# own settings survive, a re-install is a no-op, and uninstall restores the original.
. "$(dirname "$0")/lib.sh"
new_home
VEND_VER=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO/vendor/claude-swap/pyproject.toml" | head -1)
STUB="$HOME/stubbin"; mkdir -p "$STUB"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "claude-swap %s"\nexit 0\n' "$VEND_VER" > "$STUB/cswap"
chmod +x "$STUB/cswap"
export PATH="$STUB:$HOME/.local/bin:$PATH"
export SWAP_GUARD_NO_LAUNCHCTL=1   # never touch the real launchd domain

S="$HOME/.claude/settings.json"
cat > "$S" <<'EOF'
{"model": "opus",
 "permissions": {"allow": ["Bash(git status)"]},
 "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-hook"}]}],
           "Stop": [{"hooks": [{"type": "command", "command": "say done"}]}]}}
EOF
ORIG="$(jq -S . "$S")"

bash "$REPO/install.sh" >/dev/null 2>&1
assert_eq "$?" "0" "install exits 0"
for pair in "SessionStart:handoff-inject.sh" "UserPromptSubmit:ctx-watch.sh" "UserPromptSubmit:swap-guard budget --hook" \
            "Stop:ctx-notify.sh" "StopFailure:swap-guard ratelimit" "PostToolUse:swap-guard artifact-log"; do
  ev="${pair%%:*}"; hk="${pair#*:}"
  assert_eq "$(jq --arg e "$ev" --arg h "$hk" '[.hooks[$e][]?.hooks[]?.command // "" | select(contains($h))] | length' "$S")" "1" "$ev hook → $hk registered once"
done
assert_eq "$(jq -r '.hooks.StopFailure[0].matcher' "$S")" "rate_limit" "StopFailure matcher is rate_limit"
assert_eq "$(jq -r '.hooks.StopFailure[0].hooks[0].asyncRewake' "$S")" "true" "rate-limit hook can wake the session"
assert_eq "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")" "my-own-hook" "the user's own hook survives"
assert_eq "$(jq -r '.model' "$S")" "opus" "unrelated settings survive"
assert_eq "$([ -x "$HOME/.local/bin/swap-guard" ] && echo yes)" "yes" "swap-guard installed"

AFTER1="$(jq -S . "$S")"
bash "$REPO/install.sh" >/dev/null 2>&1
assert_eq "$(jq -S . "$S")" "$AFTER1" "a second install changes nothing"

bash "$REPO/uninstall.sh" >/dev/null 2>&1
assert_eq "$?" "0" "uninstall exits 0"
assert_eq "$(jq -S . "$S")" "$ORIG" "uninstall restores the original settings exactly"
assert_eq "$([ -e "$HOME/.local/bin/swap-guard" ] && echo present || echo gone)" "gone" "swap-guard removed"
assert_absent "$(cat "$HOME/.zshrc" 2>/dev/null)" "claude-swap integration (begin)" "zshrc block removed"

rm -rf "$HOME"
finish
