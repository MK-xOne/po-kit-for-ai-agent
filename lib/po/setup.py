"""po-kit: setup after install — the spec section parser and the step state file.

Called by lib/po/setup.sh, never by hand. Subcommands:

  parse <first line number>       the markdown on stdin (a spec section or a whole file):
                                  print one JSON object {found, line, kind, steps, error}.
                                  kind is "none" (the word None), "steps" (a well-formed
                                  table) or "bad" (error says why); found false when no
                                  "Setup after install" heading is there.
  plan <steps json>               the steps grouped by machine and who, for the close plan.
  record <state> <item> <steps json file> <now>
                                  write the item's steps as open; confirmed ones are kept.
  list <state> <item or -> <all 0|1> <json 0|1>
  block <changelog> <N> <write 0|1> <state>
                                  print the Setup after install block of release N's entry
                                  (Unreleased when it has no heading yet); write 1 inserts it.
  confirm <state> <item> <n> <by> <now>
                                  exit 0 confirmed, 3 already confirmed (says by whom), 1 no
                                  such step.

The state file is {"steps": [...]}, one object per step, written atomically (a temp file
and a rename) under an flock on <state>.lock.
"""
import fcntl
import json
import os
import re
import sys
import tempfile

HEADING = re.compile(r"^(#{1,6})(?:[ \t]+(.*?))?[ \t]*#*[ \t]*$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
COLUMNS = ["#", "machine", "command", "who", "check"]


def split_row(line):
    """The cells of a table row; a | inside backticks or written \\| is not a separator."""
    s = line.strip()
    if s.startswith("|"):
        s = s[1:]
    if s.endswith("|") and not s.endswith("\\|"):
        s = s[:-1]
    cells, cur, tick = [], "", False
    i = 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s) and s[i + 1] == "|":
            cur += "|"
            i += 2
            continue
        if c == "`":
            tick = not tick
        if c == "|" and not tick:
            cells.append(cur.strip())
            cur = ""
        else:
            cur += c
        i += 1
    cells.append(cur.strip())
    return cells


def find_section(lines):
    """(index of the heading, body lines) of the first Setup after install heading, or None."""
    fence = ""
    start, level = None, 0
    for i, line in enumerate(lines):
        m = FENCE.match(line)
        if m:
            if not fence:
                fence = m.group(1)
                continue
            if m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
                fence = ""
                continue
        if fence:
            continue
        h = HEADING.match(line)
        if not h:
            continue
        if start is not None and len(h.group(1)) <= level:
            return start, lines[start + 1:i]
        if start is None and len(h.group(1)) >= 2 and (h.group(2) or "").strip().lower() == "setup after install":
            start, level = i, len(h.group(1))
    if start is not None:
        return start, lines[start + 1:]
    return None


def parse(text, first):
    lines = text.split("\n")
    hit = find_section(lines)
    if hit is None:
        return {"found": False, "line": None, "kind": None, "steps": [], "error": ""}
    at, body = hit
    out = {"found": True, "line": first + at, "kind": "bad", "steps": [], "error": ""}
    rows = [(first + at + 1 + k, ln.strip()) for k, ln in enumerate(body) if ln.strip()]
    if not rows:
        out["error"] = "the section is empty; write its steps, or the word None"
        return out
    if len(rows) == 1 and rows[0][1].rstrip(".") == "None":
        out["kind"] = "none"
        return out
    for n, ln in rows:
        if not ln.startswith("|"):
            out["error"] = f"line {n}: not a table row and not the word None: {ln[:60]}"
            return out
    head = [c.lower() for c in split_row(rows[0][1])]
    if head != COLUMNS:
        out["error"] = f"line {rows[0][0]}: the columns must be | # | Machine | Command | Who | Check |"
        return out
    if len(rows) < 2 or not re.fullmatch(r"\|?(\s*:?-+:?\s*\|)+\s*:?-+:?\s*\|?", rows[1][1]):
        out["error"] = f"line {rows[0][0] + 1}: the header needs a |---| separator row under it"
        return out
    steps = []
    for n, ln in rows[2:]:
        cells = split_row(ln)
        if len(cells) != 5:
            out["error"] = f"line {n}: a step needs 5 cells (# | Machine | Command | Who | Check), it has {len(cells)}"
            return out
        num, machine, command, who, check = cells
        want = len(steps) + 1
        if num != str(want):
            out["error"] = f"line {n}: steps must be numbered 1, 2, 3...; expected {want}, found {num or 'nothing'}"
            return out
        for name, val in (("Machine", machine), ("Command", command), ("Who", who), ("Check", check)):
            if not val:
                out["error"] = f"line {n}: step {want} has no {name}"
                return out
        if command != "-":
            if not (len(command) > 2 and command.startswith("`") and command.endswith("`") and "`" not in command[1:-1]):
                out["error"] = f"line {n}: step {want}'s Command must be one `backticked` command, or - for none"
                return out
            command = command[1:-1]
        steps.append({"n": want, "machine": machine, "command": command, "who": who, "check": check})
    if not steps:
        out["error"] = "the table has no steps; write at least one, or the word None"
        return out
    out["kind"], out["steps"] = "steps", steps
    return out


def load(state):
    try:
        with open(state) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {"steps": []}
    if not isinstance(data, dict) or not isinstance(data.get("steps"), list):
        raise ValueError(f"{state} is not a setup state file")
    return data


def save(state, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(state), prefix=".po-setup.")
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=1)
        f.write("\n")
    os.replace(tmp, state)


class Locked:
    def __init__(self, state):
        self.path = state + ".lock"

    def __enter__(self):
        self.f = open(self.path, "w")
        fcntl.flock(self.f, fcntl.LOCK_EX)

    def __exit__(self, *a):
        self.f.close()


def vkey(item):
    return [int(x) if x.isdigit() else x for x in re.split(r"[.]", item)]


def record(state, item, steps_file, now):
    with open(steps_file) as f:
        steps = json.load(f)
    with Locked(state):
        data = load(state)
        keep = [s for s in data["steps"] if s.get("item") != item or s.get("status") == "confirmed"]
        done = {s.get("n") for s in keep if s.get("item") == item}
        for s in steps:
            if s["n"] in done:
                continue
            keep.append({"item": item, "n": s["n"], "machine": s["machine"], "command": s["command"],
                         "who": s["who"], "check": s["check"], "status": "open", "recorded_at": now,
                         "confirmed_by": None, "confirmed_at": None})
        keep.sort(key=lambda s: (vkey(str(s.get("item"))), s.get("n", 0)))
        data["steps"] = keep
        save(state, data)
    return 0


def list_steps(state, item, all_, as_json, tagfmt):
    steps = [s for s in load(state)["steps"] if (item == "-" or s.get("item") == item)
             and (all_ == "1" or s.get("status") == "open")]
    if as_json == "1":
        print(json.dumps({"steps": steps}))
        return 0
    for s in steps:
        tag = tagfmt.replace("{version}", str(s.get("item")))
        status = s.get("status")
        if status == "confirmed":
            status = f"confirmed by {s.get('confirmed_by')} at {s.get('confirmed_at')}"
        print(f"{tag} #{s.get('n')}  {status}  {s.get('machine')}  {s.get('who')}  {s.get('command')}")
        print(f"    check: {s.get('check')}")
    return 0


def confirm(state, item, n, by, now):
    with Locked(state):
        data = load(state)
        for s in data["steps"]:
            if s.get("item") == item and str(s.get("n")) == n:
                if s.get("status") == "confirmed":
                    print(f"already confirmed by {s.get('confirmed_by')} at {s.get('confirmed_at')}")
                    return 3
                s.update(status="confirmed", confirmed_by=by, confirmed_at=now)
                save(state, data)
                return 0
    return 1


def plan(steps_json):
    """The steps grouped by machine and who, in step order within each group."""
    groups = {}
    for s in json.loads(steps_json):
        groups.setdefault((s["machine"], s["who"]), []).append(s)
    for (machine, who), ss in groups.items():
        print(f"  {machine} · {who}")
        for s in ss:
            print(f"    {s['n']}. {s['command']}")
            print(f"       check: {s['check']}")
    return 0


ITEM_REF = re.compile(r"\bv(\d+(?:\.\d+)+)\b")
SETUP_HEAD = re.compile(r"###[ \t]+Setup after install[ \t]*")


def cell(text):
    """One table cell: a | is written \\|, a line break is a space."""
    return " ".join(str(text).split("\n")).replace("|", "\\|")


def code_span(cmd):
    """The command as a markdown code span whose fence is longer than any backtick run inside it."""
    longest = max((len(r) for r in re.findall(r"`+", cmd)), default=0)
    fence = "`" * (longest + 1)
    pad = " " if cmd.startswith("`") or cmd.endswith("`") else ""
    return f"{fence}{pad}{cmd}{pad}{fence}"


def setup_table(steps):
    """The block body for the steps: the word None, or the v0.91 table, one row per step."""
    if not steps:
        return "None"
    rows = ["| # | Machine | Command | Who | Check |", "|---|---|---|---|---|"]
    for i, s in enumerate(steps, 1):
        cmd = str(s["command"])
        shown = cell(code_span(cmd)) if cmd != "-" else "-"
        rows.append(f"| {i} | {cell(s['machine'])} | {shown} (v{s['item']}) | {cell(s['who'])} | {cell(s['check'])} |")
    return "\n".join(rows)


def release_section(lines, n):
    """(first, last+1, heading is a release) of the entry for release n, else of Unreleased, else None."""
    want = re.compile(rf"^## Release {re.escape(n)} \(")
    for pat, is_release in ((want, True), (re.compile(r"^## Unreleased\s*$"), False)):
        for i, line in enumerate(lines):
            if pat.match(line):
                j = i + 1
                while j < len(lines) and not lines[j].startswith("## "):
                    j += 1
                return i, j, is_release
    return None


def existing_block(lines, first, last):
    """(heading index, end index) of the setup block opening the entry, or None."""
    i = first + 1
    while i < last and not lines[i].strip():
        i += 1
    if i >= last or not SETUP_HEAD.fullmatch(lines[i]):
        return None
    j = i + 1
    while j < last and not lines[j].strip():
        j += 1
    while j < last and lines[j].strip() and not lines[j].startswith("#"):
        j += 1
    return i, j


def release_block(changelog, n, write, state):
    """Print the entry's setup block built from the recorded steps of the items it names; with
    write, insert (or replace) it under the `## Release n` heading. Exit 1 when it cannot."""
    with open(changelog) as f:
        text = f.read()
    lines = text.split("\n")
    found = release_section(lines, n)
    if found is None:
        print(f"po: release: {changelog} has no `## Release {n} (date): ...` or `## Unreleased` section", file=sys.stderr)
        return 1
    first, last, is_release = found
    if write and not is_release:
        print(f"po: release: {changelog} has no `## Release {n} (date): ...` heading to write under; write it first", file=sys.stderr)
        return 1
    old = existing_block(lines, first, last)
    body_lines = lines[first + 1:last]
    if old:
        body_lines = lines[first + 1:old[0]] + lines[old[1]:last]
    items = list(dict.fromkeys(ITEM_REF.findall("\n".join(body_lines))))
    steps = [s for s in load(state)["steps"] if s.get("item") in items]
    steps.sort(key=lambda s: (items.index(s["item"]), s.get("n", 0)))
    block = ["### Setup after install", "", *setup_table(steps).split("\n")]
    if not write:
        print("\n".join(block))
        return 0
    if old:
        out = lines[:old[0]] + block + lines[old[1]:]
    else:
        out = lines[:first + 1] + ["", *block] + ([""] if lines[first + 1].strip() else []) + lines[first + 1:]
    new = "\n".join(out)
    if new == text:
        print(f"{changelog}: the Release {n} setup block is already current")
        return 0
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(changelog)), prefix=".po-changelog.")
    with os.fdopen(fd, "w") as f:
        f.write(new)
    os.replace(tmp, changelog)
    print(f"{changelog}: wrote the Release {n} setup block ({len(steps)} step(s))")
    return 0


def main(argv):
    cmd = argv[1]
    try:
        if cmd == "parse":
            print(json.dumps(parse(sys.stdin.read(), int(argv[2]))))
            return 0
        if cmd == "plan":
            return plan(argv[2])
        if cmd == "record":
            return record(*argv[2:6])
        if cmd == "list":
            return list_steps(*argv[2:7])
        if cmd == "confirm":
            return confirm(*argv[2:7])
        if cmd == "block":
            return release_block(argv[2], argv[3], argv[4] == "1", argv[5])
    except (OSError, ValueError) as e:
        print(f"po: {e}", file=sys.stderr)
        return 2
    print(f"po: setup.py: unknown subcommand {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
