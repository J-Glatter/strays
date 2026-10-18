#!/usr/bin/env python3
"""Add or remove Strays' SessionEnd hook in ~/.claude/settings.json.

    claude-hook.py status | install | uninstall

Only touches the hooks.SessionEnd entry it owns. Key order and 2-space formatting are kept
(Claude Code writes the file the same way), a backup goes next to it, and the write is atomic.
"""
import json
import os
import shutil
import sys

SETTINGS = os.path.expanduser("~/.claude/settings.json")
COMMAND = '"$HOME/.local/bin/strays" --session-end 2>/dev/null || true'


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


def ours(hook):
    command = hook.get("command", "")
    return "strays" in command and "--session-end" in command


def installed(data):
    groups = data.get("hooks", {}).get("SessionEnd", [])
    return any(ours(h) for g in groups for h in g.get("hooks", []))


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "status"
    data, newline = load()

    if action == "status":
        print("installed" if installed(data) else "not installed")
        return 0 if installed(data) else 1

    if action == "install":
        if installed(data):
            print("already installed")
            return 0
        entry = {"hooks": [{"type": "command", "command": COMMAND, "timeout": 10}]}
        data.setdefault("hooks", {}).setdefault("SessionEnd", []).append(entry)
        save(data, newline)
        print("installed: new Claude Code sessions will report what they leave running")
        return 0

    if action == "uninstall":
        hooks = data.get("hooks", {})
        groups = hooks.get("SessionEnd", [])
        kept = []
        for g in groups:
            g["hooks"] = [h for h in g.get("hooks", []) if not ours(h)]
            if g["hooks"]:
                kept.append(g)
        if len(kept) == len(groups) and not installed(data):
            print("not installed")
            return 0
        if kept:
            hooks["SessionEnd"] = kept
        else:
            hooks.pop("SessionEnd", None)
        if not hooks:
            data.pop("hooks", None)
        save(data, newline)
        print("removed")
        return 0

    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
