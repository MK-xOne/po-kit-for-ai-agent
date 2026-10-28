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

po_cmd_team() {
	local json=0
	while (($# > 0)); do
		case $1 in
		--json) json=1 ;;
		*) po_usage_die "team: unknown argument '$1'" ;;
		esac
		shift
	done
	((${#PO_TEAM_NAME[@]} > 0)) || po_die "no [[team.agent]] in $PO_MANIFEST_FILE: the roster is empty"
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

	local now_s i name key age state nowitem free entry list items=() rows=()
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
		list=''
		for v in ${owns[$key]:-}; do list+="${list:+,}$(po_json_str "$v")"; done
		entry='{"agent":'$(po_json_str "$name")
		[[ -z ${PO_TEAM_MODEL[i]} ]] || entry+=',"model":'$(po_json_str "${PO_TEAM_MODEL[i]}")
		entry+=',"state":'$(po_json_str "$state")
		if [[ -n $nowitem ]]; then entry+=',"now":'$(po_json_str "$nowitem"); else entry+=',"now":null'; fi
		entry+=',"owns":['$list'],"free":'$free
		[[ -z ${lim[$key]:-} ]] || entry+=',"limit_until":'${lim[$key]}
		[[ -z ${use[$key]:-} ]] || entry+=',"usage":'${use[$key]}
		items+=("$entry}")
		rows+=("$name"$'\t'"$state"$'\t'"${nowitem:--}"$'\t'"${owns[$key]:--}"$'\t'"$free"$'\t'"${lim[$key]:--}"$'\t'"${use[$key]:--}")
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
