#!/usr/bin/env python3
"""PreToolUse hook (Bash): block git commit / push / merge and gh pr merge.

The user makes all commits, pushes and merges by hand (decided 2026-11-20).
Reads the hook payload from stdin. For a blocked command it prints a JSON
"deny" decision; otherwise it prints nothing and the command runs as usual.
"""
import json
import re
import sys

# Split on shell separators so `git log | grep merge` is not caught.
SEGMENT_SPLIT = re.compile(r"&&|\|\||[;|&\n()`]|\$\(")
# git [global options such as -C <dir>, -c k=v, --no-pager] <subcommand>
GIT = re.compile(
    r"^\s*(?:\S+=\S+\s+)*(?:sudo\s+)?git"
    r"(?:\s+(?:-C|-c|--git-dir|--work-tree)\s+\S+|\s+--?[\w-]+(?:=\S+)?)*"
    r"\s+(commit|push|merge|pull|cherry-pick|revert|am)(?=\s|$)"
)
GH = re.compile(r"^\s*gh\s+pr\s+(merge)(?=\s|$)")


def blocked(command: str):
    for segment in SEGMENT_SPLIT.split(command):
        m = GIT.search(segment) or GH.search(segment)
        if m:
            return segment.strip()
    return None


def main() -> None:
    try:
        payload = json.load(sys.stdin)
    except ValueError:
        return
    command = (payload.get("tool_input") or {}).get("command") or ""
    hit = blocked(command)
    if not hit:
        return
    print(json.dumps({
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": (
                f"Blocked by project hook: `{hit}`. The user makes every git "
                "commit, push and merge manually. Tell "
                "the user what is ready and suggest the command for them to run."
            ),
        }
    }))


if __name__ == "__main__":
    main()
