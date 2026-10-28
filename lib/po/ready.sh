# shellcheck shell=bash
# po ready — the ready list from backlog status.

po_cmd_ready() {
	local json=0 explain=0
	while (($#)); do
		case $1 in
		--json) json=1; shift ;;
		--explain) explain=1; shift ;;
		*) po_usage_die "unknown option '$1'" ;;
		esac
	done

	po_backlog_load
	local sm=""
	local rec v st
	declare -A seen=()
	tag=$(po_get versioning.tag)
	for rec in "${PO_ITEMS[@]}"; do
		IFS=$'\t' read -r v st _ <<<"$rec"
		id=$(po_fill "$tag" "$v")
		[[ -n ${seen[$id]+x} ]] && continue
		seen[$id]=1
		sm+="${id}"$'\t'"${st}"$'\n'
	done

	local file
	file=$(po_get ready.file 2>/dev/null || true)
	if [[ -z $file ]]; then
		po_die "no [ready] file configured in po.toml"
	fi
	local project_filter=""
	project_filter="${PO_MANIFEST[project.name]:-}"

	PO_STATUS_MAP="$sm" python3 - "$file" "$project_filter" "$json" "$explain" <<'PYEOF'
import json, sys, os
file, project_filter, json_flag, explain_flag = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
json_flag = json_flag == "1"
explain_flag = explain_flag == "1"

status_map = {}
for line in os.environ.get("PO_STATUS_MAP","").splitlines():
    if "\t" in line:
        k, v = line.split("\t", 1)
        status_map[k] = v

candidates = []
with open(file) as f:
    for i, raw in enumerate(f, 1):
        s = raw.strip()
        if not s:
            continue
        try:
            obj = json.loads(s)
        except Exception as e:
            print(f"malformed line {i}: {e}", file=sys.stderr)
            continue
        if not isinstance(obj, dict) or "item" not in obj:
            print(f"malformed line {i}: missing 'item'", file=sys.stderr)
            continue
        if "project" in obj and project_filter and obj["project"] != project_filter:
            continue
        candidates = [c for c in candidates if c[1].get("item") != obj["item"]]
        candidates.append((i, obj))

results = []
excluded = []
for ln, obj in candidates:
    item = obj["item"]
    title = obj.get("title", "")
    agents = obj.get("agents", [])
    depends = obj.get("depends", [])
    needs_note = obj.get("needs_note")
    reasons = []
    ok = True
    st = status_map.get(item)
    if st is None:
        ok = False; reasons.append("item absent from backlog")
    elif st != "TODO":
        ok = False; reasons.append(f"status is {st}, not TODO")
    for d in depends:
        if status_map.get(d) != "DONE":
            ok = False; reasons.append(f"depends {d} not DONE ({status_map.get(d,'absent')})")
    if needs_note:
        if not os.path.exists(needs_note):
            ok = False; reasons.append(f"needs_note missing: {needs_note}")
    if ok:
        results.append((item, title, agents))
    else:
        excluded.append((item, reasons))

if json_flag:
    out = [{"item": i, "title": t, "agents": a} for i, t, a in results]
    print(json.dumps(out))
else:
    for item, title, agents in results:
        line = item
        if title:
            line += "  " + title
        if agents:
            line += "  [" + ", ".join(agents) + "]"
        print(line)

if explain_flag:
    for item, reasons in excluded:
        print(f"{item}: " + "; ".join(reasons), file=sys.stderr)
PYEOF
}
