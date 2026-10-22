# shellcheck shell=bash
# po-kit: the backlog edits po open and po close make, planned before
# anything is written.
#
# Every edit is planned against the content of one commit (`git show
# <rev>:<path>`) in a scratch directory outside the repository; the plan
# shown is the unified diff of those copies. --commit later checks each file
# in the worktree is still byte-for-byte the planned base before replacing it.
#
# The only text the kit writes into the backlog sources is status words and
# one founding heading line:
#   - a spec heading's status word      ## v1.9.9 — Title — DOING   -> DONE
#   - a backlog table row's Status cell | DOING |                   -> | DONE |
#   - a backlog prose mention           v1.9.11 parser TODO (...)   -> DOING (...)
#                                       v1.9.10 DOING; spec         -> DONE (tag v1.9.10); spec
#   - a founding heading                ## v1.9.12 — Title — DOING
# Each edit is anchored on the item's id in tag form and the status it
# expects to find. Anything else — two candidates, another status, a prose
# status that wraps onto the next line — stops with exit 3 naming file and
# line: the PO edits by hand.

PO_EDIT_DIR=
PO_EDIT_REV=
PO_EDIT_FILES=()         # repo paths with a planned edit, first-touched order
declare -gA PO_EDIT_N=() # repo path -> scratch file number
PO_EDIT_NOTES=()         # sources that carry no record of an edited item
PO_EF=

po_conflict() {
	printf 'po: %s\n' "$*" >&2
	exit 3
}

# po_edit_init <rev>: start a plan against <rev>.
po_edit_init() {
	PO_EDIT_REV=$1
	PO_EDIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/po-edit.XXXXXX") || po_die "cannot make a scratch directory"
	# shellcheck disable=SC2064 # expand now: the directory is fixed
	trap "rm -rf -- '$PO_EDIT_DIR'" EXIT
	PO_EDIT_FILES=() PO_EDIT_NOTES=()
	PO_EDIT_N=()
}

# po_edit_file <path>: set PO_EF to the scratch copy of <path>, made from
# the plan's rev on first use. Call it directly, never inside $(...): the
# path -> copy map must survive.
po_edit_file() {
	local path=$1 n
	if [[ -z ${PO_EDIT_N[$path]+x} ]]; then
		n=${#PO_EDIT_N[@]}
		PO_EDIT_N[$path]=$n
		git show "$PO_EDIT_REV:$path" >"$PO_EDIT_DIR/$n.old" 2>/dev/null ||
			po_die "cannot read $path at $PO_EDIT_REV"
		cp -- "$PO_EDIT_DIR/$n.old" "$PO_EDIT_DIR/$n.new"
	fi
	PO_EF=$PO_EDIT_DIR/${PO_EDIT_N[$path]}.new
}

# po_edit_read <path>: the planned content of <path> into PO_LINES, and
# whether it ends in a newline into PO_LINES_NL.
po_edit_read() {
	po_edit_file "$1"
	PO_LINES=()
	PO_LINES_NL=1
	[[ -s $PO_EF ]] || return 0
	mapfile -t PO_LINES <"$PO_EF"
	[[ $(tail -c 1 -- "$PO_EF" | od -An -c) == *'\n'* ]] || PO_LINES_NL=0
}

# po_edit_write <path>: PO_LINES back into the scratch copy of <path>.
po_edit_write() {
	local p
	po_edit_file "$1"
	if ((${#PO_LINES[@]} == 0)); then
		: >"$PO_EF"
	elif ((PO_LINES_NL)); then
		printf '%s\n' "${PO_LINES[@]}" >"$PO_EF"
	else
		printf '%s\n' "${PO_LINES[@]:0:${#PO_LINES[@]}-1}" >"$PO_EF"
		printf '%s' "${PO_LINES[-1]}" >>"$PO_EF"
	fi
	for p in "${PO_EDIT_FILES[@]}"; do
		[[ $p == "$1" ]] && return 0
	done
	PO_EDIT_FILES+=("$1")
}

# po_re_quote <text>: <text> as a literal ERE.
po_re_quote() {
	local s=$1 out='' c i
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
		[][\\.^\$*+?\(\)\{\}\|/]) out+="\\$c" ;;
		*) out+=$c ;;
		esac
	done
	printf '%s' "$out"
}

# po_spec_files: the *.md files of [layout] specs_dir at the plan's rev.
po_spec_files() {
	git ls-tree -z --name-only "$PO_EDIT_REV" -- "$(po_get layout.specs_dir)/" |
		tr '\0' '\n' | grep '\.md$' || true
}

# po_version_lt <a> <b>: success when dotted version <a> sorts before <b>;
# a missing segment sorts first (1.9.12 < 1.9.12.1).
po_version_lt() {
	local -a a b
	local i x y
	IFS=. read -r -a a <<<"$1"
	IFS=. read -r -a b <<<"$2"
	for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
		x=${a[i]:--1} y=${b[i]:--1}
		((x < 0)) || x=$((10#$x))
		((y < 0)) || y=$((10#$y))
		((x < y)) && return 0
		((x > y)) && return 1
	done
	return 1
}

# po_heading_parse <line>: for an item heading, PO_H_ID (tag form),
# PO_H_TITLE, PO_H_STATUS, PO_H_SEGS (the " — " segments after the id) and
# PO_H_SEG (the status segment's index); non-zero for any other line. The
# same reading as po_backlog_headings, which reports malformed headings.
po_heading_parse() {
	local line=$1 prefix rest i word
	[[ $line == '## '* ]] || return 1
	prefix=$(po_get versioning.tag)
	prefix=${prefix%%\{version\}*}
	[[ $line == "## $prefix"[0-9]* ]] || return 1
	PO_H_ID=${line#'## '}
	PO_H_ID=${PO_H_ID%%[[:blank:]]*}
	rest=${line#"## $PO_H_ID"}
	[[ $rest == ' — '* ]] || return 1
	rest=${rest#' — '}
	PO_H_SEGS=()
	while [[ $rest == *' — '* ]]; do
		PO_H_SEGS+=("${rest%%' — '*}")
		rest=${rest#*' — '}
	done
	PO_H_SEGS+=("$rest")
	PO_H_TITLE=${PO_H_SEGS[0]} PO_H_STATUS='' PO_H_SEG=-1
	for ((i = 1; i < ${#PO_H_SEGS[@]}; i++)); do
		word=${PO_H_SEGS[i]%%[[:blank:]]*}
		if [[ $word =~ ^[A-Z]{2,}$ ]]; then
			[[ -z $PO_H_STATUS ]] || return 1
			PO_H_STATUS=$word PO_H_SEG=$i
		elif [[ -z $PO_H_STATUS ]]; then
			PO_H_TITLE+=" — ${PO_H_SEGS[i]}"
		fi
	done
	[[ -n $PO_H_STATUS ]]
}

# po_edit_heading <version> <from> <to>: flip the status word of the
# item's one spec heading. Non-zero when no spec file has a heading for it.
po_edit_heading() {
	local version=$1 from=$2 to=$3 tag file i hit_file='' hit_line=-1 n=0
	tag=$(po_fill "$(po_get versioning.tag)" "$version")
	while IFS= read -r file; do
		[[ -n $file ]] || continue
		po_edit_read "$file"
		for i in "${!PO_LINES[@]}"; do
			po_heading_parse "${PO_LINES[i]}" || continue
			[[ $PO_H_ID == "$tag" ]] || continue
			n=$((n + 1)) hit_file=$file hit_line=$i
		done
	done < <(po_spec_files)
	((n > 0)) || return 1
	((n == 1)) || po_conflict "$tag has $n headings in $(po_get layout.specs_dir); edit by hand"
	po_edit_read "$hit_file"
	po_heading_parse "${PO_LINES[hit_line]}"
	[[ $PO_H_STATUS == "$from" ]] ||
		po_conflict "$hit_file:$((hit_line + 1)): the $tag heading says $PO_H_STATUS, expected $from"
	local seg=${PO_H_SEGS[PO_H_SEG]} line="## $PO_H_ID"
	PO_H_SEGS[PO_H_SEG]=$to${seg#"$from"}
	for i in "${!PO_H_SEGS[@]}"; do
		line+=" — ${PO_H_SEGS[i]}"
	done
	PO_LINES[hit_line]=$line
	po_edit_write "$hit_file"
}

# po_edit_table <version> <from> <to>: flip the Status cell of the item's
# backlog table row. Non-zero when no table row names it.
po_edit_table() {
	local version=$1 from=$2 to=$3 tpl tag backlog i j line in_table=0 status_col=-1 col=-1 hit=-1 n=0
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
		# The row's item is its first cell in tag form, as the reader has
		# it; the tag in any later column (an "after" or "depends" cell)
		# names some other item's row.
		for j in "${!PO_CELLS[@]}"; do
			po_unfill "$tpl" "${PO_CELLS[j]}" >/dev/null || continue
			if [[ ${PO_CELLS[j]} == "$tag" ]]; then
				n=$((n + 1)) hit=$i col=$status_col
			fi
			break
		done
	done
	((n > 0)) || return 1
	((n == 1)) || po_conflict "$backlog: $tag has $n table rows; edit by hand"
	# Rebuild the row with only the Status cell's word replaced.
	local raw=${PO_LINES[hit]} lead out cell k=0
	lead=${raw%%'|'*}
	raw=${raw#*'|'}
	out="$lead|"
	while [[ $raw == *'|'* ]]; do
		cell=${raw%%'|'*}
		raw=${raw#*'|'}
		if ((k == col)); then
			[[ $(po_trim "$cell") == "$from" ]] ||
				po_conflict "$backlog:$((hit + 1)): the $tag row says '$(po_trim "$cell")', expected $from"
			cell=${cell/"$from"/"$to"}
		fi
		out+="$cell|"
		k=$((k + 1))
	done
	PO_LINES[hit]=$out$raw
	po_edit_write "$backlog"
}

PO_PROSE_STATUSES='TODO|DOING|DONE|PAUSED|BLOCKED'

# po_edit_prose <version> <from> <to>: in the backlog's lines outside
# tables, replace the one status word that follows the item's id —
# directly or after one word, "v1.9.11 parser TODO" — with <to>. Non-zero
# when the backlog has no such mention.
po_edit_prose() {
	local version=$1 from=$2 to=$3 tag backlog re wrap i n=0 hit=-1 hit_status='' line rest
	tag=$(po_fill "$(po_get versioning.tag)" "$version")
	backlog=$(po_get layout.backlog)
	re="(^|[^[:alnum:]._/-])($(po_re_quote "$tag")( [[:alnum:]-]+)? )($PO_PROSE_STATUSES)([^[:alnum:]]|$)"
	wrap="(^|[^[:alnum:]._/-])$(po_re_quote "$tag")( [[:alnum:]-]+)?[[:blank:]]*$"
	po_edit_read "$backlog"
	for i in "${!PO_LINES[@]}"; do
		line=${PO_LINES[i]}
		[[ $(po_trim "$line") == '|'* ]] && continue
		rest=$line
		while [[ $rest =~ $re ]]; do
			n=$((n + 1)) hit=$i hit_status=${BASH_REMATCH[4]}
			rest=${rest#*"${BASH_REMATCH[0]}"}
		done
		if [[ $line =~ $wrap ]] && ((i + 1 < ${#PO_LINES[@]})) &&
			[[ ${PO_LINES[i + 1]} =~ ^[[:blank:]]*(\*\*)?($PO_PROSE_STATUSES)([^[:alnum:]]|$) ]]; then
			po_conflict "$backlog:$((i + 1)): the status after $tag wraps onto the next line; edit by hand"
		fi
	done
	((n > 0)) || return 1
	((n == 1)) || po_conflict "$backlog: $tag is followed by a status $n times; edit by hand"
	[[ $hit_status == "$from" ]] ||
		po_conflict "$backlog:$((hit + 1)): the prose says $tag … $hit_status, expected $from"
	line=${PO_LINES[hit]}
	[[ $line =~ $re ]]
	local whole=${BASH_REMATCH[0]} keep=${BASH_REMATCH[1]}${BASH_REMATCH[2]} after=${BASH_REMATCH[5]}
	local tail=${line#*"$whole"}
	# A parenthetical <to> meeting one already there becomes one:
	# "DOING (Sam)" -> "DONE (tag v1.9.11; Sam)", not "DONE (tag v1.9.11) (Sam)".
	if [[ $to == *')' && $after == ' ' && $tail == '('* ]]; then
		PO_LINES[hit]=${line/"$whole("/"$keep${to%)}; "}
	else
		PO_LINES[hit]=${line/"$whole"/"$keep$to$after"}
	fi
	po_edit_write "$backlog"
}

# po_edit_status <version> <from> <to> [<prose-to>]: flip every source that
# records the item — its heading, its table row, its prose mention (written
# <prose-to>, default <to>). Sources with no record are noted; exit 3 when
# none records it.
po_edit_status() {
	local version=$1 from=$2 to=$3 prose_to=${4:-$3} tag found=0
	tag=$(po_fill "$(po_get versioning.tag)" "$version")
	if po_edit_heading "$version" "$from" "$to"; then
		found=1
	else
		PO_EDIT_NOTES+=("$tag: no heading in $(po_get layout.specs_dir)")
	fi
	if po_edit_table "$version" "$from" "$to"; then
		found=1
	else
		PO_EDIT_NOTES+=("$tag: no table row in $(po_get layout.backlog)")
	fi
	if po_edit_prose "$version" "$from" "$prose_to"; then
		found=1
	else
		PO_EDIT_NOTES+=("$tag: no status in $(po_get layout.backlog) prose")
	fi
	((found)) || po_conflict "$tag: no backlog source records it"
}

# po_edit_found <version> <title>: add "## <tag> — <title> — DOING" to the
# spec file holding the closest lower version, before the first heading
# above <version> there (at the end when there is none). Sets PO_FOUND_FILE.
po_edit_found() {
	local version=$1 title=$2 tpl tag file i v best='' best_file='' at heading
	tpl=$(po_get versioning.tag)
	tag=$(po_fill "$tpl" "$version")
	while IFS= read -r file; do
		[[ -n $file ]] || continue
		po_edit_read "$file"
		for i in "${!PO_LINES[@]}"; do
			po_heading_parse "${PO_LINES[i]}" || continue
			v=$(po_unfill "$tpl" "$PO_H_ID") || continue
			po_version_lt "$v" "$version" || continue
			if [[ -z $best ]] || po_version_lt "$best" "$v"; then
				best=$v best_file=$file
			fi
		done
	done < <(po_spec_files)
	[[ -n $best_file ]] ||
		po_die "no heading below $tag in $(po_get layout.specs_dir) to found it beside"
	po_edit_read "$best_file"
	at=${#PO_LINES[@]}
	for i in "${!PO_LINES[@]}"; do
		po_heading_parse "${PO_LINES[i]}" || continue
		v=$(po_unfill "$tpl" "$PO_H_ID") || continue
		if po_version_lt "$version" "$v"; then
			at=$i
			break
		fi
	done
	heading="## $tag — $title — DOING"
	if ((at == ${#PO_LINES[@]})); then
		PO_LINES_NL=1
		((${#PO_LINES[@]} == 0)) || [[ -z ${PO_LINES[-1]} ]] || PO_LINES+=("")
		PO_LINES+=("$heading")
	else
		PO_LINES=("${PO_LINES[@]:0:at}" "$heading" "" "${PO_LINES[@]:at}")
	fi
	po_edit_write "$best_file"
	# shellcheck disable=SC2034 # read by open.sh
	PO_FOUND_FILE=$best_file
}

# po_edit_verify <version>:<STATUS>...: read the planned sources back with
# the backlog reader: each named item must have exactly that status in
# every source that records it, and no item may be left disagreeing.
po_edit_verify() {
	(
		local path want rec v s rv rs seen c backlog
		backlog=$(po_get layout.backlog)
		PO_ITEMS=()
		po_edit_file "$backlog"
		po_backlog_tables "$backlog" "$PO_EF"
		while IFS= read -r path; do
			[[ -n $path ]] || continue
			po_edit_file "$path"
			po_backlog_headings "$path" "$PO_EF"
		done < <(po_spec_files)
		c=$(po_backlog_conflicts)
		[[ -z $c ]] || po_conflict "the planned edits leave the backlog disagreeing with itself: ${c//$'\t'/ }"
		for want in "$@"; do
			v=${want%:*} s=${want##*:} seen=0
			for rec in "${PO_ITEMS[@]}"; do
				rv=${rec%%$'\t'*}
				[[ $rv == "$v" ]] || continue
				rs=${rec#*$'\t'}
				rs=${rs%%$'\t'*}
				[[ $rs == "$s" ]] || po_conflict "after the planned edits $v reads $rs, not $s"
				seen=1
			done
			((seen)) || po_conflict "after the planned edits no source records $v"
		done
	) || exit $?
}

# po_edit_diff: the plan as a unified diff, file by file.
po_edit_diff() {
	local path n d rc
	for path in "${PO_EDIT_FILES[@]}"; do
		n=${PO_EDIT_N[$path]}
		rc=0
		# Exit 1 is "the files differ"; only above that is an error.
		d=$(git diff --no-index --no-color -U2 -- "$PO_EDIT_DIR/$n.old" "$PO_EDIT_DIR/$n.new") || rc=$?
		((rc <= 1)) || po_die "could not diff the planned $path"
		printf -- '--- a/%s\n+++ b/%s\n' "$path" "$path"
		printf '%s\n' "$d" | sed -n '/^@@/,$p'
	done
}

# po_edit_check_base <worktree>: refuse unless each planned file's blob in
# <worktree>'s index is the planned base. Blobs, not checkout bytes: a
# checkout with line-ending conversion holds other bytes for the same blob.
po_edit_check_base() {
	local wt=$1 path n
	for path in "${PO_EDIT_FILES[@]}"; do
		n=${PO_EDIT_N[$path]}
		[[ $(git -C "$wt" rev-parse -q --verify ":$path" 2>/dev/null) == "$(git hash-object --no-filters -- "$PO_EDIT_DIR/$n.old")" ]] ||
			return 1
	done
}

# po_edit_apply <worktree>: stage the planned files in <worktree>'s index as
# blobs written byte for byte, then check them out through git's own
# filters. Dies with <stop> (what has already happened) on failure.
po_edit_apply() {
	local wt=$1 stop=$2 path n blob mode
	po_edit_check_base "$wt" || po_die "stopped$stop: a planned file in $wt is not the planned base"
	for path in "${PO_EDIT_FILES[@]}"; do
		n=${PO_EDIT_N[$path]}
		blob=$(git -C "$wt" hash-object -w --no-filters -- "$PO_EDIT_DIR/$n.new") ||
			po_die "stopped$stop: could not write the planned $path"
		mode=$(git -C "$wt" ls-files -s -- "$path")
		mode=${mode%% *}
		git -C "$wt" update-index --cacheinfo "$mode,$blob,$path" ||
			po_die "stopped$stop: could not stage $path"
	done
}
