#!/bin/bash
# tests/lib.sh — tiny assertion helpers for the plain-bash test suite.
# Every test runs against the REPO copies of the kit scripts inside a throwaway
# $HOME, so the developer's live setup is never read or written.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SG="$REPO/bin/swap-guard"
SL="$REPO/statusline/statusline-command.sh"
INJ="$REPO/hooks/handoff-inject.sh"

T_PASS=0
T_FAIL=0
T_NAME="${0##*/}"

# new_home — fresh sandbox HOME (exported) with the kit's state dirs.
new_home() {
  TH="$(mktemp -d "${TMPDIR:-/tmp}/overclaude-test.XXXXXX")"
  mkdir -p "$TH/.claude/sessions" "$TH/.claude/projects" "$TH/.claude-swap-backup/cache"
  export HOME="$TH"
  export SWAP_NO_REFRESH=1
}

strip_ansi() { LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g'; }

pass() { T_PASS=$((T_PASS + 1)); }
fail() { T_FAIL=$((T_FAIL + 1)); printf '  FAIL [%s] %s\n' "$T_NAME" "$1"; [ -n "${2:-}" ] && printf '       got: %s\n' "$2"; }

assert_eq()       { if [ "$1" = "$2" ]; then pass; else fail "$3 (expected '$2')" "$1"; fi; }
assert_contains() { case "$1" in *"$2"*) pass;; *) fail "$3 (expected to contain '$2')" "$1";; esac; }
assert_absent()   { case "$1" in *"$2"*) fail "$3 (expected NOT to contain '$2')" "$1";; *) pass;; esac; }
assert_le()       { if [ "$1" -le "$2" ] 2>/dev/null; then pass; else fail "$3 (expected <= $2)" "$1"; fi; }

# iso_in <seconds> — ISO-8601 UTC timestamp N seconds from now (negative = past),
# in cswap's cache format.
iso_in() { date -u -r $(( $(date +%s) + $1 )) '+%Y-%m-%dT%H:%M:%S.123456+00:00'; }

# write_seq <active> — two accounts: 1=work, 2=personal
write_seq() {
  cat > "$HOME/.claude-swap-backup/sequence.json" <<EOF
{"activeAccountNumber": $1, "sequence": [1, 2],
 "accounts": {"1": {"email": "work@example.com", "alias": "work"},
              "2": {"email": "personal@example.com", "alias": "personal"}}}
EOF
}

finish() {
  printf '%s: %d passed, %d failed\n' "$T_NAME" "$T_PASS" "$T_FAIL"
  [ "$T_FAIL" -eq 0 ]
}
