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

# Stamp files at a worktree root; they are not part of the state stamped.
PO_STAMP_NAME_RE='^gate-([1-9][0-9]*)\.txt$'

po_stamp_fail() {
	printf 'po stamp: FAIL: %s\n' "$*" >&2
	printf 'po stamp: no evidence written\n' >&2
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

# po_stamp_run <dir> <command>: run <command> with sh in <dir>, its output
# going to stderr as it happens. Sets PO_RUN_CODE to its exit status and
# PO_RUN_RESULTS to the summary lines it printed: libtest's ("test result:
# ...") or, with [gate] test_format = "pytest", pytest's final lines.
po_stamp_run() {
	local out pytest=0
	[[ ${PO_MANIFEST[gate.test_format]:-libtest} != pytest ]] || pytest=1
	# Command substitution does not inherit errexit, so PIPESTATUS survives.
	# Lines are copied to stderr through the inherited descriptor: reopening
	# it (tee /dev/stderr) would truncate a log file stderr points at.
	out=$(
		(cd "$1" && exec sh -c "$2") </dev/null 2>&1 | {
			while IFS= read -r line || [[ -n $line ]]; do
				printf '%s\n' "$line" >&2
				if ((pytest)); then
					if [[ $line =~ $PO_PYTEST_RE ]]; then printf '%s\n' "$line"; fi
				elif [[ $line == 'test result: '* ]]; then
					printf '%s\n' "$line"
				fi
			done
		}
		printf 'po-stamp-exit %s\n' "${PIPESTATUS[0]}"
	)
	PO_RUN_CODE=${out##*po-stamp-exit }
	PO_RUN_RESULTS=${out%po-stamp-exit *}
	PO_RUN_RESULTS=${PO_RUN_RESULTS%$'\n'}
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
	local count_cmd sumfn=po_stamp_sum summary="'test result:' line"
	count_cmd=$(po_get gate.test_count_cmd)
	if [[ ${PO_MANIFEST[gate.test_format]:-libtest} == pytest ]]; then
		sumfn=po_stamp_sum_pytest summary='pytest summary'
	fi

	if [[ -n $bin ]]; then
		[[ $bin == /* ]] || bin=$PO_INVOKE_DIR/$bin
		command -v sha256sum >/dev/null || po_die "sha256sum not found; --bin needs it"
		[[ -e $bin ]] || printf 'po stamp: %s does not exist yet; it is hashed after the gate\n' "$bin" >&2
	fi

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
	dirty=$(po_stamp_porcelain "$wt" | grep -c '' || true)
	state=$(po_stamp_state "$wt")

	printf 'po stamp: gate in %s at %s\n' "$wt" "$head" >&2
	local gate_sum=0 gate_lines=0
	for i in "${!names[@]}"; do
		printf 'po stamp: leg %s: %s\n' "${names[i]}" "${cmds[i]}" >&2
		po_stamp_run "$wt" "${cmds[i]}"
		[[ $PO_RUN_CODE == 0 ]] ||
			po_stamp_fail "gate leg '${names[i]}' (${cmds[i]}) exited $PO_RUN_CODE"
		$sumfn "$PO_RUN_RESULTS" "gate leg '${names[i]}'"
		gate_sum=$((gate_sum + PO_SUM))
		gate_lines=$((gate_lines + PO_SUM_LINES))
	done

	printf 'po stamp: test count: %s\n' "$count_cmd" >&2
	po_stamp_run "$wt" "$count_cmd"
	[[ $PO_RUN_CODE == 0 ]] || po_stamp_fail "test_count_cmd ($count_cmd) exited $PO_RUN_CODE"
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

	local legs block
	legs=$(
		IFS=/
		printf '%s' "${names[*]}"
	)
	block=$(
		printf 'HEAD %s (%s)  dirty %s\n' "$head" "$branch" "$dirty"
		printf 'gate PASS: %s   tests %s passed\n' "$legs" "$tests"
		printf 'diffstat vs merge-base(%s): %s\n' "$main" "$diffstat"
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
	printf '%s\n' "$block"
	printf 'po stamp: wrote %s\n' "$file" >&2
}
