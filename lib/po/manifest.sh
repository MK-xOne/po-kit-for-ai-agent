# shellcheck shell=bash
# po-kit: the po.toml reader — the shared foundation every command builds on.
#
# po.toml is read as a deliberately small TOML subset, and anything outside
# it is an error naming the file and line, never a guess:
#   - blank lines and `# comment` lines
#   - `[section]` headers (lowercase letters, digits, `_`), each at most once
#   - one sub-table, `[gate.legs]`, whose keys are free leg names and whose
#     values are shell commands, kept in file order
#   - `key = "basic string"` or `key = 123`, optionally followed by a
#     `# comment`; the only escapes are \" and \\
#   - `key = ["a", "b"]`, a one-line array of basic strings, only for the
#     keys in PO_ARRAYS; kept as its strings joined by newlines
# Sections and keys are checked against the schema below: a typo is an
# error, not a silently ignored setting.

# section.key -> 1 (required) or 0 (optional). The keys items B-E use are
# known now so a manifest written once stays valid as the kit grows.
declare -gA PO_SCHEMA=(
	[gate.command]=0
	[gate.test_count_cmd]=0
	[gate.test_format]=0
	[versioning.scheme]=0
	[versioning.tag]=1
	[versioning.item_commit]=0
	[versioning.admin_prefix]=0
	[versioning.insert_segment]=0
	[versioning.tag_style]=0
	[layout.backlog]=1
	[layout.specs_dir]=1
	[layout.worktrees]=1
	[layout.branch]=1
	[layout.main]=0
	[layout.owner_column]=0
	[docs.decisions]=0
	[docs.rules]=0
	[hooks.on_close]=0
	[kickoff.preamble]=0
	[close.checklist]=0
)

# The keys whose value is an array of strings, not a string or an integer.
declare -gA PO_ARRAYS=(
	[kickoff.preamble]=1
	[close.checklist]=1
)

# Defaults for optional keys the kit reads.
declare -gA PO_DEFAULTS=(
	[layout.main]=main
	[versioning.tag_style]=light
)

# The parsed manifest: section.key -> value.
declare -gA PO_MANIFEST=()
PO_MANIFEST_FILE=
# [gate.legs] names in file order; each command is PO_MANIFEST[gate.legs.<name>].
PO_GATE_LEGS=()

po_die() {
	printf 'po: %s\n' "$*" >&2
	exit 2
}

# po_manifest_load <file>: parse <file> into PO_MANIFEST, or die.
po_manifest_load() {
	local file=$1 line lineno=0 section='' key value rest
	local -A seen_sections=()
	[[ -f $file ]] || po_die "manifest not found: $file"
	PO_MANIFEST=()
	PO_MANIFEST_FILE=$file
	PO_GATE_LEGS=()
	while IFS= read -r line || [[ -n $line ]]; do
		lineno=$((lineno + 1))
		local where="$file:$lineno"
		[[ $line == *$'\r'* ]] && po_die "$where: carriage return in manifest"
		# Strip leading and trailing blanks.
		line=${line#"${line%%[![:blank:]]*}"}
		line=${line%"${line##*[![:blank:]]}"}
		[[ -z $line || $line == '#'* ]] && continue
		if [[ $line =~ ^\[([a-z0-9_]+|gate\.legs)\]$ ]]; then
			section=${BASH_REMATCH[1]}
			[[ -n ${seen_sections[$section]:-} ]] &&
				po_die "$where: section [$section] appears twice"
			seen_sections[$section]=1
			po_manifest_known_section "$section" ||
				po_die "$where: unknown section [$section]"
			continue
		fi
		[[ $line =~ ^\[ ]] && po_die "$where: malformed section header: $line"
		if [[ ! $line =~ ^([a-z0-9_]+)[[:blank:]]*=[[:blank:]]*(.*)$ ]]; then
			po_die "$where: expected 'key = value': $line"
		fi
		key=${BASH_REMATCH[1]}
		rest=${BASH_REMATCH[2]}
		[[ -n $section ]] || po_die "$where: key '$key' before any [section]"
		local full="$section.$key"
		[[ $section == gate.legs || -n ${PO_SCHEMA[$full]+x} ]] ||
			po_die "$where: unknown key '$key' in [$section]"
		[[ -n ${PO_MANIFEST[$full]+x} ]] && po_die "$where: key '$key' in [$section] set twice"
		if [[ -n ${PO_ARRAYS[$full]+x} ]]; then
			po_manifest_array "$rest" "$where" || exit 2
			value=$PO_PARSED
		elif [[ $rest == '['* ]]; then
			po_die "$where: key '$key' in [$section] is not an array"
		elif [[ $rest == '"'* ]]; then
			po_manifest_string "$rest" "$where" || exit 2
			value=$PO_PARSED
		elif [[ $rest =~ ^([0-9]+)([[:blank:]]+#.*)?$ ]]; then
			value=${BASH_REMATCH[1]}
		else
			po_die "$where: value must be a \"quoted string\" or an integer: $rest"
		fi
		if [[ $section == gate.legs ]]; then
			[[ $rest == '"'* && -n $value ]] || po_die "$where: leg '$key' needs a non-empty \"command\""
			PO_GATE_LEGS+=("$key")
		fi
		PO_MANIFEST[$full]=$value
	done <"$file"
	[[ -n ${seen_sections[gate.legs]:-} && ${#PO_GATE_LEGS[@]} == 0 ]] &&
		po_die "$file: [gate.legs] names no legs"
	[[ ${#PO_GATE_LEGS[@]} -gt 0 && -n ${PO_MANIFEST[gate.command]+x} ]] &&
		po_die "$file: [gate] command and [gate.legs] both define the gate; keep one"
	[[ -z ${PO_MANIFEST[hooks.on_close]+x} || -n ${PO_MANIFEST[hooks.on_close]} ]] ||
		po_die "$file: [hooks] on_close needs a non-empty \"command\""
	[[ -z ${PO_MANIFEST[layout.owner_column]+x} || -n ${PO_MANIFEST[layout.owner_column]} ]] ||
		po_die "$file: [layout] owner_column needs a non-empty \"column name\""
	[[ -z ${PO_MANIFEST[versioning.tag_style]+x} || ${PO_MANIFEST[versioning.tag_style]} == light || ${PO_MANIFEST[versioning.tag_style]} == annotated ]] ||
		po_die "$file: [versioning] tag_style must be \"light\" or \"annotated\": ${PO_MANIFEST[versioning.tag_style]}"
	[[ -z ${PO_MANIFEST[gate.test_format]+x} || ${PO_MANIFEST[gate.test_format]} == libtest || ${PO_MANIFEST[gate.test_format]} == pytest ]] ||
		po_die "$file: [gate] test_format must be \"libtest\" or \"pytest\": ${PO_MANIFEST[gate.test_format]}"
	local required
	for required in "${!PO_SCHEMA[@]}"; do
		[[ ${PO_SCHEMA[$required]} == 1 && -z ${PO_MANIFEST[$required]+x} ]] &&
			po_die "$file: required key '${required#*.}' missing from [${required%%.*}]"
	done
	po_manifest_check_templates
}

po_manifest_known_section() {
	local k
	[[ $1 == gate.legs ]] && return 0
	for k in "${!PO_SCHEMA[@]}"; do
		[[ ${k%%.*} == "$1" ]] && return 0
	done
	return 1
}

# po_manifest_string <text> <where>: read one basic string from the start
# of <text> into PO_PARSED; only a comment may follow it.
po_manifest_string() {
	local text=${1:1} where=$2 out='' c i=0 n
	n=${#text}
	while ((i < n)); do
		c=${text:i:1}
		if [[ $c == "\\" ]]; then
			c=${text:i+1:1}
			case $c in
			'"' | "\\") out+=$c ;;
			*) po_die "$where: unsupported escape \\$c in string" ;;
			esac
			i=$((i + 2))
			continue
		fi
		if [[ $c == '"' ]]; then
			local tail=${text:i+1}
			tail=${tail#"${tail%%[![:blank:]]*}"}
			[[ -z $tail || $tail == '#'* ]] ||
				po_die "$where: unexpected text after string: $tail"
			PO_PARSED=$out
			return 0
		fi
		out+=$c
		i=$((i + 1))
	done
	po_die "$where: unterminated string"
}

# po_manifest_array <text> <where>: read `["a", "b"]` (one line, basic
# strings, optional trailing comment) into PO_PARSED, the strings joined by
# newlines. `[]` gives an empty PO_PARSED; an empty string is a blank line.
po_manifest_array() {
	local text=$1 where=$2 out='' sep='' s
	[[ $text == '['* ]] || po_die "$where: value must be an array of \"strings\": $text"
	text=${text:1}
	text=${text#"${text%%[![:blank:]]*}"}
	while :; do
		if [[ $text == ']'* ]]; then
			text=${text:1}
			text=${text#"${text%%[![:blank:]]*}"}
			[[ -z $text || $text == '#'* ]] ||
				po_die "$where: unexpected text after array: $text"
			PO_PARSED=$out
			return 0
		fi
		[[ $text == '"'* ]] || po_die "$where: array elements must be \"quoted strings\": $text"
		po_manifest_string_prefix "$text" "$where" || exit 2
		s=$PO_PARSED text=$PO_REST
		out+=$sep$s sep=$'\n'
		text=${text#"${text%%[![:blank:]]*}"}
		if [[ $text == ,* ]]; then
			text=${text:1}
			text=${text#"${text%%[![:blank:]]*}"}
			[[ $text != ']'* ]] || po_die "$where: trailing comma in array"
		elif [[ $text != ']'* ]]; then
			po_die "$where: expected ',' or ']' in array: $text"
		fi
	done
}

# po_manifest_string_prefix <text> <where>: read one basic string from the
# start of <text> into PO_PARSED, what follows its closing quote into PO_REST.
po_manifest_string_prefix() {
	local text=${1:1} where=$2 out='' c i=0 n
	n=${#text}
	while ((i < n)); do
		c=${text:i:1}
		if [[ $c == "\\" ]]; then
			c=${text:i+1:1}
			case $c in
			'"' | "\\") out+=$c ;;
			*) po_die "$where: unsupported escape \\$c in string" ;;
			esac
			i=$((i + 2))
			continue
		fi
		if [[ $c == '"' ]]; then
			PO_PARSED=$out PO_REST=${text:i+1}
			return 0
		fi
		out+=$c
		i=$((i + 1))
	done
	po_die "$where: unterminated string"
}

# Every template the kit fills must carry {version} exactly once.
po_manifest_check_templates() {
	local key value rest
	for key in versioning.tag layout.branch versioning.item_commit; do
		[[ -n ${PO_MANIFEST[$key]+x} ]] || continue
		value=${PO_MANIFEST[$key]}
		rest=${value#*\{version\}}
		[[ $rest != "$value" && $rest != *'{version}'* ]] ||
			po_die "$PO_MANIFEST_FILE: '${key#*.}' must contain {version} exactly once: $value"
	done
}

# po_get <section.key>: the value, or its default, or die.
po_get() {
	if [[ -n ${PO_MANIFEST[$1]+x} ]]; then
		printf '%s' "${PO_MANIFEST[$1]}"
	elif [[ -n ${PO_DEFAULTS[$1]+x} ]]; then
		printf '%s' "${PO_DEFAULTS[$1]}"
	else
		po_die "manifest has no '$1'"
	fi
}

# po_fill <template> <version>: substitute {version}.
po_fill() {
	printf '%s' "${1/\{version\}/$2}"
}

# po_unfill <template> <text>: the version <text> was filled from, if
# <text> has the template's shape; non-zero otherwise.
po_unfill() {
	local template=$1 text=$2 prefix suffix version
	prefix=${template%%\{version\}*}
	suffix=${template#*\{version\}}
	[[ $text == "$prefix"* && $text == *"$suffix" ]] || return 1
	version=${text#"$prefix"}
	version=${version%"$suffix"}
	[[ $version =~ ^[0-9]+(\.[0-9]+)+$ ]] || return 1
	printf '%s' "$version"
}
