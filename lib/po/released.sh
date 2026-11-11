# shellcheck shell=bash
# po released — which DONE items the project's latest release contains,
# judged from git (read-only).
#
# [release] source says what a release is:
#   tag     the newest tag matching [release] pattern (default release-*) by
#           version order
#   github  the tag the caller passes with --release (a feed producer reads
#           the newest GitHub release; the kit never calls GitHub)
#   none    no releases (the default when [release] is absent)
# A DONE item is released by one of two rules:
#   tagged    its item tag ([versioning] tag filled) exists: released when
#             that tag is an ancestor of the release tag. A tag that exists
#             but is not an ancestor is not released; the rule below is not
#             tried.
#   untagged  no item tag is filled in or the tag is absent from the
#             repository: the DONE commit decides. That is the newest commit
#             on the main branch whose subject starts `admin: <v> DONE` (<v>
#             as the backlog writes it, with or without a leading `v`, up to
#             the following space), else the newest commit that changed the
#             item's row in the backlog or its `## <tag> — ...` heading in
#             specs_dir (the heading form older backlogs keep their items in).
#             Released when that commit is an ancestor of the release tag; no
#             such commit means not released.
#             The set is computed in a constant number of git calls (v0.152):
#             one cat-file for the item tags, one rev-list of the release, one
#             log of main's subjects and, only when some item needs it, one log
#             of the backlog and specs_dir diffs; the rules are joined in text.

# po_released_scan <release>: fill PO_RELEASED with the DONE versions the
# release contains, in backlog order. See the rules in the header.
po_released_scan() {
	local release=$1 main backlog specs_dir tpl rec v st word tag cell sha line
	local -a done_v=() untagged=()
	local -A tagsha=() anc=() admin=() touched=() tagof=()
	PO_RELEASED=()
	main=$(po_get layout.main)
	backlog=$(po_get layout.backlog)
	specs_dir=$(po_get layout.specs_dir)
	tpl=$(po_get versioning.tag)
	po_backlog_load
	local -A seen=()
	for rec in "${PO_ITEMS[@]}"; do
		IFS=$'\t' read -r v st _ <<<"$rec"
		[[ -z ${seen[$v]+x} ]] || continue
		seen[$v]=1
		# Adopt the dashboard's status_word rule (first word, upper-cased,
		# trailing punctuation stripped) so DONE:, DONE. and done count.
		word=${st%% *}; word=${word^^}
		while [[ $word == *[[:punct:]] ]]; do word=${word%?}; done
		[[ $word == DONE ]] && done_v+=("$v")
	done
	((${#done_v[@]})) || return 0

	# Item tags: one batch lookup, peeled to a commit as rev-parse ^{commit} does.
	# The tag is filled inline (po_fill's rule) to spare a subshell per item.
	local -a tags=()
	for v in "${done_v[@]}"; do
		tag=${tpl/\{version\}/$v}
		tagof[$v]=$tag
		[[ -z $tag ]] || tags+=("$tag")
	done
	if ((${#tags[@]})); then
		local i=0
		while IFS= read -r line; do
			[[ $line == *' missing' || $line == *' ambiguous' ]] || tagsha[${tags[$i]}]=${line%% *}
			i=$((i + 1))
		done < <(printf 'refs/tags/%s^{commit}\n' "${tags[@]}" | git cat-file --batch-check 2>/dev/null)
	fi
	while IFS= read -r sha; do anc[$sha]=1; done < <(git rev-list "refs/tags/$release" 2>/dev/null)

	for v in "${done_v[@]}"; do
		tag=${tagof[$v]}
		[[ -n $tag && -n ${tagsha[$tag]+x} ]] || untagged+=("$v")
	done
	if ((${#untagged[@]})); then
		# The newest `admin: <v> DONE` subject per <v> (DONE then the end or a space).
		while IFS=$'\t' read -r v sha; do admin[$v]=$sha; done < <(
			git log "$main" --format='%H%x09%s' 2>/dev/null | awk -F'\t' '
				{ sha = $1; s = substr($0, length(sha) + 2); sub(/^ +/, "", s)
				  if (substr(s, 1, 7) != "admin: ") next
				  r = substr(s, 8); i = index(r, " "); if (!i) next
				  tok = substr(r, 1, i - 1); t = substr(r, i + 1)
				  if (substr(t, 1, 4) != "DONE") next
				  t = substr(t, 5); if (t != "" && t !~ /^[[:space:]]/) next
				  if (!(tok in seen)) { seen[tok] = 1; printf "%s\t%s\n", tok, sha } }')
	fi
	local need=''
	for v in "${untagged[@]}"; do
		[[ -n ${admin[v$v]+x} || -n ${admin[$v]+x} ]] || need+=${tagof[$v]:-$v}$'\n'
	done
	if [[ -n $need ]]; then
		# The newest commit whose diff adds or removes the item's table row
		# (first cell) or its `## <cell>` heading, as `git log -G` would find
		# it; the key is that cell or heading word, so a cell is matched as
		# literal text. The scan stops once every needed cell is found.
		while IFS=$'\t' read -r cell sha; do touched[$cell]=$sha; done < <(
			git log "$main" -p --unified=0 --no-color --no-ext-diff --format=$'\001%H' -- "$backlog" "$specs_dir" 2>/dev/null |
				PO_RELEASED_NEED=$need awk '
				BEGIN { left = split(ENVIRON["PO_RELEASED_NEED"], a, "\n") - 1; for (i = 1; i <= left; i++) need[a[i]] = 1 }
				/^\001/ { sha = substr($0, 2); hunk = 0; next }
				/^diff / { hunk = 0; next }
				/^@@/ { hunk = 1; next }
				!hunk { next }
				/^[-+]/ { l = substr($0, 2); k = ""
				  if (substr(l, 1, 1) == "|") { r = substr(l, 2); i = index(r, "|"); if (!i) next
				    k = substr(r, 1, i - 1); sub(/^ +/, "", k); sub(/ +$/, "", k) }
				  else if (substr(l, 1, 3) == "## ") { k = substr(l, 4); i = index(k, " "); if (i) k = substr(k, 1, i - 1) }
				  else next
				  if ((k in need) && !(k in seen)) { seen[k] = 1; printf "%s\t%s\n", k, sha; if (--left <= 0) exit } }')
	fi

	local done_commit
	for v in "${done_v[@]}"; do
		tag=${tagof[$v]}
		if [[ -n $tag && -n ${tagsha[$tag]+x} ]]; then
			[[ -z ${anc[${tagsha[$tag]}]+x} ]] || PO_RELEASED+=("$v")
			continue
		fi
		done_commit=${admin[v$v]:-${admin[$v]:-}}
		if [[ -z $done_commit ]]; then
			cell=${tag:-$v}
			done_commit=${touched[$cell]:-}
		fi
		[[ -n $done_commit && -n ${anc[$done_commit]+x} ]] && PO_RELEASED+=("$v")
	done
	return 0
}

po_cmd_released() {
	local json=0 given='' have_given=0
	while (($#)); do
		case $1 in
		--json) json=1; shift ;;
		--release)
			(($# >= 2)) || po_usage_die "--release needs a tag"
			given=$2 have_given=1
			shift 2
			;;
		*) po_usage_die "unknown option '$1'" ;;
		esac
	done
	local source release=
	source=$(po_get release.source)
	case $source in
	tag)
		((have_given == 0)) || po_usage_die "--release applies to [release] source \"github\" only; this project's source is \"tag\""
		release=$(git tag -l "$(po_get release.pattern)" --sort=-v:refname | head -n 1)
		;;
	github)
		if ((have_given)); then
			[[ -n $given ]] || po_usage_die "--release needs a tag"
			git rev-parse -q --verify "refs/tags/$given^{commit}" >/dev/null ||
				po_die "release tag '$given' is not in this repository (fetch tags first)"
			release=$given
		fi
		;;
	none)
		((have_given == 0)) || po_usage_die "--release applies to [release] source \"github\" only; this project's source is \"none\""
		;;
	esac

	local -a PO_RELEASED=()
	[[ -z $release ]] || po_released_scan "$release"
	local -a released=("${PO_RELEASED[@]}")

	if ((json)); then
		local list='' sep='' relj=null
		[[ -z $release ]] || relj=$(po_json_str "$release")
		local s
		for v in "${released[@]}"; do
			# po_json_str's escapes, inline: a subshell per item is slow on hundreds of items.
			s=${v//\\/\\\\} s=${s//\"/\\\"} s=${s//$'\n'/\\n} s=${s//$'\t'/\\t} s=${s//[$'\001'-$'\037\177']/ }
			list+=$sep\"$s\" sep=,
		done
		printf '{"source":%s,"release":%s,"released":[%s]}\n' "$(po_json_str "$source")" "$relj" "$list"
	else
		printf 'release: %s\n' "${release:-none}"
		((${#released[@]} == 0)) || printf '%s\n' "${released[@]}"
	fi
}
