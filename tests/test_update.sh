#!/bin/bash
# Update notice: swap-guard version-check (daily, cached), the statusline badge,
# and the CLI's choice of upgrade command.
. "$(dirname "$0")/lib.sh"
new_home
ST="$HOME/.claude-swap-backup"
echo "1.2.0" > "$ST/kit-version"

STUB="$HOME/stubbin"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'EOF'
#!/bin/bash
echo call >> "$HOME/curl-calls"
[ -n "${STUB_OFFLINE:-}" ] && exit 6
printf '{"info":{"version":"%s"}}\n' "${STUB_LATEST:-1.3.0}"
EOF
chmod +x "$STUB/curl"
export PATH="$STUB:$PATH"
calls() { wc -l < "$HOME/curl-calls" 2>/dev/null | tr -d ' ' || echo 0; }

out="$("$SG" version-check)"
assert_eq "$(printf '%s' "$out" | jq -r .version)" "1.3.0" "version-check reads PyPI's latest"
assert_eq "$(printf '%s' "$out" | jq -r .installed)" "1.2.0" "and reports the installed kit version"
"$SG" version-check >/dev/null
assert_eq "$(calls)" "1" "a second check within a day uses the cache"
jq --argjson t $(( $(date +%s) - 3600 )) '.checkedAt = $t' "$ST/cache/latest-version.json" > "$HOME/t" && mv "$HOME/t" "$ST/cache/latest-version.json"; touch "$ST/kit-version"
STUB_LATEST=1.3.1 "$SG" version-check >/dev/null
assert_eq "$(jq -r .version "$ST/cache/latest-version.json")" "1.3.1" "a check older than the last install is refreshed"
"$SG" version-check >/dev/null
assert_eq "$(calls)" "2" "then cached again"
STUB_LATEST=1.3.0 "$SG" version-check --force >/dev/null

jq '.checkedAt = 1' "$ST/cache/latest-version.json" > "$HOME/t" && mv "$HOME/t" "$ST/cache/latest-version.json"
STUB_OFFLINE=1 "$SG" version-check >/dev/null
assert_eq "$(jq -r .version "$ST/cache/latest-version.json")" "1.3.0" "offline keeps the last known version"
assert_eq "$(jq -r .error "$ST/cache/latest-version.json")" "unreachable" "offline attempt is recorded (retry tomorrow)"

render() { echo '{"model":{"display_name":"m"},"workspace":{"current_dir":"/x"},"context_window":{"used_percentage":1}}' | bash "$SL" | strip_ansi; }
assert_contains "$(render)" "⬆ overclaude 1.3.0 available" "statusline shows the badge when outdated"
echo "1.3.0" > "$ST/kit-version"
assert_absent "$(render)" "available" "no badge when up to date"
echo "1.4.0" > "$ST/kit-version"
assert_absent "$(render)" "available" "no badge when ahead (a dev build)"
echo "1.2.0" > "$ST/kit-version"
assert_absent "$(OVERCLAUDE_NO_UPDATE_CHECK=1 render)" "available" "OVERCLAUDE_NO_UPDATE_CHECK hides it"

# CLI: the upgrade command follows how the package was installed.
printf '#!/bin/bash\nexit 0\n' > "$STUB/pipx"; printf '#!/bin/bash\nexit 0\n' > "$STUB/uv"; chmod +x "$STUB/pipx" "$STUB/uv"
cmd_for() { PYTHONPATH="$REPO/src" python3 -c "
import sys; sys.prefix = '$1'
from overclaude import cli; print(' '.join(cli._upgrade_command()[:3]))" 2>/dev/null; }
assert_eq "$(cmd_for "$HOME/.local/pipx/venvs/overclaude")" "pipx upgrade overclaude" "pipx install → pipx upgrade"
assert_eq "$(cmd_for "$HOME/.local/share/uv/tools/overclaude")" "uv tool upgrade" "uv tool install → uv tool upgrade"
assert_contains "$(cmd_for /usr/local)" "-m pip" "anything else → pip"

rm -rf "$HOME"
finish
