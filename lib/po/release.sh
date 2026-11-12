# shellcheck shell=bash
# po version, po doctor, po release — which po-kit is installed, and whether every
# project that adopted it still works under it. Both read-only.
#
# The adopters list is ~/.config/po-kit/adopters: one repository path per
# line, a leading ~/ meaning $HOME, blank lines and lines starting with #
# skipped. bin/po-install installs a tag and runs po doctor after switching.

# po_version_string: the exact tag this checkout is at, else git's
# description of it (v0.10-3-g796ae94, -dirty when modified).
po_version_string() {
	local root
	root=$(dirname "$PO_LIB")
	root=$(dirname "$root")
	git -C "$root" describe --tags --exact-match HEAD 2>/dev/null ||
		git -C "$root" describe --tags --always --dirty 2>/dev/null ||
		po_die "cannot tell which version this is: $root is not a git checkout"
}

po_cmd_version() {
	(($# == 0)) || po_usage_die "version takes no arguments"
	po_version_string
}

# po_adopters_file: the path of the adopters list.
po_adopters_file() {
	printf '%s/.config/po-kit/adopters' "${HOME:?HOME is not set}"
}

# po_doctor_manifest <repo>: read <repo>'s manifest as it is on disk with
# this version's reader. Prints, on success, one "[section] key" line per
# optional key the manifest does not set; on failure the reader's message.
po_doctor_manifest() {
	local key sect name
	[[ -d $1 ]] || po_die "not a directory"
	cd "$1" || po_die "cannot enter it"
	git rev-parse --git-dir >/dev/null 2>&1 || po_die "not a git repository"
	po_worktrees_load
	po_manifest_load "$PO_MAIN_WT/po.toml"
	while IFS= read -r key; do
		[[ ${PO_SCHEMA[$key]} == 0 && -z ${PO_MANIFEST[$key]+x} ]] || continue
		# gate.command is the one-leg form of [gate.legs], not a missing setting.
		[[ $key != gate.command || ${#PO_GATE_LEGS[@]} == 0 ]] || continue
		sect=${key%.*} name=${key##*.}
		printf '[%s] %s\n' "$sect" "$name"
	done < <(printf '%s\n' "${!PO_SCHEMA[@]}" | sort)
}

po_cmd_doctor() {
	(($# == 0)) || po_usage_die "doctor takes no arguments"
	local file line path out code n=0 failed=0 adopt
	file=$(po_adopters_file)
	[[ -f $file ]] || po_die "no adopters list at $file (one repository path per line)"
	local -a paths=()
	while IFS= read -r line || [[ -n $line ]]; do
		line=$(po_trim "$line")
		[[ -z $line || $line == '#'* ]] && continue
		# shellcheck disable=SC2088 # matching the literal text "~/"
		[[ $line == '~/'* ]] && line=$HOME/${line#'~/'}
		paths+=("$line")
	done <"$file"
	printf 'po doctor  %s, %s adopters (%s)\n' "$(po_version_string)" "${#paths[@]}" "$file"
	for path in "${paths[@]}"; do
		n=$((n + 1))
		printf 'adopter   %s\n' "$path"
		code=0
		if [[ $path != /* ]]; then
			out="po: not an absolute path"
			code=2
		else
			out=$( (po_doctor_manifest "$path") 2>&1) || code=$?
		fi
		if ((code != 0)); then
			printf '  manifest  FAIL  %s\n' "${out%%$'\n'*}"
			failed=$((failed + 1))
			continue
		fi
		printf '  manifest  ok\n'
		code=0
		out=$("$PO_SELF" -C "$path" status 2>&1 >/dev/null) || code=$?
		case $code in
		0) printf '  status    ok\n' ;;
		3 | 8) printf '  status    ok (exit %s: the report says what is wrong with the backlog or the idle items)\n' "$code" ;;
		*)
			printf '  status    FAIL  exit %s: %s\n' "$code" "${out%%$'\n'*}"
			failed=$((failed + 1))
			continue
			;;
		esac
		while IFS= read -r adopt; do
			[[ -z $adopt ]] || printf '  adopt     %s\n' "$adopt"
		done < <( (po_doctor_manifest "$path") 2>/dev/null)
	done
	if ((failed > 0)); then
		printf 'doctor: FAILED  %s of %s adopters\n' "$failed" "$n"
		return 2
	fi
	printf 'doctor: ok  %s adopters\n' "$n"
}

# ---- po release <N> ---------------------------------------------------------
# The pre-release check for release-N. Under [release] review = true it
# refuses (exit 6) unless the backlog has a row "test review: ... release-N"
# in TODO, DOING or DONE; --open-review adds that row as an admin commit, as
# po open does (a dry run without --commit; idempotent). With the key off
# and no --open-review it prints nothing and changes nothing.

po_release_usage() {
	po_usage_die 'usage: po release <N> [--open-review] [--commit] | po release <N> --setup | po release <N> --write'
}

# po_release_review_row <N>: the version of an existing review row for
# release-N into PO_REVIEW_VERSION and its status into PO_REVIEW_STATUS;
# non-zero when there is none.
po_release_review_row() {
	local re rec v st title word
	re="(^|[^[:alnum:]._-])release-$(po_re_quote "$1")([^0-9.]|\.([^0-9]|\$)|\$)"
	PO_REVIEW_VERSION='' PO_REVIEW_STATUS=''
	for rec in "${PO_ITEMS[@]}"; do
		IFS=$'\t' read -r v st title _ <<<"$rec"
		[[ $title == "test review:"* && $title =~ $re ]] || continue
		word=${st%% *}
		word=${word^^}
		while [[ $word == *[[:punct:]] ]]; do word=${word%?}; done
		[[ $word == TODO || $word == DOING || $word == DONE ]] || continue
		PO_REVIEW_VERSION=$v PO_REVIEW_STATUS=$word
		return 0
	done
	return 1
}

# po_letters_bump <id>: the next spreadsheet-style id (Z -> AA, DS -> DT).
po_letters_bump() {
	local s=$1 out='' c carry=1 i alphabet=ABCDEFGHIJKLMNOPQRSTUVWXYZ
	for ((i = ${#s} - 1; i >= 0; i--)); do
		c=${s:i:1}
		if ((carry)); then
			if [[ $c == Z ]]; then
				c=A
			else
				c=${alphabet#*"$c"}
				c=${c:0:1}
				carry=0
			fi
		fi
		out=$c$out
	done
	((carry == 0)) || out=A$out
	printf '%s' "$out"
}

# po_edit_review_row <version> <title>: append "<version> <title> TODO" to
# the last backlog table with a Status column, filling that table's cells
# by position: the tag, the title after it, Status; a leading all-capitals
# id column continues the last row's; others stay empty. Sets PO_REVIEW_ROW.
po_edit_review_row() {
	local version=$1 title=$2 tpl tag backlog i j line in_table=0 status_col=-1 last=-1 last_status_col=-1
	local lastid='' tag_col=-1 ncols=0 row cell
	tpl=$(po_get versioning.tag)
	tag=$(po_fill "$tpl" "$version")
	backlog=$(po_get layout.backlog)
	po_edit_read "$backlog"
	for i in "${!PO_LINES[@]}"; do
		line=$(po_trim "${PO_LINES[i]}")
		if [[ $line != '|'* ]]; then
			in_table=0
			continue
		fi
		po_split_row "$line"
		if ((in_table == 0)); then
			in_table=1 status_col=-1
			for j in "${!PO_CELLS[@]}"; do
				[[ ${PO_CELLS[j]} == Status ]] && status_col=$j
			done
			continue
		fi
		((status_col >= 0)) || continue
		[[ $line != *'|---'* ]] || continue
		last=$i last_status_col=$status_col ncols=${#PO_CELLS[@]} lastid=${PO_CELLS[0]}
		tag_col=-1
		for j in "${!PO_CELLS[@]}"; do
			if po_unfill "$tpl" "${PO_CELLS[j]}" >/dev/null; then
				tag_col=$j
				break
			fi
		done
	done
	((last >= 0 && tag_col >= 0)) || po_die "$backlog has no table with a Status column and a row to continue"
	row='|'
	for ((j = 0; j < ncols; j++)); do
		if ((j == tag_col)); then
			cell=$tag
		elif ((j == tag_col + 1)); then
			cell=$title
		elif ((j == last_status_col)); then
			cell=TODO
		elif ((j == 0)) && [[ $lastid =~ ^[A-Z]+$ ]]; then
			cell=$(po_letters_bump "$lastid")
		else
			cell=''
		fi
		if [[ -n $cell ]]; then row+=" $cell |"; else row+="  |"; fi
	done
	PO_LINES=("${PO_LINES[@]:0:last+1}" "$row" "${PO_LINES[@]:last+1}")
	po_edit_write "$backlog"
	PO_REVIEW_ROW=$row
}

# po_release_setup <N> <write 0|1>: the entry's "Setup after install" block from the
# recorded steps of the items the entry names (po setup list --all), printed, or with
# write inserted under the "## Release N" heading of CHANGELOG.md (idempotent). Where
# [release] review = true the review row must exist first, as for po release <N>.
# A project on the tiered gate (v0.182) writes only with a full passing stamp of
# main's tip in the main checkout (po_release_full_stamp).
po_release_setup() {
	local top state
	top=$(git rev-parse --show-toplevel 2>/dev/null) || po_die "not a git repository"
	(($2 == 0)) || ! po_stamp_tiered || po_release_full_stamp "$1"
	if [[ ${PO_MANIFEST[release.review]:-false} == true ]]; then
		po_backlog_load
		po_release_review_row "$1" ||
			po_refuse "release-$1 has no pre-release review row (a TODO, DOING or DONE item titled \"test review: ... release-$1\"); run po release $1 --open-review"
	fi
	state=$(po_setup_file) || po_die "no git dir"
	po_setup_py block "$top/CHANGELOG.md" "$1" "$2" "$state" || exit $?
}

# po_release_full_stamp <N>: refuse unless the main checkout's newest full
# stamp names main's tip, clean, with a passing gate: the full suite runs before
# every release, whatever the items' fast stamps said. The release commit that
# follows touches only CHANGELOG.md.
po_release_full_stamp() {
	local main mtip stamp block first second
	main=$(po_get layout.main)
	mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") || po_die "no branch '$main' (manifest [layout] main)"
	stamp=$(po_stamp_newest "$PO_MAIN_WT" full)
	if [[ -n $stamp ]]; then
		block=$(<"$stamp")
		first=${block%%$'\n'*} second=${block#*$'\n'}
		second=${second%%$'\n'*}
		[[ $first == "HEAD $mtip ($main)  dirty 0" && $second == 'gate PASS: '* ]] && return 0
	fi
	po_refuse "release-$1 needs a full stamp at $(po_short "$mtip"): run po stamp --tier full in $PO_MAIN_WT"
}

po_cmd_release() {
	local commit=0 open_review=0 n='' setup=0 write=0
	while (($# > 0)); do
		case $1 in
		--commit) commit=1 ;;
		--open-review) open_review=1 ;;
		--setup) setup=1 ;;
		--write) write=1 ;;
		-*) po_usage_die "release: unknown argument '$1'" ;;
		*)
			[[ -z $n ]] || po_release_usage
			n=$1
			;;
		esac
		shift
	done
	[[ -n $n ]] || po_release_usage
	[[ $n =~ ^[0-9]+(\.[0-9]+)*$ ]] || po_usage_die "release: N must be a release number like 23 or 23.1: $n"
	((open_review || commit == 0)) || po_usage_die "release: --commit applies to --open-review"
	if ((setup || write)); then
		((open_review == 0 && commit == 0)) || po_usage_die "release: --setup and --write do not combine with --open-review or --commit"
		po_release_setup "$n" "$write"
		return
	fi
	local review=${PO_MANIFEST[release.review]:-false}
	[[ $review == true || $open_review == 1 ]] || return 0

	local main mtip title="test review: release-$n"
	main=$(po_get layout.main)
	mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") ||
		po_die "no branch '$main' (manifest [layout] main)"
	po_backlog_load
	local conflicts
	conflicts=$(po_backlog_conflicts)
	[[ -z $conflicts ]] || po_conflict "the backlog disagrees with itself (run po status): ${conflicts//$'\t'/ }"

	local tag
	if po_release_review_row "$n"; then
		tag=$(po_fill "$(po_get versioning.tag)" "$PO_REVIEW_VERSION")
		printf 'release-%s: review row %s exists (%s)\n' "$n" "$tag" "$PO_REVIEW_STATUS"
		return 0
	fi
	((open_review)) ||
		po_refuse "release-$n has no pre-release review row (a TODO, DOING or DONE item titled \"test review: ... release-$n\"); run po release $n --open-review"

	local version
	version=$(po_next_number)
	tag=$(po_fill "$(po_get versioning.tag)" "$version")
	po_edit_init "$mtip"
	po_edit_review_row "$version" "$title"
	po_edit_verify "$version:TODO"
	local msg=$PO_EDIT_DIR/message
	# shellcheck disable=SC2034 # read by po_admin_message
	PO_EVIDENCE=
	po_admin_message "$msg" "$(po_get versioning.admin_prefix) $tag $title founded TODO" ''
	po_main_checkout
	((commit == 0)) || po_commit_ready

	if ((commit)); then
		printf 'po release --commit: carrying out the plan below\n'
	else
		printf 'po release: DRY RUN — nothing changes without --commit\n'
	fi
	printf 'review    %s  %s  (new row, TODO)\n' "$tag" "$title"
	printf 'row       %s\n' "$PO_REVIEW_ROW"
	printf 'main      %s  %s (local; po never fetches or pushes)\n' "$main" "$(po_short "$mtip")"
	po_print_plan_tail "$msg"
	if ((commit == 0)); then
		po_readiness
		return 0
	fi
	printf '\n'
	[[ $(git rev-parse "refs/heads/$main") == "$mtip" ]] || po_die "stopped before any write: $main moved since the plan"
	po_write_admin "$msg" ''
}
