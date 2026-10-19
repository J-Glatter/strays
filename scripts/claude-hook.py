#!/usr/bin/env python3
"""Add or remove Strays' Claude Code hooks in ~/.claude/settings.json.

    claude-hook.py status | install | uninstall

SessionStart tells a new session what's already running in its project; SessionEnd records what
an ending session leaves running. Only touches the entries it owns. Key order and 2-space formatting are kept
(Claude Code writes the file the same way), a backup goes next to it, and the write is atomic.
"""
import json
import os
import shutil
import sys

SETTINGS = os.path.expanduser("~/.claude/settings.json")
HOOKS = {
    "SessionStart": "--session-start",
    "SessionEnd": "--session-end",
}


def command(flag):
    return '"$HOME/.local/bin/strays" ' + flag + " 2>/dev/null || true"


def load():
    if not os.path.exists(SETTINGS):
        return {}, True
    with open(SETTINGS, encoding="utf-8") as f:
        raw = f.read()
    return json.loads(raw), raw.endswith("\n")


def save(data, trailing_newline):
    if os.path.exists(SETTINGS):
        shutil.copy2(SETTINGS, SETTINGS + ".strays-backup")
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    tmp = SETTINGS + ".strays-tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(json.dumps(data, indent=2, ensure_ascii=False) + ("\n" if trailing_newline else ""))
    os.replace(tmp, SETTINGS)


def ours(hook, flag):
    cmd = hook.get("command", "")
    return "strays" in cmd and flag in cmd


def installed(data, event):
    groups = data.get("hooks", {}).get(event, [])
    return any(ours(h, HOOKS[event]) for g in groups for h in g.get("hooks", []))


def all_installed(data):
    return all(installed(data, e) for e in HOOKS)


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    data, newline = load()

    if action == "status":
        for event in HOOKS:
            print(f"{event}: " + ("installed" if installed(data, event) else "not installed"))
        return 0 if all_installed(data) else 1

    if action == "install":
        missing = [e for e in HOOKS if not installed(data, e)]
        if not missing:
            print("already installed")
            return 0
        for event in missing:
            entry = {"hooks": [{"type": "command", "command": command(HOOKS[event]), "timeout": 10}]}
            data.setdefault("hooks", {}).setdefault(event, []).append(entry)
        save(data, newline)
        print("installed " + ", ".join(missing) + " (applies to Claude sessions started from now on)")
        return 0

    if action == "uninstall":
        hooks = data.get("hooks", {})
        removed = []
        for event, flag in HOOKS.items():
            groups = hooks.get(event, [])
            kept = []
            for g in groups:
                before = len(g.get("hooks", []))
                g["hooks"] = [h for h in g.get("hooks", []) if not ours(h, flag)]
                if len(g["hooks"]) < before:
                    removed.append(event)
                if g["hooks"]:
                    kept.append(g)
            if kept:
                hooks[event] = kept
            else:
                hooks.pop(event, None)
        if not removed:
            print("not installed")
            return 0
        if not hooks:
            data.pop("hooks", None)
        save(data, newline)
        print("removed " + ", ".join(sorted(set(removed))))
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
