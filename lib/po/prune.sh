# shellcheck shell=bash
# po prune [--commit] — worktrees and branches already merged into main.
#
# Without --commit nothing changes: the plan is printed and po exits.
# With --commit the plan is carried out with git's own safe operations, and
# every step re-checks its precondition first:
#   - `git worktree remove <path>` (no --force: git itself refuses a
#     worktree with changes or untracked files)
#   - `git worktree remove <path>` per registration whose directory is gone
#     (never `git worktree prune`, which would drop the kept ones too)
#   - `git update-ref -d refs/heads/<branch> <sha>`: deletes the branch only
#     if it still points at the commit verified merged
# Never removed, whatever their history: the main worktree and branch;
# anything locked, dirty, holding ignored files, or stopped mid-rebase/
# merge/cherry-pick/revert/bisect (and the branch a stopped rebase returns
# to); a missing-directory registration whose detached HEAD is not on main;
# worktrees outside [layout] worktrees; and the
# branches (and worktrees) of DOING and held (PAUSED/BLOCKED) items — a
# freshly founded item's branch sits on main and looks merged.
# Never pushes; deleting a local branch leaves any remote copy alone.

po_cmd_prune() {
	local commit=0
	while (($# > 0)); do
		case $1 in
		--commit) commit=1 ;;
		*) po_usage_die "prune: unknown argument '$1'" ;;
		esac
		shift
	done
	local main layout_dir tag_tpl branch_tpl
	main=$(po_get layout.main)
	git show-ref --verify --quiet "refs/heads/$main" || po_die "no branch '$main'"
	po_worktrees_load
	po_backlog_load
	layout_dir="${PO_MAIN_WT%/}/$(po_get layout.worktrees)"
	tag_tpl=$(po_get versioning.tag)
	branch_tpl=$(po_get layout.branch)

	# Branch -> "<STATUS> <tag>" for every DOING or held item.
	local -A protected=()
	local rec v rest
	while IFS= read -r rec; do
		[[ -n $rec ]] || continue
		v=${rec%%$'\t'*}
		rest=${rec#*$'\t'}
		protected[$(po_fill "$branch_tpl" "$v")]="${rest%%$'\t'*} $(po_fill "$tag_tpl" "$v")"
	done < <(po_open_items)

	# Worktrees.
	local -a wt_remove=() wt_stale=() kept=()
	local -A checked_out=() # branch -> 1, for worktrees that stay
	local i p b h f rel label why dirty
	for i in "${!PO_WT_PATH[@]}"; do
		p=${PO_WT_PATH[i]}
		b=${PO_WT_BRANCH[i]}
		h=${PO_WT_HEAD[i]}
		f=" ${PO_WT_FLAGS[i]} "
		rel=$(po_rel "$p")
		label=${b:-detached $(po_short "$h")}
		if ((i == 0)); then
			[[ -n $b ]] && checked_out[$b]=1
			continue
		fi
		if [[ $f == *' prunable '* ]]; then
			if [[ $f == *' locked '* ]]; then
				[[ -n $b ]] && checked_out[$b]=1
				kept+=("worktree $rel ($label)"$'\t'"locked")
			elif [[ -z $b ]] && ! po_merged "$h" "$main"; then
				# The registration is the last thing naming this commit.
				kept+=("worktree $rel ($label)"$'\t'"directory missing, detached HEAD not on $main")
			else
				wt_stale+=("$p"$'\t'"$label")
			fi
			continue
		fi
		# A stopped rebase shows as detached; its branch is still in use.
		local busy rebasing
		busy=$(po_wt_busy "$p")
		rebasing=$(po_wt_rebasing_branch "$p")
		[[ -n $rebasing ]] && checked_out[$rebasing]=1
		why=''
		if [[ $f == *' locked '* ]]; then
			why=locked
		elif [[ -n $busy ]]; then
			why="$busy in progress"
		elif [[ -n $b && -n ${protected[$b]+x} ]]; then
			why="open item (${protected[$b]})"
		elif ! po_merged "$h" "$main"; then
			# Not merged: not prune's business, and not listed.
			[[ -n $b ]] && checked_out[$b]=1
			continue
		elif ! po_under "$p" "$layout_dir"; then
			why="outside $(po_get layout.worktrees)"
		else
			dirty=$(po_wt_dirty "$p")
			if ((dirty > 0)); then
				why="dirty ($dirty)"
			else
				dirty=$(po_wt_ignored "$p")
				((dirty == 0)) || why="ignored files ($dirty) — git worktree remove would delete them"
			fi
		fi
		if [[ -n $why ]]; then
			[[ -n $b ]] && checked_out[$b]=1
			kept+=("worktree $rel ($label)"$'\t'"$why")
		else
			wt_remove+=("$p"$'\t'"$label")
		fi
	done

	# Branches: exactly `git branch --merged <main>`, less what must stay.
	local -a br_delete=()
	local br
	while IFS= read -r br; do
		[[ $br == "$main" ]] && continue
		if [[ -n ${protected[$br]+x} ]]; then
			kept+=("branch $br"$'\t'"open item (${protected[$br]})")
		elif [[ -n ${checked_out[$br]+x} ]]; then
			kept+=("branch $br"$'\t'"checked out in a worktree that stays")
		else
			br_delete+=("$br"$'\t'"$(git rev-parse "refs/heads/$br")")
		fi
	done < <(git for-each-ref --format='%(refname:short)' --merged="$main" refs/heads/ | sort -V)

	if ((commit)); then
		printf 'po prune --commit: carrying out the plan below\n'
	else
		printf 'po prune: DRY RUN — nothing changes without --commit\n'
	fi
	printf 'main %s %s\n' "$main" "$(po_short "$main")"
	local x
	printf '\nWORKTREES TO REMOVE (%s)\n' "${#wt_remove[@]}"
	for x in "${wt_remove[@]}"; do
		printf '  %s  %s\n' "$(po_rel "${x%%$'\t'*}")" "${x#*$'\t'}"
	done
	printf '\nSTALE REGISTRATIONS TO PRUNE (%s)\n' "${#wt_stale[@]}"
	for x in "${wt_stale[@]}"; do
		printf '  %s  %s\n' "$(po_rel "${x%%$'\t'*}")" "${x#*$'\t'}"
	done
	printf '\nBRANCHES TO DELETE (%s)\n' "${#br_delete[@]}"
	for x in "${br_delete[@]}"; do
		printf '  %s  %s\n' "${x%%$'\t'*}" "$(po_short "${x#*$'\t'}")"
	done
	printf '\nKEPT (%s)\n' "${#kept[@]}"
	for x in "${kept[@]}"; do
		printf '  %s  — %s\n' "${x%%$'\t'*}" "${x#*$'\t'}"
	done

	# The backlog disagreeing with itself makes "open item" uncertain: the
	# plan above already protects every branch any source calls open, but
	# --commit waits until the backlog is consistent.
	local -a conflicts=()
	mapfile -t conflicts < <(po_backlog_conflicts)
	if ((${#conflicts[@]} > 0)); then
		printf '\nCONFLICTS (%s) — the backlog disagrees with itself; run po status\n' "${#conflicts[@]}"
		((commit)) && po_die "refusing --commit while the backlog has conflicts"
	fi

	((commit)) || return 0

	printf '\n'
	local sha
	for x in "${wt_remove[@]}"; do
		p=${x%%$'\t'*}
		git worktree remove "$p" || po_die "stopped: 'git worktree remove $p' failed"
		printf 'removed worktree %s\n' "$(po_rel "$p")"
	done
	for x in "${wt_stale[@]}"; do
		p=${x%%$'\t'*}
		[[ ! -e $p ]] || po_die "stopped: $p exists again since the plan"
		git worktree remove "$p" || po_die "stopped: 'git worktree remove $p' failed"
		printf 'pruned stale registration %s\n' "$(po_rel "$p")"
	done
	for x in "${br_delete[@]}"; do
		br=${x%%$'\t'*}
		sha=${x#*$'\t'}
		po_merged "$sha" "$main" || po_die "stopped: $br no longer merged into $main"
		git update-ref -d "refs/heads/$br" "$sha" ||
			po_die "stopped: could not delete $br (moved since the plan?)"
		printf 'deleted branch %s (was %s)\n' "$br" "$(po_short "$sha")"
	done
	return 0
}
