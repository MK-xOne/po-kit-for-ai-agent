# shellcheck shell=bash
# po-kit: po team — read-only. The feed the dashboard Team view reads:
#
#   po team [--json]
#
# One entry per [[team.agent]] of the manifest, in roster order:
#   {"agent","model"?,"state","now","owns":[],"free","limit_until"?,"usage"?}
# built from what the kit knows:
#   - the roster ([[team.agent]] name, model, role) in po.toml;
#   - the gate events: the age of an agent's newest event is its `idle <time>`;
#   - the backlog owner column ([layout] owner_column): `owns` is the open items
#     (DOING, PAUSED, BLOCKED) the agent owns, by version, as the backlog has them;
#   - WORKING, with `now` the lowest-numbered DOING item it owns, while the
#     agent owns one and its newest event is under 15 minutes old;
#   - `free`: not WORKING, and owning nothing, or idle 15 minutes or more with
#     every owned item held (PAUSED or BLOCKED, i.e. waiting on someone else).
#   - `inactive`: true for an agent named in the [team] inactive_file (the
#     agent switch file: one name per line, `#` comments, names matched without
#     case; a missing file names nobody); such an agent is never `free` and the
#     table says OFF in the FREE column. Its state and items are left as they are.
#
#   po team off|on <agent> [--commit]
#
# switches an agent off (its name appended to the inactive_file) or on (its
# line removed), in place; team_switch.py keeps every other byte. Without
# --commit it prints what it would do and writes nothing.
# Rate limits and usage are the host's facts, not probed here: the optional
# files named by [team] limits_file and usage_file are merged when present
# (see team_files.py for their shape); a missing file is ignored.

PO_TEAM_ACTIVE_SECS=900

# po_team_idle <seconds>: 22m, 3h, 2d.
po_team_idle() {
	if (($1 < 3600)); then
		printf '%dm' $(($1 / 60))
	elif (($1 < 86400)); then
		printf '%dh' $(($1 / 3600))
	else
		printf '%dd' $(($1 / 86400))
	fi
}

# po_team_inactive: the lower-cased names the [team] inactive_file lists, one per line.
po_team_inactive() {
	local f=${PO_MANIFEST[team.inactive_file]:-} line
	[[ -n $f && -f $f ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		po_trim_into "$line" line
		[[ -z $line || $line == '#'* ]] || printf '%s\n' "${line,,}"
	done <"$f"
}

# po_team_switch off|on <args>: po team off|on <agent> [--commit].
po_team_switch() {
	local mode=$1 agent='' commit=0 i name=''
	shift
	while (($# > 0)); do
		case $1 in
		--commit) commit=1 ;;
		-*) po_usage_die "team: unknown argument '$1'" ;;
		*)
			[[ -z $agent ]] || po_usage_die "team: unknown argument '$1'"
			agent=$1
			;;
		esac
		shift
	done
	[[ -n $agent ]] || po_usage_die "team $mode: give an agent name"
	for i in "${!PO_TEAM_NAME[@]}"; do
		[[ ${PO_TEAM_NAME[i],,} == "${agent,,}" ]] && name=${PO_TEAM_NAME[i]}
	done
	[[ -n $name ]] || po_die "team $mode: '$agent' is not an agent of the [[team.agent]] roster in $PO_MANIFEST_FILE"
	local f=${PO_MANIFEST[team.inactive_file]:-}
	[[ -n $f ]] || po_die "team $mode: no [team] inactive_file in $PO_MANIFEST_FILE"
	local word=inactive
	[[ $mode == off ]] || word=active
	if ((!commit)); then
		printf 'po team: PLAN — would switch %s %s in %s; nothing changes without --commit\n' "$name" "$mode" "$f"
		return 0
	fi
	command -v python3 >/dev/null 2>&1 || po_die "team $mode: writing $f needs python3"
	local res
	res=$(python3 -I "$PO_LIB/team_switch.py" "$f" "$mode" "$name") || po_die "team $mode: could not write $f"
	printf '%s is %s %s\n' "$name" "$res" "$word"
}

po_cmd_team() {
	local json=0
	case ${1:-} in
	off | on)
		((${#PO_TEAM_NAME[@]} > 0)) || po_die "no [[team.agent]] in $PO_MANIFEST_FILE: the roster is empty"
		po_team_switch "$@"
		return
		;;
	esac
	while (($# > 0)); do
		case $1 in
		--json) json=1 ;;
		*) po_usage_die "team: unknown argument '$1'" ;;
		esac
		shift
	done
	((${#PO_TEAM_NAME[@]} > 0)) || po_die "no [[team.agent]] in $PO_MANIFEST_FILE: the roster is empty"
	# po dispatch reads this feed itself and sets PO_TEAM_NO_OWNER_OK: a project without the column dispatches as before.
	[[ -n ${PO_MANIFEST[layout.owner_column]+x} || -n ${PO_TEAM_NO_OWNER_OK:-} ]] ||
		po_die "team: needs [layout] owner_column in $PO_MANIFEST_FILE: without it no agent owns anything and every agent would show free"
	po_backlog_load

	# The newest event time per agent (the log is in time order).
	local -A last=()
	local file line a t
	if file=$(po_events_file) && [[ -f $file ]]; then
		while IFS= read -r line; do
			[[ $line == '{'*'}' ]] || continue
			a=$(po_event_field "$line" agent)
			t=$(po_event_field "$line" time)
			[[ -n $a && $a != - && -n $t && $t != - ]] && last[${a,,}]=$t
		done <"$file"
	fi

	# Open items per owner, lowest version first.
	local -A doing=() held=() owns=()
	local rec v s own
	while IFS= read -r rec; do
		[[ -n $rec ]] || continue
		v=${rec%%$'\t'*}
		s=${rec#*$'\t'}
		s=${s%%$'\t'*}
		own=$(po_item_owner "$v")
		own=${own,,}
		[[ -n $own ]] || continue
		owns[$own]+="${owns[$own]:+ }$v"
		if [[ $s == "$PO_LIVE_STATUS" ]]; then doing[$own]+="${doing[$own]:+ }$v"; else held[$own]+="${held[$own]:+ }$v"; fi
	done < <(po_open_items)

	# Optional host files: name TAB limit TAB usage.
	local -A lim=() use=()
	local fname fl fu
	fl=${PO_MANIFEST[team.limits_file]:--} fu=${PO_MANIFEST[team.usage_file]:--}
	if [[ $fl != - || $fu != - ]]; then
		command -v python3 >/dev/null 2>&1 || po_die "team: merging limits_file or usage_file needs python3"
		while IFS=$'\t' read -r fname fl fu; do
			lim[${fname,,}]=$fl use[${fname,,}]=$fu
		done < <(python3 -I "$PO_LIB/team_files.py" "$fl" "$fu")
	fi

	local -A off=()
	while IFS= read -r a; do off[$a]=1; done < <(po_team_inactive)

	local now_s i name key age state nowitem free freecol entry list items=() rows=()
	now_s=$(date +%s)
	for i in "${!PO_TEAM_NAME[@]}"; do
		name=${PO_TEAM_NAME[i]} key=${PO_TEAM_NAME[i],,}
		age=-1 state='idle never' nowitem='' free=false
		if [[ -n ${last[$key]:-} ]] && t=$(date -d "${last[$key]}" +%s 2>/dev/null); then
			age=$((now_s - t))
			((age >= 0)) || age=0
			state="idle $(po_team_idle "$age")"
		fi
		if [[ -n ${doing[$key]:-} ]] && ((age >= 0 && age < PO_TEAM_ACTIVE_SECS)); then
			state=WORKING
			nowitem=${doing[$key]%% *}
		elif [[ -z ${owns[$key]:-} ]] || { [[ -z ${doing[$key]:-} ]] && ((age < 0 || age >= PO_TEAM_ACTIVE_SECS)); }; then
			free=true
		fi
		freecol=$free
		[[ -z ${off[$key]:-} ]] || free=false freecol=OFF
		list=''
		for v in ${owns[$key]:-}; do list+="${list:+,}$(po_json_str "$v")"; done
		entry='{"agent":'$(po_json_str "$name")
		[[ -z ${PO_TEAM_MODEL[i]} ]] || entry+=',"model":'$(po_json_str "${PO_TEAM_MODEL[i]}")
		entry+=',"state":'$(po_json_str "$state")
		if [[ -n $nowitem ]]; then entry+=',"now":'$(po_json_str "$nowitem"); else entry+=',"now":null'; fi
		entry+=',"owns":['$list'],"free":'$free
		[[ -z ${off[$key]:-} ]] || entry+=',"inactive":true'
		[[ -z ${lim[$key]:-} ]] || entry+=',"limit_until":'${lim[$key]}
		[[ -z ${use[$key]:-} ]] || entry+=',"usage":'${use[$key]}
		items+=("$entry}")
		rows+=("$name"$'\t'"$state"$'\t'"${nowitem:--}"$'\t'"${owns[$key]:--}"$'\t'"$freecol"$'\t'"${lim[$key]:--}"$'\t'"${use[$key]:--}")
	done

	if ((json)); then
		local sep=''
		printf '['
		for entry in "${items[@]}"; do
			printf '%s\n  %s' "$sep" "$entry"
			sep=,
		done
		printf '\n]\n'
		return 0
	fi
	{
		printf 'AGENT\tSTATE\tNOW\tOWNS\tFREE\tLIMIT\tUSAGE\n'
		printf '%s\n' "${rows[@]}"
	} | column -t -s $'\t'
}
