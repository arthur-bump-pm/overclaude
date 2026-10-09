# overclaude — maintainer protocol

This repo is the **published** overclaude kit: GitHub (arthur-bump-pm/overclaude) + PyPI (`overclaude`). Changes here reach other machines only through releases, so:

## After ANY change to the kit

1. **Changes made to the live setup** (`~/.claude/...`, `~/.local/bin/swap-guard`, the `~/.zshrc` block): run `./sync.sh` to pull them into the repo. Never hand-copy — sync.sh has the personal-data scrub gate.
2. **Test it**: `bash tests/run.sh` (throwaway `$HOME`, safe to run anytime) and `shellcheck -S error` on changed scripts. CI runs both on every push and the publish job is gated on them — add a test with any behavior change.
3. **Ship it**: `./sync.sh --release` — runs the release gate first (shellcheck + full suite under `/bin/bash` 3.2; any failure aborts before anything is committed), then syncs, patch-bumps `version` in pyproject.toml, commits, pushes, and cuts a GitHub release. The `publish.yml` workflow (PyPI trusted publishing) takes it from there — it reuses the push-triggered Tests run's verdict for the release commit (re-running the suite only if that run is missing or was cancelled). Use `--dry-run` first when unsure.
4. **`git push` alone does NOT update PyPI.** Only a release does. If a change matters to other machines, it needs a release.

## Rules

- Keep repo copies and live files **byte-identical** — that's what keeps sync.sh diffs clean. If you edit a kit file in the repo directly, also run `./install.sh` to propagate it to the live setup.
- Never weaken the scrub gate in sync.sh. No usernames, emails, or `/Users/...` paths in any committed file — use `$HOME`, generic aliases (`work`/`personal`), and `myproject` in examples.
- `vendor/claude-swap/` is unmodified third-party source (MIT, credited in README). Never edit it in place; version bumps follow `vendor/README.md`.
- For a minor/major version bump (new feature / breaking change), edit `version` in pyproject.toml manually before `./sync.sh --release` (it only auto-bumps the patch level).
- After releasing, remind the user that other machines update via `pipx upgrade overclaude && overclaude install`.
