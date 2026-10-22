# shellcheck shell=bash
# po version, po doctor — which po-kit is installed, and whether every
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
		sect=${key%%.*} name=${key#*.}
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
