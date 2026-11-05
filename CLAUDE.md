# overclaude — maintainer protocol

This repo is the **published** overclaude kit: GitHub (arthur-bump-pm/overclaude) + PyPI (`overclaude`). Changes here reach other machines only through releases, so:

## After ANY change to the kit

1. **Changes made to the live setup** (`~/.claude/...`, `~/.local/bin/swap-guard`, the `~/.zshrc` block): run `./sync.sh` to pull them into the repo. Never hand-copy — sync.sh has the personal-data scrub gate.
2. **Test it**: `bash tests/run.sh` (throwaway `$HOME`, safe to run anytime) and `shellcheck -S error` on changed scripts. There is no CI: the release gate runs both before anything ships — add a test with any behavior change.
3. **Ship it**: `./sync.sh --release` — runs the release gate first (shellcheck + full suite under `/bin/bash` 3.2; any failure aborts before anything is committed), then syncs, patch-bumps `version` in pyproject.toml, commits, builds the wheel and sdist on this Mac, checks them (`tests/check_wheel.sh`, `twine check`), uploads them to PyPI with `uv publish`, then pushes and cuts a GitHub release (notes only). The PyPI token is read from the login Keychain (service `pypi-overclaude`, account `__token__`); the owner stores it once with `security add-generic-password -U -a __token__ -s pypi-overclaude -w` and it is never printed or written to a file. Use `--dry-run` first when unsure.
4. **`git push` alone does NOT update PyPI.** Only a release does. If a change matters to other machines, it needs a release.

## Rules

- **No GitHub Actions, ever** (owner's rule, 5 Nov 2026): no `.github/workflows`, no CI on GitHub, no Actions-based publishing. Actions is turned off on the repo.

- Keep repo copies and live files **byte-identical** — that's what keeps sync.sh diffs clean. If you edit a kit file in the repo directly, also run `./install.sh` to propagate it to the live setup.
- Never weaken the scrub gate in sync.sh. Once per clone, `bash scrub.sh --install-hook` adds a pre-push check for commits made outside sync.sh; `bash scrub.sh --history` scans every commit. No usernames, emails, or `/Users/...` paths in any committed file — use `$HOME`, generic aliases (`work`/`personal`), and `myproject` in examples.
- `vendor/claude-swap/` is unmodified third-party source (MIT, credited in README). Never edit it in place; version bumps follow `vendor/README.md`.
- For a minor/major version bump (new feature / breaking change), edit `version` in pyproject.toml manually before `./sync.sh --release` (it only auto-bumps the patch level).
- After releasing, remind the user that other machines update via `pipx upgrade overclaude && overclaude install`.
- Keep the README `## Versions` table current at every status change: a 🚧 row when work on a version starts (docs-only push to main), ✅ + date in the release commit itself.
