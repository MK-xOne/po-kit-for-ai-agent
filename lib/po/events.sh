# shellcheck shell=bash
# po-kit: gate events — one JSON object per line in po-events.jsonl, in the
# repository's common git dir (shared by every worktree, and writable by an
# agent that cannot write outside the repository).
#
# po stamp logs every run, pass and fail; po open and po close log one event
# each after a complete --commit. `po events` reads the log back. Logging
# never changes a command's exit status or output: a log that cannot be
# written warns and moves on.
#
# An event, keys in this order:
#   {"time":"2026-10-23T22:30:00Z","kind":"stamp","item":"0.12","project":"po-kit",
#    "result":"pass","agent":"alice","legs":[{"name":"lint","result":"pass"}],
#    "detail":""}
# kind is stamp|open|close; result is pass|fail; item is null when the branch
# is not an item branch; a leg's result is pass, fail or skip (not reached);
# detail says why a stamp failed, else "".

PO_EVENTS_NAME=po-events.jsonl

# po_events_file: the log's absolute path.
po_events_file() {
	local dir
	dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	printf '%s/%s' "$dir" "$PO_EVENTS_NAME"
}

# po_json_str <text>: <text> as a JSON string. Control characters become
# spaces, so an event is always one line.
po_json_str() {
	local s=${1//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//[$'\001'-$'\037\177']/ }
	printf '"%s"' "$s"
}

# po_event_agent: BUZZ_AGENT, else the user.
po_event_agent() {
	printf '%s' "${BUZZ_AGENT:-${USER:-$(id -un 2>/dev/null || echo unknown)}}"
}

# po_event_log <kind> <item|-> <result> <legs-json> <detail>: append one
# event. Never fails; a write that fails warns.
po_event_log() {
	local kind=$1 item=$2 result=$3 legs=$4 detail=$5 file project line itemj=null
	[[ $item == - ]] || itemj=$(po_json_str "$item")
	project=$(basename -- "${PO_MAIN_WT:-$PWD}")
	line=$(printf '{"time":"%s","kind":"%s","item":%s,"project":%s,"result":"%s","agent":%s,"legs":[%s],"detail":%s}' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$itemj" "$(po_json_str "$project")" "$result" \
		"$(po_json_str "$(po_event_agent)")" "$legs" "$(po_json_str "$detail")")
	if ! file=$(po_events_file) || ! { printf '%s\n' "$line" >>"$file"; } 2>/dev/null; then
		printf 'po: warning: could not write the %s event to %s\n' "$kind" "${file:-the git dir}" >&2
	fi
	return 0
}

# po_event_leg <name> <result>: one element of an event's legs array.
po_event_leg() {
	printf '{"name":%s,"result":"%s"}' "$(po_json_str "$1")" "$2"
}

# po_event_field <line> <key>: the top-level string value of <key> in an
# event line ("null" prints as -), unescaped.
po_event_field() {
	local re='[{,]"'$2'":("(([^"\\]|\\.)*)"|null)' v
	[[ $1 =~ $re ]] || return 0
	if [[ ${BASH_REMATCH[1]} == null ]]; then
		printf -- '-'
		return 0
	fi
	v=${BASH_REMATCH[2]}
	v=${v//\\\"/\"}
	printf '%s' "${v//\\\\/\\}"
}

# po_event_legs <line>: "name:result name:result" from the legs array.
po_event_legs() {
	local rest=$1 out='' re='\{"name":"(([^"\\]|\\.)*)","result":"([a-z]+)"\}'
	rest=${rest#*\"legs\":\[}
	while [[ $rest =~ $re ]]; do
		out+="${out:+ }${BASH_REMATCH[1]}:${BASH_REMATCH[3]}"
		rest=${rest#*"${BASH_REMATCH[0]}"}
	done
	printf '%s' "${out:--}"
}

# po_event_local <iso-utc>: the time in the viewer's zone, or the input
# unchanged when date cannot read it.
po_event_local() {
	date -d "$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$1"
}

po_cmd_events() {
	local all=0 json=0
	while (($# > 0)); do
		case $1 in
		--all) all=1 ;;
		--json) json=1 ;;
		*) po_usage_die "events: unknown argument '$1'" ;;
		esac
		shift
	done
	local file lines=() line
	file=$(po_events_file) || po_die "not inside a git repository"
	if [[ -f $file ]]; then
		# Newest first: the log is appended in time order. Lines that are not
		# events (a torn write) are skipped.
		while IFS= read -r line; do
			[[ $line == '{'*'}' ]] && lines+=("$line")
		done < <(awk '{ a[NR] = $0 } END { for (i = NR; i >= 1; i--) print a[i] }' "$file")
	fi
	((all)) || ((${#lines[@]} <= 10)) || lines=("${lines[@]:0:10}")
	if ((json)); then
		((${#lines[@]} == 0)) || printf '%s\n' "${lines[@]}"
		return 0
	fi
	if ((${#lines[@]} == 0)); then
		printf 'po events: none yet (%s)\n' "$file"
		return 0
	fi
	{
		printf 'TIME\tKIND\tITEM\tPROJECT\tRESULT\tAGENT\tLEGS\n'
		for line in "${lines[@]}"; do
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$(po_event_local "$(po_event_field "$line" time)")" \
				"$(po_event_field "$line" kind)" "$(po_event_field "$line" item)" \
				"$(po_event_field "$line" project)" "$(po_event_field "$line" result)" \
				"$(po_event_field "$line" agent)" "$(po_event_legs "$line")"
		done
	} | column -t -s $'\t'
}
