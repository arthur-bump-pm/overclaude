#!/bin/bash
# handoff-inject output budget + swap-guard history/restore.
. "$(dirname "$0")/lib.sh"
new_home
CWD=/tmp/overclaude-test-proj

pending() { "$SG" path handoff --cwd "$CWD"; }
arm() { # arm <body-file> [age-seconds]
  { printf '<!-- handoff cwd="%s" created="%s" -->\n' "$CWD" "$(( $(date +%s) - ${2:-0} ))"; cat "$1"; } > "$(pending)"
}
# Archive names have 1-second resolution; real injects of one cwd are minutes
# apart, so keep test injects in distinct seconds too.
inject() { sleep 1; echo "{\"cwd\":\"$CWD\"}" | bash "$INJ"; }

printf '# Handoff — small\n## Goal\nship\n## Next steps\n- a\n' > "$HOME/small.md"
arm "$HOME/small.md"
out=$(inject)
assert_contains "$out" "# Handoff — small" "small package injected whole"
assert_absent "$out" "Read the FULL package" "no pointer for small package"
[ -f "$(pending)" ] && fail "pending file should be archived after inject" || pass

# Many sections, ~12 KB: whole sections up to the budget, then a pointer.
{ echo "# Handoff — big"; for i in 1 2 3 4 5 6 7 8; do echo "## Section $i"; for j in $(seq 1 12); do printf 'line %s.%s %s\n' "$i" "$j" "$(printf 'x%.0s' $(seq 1 100))"; done; done; } > "$HOME/big.md"
arm "$HOME/big.md"
out=$(inject)
assert_le "$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')" 9500 "big package output under budget"
assert_contains "$out" "## Section 1" "first section kept"
assert_absent "$out" "## Section 8" "last section deferred"
assert_contains "$out" "Read the FULL package" "pointer to full file"

# One giant section: fill the budget line by line (regression: printed only the title).
{ echo "# Handoff — huge"; echo "## Goal"; for j in $(seq 1 300); do printf 'g%s %s\n' "$j" "$(printf 'y%.0s' $(seq 1 100))"; done; } > "$HOME/huge.md"
arm "$HOME/huge.md"
out=$(inject)
b=$(printf '%s' "$out" | LC_ALL=C wc -c | tr -d ' ')
assert_le "$b" 9500 "huge section output under budget"
assert_le 6000 "$b" "huge section fills most of the budget"

# Multibyte text: byte budget keeps the CHARACTER count under the 10k cap.
{ echo "# Handoff — ko"; echo "## Goal"; for j in $(seq 1 200); do echo "한국어 문장입니다 한국어 문장입니다 한국어 문장입니다"; done; } > "$HOME/ko.md"
arm "$HOME/ko.md"
chars=$(inject | LC_ALL=en_US.UTF-8 wc -m | tr -d ' ')
assert_le "$chars" 10000 "multibyte output under 10k characters"

# Expired package: archived as -expired, nothing printed.
arm "$HOME/small.md" 700
out=$(inject)
assert_eq "$out" "" "expired package prints nothing"

# --- history / restore ---
h=$("$SG" history --cwd "$CWD")
assert_eq "$(printf '%s' "$h" | jq 'length')" "5" "history lists the 5 archived packages"
assert_eq "$(printf '%s' "$h" | jq -r '.[0].expired')" "true" "newest entry is the expired one"
assert_eq "$(printf '%s' "$h" | jq -r '.[0].title')" "Handoff — small" "title parsed from line 2"

r=$("$SG" restore --cwd "$CWD")
assert_eq "$(printf '%s' "$r" | jq -r '.cwd')" "$CWD" "restore newest re-arms for cwd"
assert_contains "$(head -n 1 "$(pending)")" "created=\"$(date +%s | cut -c1-8)" "restored header has a fresh timestamp"
r=$("$SG" restore 2 --cwd "$CWD")
assert_eq "$(printf '%s' "$r" | jq -r '.error')" "pending-exists" "refuses to overwrite a live pending package"
r=$("$SG" restore --cwd "$CWD" 2 --force)
assert_contains "$(printf '%s' "$r" | jq -r '.restored')" "handoff-archive" "--force replaces (selector after --cwd value)"
out=$(inject)
assert_contains "$out" "Handoff from previous session" "injector loads a restored package"
f=$(printf '%s' "$h" | jq -r '.[1].path')
assert_eq "$("$SG" restore "$f" --cwd /elsewhere | jq -r '.error')" "cwd-mismatch" "path restore into another cwd refused"
assert_eq "$("$SG" restore /etc/hosts --cwd "$CWD" | jq -r '.error')" "not-found" "paths outside the archive refused"

# Review finding: `..` traversal and symlinks must not escape the archive dir
# (a restored package is injected as trusted context).
mkdir -p "$HOME/evil"; arch="$HOME/.claude-swap-backup/handoff-archive"
printf '<!-- handoff cwd="%s" created="1" -->\n# EVIL\n' "$CWD" > "$HOME/evil/x.md"
assert_eq "$("$SG" restore "$arch/../../evil/x.md" --cwd "$CWD" --force | jq -r '.error')" "not-found" ".. traversal refused"
ln -s "$HOME/evil/x.md" "$arch/20990101-000000-$(printf '%s' "$CWD" | shasum -a 256 | cut -c1-12).md"
assert_eq "$("$SG" restore "$arch/20990101-000000-$(printf '%s' "$CWD" | shasum -a 256 | cut -c1-12).md" --cwd "$CWD" --force | jq -r '.error')" "not-found" "symlinked archive entry refused by path"
assert_eq "$("$SG" restore 1 --cwd "$CWD" --force | jq -r '.error')" "not-found" "symlinked archive entry refused by number"
rm -f "$arch/20990101-000000-"*.md

# Review finding: an EXPIRED pending package that was never archived (no session
# started since) must be archived on restore, not destroyed.
printf '<!-- handoff cwd="%s" created="%s" -->\n# UNARCHIVED WORK\n' "$CWD" "$(( $(date +%s) - 700 ))" > "$(pending)"
r=$("$SG" restore 2 --cwd "$CWD")
rep=$(printf '%s' "$r" | jq -r '.replacedArchivedTo')
assert_contains "$(cat "$rep" 2>/dev/null)" "UNARCHIVED WORK" "stale pending package archived as -replaced"
assert_contains "$("$SG" history --cwd "$CWD" | jq -r '.[].path')" "-replaced.md" "replaced package listed in history"
# --force on a LIVE package also keeps a copy
r=$("$SG" restore 1 --cwd "$CWD" --force)
[ -f "$(printf '%s' "$r" | jq -r '.replacedArchivedTo')" ] && pass || fail "--force archives the live package it replaces" "$r"
assert_eq "$("$SG" restore 99 --cwd "$CWD" | jq -r '.error')" "not-found" "out-of-range index"

finish
