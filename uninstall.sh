#!/bin/bash
# uninstall.sh — overclaude uninstaller.
# macOS /bin/bash 3.2 compatible. set -u; errors handled explicitly.
# Removes what install.sh added. Does NOT touch ~/.claude-swap-backup (user state).

set -u

CLAUDE_DIR="$HOME/.claude"
LOCALBIN="$HOME/.local/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
ZSHRC="$HOME/.zshrc"

BEGIN_MARKER='# --- claude-swap integration (begin) ---'
END_MARKER='# --- claude-swap integration (end) ---'

EPOCH=$(date +%s)

DID=()
SKIPPED=()
WARNED=()
note_did()  { DID[${#DID[@]}]="$1"; echo "  [-] $1"; }
note_skip() { SKIPPED[${#SKIPPED[@]}]="$1"; echo "  [=] $1"; }
note_warn() { WARNED[${#WARNED[@]}]="$1"; echo "  [!] $1" >&2; }
die()       { echo "uninstall: ERROR: $1" >&2; exit 1; }

backup_file() {
  bf_path="$1"
  if [ -f "$bf_path" ]; then
    cp -p "$bf_path" "$bf_path.bak-$EPOCH" || die "backup failed: $bf_path"
    echo "$bf_path.bak-$EPOCH"
  fi
}

echo "== overclaude uninstaller =="
echo "   epoch: $EPOCH"
echo

# ---------------------------------------------------------------------------
# 1. Remove copied files.
# ---------------------------------------------------------------------------
echo "-- files --"
for p in \
  "$LOCALBIN/swap-guard" \
  "$CLAUDE_DIR/skills/swap/SKILL.md" \
  "$CLAUDE_DIR/skills/handoff/SKILL.md" \
  "$CLAUDE_DIR/hooks/handoff-inject.sh" \
  "$CLAUDE_DIR/hooks/ctx-watch.sh" \
  "$CLAUDE_DIR/hooks/ctx-notify.sh" \
  "$CLAUDE_DIR/statusline-command.sh" \
  "$CLAUDE_DIR/ULTRACODE.md" ; do
  if [ -f "$p" ]; then
    rm -f "$p" && note_did "removed $p" || note_warn "could not remove $p"
  else
    note_skip "not present: $p"
  fi
done

# Prune now-empty skill directories (never touch anything non-empty).
for d in "$CLAUDE_DIR/skills/swap" "$CLAUDE_DIR/skills/handoff"; do
  [ -d "$d" ] && rmdir "$d" 2>/dev/null && note_did "removed empty dir $d"
done
echo

# ---------------------------------------------------------------------------
# 2. CLAUDE.md — remove the @ULTRACODE.md import line.
# ---------------------------------------------------------------------------
echo "-- CLAUDE.md --"
if [ -f "$CLAUDE_MD" ] && grep -qxF '@ULTRACODE.md' "$CLAUDE_MD"; then
  b=$(backup_file "$CLAUDE_MD")
  # Delete only exact-match lines "@ULTRACODE.md".
  awk '$0 != "@ULTRACODE.md"' "$CLAUDE_MD" >"$CLAUDE_MD.tmp-$EPOCH" \
    && mv "$CLAUDE_MD.tmp-$EPOCH" "$CLAUDE_MD" \
    && note_did "removed @ULTRACODE.md line from $CLAUDE_MD (backup: $b)" \
    || note_warn "could not edit $CLAUDE_MD"
else
  note_skip "no @ULTRACODE.md line in CLAUDE.md"
fi
echo

# ---------------------------------------------------------------------------
# 3. .zshrc — delete the block between the begin/end markers (inclusive).
# ---------------------------------------------------------------------------
echo "-- .zshrc --"
if [ -f "$ZSHRC" ] && grep -qF "$BEGIN_MARKER" "$ZSHRC"; then
  b=$(backup_file "$ZSHRC")
  # Buffers runs of blank lines so the single separator blank that install.sh
  # adds before the block is consumed with it (keeps install/uninstall cycles
  # byte-idempotent); at most one blank is dropped, user blank lines survive.
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    $0 == b { drop = 1
              if (pending > 0) pending--
              while (pending > 0) { print ""; pending-- } }
    drop != 1 {
      if ($0 == "") { pending++ }
      else { while (pending > 0) { print ""; pending-- }; print }
    }
    $0 == e { drop = 0 }
    END { while (pending > 0) { print ""; pending-- } }
  ' "$ZSHRC" >"$ZSHRC.tmp-$EPOCH" \
    && mv "$ZSHRC.tmp-$EPOCH" "$ZSHRC" \
    && note_did "removed claude-swap block from $ZSHRC (backup: $b)" \
    || note_warn "could not edit $ZSHRC"
  note_warn "Open a new shell for the change to take effect."
else
  note_skip "no claude-swap block in .zshrc"
fi
echo

# ---------------------------------------------------------------------------
# 4. settings.json — remove ONLY our entries (jq, exact command matches).
# ---------------------------------------------------------------------------
echo "-- settings.json --"
if [ ! -f "$SETTINGS" ]; then
  note_skip "no settings.json"
elif ! jq empty "$SETTINGS" >/dev/null 2>&1; then
  note_warn "$SETTINGS is not valid JSON; leaving it untouched."
else
  CLEANED=$(jq '
    def dropgroups($evt; $cmd):
      if (.hooks[$evt]? | type) == "array"
      then .hooks[$evt] |= map(select((any(.hooks[]?; (.command // "") == $cmd)) | not))
      else . end;
    .
    | (if (.permissions.allow) != null then
         .permissions.allow |= map(select(. != "Bash(cswap *)" and . != "Bash(swap-guard *)"))
       else . end)
    | dropgroups("SessionStart";    "bash ~/.claude/hooks/handoff-inject.sh")
    | dropgroups("UserPromptSubmit"; "bash ~/.claude/hooks/ctx-watch.sh")
    | dropgroups("Stop";            "bash ~/.claude/hooks/ctx-notify.sh")
    | (if (.statusLine.command // "") == "bash ~/.claude/statusline-command.sh"
         then del(.statusLine) else . end)
    # Prune structures that we emptied (never delete non-empty user content).
    | (if (.permissions.allow?) == [] then del(.permissions.allow) else . end)
    | (if (.permissions?) == {} then del(.permissions) else . end)
    | (if (.hooks.SessionStart?) == [] then del(.hooks.SessionStart) else . end)
    | (if (.hooks.UserPromptSubmit?) == [] then del(.hooks.UserPromptSubmit) else . end)
    | (if (.hooks.Stop?) == [] then del(.hooks.Stop) else . end)
    | (if (.hooks?) == {} then del(.hooks) else . end)
  ' "$SETTINGS") || die "jq cleanup failed for settings.json"

  CUR_NORM=$(jq -S . "$SETTINGS" 2>/dev/null)
  NEW_NORM=$(printf '%s' "$CLEANED" | jq -S . 2>/dev/null)
  if [ "$CUR_NORM" = "$NEW_NORM" ]; then
    note_skip "settings.json has no kit entries (no change)"
  else
    b=$(backup_file "$SETTINGS")
    printf '%s\n' "$CLEANED" | jq . >"$SETTINGS.tmp-$EPOCH" || die "could not render settings.json"
    mv "$SETTINGS.tmp-$EPOCH" "$SETTINGS" || die "could not write $SETTINGS"
    note_did "removed kit entries from settings.json (backup: $b)"
  fi
fi
echo

# ---------------------------------------------------------------------------
# Summary + state note.
# ---------------------------------------------------------------------------
echo "== summary =="
echo "  changed:  ${#DID[@]}"
echo "  skipped:  ${#SKIPPED[@]}"
echo "  warnings: ${#WARNED[@]}"
echo
echo "NOTE: runtime state under ~/.claude-swap-backup/ was left in place (user data)."
echo "      To remove it as well, run:  rm -rf ~/.claude-swap-backup"
echo "      Timestamped .bak-$EPOCH backups of edited files were kept alongside them."
echo "Done."
