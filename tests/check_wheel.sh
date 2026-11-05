#!/bin/bash
# check_wheel.sh <dist-dir> — the built wheel carries the full kit payload and imports.
# Run by `sync.sh --release` before anything is uploaded (it replaced the old CI job).
set -u
dist="${1:?usage: tests/check_wheel.sh <dist-dir>}"
whl=$(ls "$dist"/*.whl 2>/dev/null | head -1)
[ -n "$whl" ] || { echo "no wheel in $dist"; exit 1; }
list=$(unzip -l "$whl")
for f in install.sh uninstall.sh doctor.sh bin/swap-guard bin/overclaude-install-transaction bin/overclaude-checkpoint \
         bin/overclaude-codex-continue bin/overclaude-codex-probe bin/overclaude-codex-pool hooks/handoff-inject.sh \
         hooks/ctx-watch.sh hooks/ctx-notify.sh statusline/statusline-command.sh \
         skills/swap/SKILL.md skills/handoff/SKILL.md skills/checkpoint/SKILL.md claude/ULTRACODE.md \
         settings/settings-fragment.json shell/zshrc-snippet.sh vendor/claude-swap/pyproject.toml \
         bin/overclaude_runtime/tomli/_parser.py bin/overclaude_runtime/tomli/LICENSE; do
  printf '%s\n' "$list" | grep -q "overclaude/payload/$f" || { echo "payload missing: $f"; exit 1; }
done
printf '%s\n' "$list" | grep -q "overclaude/verify.py" || { echo "verifier missing"; exit 1; }
venv=$(mktemp -d "${TMPDIR:-/tmp}/overclaude-wheel.XXXXXX")
trap 'rm -rf "$venv"' EXIT
uv venv --quiet "$venv" && uv pip install --quiet --python "$venv/bin/python" --no-deps "$whl" || { echo "wheel install failed"; exit 1; }
"$venv/bin/python" -c 'from overclaude.verify import verify; from overclaude.cli import _payload_dir; assert callable(verify); _payload_dir()' \
  || { echo "wheel import check failed"; exit 1; }
echo "payload complete"
