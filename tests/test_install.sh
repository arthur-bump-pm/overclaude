#!/bin/bash
# install.sh / uninstall.sh in a throwaway $HOME: every fragment hook lands, the user's
# own settings survive, a re-install is a no-op, and uninstall restores the original.
. "$(dirname "$0")/lib.sh"
new_home
VEND_VER=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$REPO/vendor/claude-swap/pyproject.toml" | head -1)
STUB="$HOME/stubbin"; mkdir -p "$STUB"
printf '#!/bin/bash\n[ "$1" = --version ] && echo "claude-swap %s"\n[ "$1" = list ] && echo "{\\"accounts\\":[]}"\nexit 0\n' "$VEND_VER" > "$STUB/cswap"
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

bash "$REPO/install.sh" > "$HOME/i1.log" 2>&1
assert_eq "$?" "0" "install exits 0"
assert_contains "$(cat "$HOME/i1.log")" "Instant swap is ON" "the installer says when it turns instant swap on"
assert_absent "$(cat "$HOME/i1.log")" "Routing guard" "no routing guard is installed"
assert_eq "$(jq '[.hooks[]?[]?.hooks[]?.command // "" | select(contains("route-guard"))] | length' "$S")" "0" "and no route-guard hook"
assert_eq "$([ -e "$HOME/.claude/ULTRACODE.md" ] && echo yes || echo no)" "no" "no ULTRACODE.md is shipped"
assert_eq "$([ -e "$HOME/.claude/CLAUDE.md" ] && echo yes || echo no)" "no" "and CLAUDE.md is not created"
for pair in "SessionStart:handoff-inject.sh" "UserPromptSubmit:ctx-watch.sh" "UserPromptSubmit:swap-guard budget --hook" \
            "Stop:ctx-notify.sh" "StopFailure:swap-guard ratelimit" "PostToolUse:swap-guard artifact-log" \
            "StopFailure:swap-guard server-retry" "PostToolUseFailure:swap-guard loop-guard" "PostToolUse:swap-guard checkpoint"; do
  ev="${pair%%:*}"; hk="${pair#*:}"
  assert_eq "$(jq --arg e "$ev" --arg h "$hk" '[.hooks[$e][]?.hooks[]?.command // "" | select(contains($h))] | length' "$S")" "1" "$ev hook → $hk registered once"
done
assert_eq "$(jq -r '.hooks.StopFailure[0].matcher' "$S")" "rate_limit" "StopFailure matcher is rate_limit"
assert_eq "$(jq -r '.hooks.StopFailure[0].hooks[0].asyncRewake' "$S")" "true" "rate-limit hook can wake the session"
assert_eq "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$S")" "my-own-hook" "the user's own hook survives"
assert_eq "$(jq -r '.model' "$S")" "opus" "unrelated settings survive"
assert_eq "$([ -x "$HOME/.local/bin/swap-guard" ] && echo yes)" "yes" "swap-guard installed"

assert_eq "$([ -x "$HOME/.local/bin/overclaude-codex-continue" ] && echo yes)" "yes" "Codex continuation runner installed"
assert_eq "$([ -x "$HOME/.local/bin/overclaude-codex-probe" ] && echo yes)" "yes" "Codex policy probe installed"
assert_eq "$([ -x "$HOME/.local/bin/overclaude-codex-pool" ] && echo yes)" "yes" "Codex pool preview installed"

KA="$HOME/Library/LaunchAgents/com.overclaude.keepalive.plist"
assert_eq "$([ -f "$KA" ] && echo yes)" "yes" "install turns the keepalive agent on"
assert_contains "$(cat "$HOME/i1.log")" "keepalive agent on" "and says so"
MW="$HOME/Library/LaunchAgents/com.overclaude.memwatch.plist"
assert_eq "$([ -f "$MW" ] && echo yes)" "yes" "install turns the memory watcher on"
assert_contains "$(cat "$MW")" "<string>tick</string>" "…running mem tick"
assert_eq "$(jq '[.hooks.PreToolUse[]? | select(.matcher == "Agent|Task|Workflow") | .hooks[]?.command // "" | select(contains("swap-guard mem --gate"))] | length' "$S")" "1" "the memory gate hook is registered once, on Agent|Task|Workflow"

AFTER1="$(jq -S . "$S")"
bash "$REPO/install.sh" > "$HOME/i2.log" 2>&1
assert_absent "$(cat "$HOME/i2.log")" "Instant swap is ON" "and only the first time"
assert_eq "$(jq -S . "$S")" "$AFTER1" "a second install changes nothing"
assert_contains "$(cat "$HOME/i2.log")" "keepalive agent already on" "a re-install only reloads the keepalive agent"
"$HOME/.local/bin/swap-guard" keepalive on --interval 3600 >/dev/null
bash "$REPO/install.sh" >/dev/null 2>&1
assert_eq "$(plutil -extract StartInterval raw "$KA")" "3600" "a re-install keeps a custom keepalive interval"
"$HOME/.local/bin/swap-guard" keepalive off >/dev/null
bash "$REPO/install.sh" > "$HOME/i3.log" 2>&1
assert_eq "$([ -f "$KA" ] && echo yes || echo no)" "no" "a re-install respects keepalive off"
assert_contains "$(cat "$HOME/i3.log")" "keepalive agent is off" "and says how to turn it back on"
"$HOME/.local/bin/swap-guard" keepalive on >/dev/null
"$HOME/.local/bin/swap-guard" mem watch off >/dev/null
bash "$REPO/install.sh" > "$HOME/i4.log" 2>&1
assert_eq "$([ -f "$MW" ] && echo yes || echo no)" "no" "a re-install respects mem watch off"
assert_contains "$(cat "$HOME/i4.log")" "memory watcher is off" "and says how to turn it back on"
"$HOME/.local/bin/swap-guard" mem watch on >/dev/null
# Upgrade from 1.4: its settings had no server-retry or loop-guard hooks.
jq '.hooks.StopFailure |= map(select([.hooks[]?.command // "" | contains("server-retry")] | any | not))
    | del(.hooks.PostToolUseFailure)' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
bash "$REPO/install.sh" >/dev/null 2>&1
for pair in "StopFailure:swap-guard ratelimit" "StopFailure:swap-guard server-retry" "PostToolUseFailure:swap-guard loop-guard" "PostToolUse:swap-guard checkpoint"; do
  ev="${pair%%:*}"; hk="${pair#*:}"
  assert_eq "$(jq --arg e "$ev" --arg h "$hk" '[.hooks[$e][]?.hooks[]?.command // "" | select(contains($h))] | length' "$S")" "1" "upgrade from 1.4: $ev → $hk registered once"
done
assert_eq "$(jq -S . "$S")" "$AFTER1" "and the result equals a fresh install"

bash "$REPO/uninstall.sh" >/dev/null 2>&1
assert_eq "$?" "0" "uninstall exits 0"
assert_eq "$(jq -S . "$S")" "$ORIG" "uninstall restores the original settings exactly"
assert_eq "$([ -e "$HOME/.local/bin/swap-guard" ] && echo present || echo gone)" "gone" "swap-guard removed"
assert_eq "$([ -f "$KA" ] && echo yes || echo no)" "no" "uninstall removes the keepalive agent"
assert_absent "$(cat "$HOME/.zshrc" 2>/dev/null)" "claude-swap integration (begin)" "zshrc block removed"

# A damaged end marker must never cost the user the rest of their .zshrc; mode + symlink kept.
mkdir -p "$HOME/dotfiles"; printf 'export EDITOR=vim\n' > "$HOME/dotfiles/zshrc"; chmod 600 "$HOME/dotfiles/zshrc"
rm -f "$HOME/.zshrc"; ln -s "$HOME/dotfiles/zshrc" "$HOME/.zshrc"
bash "$REPO/install.sh" >/dev/null 2>&1
assert_eq "$([ -L "$HOME/.zshrc" ] && echo link)" "link" "install keeps a symlinked .zshrc a symlink"
sed -i '' 's/^# --- claude-swap integration (end) ---$/& /' "$HOME/dotfiles/zshrc"
printf 'alias gs="git status"\n' >> "$HOME/dotfiles/zshrc"
bash "$REPO/uninstall.sh" > "$HOME/u2.log" 2>&1
assert_contains "$(cat "$HOME/dotfiles/zshrc")" 'alias gs="git status"' "an edited end marker never truncates the user's .zshrc"
assert_contains "$(cat "$HOME/u2.log")" "left untouched" "and uninstall says it left the block alone"
sed -i '' 's/^\(# --- claude-swap integration (end) ---\) $/\1/' "$HOME/dotfiles/zshrc"
bash "$REPO/uninstall.sh" >/dev/null 2>&1
assert_eq "$(cat "$HOME/dotfiles/zshrc")" "$(printf 'export EDITOR=vim\nalias gs="git status"')" "with the markers intact only the block goes"
assert_eq "$([ -L "$HOME/.zshrc" ] && echo link)" "link" "uninstall keeps the symlink"
assert_eq "$(stat -f %Lp "$HOME/dotfiles/zshrc")" "600" "and the file mode"

assert_eq "$([ -e "$HOME/.local/bin/overclaude-codex-continue" ] && echo present || echo gone)" "gone" "Codex continuation runner removed"
assert_eq "$([ -e "$HOME/.local/bin/overclaude-codex-probe" ] && echo present || echo gone)" "gone" "Codex policy probe removed"
assert_eq "$([ -e "$HOME/.local/bin/overclaude-codex-pool" ] && echo present || echo gone)" "gone" "Codex pool preview removed"
# An update from an older version takes away what it added: ULTRACODE.md, the
# @ULTRACODE.md import (the user's own lines stay) and the routing-guard hook
# (the user's own hooks stay), each backed up first.
rm -rf "$HOME"
new_home; export SWAP_GUARD_NO_LAUNCHCTL=1
export PATH="$STUB:$HOME/.local/bin:$PATH"
S="$HOME/.claude/settings.json"
printf 'my policy\n' > "$HOME/.claude/ULTRACODE.md"
printf '%s\n' 'my rules' '@ULTRACODE.md' 'more' > "$HOME/.claude/CLAUDE.md"
cat > "$S" <<'EOF'
{"hooks": {"PreToolUse": [{"matcher": "Agent|Task|Workflow", "hooks": [{"type": "command", "command": "~/.local/bin/swap-guard route-guard", "timeout": 10}]},
                          {"matcher": "Bash", "hooks": [{"type": "command", "command": "my-own-hook"}]}]}}
EOF
bash "$REPO/install.sh" > "$HOME/u.log" 2>&1
assert_eq "$?" "0" "an update over an older install exits 0"
assert_eq "$([ -e "$HOME/.claude/ULTRACODE.md" ] && echo yes || echo no)" "no" "the old ULTRACODE.md is removed"
assert_eq "$(cat "$HOME/.claude/CLAUDE.md")" "$(printf 'my rules\nmore')" "the @ULTRACODE.md line goes, the user's lines stay"
assert_eq "$(jq '[.hooks[]?[]?.hooks[]?.command // "" | select(contains("route-guard"))] | length' "$S")" "0" "the route-guard hook is removed"
assert_eq "$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command] | index("my-own-hook") != null' "$S")" "true" "the user's own PreToolUse hook stays"
assert_eq "$(cat "$HOME/.claude-swap-backup/retired/ULTRACODE.md."*)" "my policy" "ULTRACODE.md is backed up first"
assert_contains "$(cat "$HOME/.claude-swap-backup/retired/CLAUDE.md."*)" "@ULTRACODE.md" "and CLAUDE.md"
assert_contains "$(cat "$HOME/.claude-swap-backup/retired/settings.json."*)" "route-guard" "and settings.json"
tx="$(ls "$HOME/.claude-swap-backup/install-transactions" | grep -v '^\.' | tail -n 1)"
assert_eq "$(jq -r '.entries[] | select(.rel == ".claude/ULTRACODE.md") | [.before.exists, .after.exists, .status] | map(tostring) | join(",")' "$HOME/.claude-swap-backup/install-transactions/$tx/journal.json")" "true,false,applied" "the journal records the removal (recoverable)"
assert_eq "$(OVERCLAUDE_VERSION= bash "$REPO/install.sh" > "$HOME/u2.log" 2>&1; echo $?)" "0" "a second install loads that journal and is a no-op"
assert_eq "$("$HOME/.local/bin/swap-guard" route-guard < /dev/null; echo "rc=$?")" "rc=0" "a leftover hook calling route-guard is a silent no-op, never a block"

# A CRLF CLAUDE.md (or one with trailing spaces): the import line still goes, and
# the file is backed up first, by the same rule the removal uses.
rm -rf "$HOME"; new_home
export PATH="$STUB:$HOME/.local/bin:$PATH" SWAP_GUARD_NO_LAUNCHCTL=1
printf '%s\r\n' 'my rules' '@ULTRACODE.md  ' 'more' > "$HOME/.claude/CLAUDE.md"
bash "$REPO/install.sh" > "$HOME/c.log" 2>&1
assert_eq "$?" "0" "install over a CRLF CLAUDE.md exits 0"
assert_eq "$(od -c "$HOME/.claude/CLAUDE.md" | tr -s ' ')" "$(printf 'my rules\r\nmore\r\n' | od -c | tr -s ' ')" "the CRLF import line goes; the other lines keep their CRLF"
assert_eq "$(ls "$HOME/.claude-swap-backup/retired/" 2>/dev/null | grep -c '^CLAUDE.md\.')" "1" "and CLAUDE.md is backed up first"
rm -rf "$HOME"
finish
