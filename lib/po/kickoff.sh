# shellcheck shell=bash
# po kickoff — read-only. The mechanical half of an item's founding brief.
#
# Prints a skeleton the PO writes the judgment layer on top of:
#   1. the item's own spec section, verbatim, from the *.md files under
#      [layout] specs_dir as committed on main;
#   2. the standing-rules pointer, [docs] rules, checked on main;
#   3. every admin or ruling commit on main from the previous boundary to
#      the item's founding, classed exactly as po fresh classes them.
#
# The section starts at the item's heading and runs to the next heading of
# the same or a higher level (fenced code is not read for headings). Its
# heading is, in order of preference:
#   - the heading the backlog parser reads, `## <tag-form id> — …`;
#   - else a heading of any level naming `item <label>`, where <label> is a
#     cell left of the id in the item's backlog table row (a table-shaped
#     ledger: `| E | v0.5 | … |` and `### … (item E — …)`).
# Every heading that matches is printed, each with its file and lines.
#
# The founding boundary is the oldest first-parent commit on main at which
# a backlog source says the item is DOING; the previous boundary is the
# highest tag below the item's version reachable from it. An item not yet DOING on main is listed to
# main's tip; an open item also lists what main gained since its founding.
#
# An optional [kickoff] preamble = ["line", ...] in po.toml prints its lines,
# verbatim, at the very top, followed by a blank line; without it the output
# is exactly what it was.
#
# Writes nothing anywhere: no files, no refs, no index. Exit 0, 1 usage,
# 2 a missing source — no spec section (a founding in progress), no
# [docs] rules or one that is not on main, an unreadable backlog.

# po_kickoff_sections <version> <rev>: every spec section of the item, as
# "<file>\t<first line>\t<last line>" records in PO_KO_SECTIONS, and how
# they were found in PO_KO_RULE.
po_kickoff_sections() {
	local v=$1 rev=$2 specs_dir backlog tag id file rec where row i
	local -a labels=()
	specs_dir=$(po_get layout.specs_dir)
	backlog=$(po_get layout.backlog)
	tag=$(po_get versioning.tag)
	id=$(po_fill "$tag" "$v")
	PO_KO_SECTIONS=() PO_KO_RULE=
	# Labels: the cells left of the id in each of the item's table rows.
	for rec in "${PO_ITEMS[@]}"; do
		[[ ${rec%%$'\t'*} == "$v" ]] || continue
		where=${rec##*$'\t'}
		[[ ${where%:*} == "$backlog" ]] || continue
		row=$(git show "$rev:$backlog" | sed -n "${where##*:}p")
		po_split_row "$(po_trim "$row")"
		for i in "${!PO_CELLS[@]}"; do
			[[ ${PO_CELLS[i]} == "$id" ]] && break
			[[ ${PO_CELLS[i]} =~ ^[[:alnum:]][[:alnum:]._-]*$ ]] && labels+=("${PO_CELLS[i]}")
		done
	done
	local rule
	for rule in id label; do
		[[ $rule == label && ${#labels[@]} == 0 ]] && break
		while IFS= read -r file; do
			[[ $file == *.md ]] || continue
			po_kickoff_scan "$rule" "$id" "$file" "$rev" "${labels[@]}"
		done < <(git ls-tree -z --name-only "$rev" -- "$specs_dir/" | tr '\0' '\n')
		if ((${#PO_KO_SECTIONS[@]} > 0)); then
			if [[ $rule == id ]]; then
				PO_KO_RULE="heading $id"
			else
				PO_KO_RULE="heading names item $(printf '%s/' "${labels[@]}")"
				PO_KO_RULE=${PO_KO_RULE%/}
			fi
			return 0
		fi
	done
}

# po_kickoff_scan <id|label> <id> <file> <rev> [<label>...]: append the
# sections of <file> whose heading matches to PO_KO_SECTIONS.
po_kickoff_scan() {
	local rule=$1 id=$2 file=$3 rev=$4 n i level=0 start=0 fence='' line hashes text l re
	shift 4
	local -a lines labels=("$@") res=()
	for l in "${labels[@]}"; do
		re=${l//./\\.}
		# Not followed by more of a label: D is not D.1 or D-2.
		res+=("(^|[^[:alnum:]_])item ${re}(\$|[^[:alnum:]_.-]|[.-](\$|[^[:alnum:]_]))")
	done
	mapfile -t lines < <(git show "$rev:$file")
	n=${#lines[@]}
	for ((i = 0; i < n; i++)); do
		line=${lines[i]}
		# A fence closes only on its own character, at least as long, with
		# nothing after it but blanks.
		if [[ $line =~ ^\ {0,3}(\`{3,}|~{3,})(.*)$ ]]; then
			if [[ -z $fence ]]; then
				fence=${BASH_REMATCH[1]}
				continue
			fi
			if [[ ${BASH_REMATCH[1]:0:1} == "${fence:0:1}" && ${#BASH_REMATCH[1]} -ge ${#fence} &&
				-z $(po_trim "${BASH_REMATCH[2]}") ]]; then
				fence=''
				continue
			fi
		fi
		[[ -n $fence ]] && continue
		[[ $line =~ ^(#{1,6})([[:blank:]]+(.*))?$ ]] || continue
		hashes=${BASH_REMATCH[1]}
		text=${BASH_REMATCH[3]}
		if ((start)) && ((${#hashes} <= level)); then
			PO_KO_SECTIONS+=("$file"$'\t'"$start"$'\t'"$i")
			start=0
		fi
		((start)) && continue
		if [[ $rule == id ]]; then
			[[ $line == "## $id — "* ]] || continue
		else
			local hit=0
			for re in "${res[@]}"; do
				[[ $text =~ $re ]] && hit=1
			done
			((hit)) || continue
		fi
		start=$((i + 1)) level=${#hashes}
	done
	((start)) && PO_KO_SECTIONS+=("$file"$'\t'"$start"$'\t'"$n")
	return 0
}

# po_kickoff_founding <version> <main tip>: the oldest first-parent commit
# on main at which a backlog source says the item is DOING into
# PO_KO_FOUND (empty when none), and the commits before it whose backlog
# po cannot read (an older layout) into PO_KO_UNREAD — skipped, and named.
po_kickoff_founding() {
	local v=$1 mtip=$2 id c says
	id=$(po_fill "$(po_get versioning.tag)" "$v")
	PO_KO_FOUND='' PO_KO_UNREAD=()
	while IFS= read -r c; do
		if ! says=$(po_backlog_load "$c" 2>/dev/null && po_item_statuses "$v"); then
			PO_KO_UNREAD+=("$c")
			continue
		fi
		if grep -qx "$PO_LIVE_STATUS" <<<"$says"; then
			PO_KO_FOUND=$c
			return 0
		fi
	done < <(git log --first-parent --reverse --format=%H -G "${id//./\\.}" "$mtip" -- \
		":(literal)$(po_get layout.backlog)" ":(literal)$(po_get layout.specs_dir)")
}

# po_kickoff_prev <version> <commit>: the previous boundary — the highest
# tag in tag form below <version> reachable from <commit>, or nothing. The
# bound keeps an item's own tag, and later items', out of its range.
po_kickoff_prev() {
	local tpl t v
	tpl=$(po_get versioning.tag)
	while IFS= read -r t; do
		v=$(po_unfill "$tpl" "$t") || continue
		if po_version_lt "$v" "$1"; then
			printf '%s' "$t"
			return 0
		fi
	done < <(git tag --merged "$2" --sort=-v:refname)
}

# po_kickoff_list <range>: the admin and ruling commits in <range>,
# oldest first, each line as po fresh prints it.
po_kickoff_list() {
	local c s class shown=0 total=0 out=''
	while IFS=' ' read -r c s; do
		total=$((total + 1))
		class=$(po_commit_class "$c" "$s")
		[[ $class == ADMIN* || $class == *' RUL'* ]] || continue
		shown=$((shown + 1))
		out+=$(po_commit_line "$c" "$s" "$class")$'\n'
	done < <(git log --reverse --topo-order --format='%H %s' "$@")
	printf '\n%s (%s of %s commits; ITEM and OTHER without a mark not listed)\n' "$PO_KO_TITLE" "$shown" "$total"
	printf '%s' "$out"
}

po_cmd_kickoff() {
	(($# == 1)) || po_usage_die "kickoff needs exactly one <version>"
	[[ $1 != -* ]] || po_usage_die "kickoff: unknown argument '$1'"
	local version main mtip id title says owner rules rec file first last found prev
	version=$(po_version_arg kickoff "$1")
	main=$(po_get layout.main)
	mtip=$(git rev-parse -q --verify "refs/heads/$main^{commit}") ||
		po_die "no branch '$main' (manifest [layout] main)"
	id=$(po_fill "$(po_get versioning.tag)" "$version")
	po_backlog_load "$mtip"

	po_kickoff_sections "$version" "$mtip"
	((${#PO_KO_SECTIONS[@]} > 0)) ||
		po_die "no spec section for $id under $(po_get layout.specs_dir) on $main — a founding in progress? write the spec first"
	[[ -n ${PO_MANIFEST[docs.rules]+x} ]] ||
		po_die "the manifest names no [docs] rules; kickoff points the session at them"
	rules=${PO_MANIFEST[docs.rules]}
	[[ $(git cat-file -t "$mtip:$rules" 2>/dev/null) == blob ]] ||
		po_die "[docs] rules '$rules' is not a file on $main"

	# [kickoff] preamble: the project's own lines, first in the brief.
	[[ -z ${PO_MANIFEST[kickoff.preamble]:-} ]] || printf '%s\n\n' "${PO_MANIFEST[kickoff.preamble]}"

	title=$(po_item_title "$version")
	says=$(po_item_statuses "$version" | sort -u | paste -sd/ -)
	printf 'KICKOFF   %s%s\n' "$id" "${title:+ — $title}"
	printf 'status    %s (%s %s)\n' "${says:-not in the backlog}" "$main" "$(po_short "$mtip")"
	printf 'branch    %s\n' "$(po_fill "$(po_get layout.branch)" "$version")"
	owner=$(po_item_owner "$version")
	[[ -z $owner ]] || printf 'owner     %s\n' "$owner"
	printf 'rules     %s (blob %s on %s) — the standing rules; read first\n' \
		"$rules" "$(git rev-parse --short "$mtip:$rules")" "$main"
	if [[ -n ${PO_MANIFEST[docs.decisions]+x} ]]; then
		local dec=${PO_MANIFEST[docs.decisions]}
		if [[ $(git cat-file -t "$mtip:$dec" 2>/dev/null) == blob ]]; then
			printf 'decisions %s\n' "$dec"
		else
			printf 'decisions %s (not on %s)\n' "$dec" "$main"
		fi
	fi

	po_kickoff_founding "$version" "$mtip"
	found=$PO_KO_FOUND
	local end=${found:-$mtip}
	prev=$(po_kickoff_prev "$version" "$end")
	if [[ -n $found ]]; then
		printf 'boundary  %s .. founded DOING at %s\n' "${prev:-(no tag)}" "$(po_short "$found")"
	else
		printf 'boundary  %s .. %s tip %s (never DOING on %s)\n' "${prev:-(no tag)}" "$main" "$(po_short "$mtip")" "$main"
	fi
	for rec in "${PO_KO_UNREAD[@]}"; do
		printf 'note      %s mentions %s but po cannot read its backlog; not taken as the founding\n' "$(po_short "$rec")" "$id"
	done

	for rec in "${PO_KO_SECTIONS[@]}"; do
		IFS=$'\t' read -r file first last <<<"$rec"
		printf '\nSPEC SECTION %s:%s-%s (%s, from %s %s)\n' "$file" "$first" "$last" "$PO_KO_RULE" "$main" "$(po_short "$mtip")"
		git show "$mtip:$file" | sed -n "${first},${last}p"
		# A file without a final newline: keep the end marker on its own line.
		[[ -z $(git show "$mtip:$file" | tail -c 1) ]] ||
			((last <= $(git show "$mtip:$file" | wc -l))) || printf '\n'
		printf 'END SPEC SECTION\n'
	done

	if [[ -n $prev ]]; then
		PO_KO_TITLE="ADMIN/RULING SINCE $prev"
		po_kickoff_list "$prev..$end"
	else
		PO_KO_TITLE="ADMIN/RULING SINCE THE ROOT (no tag before the founding)"
		po_kickoff_list "$end"
	fi
	if [[ -n $found && $found != "$mtip" ]] && po_item_open "$version"; then
		PO_KO_TITLE="ADMIN/RULING SINCE THE FOUNDING (the item is open; to $main tip $(po_short "$mtip"))"
		po_kickoff_list "$found..$mtip"
	fi

	printf '\nJUDGMENT LAYER (PO, by hand): scope, tensions, fixed points, safety lines\n'
}

# po_item_open <version>: success when a backlog source says DOING or held.
po_item_open() {
	local s
	while IFS= read -r s; do
		[[ $s == "$PO_LIVE_STATUS" ]] || po_is_held "$s" && return 0
	done < <(po_item_statuses "$1")
	return 1
}
