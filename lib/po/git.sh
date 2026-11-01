# shellcheck shell=bash
# po-kit: read-only views of the repository's worktrees and branches.
#
# Nothing here writes: worktree dirtiness is read with
# `git --no-optional-locks status`, which never refreshes an index.

# PO_WT_*: parallel arrays, one entry per registered worktree, in
# `git worktree list` order (the main worktree first).
PO_WT_PATH=()
PO_WT_HEAD=()
PO_WT_BRANCH=() # short branch name, or empty when detached
PO_WT_FLAGS=()  # space-separated: bare locked prunable
# shellcheck disable=SC2034 # read by status.sh, prune.sh and bin/po
PO_MAIN_WT=

po_worktrees_load() {
	local line path='' head='' branch='' flags=''
	PO_WT_PATH=() PO_WT_HEAD=() PO_WT_BRANCH=() PO_WT_FLAGS=()
	_po_wt_flush() {
		[[ -n $path ]] || return 0
		PO_WT_PATH+=("$path")
		PO_WT_HEAD+=("$head")
		PO_WT_BRANCH+=("$branch")
		PO_WT_FLAGS+=("${flags# }")
		path='' head='' branch='' flags=''
	}
	while IFS= read -r line; do
		case $line in
		'worktree '*) path=${line#worktree } ;;
		'HEAD '*) head=${line#HEAD } ;;
		'branch refs/heads/'*) branch=${line#branch refs/heads/} ;;
		'branch '*) po_die "worktree $path is on a non-branch ref: ${line#branch }" ;;
		detached) ;;
		bare) flags+=' bare' ;;
		locked | 'locked '*) flags+=' locked' ;;
		prunable | 'prunable '*) flags+=' prunable' ;;
		'') _po_wt_flush ;;
		*) po_die "unrecognised 'git worktree list --porcelain' line: $line" ;;
		esac
	done < <(git worktree list --porcelain)
	_po_wt_flush
	unset -f _po_wt_flush
	((${#PO_WT_PATH[@]} > 0)) || po_die "git lists no worktrees"
	# shellcheck disable=SC2034 # read by status.sh, prune.sh and bin/po
	PO_MAIN_WT=${PO_WT_PATH[0]}
}

# po_wt_probe <path>: one `git status -z` of the worktree, read once into
# PO_PROBE_DIRTY[path] (the entry count: tracked changes and untracked
# files; ignored files do not count) and PO_PROBE_MTIME[path] (the newest
# mtime among the changed and untracked files, 0 when none; a deleted file
# has none). Later calls for the same path reuse it: one `po status` run
# reads a worktree's state once, however many lines show it.
declare -A PO_PROBE_DIRTY=() PO_PROBE_MTIME=()
po_wt_probe() {
	local wt=$1 entry code path t n=0 newest=0
	[[ -z ${PO_PROBE_DIRTY[$wt]+x} ]] || return 0
	while IFS= read -r -d '' entry; do
		code=${entry:0:2}
		path=${entry:3}
		n=$((n + 1))
		[[ $code == *[RC]* ]] && IFS= read -r -d '' _ # the source of a rename
		[[ -e $wt/$path || -L $wt/$path ]] || continue
		t=$(stat -c %Y "$wt/$path") && ((t > newest)) && newest=$t
	done < <(git -C "$wt" --no-optional-locks -c core.quotePath=false status --porcelain -z --untracked-files=all)
	PO_PROBE_DIRTY[$wt]=$n
	# shellcheck disable=SC2034 # read by status.sh
	PO_PROBE_MTIME[$wt]=$newest
}

# po_wt_dirty <path>: the number of changed and untracked entries.
po_wt_dirty() {
	po_wt_probe "$1"
	printf '%s\n' "${PO_PROBE_DIRTY[$1]}"
}

# po_wt_ignored <path>: the number of ignored files and directories (a
# directory counts once; an empty one, holding nothing to lose, not at all —
# cargo leaves an empty target/ even under CARGO_TARGET_DIR). `git worktree
# remove` deletes them without asking, so prune and close keep a worktree
# that has any.
po_wt_ignored() {
	git -C "$1" --no-optional-locks ls-files --others --ignored --exclude-standard --directory --no-empty-directory | wc -l
}

# po_wt_busy <path>: the name of the git operation stopped part-way in this
# worktree (rebase, merge, cherry-pick, revert, bisect), or nothing.
po_wt_busy() {
	local name gp
	for name in rebase-merge:rebase rebase-apply:rebase MERGE_HEAD:merge \
		CHERRY_PICK_HEAD:cherry-pick REVERT_HEAD:revert BISECT_LOG:bisect; do
		gp=$(git -C "$1" rev-parse --path-format=absolute --git-path "${name%%:*}")
		if [[ -e $gp ]]; then
			printf '%s' "${name#*:}"
			return 0
		fi
	done
}

# po_wt_rebasing_branch <path>: the branch a stopped rebase in this
# worktree will return to (git lists such a worktree as detached), or
# nothing.
po_wt_rebasing_branch() {
	local dir gp head
	for dir in rebase-merge rebase-apply; do
		gp=$(git -C "$1" rev-parse --path-format=absolute --git-path "$dir/head-name")
		if [[ -f $gp ]]; then
			head=$(<"$gp")
			[[ $head == refs/heads/* ]] && printf '%s' "${head#refs/heads/}"
			return 0
		fi
	done
}

# po_ahead_behind <ref> <main>: "<ahead> <behind>" of <ref> against <main>.
po_ahead_behind() {
	local counts
	counts=$(git rev-list --left-right --count "$1...$2")
	printf '%s %s' "${counts%%[[:blank:]]*}" "${counts##*[[:blank:]]}"
}

# po_merged <commit> <main>: success when <commit> is reachable from <main>.
po_merged() {
	git merge-base --is-ancestor "$1" "$2"
}

# po_under <path> <dir>: success when <path> lies strictly inside <dir>.
po_under() {
	[[ $1 == "${2%/}/"* ]]
}

po_short() {
	git rev-parse --short "$1"
}

# po_latest_tag <main>: the highest-versioned tag in the manifest's tag
# form (versioning.tag filled with a dotted number, nothing else) that is
# reachable from <main>, or empty.
po_latest_tag() {
	local tpl t
	tpl=$(po_get versioning.tag)
	while IFS= read -r t; do
		if po_unfill "$tpl" "$t" >/dev/null; then
			printf '%s' "$t"
			return 0
		fi
	done < <(git tag --merged "$1" --sort=-v:refname)
}
