#!/bin/bash
# sync.sh — pull the LIVE setup files from this machine back into the repo,
# scrub-check the diff for personal data, then commit and push.
# With --release: also bump the patch version, build and upload to PyPI from
# this Mac, then push and cut a GitHub release. No GitHub Actions (owner's rule).
# macOS /bin/bash 3.2 compatible.
# Usage: ./sync.sh [--dry-run] [--release] [commit message]
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR" || exit 1

PKG=overclaude
DRY_RUN=no
RELEASE=no
MSG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=yes ;;
    --release) RELEASE=yes ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "sync: unknown option $arg (see --help)" >&2; exit 2 ;;
    *) MSG="$arg" ;;
  esac
done
# A release is cut from main only: gh tags the commit given by --target below,
# and PyPI should only ever get what main has.
if [ "$RELEASE" = yes ]; then
  BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
  [ "$BR" = main ] || {
    echo "release: you are on '$BR' — release from main (git checkout main && git merge --ff-only $BR)." >&2
    exit 1; }
fi
[ -n "$MSG" ] || MSG="sync: update from live setup ($(date +%Y-%m-%d))"

BEGIN_MARKER='# --- claude-swap integration (begin) ---'
END_MARKER='# --- claude-swap integration (end) ---'

# live-path:repo-path pairs (bash 3.2: newline list, no assoc arrays)
PAIRS="$HOME/.local/bin/overclaude-codex-continue:bin/overclaude-codex-continue
$HOME/.local/bin/overclaude-codex-probe:bin/overclaude-codex-probe
$HOME/.local/bin/overclaude-codex-pool:bin/overclaude-codex-pool
$HOME/.local/bin/overclaude-checkpoint:bin/overclaude-checkpoint
$HOME/.local/bin/swap-guard:bin/swap-guard
$HOME/.claude/skills/swap/SKILL.md:skills/swap/SKILL.md
$HOME/.claude/skills/handoff/SKILL.md:skills/handoff/SKILL.md
$HOME/.claude/skills/checkpoint/SKILL.md:skills/checkpoint/SKILL.md
$HOME/.claude/hooks/handoff-inject.sh:hooks/handoff-inject.sh
$HOME/.claude/hooks/ctx-watch.sh:hooks/ctx-watch.sh
$HOME/.claude/hooks/ctx-notify.sh:hooks/ctx-notify.sh
$HOME/.claude/statusline-command.sh:statusline/statusline-command.sh
$HOME/.claude/ULTRACODE.md:claude/ULTRACODE.md"
for runtime_file in README.md __init__.py tomli/LICENSE tomli/__init__.py tomli/_parser.py tomli/_re.py tomli/_types.py tomli/py.typed; do
  PAIRS="$PAIRS
$HOME/.local/bin/overclaude_runtime/$runtime_file:bin/overclaude_runtime/$runtime_file"
done

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
  elif [ "$DRY_RUN" = yes ]; then
    echo "  [~] would update: $repo (live differs — run ./install.sh first if the repo is newer)"
    CHANGED=1
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
  elif [ "$DRY_RUN" = yes ]; then
    rm -f .zshrc-snippet.tmp
    echo "  [~] would update: shell/zshrc-snippet.sh (live differs — run ./install.sh first if the repo is newer)"
    CHANGED=1
  else
    mv .zshrc-snippet.tmp shell/zshrc-snippet.sh
    echo "  [+] updated:   shell/zshrc-snippet.sh"
    CHANGED=1
  fi
else
  echo "  [!] no claude-swap block in ~/.zshrc; snippet left as-is" >&2
  rm -f .zshrc-snippet.tmp 2>/dev/null
fi

# ---------------------------------------------------------------------------
# Release gate: shellcheck + the full suite must pass BEFORE anything is
# committed, pushed, or released. Nothing re-checks later: there is no CI.
# Runs under /bin/bash 3.2, the strictest shell users' `env bash` resolves to.
# ---------------------------------------------------------------------------
if [ "$RELEASE" = yes ]; then
  echo
  echo "== release gate (tests before anything ships) =="
  # Homebrew's folders aren't on PATH in every shell (Claude Code's `!` runs a bare one).
  PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
  # The PyPI upload token lives in the login Keychain; check it first so a release
  # never stops half-way. The owner stores it once (see CLAUDE.md); it is never printed.
  if [ "$DRY_RUN" != yes ]; then
    command -v uv >/dev/null 2>&1 || { echo "release: uv not found — brew install uv" >&2; exit 1; }
    /usr/bin/security find-generic-password -s "pypi-$PKG" -a __token__ >/dev/null 2>&1 || {
      echo "release: no PyPI token in the Keychain (service pypi-$PKG). Store it once with:" >&2
      echo "  security add-generic-password -U -a __token__ -s pypi-$PKG -w" >&2
      exit 1; }
  fi
  command -v shellcheck >/dev/null 2>&1 || {
    echo "release: shellcheck not found — brew install shellcheck" >&2; exit 1; }
  shellcheck -S error bin/swap-guard hooks/*.sh statusline/statusline-command.sh \
    install.sh uninstall.sh doctor.sh sync.sh scrub.sh tests/*.sh || {
    echo "release: ABORTED — shellcheck errors (nothing committed or released)." >&2; exit 1; }
  echo "  [ok] shellcheck"
  GATE_LOG=$(mktemp "${TMPDIR:-/tmp}/overclaude-gate.XXXXXX")
  if PATH=/bin:/usr/bin:$PATH /bin/bash tests/run.sh >"$GATE_LOG" 2>&1; then
    echo "  [ok] test suite ($(awk '/ passed, /{n+=$2} END{print n+0}' "$GATE_LOG") checks, /bin/bash 3.2)"
    rm -f "$GATE_LOG"
  else
    grep -E 'FAIL|failed' "$GATE_LOG" | tail -25 >&2
    echo "release: ABORTED — tests failed (nothing committed or released). Full log: $GATE_LOG" >&2
    exit 1
  fi
fi

NOTHING_TO_COMMIT=no
if [ "$CHANGED" -eq 0 ] && git diff --quiet && git diff --cached --quiet \
   && [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  NOTHING_TO_COMMIT=yes
fi

if [ "$NOTHING_TO_COMMIT" = yes ] && [ "$RELEASE" = no ]; then
  echo "Nothing to sync — repo already matches the live setup."
  exit 0
fi

if [ "$NOTHING_TO_COMMIT" = no ]; then
  # -------------------------------------------------------------------------
  # Scrub gate: the diff must not contain personal data.
  # -------------------------------------------------------------------------
  ME=$(id -un)
  # Scanned: tracked changes AND brand-new untracked files (`git add -A` below
  # commits those too). Not scanned: vendor/ — verbatim upstream source whose
  # own test fixtures use placeholder emails; the repo rules forbid editing it.
  # The matching rules live in scrub.sh (tested by tests/test_scrub.sh).
  DIFF=$(git diff --no-color --no-ext-diff --no-textconv -- . ':(exclude)vendor'; git diff --no-color --no-ext-diff --no-textconv --cached -- . ':(exclude)vendor'
         git ls-files --others --exclude-standard -z -- . ':(exclude)vendor' |
           xargs -0 -I{} sed 's/^/+/' {} 2>/dev/null)
  # First prove the gate itself still works: it must catch a planted path, email
  # and username (a broken rule would otherwise pass everything silently).
  bash ./scrub.sh --self-test "$ME" >/dev/null || {
    echo "sync: ABORTED — scrub.sh failed its self-test (run: bash scrub.sh --self-test)" >&2; exit 1; }
  HITS=$(printf '%s\n' "$DIFF" | bash ./scrub.sh "$ME")
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
    [ "$RELEASE" = yes ] || exit 0
  else
    git add -A || exit 1
    git commit -m "$MSG" || exit 1
    git push || { echo "sync: commit created but push failed — push manually." >&2; exit 1; }
    echo "Pushed."
  fi
fi

# ---------------------------------------------------------------------------
# --release: patch-bump the version, build on this Mac, check the wheel, upload
# to PyPI, then push and cut the GitHub release (notes only; nothing runs there).
# Remember: git push alone does NOT update PyPI — only releases do.
# ---------------------------------------------------------------------------
[ "$RELEASE" = yes ] || exit 0
echo
echo "== release =="

command -v gh >/dev/null 2>&1 || {
  echo "release: gh CLI not found — bump the version in pyproject.toml and create the release manually." >&2
  exit 1
}

# gh creates release tags on the REMOTE only — fetch them or describe sees nothing.
git fetch --tags --quiet 2>/dev/null
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null) || LAST_TAG=""
if [ "$NOTHING_TO_COMMIT" = yes ] && [ -n "$LAST_TAG" ] \
   && [ "$(git rev-list -n 1 "$LAST_TAG" 2>/dev/null)" = "$(git rev-parse HEAD)" ]; then
  echo "No commits since $LAST_TAG — nothing to release."
  exit 0
fi

CUR=$(sed -n 's/^version = "\(.*\)"$/\1/p' pyproject.toml | head -1)
case "$CUR" in
  *.*.*) : ;;
  *) echo "release: could not parse version from pyproject.toml (got: '$CUR')" >&2; exit 1 ;;
esac
NEW=$(printf '%s' "$CUR" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
# Manual minor/major bump (version already ahead of the last tag): release it as-is.
if [ -n "$LAST_TAG" ] && [ "$CUR" != "${LAST_TAG#v}" ] \
   && [ "$(printf '%s\n%s\n' "${LAST_TAG#v}" "$CUR" | sort -V | tail -1)" = "$CUR" ]; then
  NEW="$CUR"
fi

# Release notes: the commits since the last tag (before the bump commit).
if [ -n "$LAST_TAG" ]; then
  NOTES=$(git log "$LAST_TAG"..HEAD --oneline --no-decorate | sed 's/^[a-f0-9]* /- /')
else
  NOTES=""
fi
# Nothing committed yet at preview time (or first release): fall back to the sync message.
[ -n "$NOTES" ] || NOTES="- $MSG"

if [ "$DRY_RUN" = yes ]; then
  echo "(dry run) would bump $CUR -> $NEW, build and upload $PKG $NEW to PyPI, and create release v$NEW with notes:"
  printf '%s\n' "$NOTES"
  exit 0
fi

if [ "$NEW" != "$CUR" ]; then
  sed -i '' "s/^version = \"$CUR\"/version = \"$NEW\"/" pyproject.toml || exit 1
  git add pyproject.toml && git commit -m "release: v$NEW" || {
    echo "release: version-bump commit failed" >&2; exit 1
  }
fi
# Build and upload BEFORE pushing: a failed upload leaves only a local bump commit,
# and re-running `./sync.sh --release` picks it up as a manual bump (same version).
DIST=$(mktemp -d "${TMPDIR:-/tmp}/$PKG-dist.XXXXXX")
uv build --quiet --sdist --wheel -o "$DIST" || { echo "release: build failed (nothing pushed)" >&2; exit 1; }
bash tests/check_wheel.sh "$DIST" || { echo "release: wheel check failed (nothing pushed)" >&2; exit 1; }
uvx --quiet twine check --strict "$DIST"/* || { echo "release: twine check failed (nothing pushed)" >&2; exit 1; }
# --check-url skips files PyPI already has, so a re-run after a partial upload is safe.
TOKEN="$(/usr/bin/security find-generic-password -s "pypi-$PKG" -a __token__ -w 2>/dev/null)"
[ -n "$TOKEN" ] || { echo "release: could not read the PyPI token from the Keychain (unlock it, then re-run; nothing pushed)" >&2; exit 1; }
UV_PUBLISH_TOKEN="$TOKEN" uv publish --quiet --check-url "https://pypi.org/simple/" "$DIST"/* || {
  echo "release: PyPI upload failed (the version bump is not pushed). Fix it, then re-run ./sync.sh --release" >&2; exit 1; }
unset TOKEN
rm -rf "$DIST"
echo "  [ok] $PKG $NEW uploaded to PyPI"
# Manual bump: the version is already committed, so there is no bump commit — just push.
git push || { echo "release: push failed (PyPI already has $NEW) — re-run: git push && gh release create v$NEW" >&2; exit 1; }
gh release create "v$NEW" --target "$(git rev-parse HEAD)" --title "overclaude v$NEW" --notes "$NOTES" || {
  echo "release: gh release create failed — the version bump IS committed; re-run: gh release create v$NEW" >&2
  exit 1
}
echo "Release v$NEW created and $PKG $NEW is on PyPI."
echo "Other machines update with: overclaude update   (or: pipx upgrade overclaude && overclaude install)"
