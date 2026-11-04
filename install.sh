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
  "$SCRIPT_DIR/bin/overclaude-checkpoint" \
  "$SCRIPT_DIR/bin/overclaude-install-transaction" \
  "$SCRIPT_DIR/bin/overclaude-codex-continue" \
  "$SCRIPT_DIR/skills/swap/SKILL.md" \
  "$SCRIPT_DIR/skills/handoff/SKILL.md" \
  "$SCRIPT_DIR/skills/checkpoint/SKILL.md" \
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

# cswap is vendored as a full source tree (see vendor/README.md). Install it when
# missing, and UPGRADE an installed copy older than the vendored one (the kit is
# tested against the vendored version's JSON shapes). Never downgrade.
VEND_SRC="$SCRIPT_DIR/vendor/claude-swap"
VEND_VER=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$VEND_SRC/pyproject.toml" 2>/dev/null | head -1)
CSWAP_BIN=$(command -v cswap 2>/dev/null || { [ -x "$LOCALBIN/cswap" ] && echo "$LOCALBIN/cswap"; })
CSWAP_VER=""
[ -n "$CSWAP_BIN" ] && CSWAP_VER=$("$CSWAP_BIN" --version 2>/dev/null | awk '{print $NF}')
cswap_older() { # true iff installed < vendored (both known)
  [ -n "$CSWAP_VER" ] && [ -n "$VEND_VER" ] && [ "$CSWAP_VER" != "$VEND_VER" ] &&
    [ "$(printf '%s\n%s\n' "$CSWAP_VER" "$VEND_VER" | sort -V | head -1)" = "$CSWAP_VER" ]
}
if [ -n "$CSWAP_BIN" ] && ! cswap_older; then
  echo "  [ok] cswap: $CSWAP_BIN${CSWAP_VER:+ ($CSWAP_VER)}"
else
  # with whichever Python tool-runner is available: pipx, else uv.
  CSWAP_ACTION="cswap not found — installing"; CSWAP_FORCE=""
  if [ -n "$CSWAP_BIN" ]; then
    CSWAP_ACTION="cswap $CSWAP_VER is older than the bundled $VEND_VER — upgrading"; CSWAP_FORCE="--force"
  fi
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
      echo "  [..] $CSWAP_ACTION bundled copy via pipx (deps come from PyPI)..."
      pipx install $CSWAP_FORCE "$VEND_SRC" >"$CSWAP_LOG" 2>&1; cswap_outcome "pipx install $CSWAP_FORCE" $?
    elif command -v uv >/dev/null 2>&1; then
      echo "  [..] $CSWAP_ACTION bundled copy via uv (deps come from PyPI)..."
      uv tool install $CSWAP_FORCE "$VEND_SRC" >"$CSWAP_LOG" 2>&1; cswap_outcome "uv tool install $CSWAP_FORCE" $?
    else
      note_warn "${CSWAP_ACTION%% —*}, but neither pipx nor uv is available."
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
# Managed payload + shared configuration: write-ahead journal and offline verify.
# Dependency installation above and service activation below are separate.
# ---------------------------------------------------------------------------
echo "-- managed files and settings --"
KIT_VER="${OVERCLAUDE_VERSION:-}"
[ -n "$KIT_VER" ] || KIT_VER=$(sed -n 's/^version = "\(.*\)"$/\1/p' "$SCRIPT_DIR/pyproject.toml" 2>/dev/null | head -1)
[ -n "$KIT_VER" ] || KIT_VER=$(overclaude version 2>/dev/null | head -1)
[ -n "$KIT_VER" ] || die "cannot determine kit version"
python3 "$SCRIPT_DIR/bin/overclaude-install-transaction" --payload "$SCRIPT_DIR" apply --version "$KIT_VER" ||
  die "managed file transaction failed; package/dependency changes, if any, are separate; inspect or recover the transaction"
note_did "managed payload and settings verified"
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
# Keepalive agent: refreshes idle accounts' logins every 2 h so none expires
# unused. On by default; `swap-guard keepalive off` is remembered here.
# ---------------------------------------------------------------------------
echo "-- keepalive --"
KA_PLIST="$HOME/Library/LaunchAgents/com.overclaude.keepalive.plist"
if [ -f "$HOME/.claude-swap-backup/keepalive.off" ]; then
  note_skip "keepalive agent is off (turn on: swap-guard keepalive on)"
else
  ka_had=no; [ -f "$KA_PLIST" ] && ka_had=yes
  ka_int=$(plutil -extract StartInterval raw "$KA_PLIST" 2>/dev/null)
  case "$ka_int" in ''|*[!0-9]*) ka_int=7200;; esac
  if ka_out=$("$LOCALBIN/swap-guard" keepalive on --interval "$ka_int" 2>&1); then
    if [ "$ka_had" = yes ]; then note_skip "keepalive agent already on (reloaded)"
    else note_did "keepalive agent on: idle accounts' logins are refreshed every $((ka_int / 60)) min (off: swap-guard keepalive off)"; fi
  else
    note_warn "keepalive agent not installed: $(printf '%s' "$ka_out" | tail -n 1)"
    note_warn "  retry later with: swap-guard keepalive on"
  fi
fi
echo

# ---------------------------------------------------------------------------
# Memory watcher: samples this Mac's memory every minute for the statusline and
# the hooks, cleans up orphaned helper processes and warns when memory gets tight.
# On by default; `swap-guard mem watch off` is remembered here.
# ---------------------------------------------------------------------------
echo "-- memory watcher --"
MW_PLIST="$HOME/Library/LaunchAgents/com.overclaude.memwatch.plist"
if [ -f "$HOME/.claude-swap-backup/memwatch.off" ]; then
  note_skip "memory watcher is off (turn on: swap-guard mem watch on)"
else
  mw_had=no; [ -f "$MW_PLIST" ] && mw_had=yes
  mw_int=$(plutil -extract StartInterval raw "$MW_PLIST" 2>/dev/null)
  case "$mw_int" in ''|*[!0-9]*) mw_int=60;; esac
  if mw_out=$("$LOCALBIN/swap-guard" mem watch on --interval "$mw_int" 2>&1); then
    if [ "$mw_had" = yes ]; then note_skip "memory watcher already on (reloaded)"
    else note_did "memory watcher on: memory is checked every minute; orphaned helpers are cleaned and sessions warned when it gets tight (off: swap-guard mem watch off)"; fi
  else
    note_warn "memory watcher not installed: $(printf '%s' "$mw_out" | tail -n 1)"
    note_warn "  retry later with: swap-guard mem watch on"
  fi
fi
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
