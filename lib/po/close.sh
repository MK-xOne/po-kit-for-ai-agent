# shellcheck shell=bash
# po close <version> [--commit] — the closing boundary of an item.
#
# Pre-flight, read-only, every check before any write:
#   - every backlog source on main says the item is DOING, and no item's
#     sources disagree (exit 3);
#   - its branch is exactly one item-format commit on top of main (6);
#   - main is an ancestor of the branch, i.e. po fresh passes (5);
#   - the highest gate-<n>.txt in its worktree names the branch tip, clean
#     (dirty 0), gate PASS (6);
#   - its tag, and the --next item's branch, tag and worktree, are free (6).
# Then, with --commit, in order: fast-forward main to the branch; tag the
# tip (by default a bare lightweight tag — written with update-ref, so tag.gpgSign
# and the like never turn it into a signed or annotated one; with [versioning]
# tag_style = "annotated", `git tag -a`, signing as git's config says); the backlog
# edits; the admin commit, its author from git's own config; the --next
# item's branch and worktree at the admin commit; the closed item's stamp
# files, worktree (`git worktree remove`, never --force) and branch.
# A [hooks] on_close command then runs (exit 7 when it fails; the boundary
# stands). Without --commit the whole plan is printed, admin message included, and
# nothing changes. Never pushes.

po_close_usage() {
	po_usage_die "usage: po close <version> [--next <version> [--next-title <title>] [--for <name>]] [--also-done <version>]... [--body-file <file>] [--commit]"
}

po_cmd_close() {
	local commit=0 version='' next='' next_title='' for_name='' body_file='' x
	local -a also=()
	while (($# > 0)); do
		case $1 in
		--commit) commit=1 ;;
		--next | --next-title | --also-done | --for | --body-file)
			(($# >= 2)) || po_usage_die "close: $1 needs a value"
			case $1 in
			--next) next=$(po_version_arg close "$2") ;;
			--next-title) next_title=$2 ;;
			--also-done) also+=("$(po_version_arg close "$2")") ;;
			--for) for_name=$2 ;;
			--body-file) body_file=$2 ;;
			esac
			shift
			;;
		-*) po_usage_die "close: unknown argument '$1'" ;;
		*)
			[[ -z $version ]] || po_close_usage
			version=$(po_version_arg close "$1")
			;;
		esac
		shift
	done
	[[ -n $version ]] || po_close_usage
	[[ -z $next_title || -n $next ]] || po_usage_die "close: --next-title needs --next"
	[[ -z $for_name || -n $next ]] || po_usage_die "close: --for names who the --next item is for; it needs --next"
	[[ -z $for_name || $for_name != *[$'\t\n\r']* ]] || po_usage_die "close: --for must be one line"
	[[ -z $next_title ]] || po_check_title "$next_title"
	[[ -z $body_file || -f $body_file ]] || po_usage_die "close: --body-file $body_file is not a file"
	[[ -z $body_file ]] || body_file=$(readlink -f -- "$body_file")

	local main ttpl btpl tag branch mtip tip
	main=$(po_get layout.main)
	ttpl=$(po_get versioning.tag)
	btpl=$(po_get layout.branch)
	tag=$(po_fill "$ttpl" "$version")
	branch=$(po_fill "$btpl" "$version")
	mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") ||
		po_die "no branch '$main' (manifest [layout] main)"
	po_backlog_load

	# The backlog: consistent, and the item DOING.
	local conflicts
	conflicts=$(po_backlog_conflicts)
	[[ -z $conflicts ]] || po_conflict "the backlog disagrees with itself (run po status): ${conflicts//$'\t'/ }"
	po_item_is "$version" DOING ||
		po_refuse "$tag is ${PO_ITEM_SAYS:-recorded by no backlog source}, not DOING"
	local title
	title=$(po_item_title "$version")

	# The branch: one item commit on main.
	tip=$(git rev-parse -q --verify "refs/heads/$branch^{commit}") || po_refuse "no branch $branch"
	local n subject parents
	n=$(git rev-list --count "$mtip..$tip")
	((n == 1)) || po_refuse "$branch has $n commits main lacks; one item = one commit"
	subject=$(git log -1 --format=%s "$tip")
	parents=$(git log -1 --format=%P "$tip")
	[[ $parents != *' '* ]] || po_refuse "$branch's commit is a merge"
	[[ $(po_fresh_item_version "$subject") == "$version" ]] ||
		po_refuse "$branch's commit is not in item form ($(po_get versioning.item_commit) for $version): $subject"

	# Fresh: main is an ancestor of the branch.
	local fresh_out fresh_code=0
	fresh_out=$(po_cmd_fresh "$version" 2>&1) || fresh_code=$?
	if ((fresh_code != 0)); then
		printf '%s\n' "$fresh_out"
		((fresh_code == 5)) && exit 5
		po_die "po fresh $version failed (exit $fresh_code)"
	fi

	# The evidence: the newest stamp in the item's worktree names the tip.
	local i wt='' f stamp='' sn=0 block
	for i in "${!PO_WT_PATH[@]}"; do
		[[ ${PO_WT_BRANCH[i]} == "$branch" && " ${PO_WT_FLAGS[i]} " != *' prunable '* ]] && wt=${PO_WT_PATH[i]}
	done
	[[ -n $wt ]] || po_refuse "$branch has no worktree, so no po stamp evidence"
	for f in "$wt"/gate-*.txt; do
		[[ ${f##*/} =~ $PO_STAMP_NAME_RE ]] || continue
		if ((10#${BASH_REMATCH[1]} > sn)); then
			sn=$((10#${BASH_REMATCH[1]}))
			stamp=$f
		fi
	done
	[[ -n $stamp ]] || po_refuse "no po stamp evidence (gate-<n>.txt) in $(po_rel "$wt")"
	block=$(<"$stamp")
	local first=${block%%$'\n'*} second=${block#*$'\n'}
	second=${second%%$'\n'*}
	[[ $first == "HEAD $tip ($branch)  dirty 0" ]] ||
		po_refuse "$(po_rel "$stamp") does not stamp the branch tip $tip clean: $first"
	[[ $second == 'gate PASS: '* ]] || po_refuse "$(po_rel "$stamp") is not a passing gate: $second"

	git show-ref --verify --quiet "refs/tags/$tag" && po_refuse "tag $tag already exists"

	# --also-done: investigations that close with no merge and no tag.
	local a ab
	for a in "${also[@]}"; do
		[[ $a != "$version" ]] || po_usage_die "close: --also-done $a is the item being closed"
		po_item_is "$a" DOING ||
			po_refuse "--also-done $(po_fill "$ttpl" "$a") is ${PO_ITEM_SAYS:-recorded by no backlog source}, not DOING"
		ab=$(po_fill "$btpl" "$a")
		if git show-ref --verify --quiet "refs/heads/$ab"; then
			n=$(git rev-list --count "$mtip..refs/heads/$ab")
			((n == 0)) || po_refuse "--also-done $(po_fill "$ttpl" "$a"): $ab has $n commits main lacks; close it with po close"
		fi
	done

	# --next: an item founded TODO goes DOING, or a new one is founded.
	local next_mode=''
	if [[ -n $next ]]; then
		[[ $next != "$version" ]] || po_usage_die "close: --next $next is the item being closed"
		if [[ -n $(po_item_statuses "$next") ]]; then
			po_item_is "$next" TODO ||
				po_refuse "--next $(po_fill "$ttpl" "$next") is $PO_ITEM_SAYS; only a TODO item can go DOING"
			[[ -z $next_title || $next_title == "$(po_item_title "$next")" ]] ||
				po_conflict "--next-title differs from the backlog's title for $next: $(po_item_title "$next")"
			for_name=$(po_resolve_owner "$next" "$for_name") || exit $?
			next_mode=flip
		else
			[[ -n $next_title ]] || po_usage_die "close: --next $next is not in the backlog; found it with --next-title <title>"
			po_check_number "$next" 0
			next_mode=found
		fi
		po_check_free "$next"
	fi

	# The edits, planned against the tip main will fast-forward to.
	po_edit_init "$tip"
	po_edit_status "$version" DOING DONE "DONE (tag $tag)"
	local -a verify=("$version:DONE")
	for a in "${also[@]}"; do
		po_edit_status "$a" DOING DONE
		verify+=("$a:DONE")
	done
	if [[ $next_mode == flip ]]; then
		po_edit_status "$next" TODO DOING
	elif [[ $next_mode == found ]]; then
		po_edit_found "$next" "$next_title"
		PO_EDIT_NOTES+=("$(po_fill "$ttpl" "$next"): founded by its heading; a $(po_get layout.backlog) mention is the PO's prose")
	fi
	[[ -z $next ]] || verify+=("$next:DOING")
	po_edit_verify "${verify[@]}"

	# The admin commit.
	local subj
	subj="$(po_get versioning.admin_prefix) $tag DONE (tag $tag)"
	for a in "${also[@]}"; do subj+=" + $(po_fill "$ttpl" "$a") DONE"; done
	if [[ $next_mode == flip ]]; then
		subj+="; $(po_fill "$ttpl" "$next") DOING"
	elif [[ $next_mode == found ]]; then
		subj+="; $(po_fill "$ttpl" "$next") $next_title founded DOING"
	fi
	[[ -z $for_name ]] || subj+=" for $for_name"
	# shellcheck disable=SC2034 # read by po_admin_message
	PO_EVIDENCE_HEAD="Evidence ($tag, po stamp ${stamp##*/}):"
	# shellcheck disable=SC2034 # read by po_admin_message
	PO_EVIDENCE=$block
	local msg=$PO_EDIT_DIR/message
	po_admin_message "$msg" "$subj" "$body_file"

	po_main_checkout
	((commit == 0)) || po_commit_ready

	# The plan.
	if ((commit)); then
		printf 'po close --commit: carrying out the plan below\n'
	else
		printf 'po close: DRY RUN — nothing changes without --commit\n'
	fi
	printf 'item      %s  %s\n' "$tag" "$title"
	printf 'branch    %s  %s  %s\n' "$branch" "$(po_short "$tip")" "$subject"
	printf 'main      %s  %s (local; po never fetches or pushes)\n' "$main" "$(po_short "$mtip")"
	printf 'fresh     %s\n' "$(grep '^FRESH' <<<"$fresh_out")"
	printf 'evidence  %s\n' "$(po_rel "$stamp")"
	printf '%s\n' "$block" | sed 's/^/          /'
	printf '\nSTEPS\n'
	local s=1
	printf '  %s. fast-forward %s %s -> %s\n' $((s++)) "$main" "$(po_short "$mtip")" "$(po_short "$tip")"
	if [[ $(po_get versioning.tag_style) == annotated ]]; then
		printf '  %s. tag %s at %s (annotated, message "%s: %s"; signing follows git config)\n' $((s++)) "$tag" "$(po_short "$tip")" "$tag" "$title"
	else
		printf '  %s. tag %s at %s (lightweight; never signed or annotated)\n' $((s++)) "$tag" "$(po_short "$tip")"
	fi
	printf '  %s. backlog edits below, committed on %s as the admin commit\n' $((s++)) "$main"
	[[ -z $next ]] ||
		printf '  %s. branch %s + worktree %s at the admin commit\n' $((s++)) \
			"$(po_fill "$btpl" "$next")" "$(po_rel "$(po_new_worktree_path "$next")")"
	printf '  %s. remove %s (its stamp files, then git worktree remove) and branch %s\n' $((s++)) \
		"$(po_rel "$wt")" "$branch"
	for a in "${also[@]}"; do
		printf '     (%s closes with no merge and no tag; its branch, if any, is left to po prune)\n' "$(po_fill "$ttpl" "$a")"
	done
	local hook=''
	[[ -z ${PO_MANIFEST[hooks.on_close]+x} ]] || hook=${PO_MANIFEST[hooks.on_close]}
	if [[ -n $hook ]]; then
		printf '  %s. then run the on_close hook (sh -c in %s, stdin /dev/null, output to stderr); a non-zero exit is a warning and exit 7, the boundary stands\n' $((s++)) "$PO_MAIN_WT"
		po_close_hook_plan "$hook" "$version" "$tag" "$title" "$tip" "$body_file" "$next"
	fi
	po_print_plan_tail "$msg"
	if ((commit == 0)); then
		po_readiness
		return 0
	fi

	# --commit. Each step re-checks what it relies on.
	printf '\n'
	[[ $(git rev-parse "refs/heads/$main") == "$mtip" ]] || po_die "stopped before any write: $main moved since the plan"
	[[ $(git rev-parse "refs/heads/$branch") == "$tip" ]] || po_die "stopped before any write: $branch moved since the plan"
	git -C "$PO_MAIN_CO" merge -q --ff-only "$branch" || po_die "stopped: the fast-forward of $main failed; nothing written"
	[[ $(git rev-parse "refs/heads/$main") == "$tip" ]] || po_die "stopped: $main is not at $tip after the fast-forward"
	printf 'fast-forwarded %s to %s\n' "$main" "$(po_short "$tip")"
	if [[ $(po_get versioning.tag_style) == annotated ]]; then
		git tag -a -m "$tag: $title" "$tag" "$tip" ||
			po_die "stopped after the fast-forward: could not create tag $tag (annotated; the tag and the admin commit are owed)"
	else
		git update-ref -m "po close: tag $tag" "refs/tags/$tag" "$tip" "" ||
			po_die "stopped after the fast-forward: could not create tag $tag"
	fi
	printf 'tagged %s at %s\n' "$tag" "$(po_short "$tip")"
	po_write_admin "$msg" " after fast-forwarding $main to $(po_short "$tip") and tagging $tag (the admin commit is owed)"
	[[ -z $next ]] || po_make_worktree "$next"

	# The closed item's worktree and branch. The boundary is complete
	# already; what cannot be removed is reported and left to po prune.
	local kept=''
	for f in "$wt"/gate-*.txt; do
		[[ ${f##*/} =~ $PO_STAMP_NAME_RE ]] && rm -f -- "$f"
	done
	if [[ -n $(po_wt_busy "$wt") ]]; then
		kept="an operation is in progress there"
	elif x=$(po_wt_ignored "$wt") && ((x > 0)); then
		kept="it holds ignored files ($x)"
	elif ! git worktree remove "$wt" 2>/dev/null; then
		kept="git worktree remove refused (dirty?)"
	fi
	if [[ -n $kept ]]; then
		printf 'kept %s and branch %s: %s — po prune lists it\n' "$(po_rel "$wt")" "$branch" "$kept"
	else
		printf 'removed worktree %s\n' "$(po_rel "$wt")"
		if git update-ref -d "refs/heads/$branch" "$tip"; then
			printf 'deleted branch %s (was %s)\n' "$branch" "$(po_short "$tip")"
		else
			printf 'kept branch %s: it moved since the plan\n' "$branch"
		fi
	fi
	[[ -z $hook ]] || po_close_hook "$hook" "$version" "$tag" "$title" "$tip" "$body_file" "$next" "$block"
}

# po_close_hook_plan <cmd> <version> <tag> <title> <item-commit> <body-file> <next>:
# the dry run's listing of the hook and the environment it would get.
po_close_hook_plan() {
	local k
	printf '\nHOOK on_close (runs only after a complete --commit boundary; a dry run runs nothing)\n'
	printf '  command  %s\n' "$1"
	printf '  in       %s\n' "$PO_MAIN_WT"
	printf '  env      PO_HOOK=on_close\n'
	for k in "PO_VERSION=$2" "PO_TAG=$3" "PO_TITLE=$4" "PO_ITEM_COMMIT=$5" \
		'PO_ADMIN_COMMIT=(the admin commit, once made)' 'PO_DATE=(its author date, ISO 8601)' \
		'PO_EVIDENCE=(a temporary file holding the stamp block quoted above)' \
		"PO_BODY_FILE=$6" "PO_NEXT=$7" "PO_REPO=$PO_MAIN_WT"; do
		printf '           %s\n' "$k"
	done
}

# po_close_hook <cmd> <version> <tag> <title> <item-commit> <body-file> <next> <block>:
# run the [hooks] on_close command once the boundary is complete. A failure
# warns and exits 7; nothing is rolled back.
po_close_hook() {
	local cmd=$1 ev code=0 admin date
	admin=$(git rev-parse "refs/heads/$(po_get layout.main)")
	date=$(git log -1 --format=%aI "$admin")
	ev=$(mktemp "${TMPDIR:-/tmp}/po-evidence.XXXXXX") || po_die "the boundary is complete, but the on_close hook did not run: no temporary file"
	printf '%s\n' "$8" >"$ev"
	printf 'running hook on_close: %s\n' "$cmd"
	(
		cd "$PO_MAIN_WT" || exit 2
		exec env PO_HOOK=on_close PO_VERSION="$2" PO_TAG="$3" PO_TITLE="$4" PO_ITEM_COMMIT="$5" \
			PO_ADMIN_COMMIT="$admin" PO_DATE="$date" PO_EVIDENCE="$ev" PO_BODY_FILE="$6" \
			PO_NEXT="$7" PO_REPO="$PO_MAIN_WT" sh -c "$cmd" </dev/null >&2
	) || code=$?
	rm -f -- "$ev"
	if ((code != 0)); then
		printf 'po: warning: hook on_close exited %s; the boundary stands, nothing is rolled back\n' "$code" >&2
		exit 7
	fi
}
