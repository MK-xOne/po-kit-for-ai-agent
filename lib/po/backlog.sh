# shellcheck shell=bash
# po-kit: reading item statuses out of the backlog, as committed on main.
#
# Two sources, both read from the main ref (`git show main:<path>`), never
# from a working tree, so the answer does not depend on where po runs or on
# anyone's uncommitted edits:
#   1. Markdown tables in [layout] backlog with a `Status` column. The item is
#      the first cell in tag form (versioning.tag filled, e.g. v1.9.8); its
#      title is the cell after it.
#   2. Item headings in the *.md files of [layout] specs_dir:
#        ## <tag-form id> — <title> — <STATUS>[ anything]
#      split on " — "; the status is the one segment after the title whose
#      first word is all capitals (two such segments are an error).
# An open status (DOING, PAUSED, BLOCKED) written any other way — bold,
# lower case, decorated — is an error, never a silent "not open".
# Ambiguity is an error naming file:line. Two sources that disagree are not
# an error to read, but they are reported (po status exits 3).
#
# With [layout] owner_column, a table's column of that name also gives each
# item its owner (PO_OWNERS, table rows only; the first row of an item wins).
#
# Result: PO_ITEMS, one record per item and source:
#   <version>\t<STATUS>\t<title>\t<file>:<line>

PO_ITEMS=()
declare -gA PO_OWNERS=()

# The statuses that hold a branch open: DOING is live work; the held ones
# keep a parked branch the kit must not prune.
PO_LIVE_STATUS=DOING
PO_HELD_STATUSES=(PAUSED BLOCKED)

po_is_held() {
	local s
	for s in "${PO_HELD_STATUSES[@]}"; do
		[[ $1 == "$s" ]] && return 0
	done
	return 1
}

# po_check_status <text> <where> <table|heading>: die when <text> looks like
# an open status (DOING, PAUSED, BLOCKED) without being written exactly as
# one — **DOING**, Doing, `DOING (x)` in a table cell — since misreading one
# would let prune take a live branch. A heading segment may carry words
# after its status word; a table cell may not.
po_check_status() {
	local text=$1 first norm
	first=${text%%[[:blank:]]*}
	norm=${first//[*_\`]/}
	norm=${norm^^}
	[[ $norm == "$PO_LIVE_STATUS" ]] || po_is_held "$norm" || return 0
	if [[ $3 == table ]]; then
		[[ $text == "$norm" ]] && return 0
	else
		[[ $first == "$norm" ]] && return 0
	fi
	po_die "$2: status '$text' is not written exactly as $norm"
}

po_trim() {
	local s=$1
	s=${s#"${s%%[![:blank:]]*}"}
	s=${s%"${s##*[![:blank:]]}"}
	printf '%s' "$s"
}

# po_batch_read <rev> <outdir> <path>...: write the content of each path at
# <rev> to <outdir>/<index> (empty when missing) with one git process.
po_batch_read() {
	local rev=$1 outdir=$2
	shift 2
	printf '%s\n' "$@" | python3 -I -c '
import subprocess, sys, os
rev, outdir = sys.argv[1], sys.argv[2]
names = [ln.rstrip("\n") for ln in sys.stdin if ln.strip()]
inp = "".join(f"{rev}:{p}\n" for p in names).encode()
data = subprocess.run(["git", "cat-file", "--batch"], input=inp,
                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout
pos = 0
for idx in range(len(names)):
    content = b""
    nl = data.find(b"\n", pos)
    if nl >= 0:
        parts = data[pos:nl].split()
        pos = nl + 1
        if len(parts) >= 3 and parts[1] != b"missing":
            size = int(parts[2])
            content = data[pos:pos + size]
            pos += size + 1
    with open(os.path.join(outdir, str(idx)), "wb") as fh:
        fh.write(content)
' "$rev" "$outdir"
}

# Memo globals for po_backlog_load (per commit, within one po run).
PO_BACKLOG_MEMO_REV=''
PO_BACKLOG_MEMO_ITEMS=''
PO_BACKLOG_MEMO_OWNERS=''

# po_backlog_load [<rev>]: fill PO_ITEMS from main, or from <rev>.
po_backlog_load() {
	local main backlog specs_dir sha
	main=${1:-$(po_get layout.main)}
	# The memo is keyed by the commit, so a ref that moves mid-run misses.
	sha=$(git rev-parse -q --verify "$main^{commit}" 2>/dev/null) || sha=''
	backlog=$(po_get layout.backlog)
	specs_dir=$(po_get layout.specs_dir)

	# Memo hit: restore without touching git.
	if [[ -n $sha && $sha == "${PO_BACKLOG_MEMO_REV:-}" ]]; then
		PO_ITEMS=()
		if [[ -n "${PO_BACKLOG_MEMO_ITEMS:-}" ]]; then
			while IFS= read -r _m_line; do
				[[ -z "$_m_line" ]] && continue
				PO_ITEMS+=("$_m_line")
			done <<< "$PO_BACKLOG_MEMO_ITEMS"
		fi
		PO_OWNERS=()
		if [[ -n "${PO_BACKLOG_MEMO_OWNERS:-}" ]]; then
			while IFS=$'\t' read -r _m_k _m_v; do
				[[ -z "$_m_k" ]] && continue
				PO_OWNERS[$_m_k]=$_m_v
			done <<< "$PO_BACKLOG_MEMO_OWNERS"
		fi
		return 0
	fi

	PO_ITEMS=()
	PO_OWNERS=()
	git cat-file -e "$main:$backlog" 2>/dev/null ||
		po_die "backlog '$backlog' not found on $main"
	git cat-file -e "$main:${specs_dir%/}/" 2>/dev/null ||
		po_die "specs_dir '$specs_dir' not found on $main"

	local -a _files=()
	_files+=("$backlog")
	local _f
	while IFS= read -r _f; do
		[[ $_f == *.md ]] || continue
		_files+=("$_f")
	done < <(git ls-tree -z --name-only "$main" -- "$specs_dir/" | tr '\0' '\n')

	local _tmpdir
	_tmpdir=$(mktemp -d)
	po_batch_read "$main" "$_tmpdir" "${_files[@]}"

	local _i=0
	po_backlog_tables "$backlog" "$_tmpdir/0"
	_i=1
	local _file
	for _file in "${_files[@]:1}"; do
		[[ $_file == *.md ]] || { _i=$((_i+1)); continue; }
		po_backlog_headings "$_file" "$_tmpdir/$_i"
		_i=$((_i+1))
	done

	rm -rf "$_tmpdir"

	PO_BACKLOG_MEMO_REV=$sha
	PO_BACKLOG_MEMO_ITEMS=''
	local _rec
	for _rec in "${PO_ITEMS[@]}"; do
		PO_BACKLOG_MEMO_ITEMS+="$_rec"$'\n'
	done
	PO_BACKLOG_MEMO_OWNERS=''
	local _k
	for _k in "${!PO_OWNERS[@]}"; do
		PO_BACKLOG_MEMO_OWNERS+="$_k"$'\t'"${PO_OWNERS[$_k]}"$'\n'
	done
}

# Split one table row into PO_CELLS (outer pipes dropped, cells trimmed).
po_split_row() {
	local row=$1
	row=${row#|}
	row=${row%|}
	PO_CELLS=()
	while [[ $row == *'|'* ]]; do
		PO_CELLS+=("$(po_trim "${row%%|*}")")
		row=${row#*|}
	done
	PO_CELLS+=("$(po_trim "$row")")
}

po_backlog_tables() {
	local name=$1 src=$2 line lineno=0 in_table=0 status_col=-1 width=0
	local tag version id_col i owner_name='' owner_col=-1
	tag=$(po_get versioning.tag)
	[[ -z ${PO_MANIFEST[layout.owner_column]+x} ]] || owner_name=${PO_MANIFEST[layout.owner_column]}
	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		line=$(po_trim "$line")
		if [[ $line != '|'* ]]; then
			in_table=0
			continue
		fi
		po_split_row "$line"
		if ((in_table == 0)); then
			# A header row: find the Status column.
			in_table=1
			status_col=-1 owner_col=-1
			width=${#PO_CELLS[@]}
			for i in "${!PO_CELLS[@]}"; do
				local hdr=${PO_CELLS[i]//[*_\`]/}
				[[ ${hdr,,} != status || ${PO_CELLS[i]} == Status ]] ||
					po_die "$name:$lineno: column header '${PO_CELLS[i]}' is not written exactly as Status"
				if [[ ${PO_CELLS[i]} == Status ]]; then
					((status_col < 0)) ||
						po_die "$name:$lineno: two Status columns"
					status_col=$i
				fi
				if [[ -n $owner_name && ${PO_CELLS[i]} == "$owner_name" ]]; then
					((owner_col < 0)) ||
						po_die "$name:$lineno: two $owner_name columns"
					owner_col=$i
				fi
			done
			continue
		fi
		[[ $line =~ ^\|[-:|[:blank:]]+\|$ ]] && continue
		((status_col >= 0)) || continue
		((${#PO_CELLS[@]} == width)) ||
			po_die "$name:$lineno: row has ${#PO_CELLS[@]} cells, header has $width"
		local status=${PO_CELLS[status_col]}
		po_check_status "$status" "$name:$lineno" table
		id_col=-1
		for i in "${!PO_CELLS[@]}"; do
			if version=$(po_unfill "$tag" "${PO_CELLS[i]}"); then
				id_col=$i
				break
			fi
		done
		if ((id_col < 0)); then
			[[ $status == "$PO_LIVE_STATUS" ]] || po_is_held "$status" &&
				po_die "$name:$lineno: $status row has no cell in tag form ($tag)"
			continue
		fi
		local title=
		((id_col + 1 < width && id_col + 1 != status_col)) && title=${PO_CELLS[id_col + 1]}
		PO_ITEMS+=("$version"$'\t'"$status"$'\t'"$title"$'\t'"$name:$lineno")
		((owner_col < 0)) || [[ -n ${PO_OWNERS[$version]+x} ]] || PO_OWNERS[$version]=${PO_CELLS[owner_col]}
	done <"$src"
}

po_backlog_headings() {
	local name=$1 src=$2 line lineno=0 tag prefix id version
	local -a segs
	tag=$(po_get versioning.tag)
	prefix=${tag%%\{version\}*}
	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		[[ $line == "## $prefix"[0-9]* ]] || continue
		id=${line#'## '}
		id=${id%%[[:blank:]]*}
		version=$(po_unfill "$tag" "$id") ||
			po_die "$name:$lineno: heading id '$id' is not in tag form ($tag)"
		# Split on " — " (space, em dash, space).
		local rest=${line#"## $id"}
		segs=()
		[[ $rest == ' — '* ]] || po_die "$name:$lineno: heading has no ' — ' after its id"
		rest=${rest#' — '}
		while [[ $rest == *' — '* ]]; do
			segs+=("${rest%%' — '*}")
			rest=${rest#*' — '}
		done
		segs+=("$rest")
		((${#segs[@]} >= 2)) || po_die "$name:$lineno: heading has no status segment"
		# The status is the one segment after the title whose first word is
		# all capitals; two such segments are ambiguous.
		local title=${segs[0]} status='' i word
		for ((i = 1; i < ${#segs[@]}; i++)); do
			word=${segs[i]%%[[:blank:]]*}
			po_check_status "${segs[i]}" "$name:$lineno" heading
			if [[ $word =~ ^[A-Z]{2,}$ ]]; then
				[[ -z $status ]] ||
					po_die "$name:$lineno: two status-like segments ('$status', '$word')"
				status=$word
			elif [[ -z $status ]]; then
				title+=" — ${segs[i]}"
			fi
		done
		[[ -n $status ]] || po_die "$name:$lineno: heading has no ALL-CAPS status segment"
		PO_ITEMS+=("$version"$'\t'"$status"$'\t'"$title"$'\t'"$name:$lineno")
	done <"$src"
}

# po_backlog_conflicts: one line per item whose sources disagree, or whose
# heading appears twice with different statuses.
po_backlog_conflicts() {
	local rec v s rest
	local -A first=() where=()
	for rec in "${PO_ITEMS[@]}"; do
		v=${rec%%$'\t'*}
		rest=${rec#*$'\t'}
		s=${rest%%$'\t'*}
		if [[ -z ${first[$v]+x} ]]; then
			first[$v]=$s
			where[$v]=${rec##*$'\t'}
		elif [[ ${first[$v]} != "$s" ]]; then
			printf '%s\t%s at %s\t%s at %s\n' "$v" "${first[$v]}" "${where[$v]}" "$s" "${rec##*$'\t'}"
		fi
	done
}
