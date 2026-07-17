# vendor/

## claude-swap (cswap) — vendored

- **What**: `claude_swap-0.21.0.tar.gz` — the official source distribution of [claude-swap](https://github.com/realiti4/claude-swap) by **Onur Cetinkol**, downloaded unmodified from [PyPI](https://pypi.org/project/claude-swap/).
- **License**: MIT (the LICENSE file is inside the tarball). overclaude itself is also MIT; the two are compatible.
- **Why vendored**: cswap is the credential-switching engine overclaude wraps. Bundling the exact tested version makes `./install.sh` self-contained — no separate manual install, no version drift between machines.
- **How it's used**: `install.sh` runs `pipx install <this tarball>` when `cswap` isn't already on the machine. Python package dependencies (keyring, textual, truststore) are still resolved from PyPI by pipx at install time.

### Updating the vendored version

```bash
python3 -m pip download claude-swap==<NEW_VERSION> --no-deps --no-binary :all: -d vendor/
rm vendor/claude_swap-<OLD_VERSION>.tar.gz
./install.sh   # verify, then commit
```

`install.sh` picks up whatever `vendor/claude_swap-*.tar.gz` is present — no script change needed for a version bump. Test a switch round-trip (`cswap list --json`, `cswap switch <alias>`) before pushing, since the rest of the kit depends on cswap's JSON output shapes and state files (`~/.claude-swap-backup/sequence.json`, `cache/usage.json`).
