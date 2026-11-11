# shellcheck shell=bash
# po-kit: po stamp — run the gate in the current worktree and write the
# evidence block from what actually happened.
#
# The block is all or nothing: every leg must pass, the test count must be
# read and agree with the gate's own, and the worktree must be the same
# after the gate as before it. Otherwise nothing is written and the exit is
# 4 with the reason named. The only file stamp writes is gate-<n>.txt at the
# root of the worktree it runs in, with <n> one past the highest already
# there; an existing file is never overwritten.
#
# A failed run keeps its evidence outside the worktree: the event names the
# failing leg with the last PO_STAMP_TAIL lines of its output, and the full
# output of the run, every command so far, goes to a log file under
# po-logs/ in the common git dir. Both, and the event's detail, are
# redacted (po_redact) first. po never prunes po-logs/.
#
# Optional [stamp] prepare lines (formatters: `cargo fmt`, `ruff format`) run
# first, in order, before the state is taken, so what they change is what
# the gate tests and a format-only failure cannot happen. They are one leg,
# prepare, ahead of the gate's in the event; a failing line fails the stamp
# like a gate leg, and the block names each line that ran.

# Stamp files at a worktree root; they are not part of the state stamped.
PO_STAMP_NAME_RE='^gate-([1-9][0-9]*)\.txt$'

# What the event log needs from the run in progress: the item (the version the
# branch names, or - for another branch), the gate's leg names and each leg's
# result so far (skip until it runs).
PO_STAMP_ITEM=-
PO_STAMP_NAMES=()
PO_STAMP_RES=()
# Wall-clock seconds: the run's start, and each leg's time (0 until it runs).
PO_STAMP_START=0
PO_STAMP_SECS=()
# The run's captured output: a private temporary directory holding out-<i>
# for leg i (the prepare leg, when there is one, is leg 0) and out-count for
# test_count_cmd, and the list of what ran, in order, as
# "<file> <exit> <label>" lines in ran. Empty before the gate.
PO_STAMP_TMP=''
PO_STAMP_TAIL=40
# Longest line kept in a tail; a longer one is cut and ends in "...".
PO_STAMP_TAIL_WIDTH=400

# po_redact: stdin to stdout with secrets replaced by [REDACTED]: the value
# of every environment variable whose name says it is a secret (TOKEN,
# SECRET, PASSWORD, PASSWD, API_KEY, PRIVATE_KEY, ACCESS_KEY, CREDENTIAL,
# AUTH, NSEC), is 8 characters or more and is not a path; the value after a
# key of that kind written key=value or key: value; the value of an
# Authorization header, up to a quote or semicolon; a Bearer or Basic
# credential; the user and password of a URL; tokens of well-known shapes
# (ghp_..., github_pat_..., glpat-..., sk-..., xox?-..., AKIA..., nsec1...);
# and every line of a PEM private key block. Terminal colour codes and
# carriage-return redraws are dropped. Best effort: a secret of no known
# shape, under a name that does not say so, passes through.
po_redact() {
	LC_ALL=C awk '
	# Replace, left to right, every match of pre val (lowercase EREs, matched
	# on the lowercased line) in s with pre kept and val [REDACTED], when val
	# is at least min characters long.
	function sub_rule(s, pre, val, min,    out, rest, at, len, plen) {
		out = ""; rest = s
		while (match(tolower(rest), pre val)) {
			at = RSTART; len = RLENGTH
			plen = 0
			if (match(tolower(substr(rest, at, len)), "^" pre)) plen = RLENGTH
			out = out substr(rest, 1, at - 1)
			if (len - plen >= min) out = out substr(rest, at, plen) "[REDACTED]"
			else out = out substr(rest, at, len)
			rest = substr(rest, at + len)
			if (len == 0) break
		}
		return out rest
	}
	function sub_lit(s, v,    out, i) {
		out = ""
		while ((i = index(s, v)) > 0) { out = out substr(s, 1, i - 1) "[REDACTED]"; s = substr(s, i + length(v)) }
		return out s
	}
	BEGIN {
		n = 0
		for (k in ENVIRON) {
			u = toupper(k)
			# A path (SSH_AUTH_SOCK, XAUTHORITY) names a secret; it is not one.
			if (u ~ /(TOKEN|SECRET|PASSWORD|PASSWD|API_?KEY|PRIVATE_?KEY|ACCESS_?KEY|CREDENTIAL|AUTH|NSEC)/ && length(ENVIRON[k]) >= 8 && ENVIRON[k] !~ /^\//)
				vals[++n] = ENVIRON[k]
		}
		# Longest first, so a secret that contains another is replaced whole.
		for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
			if (length(vals[j]) > length(vals[i])) { t = vals[i]; vals[i] = vals[j]; vals[j] = t }
		B = "(^|[^a-z0-9_-])"
		Q = "[\"\047]?"
		KEY = "[a-z0-9_.-]*(password|passwd|secret|token|api[_-]?key|private[_-]?key|access[_-]?key|credential|nsec)[a-z0-9_.-]*" Q "[ \t]*[:=][ \t]*" Q
	}
	{
		s = $0
		sub(/\r+$/, "", s)
		gsub(/\033\[[0-9;?]*[ -\/]*[@-~]/, "", s)
		while ((j = index(s, "\r")) > 0) s = substr(s, j + 1)
		if (inkey) {
			if (s ~ /-----END [A-Z0-9 ]*PRIVATE KEY-----/) inkey = 0
			print "[REDACTED]"; next
		}
		if (s ~ /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----/) {
			if (s !~ /-----END [A-Z0-9 ]*PRIVATE KEY-----/) inkey = 1
			print "[REDACTED]"; next
		}
		for (i = 1; i <= n; i++) s = sub_lit(s, vals[i])
		s = sub_rule(s, "authorization[\"\047]?[ \t]*[:=][ \t]*", "[^\"\047;]+", 1)
		s = sub_rule(s, B "(bearer|basic)[ \t]+", "[a-z0-9._~+/=-]+", 8)
		gsub(/:\/\/[^\/@ \t:]*:[^\/@ \t]+@/, "://[REDACTED]@", s)
		s = sub_rule(s, KEY, "[^] \t\"\047,;)}]+", 1)
		s = sub_rule(s, B, "(ghp|gho|ghu|ghs|ghr)_[a-z0-9]+", 20)
		s = sub_rule(s, B, "github_pat_[a-z0-9_]+", 20)
		s = sub_rule(s, B, "glpat-[a-z0-9_-]+", 20)
		s = sub_rule(s, B, "sk-[a-z0-9_-]+", 20)
		s = sub_rule(s, B, "xox[abeprs]-[a-z0-9-]+", 15)
		s = sub_rule(s, B, "akia[a-z0-9]+", 20)
		s = sub_rule(s, B, "nsec1[a-z0-9]+", 30)
		print s
	}'
}

# po_stamp_tail <file>: the last PO_STAMP_TAIL lines of <file>, redacted,
# each cut at PO_STAMP_TAIL_WIDTH characters.
po_stamp_tail() {
	tail -n "$PO_STAMP_TAIL" -- "$1" 2>/dev/null | po_redact |
		LC_ALL=C awk -v w="$PO_STAMP_TAIL_WIDTH" '{ if (length($0) > w) $0 = substr($0, 1, w) "..."; print }'
}

# po_stamp_seconds: whole seconds since the run began, into PO_EVENT_SECONDS
# for the event about to be logged.
po_stamp_seconds() {
	# shellcheck disable=SC2034 # read by po_event_log
	PO_EVENT_SECONDS=$(($(date +%s) - PO_STAMP_START))
}

# po_stamp_load1: the machine's one-minute load average (the first field of
# /proc/loadavg) as a JSON number; nothing when it cannot be read.
po_stamp_load1() {
	local l rest
	read -r l rest </proc/loadavg 2>/dev/null || return 0
	[[ $l =~ ^[0-9]+(\.[0-9]+)?$ ]] && printf '%s' "$l"
	return 0
}

# po_stamp_legs_json [<failing leg index>]: the legs array body for the event
# log; the failing leg carries "tail", its output's last lines.
po_stamp_legs_json() {
	local i out='' failing=${1:--1} tail
	for i in "${!PO_STAMP_NAMES[@]}"; do
		tail=''
		if ((i == failing)) && [[ -n $PO_STAMP_TMP ]]; then
			tail=$(po_stamp_tail "$PO_STAMP_TMP/out-$i")
		fi
		if ((i == failing)); then
			out+="${out:+,}$(po_event_leg "${PO_STAMP_NAMES[i]}" "${PO_STAMP_RES[i]}" "${PO_STAMP_SECS[i]:-0}" "$tail")"
		else
			out+="${out:+,}$(po_event_leg "${PO_STAMP_NAMES[i]}" "${PO_STAMP_RES[i]}" "${PO_STAMP_SECS[i]:-0}")"
		fi
	done
	printf '%s' "$out"
}

# po_stamp_write_log <reason>: the full output of the run so far, redacted,
# into a new file under po-logs/ in the common git dir; its path on stdout.
# Prints nothing when nothing ran or the file cannot be written.
po_stamp_write_log() {
	local dir file f code label item=${PO_STAMP_ITEM//[^A-Za-z0-9._-]/_}
	[[ -n $PO_STAMP_TMP && -s $PO_STAMP_TMP/ran ]] || return 0
	dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
	dir=$dir/po-logs
	if ! mkdir -p -- "$dir" 2>/dev/null; then
		printf 'po: warning: could not write the stamp log to %s\n' "$dir" >&2
		return 0
	fi
	[[ $item == - ]] && item=none
	file=$dir/stamp-$(date -u +%Y%m%dT%H%M%SZ)-$item-$$.log
	if ! {
		printf 'po stamp: FAIL: %s\n' "$1"
		while read -r f code label; do
			printf '\n== %s (exit %s)\n' "$label" "$code"
			cat -- "$PO_STAMP_TMP/$f"
		done <"$PO_STAMP_TMP/ran"
	} 2>/dev/null | po_redact >"$file" 2>/dev/null; then
		rm -f -- "$file"
		printf 'po: warning: could not write the stamp log to %s\n' "$dir" >&2
		return 0
	fi
	printf '%s' "$file"
}

po_stamp_cleanup() {
	[[ -z $PO_STAMP_TMP ]] || rm -rf -- "$PO_STAMP_TMP"
	PO_STAMP_TMP=''
}

# po_stamp_fail <reason>: log the failed run (the failing leg's tail and the
# full log), say why and exit 4. PO_STAMP_FAILING is the index of the leg
# that failed, or -1 when the failure is not a leg's.
PO_STAMP_FAILING=-1
po_stamp_fail() {
	local log detail
	log=$(po_stamp_write_log "$*")
	# The reason names the leg's command, which may hold a secret.
	detail=$(printf '%s\n' "$*" | po_redact)
	po_stamp_seconds
	po_event_log stamp "$PO_STAMP_ITEM" fail "$(po_stamp_legs_json "$PO_STAMP_FAILING")" "$detail" "${log:--}"
	po_stamp_cleanup
	printf 'po stamp: FAIL: %s\n' "$*" >&2
	[[ -z $log ]] || printf 'po stamp: the full output is in %s\n' "$log" >&2
	printf 'po stamp: no evidence written\n' >&2
	printf "memory: file a proposal or record 'nothing new learned' with the close body\n" >&2
	exit 4
}

# po_stamp_porcelain <wt>: `git status --porcelain` lines, minus stamp files.
po_stamp_porcelain() {
	git -C "$1" --no-optional-locks status --porcelain --untracked-files=all |
		grep -vE '^\?\? gate-[1-9][0-9]*\.txt$' || true
}

# po_stamp_state <wt>: one hash over HEAD, the status lines, every change
# to tracked files and the content of every untracked file. Two equal
# hashes mean the gate saw one unchanging tree.
po_stamp_state() {
	local wt=$1 f
	{
		git -C "$wt" rev-parse HEAD
		po_stamp_porcelain "$wt"
		git -C "$wt" --no-optional-locks diff --no-ext-diff --no-textconv --binary HEAD
		while IFS= read -r -d '' f; do
			[[ ${f##*/} == "$f" && $f =~ $PO_STAMP_NAME_RE ]] && continue
			printf '%s\0' "$f"
			if [[ -L $wt/$f ]]; then
				readlink "$wt/$f"
			elif [[ -f $wt/$f ]]; then
				git -C "$wt" hash-object --no-filters -- "$f"
			fi
		done < <(git -C "$wt" ls-files --others --exclude-standard -z)
	} | git hash-object --stdin
}

# pytest's final line, with or without the `=` rule: "223 passed in 1.23s",
# "== 3 passed, 1 skipped in 0.5s ==", "no tests ran in 0.01s", and the
# "(0:01:01)" a long run appends to the time.
PO_PYTEST_ITEM='[0-9]+ (subtests )?(passed|failed|skipped|deselected|xfailed|xpassed|warnings?|errors?|rerun)'
PO_PYTEST_RE='^(=+ )?(no tests ran|'$PO_PYTEST_ITEM'(, '$PO_PYTEST_ITEM')*) in [0-9.]+s( \([0-9:]+\))?( =+)?$'

# Whether commands run in a transient user scope of their own: empty until
# the first run decides (1 or 0).
PO_STAMP_SCOPE=''

# po_stamp_scope_init: decide, once, whether to scope: not when
# PO_STAMP_NO_SCOPE=1 or [gate] scope = false, and not when systemd-run is
# absent (said once) or cannot start a user scope here (quietly).
po_stamp_scope_init() {
	[[ -z $PO_STAMP_SCOPE ]] || return 0
	PO_STAMP_SCOPE=0
	[[ ${PO_STAMP_NO_SCOPE:-} != 1 && ${PO_MANIFEST[gate.scope]:-true} != false ]] || return 0
	if ! command -v systemd-run >/dev/null 2>&1 || ! command -v systemctl >/dev/null 2>&1; then
		printf 'po stamp: warning: systemd-run not found; commands run without a scope, so processes they leave behind are not detected\n' >&2
		return 0
	fi
	systemd-run --user --scope --quiet "--unit=po-stamp-probe-$$-$(date +%s%N)" true >/dev/null 2>&1 &&
		PO_STAMP_SCOPE=1
	return 0
}

# po_stamp_live_pids <scope unit>: the unit's live (not zombie) process ids
# on stdout; nothing when the scope is gone.
po_stamp_live_pids() {
	local cg pid st
	cg=$(systemctl --user show -p ControlGroup --value "$1.scope" 2>/dev/null) || return 0
	[[ -n $cg && -r /sys/fs/cgroup$cg/cgroup.procs ]] || return 0
	while read -r pid; do
		st=$(LC_ALL=C sed -n 's/^State:[[:space:]]*\(.\).*/\1/p' "/proc/$pid/status" 2>/dev/null) || continue
		[[ -z $st || $st == Z ]] || printf '%s\n' "$pid"
	done <"/sys/fs/cgroup$cg/cgroup.procs"
}

# po_stamp_sweep <scope unit>: PO_RUN_LEFT is the number of processes still
# alive in the scope, PO_RUN_LEFT_COMM their names (the first 10), then the
# scope is stopped; a child that ignores SIGTERM is killed after 2 seconds.
po_stamp_sweep() {
	local pid i comm
	local -a pids=() comms=()
	PO_RUN_LEFT=0 PO_RUN_LEFT_COMM=''
	mapfile -t pids < <(po_stamp_live_pids "$1")
	((${#pids[@]} > 0)) || return 0
	PO_RUN_LEFT=${#pids[@]}
	for pid in "${pids[@]:0:10}"; do
		comm=$(<"/proc/$pid/comm") 2>/dev/null || comm=$pid
		comms+=("$comm")
	done
	PO_RUN_LEFT_COMM=$(
		IFS=,
		printf '%s' "${comms[*]}"
	)
	PO_RUN_LEFT_COMM=${PO_RUN_LEFT_COMM//,/, }
	systemctl --user stop --no-block "$1.scope" >/dev/null 2>&1 || true
	for i in $(seq 20); do
		[[ -z $(po_stamp_live_pids "$1") ]] && return 0
		sleep 0.1
	done
	systemctl --user kill --signal=SIGKILL "$1.scope" >/dev/null 2>&1 || true
	for i in $(seq 20); do
		[[ -z $(po_stamp_live_pids "$1") ]] && return 0
		sleep 0.1
	done
	return 0
}

# po_stamp_left <leg label> <leg index or -1>: fail the stamp when the last
# run left processes behind. Called once the run is recorded.
po_stamp_left() {
	((PO_RUN_LEFT == 0)) && return 0
	PO_STAMP_FAILING=$2
	po_stamp_fail "$PO_RUN_LEFT process(es) left behind by $1: $PO_RUN_LEFT_COMM"
}

# po_stamp_run <dir> <command> [<capture file> <label>]: run <command> with
# sh in <dir>, its output going to stderr as it happens, and, given a capture
# file, to that file too, recorded with <label> in the run's list. Sets
# PO_RUN_CODE to its exit status and PO_RUN_RESULTS to the summary lines it
# printed: libtest's ("test result: ...") or, with [gate] test_format =
# "pytest", pytest's final lines. The runner's own sentinel lines are kept
# apart: PO_RUN_ENDED is the number of "RUN-END ..." lines the output had and
# PO_RUN_ABORTED the number of "RUN-ABORTED" lines (a runner that finishes
# prints the first; one that dies any other way prints the second).
#
# The output is read until the command itself exits, then for [gate]
# drain_secs more (default 5): a process the command left behind that holds
# the output open cannot keep the stamp waiting. With a scope (see
# po_stamp_scope_init) the command runs in its own transient user scope;
# once it has exited, what is still alive there is counted into PO_RUN_LEFT
# (names in PO_RUN_LEFT_COMM) and the scope is stopped.
po_stamp_run() {
	local out pytest=0 cap=/dev/null tmp unit='' drain
	[[ ${PO_MANIFEST[gate.test_format]:-libtest} != pytest ]] || pytest=1
	[[ -z ${3:-} || -z $PO_STAMP_TMP ]] || cap=$PO_STAMP_TMP/$3
	drain=${PO_MANIFEST[gate.drain_secs]:-5}
	po_stamp_scope_init
	local -a runner=(sh -c "$2")
	if ((PO_STAMP_SCOPE)); then
		unit=po-stamp-$$-$(date +%s%N)
		runner=(systemd-run --user --scope --quiet "--unit=$unit" sh -c "$2")
	fi
	tmp=$(mktemp -d "${TMPDIR:-/tmp}/po-run.XXXXXX") || po_die "could not make a temporary directory"
	mkfifo "$tmp/pipe" || po_die "could not make a pipe in $tmp"
	# The command runs in the background with its output on a fifo; its
	# status lands in $tmp/code. Command substitution does not inherit
	# errexit. Lines are copied to stderr through the inherited descriptor:
	# reopening it (tee /dev/stderr) would truncate a log file stderr points at.
	out=$(
		{
			(cd "$1" && exec "${runner[@]}") </dev/null >"$tmp/pipe" 2>&1
			echo $? >"$tmp/code"
		} &
		cmdpid=$!
		exec 4<"$tmp/pipe"
		emit() {
			printf '%s\n' "$1" >&2
			printf '%s\n' "$1" >&3
			if [[ $1 == 'RUN-END '* ]]; then
				printf '\001end\n'
			elif [[ $1 == RUN-ABORTED* ]]; then
				printf '\001aborted\n'
			elif ((pytest)); then
				if [[ $1 =~ $PO_PYTEST_RE ]]; then printf '%s\n' "$1"; fi
			elif [[ $1 == 'test result: '* ]]; then
				printf '%s\n' "$1"
			fi
		}
		{
			buf='' deadline=0
			while :; do
				line=''
				if IFS= read -r -t 0.2 -u 4 line; then
					emit "$buf$line"
					buf=''
				else
					rc=$?
					buf+=$line
					((rc > 128)) || break
				fi
				if [[ -e $tmp/code ]]; then
					now=$(date +%s%N)
					((deadline)) || deadline=$((now + drain * 1000000000))
					((now < deadline)) || break
				fi
			done
			# A last line without a newline is still output.
			if [[ -n $buf ]]; then emit "$buf"; fi
		} 3>"$cap"
		wait "$cmdpid" 2>/dev/null
		code=$(<"$tmp/code") 2>/dev/null
		printf 'po-stamp-exit %s\n' "${code:-1}"
	)
	rm -rf -- "$tmp"
	PO_RUN_CODE=${out##*po-stamp-exit }
	PO_RUN_RESULTS=${out%po-stamp-exit *}
	PO_RUN_RESULTS=${PO_RUN_RESULTS%$'\n'}
	PO_RUN_ENDED=0 PO_RUN_ABORTED=0
	if [[ $PO_RUN_RESULTS == *$'\001'* ]]; then
		local kept='' rl
		while IFS= read -r rl; do
			case $rl in
			$'\001end') PO_RUN_ENDED=$((PO_RUN_ENDED + 1)) ;;
			$'\001aborted') PO_RUN_ABORTED=$((PO_RUN_ABORTED + 1)) ;;
			*) kept+=${kept:+$'\n'}$rl ;;
			esac
		done <<<"$PO_RUN_RESULTS"
		PO_RUN_RESULTS=$kept
	fi
	PO_RUN_LEFT=0 PO_RUN_LEFT_COMM=''
	[[ -z $unit ]] || po_stamp_sweep "$unit"
	if [[ $cap != /dev/null ]]; then
		printf '%s %s %s\n' "$3" "$PO_RUN_CODE" "$4" >>"$PO_STAMP_TMP/ran"
	fi
}

# po_stamp_sum <results> <what>: the sum of "N passed" over libtest summary
# lines into PO_SUM and their number into PO_SUM_LINES; any summary that is
# not ok fails the stamp.
po_stamp_sum() {
	local line
	PO_SUM=0 PO_SUM_LINES=0
	while IFS= read -r line; do
		[[ -n $line ]] || continue
		[[ $line =~ ^test\ result:\ ok\.\ ([0-9]+)\ passed\; ]] ||
			po_stamp_fail "$2 printed a summary that is not ok: $line"
		PO_SUM=$((PO_SUM + 10#${BASH_REMATCH[1]}))
		PO_SUM_LINES=$((PO_SUM_LINES + 1))
	done <<<"$1"
}

# po_stamp_sum_pytest <results> <what>: the `N passed` of the last pytest
# summary line into PO_SUM, and PO_SUM_LINES 1, or 0 when there is none.
# A summary naming failures or errors, or no passed tests, fails the stamp.
po_stamp_sum_pytest() {
	local line=''
	PO_SUM=0 PO_SUM_LINES=0
	[[ -z $1 ]] || line=${1##*$'\n'}
	[[ -n $line ]] || return 0
	[[ $line =~ (^|[^a-z])(failed|errors?) ]] && po_stamp_fail "$2 printed a pytest summary that is not ok: $line"
	[[ $line =~ (^|[^a-z])([0-9]+)\ passed ]] ||
		po_stamp_fail "$2 printed a pytest summary with no passed tests: $line"
	PO_SUM=$((10#${BASH_REMATCH[2]}))
	PO_SUM_LINES=1
}

# po_stamp_hunk_lines <+|->: the added (+) or removed (-) lines of the diff
# on stdin, without their marker; file headers are not hunk lines.
po_stamp_hunk_lines() {
	awk -v m="$1" '
		/^diff --git / { hunk = 0; next }
		/^@@/ { hunk = 1; next }
		hunk && substr($0, 1, 1) == m { print substr($0, 2) }'
}

# po_stamp_test_counts <wt> <merge-base> <head> <main>: the block's line
# "tests vs merge-base(<main>): +A -R", A and R the lines the diff adds and
# removes in [stamp] test_files that match test_def (a rewritten definition
# counts in both), then the flag line when the same diff changes a file that
# is neither a test file nor docs and removes no definition. Information only.
po_stamp_test_counts() {
	local wt=$1 mb=$2 head=$3 main=$4 def=${PO_MANIFEST[stamp.test_def]} p diff a r code
	local -a tf=() notest=()
	while IFS= read -r p; do
		[[ -z ${p//[[:blank:]]/} ]] || tf+=("$p") notest+=(":(exclude)$p")
	done <<<"${PO_MANIFEST[stamp.test_files]}"
	# -U0: no context lines; a hunk's content lines are those after its @@.
	# The definitions are matched by grep -E, as the manifest checked them.
	diff=$(git -C "$wt" diff --no-color --no-ext-diff -U0 "$mb" "$head" -- "${tf[@]}") ||
		po_die "could not diff $mb..$head for [stamp] test_files"
	a=$(po_stamp_hunk_lines + <<<"$diff" | grep -cE -- "$def") || true
	r=$(po_stamp_hunk_lines - <<<"$diff" | grep -cE -- "$def") || true
	printf 'tests vs merge-base(%s): +%s -%s\n' "$main" "$a" "$r"
	((r == 0)) || return 0
	code=$(git -C "$wt" diff --name-only --no-ext-diff "$mb" "$head" -- . "${notest[@]}" \
		':(exclude)*.md' ':(exclude)docs/' ':(exclude)CHANGELOG.md') ||
		po_die "could not diff $mb..$head for the code-change flag"
	[[ -z $code ]] ||
		printf 'flag: code changed, no test removed or rewritten (PO: check for pins on replaced behaviour)\n'
}

po_cmd_stamp() {
	local bin='' wt=$PO_INVOKE_WT
	while (($# > 0)); do
		case $1 in
		--bin)
			(($# >= 2)) || po_usage_die "--bin needs a path"
			bin=$2
			shift 2
			;;
		*) po_usage_die "stamp: unknown argument '$1'" ;;
		esac
	done

	# The gate: [gate.legs] in order, or [gate] command as one leg.
	local -a names=() cmds=()
	local name i
	if ((${#PO_GATE_LEGS[@]} > 0)); then
		for name in "${PO_GATE_LEGS[@]}"; do
			names+=("$name")
			cmds+=("${PO_MANIFEST[gate.legs.$name]}")
		done
	elif [[ -n ${PO_MANIFEST[gate.command]+x} ]]; then
		names=(gate)
		cmds=("${PO_MANIFEST[gate.command]}")
	else
		po_die "$PO_MANIFEST_FILE: no gate: set [gate] command or [gate.legs]"
	fi
	local count_cmd sumfn=po_stamp_sum summary="'test result:' line" test_leg=-1
	# A leg named test is the suite: its saved output is the count's source,
	# so the suite runs once and test_count_cmd is only a filter over that
	# output. With no test leg, test_count_cmd is the (required) counting run.
	for i in "${!names[@]}"; do
		[[ ${names[i]} == test ]] && test_leg=$i
	done
	if ((test_leg >= 0)); then
		count_cmd=${PO_MANIFEST[gate.test_count_cmd]:-}
	else
		count_cmd=$(po_get gate.test_count_cmd)
	fi
	if [[ ${PO_MANIFEST[gate.test_format]:-libtest} == pytest ]]; then
		sumfn=po_stamp_sum_pytest summary='pytest summary'
	fi

	if [[ -n $bin ]]; then
		[[ $bin == /* ]] || bin=$PO_INVOKE_DIR/$bin
		command -v sha256sum >/dev/null || po_die "sha256sum not found; --bin needs it"
		[[ -e $bin ]] || printf 'po stamp: %s does not exist yet; it is hashed after the gate\n' "$bin" >&2
	fi

	# [stamp] prepare: its non-blank lines, run before the state is taken.
	local -a prep=()
	local line
	while IFS= read -r line; do
		[[ -z ${line//[[:blank:]]/} ]] || prep+=("$line")
	done <<<"${PO_MANIFEST[stamp.prepare]:-}"

	local main mb head branch dirty state diffstat
	main=$(po_get layout.main)
	git rev-parse -q --verify "refs/heads/$main^{commit}" >/dev/null ||
		po_die "no branch '$main' (manifest [layout] main)"
	head=$(git -C "$wt" rev-parse -q --verify 'HEAD^{commit}') || po_die "$wt has no HEAD commit"
	branch=$(git -C "$wt" symbolic-ref -q --short HEAD) || branch=detached
	mb=$(git -C "$wt" merge-base "refs/heads/$main" "$head") ||
		po_die "HEAD $head shares no history with $main"
	diffstat=$(git -C "$wt" diff --shortstat "$mb" "$head")
	diffstat=${diffstat# }
	[[ -n $diffstat ]] || diffstat='no changes'
	local tcount=''
	[[ -z ${PO_MANIFEST[stamp.test_files]+x} ]] || tcount=$(po_stamp_test_counts "$wt" "$mb" "$head" "$main")

	printf 'po stamp: gate in %s at %s\n' "$wt" "$head" >&2
	local gate_sum=0 gate_lines=0 test_sum=0 test_lines=0 off=0 leg_start
	PO_STAMP_ITEM=$(po_unfill "$(po_get layout.branch)" "$branch" 2>/dev/null) || PO_STAMP_ITEM=-
	PO_STAMP_NAMES=()
	((${#prep[@]} == 0)) || PO_STAMP_NAMES=(prepare) off=1
	PO_STAMP_NAMES+=("${names[@]}")
	PO_STAMP_RES=() PO_STAMP_SECS=()
	PO_STAMP_START=$(date +%s)
	for i in "${!PO_STAMP_NAMES[@]}"; do PO_STAMP_RES+=(skip) PO_STAMP_SECS+=(0); done
	# Outside the worktree, so it is never part of the state stamped.
	PO_STAMP_TMP=$(mktemp -d "${TMPDIR:-/tmp}/po-stamp.XXXXXX") || PO_STAMP_TMP=''
	# The prepare leg's output (out-0) is every line's in turn; test
	# summaries it prints count for nothing.
	if ((off)); then
		PO_STAMP_RES[0]=fail
		PO_STAMP_FAILING=0
		leg_start=$(date +%s)
		for i in "${!prep[@]}"; do
			printf 'po stamp: prepare: %s\n' "${prep[i]}" >&2
			po_stamp_run "$wt" "${prep[i]}" "out-prep-$i" "prepare: ${prep[i]}"
			PO_STAMP_SECS[0]=$(($(date +%s) - leg_start))
			[[ -z $PO_STAMP_TMP ]] || cat -- "$PO_STAMP_TMP/out-prep-$i" >>"$PO_STAMP_TMP/out-0" 2>/dev/null
			[[ $PO_RUN_CODE == 0 ]] ||
				po_stamp_fail "prepare line '${prep[i]}' exited $PO_RUN_CODE"
			po_stamp_left "prepare: ${prep[i]}" 0
		done
		PO_STAMP_FAILING=-1
		PO_STAMP_RES[0]=pass
	fi
	# Taken after prepare: the block and the unchanged-tree check name the
	# tree the gate tests.
	dirty=$(po_stamp_porcelain "$wt" | grep -c '' || true)
	state=$(po_stamp_state "$wt")
	for i in "${!names[@]}"; do
		printf 'po stamp: leg %s: %s\n' "${names[i]}" "${cmds[i]}" >&2
		leg_start=$(date +%s)
		po_stamp_run "$wt" "${cmds[i]}" "out-$((i + off))" "leg ${names[i]}: ${cmds[i]}"
		PO_STAMP_SECS[i + off]=$(($(date +%s) - leg_start))
		PO_STAMP_RES[i + off]=fail
		PO_STAMP_FAILING=$((i + off))
		[[ $PO_RUN_CODE == 0 ]] ||
			po_stamp_fail "gate leg '${names[i]}' (${cmds[i]}) exited $PO_RUN_CODE"
		((PO_RUN_ABORTED == 0)) ||
			po_stamp_fail "gate leg '${names[i]}' (${cmds[i]}) printed RUN-ABORTED: the runner died before its last block"
		po_stamp_left "leg ${names[i]}" $((i + off))
		$sumfn "$PO_RUN_RESULTS" "gate leg '${names[i]}'"
		PO_STAMP_FAILING=-1
		PO_STAMP_RES[i + off]=pass
		gate_sum=$((gate_sum + PO_SUM))
		gate_lines=$((gate_lines + PO_SUM_LINES))
		((i != test_leg)) || test_sum=$PO_SUM test_lines=$PO_SUM_LINES
	done

	local count_run=$count_cmd
	if ((test_leg >= 0 && ${#PO_STAMP_TMP} > 0)); then
		local saved
		printf -v saved '%q' "$PO_STAMP_TMP/out-$((test_leg + off))"
		count_run="cat $saved"
		[[ -z $count_cmd ]] || count_run="cat $saved | { $count_cmd; }"
		count_cmd=${count_cmd:-"the test leg's output"}
		# The count comes from the test leg alone: so does the sum it is
		# checked against; other legs' summaries (doc, integration) are theirs.
		gate_sum=$test_sum gate_lines=$test_lines
	fi
	printf 'po stamp: test count: %s\n' "$count_cmd" >&2
	po_stamp_run "$wt" "$count_run" out-count "test count: $count_cmd"
	[[ $PO_RUN_CODE == 0 ]] || po_stamp_fail "test_count_cmd ($count_cmd) exited $PO_RUN_CODE"
	((PO_RUN_ABORTED == 0)) ||
		po_stamp_fail "test_count_cmd ($count_cmd) printed RUN-ABORTED: the runner died before its last block, so no count is taken"
	[[ -z ${PO_MANIFEST[gate.run_sentinel]:-} || $PO_RUN_ENDED -gt 0 ]] ||
		po_stamp_fail "test_count_cmd ($count_cmd) printed no RUN-END sentinel: the run did not finish, so no count is taken"
	po_stamp_left "the test count" -1
	$sumfn "$PO_RUN_RESULTS" "test_count_cmd"
	((PO_SUM_LINES > 0)) || po_stamp_fail "test_count_cmd ($count_cmd) printed no $summary"
	local tests=$PO_SUM
	((gate_lines == 0 || gate_sum == tests)) ||
		po_stamp_fail "the gate passed $gate_sum tests but test_count_cmd counted $tests"

	[[ $(po_stamp_state "$wt") == "$state" ]] ||
		po_stamp_fail "the worktree changed while the gate ran; the evidence would not name what was tested"

	local bin_line=''
	if [[ -n $bin ]]; then
		[[ -f $bin ]] || po_stamp_fail "--bin $bin is not a file"
		local sum shown=$bin
		sum=$(sha256sum -- "$bin") || po_stamp_fail "could not hash $bin"
		po_under "$bin" "$wt" && shown=${bin#"${wt%/}/"}
		bin_line=$(printf 'bin sha256 %s (%s)' "${sum%% *}" "$shown")
	fi

	# The run's time, taken once: the block's line and the event carry the
	# same seconds. Over [stamp] slow_after (the project's gate time budget)
	# the block says so; at or under it the block is unchanged.
	local over='' budget
	po_stamp_seconds
	budget=$((10#${PO_MANIFEST[stamp.slow_after]:-300}))
	((PO_EVENT_SECONDS <= budget)) ||
		over="gate time: $(po_event_secs "$PO_EVENT_SECONDS"), over budget $(po_event_secs "$budget") (slow_after)"

	local legs block
	legs=$(
		IFS=/
		printf '%s' "${names[*]}"
	)
	block=$(
		printf 'HEAD %s (%s)  dirty %s\n' "$head" "$branch" "$dirty"
		printf 'gate PASS: %s   tests %s passed\n' "$legs" "$tests"
		printf 'diffstat vs merge-base(%s): %s\n' "$main" "$diffstat"
		[[ -z $tcount ]] || printf '%s\n' "$tcount"
		[[ -z $over ]] || printf '%s\n' "$over"
		for line in "${prep[@]}"; do printf 'prepare ran: %s\n' "$line"; done
		[[ -z $bin_line ]] || printf '%s\n' "$bin_line"
	)

	# The next number: one past the highest stamp file already there.
	local f n=0
	for f in "$wt"/gate-*.txt; do
		[[ ${f##*/} =~ $PO_STAMP_NAME_RE ]] || continue
		((10#${BASH_REMATCH[1]} > n)) && n=$((10#${BASH_REMATCH[1]}))
	done
	local file=$wt/gate-$((n + 1)).txt
	[[ ! -e $file && ! -L $file ]] || po_stamp_fail "${file##*/} already exists"
	# noclobber: the redirection fails rather than replace a file that
	# appeared since the check; a write that fails part-way is removed.
	if ! (set -C && printf '%s\n' "$block" >"$file") 2>/dev/null; then
		[[ -f $file ]] && rm -f -- "$file"
		po_stamp_fail "could not write ${file##*/}"
	fi
	po_stamp_cleanup
	# shellcheck disable=SC2034 # read by po_event_log
	PO_EVENT_TESTS=$tests PO_EVENT_LOAD1=$(po_stamp_load1)
	po_event_log stamp "$PO_STAMP_ITEM" pass "$(po_stamp_legs_json)" ''
	printf '%s\n' "$block"
	printf 'po stamp: wrote %s\n' "$file" >&2
}
