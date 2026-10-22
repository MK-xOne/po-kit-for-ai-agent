# shellcheck shell=bash
# po status — read-only. What is in flight, as the repository has it.
#
# Exit 0, or 3 when the backlog's sources disagree about an item's status
# (the report is printed in full either way). With --idle <minutes>, 8 when
# a DOING item has been idle longer; 3 outranks 8.

po_rel() {
	if po_under "$1" "$PO_MAIN_WT"; then
		printf '%s' "${1#"${PO_MAIN_WT%/}/"}"
	else
		printf '%s' "$1"
	fi
}

# po_wt_idle <worktree>: seconds since the newest of the branch tip's
# commit date, the newest gate-<n>.txt, and the newest mtime among the
# worktree's changed and untracked files (a deleted file has none).
po_wt_idle() {
	local wt=$1 newest t entry code path f
	newest=$(git -C "$wt" log -1 --format=%ct HEAD 2>/dev/null) || newest=0
	for f in "$wt"/gate-*.txt; do
		[[ ${f##*/} =~ $PO_STAMP_NAME_RE ]] || continue
		t=$(stat -c %Y "$f") && ((t > newest)) && newest=$t
	done
	while IFS= read -r -d '' entry; do
		code=${entry:0:2}
		path=${entry:3}
		[[ $code == *[RC]* ]] && IFS= read -r -d '' _ # the source of a rename
		[[ -e $wt/$path || -L $wt/$path ]] || continue
		t=$(stat -c %Y "$wt/$path") && ((t > newest)) && newest=$t
	done < <(git -C "$wt" --no-optional-locks -c core.quotePath=false status --porcelain -z --untracked-files=all)
	t=$(($(date +%s) - newest))
	printf '%s' $((t < 0 ? 0 : t))
}

# po_fmt_idle <seconds>: 3h12m
po_fmt_idle() {
	printf '%dh%02dm' $(($1 / 3600)) $(($1 % 3600 / 60))
}

# po_item_lines <version> [idle]: the branch and worktree lines for one
# item. With a second argument, the branch line ends in the idle time and
# PO_IDLE_SECS is set to it ("" when the item has no worktree).
po_item_lines() {
	local version=$1 main branch ab i found=-1 idle='' suffix=''
	main=$(po_get layout.main)
	branch=$(po_fill "$(po_get layout.branch)" "$version")
	for i in "${!PO_WT_PATH[@]}"; do
		[[ ${PO_WT_BRANCH[i]} == "$branch" ]] && found=$i
	done
	if [[ -n ${2:-} ]]; then
		suffix='  idle -'
		if ((found >= 0)) && [[ " ${PO_WT_FLAGS[found]} " != *' prunable '* ]]; then
			idle=$(po_wt_idle "${PO_WT_PATH[found]}")
			suffix="  idle $(po_fmt_idle "$idle")"
		fi
	fi
	PO_IDLE_SECS=$idle
	if git show-ref --verify --quiet "refs/heads/$branch"; then
		ab=$(po_ahead_behind "$branch" "$main")
		printf '          branch %s  %s  ahead %s  behind %s%s\n' \
			"$branch" "$(po_short "$branch")" "${ab% *}" "${ab#* }" "$suffix"
	else
		printf '          branch %s  (none)%s\n' "$branch" "$suffix"
	fi
	if ((found < 0)); then
		printf '          worktree (none)\n'
	elif [[ " ${PO_WT_FLAGS[found]} " == *' prunable '* ]]; then
		printf '          worktree %s  MISSING (prunable)\n' "$(po_rel "${PO_WT_PATH[found]}")"
	else
		printf '          worktree %s  dirty %s\n' \
			"$(po_rel "${PO_WT_PATH[found]}")" "$(po_wt_dirty "${PO_WT_PATH[found]}")"
	fi
}

# po_owner_line <version>: the item's owner, when owner_column names one.
po_owner_line() {
	local owner
	owner=$(po_item_owner "$1")
	[[ -z $owner ]] || printf '          owner %s\n' "$owner"
}

# po_open_versions: "<version>\t<status>\t<title>\t<where>" for every
# live or held item, first source wins, sorted by version.
po_open_items() {
	local rec v rest s
	local -A seen=()
	for rec in "${PO_ITEMS[@]}"; do
		v=${rec%%$'\t'*}
		rest=${rec#*$'\t'}
		s=${rest%%$'\t'*}
		[[ $s == "$PO_LIVE_STATUS" ]] || po_is_held "$s" || continue
		[[ -n ${seen[$v]+x} ]] && continue
		seen[$v]=1
		printf '%s\n' "$rec"
	done | sort -t$'\t' -k1,1V
}

# po_split_tabs <record>: its tab-separated fields into PO_F, empty
# fields kept (`read` with a tab IFS would merge them).
po_split_tabs() {
	local rest=$1
	PO_F=()
	while [[ $rest == *$'\t'* ]]; do
		PO_F+=("${rest%%$'\t'*}")
		rest=${rest#*$'\t'}
	done
	PO_F+=("$rest")
}

po_cmd_status() {
	local idle_limit=''
	while (($# > 0)); do
		case $1 in
		--idle)
			(($# >= 2)) && [[ $2 =~ ^[0-9]+$ ]] || po_usage_die "--idle needs a whole number of minutes"
			idle_limit=$((10#$2 * 60))
			shift 2
			;;
		*) po_usage_die "status: unknown argument '$1'" ;;
		esac
	done
	local main main_sha tag layout_dir
	main=$(po_get layout.main)
	git show-ref --verify --quiet "refs/heads/$main" || po_die "no branch '$main'"
	main_sha=$(po_short "$main")
	po_worktrees_load
	po_backlog_load
	layout_dir="${PO_MAIN_WT%/}/$(po_get layout.worktrees)"
	tag=$(po_latest_tag "$main")

	printf 'repo      %s\n' "$PO_MAIN_WT"
	printf 'main      %s %s\n' "$main" "$main_sha"
	if [[ -n $tag ]]; then
		printf 'tag       %s (%s, %s commits behind %s)\n' "$tag" "$(po_short "$tag^{commit}")" \
			"$(git rev-list --count "$tag..$main")" "$main"
	else
		printf 'tag       (none reachable from %s)\n' "$main"
	fi
	printf 'manifest  %s\n' "$PO_MANIFEST_FILE"

	local -a open=() live=() held=() idle_items=()
	local rec v rest s title where
	mapfile -t open < <(po_open_items)
	for rec in "${open[@]}"; do
		rest=${rec#*$'\t'}
		s=${rest%%$'\t'*}
		if [[ $s == "$PO_LIVE_STATUS" ]]; then live+=("$rec"); else held+=("$rec"); fi
	done
	local -A open_branch=()
	for rec in "${open[@]}"; do
		open_branch[$(po_fill "$(po_get layout.branch)" "${rec%%$'\t'*}")]=1
	done

	local section
	for section in DOING HELD; do
		local -a list=()
		if [[ $section == DOING ]]; then list=("${live[@]}"); else list=("${held[@]}"); fi
		printf '\n%s (%s)\n' "$section" "${#list[@]}"
		for rec in "${list[@]}"; do
			po_split_tabs "$rec"
			v=${PO_F[0]} s=${PO_F[1]} title=${PO_F[2]} where=${PO_F[3]}
			if [[ $section == DOING ]]; then
				printf '  %-9s %s  [%s]\n' "$(po_fill "$(po_get versioning.tag)" "$v")" "$title" "$where"
			else
				printf '  %-9s %s  %s  [%s]\n' "$(po_fill "$(po_get versioning.tag)" "$v")" "$s" "$title" "$where"
			fi
			po_owner_line "$v"
			if [[ $section == DOING ]]; then
				po_item_lines "$v" idle
				if [[ -n $idle_limit && -n $PO_IDLE_SECS ]] && ((PO_IDLE_SECS > idle_limit)); then
					idle_items+=("$(po_fill "$(po_get versioning.tag)" "$v")"$'\t'"$PO_IDLE_SECS")
				fi
			else
				po_item_lines "$v"
			fi
		done
	done

	# Every registered worktree, classified once, in priority order.
	local i n_main=0 n_prunable=0 n_open=0 n_merged=0 n_unmerged=0
	local -a orphans=() unmerged=() dirty=()
	local -A registered=()
	for i in "${!PO_WT_PATH[@]}"; do
		local p=${PO_WT_PATH[i]} b=${PO_WT_BRANCH[i]} h=${PO_WT_HEAD[i]}
		registered[$p]=1
		if [[ " ${PO_WT_FLAGS[i]} " != *' prunable '* ]]; then
			local n
			n=$(po_wt_dirty "$p")
			((n == 0)) || dirty+=("$(po_rel "$p")"$'\t'"$n")
		fi
		if ((i == 0)); then
			n_main=$((n_main + 1))
		elif [[ " ${PO_WT_FLAGS[i]} " == *' prunable '* ]]; then
			n_prunable=$((n_prunable + 1))
			orphans+=("$(po_rel "$p")"$'\t'"directory missing (prunable registration)")
		elif [[ -n $b && -n ${open_branch[$b]+x} ]]; then
			n_open=$((n_open + 1))
		elif po_merged "$h" "$main"; then
			n_merged=$((n_merged + 1))
		else
			n_unmerged=$((n_unmerged + 1))
			[[ -z $b ]] && orphans+=("$(po_rel "$p")"$'\t'"detached at $(po_short "$h"), commits not on $main")
		fi
	done
	# Directories in the layout's worktree dir git does not know about.
	if [[ -d $layout_dir ]]; then
		local d
		for d in "$layout_dir"/*/; do
			[[ -d $d ]] || continue
			d=${d%/}
			[[ -n ${registered[$d]+x} ]] ||
				orphans+=("$(po_rel "$d")"$'\t'"directory not registered as a worktree")
		done
	fi

	# Branches with commits main lacks and no open item.
	local br
	while IFS= read -r br; do
		[[ $br == "$main" || -n ${open_branch[$br]+x} ]] && continue
		local ab wt=none
		ab=$(po_ahead_behind "$br" "$main")
		for i in "${!PO_WT_PATH[@]}"; do
			[[ ${PO_WT_BRANCH[i]} == "$br" ]] && wt=$(po_rel "${PO_WT_PATH[i]}")
		done
		unmerged+=("$br"$'\t'"ahead ${ab% *}  behind ${ab#* }  worktree $wt")
	done < <(git for-each-ref --format='%(refname:short)' --no-merged="$main" refs/heads/ | sort -V)

	printf '\nORPHANED WORKTREES (%s)\n' "${#orphans[@]}"
	local o
	for o in "${orphans[@]}"; do
		printf '  %s  %s\n' "${o%%$'\t'*}" "${o#*$'\t'}"
	done
	printf '\nDIRTY WORKTREES (%s)\n' "${#dirty[@]}"
	for o in "${dirty[@]}"; do
		printf '  %s  dirty %s\n' "${o%%$'\t'*}" "${o#*$'\t'}"
	done
	printf '\nUNMERGED BRANCHES WITH NO OPEN ITEM (%s)\n' "${#unmerged[@]}"
	for o in "${unmerged[@]}"; do
		printf '  %s  %s\n' "${o%%$'\t'*}" "${o#*$'\t'}"
	done
	printf '\nWORKTREES  %s registered: main %s, open items %s, merged %s, unmerged %s, prunable %s\n' \
		"${#PO_WT_PATH[@]}" "$n_main" "$n_open" "$n_merged" "$n_unmerged" "$n_prunable"

	if [[ -n $idle_limit ]]; then
		printf '\nIDLE (%s)\n' "${#idle_items[@]}"
		for o in "${idle_items[@]}"; do
			printf '  %-9s idle %s\n' "${o%%$'\t'*}" "$(po_fmt_idle "${o#*$'\t'}")"
		done
	fi

	local -a conflicts=()
	mapfile -t conflicts < <(po_backlog_conflicts)
	if ((${#conflicts[@]} > 0)); then
		printf '\nCONFLICTS (%s) — the backlog disagrees with itself\n' "${#conflicts[@]}"
		local c
		for c in "${conflicts[@]}"; do
			po_split_tabs "$c"
			v=${PO_F[0]} s=${PO_F[1]} where=${PO_F[2]}
			printf '  %s  %s  vs  %s\n' "$(po_fill "$(po_get versioning.tag)" "$v")" "$s" "$where"
		done
		return 3
	fi
	((${#idle_items[@]} == 0)) || return 8
	return 0
}
