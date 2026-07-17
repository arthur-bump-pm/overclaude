#!/bin/bash
# sync.sh — pull the LIVE setup files from this machine back into the repo,
# scrub-check the diff for personal data, then commit and push.
# macOS /bin/bash 3.2 compatible. Usage: ./sync.sh [--dry-run] [commit message]
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

DRY_RUN=no
MSG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=yes ;;
    *) MSG="$arg" ;;
  esac
done
[ -n "$MSG" ] || MSG="sync: update from live setup ($(date +%Y-%m-%d))"

BEGIN_MARKER='# --- claude-swap integration (begin) ---'
END_MARKER='# --- claude-swap integration (end) ---'

# live-path:repo-path pairs (bash 3.2: newline list, no assoc arrays)
PAIRS="$HOME/.local/bin/swap-guard:bin/swap-guard
$HOME/.claude/skills/swap/SKILL.md:skills/swap/SKILL.md
$HOME/.claude/skills/handoff/SKILL.md:skills/handoff/SKILL.md
$HOME/.claude/hooks/handoff-inject.sh:hooks/handoff-inject.sh
$HOME/.claude/hooks/ctx-watch.sh:hooks/ctx-watch.sh
$HOME/.claude/hooks/ctx-notify.sh:hooks/ctx-notify.sh
$HOME/.claude/statusline-command.sh:statusline/statusline-command.sh
$HOME/.claude/ULTRACODE.md:claude/ULTRACODE.md"

echo "== overclaude sync (live -> repo) =="
CHANGED=0

old_ifs="$IFS"; IFS='
'
for pair in $PAIRS; do
  IFS="$old_ifs"
  live="${pair%%:*}"; repo="${pair#*:}"
  if [ ! -f "$live" ]; then
    echo "  [!] live file missing, skipped: $live" >&2
    continue
  fi
  if cmp -s "$live" "$repo" 2>/dev/null; then
    echo "  [=] unchanged: $repo"
  else
    cp "$live" "$repo" || { echo "sync: ERROR copying $live" >&2; exit 1; }
    echo "  [+] updated:   $repo"
    CHANGED=1
  fi
  IFS='
'
done
IFS="$old_ifs"

# zshrc block -> shell/zshrc-snippet.sh
if grep -qF "$BEGIN_MARKER" "$HOME/.zshrc" 2>/dev/null; then
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '$0 == b {f=1} f {print} $0 == e {f=0}' \
    "$HOME/.zshrc" > .zshrc-snippet.tmp
  if cmp -s .zshrc-snippet.tmp shell/zshrc-snippet.sh; then
    echo "  [=] unchanged: shell/zshrc-snippet.sh"
    rm -f .zshrc-snippet.tmp
  else
    mv .zshrc-snippet.tmp shell/zshrc-snippet.sh
    echo "  [+] updated:   shell/zshrc-snippet.sh"
    CHANGED=1
  fi
else
  echo "  [!] no claude-swap block in ~/.zshrc; snippet left as-is" >&2
  rm -f .zshrc-snippet.tmp 2>/dev/null
fi

if [ "$CHANGED" -eq 0 ] && git diff --quiet && git diff --cached --quiet; then
  echo "Nothing to sync — repo already matches the live setup."
  exit 0
fi

# ---------------------------------------------------------------------------
# Scrub gate: the diff must not contain personal data.
# ---------------------------------------------------------------------------
ME=$(id -un)
DIFF=$(git diff)
HITS=$(printf '%s\n' "$DIFF" | grep -nE "^\+" | grep -E \
  -e "/Users/[A-Za-z0-9._-]+" \
  -e "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}" \
  -e "$ME" 2>/dev/null)
if [ -n "$HITS" ]; then
  echo
  echo "sync: ABORTED — added lines contain personal data (username/email//Users path):" >&2
  printf '%s\n' "$HITS" | head -20 >&2
  echo "Fix the live files (keep them \$HOME-relative and generic), then re-run." >&2
  exit 1
fi
echo "  [ok] scrub: no personal data in the diff"

echo
git --no-pager diff --stat
if [ "$DRY_RUN" = yes ]; then
  echo
  echo "(dry run — nothing committed)"
  exit 0
fi

git add -A || exit 1
git commit -m "$MSG" || exit 1
git push || { echo "sync: commit created but push failed — push manually." >&2; exit 1; }
echo "Done — pushed."
