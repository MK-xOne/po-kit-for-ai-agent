#!/usr/bin/env python3
"""po-kit: po team off|on — write the agent switch file ([team] inactive_file).

Usage: team_switch.py <file> off|on <agent>
The file holds one agent name per line; `#` lines are comments; names match
without regard to case or surrounding blanks. off appends <agent> as the last
line unless a line already names it; on removes every line naming it. Every
other byte is kept: comments, order, and the final newline or its absence. An
appended line follows the file's own ending: after a final newline it is
`<agent>\\n`, after none it is `\\n<agent>` (still no final newline); removing
an unterminated last line also drops the newline before it. So off then on of
the last line gives the file back byte for byte. A line switched on and off
again comes back at the end. The file is rewritten in place (same inode, no
rename); a missing file is created by off and is already-active for on.
Prints `now` (written) or `already` (nothing to do). Standard library only.
"""
import os
import sys


def names(line):
    """The agent a line names (lower-cased), or '' for a comment or a blank line."""
    s = line.decode("utf-8", "replace").strip()
    return "" if not s or s.startswith("#") else s.lower()


def switch(data, mode, agent):
    """(new bytes, changed) for the file's bytes, mode off|on and the agent's name."""
    want = agent.lower()
    lines = data.splitlines(keepends=True)
    hit = [i for i, line in enumerate(lines) if names(line) == want]
    if mode == "off":
        if hit:
            return data, False
        add = agent.encode("utf-8")
        if not data or data.endswith(b"\n"):
            return data + add + b"\n", True
        return data + b"\n" + add, True
    if not hit:
        return data, False
    keep = [line for i, line in enumerate(lines) if i not in hit]
    out = b"".join(keep)
    last = lines[-1]
    if hit[-1] == len(lines) - 1 and not last.endswith(b"\n") and out.endswith(b"\n"):
        out = out[:-1]
    return out, True


def main():
    path, mode, agent = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode not in ("off", "on"):
        sys.exit("team_switch.py: mode must be off or on")
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        data = None
    if data is None:
        if mode == "on":
            print("already")
            return
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        with os.fdopen(fd, "wb") as f:
            f.write(agent.encode("utf-8") + b"\n")
        print("now")
        return
    out, changed = switch(data, mode, agent)
    if not changed:
        print("already")
        return
    with open(path, "r+b") as f:
        f.write(out)
        f.truncate()
    print("now")


if __name__ == "__main__":
    main()
