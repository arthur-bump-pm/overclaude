"""overclaude CLI — runs the bundled kit installer/uninstaller.

The package wheel carries the same payload a git clone has (bin/, skills/,
hooks/, statusline/, claude/, settings/, shell/, vendor/claude-swap, and the
install/uninstall/doctor scripts). This CLI just locates that payload and runs the
battle-tested bash scripts against it.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import urllib.request
from importlib.metadata import version as pkg_version
from importlib.resources import files


def _payload_dir():
    p = files("overclaude").joinpath("payload")
    path = str(p)
    if not os.path.isdir(path) or not os.path.isfile(os.path.join(path, "install.sh")):
        sys.exit("overclaude: bundled payload is missing — broken install; reinstall the package")
    return path


def _run_script(name, *args):
    # OVERCLAUDE_VERSION lets install.sh record the installed version (doctor and the
    # statusline's update badge compare it with PyPI).
    env = dict(os.environ, OVERCLAUDE_VERSION=pkg_version("overclaude"))
    return subprocess.call(["bash", os.path.join(_payload_dir(), name), *args], env=env)


def _latest_version():
    try:
        with urllib.request.urlopen("https://pypi.org/pypi/overclaude/json", timeout=10) as r:
            return json.load(r)["info"]["version"]
    except Exception:
        return None


def _upgrade_command():
    """How this copy was installed decides how to upgrade it."""
    prefix = sys.prefix.replace(os.sep, "/")
    if "/pipx/venvs/" in prefix and shutil.which("pipx"):
        return ["pipx", "upgrade", "overclaude"]
    if "/uv/tools/" in prefix and shutil.which("uv"):
        return ["uv", "tool", "upgrade", "overclaude"]
    return [sys.executable, "-m", "pip", "install", "--upgrade", "overclaude"]


def _update(check_only):
    current = pkg_version("overclaude")
    latest = _latest_version()
    if latest is None:
        print("overclaude: could not reach PyPI to check for a newer version")
        return 1
    print(f"installed {current} · latest {latest}")
    if check_only:
        return 0
    if latest == current:
        print("already up to date — refreshing the live kit files anyway")
    else:
        cmd = _upgrade_command()
        print("upgrading: " + " ".join(cmd))
        rc = subprocess.call(cmd)
        if rc != 0:
            print("overclaude: upgrade failed; nothing else was changed")
            return rc
    # A fresh interpreter loads the upgraded package before installing its payload.
    rc = subprocess.call([sys.executable, "-m", "overclaude.cli", "install"])
    if rc == 0:
        print("done — restart open Claude Code sessions so they load the new hooks")
    return rc


def main():
    ap = argparse.ArgumentParser(
        prog="overclaude",
        description="Claude Code, overclocked — /swap, /handoff, statusline, ULTRACODE model routing.",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install", help="install/refresh the kit into ~/.claude (idempotent, backs everything up)")
    sub.add_parser("uninstall", help="remove exactly what install added (state in ~/.claude-swap-backup survives)")
    p_doc = sub.add_parser("doctor", help="health check of the live install, with a fix for each problem")
    p_doc.add_argument("--fix", action="store_true", help="apply the safe repairs, then check again")
    p_up = sub.add_parser("update", help="upgrade overclaude from PyPI and reinstall the kit")
    p_up.add_argument("--check", action="store_true", help="only report installed vs latest")
    sub.add_parser("path", help="print the bundled payload directory")
    sub.add_parser("version", help="print the overclaude version")
    args = ap.parse_args()

    if args.cmd == "install":
        sys.exit(_run_script("install.sh"))
    if args.cmd == "uninstall":
        sys.exit(_run_script("uninstall.sh"))
    if args.cmd == "doctor":
        sys.exit(_run_script("doctor.sh", *(["--fix"] if args.fix else [])))
    if args.cmd == "update":
        sys.exit(_update(args.check))
    if args.cmd == "path":
        print(_payload_dir())
        return
    if args.cmd == "version":
        print(pkg_version("overclaude"))


if __name__ == "__main__":
    main()
