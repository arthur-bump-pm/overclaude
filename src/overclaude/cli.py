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
            print("overclaude: package upgrade failed; managed kit installation was not attempted")
            return rc
    # A fresh interpreter loads the upgraded package before installing its payload.
    rc = subprocess.call([sys.executable, "-m", "overclaude.cli", "install"])
    if rc == 0:
        rc = subprocess.call([sys.executable, "-m", "overclaude.cli", "verify"])
        if rc == 0:
            print("done — restart open Claude Code sessions so they load the new hooks")
        else:
            print("overclaude: installed files failed offline verification; package upgrade was not rolled back", file=sys.stderr)
    return rc


def main():
    ap = argparse.ArgumentParser(
        prog="overclaude",
        description="Claude Code, overclocked — /swap, /handoff, statusline, ULTRACODE model routing.",
    )
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install", help="install/refresh the kit into ~/.claude (idempotent, backs everything up)")
    sub.add_parser("verify", help="check installed kit files and hooks offline")
    p_recover = sub.add_parser("recover", help="inspect or recover an interrupted managed-file transaction", allow_abbrev=False)
    recovery = p_recover.add_mutually_exclusive_group(required=True)
    recovery.add_argument("--list", action="store_true")
    recovery.add_argument("--transaction")
    p_recover.add_argument("--keep-current", action="store_true", help="retain reviewed conflicts after restoring all eligible files")
    p_status = sub.add_parser("status", help="show Codex continuation status")
    p_status.add_argument("--cwd")
    p_status.add_argument("--run")
    p_status.add_argument("--json", action="store_true")
    p_resume = sub.add_parser("resume", help="resume a saved Codex continuation", allow_abbrev=False)
    p_resume.add_argument("--run", required=True)
    p_resume.add_argument("--dry-run", action="store_true")
    p_pool = sub.add_parser("codex-pool", help="preview eligible Codex accounts without switching", allow_abbrev=False)
    p_pool.add_argument("--model")
    sub.add_parser("uninstall", help="remove exactly what install added (state in ~/.claude-swap-backup survives)")
    p_doc = sub.add_parser("doctor", help="health check of the live install, with a fix for each problem")
    p_doc.add_argument("--fix", action="store_true", help="apply the safe repairs, then check again")
    p_up = sub.add_parser("update", help="upgrade overclaude from PyPI and reinstall the kit")
    p_up.add_argument("--check", action="store_true", help="only report installed vs latest")
    p_fl = sub.add_parser("fleet", help="your other Macs over Tailscale SSH: add <host> | rm <host> | list | status | swap [--from <email>] [--dry-run] | auto on|off")
    p_fl.add_argument("args", nargs=argparse.REMAINDER)
    p_rm = sub.add_parser("remote", help="a Claude session on another Mac, driven from claude.ai/code: start <mac> [goal] | list <mac> | logs|stop|attach <mac> <name>")
    p_rm.add_argument("args", nargs=argparse.REMAINDER)
    sub.add_parser("path", help="print the bundled payload directory")
    sub.add_parser("version", help="print the overclaude version")
    args = ap.parse_args()

    if args.cmd == "install":
        sys.exit(_run_script("install.sh"))
    if args.cmd == "verify":
        from .verify import verify
        errors, notes = verify(_payload_dir(), os.path.expanduser("~"), pkg_version("overclaude"))
        for note in notes:
            print("note: " + note)
        for error in errors:
            print("error: " + error, file=sys.stderr)
        if not errors:
            print("overclaude: offline verification passed")
        sys.exit(1 if errors else 0)
    if args.cmd == "recover":
        if args.keep_current and args.list:
            p_recover.error("--keep-current requires --transaction")
        payload = _payload_dir()
        helper = os.path.join(payload, "bin", "overclaude-install-transaction")
        action = ["list"] if args.list else ["recover", "--transaction", args.transaction] + (["--keep-current"] if args.keep_current else [])
        sys.exit(subprocess.call([sys.executable, helper, "--payload", payload, *action]))
    if args.cmd in ("status", "resume"):
        runner = os.path.expanduser("~/.local/bin/overclaude-codex-continue")
        if not os.path.isfile(runner) or not os.access(runner, os.X_OK):
            sys.exit("overclaude: continuation helper missing; run overclaude install")
        if args.cmd == "status":
            rest = (["--cwd", args.cwd] if args.cwd else []) + (["--run", args.run] if args.run else []) + (["--json"] if args.json else [])
        else:
            rest = ["--run", args.run] + (["--dry-run"] if args.dry_run else [])
        sys.exit(subprocess.call([runner, args.cmd, *rest]))
    if args.cmd == "codex-pool":
        helper = os.path.expanduser("~/.local/bin/overclaude-codex-pool")
        if not os.path.isfile(helper) or not os.access(helper, os.X_OK):
            sys.exit("overclaude: pool preview helper missing; run overclaude install")
        sys.exit(subprocess.call([helper, *(["--model", args.model] if args.model else [])]))
    if args.cmd == "uninstall":
        sys.exit(_run_script("uninstall.sh"))
    if args.cmd == "doctor":
        sys.exit(_run_script("doctor.sh", *(["--fix"] if args.fix else [])))
    if args.cmd == "update":
        sys.exit(_update(args.check))
    if args.cmd == "fleet":
        sg = shutil.which("swap-guard") or os.path.join(_payload_dir(), "bin", "swap-guard")
        rest = args.args or ["status", "--text"]
        if rest == ["status"]:
            rest = ["status", "--text"]
        sys.exit(subprocess.call(["bash", sg, "fleet", *rest]))
    if args.cmd == "remote":
        sg = shutil.which("swap-guard") or os.path.join(_payload_dir(), "bin", "swap-guard")
        rest = args.args
        if len(rest) == 2 and rest[0] == "list":
            rest = [*rest, "--text"]
        sys.exit(subprocess.call(["bash", sg, "remote", *rest]))
    if args.cmd == "path":
        print(_payload_dir())
        return
    if args.cmd == "version":
        print(pkg_version("overclaude"))


if __name__ == "__main__":
    main()
