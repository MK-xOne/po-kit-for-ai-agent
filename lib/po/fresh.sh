# shellcheck shell=bash
# po fresh — read-only. Is an item branch based at the tip of main?
#
# Lists every commit on main since the branch point, oldest first, each
# classed by its subject (the manifest's admin prefix, its item-commit
# form) and marked when it changes the decisions or rules file. Judged
# against the local main only: fresh never fetches, rebases or writes.
#
# Exit 0 when main is an ancestor of the branch, 5 (REBASE REQUIRED) when
# it is not, 1 on usage, 2 when the branch or main does not exist.

# po_fresh_item_version <subject>: the version an item commit's subject
# names, when it has the manifest's item_commit form; non-zero otherwise.
po_fresh_item_version() {
	local tpl pre mid rest v
	[[ -n ${PO_MANIFEST[versioning.item_commit]+x} ]] || return 1
	tpl=${PO_MANIFEST[versioning.item_commit]}
	pre=${tpl%%\{version\}*}
	mid=${tpl#*\{version\}}
	mid=${mid%%\{title\}*}
	[[ $1 == "$pre"* ]] || return 1
	rest=${1#"$pre"}
	[[ -n $mid && $rest == *"$mid"* ]] || return 1
	v=${rest%%"$mid"*}
	[[ $v =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
	printf '%s' "$v"
}

# po_fresh_marks <commit>: " RULING" when it changes [docs] decisions,
# " RULES" when it changes [docs] rules (against its first parent).
po_fresh_marks() {
	local key mark path
	git rev-parse -q --verify "$1^1" >/dev/null || return 0
	for key in docs.decisions:RULING docs.rules:RULES; do
		[[ -n ${PO_MANIFEST[${key%%:*}]+x} ]] || continue
		path=${PO_MANIFEST[${key%%:*}]}
		mark=${key#*:}
		[[ -n $(git diff --name-only "$1^1" "$1" -- ":(literal)$path") ]] && printf ' %s' "$mark"
	done
	return 0
}

# po_commit_class <commit> <subject>: its class — ADMIN (admin_prefix),
# ITEM <tag> (item_commit form) or OTHER — and its marks. po kickoff
# classes commits with this too, so the two always agree.
po_commit_class() {
	local v
	if [[ -n ${PO_MANIFEST[versioning.admin_prefix]+x} && $2 == "${PO_MANIFEST[versioning.admin_prefix]}"* ]]; then
		printf 'ADMIN'
	elif v=$(po_fresh_item_version "$2"); then
		printf 'ITEM %s' "$(po_fill "$(po_get versioning.tag)" "$v")"
	else
		printf 'OTHER'
	fi
	po_fresh_marks "$1"
}

# po_commit_line <commit> <subject> [<class>]: one listed commit.
po_commit_line() {
	printf '  %s  %-13s %s\n' "$(po_short "$1")" "${3:-$(po_commit_class "$1" "$2")}" "$2"
}

po_cmd_fresh() {
	(($# == 1)) || po_usage_die "fresh needs exactly one <version>"
	[[ $1 != -* ]] || po_usage_die "fresh: unknown argument '$1'"
	local version main branch tip mtip base ab ahead behind
	version=$(po_version_arg fresh "$1")
	main=$(po_get layout.main)
	branch=$(po_fill "$(po_get layout.branch)" "$version")
	mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") ||
		po_die "no branch '$main' (manifest [layout] main)"
	tip=$(git rev-parse -q --verify "refs/heads/$branch^{commit}") ||
		po_die "no branch '$branch' for version $version"
	base=$(git merge-base "$mtip" "$tip") || po_die "$branch shares no history with $main"
	ab=$(po_ahead_behind "$tip" "$mtip")
	ahead=${ab% *} behind=${ab#* }

	printf 'branch    %s  %s  ahead %s  behind %s\n' "$branch" "$(po_short "$tip")" "$ahead" "$behind"
	printf 'main      %s  %s (local; po never fetches)\n' "$main" "$(po_short "$mtip")"
	printf 'base      %s  (merge-base)\n' "$(po_short "$base")"

	local i
	for i in "${!PO_WT_PATH[@]}"; do
		[[ $(po_wt_rebasing_branch "${PO_WT_PATH[i]}") == "$branch" ]] &&
			printf 'note      a rebase of %s is stopped part-way in %s; the branch ref is still the old tip\n' \
				"$branch" "${PO_WT_PATH[i]}"
	done
	local ref
	while IFS= read -r ref; do
		[[ -n $ref ]] || continue
		[[ $(git rev-parse "$ref") == "$mtip" ]] ||
			printf 'note      %s is at %s (as of the last fetch); fresh judges against local %s\n' \
				"${ref#refs/remotes/}" "$(po_short "$ref")" "$main"
	done < <(git for-each-ref --format='%(refname)' "refs/remotes/*/$main")

	printf '\nMAIN SINCE BRANCH POINT (%s)\n' "$behind"
	local c s
	while IFS=' ' read -r c s; do
		po_commit_line "$c" "$s"
	done < <(git log --reverse --topo-order --format='%H %s' "$tip..$mtip")

	printf '\n'
	if ((behind == 0)); then
		printf 'FRESH: %s is based at %s tip %s\n' "$branch" "$main" "$(po_short "$mtip")"
		return 0
	fi
	printf 'REBASE REQUIRED: %s is %s behind %s (tip %s); rebase it onto %s and re-run the gate\n' \
		"$branch" "$behind" "$main" "$(po_short "$mtip")" "$main"
	exit 5
}
