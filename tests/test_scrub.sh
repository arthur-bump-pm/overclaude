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
assert_eq "$(hit "+Upper.Case@Example.COM")" "clean" "placeholder domains in any letter case are ignored"
A=@   # assembled at runtime, like the fixtures above
assert_eq "$(hit "+file .claude-config-1-work${A}example.com.json")" "clean" "a cswap file name with a placeholder address is fine (.json is no TLD)"
assert_eq "$(hit "+mail jane${A}example.com.au")" "caught" "but a real country domain after a reserved name is caught"
assert_eq "$(hit "+mail jane${A}example.com.json.io")" "caught" "an exempt extension followed by more domain is caught"
assert_eq "$(hit "+mail jane${A}foo.test_x.io")" "caught" "an underscore continues the name (still caught, as before)"
for real in "jane${A}Corp.Test-Labs.io" "jane${A}x.Invalid-co.com" "jane${A}acme.Example.co" "jane${A}qa.test-labs.io" "jane${A}dev.localhost.acme.com"; do
  assert_eq "$(hit "+mail $real")" "caught" "a reserved name inside a real domain is still caught ($real)"
done

# --self-test, --history and the pre-push hook, against a throwaway repo.
assert_eq "$(bash "$S" --self-test someuser >/dev/null 2>&1; echo $?)" "0" "--self-test passes on the real rules"
new_home
R="$HOME/repo"; mkdir -p "$R" && cd "$R" && git init -q && git config user.email t@example.com && git config user.name t
cp "$S" scrub.sh; echo ok > a.txt; git add -A; git commit -qm clean
assert_eq "$(bash scrub.sh --history someuser >/dev/null; echo $?)" "0" "--history: a clean history passes"
printf 'path=/%s/jane/x\n' "$U" > b.txt; git add b.txt; git commit -qm leak
out="$(bash scrub.sh --history someuser)"; rc=$?
assert_eq "$rc" "1" "--history: a commit adding a /Users path is found"
assert_contains "$out" "leak" "and named"
git init -q --bare "$HOME/remote.git"; git remote add origin "$HOME/remote.git"
git config color.ui always
assert_eq "$(bash scrub.sh --history someuser >/dev/null; echo $?)" "1" "--history still catches it with color.ui=always"
mkdir -p sub; assert_eq "$(cd sub && bash ../scrub.sh --history someuser >/dev/null; echo $?)" "1" "and when run from a subfolder"
git reset -q --hard HEAD~1; git push -q origin HEAD:refs/heads/main 2>/dev/null
rm -rf "$(git rev-parse --git-path hooks)"
assert_contains "$(bash scrub.sh --install-hook)" "pre-push hook installed" "--install-hook (creates the hooks folder if missing)"
printf '#!/bin/bash\nexit 0\n' > scrub.sh   # an old checkout's scrub.sh must not disarm the hook
printf 'mail jane@%s.com\n' "$G" > c.txt; git add c.txt; git commit -qm leak2
git push -q origin HEAD:refs/heads/main 2>"$HOME/push-err"; rc=$?
assert_eq "$rc" "1" "the hook refuses a push that adds an email"
assert_contains "$(cat "$HOME/push-err")" "push refused" "and says why"
git reset -q --hard HEAD~1; echo fine > d.txt; git add d.txt; git commit -qm fine
assert_eq "$(git push -q origin HEAD:refs/heads/main 2>/dev/null; echo $?)" "0" "a clean push goes through"
cd / && rm -rf "$HOME"
finish
