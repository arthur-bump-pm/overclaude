# vendor/

## claude-swap (cswap) — vendored

- **What**: `claude-swap/` — the complete, unmodified source tree of [claude-swap](https://github.com/realiti4/claude-swap) v0.21.0 by **Onur Cetinkol**, as published to [PyPI](https://pypi.org/project/claude-swap/) (extracted from the official sdist).
- **License**: MIT (`claude-swap/LICENSE`). overclaude itself is also MIT; the two are compatible.
- **Why vendored**: cswap is the credential-switching engine overclaude wraps. Bundling the exact tested version makes the kit self-contained — no separate manual install, no version drift between machines, and the source is browsable right here.
- **How it's used**: `install.sh` runs `pipx install vendor/claude-swap` (or `uv tool install` if pipx is absent) when `cswap` isn't already on the machine. Python package dependencies (keyring, textual, truststore) are still resolved from PyPI at install time.

### Updating the vendored version

```bash
python3 -m pip download claude-swap==<NEW_VERSION> --no-deps --no-binary :all: -d /tmp/
rm -rf vendor/claude-swap
tar -xzf /tmp/claude_swap-<NEW_VERSION>.tar.gz -C vendor/
mv vendor/claude_swap-<NEW_VERSION> vendor/claude-swap
./install.sh   # verify, then commit
```

Test a switch round-trip (`cswap list --json`, `cswap switch <alias>`) before pushing, since the rest of the kit depends on cswap's JSON output shapes and state files (`~/.claude-swap-backup/sequence.json`, `cache/usage.json`).
