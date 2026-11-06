# shellcheck shell=bash
# po lint-founding — read-only. Does what a founding commit left on main hold together?
#
#   po lint-founding [--ready <file>] [--project <name>] [--agents <a,b,...>]
#
# Three checks, all against main as committed (never a working tree). One
# finding per line, `<file>:<line>: <what is wrong>`; nothing is printed for a
# clean backlog. Exit 0 clean, 1 findings.
#   1. Every backlog table row and every item heading has its status, written
#      as one ALL-CAPS word (a row of a table with a Status column; a heading
#      `## <tag-form id> — <title> — <STATUS>`). po's own readers stop at the
#      first malformed one; this lists them all.
#   2. Every item that is not DONE has its spec: a heading for it in a *.md
#      file of [layout] specs_dir, found the way `po kickoff` finds it. Skipped
#      when specs_dir is the repository root (".": the specs are the backlog
#      rows themselves).
#   3. The ready file ([ready] file, or --ready): every line is valid JSON with
#      an `item`, names an item that is TODO on main (DOING and DONE lines are
#      the history of items already given out and are left alone; a HELD, PAUSED or
#      BLOCKED item is not ready), names only known agents,
#      and no line is duplicated (a corrected line for an item replaces the old one,
#      and only the last line of an item is checked). A
#      line whose `project` differs from [project] name (or --project) is
#      another project's and is not read. Known agents: the [[team.agent]]
#      roster, [dispatch] order and --agents; with none of those, the agent
#      names are not checked. Without a ready file the check is skipped.

po_cmd_lint_founding() {
	local ready='' project='' agents='' a
	ready=${PO_MANIFEST[ready.file]:-}
	project=${PO_MANIFEST[project.name]:-}
	while (($# > 0)); do
		case $1 in
		--ready)
			(($# >= 2)) || po_usage_die "lint-founding: --ready needs a file"
			ready=$2
			shift
			;;
		--project)
			(($# >= 2)) || po_usage_die "lint-founding: --project needs a name"
			project=$2
			shift
			;;
		--agents)
			(($# >= 2)) || po_usage_die "lint-founding: --agents needs a comma-separated list"
			agents+=",$2"
			shift
			;;
		*) po_usage_die "lint-founding: unknown argument '$1'" ;;
		esac
		shift
	done
	command -v python3 >/dev/null 2>&1 || po_die "lint-founding needs python3"
	for a in "${PO_TEAM_NAME[@]}"; do agents+=",$a"; done
	while IFS= read -r a; do
		[[ -z $a ]] || agents+=",$a"
	done <<<"${PO_MANIFEST[dispatch.order]:-}"

	python3 -I -c '
import json, re, subprocess, sys

main, backlog, specs_dir, tag, ready, project, agents = sys.argv[1:8]
known = {a.strip().lower() for a in agents.split(",") if a.strip()}
prefix, _, suffix = tag.partition("{version}")
ID = re.compile("^" + re.escape(prefix) + r"([0-9]+(?:\.[0-9]+)+)" + re.escape(suffix) + "$")
CAPS = re.compile(r"^[A-Z]{2,}$")
OPEN_WORDS = {"DOING", "PAUSED", "BLOCKED"}
findings = []


def say(where, msg):
    findings.append("%s: %s" % (where, msg))


def git(*args):
    r = subprocess.run(["git", *args], capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def cells(row):
    row = row.strip()
    row = row[1:] if row.startswith("|") else row
    row = row[:-1] if row.endswith("|") else row
    return [c.strip() for c in row.split("|")]


def decorated(word):
    """The word with markdown decoration stripped, upper-cased, if it is an open status written loosely."""
    norm = re.sub(r"[*_`]", "", word).upper()
    return norm if norm in OPEN_WORDS and norm != word else None


listing = git("ls-tree", "--name-only", main, "--", specs_dir.rstrip("/") + "/") or ""
spec_files = [f for f in listing.splitlines() if f.endswith(".md")]
files = [backlog] + [f for f in spec_files if f != backlog]
text = {}
for f in files:
    t = git("show", "%s:%s" % (main, f))
    if t is None:
        if f == backlog:
            print("po: backlog %s not found on %s" % (backlog, main), file=sys.stderr)
            sys.exit(2)
        continue
    text[f] = t.split("\n")

status = {}   # version -> (status, where): the first valid source wins
labels = {}   # version -> [row labels left of the id cell]
for f in files:
    if f not in text:
        continue
    fence = ""
    in_table, status_col, width = False, -1, 0
    for n, line in enumerate(text[f], 1):
        m = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
        if m:
            if not fence:
                fence = m.group(1)
            elif m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
                fence = ""
            continue
        if fence:
            continue
        where = "%s:%d" % (f, n)
        s = line.strip()
        if s.startswith("|"):
            cs = cells(s)
            if not in_table:
                in_table, status_col, width = True, -1, len(cs)
                for i, c in enumerate(cs):
                    if re.sub(r"[*_`]", "", c).lower() == "status":
                        if c != "Status":
                            say(where, "column header %r is not written exactly as Status" % c)
                        elif status_col < 0:
                            status_col = i
                continue
            if re.match(r"^\|[-:|\s]+\|$", s) or status_col < 0:
                continue
            idx = next((i for i, c in enumerate(cs) if ID.match(c)), -1)
            if idx < 0:
                continue
            ver = ID.match(cs[idx]).group(1)
            if len(cs) != width:
                say(where, "%s: row has %d cells, header has %d" % (cs[idx], len(cs), width))
                continue
            st = cs[status_col]
            if not CAPS.match(st):
                say(where, "%s: status %r is missing or not one ALL-CAPS word" % (cs[idx], st))
                continue
            status.setdefault(ver, (st, where))
            labels.setdefault(ver, [c for c in cs[:idx] if re.match(r"^[A-Za-z0-9][A-Za-z0-9._-]*$", c)])
            continue
        in_table = False
        if not line.startswith("## " + prefix) or not re.match(r"[0-9]", line[len("## " + prefix):len("## " + prefix) + 1]):
            continue
        ident = line[3:].split(None, 1)[0]
        mi = ID.match(ident)
        if not mi:
            say(where, "heading id %r is not in tag form %s" % (ident, tag))
            continue
        rest = line[3 + len(ident):]
        if not rest.startswith(" — "):
            say(where, "%s: heading has no \" — \" after its id" % ident)
            continue
        segs = rest[3:].split(" — ")
        if len(segs) < 2:
            say(where, "%s: heading has no status segment" % ident)
            continue
        caps = []
        for seg in segs[1:]:
            word = seg.split(None, 1)[0] if seg.strip() else ""
            fixed = decorated(word)
            if fixed:
                say(where, "%s: status %r is not written exactly as %s" % (ident, seg, fixed))
                caps.append(None)
            elif CAPS.match(word):
                caps.append(word)
        if not caps:
            say(where, "%s: heading has no ALL-CAPS status segment" % ident)
        elif len(caps) > 1:
            say(where, "%s: heading has two status-like segments" % ident)
        elif caps[0]:
            status.setdefault(mi.group(1), (caps[0], where))

# 2. every open item has a spec section
if specs_dir.rstrip("/") not in (".", ""):
    heads = []  # (level, text) of every heading in the spec files, fenced code skipped
    for f in spec_files:
        fence = ""
        for line in text.get(f, []):
            m = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
            if m:
                if not fence:
                    fence = m.group(1)
                elif m.group(1)[0] == fence[0] and len(m.group(1)) >= len(fence) and not m.group(2).strip():
                    fence = ""
                continue
            if fence:
                continue
            h = re.match(r"^(#{1,6})(?:[ \t]+(.*))?$", line)
            if h:
                heads.append((line, h.group(2) or ""))
    for ver, (st, where) in status.items():
        if st == "DONE":
            continue
        ident = prefix + ver + suffix
        if any(line.startswith("## " + ident + " — ") for line, _ in heads):
            continue
        hit = False
        for lab in labels.get(ver, []):
            re_l = re.escape(lab)
            pat = re.compile(r"(^|[^A-Za-z0-9_])item " + re_l + r"($|[^A-Za-z0-9_.-]|[.-]($|[^A-Za-z0-9_]))")
            if any(pat.search(t) for _, t in heads):
                hit = True
        if not hit:
            say(where, "%s (%s) has no spec section under %s" % (ident, st, specs_dir))

# 3. the ready file
if ready:
    try:
        lines = open(ready, encoding="utf-8").read().split("\n")
    except OSError as e:
        say(ready, "cannot read the ready file: %s" % e.strerror)
        lines = []
    seen, last = {}, {}   # raw line -> first line number; item -> (line number, object): the last one wins
    for n, raw in enumerate(lines, 1):
        if not raw.strip():
            continue
        where = "%s:%d" % (ready, n)
        try:
            obj = json.loads(raw)
        except ValueError as e:
            say(where, "not valid JSON: %s" % e)
            continue
        if not isinstance(obj, dict) or not isinstance(obj.get("item"), str):
            say(where, "no \"item\" string")
            continue
        if project and "project" in obj and obj["project"] != project:
            continue
        key = json.dumps(obj, sort_keys=True)
        if key in seen:
            say(where, "duplicate of line %d" % seen[key])
        else:
            seen[key] = n
        last[obj["item"]] = (n, obj)
    for item, (n, obj) in sorted(last.items(), key=lambda kv: kv[1][0]):
        where = "%s:%d" % (ready, n)
        mi = ID.match(item)
        st = status.get(mi.group(1))[0] if mi and status.get(mi.group(1)) else None
        if st is None:
            say(where, "%s is not in the backlog" % item)
        elif st not in ("TODO", "DOING", "DONE"):
            say(where, "%s is %s, not TODO" % (item, st))
        ag = obj.get("agents", [])
        if not isinstance(ag, list) or not all(isinstance(a, str) for a in ag):
            say(where, "%s: \"agents\" is not a list of names" % item)
        elif known:
            for a in ag:
                if a.lower() not in known:
                    say(where, "%s: unknown agent %r" % (item, a))

for f in findings:
    print(f)
sys.exit(1 if findings else 0)
' "$(po_get layout.main)" "$(po_get layout.backlog)" "$(po_get layout.specs_dir)" "$(po_get versioning.tag)" \
		"$ready" "$project" "$agents"
}
