#!/bin/bash
# scrub.sh — personal-data filter for sync.sh's commit gate.
# Reads a unified diff (or '+'-prefixed file contents) on stdin and prints every
# ADDED line that contains a /Users/<name> path, an email address, or the given
# username. Exit 1 if anything was found, 0 if clean.
#
# Precision rules (none of them can hide a real address or path):
#   - the diff's own leading '+' is stripped before matching, so "+@pytest" in a
#     diff is not mistaken for an email;
#   - addresses at RFC 2606 / RFC 6761 reserved names (example.com/.org/.net,
#     *.example, *.test, *.invalid, *.localhost, in any letter case) are
#     placeholders that can never belong to a person, and are ignored — only when
#     the reserved name ENDS the domain (one inside a longer real domain is caught;
#     a file extension that is no TLD, as in cswap's "<n>-<address>.json", is fine).
# Usage: scrub.sh <username> < diff
#        scrub.sh --self-test [<username>]   prove the gate still catches a planted
#                                            path, email and username (exit 1 if not)
#        scrub.sh --history [<username>]     scan every commit (vendor/ excluded)
#        scrub.sh --install-hook             add a git pre-push hook that scans what
#                                            is about to be pushed
set -u

_scan() { # _scan <username> < diff
  grep -nE '^\+' |
    grep -vE '^[0-9]+:\+\+\+ ' |
    sed -E 's/^([0-9]+):\+/\1:/' |
    perl -pe 's/[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)*(?:example\.(?:com|org|net)|[A-Za-z0-9-]+\.(?:example|test|invalid|localhost))(?![A-Za-z0-9_-]|\.(?!(?:json|enc|txt|log|bak|lock|tmp|prev)(?![A-Za-z0-9_-]|\.[A-Za-z0-9]))[A-Za-z0-9])/<reserved>/gi' |
    grep -E \
      -e "/Users/[A-Za-z0-9_-][A-Za-z0-9._-]*" \
      -e "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}" \
      -e "$1"
  [ "${PIPESTATUS[4]}" -ne 0 ]
}

case "${1:-}" in
  --self-test)
    # The planted values are assembled here at runtime, so this file itself holds no
    # literal address or path (the gate would rightly refuse to commit it).
    me="${2:-$(id -un)}"; d=gmail; u=Users; fails=0
    for planted in "+path=/$u/someone/project" "+mail jane.doe@$d.com" "+owner $me" "+mixed a@example.com b@corp$d.io"; do
      printf '%s\n' "$planted" | _scan "$me" >/dev/null && { echo "scrub self-test: MISSED a planted ${planted#+}" >&2; fails=1; }
    done
    for clean in "+fixture work@example.com" "+x@build.test" "+-removed" "+the literal /$u/... in docs"; do
      printf '%s\n' "$clean" | _scan "$me" >/dev/null || { echo "scrub self-test: flagged a placeholder: ${clean#+}" >&2; fails=1; }
    done
    [ "$fails" -eq 0 ] && echo "scrub self-test: ok (planted path, email and username caught; placeholders ignored)"
    exit "$fails";;
  --history)
    me="${2:-$(id -un)}"; found=0
    cd "$(git rev-parse --show-toplevel)" || exit 1
    for c in $(git rev-list --all); do
      # _scan exits 0 when clean. No color/external diff: a colored "+" never matches.
      hits="$(git show --no-color --no-ext-diff --no-textconv --format= "$c" -- . ':(exclude)vendor' 2>/dev/null | _scan "$me")" && continue
      echo "== $(git log -1 --format='%h %s' "$c")"; printf '%s\n' "$hits" | head -10; found=1
    done
    [ "$found" -eq 0 ] && echo "scrub history: clean ($(git rev-list --all | wc -l | tr -d ' ') commits)"
    exit "$found";;
  --install-hook)
    hooks="$(git rev-parse --git-path hooks)" || exit 1
    mkdir -p "$hooks" || exit 1
    hook="$hooks/pre-push"
    # The hook runs its own copy, so a push from a branch with an older scrub.sh is
    # still scanned. Re-run --install-hook after scrub.sh changes to refresh it.
    cp "$0" "$hooks/overclaude-scrub.sh" || exit 1
    if [ -e "$hook" ] && ! grep -q 'overclaude scrub' "$hook"; then
      echo "scrub: $hook already exists and isn't ours; add this line to it: bash \"$hooks/overclaude-scrub.sh\" --pre-push" >&2; exit 1
    fi
    printf '#!/bin/bash\n# overclaude scrub: refuse a push whose new commits add personal data\nexec bash "$(dirname "$0")/overclaude-scrub.sh" --pre-push\n' > "$hook" &&
      chmod +x "$hook" && echo "scrub: pre-push hook installed ($hook)"
    exit $?;;
  --pre-push)
    # git feeds "<local ref> <local sha> <remote ref> <remote sha>" per pushed ref.
    me="$(id -un)"; bad=0
    cd "$(git rev-parse --show-toplevel)" || exit 1
    while read -r _ lsha _ _; do
      case "$lsha" in *[!0]*) ;; *) continue;; esac   # a deletion pushes nothing
      hits="$(git log -p --no-color --no-ext-diff --no-textconv --format= "$lsha" --not --remotes -- . ':(exclude)vendor' 2>/dev/null | _scan "$me")" && continue
      echo "push refused: these new lines contain personal data (username/email//Users path):" >&2
      printf '%s\n' "$hits" | head -20 >&2; bad=1
    done
    exit "$bad";;
esac
_scan "${1:-$(id -un)}"
