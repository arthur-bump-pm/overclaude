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
#     *.example, *.test, *.invalid, *.localhost) are placeholders that can never
#     belong to a person, and are ignored.
# Usage: scrub.sh <username> < diff
set -u
ME="${1:-$(id -un)}"
grep -nE '^\+' |
  grep -vE '^[0-9]+:\+\+\+ ' |
  sed -E 's/^([0-9]+):\+/\1:/' |
  perl -pe 's/[A-Za-z0-9._%+-]+@(?:[A-Za-z0-9-]+\.)*(?:example\.(?:com|org|net)|[A-Za-z0-9-]+\.(?:example|test|invalid|localhost))\b/<reserved>/g' |
  grep -E \
    -e "/Users/[A-Za-z0-9_-][A-Za-z0-9._-]*" \
    -e "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.[A-Za-z]{2,}" \
    -e "$ME"
[ "${PIPESTATUS[4]}" -ne 0 ]
