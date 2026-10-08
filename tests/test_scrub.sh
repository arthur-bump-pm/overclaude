#!/bin/bash
# scrub.sh: real personal data is always caught; reserved placeholders are not.
# The "real-looking" fixtures are assembled at runtime (G/U/P below) so this file
# itself contains no literal address or path — otherwise the gate it tests would
# (correctly) refuse to commit it.
. "$(dirname "$0")/lib.sh"
S="$REPO/scrub.sh"
G=gmail; U=Users; P=pytest
hit() { printf '%s\n' "$1" | bash "$S" someuser >/dev/null && echo clean || echo caught; }
assert_eq "$(hit "+contact me at jane.doe@$G.com")" "caught" "real email caught"
assert_eq "$(hit "+path=/$U/jane/projects")" "caught" "/Users path caught"
assert_eq "$(hit '+owned by someuser')" "caught" "username caught"
assert_eq "$(hit "+mixed: a@example.com and jane@company$G.io")" "caught" "real email next to a placeholder still caught"
assert_eq "$(hit '+fixture work@example.com')" "clean" "example.com placeholder ignored"
assert_eq "$(hit '+x@build.test y@nope.invalid')" "clean" ".test/.invalid ignored"
assert_eq "$(hit "+@$P.fixture(autouse=True)")" "clean" "diff marker not mistaken for an email"
assert_eq "$(hit "+the literal /$U/... in docs")" "clean" "documented /Users/... literal ignored"
assert_eq "$(hit "-removed jane@$G.com")" "clean" "removed lines ignored"
assert_eq "$(hit "+++ b/jane@$G.com.txt")" "clean" "diff file headers ignored"
finish
