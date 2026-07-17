"""overclaude CLI — runs the bundled kit installer/uninstaller.

The package wheel carries the same payload a git clone has (bin/, skills/,
hooks/, statusline/, claude/, settings/, shell/, vendor/claude-swap, and the
install/uninstall scripts). This CLI just locates that payload and runs the
battle-tested bash scripts against it.
"""

import argparse
import os
import subprocess
import sys
from importlib.metadata import version as pkg_version
from importlib.resources import files


def _payload_dir():
    p = files("overclaude").joinpath("payload")
    path = str(p)
    if not os.path.isdir(path) or not os.path.isfile(os.path.join(path, "install.sh")):
        sys.exit("overclaude: bundled payload is missing — broken install; reinstall the package")
    return path


def _run_script(name):
    return subprocess.call(["bash", os.path.join(_payload_dir(), name)])


def main():
    ap = argparse.ArgumentParser(
        prog="overclaude",
        description="Claude Code, overclocked — /swap, /handoff, statusline, ULTRACODE model routing.",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install", help="install/refresh the kit into ~/.claude (idempotent, backs everything up)")
    sub.add_parser("uninstall", help="remove exactly what install added (state in ~/.claude-swap-backup survives)")
    sub.add_parser("path", help="print the bundled payload directory")
    sub.add_parser("version", help="print the overclaude version")
    args = ap.parse_args()

    if args.cmd == "install":
        sys.exit(_run_script("install.sh"))
    if args.cmd == "uninstall":
        sys.exit(_run_script("uninstall.sh"))
    if args.cmd == "path":
        print(_payload_dir())
        return
    if args.cmd == "version":
        print(pkg_version("overclaude"))


if __name__ == "__main__":
    main()
