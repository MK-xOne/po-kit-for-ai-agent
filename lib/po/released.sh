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
# An item is released when its item tag ([versioning] tag filled) is an
# ancestor of the release tag. A DONE row without an item tag is not.

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
		local rec v st tpl tag
		declare -A seen=()
		tpl=$(po_get versioning.tag)
		for rec in "${PO_ITEMS[@]}"; do
			IFS=$'\t' read -r v st _ <<<"$rec"
			[[ -z ${seen[$v]+x} ]] || continue
			seen[$v]=1
			[[ ${st%% *} == DONE ]] || continue
			tag=$(po_fill "$tpl" "$v")
			git rev-parse -q --verify "refs/tags/$tag^{commit}" >/dev/null || continue
			git merge-base --is-ancestor "refs/tags/$tag" "refs/tags/$release" && released+=("$v")
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
