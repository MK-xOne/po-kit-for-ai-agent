# shellcheck shell=bash
# po-kit: what po open and po close share — the numbering law, the checks
# every boundary makes before it writes, and the writes themselves.
#
# Exit 6: the item law refuses the boundary (a number out of sequence, a
# branch that is not one item commit, missing or stale stamp evidence, an
# item not in the status the boundary needs, a ref or path already taken,
# a main worktree --commit cannot write in).

po_refuse() {
	printf 'po: refused: %s\n' "$*" >&2
	exit 6
}

# po_version_arg <command> <arg>: the dotted version from "1.9.10" or tag
# form ("v1.9.10"), or a usage error.
po_version_arg() {
	local v
	if [[ $2 =~ ^[0-9]+(\.[0-9]+)+$ ]]; then
		printf '%s' "$2"
	elif v=$(po_unfill "$(po_get versioning.tag)" "$2"); then
		printf '%s' "$v"
	else
		po_usage_die "$1: '$2' is not a version (like 1.9.10) or a tag in the manifest's form"
	fi
}

# po_item_statuses <version>: the status each backlog source on main gives
# it, one per line (none when no source records it).
po_item_statuses() {
	local rec rest
	for rec in "${PO_ITEMS[@]}"; do
		[[ ${rec%%$'\t'*} == "$1" ]] || continue
		rest=${rec#*$'\t'}
		printf '%s\n' "${rest%%$'\t'*}"
	done
}

# po_item_title <version>: the first source's title for it.
po_item_title() {
	local rec rest
	for rec in "${PO_ITEMS[@]}"; do
		[[ ${rec%%$'\t'*} == "$1" ]] || continue
		rest=${rec#*$'\t'}
		rest=${rest#*$'\t'}
		printf '%s' "${rest%%$'\t'*}"
		return 0
	done
}

# po_item_owner <version>: the owner its backlog table row gives it, when
# [layout] owner_column is set; empty otherwise or for an empty cell.
po_item_owner() {
	[[ -z ${PO_OWNERS[$1]+x} ]] || printf '%s' "${PO_OWNERS[$1]}"
}

# po_resolve_owner <version> <for-name>: the name the admin subject says
# "for": <for-name> when given, else the backlog's owner. A <for-name> that
# differs from the owner the table names is a backlog disagreement (3).
po_resolve_owner() {
	local owner
	owner=$(po_item_owner "$1")
	if [[ -n $2 && -n $owner && $2 != "$owner" ]]; then
		po_conflict "--for $2 disagrees with the backlog's owner for $(po_fill "$(po_get versioning.tag)" "$1"): $owner"
	fi
	printf '%s' "${2:-$owner}"
}

# po_item_is <version> <STATUS>: success when at least one source records
# it and every source says <STATUS>. Sets PO_ITEM_SAYS to what they say.
po_item_is() {
	local s
	PO_ITEM_SAYS=$(po_item_statuses "$1" | sort -u | paste -sd/ -)
	[[ -n $PO_ITEM_SAYS ]] || return 1
	while IFS= read -r s; do
		[[ $s == "$2" ]] || return 1
	done < <(po_item_statuses "$1")
}

po_segments() {
	local d=${1//[!.]/}
	printf '%s' $((${#d} + 1))
}

# po_base_segments: how many segments a sequential number has — one less
# than [versioning] insert_segment, else as many as the highest item's.
po_base_segments() {
	if [[ -n ${PO_MANIFEST[versioning.insert_segment]+x} ]]; then
		local ins=${PO_MANIFEST[versioning.insert_segment]}
		printf '%s' "$((ins - 1))"
	else
		# Inserts carry more segments than sequential numbers, so the base
		# is the fewest any item has.
		local rec v min=''
		for rec in "${PO_ITEMS[@]}"; do
			v=$(po_segments "${rec%%$'\t'*}")
			[[ -n $min ]] && ((min <= v)) || min=$v
		done
		printf '%s' "${min:-1}"
	fi
}

# po_latest_founded <segments>: the highest version any source records,
# among those with <segments> segments (any, when empty).
po_latest_founded() {
	local rec v best=''
	for rec in "${PO_ITEMS[@]}"; do
		v=${rec%%$'\t'*}
		[[ -z $1 || $(po_segments "$v") == "$1" ]] || continue
		if [[ -z $best ]] || po_version_lt "$best" "$v"; then best=$v; fi
	done
	printf '%s' "$best"
}

# po_bump <version> <index>: <version> with segment <index> (0-based)
# incremented and every later one zeroed.
po_bump() {
	local -a s
	local i out=''
	IFS=. read -r -a s <<<"$1"
	s[$2]=$((10#${s[$2]} + 1))
	for ((i = $2 + 1; i < ${#s[@]}; i++)); do s[i]=0; done
	for i in "${!s[@]}"; do out+=${out:+.}$((10#${s[i]})); done
	printf '%s' "$out"
}

# po_next_number: the next sequential number (latest founded + 1).
po_next_number() {
	local base latest
	base=$(po_base_segments)
	latest=$(po_latest_founded "$base")
	[[ -n $latest ]] || po_die "the backlog founds no ${base}-segment item to continue from"
	po_bump "$latest" $((base - 1))
}

# po_check_number <version> <epoch>: refuse a number the sequential-at-
# founding law does not allow for a new item: the next number; with
# <epoch> = 1, a bump of an earlier segment instead (1.10.0, 2.0.0); or an
# insert, the next free last segment under a founded item (1.9.8.1).
po_check_number() {
	local v=$1 epoch=$2 base segs tag latest next i
	base=$(po_base_segments)
	segs=$(po_segments "$v")
	tag=$(po_fill "$(po_get versioning.tag)" "$v")
	if ((segs == base)); then
		latest=$(po_latest_founded "$base")
		[[ -n $latest ]] || po_refuse "the backlog founds no ${base}-segment item to continue from"
		next=$(po_bump "$latest" $((base - 1)))
		[[ $v == "$next" ]] && return 0
		if ((epoch)); then
			for ((i = 0; i < base - 1; i++)); do
				[[ $v == "$(po_bump "$latest" "$i")" ]] && return 0
			done
			po_refuse "$tag is not an epoch step from the latest founded $latest"
		fi
		po_refuse "$tag breaks the sequential-at-founding law: the latest founded is $latest, so the next is $next (--epoch for a new epoch)"
	fi
	local ins=${PO_MANIFEST[versioning.insert_segment]:-}
	if [[ -n $ins ]] && ((segs == ins)); then
		local parent=${v%.*} rec c last=0
		[[ -n $(po_item_statuses "$parent") ]] ||
			po_refuse "$tag inserts under $parent, which no backlog source records"
		for rec in "${PO_ITEMS[@]}"; do
			c=${rec%%$'\t'*}
			[[ $c == "$parent".* && $(po_segments "$c") == "$ins" ]] || continue
			((10#${c##*.} > last)) && last=$((10#${c##*.}))
		done
		[[ $v == "$parent.$((last + 1))" ]] && return 0
		po_refuse "$tag is not the next insert under $parent: that is $parent.$((last + 1))"
	fi
	po_refuse "$tag has $segs segments; sequential numbers have $base${ins:+, inserts $ins}"
}

# po_check_title <title>: a usage error for a title the heading cannot hold.
po_check_title() {
	[[ -n $1 && $1 != *[$'\t\n\r']* ]] || po_usage_die "a title must be one non-empty line"
	[[ $1 != *' — '* ]] || po_usage_die "a title cannot contain ' — ' (the heading separator)"
}

# po_check_free <version>: refuse when the item's branch, tag or worktree
# path is already taken.
po_check_free() {
	local branch tag path
	branch=$(po_fill "$(po_get layout.branch)" "$1")
	tag=$(po_fill "$(po_get versioning.tag)" "$1")
	path=$(po_new_worktree_path "$1")
	git show-ref --verify --quiet "refs/heads/$branch" && po_refuse "branch $branch already exists"
	git show-ref --verify --quiet "refs/tags/$tag" && po_refuse "tag $tag already exists"
	[[ ! -e $path && ! -L $path ]] || po_refuse "$(po_rel "$path") already exists"
	return 0
}

# po_new_worktree_path <version>: where the item's worktree is made.
po_new_worktree_path() {
	# shellcheck disable=SC2153 # set by po_worktrees_load
	printf '%s/%s/%s' "${PO_MAIN_WT%/}" "$(po_get layout.worktrees)" "$(po_fill "$(po_get layout.branch)" "$1")"
}

# po_main_checkout: the worktree with main checked out into PO_MAIN_CO,
# and what stops --commit writing there into PO_MAIN_CO_BLOCK (empty when
# nothing does).
po_main_checkout() {
	local main i busy n
	main=$(po_get layout.main)
	PO_MAIN_CO='' PO_MAIN_CO_BLOCK=''
	for i in "${!PO_WT_PATH[@]}"; do
		[[ ${PO_WT_BRANCH[i]} == "$main" ]] && PO_MAIN_CO=${PO_WT_PATH[i]}
	done
	if [[ -z $PO_MAIN_CO ]]; then
		PO_MAIN_CO_BLOCK="no worktree has $main checked out"
		return 0
	fi
	busy=$(po_wt_busy "$PO_MAIN_CO")
	# Tracked changes, staged or not, would mix into the admin commit or
	# sit under its edits; untracked files (the worktrees directory itself,
	# when it is not ignored) touch neither.
	n=$(git -C "$PO_MAIN_CO" --no-optional-locks status --porcelain --untracked-files=no | wc -l)
	if [[ -n $busy ]]; then
		PO_MAIN_CO_BLOCK="$busy in progress in $PO_MAIN_CO"
	elif ((n > 0)); then
		PO_MAIN_CO_BLOCK="$PO_MAIN_CO has tracked changes ($n)"
	fi
}

# po_author: who the admin commit will be by, from git's own config.
po_author() {
	local id
	id=$(git -C "${PO_MAIN_CO:-.}" var GIT_AUTHOR_IDENT 2>/dev/null) || return 1
	printf '%s' "${id% * *}"
}

# po_admin_message <file> <subject> <body-file>: the admin commit message.
# PO_EVIDENCE, when set, is quoted after the subject.
po_admin_message() {
	{
		printf '%s\n' "$2"
		if [[ -n ${PO_EVIDENCE:-} ]]; then
			printf '\n%s\n' "$PO_EVIDENCE_HEAD"
			printf '%s\n' "$PO_EVIDENCE"
		fi
		if [[ -n $3 ]]; then
			printf '\n'
			cat -- "$3"
		fi
	} >"$1"
}

# po_print_plan_tail <message-file>: the edits, notes and admin message.
po_print_plan_tail() {
	local x
	printf '\nEDITS (%s files)\n' "${#PO_EDIT_FILES[@]}"
	po_edit_diff
	if ((${#PO_EDIT_NOTES[@]} > 0)); then
		printf '\nNOTES\n'
		for x in "${PO_EDIT_NOTES[@]}"; do printf '  %s\n' "$x"; done
	fi
	printf '\nADMIN COMMIT MESSAGE\n'
	sed 's/^/  | /' "$1"
}

# po_commit_ready: refuse --commit when main's checkout cannot take the
# admin commit or no author is configured.
po_commit_ready() {
	[[ -z $PO_MAIN_CO_BLOCK ]] || po_refuse "--commit: $PO_MAIN_CO_BLOCK"
	po_author >/dev/null || po_refuse "--commit: git has no author identity (user.name / user.email) for $PO_MAIN_CO"
}

# po_readiness: the --commit readiness lines a dry run prints.
po_readiness() {
	local author
	printf '\nCOMMIT READINESS\n'
	if [[ -n $PO_MAIN_CO_BLOCK ]]; then
		printf '  main checkout  NOT READY: %s — --commit would refuse\n' "$PO_MAIN_CO_BLOCK"
	else
		printf '  main checkout  %s (clean)\n' "$PO_MAIN_CO"
	fi
	if author=$(po_author); then
		printf '  author         %s (git config)\n' "$author"
	else
		printf '  author         NOT SET — --commit would refuse\n'
	fi
}

# po_write_admin <message-file> <stop>: apply the planned edits in main's
# checkout and commit them; prints the new commit. <stop> says what has
# already been written, for the message when this fails.
po_write_admin() {
	po_edit_apply "$PO_MAIN_CO" "$2"
	git -C "$PO_MAIN_CO" commit -q -F "$1" ||
		po_die "stopped$2: the admin commit failed; the edits are staged in $PO_MAIN_CO — commit them with the message the plan printed"
	# The index holds the new blobs; bring the files in the checkout to them.
	local path
	for path in "${PO_EDIT_FILES[@]}"; do
		git -C "$PO_MAIN_CO" checkout-index -f -u -- "$path" ||
			po_die "stopped after the admin commit: could not refresh $path in $PO_MAIN_CO"
	done
	printf 'admin commit %s\n' "$(git -C "$PO_MAIN_CO" log -1 --format='%h %s')"
}

# po_make_worktree <version>: the item's branch and worktree at main's tip.
po_make_worktree() {
	local branch path main
	main=$(po_get layout.main)
	branch=$(po_fill "$(po_get layout.branch)" "$1")
	path=$(po_new_worktree_path "$1")
	git worktree add -q -b "$branch" "$path" "refs/heads/$main" ||
		po_die "stopped: could not create the worktree $path"
	printf 'branch %s + worktree %s at %s\n' "$branch" "$(po_rel "$path")" "$(po_short "refs/heads/$main")"
}
