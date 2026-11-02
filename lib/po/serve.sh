# shellcheck shell=bash
# po-kit: po serve — read-only. A small HTTP viewer of the gate events:
#
#   po serve [--bind <addr>] [--port <n>]
#
# The web view at /app/ takes its feed URLs from [serve.web] in po.toml
# (decisions_url, projects_url, team_url, events_url, answer_url) and its stall_minutes (default 30).
#
# The work is lib/po/serve.py (python3 standard library). It reads events only
# by running `po events --json` in this repository; it binds 127.0.0.1 unless
# told otherwise and refuses 0.0.0.0 and ::. GET only.

po_cmd_serve() {
	local -a args=()
	while (($# > 0)); do
		case $1 in
		--bind | --port)
			(($# >= 2)) || po_usage_die "serve: $1 needs a value"
			args+=("$1" "$2")
			shift 2
			;;
		*) po_usage_die "serve: unknown argument '$1'" ;;
		esac
	done
	command -v python3 >/dev/null 2>&1 || po_die "serve needs python3"
	local k v
	for k in decisions projects team events answer; do
		v=${PO_MANIFEST[serve.web.${k}_url]:-}
		[[ -z $v ]] || args+=("--$k-url" "$v")
	done
	v=${PO_MANIFEST[serve.web.stall_minutes]:-}
	[[ -z $v ]] || args+=(--stall-minutes "$v")
	PO_SLOW_AFTER=${PO_MANIFEST[stamp.slow_after]:-300} exec python3 -I "$PO_LIB/serve.py" "${args[@]}" --repo "$PWD"
}
