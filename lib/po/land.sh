# shellcheck shell=bash
# po land <version> [--dry-run] — a finished item the whole way: rebase onto
# main, stamp, close (changelog in the close's admin commit), push, in one
# command, so a host queue can run it one item at a time with nobody at the
# keyboard. po land judges nothing: it runs only after the item's SPEC MET
# is recorded, and every refusal is po close's refusal under the same law.
#
# The record (po land record) lives beside po's other per-repository state,
# in the common git dir, never in the worktree (a file there is a dirty line
# for po stamp and a kept worktree for po close):
#   <common git dir>/po-land/<version>/spec-met     by=<name> at=<ISO UTC> ref=<id|hand>
#   <common git dir>/po-land/<version>/report.md    the dev's REPORT (optional)
#   <common git dir>/po-land/<version>/changelog.md the changelog block (optional)
#
# Pre-flight, read-only, every check before any write (exit codes as the kit's):
#   1. the record exists (6);
#   2. every backlog source says DOING (3 / 6);
#   3. the branch has a worktree, and no git operation is stopped in it (6);
#   4. the worktree is clean (6: the first dirty path);
#   5. exactly one item-form commit over the merge-base with main, not a
#      merge (6: both subjects), or none (a no-change item);
#   6. the newest gate-<n>.txt names the branch tip, dirty 0, gate PASS (6);
#   7. the main checkout is clean and has an author (6).
# Then, in order, each step re-checking what it relies on:
#   8. rebase, when main is not an ancestor of the tip; a conflict is
#      aborted, the worktree verified back at the dev's tip, exit 5;
#   9. po stamp in the worktree, unless nothing was rebased and the dev's
#      stamp names the tip; a failed stamp is exit 4, the worktree left at
#      the rebased tip (the dev's old tip printed);
#  10. the close body from fixed parts (the stamp line, SPEC MET, the REPORT's
#      PROPOSED notes and Memory line, else "Memory: nothing new learned");
#  11. po close <version> --body-file ... [--changelog-file ...] --commit;
#  12. the worktree and branch, when po close kept them (ignored files);
#  13. the [land] push command, sh -c in the main checkout (exit 7 on
#      failure, the boundary standing); none configured: no push;
#  14. the record is removed.
# stdout carries exactly one line, "land: <OUTCOME> ...", with OUTCOME one of
# OK, REFUSED, CONFLICT, STAMP FAILED, CLOSE FAILED, PUSH FAILED; everything
# else goes to stderr. --dry-run prints every check as a plan line (ok, or
# "would refuse: <reason>") and the steps 8-14 as a plan, runs no gate and
# writes nothing, exit 0 whenever the plan could be printed.
# Never: resolve a conflict, retry a stamp, amend or reset a commit the dev
# made, push anything but what po close produced.

po_land_usage() {
	po_usage_die "usage: po land <version> [--dry-run] | po land record <version> --spec-met --by <name> [--ref <id>] [--report-file <f>] [--changelog-file <f>]"
}

# po_land_dir <version>: the record directory (in the common git dir).
po_land_dir() {
	local dir
	dir=$(git rev-parse --path-format=absolute --git-common-dir) || po_die "no git common dir"
	printf '%s/po-land/%s' "$dir" "$1"
}

# po_land_short_title <title>: a backlog title cut for one line: up to its
# first " (" or ". ", and at 120 characters (then "...").
po_land_short_title() {
	local t=$1
	t=${t%% (*}
	t=${t%%. *}
	((${#t} <= 120)) || t="${t:0:120}..."
	printf '%s' "$t"
}

# po_land_out <OUTCOME> [<rest>]: the one stdout line.
po_land_out() {
	if [[ -n ${2:-} ]]; then
		printf 'land: %s %s\n' "$1" "$2"
	else
		printf 'land: %s\n' "$1"
	fi
}

# po_land_refuse <reason>: the stdout line, po close's own refusal, exit 6.
po_land_refuse() {
	po_land_out REFUSED "$*"
	po_refuse "$*"
}

po_cmd_land() {
	(($# > 0)) || po_land_usage
	if [[ $1 == record ]]; then
		shift
		po_cmd_land_record "$@"
		return
	fi
	local dry=0 version=''
	while (($# > 0)); do
		case $1 in
		--dry-run) dry=1 ;;
		-*) po_usage_die "land: unknown argument '$1'" ;;
		*)
			[[ -z $version ]] || po_land_usage
			version=$(po_version_arg land "$1")
			;;
		esac
		shift
	done
	[[ -n $version ]] || po_land_usage
	po_land_run "$version" "$dry"
}

# po land record <version> --spec-met --by <name> [--ref <id>] [--report-file <f>] [--changelog-file <f>]
po_cmd_land_record() {
	local version='' spec_met=0 by='' ref=hand report='' changelog=''
	while (($# > 0)); do
		case $1 in
		--spec-met) spec_met=1 ;;
		--by | --ref | --report-file | --changelog-file)
			(($# >= 2)) || po_usage_die "land record: $1 needs a value"
			case $1 in
			--by) by=$2 ;;
			--ref) ref=$2 ;;
			--report-file) report=$2 ;;
			--changelog-file) changelog=$2 ;;
			esac
			shift
			;;
		-*) po_usage_die "land record: unknown argument '$1'" ;;
		*)
			[[ -z $version ]] || po_land_usage
			version=$(po_version_arg "land record" "$1")
			;;
		esac
		shift
	done
	[[ -n $version ]] || po_land_usage
	((spec_met)) || po_usage_die "land record: needs --spec-met (the only record po land knows)"
	[[ -n $by && $by != *[$'\t\n\r ']* ]] || po_usage_die "land record: needs --by <name> (one word)"
	[[ $ref != *[$'\t\n\r ']* ]] || po_usage_die "land record: --ref must be one word"
	[[ -z $report || -f $report ]] || po_usage_die "land record: --report-file $report is not a file"
	[[ -z $changelog || -f $changelog ]] || po_usage_die "land record: --changelog-file $changelog is not a file"

	local tag branch main mtip tip mb
	tag=$(po_fill "$(po_get versioning.tag)" "$version")
	branch=$(po_fill "$(po_get layout.branch)" "$version")
	main=$(po_get layout.main)
	po_backlog_load
	po_item_is "$version" DOING ||
		po_refuse "$tag is ${PO_ITEM_SAYS:-recorded by no backlog source}, not DOING"
	# A block for an item whose own commit changes the changelog would land the entry twice.
	if [[ -n $changelog && -n ${PO_MANIFEST[close.changelog]+x} ]] &&
		mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") &&
		tip=$(git rev-parse -q --verify "refs/heads/$branch^{commit}") &&
		mb=$(git merge-base "$mtip" "$tip" 2>/dev/null) &&
		[[ -n $(git diff --name-only "$mb" "$tip" -- ":(literal)${PO_MANIFEST[close.changelog]}") ]]; then
		po_refuse "$branch already changes ${PO_MANIFEST[close.changelog]}; a --changelog-file block would make the entry land twice"
	fi
	local dir
	dir=$(po_land_dir "$version")
	rm -rf -- "$dir"
	mkdir -p -- "$dir" || po_die "cannot make $dir"
	printf 'by=%s at=%s ref=%s\n' "$by" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ref" >"$dir/spec-met"
	[[ -z $report ]] || cp -- "$report" "$dir/report.md"
	[[ -z $changelog ]] || cp -- "$changelog" "$dir/changelog.md"
	printf 'recorded SPEC MET for %s by %s (%s); po land %s may run\n' "$tag" "$by" "$dir" "$version"
}

# po_land_check <dry> <name> <ok text> <reason>: a pre-flight check's verdict.
# With <dry>, one plan line (ok, or would refuse); else an empty reason passes
# and a non-empty one refuses (6).
po_land_check() {
	if (($1)); then
		if [[ -z $4 ]]; then
			printf '  %-9s ok%s\n' "$2" "${3:+: $3}"
		else
			printf '  %-9s would refuse: %s\n' "$2" "$4"
		fi
		return 0
	fi
	[[ -z $4 ]] || po_land_refuse "$4"
}

# po_land_stamp_file <worktree> [full]: the newest gate-<n>.txt there, with
# full the newest full one (empty when none).
po_land_stamp_file() {
	po_stamp_newest "$@"
}

# po_land_stamp_ok <stamp file> <tip> <branch>: non-zero with the reason on
# stdout when the stamp does not name <tip> clean with a passing gate.
po_land_stamp_ok() {
	local block first second
	block=$(<"$1")
	first=${block%%$'\n'*} second=${block#*$'\n'}
	second=${second%%$'\n'*}
	if [[ $first != "HEAD $2 ($3)  dirty 0" ]]; then
		printf '%s does not stamp the branch tip %s clean: %s' "${1##*/}" "$(po_short "$2")" "$first"
		return 1
	fi
	if [[ $second != 'gate PASS: '* ]]; then
		printf '%s is not a passing gate: %s' "${1##*/}" "$second"
		return 1
	fi
}

# po_land_body <out> <tag> <title> <stamp file> <tip> <branch> <main> <mtip> <rebased> <record dir>:
# the close body from fixed parts, no prose.
po_land_body() {
	local out=$1 tag=$2 title=$3 stamp=$4 tip=$5 branch=$6 main=$7 mtip=$8 rebased=$9 dir=${10}
	local block second tests='?' reb spec mem='' line in_notes=0
	block=$(<"$stamp")
	second=${block#*$'\n'}
	second=${second%%$'\n'*}
	[[ $second =~ tests\ ([0-9]+)\ passed ]] && tests=${BASH_REMATCH[1]}
	if ((rebased)); then
		reb="rebased onto $main $(po_short "$mtip") by po land"
	else
		reb='not rebased'
	fi
	if [[ -f $dir/spec-met ]]; then
		spec=$(<"$dir/spec-met")
		spec=${spec//by=/}
		spec=${spec// at=/ }
		spec=${spec// ref=/ }
	else
		spec='(none recorded)'
	fi
	{
		printf '%s · CLOSED. %s.\n' "$tag" "$(po_land_short_title "$title")"
		printf 'Stamp: gate PASS, %s tests, HEAD %s (%s), %s, %s\n' "$tests" "$(po_short "$tip")" "$branch" "${stamp##*/}" "$reb"
		printf 'SPEC MET: %s\n' "$spec"
		if [[ -f $dir/report.md ]]; then
			while IFS= read -r line || [[ -n $line ]]; do
				if ((in_notes)); then
					[[ -n ${line//[[:blank:]]/} ]] || in_notes=0
					((in_notes == 0)) || printf '%s\n' "$line"
				elif [[ $line == 'PROPOSED:'* ]]; then
					printf '\n%s\n' "$line"
					in_notes=1
				elif [[ -z $mem && $line =~ ^Memory:[[:space:]]*(.*nothing\ new\ learned|.*proposed|[0-9]{8}-[0-9]{6}-[0-9a-f]{4}) ]]; then
					mem=$line
				fi
			done <"$dir/report.md"
		fi
		printf '\n%s\n' "${mem:-Memory: nothing new learned}"
	} >"$out"
}

po_land_run() {
	local version=$1 dry=$2
	local main ttpl btpl tag branch mtip tip dir reason title='' wt='' i x
	main=$(po_get layout.main)
	ttpl=$(po_get versioning.tag)
	btpl=$(po_get layout.branch)
	tag=$(po_fill "$ttpl" "$version")
	branch=$(po_fill "$btpl" "$version")
	mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") ||
		po_die "no branch '$main' (manifest [layout] main)"
	dir=$(po_land_dir "$version")
	po_backlog_load

	if ((dry)); then
		printf 'po land: DRY RUN — nothing runs, nothing is written\n'
		printf 'item      %s  %s\n' "$tag" "$(po_land_short_title "$(po_item_title "$version")")"
		printf '\nPRE-FLIGHT\n'
	fi

	# 1. the record.
	local spec=''
	reason=''
	if [[ -f $dir/spec-met ]]; then
		spec=$(<"$dir/spec-met")
	else
		reason="no SPEC MET recorded for $tag; po land record $version --spec-met --by <name> [--ref <id>] records it"
	fi
	po_land_check "$dry" record "SPEC MET ${spec//=/ }" "$reason"

	# 2. the backlog: consistent (3 even in a dry run: nothing to plan), DOING.
	local conflicts
	conflicts=$(po_backlog_conflicts)
	[[ -z $conflicts ]] || po_conflict "the backlog disagrees with itself (run po status): ${conflicts//$'\t'/ }"
	reason=''
	if po_item_is "$version" DOING; then
		title=$(po_item_title "$version")
	else
		reason="$tag is ${PO_ITEM_SAYS:-recorded by no backlog source}, not DOING"
	fi
	po_land_check "$dry" backlog "DOING, $(po_land_short_title "$title")" "$reason"

	# 3. the branch and its worktree.
	reason=''
	if tip=$(git rev-parse -q --verify "refs/heads/$branch^{commit}"); then
		for i in "${!PO_WT_PATH[@]}"; do
			[[ ${PO_WT_BRANCH[i]} == "$branch" && " ${PO_WT_FLAGS[i]} " != *' prunable '* ]] && wt=${PO_WT_PATH[i]}
		done
		if [[ -z $wt ]]; then
			reason="$branch has no worktree"
		elif x=$(po_wt_busy "$wt") && [[ -n $x ]]; then
			reason="$x in progress in $(po_rel "$wt")"
		fi
	else
		reason="no branch $branch"
	fi
	po_land_check "$dry" worktree "${wt:+$(po_rel "$wt") at $(po_short "$tip")}" "$reason"

	# 4. clean.
	reason=''
	if [[ -n $wt ]]; then
		x=$(po_stamp_porcelain "$wt" | head -n 1)
		[[ -z $x ]] || reason="$(po_rel "$wt") is dirty: ${x:3}"
	else
		reason='no worktree'
	fi
	po_land_check "$dry" clean '' "$reason"

	# 5. one item commit (over the merge-base: the branch may be behind main).
	local mb='' n=0 subject=''
	reason=''
	if [[ -n $tip ]]; then
		mb=$(git merge-base "$mtip" "$tip") || po_die "$branch shares no history with $main"
		n=$(git rev-list --count "$mb..$tip")
		if ((n == 0)); then
			subject='(no commit: no change needed)'
		elif ((n > 1)); then
			reason="$branch has $n commits $main lacks; one item = one commit: $(git log --reverse --format=%s "$mb..$tip" | paste -sd '|' - | sed 's/|/ | /g')"
		else
			subject=$(git log -1 --format=%s "$tip")
			if [[ $(git log -1 --format=%P "$tip") == *' '* ]]; then
				reason="$branch's commit is a merge"
			elif [[ $(po_fresh_item_version "$subject") != "$version" ]]; then
				reason="$branch's commit is not in item form ($(po_get versioning.item_commit) for $version): $subject"
			fi
		fi
	else
		reason='no branch'
	fi
	po_land_check "$dry" commits "$n commit, $subject" "$reason"

	# 6. the dev's stamp names the tip (a fast one will do: step 9 stamps
	# full unless a full stamp names the tip already).
	local stamp='' stamp_ok=0 full=''
	reason=''
	if [[ -n $wt ]]; then
		stamp=$(po_land_stamp_file "$wt")
		if [[ -z $stamp ]]; then
			reason="no po stamp evidence (gate-<n>.txt) in $(po_rel "$wt")"
		else
			reason=$(po_land_stamp_ok "$stamp" "$tip" "$branch") || true
		fi
		full=$(po_land_stamp_file "$wt" full)
		if [[ -n $full ]] && po_land_stamp_ok "$full" "$tip" "$branch" >/dev/null; then
			stamp_ok=1 stamp=$full
		fi
	else
		reason='no worktree'
	fi
	po_land_check "$dry" stamp "${stamp##*/} names the tip, gate PASS" "$reason"

	# 7. the main checkout takes the admin commit.
	local author=''
	po_main_checkout
	reason=$PO_MAIN_CO_BLOCK
	[[ -n $reason ]] || author=$(po_author) || reason="git has no author identity (user.name / user.email) for $PO_MAIN_CO"
	po_land_check "$dry" main "$PO_MAIN_CO (clean), author $author" "$reason"

	# The changelog block and the item commit must not both carry the entry.
	local clpath=${PO_MANIFEST[close.changelog]:-}
	reason=''
	if [[ -f $dir/changelog.md && -n $clpath && -n $tip ]] &&
		[[ -n $(git diff --name-only "$mb" "$tip" -- ":(literal)$clpath") ]]; then
		reason="the record has a changelog block and $branch changes $clpath: the entry would land twice"
	fi
	[[ -z $reason ]] || po_land_check "$dry" changelog '' "$reason"

	# What the steps will do.
	local rebase_needed=0 stamp_needed=0 legs push clflag=''
	[[ -z $tip ]] || po_merged "$mtip" "$tip" || rebase_needed=1
	((rebase_needed == 0 && stamp_ok)) || stamp_needed=1
	[[ ! -f $dir/changelog.md ]] || clflag=" --changelog-file $dir/changelog.md"
	legs=$(
		IFS=/
		printf '%s' "${PO_GATE_LEGS[*]:-gate}"
	)
	push=${PO_MANIFEST[land.push]:-}
	push=${push//\{repo\}/$PO_MAIN_WT}

	if ((dry)); then
		printf '\nSTEPS\n'
		if ((rebase_needed)); then
			printf '  8. rebase: needed, main at %s vs merge-base %s\n' "$(po_short "$mtip")" "$(po_short "$mb")"
		else
			printf '  8. rebase: not needed\n'
		fi
		if ((stamp_needed)); then
			printf '  9. stamp: would run %s (full) in %s\n' "$legs" "$(po_rel "${wt:-?}")"
		else
			printf '  9. stamp: not needed (%s names the tip)\n' "${stamp##*/}"
		fi
		printf '  10. close body:\n'
		if [[ -n $stamp ]]; then
			local body
			body=$(mktemp "${TMPDIR:-/tmp}/po-land-body.XXXXXX") || po_die "could not make a temporary file"
			po_land_body "$body" "$tag" "$title" "$stamp" "$tip" "$branch" "$main" "$mtip" "$rebase_needed" "$dir"
			sed 's/^/      /' "$body"
			rm -f -- "$body"
		else
			printf '      (no stamp to build it from)\n'
		fi
		printf '  11. po close %s --body-file <tmp>%s --commit (not planned here: po close'"'"'s own dry run needs the rebased tip)\n' \
			"$version" "$clflag"
		printf '  12. the worktree and branch, when po close kept them\n'
		if [[ -n $push ]]; then
			printf '  13. push: %s (sh -c in %s)\n' "$push" "$PO_MAIN_WT"
		else
			printf '  13. push: none configured; pushing is the PO'"'"'s step\n'
		fi
		printf '  14. remove %s\n' "$dir"
		return 0
	fi

	# 8. rebase.
	local old_tip=$tip rebased=0
	if ((rebase_needed)); then
		[[ $(git rev-parse "refs/heads/$branch") == "$tip" ]] || po_die "stopped before any write: $branch moved since the checks"
		printf 'land: rebasing %s (%s) onto %s %s\n' "$branch" "$(po_short "$tip")" "$main" "$(po_short "$mtip")" >&2
		if ! git -C "$wt" rebase "refs/heads/$main" >&2; then
			local paths
			paths=$(git -C "$wt" diff --name-only --diff-filter=U | paste -sd ' ' -)
			git -C "$wt" rebase --abort >&2 || po_die "the rebase of $branch failed and could not be aborted; the worktree $wt needs a hand"
			[[ $(git -C "$wt" rev-parse HEAD) == "$tip" && -z $(po_stamp_porcelain "$wt") ]] ||
				po_die "the rebase of $branch was aborted but $wt is not back at $tip clean; it needs a hand"
			po_land_out CONFLICT "${paths:-(rebase failed with no conflicting path)}"
			printf 'po: the rebase of %s onto %s conflicts in: %s; the worktree is as the dev left it, at %s\n' \
				"$branch" "$main" "${paths:-?}" "$(po_short "$tip")" >&2
			exit 5
		fi
		tip=$(git rev-parse "refs/heads/$branch")
		rebased=1
		printf 'land: rebased %s to %s\n' "$branch" "$(po_short "$tip")" >&2
	fi

	# 9. stamp.
	if ((stamp_needed)); then
		local sout scode=0 leg='?' log='-'
		printf 'land: po stamp in %s at %s\n' "$(po_rel "$wt")" "$(po_short "$tip")" >&2
		local -a tierarg=()
		! po_stamp_tiered || tierarg=(--tier full)
		sout=$("$PO_SELF" -C "$wt" --manifest "$PO_MANIFEST_FILE" stamp "${tierarg[@]}" 2>&1) || scode=$?
		printf '%s\n' "$sout" >&2
		if ((scode != 0)); then
			[[ $sout =~ po\ stamp:\ FAIL:\ (gate\ leg|prepare\ line)\ \'([^\']+)\' ]] && leg=${BASH_REMATCH[2]}
			[[ $sout =~ the\ full\ output\ is\ in\ ([^[:space:]]+) ]] && log=${BASH_REMATCH[1]}
			po_land_out 'STAMP FAILED' "leg $leg, log $log"
			if ((rebased)); then
				printf 'po: the gate failed after the rebase; %s is at the rebased tip %s, clean (was %s: git -C %s reset --hard %s goes back)\n' \
					"$(po_rel "$wt")" "$(po_short "$tip")" "$(po_short "$old_tip")" "$(po_rel "$wt")" "$(po_short "$old_tip")" >&2
			else
				printf 'po: the gate failed; %s is unchanged at %s\n' "$(po_rel "$wt")" "$(po_short "$tip")" >&2
			fi
			exit $((scode == 0 ? 4 : scode))
		fi
		stamp=$(po_land_stamp_file "$wt" full)
	fi

	# 10. the close body.
	local body
	body=$(mktemp "${TMPDIR:-/tmp}/po-land-body.XXXXXX") || po_die "could not make a temporary file"
	# shellcheck disable=SC2064 # expand now: the file is fixed
	trap "rm -f -- '$body'" EXIT
	po_land_body "$body" "$tag" "$title" "$stamp" "$tip" "$branch" "$main" "$mtip" "$rebased" "$dir"

	# 11. close.
	local -a close=("$PO_SELF" -C "$PO_MAIN_WT" --manifest "$PO_MANIFEST_FILE" close "$version" --body-file "$body")
	[[ ! -f $dir/changelog.md ]] || close+=(--changelog-file "$dir/changelog.md")
	close+=(--commit)
	local cout ccode=0 admin='?'
	printf 'land: po close %s --commit\n' "$version" >&2
	cout=$("${close[@]}" 2>&1) || ccode=$?
	printf '%s\n' "$cout" >&2
	[[ $cout =~ admin\ commit\ ([0-9a-f]+)\  ]] && admin=${BASH_REMATCH[1]}
	if ((ccode != 0)); then
		po_land_out 'CLOSE FAILED' "(exit $ccode) $(tail -n 1 <<<"$cout")"
		exit "$ccode"
	fi

	# 12. what po close kept: this item's worktree and branch only.
	if [[ $cout == *$'\n'kept\ * || $cout == kept\ * ]]; then
		if [[ -d $wt ]]; then
			git -C "$wt" clean -fdXq >&2 || true
			if git worktree remove "$wt" >&2 2>&1; then
				printf 'land: removed worktree %s\n' "$(po_rel "$wt")" >&2
			else
				printf 'po: warning: could not remove %s; po prune lists it\n' "$(po_rel "$wt")" >&2
			fi
		fi
		if git show-ref --verify --quiet "refs/heads/$branch" && [[ ! -d $wt ]]; then
			git update-ref -d "refs/heads/$branch" "$tip" >&2 && printf 'land: deleted branch %s\n' "$branch" >&2 || true
		fi
	fi

	# 13. push.
	local pushed=none pcode=0
	if [[ -n $push ]]; then
		printf 'land: push: %s\n' "$push" >&2
		(
			cd "$PO_MAIN_WT" || exit 2
			exec env PO_VERSION="$version" PO_TAG="$tag" PO_REPO="$PO_MAIN_WT" PO_ADMIN_COMMIT="$(git rev-parse "refs/heads/$main")" sh -c "$push" </dev/null >&2
		) || pcode=$?
		if ((pcode != 0)); then
			po_land_out 'PUSH FAILED' "(exit $pcode)"
			printf 'po: the push command exited %s; the close stands (tag %s, admin commit %s), nothing is rolled back; a human pushes\n' "$pcode" "$tag" "$admin" >&2
			exit 7
		fi
		pushed=ok
	else
		printf 'push: none configured; pushing is the PO'"'"'s step\n' >&2
	fi

	# 14. the record.
	rm -rf -- "$dir"
	po_land_out OK "$tag admin $admin push $pushed"
}
