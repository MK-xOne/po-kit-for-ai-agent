# shellcheck shell=bash
# po dispatch — give the ready items to the free eligible agents.
#
#   po dispatch --plan      print who would get what, and why an item is skipped
#   po dispatch --commit    po open <item> --for <agent> --commit for each
#
# Inputs, all from the kit itself: `po ready --json` (the items that can run
# now, with the agents each may go to) and `po team --json` (who is free). For
# each ready item, in ready order, the first free agent that is eligible gets
# it: an item with a non-empty `agents` list is eligible only to those names
# (case-insensitive), one with no list to any roster agent. Agents are tried in
# the order of [dispatch] order (names; an agent not listed comes after those
# that are, in roster order). An agent gets at most one item per run, and an
# agent that is not free (WORKING, or owning an item) never gets one.
#
# --commit opens through `po open --for <agent> --commit` with BUZZ_AGENT set
# to `dispatcher`, so the open event carries that agent name. A failed open is
# reported and the run goes on. After each open, the item's kickoff is written
# to <git dir>/po-dispatch/<item>.md (a first line naming item and agent, then
# the output of po kickoff when it has one) and the optional [dispatch] notify command
# runs (sh -c, in the main worktree) with three arguments: the item, the agent,
# the prompt path. The kit knows no chat: a wrapper posts the message. A second
# run finds the opened items DOING, so it opens nothing.

PO_DISPATCHER=dispatcher

# po_dispatch_plan <ready-json> <team-json> <order>: one line per ready item,
# "ASSIGN<TAB>item<TAB>agent" or "SKIP<TAB>item<TAB>reason".
po_dispatch_plan() {
	python3 -I -c '
import json, sys
ready, team = json.loads(sys.argv[1]), json.loads(sys.argv[2])
order = [n.lower() for n in json.loads(sys.argv[3])]
names = [a["agent"] for a in team]
rank = {n.lower(): (order.index(n.lower()) if n.lower() in order else len(order)) for n in names}
free = sorted((a["agent"] for a in team if a.get("free")), key=lambda n: rank[n.lower()])
taken = set()
for it in ready:
    want = [w.lower() for w in it.get("agents", [])]
    elig = [n for n in names if not want or n.lower() in want]
    if not elig:
        print("SKIP\t%s\tno roster agent is eligible" % it["item"])
        continue
    pick = next((n for n in free if n in elig and n not in taken), None)
    if pick is None:
        print("SKIP\t%s\tno free eligible agent" % it["item"])
        continue
    taken.add(pick)
    print("ASSIGN\t%s\t%s" % (it["item"], pick))
' "$1" "$2" "$3"
}

po_cmd_dispatch() {
	local mode=''
	while (($# > 0)); do
		case $1 in
		--plan | --commit)
			[[ -z $mode || $mode == "$1" ]] || po_usage_die "dispatch: give --plan or --commit, not both"
			mode=$1
			;;
		*) po_usage_die "dispatch: unknown argument '$1'" ;;
		esac
		shift
	done
	[[ -n $mode ]] || po_usage_die "dispatch: give --plan or --commit"
	command -v python3 >/dev/null 2>&1 || po_die "dispatch needs python3"

	local ready team order=''
	ready=$("$PO_SELF" --manifest "$PO_MANIFEST_FILE" ready --json) || exit $?
	team=$(PO_TEAM_NO_OWNER_OK=1 "$PO_SELF" --manifest "$PO_MANIFEST_FILE" team --json) || exit $?
	local name sep=''
	while IFS= read -r name; do
		[[ -n $name ]] || continue
		order+=$sep$(po_json_str "$name") sep=,
	done <<<"${PO_MANIFEST[dispatch.order]:-}"
	order="[$order]"
	local plan
	plan=$(po_dispatch_plan "$ready" "$team" "$order") || po_die "dispatch: could not read the ready list or the roster"

	if [[ $mode == --plan ]]; then
		printf 'po dispatch: PLAN — nothing changes without --commit\n'
	else
		printf 'po dispatch --commit: opening the assigned items\n'
	fi
	local kind item rest agent n_ok=0 n_fail=0 n_skip=0 out dir prompt notify=''
	[[ -z ${PO_MANIFEST[dispatch.notify]+x} ]] || notify=${PO_MANIFEST[dispatch.notify]}
	while IFS=$'\t' read -r kind item rest; do
		[[ -n $kind ]] || continue
		if [[ $kind == SKIP ]]; then
			printf 'skip      %s  %s\n' "$item" "$rest"
			n_skip=$((n_skip + 1))
			continue
		fi
		agent=$rest
		if [[ $mode == --plan ]]; then
			printf 'assign    %s  to %s\n' "$item" "$agent"
			n_ok=$((n_ok + 1))
			continue
		fi
		if ! out=$(BUZZ_AGENT=$PO_DISPATCHER "$PO_SELF" --manifest "$PO_MANIFEST_FILE" open "$item" --for "$agent" --commit 2>&1); then
			printf 'FAILED    %s  to %s: %s\n' "$item" "$agent" "$(tail -n 1 <<<"$out")"
			n_fail=$((n_fail + 1))
			continue
		fi
		printf 'opened    %s  for %s\n' "$item" "$agent"
		n_ok=$((n_ok + 1))
		dir=$(dirname -- "$(po_events_file)")/po-dispatch
		prompt=$dir/$item.md
		if mkdir -p "$dir" && {
			printf '%s → %s · PROMPT\n' "$item" "$agent"
			"$PO_SELF" --manifest "$PO_MANIFEST_FILE" kickoff "$item" 2>/dev/null || true
		} >"$prompt"; then
			[[ -n $notify ]] || continue
			sh -c "$notify \"\$@\"" po-dispatch "$item" "$agent" "$prompt" </dev/null >&2 ||
				printf 'po: warning: dispatch notify exited non-zero for %s\n' "$item" >&2
		else
			printf 'po: warning: no prompt written for %s%s\n' "$item" "${notify:+; notify not run}" >&2
		fi
	done <<<"$plan"
	printf 'dispatch: %d %s, %d skipped, %d failed\n' "$n_ok" "$([[ $mode == --plan ]] && echo planned || echo opened)" "$n_skip" "$n_fail"
	((n_fail == 0)) || exit 6
	return 0
}
