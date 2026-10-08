#!/bin/bash
# tests/run.sh — run every tests/test_*.sh; exit 1 if any fails.
# Needs only bash, jq, and macOS userland (stat -f, date -r). No live state is touched.
cd "$(dirname "$0")" || exit 1
rc=0
for t in test_*.sh; do
  bash "$t" || rc=1
done
[ "$rc" -eq 0 ] && echo "ALL TESTS PASSED" || echo "TESTS FAILED"
exit "$rc"
