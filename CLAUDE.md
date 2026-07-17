# overclaude — maintainer protocol

This repo is the **published** overclaude kit: GitHub (arthur-bump-pm/overclaude) + PyPI (`overclaude`). Changes here reach other machines only through releases, so:

## After ANY change to the kit

1. **Changes made to the live setup** (`~/.claude/...`, `~/.local/bin/swap-guard`, the `~/.zshrc` block): run `./sync.sh` to pull them into the repo. Never hand-copy — sync.sh has the personal-data scrub gate.
2. **Ship it**: `./sync.sh --release` — syncs, patch-bumps `version` in pyproject.toml, commits, pushes, and cuts a GitHub release. The `publish.yml` workflow (PyPI trusted publishing) takes it from there. Use `--dry-run` first when unsure.
3. **`git push` alone does NOT update PyPI.** Only a release does. If a change matters to other machines, it needs a release.

## Rules

- Keep repo copies and live files **byte-identical** — that's what keeps sync.sh diffs clean. If you edit a kit file in the repo directly, also run `./install.sh` to propagate it to the live setup.
- Never weaken the scrub gate in sync.sh. No usernames, emails, or `/Users/...` paths in any committed file — use `$HOME`, generic aliases (`work`/`personal`), and `myproject` in examples.
- `vendor/claude-swap/` is unmodified third-party source (MIT, credited in README). Never edit it in place; version bumps follow `vendor/README.md`.
- For a minor/major version bump (new feature / breaking change), edit `version` in pyproject.toml manually before `./sync.sh --release` (it only auto-bumps the patch level).
- After releasing, remind the user that other machines update via `pipx upgrade overclaude && overclaude install`.
