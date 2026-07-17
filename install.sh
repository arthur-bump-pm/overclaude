#!/bin/bash
# install.sh — overclaude installer.
# macOS /bin/bash 3.2 compatible. set -u; errors handled explicitly.
# Reproduces the /swap + /handoff Claude Code multi-account setup on this machine.

set -u

# ---------------------------------------------------------------------------
# Locate the kit (this script lives at the repo root).
# ---------------------------------------------------------------------------
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

CLAUDE_DIR="$HOME/.claude"
LOCALBIN="$HOME/.local/bin"
SETTINGS="$CLAUDE_DIR/settings.json"
CLAUDE_MD="$CLAUDE_DIR/CLAUDE.md"
ZSHRC="$HOME/.zshrc"

FRAG="$SCRIPT_DIR/settings/settings-fragment.json"
ZSNIPPET="$SCRIPT_DIR/shell/zshrc-snippet.sh"

BEGIN_MARKER='# --- claude-swap integration (begin) ---'

EPOCH=$(date +%s)

# Summary accumulators (bash 3.2: plain indexed arrays).
DID=()
SKIPPED=()
WARNED=()

note_did()     { DID[${#DID[@]}]="$1"; echo "  [+] $1"; }
note_skip()    { SKIPPED[${#SKIPPED[@]}]="$1"; echo "  [=] $1"; }
note_warn()    { WARNED[${#WARNED[@]}]="$1"; echo "  [!] $1" >&2; }
die()          { echo "install: ERROR: $1" >&2; exit 1; }

echo "== overclaude installer =="
echo "   kit:   $SCRIPT_DIR"
echo "   epoch: $EPOCH"
echo

# ---------------------------------------------------------------------------
# 0. Sanity: kit files present.
# ---------------------------------------------------------------------------
for f in \
  "$SCRIPT_DIR/bin/swap-guard" \
  "$SCRIPT_DIR/skills/swap/SKILL.md" \
  "$SCRIPT_DIR/skills/handoff/SKILL.md" \
  "$SCRIPT_DIR/hooks/handoff-inject.sh" \
  "$SCRIPT_DIR/hooks/ctx-watch.sh" \
  "$SCRIPT_DIR/hooks/ctx-notify.sh" \
  "$SCRIPT_DIR/statusline/statusline-command.sh" \
  "$SCRIPT_DIR/claude/ULTRACODE.md" \
  "$FRAG" \
  "$ZSNIPPET" ; do
  [ -f "$f" ] || die "kit file missing: $f (run from the repo root)"
done

# ---------------------------------------------------------------------------
# 1. Dependency preflight.
# ---------------------------------------------------------------------------
echo "-- preflight --"
if ! command -v jq >/dev/null 2>&1; then
  die "jq is required but not found. Install it: brew install jq"
fi
echo "  [ok] jq: $(command -v jq)"

if command -v cswap >/dev/null 2>&1 || [ -x "$LOCALBIN/cswap" ]; then
  echo "  [ok] cswap: $(command -v cswap 2>/dev/null || echo "$LOCALBIN/cswap")"
else
  # cswap is vendored as a full source tree (see vendor/README.md) — install it
  # with whichever Python tool-runner is available: pipx, else uv.
  VEND_SRC="$SCRIPT_DIR/vendor/claude-swap"
  # mktemp creates the log with O_EXCL — a predictable $$-based name in /tmp
  # could be pre-planted as a symlink by another local user.
  CSWAP_LOG=$(mktemp "${TMPDIR:-/tmp}/overclaude-cswap-install.XXXXXX" 2>/dev/null) \
    || CSWAP_LOG="$HOME/.overclaude-cswap-install.log"

  # cswap_outcome <tool> <install-exit-code> — shared reporting for pipx/uv:
  # distinguishes "installer failed" from "installed but does not resolve".
  cswap_outcome() {
    co_tool="$1"; co_rc="$2"
    if [ "$co_rc" -ne 0 ]; then
      note_warn "bundled cswap install FAILED — installer output (last 15 lines):"
      tail -n 15 "$CSWAP_LOG" | sed 's/^/      /' >&2
      note_warn "full log: $CSWAP_LOG — retry manually: $co_tool \"$VEND_SRC\""
    elif command -v cswap >/dev/null 2>&1 || [ -x "$LOCALBIN/cswap" ]; then
      note_did "installed cswap from vendored source (vendor/claude-swap, via ${co_tool%% *})"
      rm -f "$CSWAP_LOG"
    else
      note_warn "cswap installed cleanly but does not resolve — likely a PATH/prefix issue."
      note_warn "  Open a new shell (or: source ~/.zshrc), then re-run the installer to re-check."
      rm -f "$CSWAP_LOG"
    fi
  }

  if [ -f "$VEND_SRC/pyproject.toml" ]; then
    if command -v pipx >/dev/null 2>&1; then
      echo "  [..] cswap not found — installing bundled copy via pipx (deps come from PyPI)..."
      pipx install "$VEND_SRC" >"$CSWAP_LOG" 2>&1; cswap_outcome "pipx install" $?
    elif command -v uv >/dev/null 2>&1; then
      echo "  [..] cswap not found — installing bundled copy via uv (deps come from PyPI)..."
      uv tool install "$VEND_SRC" >"$CSWAP_LOG" 2>&1; cswap_outcome "uv tool install" $?
    else
      note_warn "cswap not found and neither pipx nor uv is available."
      note_warn "  Install one (brew install pipx  |  brew install uv), then re-run ./install.sh."
    fi
  else
    note_warn "cswap not found and no vendored source present; install manually: pipx install claude-swap"
  fi
fi

case ":$PATH:" in
  *":$LOCALBIN:"*) echo "  [ok] $LOCALBIN is on PATH" ;;
  *) note_warn "$LOCALBIN is not on your PATH. Add it so swap-guard is found:"
     note_warn "  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac
echo

# ---------------------------------------------------------------------------
# Helpers.
# ---------------------------------------------------------------------------

# backup_file <path> — timestamped backup if the file exists. Prints backup path.
backup_file() {
  bf_path="$1"
  if [ -f "$bf_path" ]; then
    cp -p "$bf_path" "$bf_path.bak-$EPOCH" || die "backup failed: $bf_path"
    echo "$bf_path.bak-$EPOCH"
  fi
}

# install_file <src> <dest> <mode|-> — copy with backup-on-change, chmod.
# No backup, no copy when the destination is already identical.
install_file() {
  if_src="$1"; if_dest="$2"; if_mode="$3"
  mkdir -p "$(dirname "$if_dest")" || die "mkdir failed for $if_dest"
  if [ -f "$if_dest" ]; then
    if cmp -s "$if_src" "$if_dest"; then
      [ "$if_mode" != "-" ] && chmod "$if_mode" "$if_dest" 2>/dev/null
      note_skip "up-to-date: $if_dest"
      return 0
    fi
    b=$(backup_file "$if_dest")
    cp "$if_src" "$if_dest" || die "copy failed: $if_dest"
    [ "$if_mode" != "-" ] && chmod "$if_mode" "$if_dest"
    note_did "updated: $if_dest (backup: $b)"
  else
    cp "$if_src" "$if_dest" || die "copy failed: $if_dest"
    [ "$if_mode" != "-" ] && chmod "$if_mode" "$if_dest"
    note_did "installed: $if_dest"
  fi
}

# ---------------------------------------------------------------------------
# 2. File copies.
# ---------------------------------------------------------------------------
echo "-- files --"
install_file "$SCRIPT_DIR/bin/swap-guard"                 "$LOCALBIN/swap-guard"                 755
install_file "$SCRIPT_DIR/skills/swap/SKILL.md"           "$CLAUDE_DIR/skills/swap/SKILL.md"     -
install_file "$SCRIPT_DIR/skills/handoff/SKILL.md"        "$CLAUDE_DIR/skills/handoff/SKILL.md"  -
install_file "$SCRIPT_DIR/hooks/handoff-inject.sh"        "$CLAUDE_DIR/hooks/handoff-inject.sh"  755
install_file "$SCRIPT_DIR/hooks/ctx-watch.sh"             "$CLAUDE_DIR/hooks/ctx-watch.sh"       755
install_file "$SCRIPT_DIR/hooks/ctx-notify.sh"            "$CLAUDE_DIR/hooks/ctx-notify.sh"      755
install_file "$SCRIPT_DIR/statusline/statusline-command.sh" "$CLAUDE_DIR/statusline-command.sh" 755
install_file "$SCRIPT_DIR/claude/ULTRACODE.md"            "$CLAUDE_DIR/ULTRACODE.md"             -
echo

# ---------------------------------------------------------------------------
# 3. CLAUDE.md — ensure "@ULTRACODE.md" import line present.
# ---------------------------------------------------------------------------
echo "-- CLAUDE.md --"
mkdir -p "$CLAUDE_DIR"
if [ -f "$CLAUDE_MD" ] && grep -qxF '@ULTRACODE.md' "$CLAUDE_MD"; then
  note_skip "@ULTRACODE.md already imported in $CLAUDE_MD"
else
  b=""
  [ -f "$CLAUDE_MD" ] && b=$(backup_file "$CLAUDE_MD")
  # Ensure a trailing newline before appending, then add the import line.
  if [ -f "$CLAUDE_MD" ] && [ -s "$CLAUDE_MD" ]; then
    # add a separating newline only if the file does not already end with one
    if [ -n "$(tail -c1 "$CLAUDE_MD")" ]; then printf '\n' >>"$CLAUDE_MD"; fi
  fi
  printf '@ULTRACODE.md\n' >>"$CLAUDE_MD" || die "could not write $CLAUDE_MD"
  if [ -n "$b" ]; then
    note_did "appended @ULTRACODE.md to $CLAUDE_MD (backup: $b)"
  else
    note_did "created $CLAUDE_MD with @ULTRACODE.md"
  fi
fi
echo

# ---------------------------------------------------------------------------
# 4. settings.json merge (jq, idempotent, preserves existing content).
# ---------------------------------------------------------------------------
echo "-- settings.json --"
if [ -f "$SETTINGS" ]; then
  if ! grep -q '[^[:space:]]' "$SETTINGS" 2>/dev/null; then
    CUR_JSON='{}'   # empty/whitespace-only file: treat as fresh
  elif CUR_JSON=$(jq -ce 'if type == "object" then . else error("not an object") end' "$SETTINGS" 2>/dev/null); then
    :
  else
    die "$SETTINGS is not a JSON object; refusing to touch it. Fix or remove it first."
  fi
else
  CUR_JSON='{}'
fi

# Detect a pre-existing statusLine (so we can warn and skip rather than overwrite).
STATUSLINE_EXISTS=no
if printf '%s' "$CUR_JSON" | jq -e '.statusLine != null' >/dev/null 2>&1; then
  STATUSLINE_EXISTS=yes
fi

MERGED=$(jq -n \
  --argjson cur "$CUR_JSON" \
  --slurpfile fragarr "$FRAG" \
  '
  ($fragarr[0]) as $frag
  | ($cur.permissions.allow // []) as $ca
  | ($frag.permissions.allow // []) as $fa
  | def hasscript($evt; $name):
      (($cur.hooks[$evt]) // []) | any(.[].hooks[]?; (.command // "") | contains($name));
    ($cur
     | .permissions = (.permissions // {})
     | .permissions.allow = ($ca + ($fa - $ca))
     | .hooks = (.hooks // {})
     | .hooks.SessionStart =
         (if hasscript("SessionStart"; "handoff-inject.sh")
          then (.hooks.SessionStart // [])
          else ((.hooks.SessionStart // []) + $frag.hooks.SessionStart) end)
     | .hooks.UserPromptSubmit =
         (if hasscript("UserPromptSubmit"; "ctx-watch.sh")
          then (.hooks.UserPromptSubmit // [])
          else ((.hooks.UserPromptSubmit // []) + $frag.hooks.UserPromptSubmit) end)
     | .hooks.Stop =
         (if hasscript("Stop"; "ctx-notify.sh")
          then (.hooks.Stop // [])
          else ((.hooks.Stop // []) + $frag.hooks.Stop) end)
     | (if (.statusLine == null) then .statusLine = $frag.statusLine else . end))
  ') || die "jq merge failed for settings.json"

# statusLine notice: we never overwrite an existing one (but stay quiet when
# the existing one already points at the kit's script).
CUR_SL=$(printf '%s' "$CUR_JSON" | jq -r '.statusLine.command // ""' 2>/dev/null)
if [ "$STATUSLINE_EXISTS" = yes ] && [ "$CUR_SL" = "bash ~/.claude/statusline-command.sh" ]; then
  note_skip "statusLine already points at the kit's statusline"
elif [ "$STATUSLINE_EXISTS" = yes ]; then
  note_warn "settings.json already defines a statusLine — leaving it untouched."
  note_warn "  NOTE: the kit's statusline is what publishes the context relay that the"
  note_warn "  ctx-watch/ctx-notify hooks read — WITHOUT it the /handoff threshold"
  note_warn "  prompts will never fire. To enable them, set .statusLine.command to:"
  note_warn "    bash ~/.claude/statusline-command.sh   (refreshInterval: 10)"
  note_warn "  or merge the relay-publishing block into your own statusline script."
fi

# Write only if the normalized result differs from what is already there.
CUR_NORM=$(printf '%s' "$CUR_JSON" | jq -S . 2>/dev/null)
NEW_NORM=$(printf '%s' "$MERGED"   | jq -S . 2>/dev/null)
if [ "$CUR_NORM" = "$NEW_NORM" ]; then
  note_skip "settings.json already has the kit's config (no change)"
else
  b=""
  [ -f "$SETTINGS" ] && b=$(backup_file "$SETTINGS")
  mkdir -p "$CLAUDE_DIR"
  printf '%s\n' "$MERGED" | jq . >"$SETTINGS.tmp-$EPOCH" || die "could not render settings.json"
  mv "$SETTINGS.tmp-$EPOCH" "$SETTINGS" || die "could not write $SETTINGS"
  if [ -n "$b" ]; then
    note_did "merged kit config into settings.json (backup: $b)"
  else
    note_did "created settings.json with kit config"
  fi
fi
echo

# ---------------------------------------------------------------------------
# 5. .zshrc — append the integration snippet if the begin marker is absent.
# ---------------------------------------------------------------------------
echo "-- .zshrc --"
if [ -f "$ZSHRC" ] && grep -qF "$BEGIN_MARKER" "$ZSHRC"; then
  note_skip "claude-swap zshrc block already present in $ZSHRC"
else
  b=""
  [ -f "$ZSHRC" ] && b=$(backup_file "$ZSHRC")
  if [ -f "$ZSHRC" ] && [ -s "$ZSHRC" ]; then
    # ensure a trailing newline, then a blank separator line before our block
    if [ -n "$(tail -c1 "$ZSHRC")" ]; then printf '\n' >>"$ZSHRC"; fi
    printf '\n' >>"$ZSHRC"
  fi
  cat "$ZSNIPPET" >>"$ZSHRC" || die "could not append to $ZSHRC"
  if [ -n "$b" ]; then
    note_did "appended claude-swap block to $ZSHRC (backup: $b)"
  else
    note_did "created $ZSHRC with claude-swap block"
  fi
  note_warn "Open a new shell or run: source $ZSHRC"
fi
echo

# ---------------------------------------------------------------------------
# Verify: the kit is only "installed" if its two executables actually resolve.
# ---------------------------------------------------------------------------
echo "-- verify --"
for vcmd in cswap swap-guard; do
  if command -v "$vcmd" >/dev/null 2>&1 || [ -x "$LOCALBIN/$vcmd" ]; then
    echo "  [ok] $vcmd resolves"
  else
    note_warn "$vcmd does NOT resolve — the kit will not work until this is fixed."
    note_warn "  If pipx just installed it, open a new shell (exec zsh) and re-check."
  fi
done
echo

# ---------------------------------------------------------------------------
# Summary.
# ---------------------------------------------------------------------------
echo "== summary =="
echo "  changed:  ${#DID[@]}"
echo "  skipped:  ${#SKIPPED[@]}"
echo "  warnings: ${#WARNED[@]}"
if [ "${#WARNED[@]}" -gt 0 ]; then
  echo "  -- warnings --"
  i=0
  while [ "$i" -lt "${#WARNED[@]}" ]; do
    echo "    ! ${WARNED[$i]}"
    i=$((i + 1))
  done
fi
echo
echo "Runtime state lives under ~/.claude-swap-backup/ (managed by cswap and the scripts)."
echo "Done."
