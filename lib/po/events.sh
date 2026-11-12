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
#    "result":"pass","agent":"alice","legs":[{"name":"lint","result":"pass","seconds":3}],
#    "seconds":3,"detail":""}
# kind is stamp|open|close|setup (a `po setup confirm`, its detail "step <n>
# confirmed by <who>"); result is pass|fail; item is null when the branch
# is not an item branch; a leg's result is pass, fail or skip (not reached);
# detail says why a stamp failed, else "". A failed stamp adds two things:
# the failing leg's "tail" (the last lines of its output, redacted, one
# string with \n between lines, after "seconds") and, after detail, "log": the
# absolute path of the run's full output under po-logs/ in the same git dir
# (null when it could not be written).
# A stamp event also carries time taken, whole seconds of wall clock: each
# leg's "seconds" (0 for a leg not reached) and, after legs, the run's own
# "seconds" (prepare plus legs). An event without the keys (an older one, an
# open or a close) has an unknown time, never 0: readers show it as -.
# A passing stamp then adds, after the run's "seconds" and before detail,
# "tests" (the number its gate block prints as `tests N passed`) and "load1"
# (the first field of /proc/loadavg when the run ended; left out when it
# cannot be read). A failed stamp and the other kinds have neither; readers
# show a missing one as -, never 0.

PO_EVENTS_NAME=po-events.jsonl
PO_EVENTS_ARCHIVE_NAME=po-events-archive.jsonl
#
# The live log keeps the last [events] live_days days (default 10). Older
# events move to po-events-archive.jsonl beside it, at append time and by
# `po events --archive-now`. An event is identified by its whole line.

# po_events_file: the log's absolute path.
po_events_file() {
	local dir
	dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	printf '%s/%s' "$dir" "$PO_EVENTS_NAME"
}

# po_events_archive_file: the archive's absolute path.
po_events_archive_file() {
	local dir
	dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	printf '%s/%s' "$dir" "$PO_EVENTS_ARCHIVE_NAME"
}

# po_events_archive_now: move events older than the live window to the
# archive; prints how many moved. Younger events, events whose time is not a
# well-formed UTC stamp and lines that are not events stay live. The archive
# is appended first (skipping lines already in it), then the live log is
# replaced by one rename of a temp file, so a crash loses nothing and a rerun
# adds no duplicate. PO_EVENTS_NOW (epoch seconds) stands in for the clock.
po_events_archive_now() {
	local file arch days now cutoff tmp_live tmp_old n lock
	file=$(po_events_file) || return 1
	[[ -s $file ]] || { printf '0'; return 0; }
	arch=$(po_events_archive_file)
	days=$((10#${PO_MANIFEST[events.live_days]:-10}))
	now=${PO_EVENTS_NOW:-$(date -u +%s)}
	cutoff=$(date -u -d "@$((now - days * 86400))" +%Y-%m-%dT%H:%M:%SZ) || return 1
	lock=$file.lock
	(
		command -v flock >/dev/null 2>&1 && flock 9
		tmp_live=$(mktemp "$file.live.XXXXXX") || exit 1
		tmp_old=$(mktemp "$file.old.XXXXXX") || { rm -f "$tmp_live"; exit 1; }
		awk -v cutoff="$cutoff" -v live="$tmp_live" -v old="$tmp_old" '
			{
				if (match($0, /^\{"time":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z"/) &&
				    substr($0, 10, 20) < cutoff) print > old
				else print > live
			}' "$file" || { rm -f "$tmp_live" "$tmp_old"; exit 1; }
		if [[ ! -s $tmp_old ]]; then
			rm -f "$tmp_live" "$tmp_old"
			printf '0'
			exit 0
		fi
		n=$(wc -l <"$tmp_old")
		if [[ -f $arch ]]; then
			awk 'NR == FNR { seen[$0] = 1; next } !($0 in seen)' "$arch" "$tmp_old" >"$tmp_old.new" && mv -f "$tmp_old.new" "$tmp_old"
		fi
		{ cat -- "$tmp_old" >>"$arch"; } 2>/dev/null || { rm -f "$tmp_live" "$tmp_old"; exit 1; }
		touch -r "$file" "$tmp_live" 2>/dev/null
		mv -f "$tmp_live" "$file" || { rm -f "$tmp_live" "$tmp_old"; exit 1; }
		rm -f "$tmp_old"
		printf '%s' "$((n + 0))"
	) 9>"$lock"
}

# po_json_str <text>: <text> as a JSON string. Newlines and tabs are
# escaped; other control characters become spaces, so an event is always one
# line.
po_json_str() {
	local s=${1//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/\\n}
	s=${s//$'\t'/\\t}
	s=${s//[$'\001'-$'\037\177']/ }
	printf '"%s"' "$s"
}

# po_event_agent: BUZZ_AGENT, else the user.
po_event_agent() {
	printf '%s' "${BUZZ_AGENT:-${USER:-$(id -un 2>/dev/null || echo unknown)}}"
}

# po_event_log <kind> <item|-> <result> <legs-json> <detail> [<log|->]:
# append one event; with a sixth argument it has a "log" key, null for -.
# A non-empty PO_EVENT_SECONDS adds the run's "seconds" key after legs, then
# a non-empty PO_EVENT_TESTS "tests", PO_EVENT_TIER "tier" (fast; a full
# stamp's event has none) and PO_EVENT_LOAD1 "load1".
# Never fails; a write that fails warns.
PO_EVENT_SECONDS='' PO_EVENT_TESTS='' PO_EVENT_LOAD1='' PO_EVENT_TIER=''
po_event_log() {
	local kind=$1 item=$2 result=$3 legs=$4 detail=$5 file project line itemj=null logj='' secj=''
	[[ -z $PO_EVENT_SECONDS ]] || secj=',"seconds":'$PO_EVENT_SECONDS
	[[ -z $PO_EVENT_TESTS ]] || secj+=',"tests":'$PO_EVENT_TESTS
	[[ -z $PO_EVENT_TIER ]] || secj+=',"tier":"'$PO_EVENT_TIER'"'
	[[ -z $PO_EVENT_LOAD1 ]] || secj+=',"load1":'$PO_EVENT_LOAD1
	[[ $item == - ]] || itemj=$(po_json_str "$item")
	if (($# >= 6)); then
		logj=',"log":null'
		[[ $6 == - ]] || logj=',"log":'$(po_json_str "$6")
	fi
	project=$(basename -- "${PO_MAIN_WT:-$PWD}")
	line=$(printf '{"time":"%s","kind":"%s","item":%s,"project":%s,"result":"%s","agent":%s,"legs":[%s]%s,"detail":%s%s}' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$kind" "$itemj" "$(po_json_str "$project")" "$result" \
		"$(po_json_str "$(po_event_agent)")" "$legs" "$secj" "$(po_json_str "$detail")" "$logj")
	if ! file=$(po_events_file) || ! {
		(
			command -v flock >/dev/null 2>&1 && flock 9
			printf '%s\n' "$line" >>"$file"
		) 9>"$file.lock"
	} 2>/dev/null; then
		printf 'po: warning: could not write the %s event to %s\n' "$kind" "${file:-the git dir}" >&2
		return 0
	fi
	# Age out what left the live window; a failure here never fails the command.
	po_events_archive_now >/dev/null 2>&1 || printf 'po: warning: could not archive old events\n' >&2
	return 0
}

# po_event_leg <name> <result> <seconds> [<tail>]: one element of an event's
# legs array; given a tail (even an empty one), it has a "tail" key.
po_event_leg() {
	if (($# >= 4)); then
		printf '{"name":%s,"result":"%s","seconds":%s,"tail":%s}' "$(po_json_str "$1")" "$2" "$3" "$(po_json_str "$4")"
	else
		printf '{"name":%s,"result":"%s","seconds":%s}' "$(po_json_str "$1")" "$2" "$3"
	fi
}

# The JSON string body: escapes, or any character but a quote or backslash.
PO_JSON_BODY='(\\.|[^"\\])*'
PO_JSON_LEG_RE='\{"name":"('$PO_JSON_BODY')","result":"([a-z]+)"(,"seconds":([0-9]+))?(,"tail":"('$PO_JSON_BODY')")?\}'

# po_json_unescape <body>: a JSON string body as written by po_json_str,
# back to its text.
po_json_unescape() {
	local v=${1//\\\"/\"}
	printf '%b' "$v"
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

# po_event_secs <seconds>: whole seconds as 57s, 4m12s or 1h02m03s; - when
# empty (unknown).
po_event_secs() {
	local n=$1
	[[ $n =~ ^[0-9]+$ ]] || { printf -- '-'; return 0; }
	n=$((10#$n))
	if ((n >= 3600)); then
		printf '%dh%02dm%02ds' $((n / 3600)) $((n % 3600 / 60)) $((n % 60))
	elif ((n >= 60)); then
		printf '%dm%02ds' $((n / 60)) $((n % 60))
	else
		printf '%ds' "$n"
	fi
}

# po_event_took <line>: the run's time for the events table: its seconds, and
# the word slow after it when that is over [stamp] slow_after, then fast for a
# fast stamp (v0.182); - when the event has none.
po_event_took() {
	local re='"legs":\[.*\],"seconds":([0-9]+),"(tests|tier|load1|detail)"' s
	[[ $1 =~ $re ]] || { printf -- '-'; return 0; }
	s=$((10#${BASH_REMATCH[1]}))
	po_event_secs "$s"
	((s <= 10#${PO_MANIFEST[stamp.slow_after]:-300})) || printf ' slow'
	[[ $1 != *',"tier":"fast",'* ]] || printf ' fast'
}

# po_event_legs <line>: "name:result name:result" from the legs array; a leg
# with a time reads name:result(4m12s).
po_event_legs() {
	local rest=$1 out=''
	rest=${rest#*\"legs\":\[}
	while [[ $rest =~ $PO_JSON_LEG_RE ]]; do
		out+="${out:+ }${BASH_REMATCH[1]}:${BASH_REMATCH[3]}"
		[[ -z ${BASH_REMATCH[5]} ]] || out+="($(po_event_secs "${BASH_REMATCH[5]}"))"
		rest=${rest#*"${BASH_REMATCH[0]}"}
	done
	printf '%s' "${out:--}"
}

# po_event_tails <line>: for each leg with a tail, a heading naming the leg
# and the log, then the tail's lines indented; nothing when no leg has one.
po_event_tails() {
	local rest=$1 log
	log=$(po_event_field "$1" log)
	rest=${rest#*\"legs\":\[}
	while [[ $rest =~ $PO_JSON_LEG_RE ]]; do
		if [[ -n ${BASH_REMATCH[6]} ]]; then
			printf '\n%s %s %s: leg %s failed; its last lines' \
				"$(po_event_local "$(po_event_field "$1" time)")" "$(po_event_field "$1" project)" \
				"$(po_event_field "$1" item)" "$(po_json_unescape "${BASH_REMATCH[1]}")"
			[[ -z $log || $log == - ]] || printf ' (full output: %s)' "$log"
			printf ':\n'
			po_json_unescape "${BASH_REMATCH[7]}" | sed 's/^/    /'
			printf '\n'
		fi
		rest=${rest#*"${BASH_REMATCH[0]}"}
	done
}

# po_event_local <iso-utc>: the time in the viewer's zone, or the input
# unchanged when date cannot read it.
po_event_local() {
	date -d "$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || printf '%s' "$1"
}

po_cmd_events() {
	local all=0 json=0 archived=0 archive_now=0 trend=0 days=''
	while (($# > 0)); do
		case $1 in
		--all) all=1 ;;
		--json) json=1 ;;
		--archived) archived=1 ;;
		--archive-now) archive_now=1 ;;
		--trend) trend=1 ;;
		--days)
			(($# >= 2)) || po_usage_die "events: --days needs a number"
			days=$2
			shift
			;;
		*) po_usage_die "events: unknown argument '$1'" ;;
		esac
		shift
	done
	local file lines=() line
	file=$(po_events_file) || po_die "not inside a git repository"
	if ((trend)); then
		((!all && !archived && !archive_now)) || po_usage_die "events: --trend combines only with --days and --json"
		[[ -z $days || $days =~ ^[1-9][0-9]{0,3}$ ]] || po_usage_die "events: --days takes a whole number of days, 1 or more"
		po_events_trend "${days:-14}" "$json"
		return 0
	fi
	[[ -z $days ]] || po_usage_die "events: --days needs --trend"
	if ((archive_now)); then
		((!all && !json && !archived)) || po_usage_die "events: --archive-now takes no other option"
		local moved
		moved=$(po_events_archive_now) || po_die "could not archive the old events"
		printf 'po events: archived %s events to %s\n' "$moved" "$(po_events_archive_file)"
		return 0
	fi
	((!archived)) || file=$(po_events_archive_file)
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
		if ((archived)); then
			printf 'po events: none archived (%s)\n' "$file"
			return 0
		fi
		printf 'po events: none yet (%s)\n' "$file"
		return 0
	fi
	{
		printf 'TIME\tKIND\tITEM\tPROJECT\tRESULT\tAGENT\tTOOK\tLEGS\n'
		for line in "${lines[@]}"; do
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$(po_event_local "$(po_event_field "$line" time)")" \
				"$(po_event_field "$line" kind)" "$(po_event_field "$line" item)" \
				"$(po_event_field "$line" project)" "$(po_event_field "$line" result)" \
				"$(po_event_field "$line" agent)" "$(po_event_took "$line")" "$(po_event_legs "$line")"
		done
	} | column -t -s $'\t'
	# Under the table, newest first: what each failed stamp shown printed last.
	for line in "${lines[@]}"; do
		[[ $line == *'"tail":"'* ]] && po_event_tails "$line"
	done
	return 0
}

# po_events_trend_raw <file>...: time (UTC), tests, load1 and the test leg's
# seconds of each PASS stamp in the files (- when absent), tab-separated; a
# line in more than one file, or twice, counts once.
po_events_trend_raw() {
	local f
	for f; do [[ -f $f ]] && cat -- "$f"; done |
		awk '
		function val(   m) { m = substr($0, RSTART, RLENGTH); sub(/.*:/, "", m); sub(/[,}]$/, "", m); return m }
		seen[$0]++ { next }
		!/^\{"time":"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z","kind":"stamp",/ { next }
		index($0, ",\"result\":\"pass\",\"agent\":") == 0 { next }
		index($0, ",\"tier\":\"fast\",") { next }
		{
			t = "-"; l = "-"; s = "-"
			if (match($0, /[0-9],"tests":[0-9]+[,}]/)) t = val()
			if (match($0, /[0-9],"load1":[0-9]+(\.[0-9]+)?[,}]/)) l = val()
			if (match($0, /\{"name":"test","result":"pass","seconds":[0-9]+[,}]/)) s = val()
			print substr($0, 10, 20) "\t" t "\t" l "\t" s
		}'
}

# po_events_trend <days> <json 0|1>: PASS stamps of the live log and the
# archive, one row per local day of the last <days> days, newest first: how
# many, the highest test count, the median test leg, that median per test (in
# ms, against the day's median count) and the median load; a value no stamp
# of the day has is -. Under the table, the change from the oldest to the
# newest day with a test count. An event in both files counts once.
po_events_trend() {
	local days=$1 json=$2 now today first live arch rows kind
	now=${PO_EVENTS_NOW:-$(date -u +%s)}
	today=$(date -d "@$now" +%Y-%m-%d) || po_die "could not read the clock"
	first=$(date -d "$today -$((days - 1)) days" +%Y-%m-%d) || po_die "could not count back $days days"
	live=$(po_events_file) || po_die "not inside a git repository"
	arch=$(po_events_archive_file)
	rows=$(
		paste <(po_events_trend_raw "$arch" "$live" | cut -f1 | date -f - +%Y-%m-%d) \
			<(po_events_trend_raw "$arch" "$live" | cut -f2-) |
			awk -F'\t' -v first="$first" -v today="$today" '
			function rnd(x) { return x < 0 ? -int(-x + 0.5) : int(x + 0.5) }
			# median of the space-separated numbers in s, or "" for none
			function median(s,   a, n, i, j, v) {
				n = split(s, a, " ")
				if (n == 0) return ""
				for (i = 2; i <= n; i++) {
					v = a[i] + 0
					for (j = i - 1; j >= 1 && a[j] + 0 > v; j--) a[j + 1] = a[j]
					a[j + 1] = v
				}
				return n % 2 ? a[(n + 1) / 2] + 0 : (a[n / 2] + a[n / 2 + 1]) / 2
			}
			$1 < first || $1 > today { next }
			{
				n[$1]++
				if ($2 != "-") { ts[$1] = ts[$1] " " $2; if (!($1 in hi) || $2 + 0 > hi[$1]) hi[$1] = $2 + 0 }
				if ($3 != "-") ld[$1] = ld[$1] " " $3
				if ($4 != "-") lg[$1] = lg[$1] " " $4
			}
			END {
				for (d in n) days[++nd] = d
				for (i = 2; i <= nd; i++) { v = days[i]; for (j = i - 1; j >= 1 && days[j] < v; j--) days[j + 1] = days[j]; days[j + 1] = v }
				for (i = 1; i <= nd; i++) {
					d = days[i]
					mt = median(ts[d]); ml = median(lg[d]); mo = median(ld[d])
					T = (d in hi) ? hi[d] : "-"
					L = ml == "" ? "-" : rnd(ml)
					P = (mt == "" || ml == "" || mt == 0) ? "-" : rnd(ml * 1000 / mt)
					O = mo == "" ? "-" : sprintf("%.2f", mo)
					print "row\t" d "\t" n[d] "\t" T "\t" L "\t" P "\t" O
					if (T != "-") { if (!newest) { newest = d; nT = T; nL = L; nP = P } oldest = d; oT = T; oL = L; oP = P }
				}
				if (nd == 0) exit
				if (oldest == newest) { print "change\tchange: - (fewer than two days with a TESTS value)"; exit }
				out = sprintf("change since %s: tests %+d (%s)", oldest, nT - oT, pct(nT, oT))
				out = out ", test leg " ((oL == "-" || nL == "-") ? "-" : sprintf("%+d s (%s)", nL - oL, pct(nL, oL)))
				out = out ", per test " ((oP == "-" || nP == "-") ? "-" : sprintf("%+d ms", nP - oP))
				print "change\t" out
			}
			function pct(a, b) { return b == 0 ? "-" : sprintf("%+d%%", rnd((a - b) * 100 / b)) }'
	)
	if ((json)); then
		local sep='' d c t l p o
		printf '['
		while IFS=$'\t' read -r kind d c t l p o; do
			[[ $kind == row ]] || continue
			[[ $t == - ]] && t=null
			[[ $l == - ]] && l=null
			[[ $p == - ]] && p=null
			[[ $o == - ]] && o=null
			printf '%s{"day":"%s","stamps":%s,"tests":%s,"test_leg":%s,"per_test_ms":%s,"load1":%s}' "$sep" "$d" "$c" "$t" "$l" "$p" "$o"
			sep=,
		done <<<"$rows"
		printf ']\n'
		return 0
	fi
	if [[ $rows != *row* ]]; then
		printf 'no stamps in the last %s days\n' "$days"
		return 0
	fi
	{
		printf 'DAY\tSTAMPS\tTESTS\tTEST-LEG\tPER-TEST\tLOAD\n'
		while IFS=$'\t' read -r kind d c t l p o; do
			[[ $kind == row ]] || continue
			[[ $p == - ]] || p="$p ms"
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$d" "$c" "$t" "$(po_event_secs "$l")" "$p" "$o"
		done <<<"$rows"
	} | column -t -s $'\t'
	sed -n 's/^change\t//p' <<<"$rows"
}
