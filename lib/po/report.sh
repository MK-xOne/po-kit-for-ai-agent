# shellcheck shell=bash
# po-kit: po report — read-only. The item report as one markdown block:
#
#   <tag> report — <branch> at <short HEAD>
#   Files changed:   what git status shows, then the item commit's files
#   the newest stamp block, verbatim, between fences
#   PROPOSED:        the --note texts, numbered, as given
#
# Fresh stamp only. With no gate-<n>.txt, a newest one that names another
# HEAD or another dirty count, or any changed file newer than it, report
# exits 4 and prints nothing on stdout. It never runs the gate: stamp
# writes, report reads. The notes are the caller's words; the kit writes
# no prose and posts nothing.

po_report_fail() {
	printf 'po report: %s\n' "$*" >&2
	exit 4
}

po_cmd_report() {
	local -a notes=()
	while (($# > 0)); do
		case $1 in
		--note)
			(($# >= 2)) || po_usage_die "--note needs a text"
			[[ -n ${2//[[:space:]]/} ]] || po_usage_die "--note text is empty"
			notes+=("$2")
			shift 2
			;;
		*) po_usage_die "report: unknown argument '$1'" ;;
		esac
	done

	local wt=$PO_INVOKE_WT main head branch version tag mb
	main=$(po_get layout.main)
	git rev-parse -q --verify "refs/heads/$main^{commit}" >/dev/null ||
		po_die "no branch '$main' (manifest [layout] main)"
	head=$(git -C "$wt" rev-parse -q --verify 'HEAD^{commit}') || po_die "$wt has no HEAD commit"
	branch=$(git -C "$wt" symbolic-ref -q --short HEAD) || po_die "$wt has a detached HEAD: report names the item branch"
	version=$(po_unfill "$(po_get layout.branch)" "$branch") ||
		po_die "branch '$branch' is not an item branch ([layout] branch $(po_get layout.branch))"
	tag=$(po_fill "$(po_get versioning.tag)" "$version")
	mb=$(git -C "$wt" merge-base "refs/heads/$main" "$head") ||
		po_die "HEAD $head shares no history with $main"

	# The newest stamp: the highest gate-<n>.txt at the worktree root.
	local f n=0 stamp=''
	for f in "$wt"/gate-*.txt; do
		[[ ${f##*/} =~ $PO_STAMP_NAME_RE ]] || continue
		if ((10#${BASH_REMATCH[1]} > n)); then
			n=$((10#${BASH_REMATCH[1]}))
			stamp=$f
		fi
	done
	[[ -n $stamp ]] || po_report_fail "no stamp: run po stamp"
	local block first
	block=$(<"$stamp")
	first=${block%%$'\n'*}
	[[ $first =~ ^HEAD\ ([0-9a-f]+)\ \(.*\)\ \ dirty\ ([0-9]+)$ ]] ||
		po_report_fail "${stamp##*/} is not a stamp block: run po stamp"
	[[ ${BASH_REMATCH[1]} == "$head" ]] ||
		po_report_fail "${stamp##*/} names another HEAD (${BASH_REMATCH[1]:0:7}, not ${head:0:7}): stamp is stale: run po stamp"
	local stamped_dirty=$((10#${BASH_REMATCH[2]}))

	# Changed files: status entries (NUL-separated; a rename or copy has
	# its source as a second field), minus the stamp files themselves.
	local -a lines=() paths=()
	local entry code path orig dirty=0
	while IFS= read -r -d '' entry; do
		code=${entry:0:2}
		path=${entry:3}
		if [[ $code == *[RC]* ]]; then
			IFS= read -r -d '' orig
			path="$orig -> $path"
		fi
		[[ $code == '??' && $path =~ $PO_STAMP_NAME_RE ]] && continue
		dirty=$((dirty + 1))
		code=${code// /}
		lines+=("- $code \`$path\`")
		paths+=("${path##* -> }")
	done < <(git -C "$wt" --no-optional-locks -c core.quotePath=false status --porcelain -z --untracked-files=all)
	((dirty == stamped_dirty)) ||
		po_report_fail "stamp is stale (it saw dirty $stamped_dirty, the worktree has $dirty): run po stamp"

	# The item commit's files, when the branch is ahead of main.
	if [[ $mb != "$head" ]]; then
		while IFS= read -r -d '' code && IFS= read -r -d '' path; do
			lines+=("- $code \`$path\` (committed)")
			paths+=("$path")
		done < <(git -C "$wt" diff --name-status -z --no-renames "$mb" "$head")
	fi

	for path in "${paths[@]}"; do
		# A deleted file has no time; a missing path cannot be newer.
		[[ -e $wt/$path || -L $wt/$path ]] || continue
		[[ $wt/$path -nt $stamp ]] &&
			po_report_fail "$path is newer than ${stamp##*/}: stamp is stale: run po stamp"
	done

	# Everything is read; only now does anything reach stdout.
	local i out
	# shellcheck disable=SC2016 # the backticks are markdown fences, not substitutions
	out=$(
		printf '%s report — %s at %s\n\n' "$tag" "$branch" "${head:0:7}"
		if ((${#lines[@]} == 0)); then
			printf 'Files changed: none\n'
		else
			printf 'Files changed:\n'
			printf '%s\n' "${lines[@]}"
		fi
		printf '\nStamp (%s):\n```\n%s\n```\n' "${stamp##*/}" "$block"
		if ((${#notes[@]} > 0)); then
			printf '\nPROPOSED:\n'
			for i in "${!notes[@]}"; do
				printf '%s. %s\n' $((i + 1)) "${notes[i]}"
			done
		fi
	)
	printf '%s\n' "$out"
}
