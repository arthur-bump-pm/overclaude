"""Offline integrity checks for files and settings managed by the installer."""

import json
import os
import stat
from pathlib import Path

# The installer owns these files. Mode None means it intentionally preserves the
# user's existing permissions; executable files are explicitly chmod 755.
FILES = (
    ("bin/overclaude-codex-continue", ".local/bin/overclaude-codex-continue", 0o755),
    ("bin/overclaude-codex-probe", ".local/bin/overclaude-codex-probe", 0o755),
    ("bin/overclaude-codex-pool", ".local/bin/overclaude-codex-pool", 0o755),
    ("bin/overclaude-checkpoint", ".local/bin/overclaude-checkpoint", 0o755),
    ("bin/swap-guard", ".local/bin/swap-guard", 0o755),
    ("skills/swap/SKILL.md", ".claude/skills/swap/SKILL.md", None),
    ("skills/checkpoint/SKILL.md", ".claude/skills/checkpoint/SKILL.md", None),
    ("skills/handoff/SKILL.md", ".claude/skills/handoff/SKILL.md", None),
    ("hooks/handoff-inject.sh", ".claude/hooks/handoff-inject.sh", 0o755),
    ("hooks/ctx-watch.sh", ".claude/hooks/ctx-watch.sh", 0o755),
    ("hooks/ctx-notify.sh", ".claude/hooks/ctx-notify.sh", 0o755),
    ("statusline/statusline-command.sh", ".claude/statusline-command.sh", 0o755),
    ("claude/ULTRACODE.md", ".claude/ULTRACODE.md", None),
)

FILES += tuple(("bin/overclaude_runtime/" + name, ".local/bin/overclaude_runtime/" + name, 0o644)
               for name in ("README.md", "__init__.py", "tomli/LICENSE", "tomli/__init__.py",
                            "tomli/_parser.py", "tomli/_re.py", "tomli/_types.py", "tomli/py.typed"))


def _read(path, *, limit=4 * 1024 * 1024, follow=False):
    """Read a bounded regular file; opening a FIFO must never block verification."""
    flags = os.O_RDONLY | os.O_NONBLOCK
    if not follow:
        flags |= os.O_NOFOLLOW
    fd = os.open(path, flags)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit:
            raise ValueError("not a bounded regular file")
        with os.fdopen(fd, "rb", closefd=False) as stream:
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise ValueError("file too large")
        return data
    finally:
        os.close(fd)


def verify(payload, home, version):
    """Return (errors, notes), reading only kit files and non-secret configuration."""
    payload, home = Path(payload), Path(home)
    errors, notes = [], []
    for src, dest, mode in FILES:
        source, installed = payload / src, home / dest
        try:
            if source.is_symlink() or installed.is_symlink() or not source.is_file() or not installed.is_file():
                errors.append(f"missing required file: {dest}")
            elif _read(source) != _read(installed):
                errors.append(f"content differs: {dest}")
            elif mode is not None and stat.S_IMODE(installed.stat().st_mode) != mode:
                errors.append(f"incorrect mode (expected {mode:o}): {dest}")
        except (OSError, ValueError):
            errors.append(f"cannot read required file: {dest}")
    try:
        if _read(home / ".claude-swap-backup/kit-version").decode().strip() != version:
            errors.append("installed kit version does not match the package")
    except (OSError, UnicodeError, ValueError):
        errors.append("installed kit version is missing or unreadable")
    try:
        if "@ULTRACODE.md" not in _read(home / ".claude/CLAUDE.md", follow=True).decode().splitlines():
            errors.append("CLAUDE.md does not import @ULTRACODE.md")
    except (OSError, UnicodeError, ValueError):
        errors.append("CLAUDE.md is missing or unreadable")
    try:
        snippet = _read(payload / "shell/zshrc-snippet.sh").decode()
        zshrc = _read(home / ".zshrc", follow=True).decode()
        begin = "# --- claude-swap integration (begin) ---"
        end = "# --- claude-swap integration (end) ---"
        if zshrc.count(begin) != 1 or zshrc.count(end) != 1 or zshrc.index(begin) > zshrc.index(end):
            errors.append("shell integration markers are missing, duplicated, or out of order")
        else:
            block = zshrc[zshrc.index(begin):zshrc.index(end) + len(end)]
            if block != snippet.strip():
                notes.append("existing shell integration differs from the bundled snippet; installer preserves it")
    except (OSError, UnicodeError, ValueError):
        errors.append("shell integration is missing or unreadable")
    try:
        fragment = json.loads(_read(payload / "settings/settings-fragment.json").decode())
        settings = json.loads(_read(home / ".claude/settings.json", follow=True).decode())
        if not isinstance(settings, dict) or not isinstance(fragment, dict):
            raise ValueError("settings are not objects")
        hooks = settings.get("hooks", {})
        if not isinstance(hooks, dict):
            raise ValueError("hooks are not an object")
        if settings.get("disableAllHooks") is True:
            errors.append("all hooks are disabled in settings")
        for event, required_groups in fragment["hooks"].items():
            groups = hooks.get(event, [])
            if not isinstance(groups, list):
                groups = []
            for required in required_groups:
                # Accept unrelated extra keys/hooks, but require the matcher and
                # all execution attributes of each managed hook to agree.
                def matches(group):
                    if not isinstance(group, dict) or group.get("matcher") != required.get("matcher"):
                        return False
                    if group.get("disabled", False) is not False or group.get("enabled", True) is not True or group.get("once", False) is not False:
                        return False
                    candidates = group.get("hooks", [])
                    if not isinstance(candidates, list):
                        return False
                    def hook_matches(candidate, hook):
                        if not isinstance(candidate, dict) or any(candidate.get(k) != v for k, v in hook.items()):
                            return False
                        if candidate.get("disabled", False) is not False or candidate.get("enabled", True) is not True:
                            return False
                        for key in ("async", "asyncRewake", "once"):
                            if candidate.get(key, False) != hook.get(key, False):
                                return False
                        if "timeout" not in hook and "timeout" in candidate:
                            return False
                        return True
                    return all(any(hook_matches(candidate, hook) for candidate in candidates) for hook in required["hooks"])
                if not any(matches(group) for group in groups):
                    errors.append(f"missing or incorrect {event} hook: {required['hooks'][0]['command']}")
        allow = settings.get("permissions", {}).get("allow", [])
        if not isinstance(allow, list) or any(item not in allow for item in fragment["permissions"]["allow"]):
            errors.append("required kit permissions are missing")
        statusline = settings.get("statusLine")
        if not isinstance(statusline, dict) or statusline.get("type") != "command" or not isinstance(statusline.get("command"), str) or not statusline["command"].strip():
            errors.append("statusLine is missing or invalid")
        elif statusline != fragment.get("statusLine"):
            notes.append("custom statusLine retained; kit context relay may be unavailable")
    except (OSError, UnicodeError, ValueError, TypeError, KeyError, AttributeError):
        errors.append("settings or bundled settings fragment is missing or invalid")
    return errors, notes
