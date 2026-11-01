# shellcheck shell=bash
# po-kit: setup after install.
#
# Every item spec carries a "Setup after install" section: the word None, or a
# table | # | Machine | Command | Who | Check | with one row per step. With
# [close] require_setup = true, po close refuses an item whose spec lacks it
# (exit 6), unless the item was founded before the key was on: the manifest at
# its founding commit decides (no founding commit found, or a manifest outside
# the repository: not exempt). po close --commit records the steps as open in
# po-setup-steps.json in the common git dir; `po setup confirm` closes them.
#
# Where the section is looked for, at a given revision, first hit wins:
#   1. inside the item's spec sections, found as po kickoff finds them;
#   2. in any .md file the item's backlog row names in `backticks`.
#
#   po setup list [--item <version>] [--all] [--json]   read-only
#   po setup confirm <version> <n> --by <who>           anyone: the one who did it
#   po setup record <version> [--commit]                the PO's: re-record from the item tag

PO_SETUP_STATE_NAME=po-setup-steps.json

# po_setup_file: the state file's absolute path.
po_setup_file() {
	local dir
	dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	printf '%s/%s' "$dir" "$PO_SETUP_STATE_NAME"
}

po_setup_py() {
	command -v python3 >/dev/null 2>&1 || po_die "setup after install needs python3"
	python3 -I "$PO_LIB/setup.py" "$@"
}

# po_setup_mode <version> <main tip>: PO_SETUP_MODE = off (no [close]
# require_setup = true), exempt (founded before the key was on) or on.
po_setup_mode() {
	local v=$1 mtip=$2 found rel tmp
	PO_SETUP_MODE=off
	[[ ${PO_MANIFEST[close.require_setup]:-false} == true ]] || return 0
	PO_SETUP_MODE=on
	found=$(po_kickoff_founding "$v" "$mtip" && printf '%s' "$PO_KO_FOUND")
	[[ -n $found ]] || return 0
	po_under "$PO_MANIFEST_FILE" "$PO_MAIN_WT" || return 0
	rel=${PO_MANIFEST_FILE#"${PO_MAIN_WT%/}/"}
	if [[ $(git cat-file -t "$found:$rel" 2>/dev/null) != blob ]]; then
		PO_SETUP_MODE=exempt
		return 0
	fi
	tmp=$(mktemp "${TMPDIR:-/tmp}/po-setup-manifest.XXXXXX") || po_die "cannot make a temporary file"
	git show "$found:$rel" >"$tmp"
	(po_manifest_load "$tmp" >/dev/null 2>&1 && [[ ${PO_MANIFEST[close.require_setup]:-false} == true ]]) ||
		PO_SETUP_MODE=exempt
	rm -f -- "$tmp"
}

# po_setup_spec <version> <rev>: find and parse the item's section at <rev>.
# PO_SETUP_KIND = absent | none | steps | bad; PO_SETUP_WHERE = file:line;
# PO_SETUP_ERR the reason for bad; PO_SETUP_STEPS the steps as JSON;
# PO_SETUP_LOOKED the places searched.
po_setup_spec() {
	local v=$1 rev=$2 rec file first last out backlog where row p
	local -a files=()
	PO_SETUP_KIND=absent PO_SETUP_WHERE='' PO_SETUP_ERR='' PO_SETUP_STEPS='[]' PO_SETUP_LOOKED=''
	po_kickoff_sections "$v" "$rev"
	for rec in "${PO_KO_SECTIONS[@]}"; do
		IFS=$'\t' read -r file first last <<<"$rec"
		PO_SETUP_LOOKED+="${PO_SETUP_LOOKED:+, }$file:$first-$last"
		out=$(git show "$rev:$file" | sed -n "${first},${last}p" | po_setup_py parse "$first") || po_die "could not read $file"
		po_setup_take "$file" "$out" && return 0
	done
	# 2. Files the row names.
	backlog=$(po_get layout.backlog)
	for rec in "${PO_ITEMS[@]}"; do
		[[ ${rec%%$'\t'*} == "$v" ]] || continue
		where=${rec##*$'\t'}
		[[ ${where%:*} == "$backlog" ]] || continue
		row=$(git show "$rev:$backlog" 2>/dev/null | sed -n "${where##*:}p")
		# shellcheck disable=SC2016 # backticks, not an expansion
		while IFS= read -r p; do
			[[ -n $p ]] && files+=("$p")
		done < <(grep -oE '`[^`]+\.md`' <<<"$row" | tr -d '`')
	done
	for file in "${files[@]}"; do
		[[ $(git cat-file -t "$rev:$file" 2>/dev/null) == blob ]] || continue
		[[ ", $PO_SETUP_LOOKED, " == *", $file, "* ]] && continue
		PO_SETUP_LOOKED+="${PO_SETUP_LOOKED:+, }$file"
		out=$(git show "$rev:$file" | po_setup_py parse 1) || po_die "could not read $file"
		po_setup_take "$file" "$out" && return 0
	done
	return 0
}

# po_setup_take <file> <parse json>: success when the parse found the heading.
po_setup_take() {
	local f
	f=$(python3 -I -c 'import json,sys
d = json.loads(sys.argv[1])
if not d["found"]:
    sys.exit(1)
print(d["kind"]); print(d["line"]); print(d["error"]); print(json.dumps(d["steps"]))' "$2") || return 1
	{
		IFS= read -r PO_SETUP_KIND
		IFS= read -r PO_SETUP_WHERE
		IFS= read -r PO_SETUP_ERR
		IFS= read -r PO_SETUP_STEPS
	} <<<"$f"
	PO_SETUP_WHERE="$1:$PO_SETUP_WHERE"
}

# po_setup_count: the number of steps in PO_SETUP_STEPS.
po_setup_count() {
	python3 -I -c 'import json,sys; print(len(json.loads(sys.argv[1])))' "$PO_SETUP_STEPS"
}

# po_setup_check <version> <tag> <main tip> <rev>: the close's check. Refuses
# (exit 6) when the item needs the section and it is missing or malformed.
# Leaves PO_SETUP_MODE and, when a section is used, PO_SETUP_KIND/STEPS.
po_setup_check() {
	local v=$1 tag=$2 mtip=$3 rev=$4
	PO_SETUP_KIND=absent PO_SETUP_STEPS='[]' PO_SETUP_WHERE=''
	po_setup_mode "$v" "$mtip"
	[[ $PO_SETUP_MODE != off ]] || return 0
	po_setup_spec "$v" "$rev"
	if [[ $PO_SETUP_MODE == on ]]; then
		[[ $PO_SETUP_KIND != absent ]] ||
			po_refuse "$tag's spec has no \"Setup after install\" section (looked in: ${PO_SETUP_LOOKED:-no spec section found}); write its steps, or the word None"
		[[ $PO_SETUP_KIND != bad ]] ||
			po_refuse "$tag's \"Setup after install\" section (${PO_SETUP_WHERE}): $PO_SETUP_ERR"
	elif [[ $PO_SETUP_KIND == absent || $PO_SETUP_KIND == bad ]]; then
		# Exempt: a missing or malformed section is not used.
		PO_SETUP_KIND=absent PO_SETUP_STEPS='[]'
	fi
}

# po_setup_plan_line: the close plan's one-line summary (after evidence).
po_setup_plan_line() {
	case $PO_SETUP_MODE in
	off) return 0 ;;
	exempt)
		if [[ $PO_SETUP_KIND == steps ]]; then
			printf 'setup     %s step(s) (%s); exempt: founded before [close] require_setup\n' "$(po_setup_count)" "$PO_SETUP_WHERE"
		else
			printf 'setup     exempt: founded before [close] require_setup\n'
		fi
		;;
	on)
		if [[ $PO_SETUP_KIND == none ]]; then
			printf 'setup     None (%s)\n' "$PO_SETUP_WHERE"
		else
			printf 'setup     %s step(s) (%s)\n' "$(po_setup_count)" "$PO_SETUP_WHERE"
		fi
		;;
	esac
}

# po_setup_plan_block: the SETUP block, steps grouped by machine and who.
po_setup_plan_block() {
	[[ $PO_SETUP_KIND == steps ]] || return 0
	printf '\nSETUP (%s step(s); recorded open by --commit, open until po setup confirm)\n' "$(po_setup_count)"
	po_setup_py plan "$PO_SETUP_STEPS"
}

# po_setup_record_steps <version>: write PO_SETUP_STEPS as open; non-zero on failure.
po_setup_record_steps() {
	local state tmp code=0
	[[ $PO_SETUP_KIND == steps ]] || return 0
	state=$(po_setup_file) || return 1
	tmp=$(mktemp "${TMPDIR:-/tmp}/po-setup-steps.XXXXXX") || return 1
	printf '%s\n' "$PO_SETUP_STEPS" >"$tmp"
	po_setup_py record "$state" "$1" "$tmp" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || code=$?
	rm -f -- "$tmp"
	return "$code"
}

po_setup_usage() {
	po_usage_die "usage: po setup list [--item <version>] [--all] [--json] | po setup confirm <version> <n> --by <who> | po setup record <version> [--commit]"
}

po_cmd_setup() {
	(($# > 0)) || po_setup_usage
	local sub=$1
	shift
	case $sub in
	list) po_setup_list "$@" ;;
	confirm) po_setup_confirm "$@" ;;
	record) po_setup_record "$@" ;;
	*) po_setup_usage ;;
	esac
}

po_setup_list() {
	local item=- all=0 json=0 state
	while (($# > 0)); do
		case $1 in
		--item)
			(($# >= 2)) || po_usage_die "setup list: --item needs a version"
			item=$(po_version_arg setup "$2")
			shift
			;;
		--all) all=1 ;;
		--json) json=1 ;;
		*) po_usage_die "setup list: unknown argument '$1'" ;;
		esac
		shift
	done
	state=$(po_setup_file) || po_die "no git dir"
	po_setup_py list "$state" "$item" "$all" "$json" "$(po_get versioning.tag)" || exit 2
}

po_setup_confirm() {
	local v='' n='' by='' state code=0 tag
	while (($# > 0)); do
		case $1 in
		--by)
			(($# >= 2)) || po_usage_die "setup confirm: --by needs a name"
			by=$2
			shift
			;;
		-*) po_usage_die "setup confirm: unknown argument '$1'" ;;
		*)
			if [[ -z $v ]]; then
				v=$(po_version_arg setup "$1")
			elif [[ -z $n ]]; then
				n=$1
			else
				po_setup_usage
			fi
			;;
		esac
		shift
	done
	[[ -n $v && -n $n ]] || po_setup_usage
	[[ $n =~ ^[1-9][0-9]*$ ]] || po_usage_die "setup confirm: the step number must be 1, 2, 3...: $n"
	[[ -n $by ]] || po_usage_die "setup confirm: --by <who> is required (the one who did the step)"
	[[ $by != *[$'\t\n\r']* ]] || po_usage_die "setup confirm: --by must be one line"
	tag=$(po_fill "$(po_get versioning.tag)" "$v")
	state=$(po_setup_file) || po_die "no git dir"
	po_setup_py confirm "$state" "$v" "$n" "$by" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || code=$?
	case $code in
	0)
		printf 'confirmed %s step %s (by %s)\n' "$tag" "$n" "$by"
		po_event_log setup "$v" pass '' "step $n confirmed by $by"
		;;
	3) return 0 ;;
	1) po_usage_die "setup confirm: $tag has no recorded step $n (po setup list --item $v --all)" ;;
	*) exit 2 ;;
	esac
}

po_setup_record() {
	local v='' commit=0 tag rev
	while (($# > 0)); do
		case $1 in
		--commit) commit=1 ;;
		-*) po_usage_die "setup record: unknown argument '$1'" ;;
		*)
			[[ -z $v ]] || po_setup_usage
			v=$(po_version_arg setup "$1")
			;;
		esac
		shift
	done
	[[ -n $v ]] || po_setup_usage
	tag=$(po_fill "$(po_get versioning.tag)" "$v")
	rev=$(git rev-parse -q --verify "refs/tags/$tag^{commit}") || po_die "no tag $tag: setup record reads a closed item's spec at its tag"
	po_backlog_load "$rev"
	po_setup_spec "$v" "$rev"
	case $PO_SETUP_KIND in
	absent) po_die "$tag's spec has no \"Setup after install\" section (looked in: ${PO_SETUP_LOOKED:-no spec section found})" ;;
	bad) po_die "$tag's \"Setup after install\" section ($PO_SETUP_WHERE): $PO_SETUP_ERR" ;;
	none)
		printf 'setup     None (%s); nothing to record\n' "$PO_SETUP_WHERE"
		return 0
		;;
	esac
	po_setup_plan_block
	if ((commit == 0)); then
		printf '\npo setup record: DRY RUN — nothing written without --commit\n'
		return 0
	fi
	po_setup_record_steps "$v" || po_die "could not write $(po_setup_file)"
	printf 'recorded %s setup step(s) for %s (confirmed ones kept)\n' "$(po_setup_count)" "$tag"
}
