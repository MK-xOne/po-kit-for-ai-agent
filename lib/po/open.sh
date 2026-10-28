# shellcheck shell=bash
# po open <version|next> [<title>] [--commit] — the founding boundary.
#
# A number no backlog source records is founded new: it must be the next
# sequential number (latest founded + 1), an epoch step with --epoch, or
# the next insert under a founded item (the manifest's insert_segment);
# its heading "## <tag> — <title> — DOING" goes into the spec file holding
# the closest lower version. A number the backlog already records must be
# TODO everywhere and goes DOING (the title, if given, must match).
# Its branch, tag and worktree path must be free.
#
# With --commit, in order: the backlog edits as the founding admin commit
# on main (author from git's own config), then the item's branch and
# worktree at that commit — so the new branch is fresh by construction.
# Without --commit the plan is printed, admin message included, and
# nothing changes. Never pushes.

po_open_usage() {
	po_usage_die 'usage: po open <version|next> [<title>] [--for <name>] [--epoch] [--body-file <file>] [--commit]'
}

po_cmd_open() {
	local commit=0 epoch=0 arg='' title='' have_title=0 for_name='' body_file=''
	while (($# > 0)); do
		case $1 in
		--commit) commit=1 ;;
		--epoch) epoch=1 ;;
		--for | --body-file)
			(($# >= 2)) || po_usage_die "open: $1 needs a value"
			if [[ $1 == --for ]]; then for_name=$2; else body_file=$2; fi
			shift
			;;
		-*) po_usage_die "open: unknown argument '$1'" ;;
		*)
			if [[ -z $arg ]]; then
				arg=$1
			elif ((have_title == 0)); then
				title=$1 have_title=1
			else
				po_open_usage
			fi
			;;
		esac
		shift
	done
	[[ -n $arg ]] || po_open_usage
	((have_title == 0)) || po_check_title "$title"
	[[ -z $for_name || $for_name != *[$'\t\n\r']* ]] || po_usage_die "open: --for must be one line"
	[[ -z $body_file || -f $body_file ]] || po_usage_die "open: --body-file $body_file is not a file"
	[[ -z $body_file ]] || body_file=$(readlink -f -- "$body_file")

	local main mtip ttpl
	main=$(po_get layout.main)
	ttpl=$(po_get versioning.tag)
	mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") ||
		po_die "no branch '$main' (manifest [layout] main)"
	po_backlog_load
	local conflicts
	conflicts=$(po_backlog_conflicts)
	[[ -z $conflicts ]] || po_conflict "the backlog disagrees with itself (run po status): ${conflicts//$'\t'/ }"

	local version mode
	if [[ $arg == next ]]; then
		((epoch == 0)) || po_usage_die "open: --epoch takes an explicit version, not next"
		version=$(po_next_number)
	else
		version=$(po_version_arg open "$arg")
	fi
	local tag
	tag=$(po_fill "$ttpl" "$version")
	if [[ -n $(po_item_statuses "$version") ]]; then
		po_item_is "$version" TODO ||
			po_refuse "$tag is already founded and $PO_ITEM_SAYS; only a TODO item can go DOING"
		((have_title == 0)) || [[ $title == "$(po_item_title "$version")" ]] ||
			po_conflict "the title differs from the backlog's for $tag: $(po_item_title "$version")"
		title=$(po_item_title "$version")
		for_name=$(po_resolve_owner "$version" "$for_name") || exit $?
		mode=flip
	else
		((have_title)) || po_usage_die "open: $tag is new; give it a \"<title>\""
		po_check_number "$version" "$epoch"
		mode=found
	fi
	po_check_free "$version"

	po_edit_init "$mtip"
	if [[ $mode == flip ]]; then
		# shellcheck disable=SC2034 # read by po_edit_table
		PO_EDIT_OWNER=$for_name
		po_edit_status "$version" TODO DOING
	else
		po_edit_found "$version" "$title"
		PO_EDIT_NOTES+=("$tag: founded by its heading; a $(po_get layout.backlog) mention is the PO's prose")
	fi
	po_edit_verify "$version:DOING"

	local subj
	if [[ $mode == flip ]]; then
		subj="$(po_get versioning.admin_prefix) $tag DOING"
	else
		subj="$(po_get versioning.admin_prefix) $tag $title founded DOING"
	fi
	[[ -z $for_name ]] || subj+=" for $for_name"
	local msg=$PO_EDIT_DIR/message
	# shellcheck disable=SC2034 # read by po_admin_message
	PO_EVIDENCE=
	po_admin_message "$msg" "$subj" "$body_file"

	po_main_checkout
	((commit == 0)) || po_commit_ready

	if ((commit)); then
		printf 'po open --commit: carrying out the plan below\n'
	else
		printf 'po open: DRY RUN — nothing changes without --commit\n'
	fi
	if [[ $mode == flip ]]; then
		printf 'item      %s  %s  (founded TODO; goes DOING)\n' "$tag" "$title"
	else
		printf 'item      %s  %s  (new; heading in %s)\n' "$tag" "$title" "$PO_FOUND_FILE"
	fi
	printf 'main      %s  %s (local; po never fetches or pushes)\n' "$main" "$(po_short "$mtip")"
	printf '\nSTEPS\n'
	printf '  1. backlog edits below, committed on %s as the admin commit\n' "$main"
	printf '  2. branch %s + worktree %s at the admin commit\n' \
		"$(po_fill "$(po_get layout.branch)" "$version")" "$(po_rel "$(po_new_worktree_path "$version")")"
	po_print_plan_tail "$msg"
	if ((commit == 0)); then
		po_readiness
		return 0
	fi

	printf '\n'
	[[ $(git rev-parse "refs/heads/$main") == "$mtip" ]] || po_die "stopped before any write: $main moved since the plan"
	po_write_admin "$msg" ''
	po_make_worktree "$version"
	po_event_log open "$version" pass '' "$title"
}
