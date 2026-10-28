#!/usr/bin/env python3
"""po-kit: po team — read the optional host files and print what to merge.

Usage: team_files.py <limits_file|-> <usage_file|->
limits file: a JSON object, agent -> an ISO time string, or null (no limit).
usage file:  a JSON object, agent -> an object of numbers (e.g. five_hour, seven_day).
Prints one line per agent named in either file: name TAB limit TAB usage, where
limit is a JSON string or null and usage a compact JSON object, either empty
when that file does not give the agent. A missing or empty path is ignored; a
file that cannot be read or is not shaped as above warns on stderr and gives
nothing. Standard library only.
"""
import json
import os
import sys


def warn(msg):
    sys.stderr.write("po team: warning: %s\n" % msg)


def load(path):
    if path in ("", "-") or not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        warn("cannot read %s: %s" % (path, e))
        return {}
    if not isinstance(data, dict):
        warn("%s is not a JSON object keyed by agent name" % path)
        return {}
    return data


def main():
    limits = load(sys.argv[1])
    usage = load(sys.argv[2])
    out = {}
    for name, v in limits.items():
        if v is None or isinstance(v, str):
            out.setdefault(name, ["", ""])[0] = json.dumps(v)
    for name, v in usage.items():
        if isinstance(v, dict):
            nums = {k: x for k, x in v.items() if isinstance(x, (int, float)) and not isinstance(x, bool)}
            out.setdefault(name, ["", ""])[1] = json.dumps(nums, separators=(",", ":"))
    for name, (lim, use) in out.items():
        if "\t" in name or "\n" in name:
            continue
        print("%s\t%s\t%s" % (name, lim, use))


if __name__ == "__main__":
    main()
