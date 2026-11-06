# shellcheck shell=bash
# po released — which DONE items the project's latest release contains,
# judged from git (read-only).
#
# [release] source says what a release is:
#   tag     the newest tag matching [release] pattern (default release-*) by
#           version order
#   github  the tag the caller passes with --release (a feed producer reads
#           the newest GitHub release; the kit never calls GitHub)
#   none    no releases (the default when [release] is absent)
# A DONE item is released by one of two rules:
#   tagged    its item tag ([versioning] tag filled) exists: released when
#             that tag is an ancestor of the release tag. A tag that exists
#             but is not an ancestor is not released; the rule below is not
#             tried.
#   untagged  no item tag is filled in or the tag is absent from the
#             repository: the DONE commit decides. That is the newest commit
#             on the main branch whose subject starts `admin: <v> DONE` (<v>
#             as the backlog writes it, with or without a leading `v`, up to
#             the following space), else the newest commit that changed the
#             item's row in the backlog or its `## <tag> — ...` heading in
#             specs_dir (the heading form older backlogs keep their items in).
#             Released when that commit is an ancestor of the release tag; no
#             such commit means not released.

# po_released_done_commit <version>: the DONE commit of an untagged item, or
# nothing. See the rules in the header.
po_released_done_commit() {
	local v=$1 main backlog specs_dir sha subj tpl cell re cand
	main=$(po_get layout.main)
	backlog=$(po_get layout.backlog)
	specs_dir=$(po_get layout.specs_dir)
	for cand in "v$v" "$v"; do
		while IFS=' ' read -r sha subj; do
			[[ $subj == "admin: $cand DONE"* ]] || continue
			[[ -z ${subj#"admin: $cand DONE"} || ${subj#"admin: $cand DONE"} == [[:space:]]* ]] || continue
			printf '%s' "$sha"
			return 0
		done < <(git log "$main" --format='%H %s' --fixed-strings --grep="admin: $cand DONE" 2>/dev/null)
	done
	tpl=$(po_get versioning.tag)
	cell=$(po_fill "$tpl" "$v")
	[[ -n $cell ]] || cell=$v
	re=$(printf '%s' "$cell" | sed 's/[][\.*^$]/\\&/g')
	# -G is an extended regex: a table row, or a heading as po_backlog_headings reads it.
	git log "$main" -1 --format=%H -G"^([|] *$re *[|]|## $re( |\$))" -- "$backlog" "$specs_dir" 2>/dev/null
}

po_cmd_released() {
	local json=0 given='' have_given=0
	while (($#)); do
		case $1 in
		--json) json=1; shift ;;
		--release)
			(($# >= 2)) || po_usage_die "--release needs a tag"
			given=$2 have_given=1
			shift 2
			;;
		*) po_usage_die "unknown option '$1'" ;;
		esac
	done
	local source release=
	source=$(po_get release.source)
	case $source in
	tag)
		((have_given == 0)) || po_usage_die "--release applies to [release] source \"github\" only; this project's source is \"tag\""
		release=$(git tag -l "$(po_get release.pattern)" --sort=-v:refname | head -n 1)
		;;
	github)
		if ((have_given)); then
			[[ -n $given ]] || po_usage_die "--release needs a tag"
			git rev-parse -q --verify "refs/tags/$given^{commit}" >/dev/null ||
				po_die "release tag '$given' is not in this repository (fetch tags first)"
			release=$given
		fi
		;;
	none)
		((have_given == 0)) || po_usage_die "--release applies to [release] source \"github\" only; this project's source is \"none\""
		;;
	esac

	local -a released=()
	if [[ -n $release ]]; then
		po_backlog_load
		local rec v st tpl tag done_commit
		declare -A seen=()
		tpl=$(po_get versioning.tag)
		for rec in "${PO_ITEMS[@]}"; do
			IFS=$'\t' read -r v st _ <<<"$rec"
			[[ -z ${seen[$v]+x} ]] || continue
			seen[$v]=1
			# Adopt the dashboard's status_word rule (first word, upper-cased,
			# trailing punctuation stripped) so DONE:, DONE. and done count.
			_word=${st%% *}; _word=${_word^^}
			while [[ $_word == *[[:punct:]] ]]; do _word=${_word%?}; done
			[[ $_word == DONE ]] || continue
			tag=$(po_fill "$tpl" "$v")
			if [[ -n $tag ]] && git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null; then
				git merge-base --is-ancestor "refs/tags/$tag" "refs/tags/$release" && released+=("$v")
				continue
			fi
			done_commit=$(po_released_done_commit "$v")
			[[ -n $done_commit ]] || continue
			git merge-base --is-ancestor "$done_commit" "refs/tags/$release" && released+=("$v")
		done
	fi

	if ((json)); then
		local list='' sep='' relj=null
		[[ -z $release ]] || relj=$(po_json_str "$release")
		for v in "${released[@]}"; do
			list+=$sep$(po_json_str "$v") sep=,
		done
		printf '{"source":%s,"release":%s,"released":[%s]}\n' "$(po_json_str "$source")" "$relj" "$list"
	else
		printf 'release: %s\n' "${release:-none}"
		((${#released[@]} == 0)) || printf '%s\n' "${released[@]}"
	fi
}
