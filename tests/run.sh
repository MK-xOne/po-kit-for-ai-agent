#!/usr/bin/env bash
# po-kit self-tests: small throwaway repositories under a temp dir.
# covers: bin/ lib/ examples/ po.toml README.md AGENTS.md
# shellcheck disable=SC2015 # ok/bad always return 0, so "A && ok || bad" is a true if/else here
# shellcheck disable=SC2034 # RUN_DONE is read by the EXIT trap
# Usage: tests/run.sh [--only <test file>...]    (exit 0 when every case passes)
#
# --only is the fast tier's (po stamp --tier fast, [stamp.fast] in po.toml): it
# names the test files the stamp selected, repo-relative. This file's own blocks
# (the public part) run in any case; of private/tests.d/ only the files named
# run, with the files their "# needs:" lines name (fixtures they reuse), in the
# usual order.
#
# A runner with no `set -e` hides a block that dies. So: a multi-check block
# (a python heredoc or a shell function that prints several verdicts) runs
# through `block <name> <cmd...>` (a heredoc is the command's stdin), prints
# its verdicts as "ok<TAB>name<TAB>" / "FAIL<TAB>name<TAB>detail" lines and
# ends with the line "BLOCK-END <name>"; a non-zero exit or a missing marker
# is a FAIL. A heredoc that only builds a fixture or makes one request, whose
# result the next line checks, carries the comment "# helper" on the line
# above it. The audit near the end of this file fails on any other heredoc.
# The run ends with "RUN-END <passed> <failed> <blocks>", then the summary; a
# run that ends any other way prints RUN-ABORTED and exits non-zero.
set -uo pipefail
ONLY_SET=0 ONLY=()
if (($# > 0)); then
	[[ $1 == --only ]] || { printf 'usage: tests/run.sh [--only <test file>...]\n' >&2; exit 1; }
	ONLY_SET=1
	shift
	ONLY=("$@")
fi
# Hermetic: no inherited GIT_* variable (an exported GIT_DIR — a git hook
# sets one — would point every `git -C <fixture>` below at that repository,
# making fixture branches and commits there), and no user or system git
# config (signing, hooks, default branch).
for v in $(compgen -e | grep '^GIT_'); do unset "$v"; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

PO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/bin/po"
TMP=$(mktemp -d)
RUN_DONE=0
trap 'rc=$?; rm -rf "$TMP"; if ((RUN_DONE == 0)); then printf "RUN-ABORTED\n"; exit "$((rc == 0 ? 1 : rc))"; fi' EXIT
export PROJECTS_FEED_CACHE_DIR="$TMP/pf-cache" # projects-feed state never lands in a real cache dir
export SNAPSHOT_DIR="$TMP/status-snap" SNAPSHOT_TTL=0 # v0.151: the producers never read a real snapshot, and none is reused unless a test sets a TTL
pass=0 fail=0 nblocks=0

ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/     /'
}

# block <name> <cmd...>: run a multi-check block, feeding its verdict lines to
# ok/bad; a non-zero exit or a last line other than "BLOCK-END <name>" is bad.
block() {
	local name=$1 out code status label detail
	shift
	nblocks=$((nblocks + 1))
	out=$("$@" 2>&1)
	code=$?
	while IFS=$'\t' read -r status label detail; do
		case $status in
		ok) ok "$label" ;;
		FAIL) bad "$label" "$detail" ;;
		esac
	done <<<"$out"
	if ((code != 0)); then
		bad "$name aborted (exit $code)" "$(tail -n 5 <<<"$out")"
	elif [[ ${out##*$'\n'} != "BLOCK-END $name" ]]; then
		bad "$name aborted (no BLOCK-END marker)" "$(tail -n 5 <<<"$out")"
	fi
}

# expect <name> <exit> <stdout+stderr pattern> -- <po args...>
expect() {
	local name=$1 want=$2 pattern=$3 out code
	shift 4
	out=$("$PO" "$@" 2>&1)
	code=$?
	if [[ $code == "$want" ]] && grep -qE -- "$pattern" <<<"$out"; then
		ok "$name"
	else
		bad "$name (exit $code, want $want; pattern '$pattern')" "$out"
	fi
}

GOOD_MANIFEST='[versioning]
tag = "v{version}"   # comment after a string

[layout]
backlog = "docs/BACKLOG.md"
specs_dir = "docs/backlog"
worktrees = ".wt"
branch = "item-v{version}"
'

# A repo with a backlog table and spec headings, on main.
make_repo() {
	local dir=$1
	git init -q -b main "$dir"
	git -C "$dir" config user.name t
	git -C "$dir" config user.email t@example.invalid
	mkdir -p "$dir/docs/backlog"
	cat >"$dir/docs/BACKLOG.md" <<'EOF'
# Backlog

| Item | Title | Status | Spec |
|---|---|---|---|
| v1.0.1 | First | DONE | backlog/v1.md |
| v1.0.2 | Second | DONE | backlog/v1.md |
EOF
	cat >"$dir/docs/backlog/v1.md" <<'EOF'
## v1.0.1 — First — DONE
## v1.0.2 — Second — DONE (investigation — see notes)
## v1.0.3 — Third — DOING
## v1.0.4 — Fourth — PAUSED
EOF
	printf '%s' "$GOOD_MANIFEST" >"$dir/po.toml"
	git -C "$dir" add -A
	git -C "$dir" commit -qm init
	git -C "$dir" tag v1.0.2
}

R=$TMP/repo
make_repo "$R"

# ---- manifest: fail loud --------------------------------------------------
m() { printf '%s' "$1" >"$TMP/m.toml"; }
m "$GOOD_MANIFEST"
expect "good manifest parses" 0 'DOING \(1\)' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST}bogus = \"x\"
"
expect "unknown key is an error" 2 "unknown key 'bogus' in \[layout\]" -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST}[extra]
"
expect "unknown section is an error" 2 'unknown section \[extra\]' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST}backlog = \"again\"
"
expect "duplicate key is an error" 2 "set twice" -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST}[layout]
"
expect "duplicate section is an error" 2 'appears twice' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST/\"docs\/backlog\"/docs/backlog}"
expect "unquoted string is an error" 2 'must be a "quoted string"' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST/\"docs\/backlog\"/\"docs/backlog}"
expect "unterminated string is an error" 2 'unterminated string' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST/\"docs\/backlog\"/\"docs\/backlog\" trailing}"
expect "text after a string is an error" 2 'unexpected text after string' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST/\"docs\/backlog\"/\"docs\\nbacklog\"}"
expect "unsupported escape is an error" 2 'unsupported escape' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST/item-v\{version\}/item}"
expect "template without {version} is an error" 2 'must contain \{version\} exactly once' -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST/worktrees = \".wt\"/}"
expect "missing required key is an error" 2 "required key 'worktrees' missing" -- -C "$R" --manifest "$TMP/m.toml" status
m "${GOOD_MANIFEST}[versioning]
insert_segment = 4
"
expect "a section reopened later is still an error" 2 'appears twice' -- -C "$R" --manifest "$TMP/m.toml" status
m "$(printf '[versioning]\ninsert_segment = 4  # four\n')
${GOOD_MANIFEST#'[versioning]'}"
expect "an integer with a comment parses" 0 'DOING \(1\)' -- -C "$R" --manifest "$TMP/m.toml" status
printf 'tag = "x"\n' >"$TMP/m.toml"
expect "key outside any section is an error" 2 'before any \[section\]' -- -C "$R" --manifest "$TMP/m.toml" status
expect "missing manifest is an error" 2 'manifest not found' -- -C "$R" --manifest "$TMP/none.toml" status
expect "default manifest is the main worktree's po.toml" 0 'manifest  .*/repo/po.toml' -- -C "$R" status

# ---- status ---------------------------------------------------------------
out=$("$PO" -C "$R" status 2>&1)
grep -q '  v1.0.3    Third  \[docs/backlog/v1.md:3\]' <<<"$out" &&
	grep -q '  v1.0.4    PAUSED  Fourth' <<<"$out" &&
	grep -q 'tag       v1.0.2' <<<"$out" &&
	! grep -q 'v1.0.2 .*DOING' <<<"$out" &&
	ok "status reads DOING and held items from headings" || bad "status items" "$out"

git -C "$R" worktree add -q "$R/.wt/item-v1.0.3" -b item-v1.0.3
echo x >"$R/.wt/item-v1.0.3/new.txt"
git -C "$R/.wt/item-v1.0.3" add new.txt
git -C "$R/.wt/item-v1.0.3" commit -qm "v1.0.3: Third"
echo dirty >>"$R/.wt/item-v1.0.3/new.txt"
expect "status shows ahead/behind and dirty" 0 'ahead 1  behind 0' -- -C "$R" status
expect "status counts dirty lines" 0 'worktree \.wt/item-v1\.0\.3  dirty 1' -- -C "$R" status
expect "status from inside a worktree reads the same repo" 0 'v1.0.3    Third' -- -C "$R/.wt/item-v1.0.3" status
mkdir -p "$R/.wt/stray"
expect "unregistered dir under worktrees is an orphan" 0 '\.wt/stray  directory not registered' -- -C "$R" status

# A conflict: the table says DONE, a heading says DOING.
R2=$TMP/conflict
make_repo "$R2"
printf '## v1.0.1 — First — DOING\n' >>"$R2/docs/backlog/v1.md"
git -C "$R2" commit -qam conflict
expect "sources that disagree exit 3" 3 'v1.0.1  DONE at docs/BACKLOG.md:5  vs  DOING at docs/backlog/v1.md:5' -- -C "$R2" status

# Uncommitted backlog edits are not read: main is.
R3=$TMP/uncommitted
make_repo "$R3"
printf '## v1.0.9 — Ninth — DOING\n' >>"$R3/docs/backlog/v1.md"
out=$("$PO" -C "$R3" status 2>&1)
grep -q v1.0.9 <<<"$out" && bad "status read the working tree" "$out" || ok "status reads the backlog from main, not the working tree"

# An empty title cell keeps the columns straight.
R8=$TMP/notitle
make_repo "$R8"
printf '| v1.0.8 |  | DOING | x |\n' >>"$R8/docs/BACKLOG.md"
git -C "$R8" commit -qam notitle
expect "an empty title does not shift the source column" 0 '  v1\.0\.8      \[docs/BACKLOG\.md:7\]' -- -C "$R8" status

# Backlog ambiguity fails loud.
R4=$TMP/badrow
make_repo "$R4"
printf '| v1.0.5 | Fifth | DOING |\n' >>"$R4/docs/BACKLOG.md"
git -C "$R4" commit -qam badrow
expect "a row with the wrong cell count is an error" 2 'row has 3 cells, header has 4' -- -C "$R4" status
R5=$TMP/badhead
make_repo "$R5"
printf '## v1.0.6 Sixth DOING\n' >>"$R5/docs/backlog/v1.md"
git -C "$R5" commit -qam badhead
expect "a heading with no ' — ' is an error" 2 "heading has no ' — ' after its id" -- -C "$R5" status
R6=$TMP/nostatus
make_repo "$R6"
printf '## v1.0.7 — Seventh — pending\n' >>"$R6/docs/backlog/v1.md"
git -C "$R6" commit -qam nostatus
expect "a heading with no ALL-CAPS status is an error" 2 'no ALL-CAPS status' -- -C "$R6" status
R7=$TMP/liverow
make_repo "$R7"
printf '| E9 | Untagged | DOING | x |\n' >>"$R7/docs/BACKLOG.md"
git -C "$R7" commit -qam liverow
expect "a DOING row with no tag-form id is an error" 2 'DOING row has no cell in tag form' -- -C "$R7" status

# ---- prune ----------------------------------------------------------------
P=$TMP/prune
make_repo "$P"
for v in 1.0.1 1.0.2; do
	git -C "$P" worktree add -q "$P/.wt/item-v$v" -b "item-v$v"
done
git -C "$P" worktree add -q "$P/.wt/item-v1.0.4" -b item-v1.0.4 # PAUSED, at main
git -C "$P" worktree add -q "$P/.wt/item-v1.0.3" -b item-v1.0.3 # DOING, at main
git -C "$P" branch merged-no-wt
git -C "$P" worktree add -q "$P/.wt/unmerged" -b unmerged
git -C "$P/.wt/unmerged" commit -q --allow-empty -m wip
git -C "$P" worktree add -q --detach "$P/.wt/detached-merged" main
echo u >"$P/.wt/item-v1.0.2/untracked"
before=$(git -C "$P" worktree list --porcelain; git -C "$P" for-each-ref; git -C "$P" status --porcelain)
out=$("$PO" -C "$P" prune 2>&1)
after=$(git -C "$P" worktree list --porcelain; git -C "$P" for-each-ref; git -C "$P" status --porcelain)
[[ $before == "$after" ]] && ok "prune without --commit changes nothing" || bad "dry run changed state"
grep -q 'DRY RUN' <<<"$out" && ok "prune says it is a dry run" || bad "dry run banner" "$out"
plan=$(sed -n '/^WORKTREES TO REMOVE/,/^KEPT/p' <<<"$out")
grep -q '\.wt/item-v1\.0\.1  item-v1\.0\.1' <<<"$plan" &&
	grep -q '\.wt/detached-merged  detached' <<<"$plan" &&
	grep -q 'merged-no-wt' <<<"$plan" &&
	! grep -q 'item-v1\.0\.3\|item-v1\.0\.4\|unmerged\|item-v1\.0\.2' <<<"$plan" &&
	ok "prune plans merged, clean, unprotected work only" || bad "prune plan" "$out"
grep -q 'branch item-v1.0.3  — open item (DOING v1.0.3)' <<<"$out" &&
	grep -q 'branch item-v1.0.4  — open item (PAUSED v1.0.4)' <<<"$out" &&
	grep -q 'item-v1.0.2)  — dirty (1)' <<<"$out" &&
	ok "prune keeps open items and dirty worktrees, saying why" || bad "prune kept" "$out"
del=$(sed -n '/^BRANCHES TO DELETE/,/^$/p' <<<"$out" | sed '1d;/^$/d' | awk '{print $1}')
kept=$(sed -n '/^KEPT/,$p' <<<"$out" | awk '$1=="branch"{print $2}')
merged=$(git -C "$P" branch --merged main --format='%(refname:short)' | grep -vx main | sort)
[[ $(printf '%s\n%s\n' "$del" "$kept" | sort) == "$merged" ]] &&
	ok "delete + kept branches equal git branch --merged main" || bad "branch partition" "$del / $kept / $merged"

"$PO" -C "$P" prune --commit >"$TMP/commit.out" 2>&1 && ok "prune --commit exits 0" || bad "prune --commit" "$(cat "$TMP/commit.out")"
[[ ! -d $P/.wt/item-v1.0.1 && ! -d $P/.wt/detached-merged ]] &&
	! git -C "$P" show-ref -q refs/heads/item-v1.0.1 &&
	! git -C "$P" show-ref -q refs/heads/merged-no-wt &&
	ok "prune --commit removed what it planned" || bad "commit removed" "$(cat "$TMP/commit.out")"
[[ -f $P/.wt/item-v1.0.2/untracked && -d $P/.wt/item-v1.0.3 && -d $P/.wt/unmerged ]] &&
	git -C "$P" show-ref -q refs/heads/item-v1.0.4 &&
	git -C "$P" show-ref -q refs/heads/unmerged &&
	ok "prune --commit kept everything it said it would" || bad "commit kept"
out=$("$PO" -C "$P" prune 2>&1)
grep -q 'WORKTREES TO REMOVE (0)' <<<"$out" && grep -q 'BRANCHES TO DELETE (0)' <<<"$out" &&
	ok "a second prune plans nothing" || bad "second prune" "$out"
expect "prune rejects unknown arguments" 1 "unknown argument '--force'" -- -C "$P" prune --force

# ---- regressions from review ---------------------------------------------
# Unmerged detached work behind a missing directory survives --commit.
Q=$TMP/q1
make_repo "$Q"
git -C "$Q" worktree add -q --detach "$Q/.wt/lost" main
git -C "$Q/.wt/lost" commit -q --allow-empty -m only-here
lost=$(git -C "$Q/.wt/lost" rev-parse HEAD)
git -C "$Q" worktree add -q --detach "$Q/.wt/gone" main
rm -rf "$Q/.wt/lost" "$Q/.wt/gone"
out=$("$PO" -C "$Q" prune --commit 2>&1)
grep -q 'directory missing, detached HEAD not on main' <<<"$out" &&
	git -C "$Q" worktree list --porcelain | grep -q "HEAD $lost" &&
	! git -C "$Q" worktree list --porcelain | grep -q "/.wt/gone$" &&
	grep -q "pruned stale registration .wt/gone" <<<"$out" &&
	ok "a missing dir with unmerged detached HEAD is kept beside a pruned one" || bad "lost detached work" "$out"

# Near-miss open statuses fail loud instead of reading as not-open.
for case in '**DOING**' 'Doing' 'DOING (Sam)'; do
	Q=$TMP/q2-${#case}
	make_repo "$Q"
	printf '| v1.0.5 | Fifth | %s | x |\n' "$case" >>"$Q/docs/BACKLOG.md"
	git -C "$Q" commit -qam near
	expect "table status '$case' is an error" 2 "status '.*' is not written exactly as DOING" -- -C "$Q" prune
done
Q=$TMP/q2h
make_repo "$Q"
sed -i 's/| Item | Title | Status | Spec |/| Item | Title | **Status** | Spec |/' "$Q/docs/BACKLOG.md"
git -C "$Q" commit -qam hdr
expect "a decorated Status header is an error" 2 "column header .* is not written exactly as Status" -- -C "$Q" status
Q=$TMP/q2s
make_repo "$Q"
printf '## v1.2.0 — Fix flaky tests — CI only — DOING\n' >>"$Q/docs/backlog/v1.md"
git -C "$Q" commit -qam twocaps
expect "two status-like heading segments are an error" 2 "two status-like segments \('CI', 'DOING'\)" -- -C "$Q" status
Q=$TMP/q2d
make_repo "$Q"
printf '## v1.2.1 — Lower — doing\n' >>"$Q/docs/backlog/v1.md"
git -C "$Q" commit -qam lower
expect "a lower-case heading status is an error" 2 "status 'doing' is not written exactly as DOING" -- -C "$Q" status
Q=$TMP/q2c
make_repo "$Q"
printf '## v1.0.1 — First — DOING\n' >>"$Q/docs/backlog/v1.md"
git -C "$Q" commit -qam conflict
expect "prune --commit refuses while the backlog conflicts" 2 'refusing --commit while the backlog has conflicts' -- -C "$Q" prune --commit
expect "prune dry run still shows the plan and the conflict" 0 'CONFLICTS \(1\)' -- -C "$Q" prune

# Spec files whose names git would quote are read.
Q=$TMP/q3
make_repo "$Q"
printf '## v1.3.0 — Accented — DOING\n' >"$Q/docs/backlog/épique.md"
printf '## v1.3.1 — Quoted — DOING\n' >"$Q/docs/backlog/a\"b.md"
git -C "$Q" add -A && git -C "$Q" commit -qm names
out=$("$PO" -C "$Q" status 2>&1)
grep -q 'v1.3.0    Accented' <<<"$out" && grep -q 'v1.3.1    Quoted' <<<"$out" &&
	ok "spec files with non-ASCII or quote characters are read" || bad "quoted names" "$out"

# A worktree stopped mid-rebase, and its branch, are kept.
Q=$TMP/q4
make_repo "$Q"
git -C "$Q" worktree add -q "$Q/.wt/item-v1.1.0" -b item-v1.1.0
git -C "$Q/.wt/item-v1.1.0" commit -q --allow-empty -m one
git -C "$Q/.wt/item-v1.1.0" commit -q --allow-empty -m two
git -C "$Q" merge -q --ff-only item-v1.1.0
GIT_SEQUENCE_EDITOR="sed -i 1s/^pick/edit/" git -C "$Q/.wt/item-v1.1.0" rebase -q -i --keep-empty HEAD~2 >/dev/null 2>&1
out=$("$PO" -C "$Q" prune --commit 2>&1)
grep -q 'rebase in progress' <<<"$out" && [[ -d $Q/.wt/item-v1.1.0 ]] &&
	git -C "$Q" show-ref -q refs/heads/item-v1.1.0 &&
	ok "a stopped rebase keeps its worktree and branch" || bad "mid-rebase" "$out"

# Ignored files keep a worktree.
Q=$TMP/q5
make_repo "$Q"
printf 'secrets.env\n' >"$Q/.gitignore"
git -C "$Q" add .gitignore && git -C "$Q" commit -qm ignore
git -C "$Q" worktree add -q "$Q/.wt/item-v1.0.1" -b item-v1.0.1
echo s >"$Q/.wt/item-v1.0.1/secrets.env"
git -C "$Q" worktree add -q "$Q/.wt/item-v1.0.2" -b item-v1.0.2
printf 'target/\n' >>"$Q/.gitignore"
mkdir "$Q/.wt/item-v1.0.2/target"
out=$("$PO" -C "$Q" prune --commit 2>&1)
grep -q 'ignored files (1)' <<<"$out" && [[ -f $Q/.wt/item-v1.0.1/secrets.env ]] &&
	ok "ignored files keep a worktree" || bad "ignored files" "$out"
grep -q 'removed worktree .wt/item-v1.0.2' <<<"$out" && [[ ! -e $Q/.wt/item-v1.0.2 ]] &&
	ok "an empty ignored directory does not keep a worktree" || bad "empty ignored dir" "$out"

# Only tags in exact tag form count as the latest tag.
Q=$TMP/q6
make_repo "$Q"
git -C "$Q" tag v1.0.0x
git -C "$Q" tag v1.1.0-rc1
git -C "$Q" tag v1.0.10
expect "the latest tag is the highest exact tag-form tag" 0 'tag       v1\.0\.10 ' -- -C "$Q" status

# Table cells are not glob-expanded.
Q=$TMP/q7
make_repo "$Q"
printf '| v1.0.7 | * | DONE | x |\n' >>"$Q/docs/BACKLOG.md"
git -C "$Q" commit -qam glob
expect "a '*' cell is read as text" 0 'DOING \(1\)' -- -C "$Q" status

# ---- stamp ----------------------------------------------------------------
S=$TMP/stamp
make_repo "$S"
cat >"$S/fake-test.sh" <<'EOF'
echo "   Compiling fake"
echo "test result: ok. ${PASSED_A:-3} passed; 0 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.01s"
echo "   Doc-tests fake"
echo "test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"
EOF
git -C "$S" add fake-test.sh && git -C "$S" commit -qm fake
git -C "$S" worktree add -q "$S/.wt/item-v1.0.3" -b item-v1.0.3
W=$S/.wt/item-v1.0.3
printf 'a\nb\n' >"$W/new.txt"
git -C "$W" add new.txt && git -C "$W" commit -qm "v1.0.3: Third"
git -C "$S" commit -q --allow-empty -m "main moves on"

# stamp_manifest <leg>...: the good manifest plus a gate, each leg as
# "name=command"; COUNT_CMD overrides the test count command, PREPARE is
# the raw value of [stamp] prepare, TEST_FILES and TEST_DEF those of
# [stamp] test_files and test_def.
stamp_manifest() {
	local leg
	{
		printf '%s' "$GOOD_MANIFEST"
		[[ -z ${PREPARE:-}${SLOW_AFTER:-}${TEST_FILES:-}${TEST_DEF:-} ]] || printf '[stamp]\n'
		[[ -z ${PREPARE:-} ]] || printf 'prepare = %s\n' "$PREPARE"
		[[ -z ${SLOW_AFTER:-} ]] || printf 'slow_after = %s\n' "$SLOW_AFTER"
		[[ -z ${TEST_FILES:-} ]] || printf 'test_files = %s\n' "$TEST_FILES"
		[[ -z ${TEST_DEF:-} ]] || printf 'test_def = %s\n' "$TEST_DEF"
		printf '[gate]\ntest_count_cmd = "%s"\n' "${COUNT_CMD:-sh ./fake-test.sh 2>&1}"
		[[ -z ${SENTINEL:-} ]] || printf 'run_sentinel = "required"\n'
		[[ -z ${TEST_FORMAT:-} ]] || printf 'test_format = "%s"\n' "$TEST_FORMAT"
		[[ -z ${DRAIN:-} ]] || printf 'drain_secs = %s\n' "$DRAIN"
		[[ -z ${SCOPE:-} ]] || printf 'scope = %s\n' "$SCOPE"
		printf '[gate.legs]\n'
		for leg; do printf '%s = "%s"\n' "${leg%%=*}" "${leg#*=}"; done
	} >"$TMP/s.toml"
}
STD_LEGS=(check=true "test=sh ./fake-test.sh" clippy=true fmt=true)
stamp_manifest "${STD_LEGS[@]}"
state() {
	git -C "$1" status --porcelain --untracked-files=all
	git -C "$S" for-each-ref
	git -C "$S" worktree list --porcelain
}

before=$(state "$W")
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
code=$?
want=$(
	printf 'HEAD %s (item-v1.0.3)  dirty 0\n' "$(git -C "$W" rev-parse HEAD)"
	printf 'gate PASS: check/test/clippy/fmt   tests 5 passed\n'
	printf 'diffstat vs merge-base(main): %s\n' "$(git -C "$W" diff --shortstat "$(git -C "$W" merge-base main HEAD)" HEAD | sed 's/^ //')"
)
[[ $code == 0 && $out == "$want" ]] && ok "stamp prints the block from the worktree's own state" ||
	bad "stamp block (exit $code)" "$out"$'\n--- want\n'"$want"
[[ $(cat "$W/gate-1.txt") == "$want" ]] && ok "stamp writes the same block to gate-1.txt" ||
	bad "gate-1.txt" "$(cat "$W/gate-1.txt" 2>&1)"
[[ $(state "$W") == "?? gate-1.txt"$'\n'"$before" ]] && ok "stamp writes nothing but gate-1.txt" ||
	bad "stamp side effects" "$(state "$W")"
[[ ! -e $S/gate-1.txt ]] && ok "stamp writes in the worktree it runs in, not main" || bad "stamp wrote in main"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
[[ -f $W/gate-2.txt && $(cat "$W/gate-1.txt") == "$want" ]] && grep -q 'dirty 0' <<<"$out" &&
	ok "a second stamp appends gate-2.txt; stamp files are not dirt" || bad "second stamp" "$out"
printf 'old\n' >"$W/gate-7.txt"
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
[[ -f $W/gate-8.txt && $(cat "$W/gate-7.txt") == old ]] &&
	ok "numbering continues past the highest stamp file" || bad "numbering" "$(ls "$W")"
rm -f "$W"/gate-*.txt

echo more >>"$W/new.txt"
expect "dirt in the worktree is counted in the block" 0 'dirty 1' -- -C "$W" --manifest "$TMP/s.toml" stamp
git -C "$W" checkout -q -- new.txt
rm -f "$W"/gate-*.txt

# Logged to a file, stderr keeps po's own lines beside the gate's output.
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>"$TMP/stamp.err"
grep -q '^po stamp: gate in ' "$TMP/stamp.err" && grep -q '^   Doc-tests fake$' "$TMP/stamp.err" &&
	grep -q '^po stamp: wrote ' "$TMP/stamp.err" &&
	ok "stderr sent to a file keeps every line" || bad "stderr log" "$(cat "$TMP/stamp.err")"
rm -f "$W"/gate-*.txt

# Every failure: exit 4, the reason named, no file.
stamp_fails() { # <name> <pattern> [stamp args]
	local name=$1 pattern=$2
	shift 2
	expect "$name" 4 "$pattern" -- -C "$W" --manifest "$TMP/s.toml" stamp "$@"
	compgen -G "$W/gate-*.txt" >/dev/null && bad "$name: a stamp file was written" "$(ls "$W")" ||
		ok "$name: no stamp file"
}
stamp_manifest check=true "test=sh ./fake-test.sh" "clippy=echo lint >&2; exit 3" fmt=true
stamp_fails "a failing leg is named" "gate leg 'clippy' \(echo lint >&2; exit 3\) exited 3"
stamp_manifest "${STD_LEGS[@]}" "last=false"
stamp_fails "the last leg failing still writes nothing" "gate leg 'last'"
COUNT_CMD="echo no tests here" stamp_manifest "${STD_LEGS[@]}"
stamp_fails "a count command with no summary line fails" "printed no 'test result:' line"
COUNT_CMD="PASSED_A=4 sh ./fake-test.sh" stamp_manifest "${STD_LEGS[@]}"
stamp_fails "a count that disagrees with the gate's fails" 'the gate passed 5 tests but test_count_cmd counted 6'
COUNT_CMD="echo 'test result: FAILED. 1 passed; 1 failed;'" stamp_manifest check=true
stamp_fails "a summary that is not ok fails" 'printed a summary that is not ok'
COUNT_CMD="sh ./fake-test.sh; exit 101" stamp_manifest check=true
stamp_fails "a count command that exits non-zero fails" 'exited 101'
# A failed stamp prints the memory prompt after its failure lines; a passing one does not.
stamp_manifest check=true "test=sh ./fake-test.sh" "clippy=echo lint >&2; exit 3" fmt=true
rm -f "$W"/gate-*.txt
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1 >/dev/null)
code=$?
[[ $code == 4 && ${out##*$'\n'} == "memory: file a proposal or record 'nothing new learned' with the close body" ]] &&
	grep -q '^po stamp: no evidence written$' <<<"$out" &&
	ok "a failed stamp prints the memory prompt last and still exits 4" || bad "stamp failure prompt (exit $code)" "$out"
[[ -z $("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null) ]] && ok "a failed stamp's stdout stays empty" || bad "failed stamp stdout"
stamp_manifest "${STD_LEGS[@]}"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1 >/dev/null)
! grep -q '^memory:' <<<"$out" && ok "a passing stamp prints no memory prompt" || bad "passing stamp prompt" "$out"
# The evidence block of a passing stamp is unchanged by the memory prompt.
rm -f "$W"/gate-*.txt
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
[[ $out == "$want" && $(cat "$W/gate-1.txt" 2>&1) == "$want" ]] &&
	ok "a passing stamp's evidence block is byte-identical to the expected block" || bad "passing stamp block" "$out"$'\n--- file\n'"$(cat "$W/gate-1.txt" 2>&1)"
rm -f "$W"/gate-*.txt
# A command that leaves a process holding its output must not hang the stamp.
# LEAK_SLEEP names the leftover (unique per suite run: the zero-padded PID is
# in the duration, so pgrep finds only ours even with two suites at once); the
# leaker prints a good summary, so the leftover is the only fault.
LEAK_ID=$(printf '%07d' $$)
LEAK_SLEEP=3171.$LEAK_ID LEAK_TERM_SLEEP=3172.$LEAK_ID
printf '%s\n' "sleep $LEAK_SLEEP &" 'echo "test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"' >"$TMP/z-leak.sh"
printf '%s\n' "( trap '' TERM; exec sleep $LEAK_TERM_SLEEP ) &" 'echo "test result: ok. 5 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"' >"$TMP/z-leak-term.sh"
now_ms() { echo $(($(date +%s%N) / 1000000)); }
leak_gone() { ! pgrep -f "sleep $1" >/dev/null; }
rm -f "$W"/gate-*.txt
if systemd-run --user --scope --quiet true >/dev/null 2>&1 && command -v pgrep >/dev/null; then
	DRAIN=1 COUNT_CMD=cat stamp_manifest "test=sh $TMP/z-leak.sh"
	t0=$(now_ms)
	out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$? ms=$(($(now_ms) - t0))
	[[ $code == 4 ]] && grep -q 'po stamp: FAIL: 1 process(es) left behind by leg test: sleep' <<<"$out" &&
		ok "leftover: a leaked process fails the stamp and is named" || bad "leftover fails (exit $code)" "$out"
	((ms < 4000)) && ok "leftover: the stamp ends within the grace plus the sweep (${ms} ms)" || bad "leftover time ${ms} ms" "$out"
	leak_gone "$LEAK_SLEEP" && ok "leftover: the leaked process is gone afterward" || bad "leftover still alive" "$(pgrep -af "sleep $LEAK_SLEEP")"
	zlog=$(sed -n 's/^po stamp: the full output is in //p' <<<"$out")
	[[ -f $zlog ]] && grep -q '^== leg test: .* (exit 0)$' "$zlog" && grep -q '^test result: ok. 5 passed' "$zlog" &&
		! compgen -G "$W/gate-*.txt" >/dev/null &&
		ok "leftover: the log keeps the command's real exit code and result line; no stamp file" || bad "leftover log" "$zlog"
	pkill -f "sleep $LEAK_SLEEP" 2>/dev/null

	# Nested: the stamp itself already runs in a scope of its own.
	t0=$(now_ms)
	out=$(systemd-run --user --scope --quiet "$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$? ms=$(($(now_ms) - t0))
	[[ $code == 4 ]] && grep -q 'left behind by leg test: sleep' <<<"$out" && ((ms < 4000)) && leak_gone "$LEAK_SLEEP" &&
		ok "leftover: works when the stamp already runs in a scope" || bad "leftover nested (exit $code, ${ms} ms)" "$out"
	pkill -f "sleep $LEAK_SLEEP" 2>/dev/null
	COUNT_CMD="sh ./fake-test.sh 2>&1" stamp_manifest "${STD_LEGS[@]}"
	out=$(systemd-run --user --scope --quiet "$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$?
	[[ $code == 0 ]] && ! grep -q 'left behind' <<<"$out" && grep -qx 'gate PASS: check/test/clippy/fmt   tests 5 passed' <<<"$out" &&
		ok "leftover: a clean gate in a nested scope passes with no leftover line" || bad "clean nested" "$out"
	rm -f "$W"/gate-*.txt

	# A child that ignores SIGTERM is killed by the fallback, not waited for.
	DRAIN=1 COUNT_CMD=cat stamp_manifest "test=sh $TMP/z-leak-term.sh"
	t0=$(now_ms)
	out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$? ms=$(($(now_ms) - t0))
	[[ $code == 4 ]] && grep -q 'left behind by leg test: sleep' <<<"$out" && ((ms < 8000)) && leak_gone "$LEAK_TERM_SLEEP" &&
		ok "leftover: a SIGTERM-ignoring child is killed within a few seconds (${ms} ms)" || bad "sigterm child (exit $code, ${ms} ms)" "$out"
	pkill -f "sleep $LEAK_TERM_SLEEP" 2>/dev/null
else
	ok "SKIPPED: leftover scope tests (systemctl --user or pgrep unusable here)"
fi

# The grace alone, with no scope: PO_STAMP_NO_SCOPE=1 and [gate] scope = false
# keep the old result (the leak is not detected) but the stamp does not hang.
for how in env key; do
	rm -f "$W"/gate-*.txt
	if [[ $how == env ]]; then
		DRAIN=1 COUNT_CMD=cat stamp_manifest "test=sh $TMP/z-leak.sh"
	else
		SCOPE=false DRAIN=1 COUNT_CMD=cat stamp_manifest "test=sh $TMP/z-leak.sh"
	fi
	t0=$(now_ms)
	out=$(PO_STAMP_NO_SCOPE=$([[ $how == env ]] && echo 1) "$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$? ms=$(($(now_ms) - t0))
	[[ $code == 0 && -f $W/gate-1.txt ]] && ! grep -q 'left behind' <<<"$out" && ((ms < 3000)) &&
		ok "no scope ($how): the stamp passes within the grace and does not hang (${ms} ms)" || bad "no scope $how (exit $code, ${ms} ms)" "$out"
	pkill -f "sleep $LEAK_SLEEP" 2>/dev/null
done
rm -f "$W"/gate-*.txt

# systemd-run absent: a PATH without it; the legs run unscoped, one warning.
NOSD=$TMP/nosd
mkdir "$NOSD"
for f in /usr/bin/*; do [[ ${f##*/} == systemd-run ]] || ln -s "$f" "$NOSD/${f##*/}"; done
COUNT_CMD="sh ./fake-test.sh 2>&1" stamp_manifest "${STD_LEGS[@]}"
out=$(PATH=$NOSD "$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 0 && $(grep -c 'warning: systemd-run not found' <<<"$out") == 1 ]] &&
	grep -qx 'gate PASS: check/test/clippy/fmt   tests 5 passed' <<<"$out" &&
	ok "systemd-run absent: the gate runs unscoped and warns once" || bad "systemd-run absent (exit $code)" "$out"
rm -f "$W"/gate-*.txt
DRAIN='"x"' stamp_manifest "${STD_LEGS[@]}"
expect "drain_secs must be an integer" 2 'drain_secs must be an integer' -- -C "$W" --manifest "$TMP/s.toml" stamp
rm -f "$W"/gate-*.txt

# The test leg's saved output is the count: the suite runs once (a runner that
# logs each invocation), test_count_cmd is only a filter over that output.
RUNS=$TMP/suite-runs
SUITE="echo run >>$RUNS; sh ./fake-test.sh"
count_runs() { grep -c run "$RUNS" 2>/dev/null || true; }
rm -f "$RUNS"
stamp_manifest check=true "test=$SUITE"
sed -i '/test_count_cmd/d' "$TMP/s.toml"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
[[ $(count_runs) == 1 ]] && grep -qx 'gate PASS: check/test   tests 5 passed' <<<"$out" &&
	ok "a stamp with a test leg runs the suite once and counts from its output" ||
	bad "suite run once" "runs $(count_runs): $out"
rm -f "$W"/gate-*.txt "$RUNS"
COUNT_CMD="grep -v Compiling" stamp_manifest check=true "test=$SUITE"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
[[ $(count_runs) == 1 ]] && grep -qx 'gate PASS: check/test   tests 5 passed' <<<"$out" &&
	ok "test_count_cmd filters the test leg's saved output without rerunning it" ||
	bad "filter over saved output" "runs $(count_runs): $out"
rm -f "$W"/gate-*.txt "$RUNS"
COUNT_CMD="grep -m1 '^test result'" stamp_manifest check=true "test=$SUITE"
stamp_fails "the filter's output is what the cross-check counts" 'the gate passed 5 tests but test_count_cmd counted 3'
rm -f "$RUNS"
COUNT_CMD="echo no tests here" stamp_manifest check=true "test=$SUITE"
stamp_fails "a filter that drops the summary fails" "printed no 'test result:' line"
rm -f "$RUNS"
COUNT_CMD="exit 3" stamp_manifest check=true "test=$SUITE"
stamp_fails "a failing filter fails the stamp" 'exited 3'
rm -f "$RUNS"
COUNT_CMD="$SUITE" stamp_manifest check=true
sed -i '/^\[gate.legs\]/,$d' "$TMP/s.toml"
printf 'command = "%s"\n' "$SUITE" >>"$TMP/s.toml"
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
[[ $(count_runs) == 2 ]] && ok "with no test leg test_count_cmd still reruns the suite" || bad "no test leg" "runs $(count_runs)"
rm -f "$W"/gate-*.txt "$RUNS"
# The count taken from the test leg is checked against that leg's own summary:
# another leg printing one (doc, integration) adds nothing to the comparison.
UNIT2="unit=echo 'test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s'"
TEST3="test=echo 'test result: ok. 3 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s'"
stamp_manifest "$UNIT2" "$TEST3"
sed -i '/test_count_cmd/d' "$TMP/s.toml"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx 'gate PASS: unit/test   tests 3 passed' <<<"$out" &&
	ok "legs unit and test with no test_count_cmd: the test leg's own count, 3" ||
	bad "unit + test legs, no count cmd (exit $code)" "$out"
rm -f "$W"/gate-*.txt
COUNT_CMD="cat" stamp_manifest "$UNIT2" "$TEST3"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx 'gate PASS: unit/test   tests 3 passed' <<<"$out" &&
	ok "legs unit and test with a filtering test_count_cmd: the test leg's own count, 3" ||
	bad "unit + test legs, filter (exit $code)" "$out"
rm -f "$W"/gate-*.txt
COUNT_CMD="sed s/3/4/" stamp_manifest "$UNIT2" "$TEST3"
stamp_fails "a filter counting other than the test leg still fails beside another leg" 'the gate passed 3 tests but test_count_cmd counted 4'
stamp_manifest "${STD_LEGS[@]}"

stamp_manifest "${STD_LEGS[@]}" "touchy=echo z >>new.txt"
stamp_fails "a tracked file changed by the gate fails the stamp" 'the worktree changed while the gate ran'
git -C "$W" checkout -q -- new.txt
stamp_manifest "${STD_LEGS[@]}" "touchy=echo z >made.txt"
stamp_fails "an untracked file made by the gate fails the stamp" 'the worktree changed while the gate ran'
rm -f "$W/made.txt"
stamp_manifest "${STD_LEGS[@]}"
stamp_fails "a missing --bin fails after the gate" 'is not a file' --bin nowhere
expect "--bin missing its path is a usage error" 1 '--bin needs a path' -- -C "$W" --manifest "$TMP/s.toml" stamp --bin
expect "stamp rejects unknown arguments" 1 "unknown argument '--commit'" -- -C "$W" --manifest "$TMP/s.toml" stamp --commit
rm -f "$W"/gate-*.txt

# --bin: hashed after the gate, its path relative to where po was started.
mkdir -p "$W/out"
printf 'binary\n' >"$W/out/app"
out=$(cd "$W/out" && "$PO" --manifest "$TMP/s.toml" stamp --bin app 2>/dev/null)
grep -qxF "bin sha256 $(sha256sum "$W/out/app" | cut -d' ' -f1) (out/app)" <<<"$out" &&
	ok "--bin adds the file's sha256, shown relative to the worktree" || bad "--bin line" "$out"
rm -rf "$W/out" "$W"/gate-*.txt
stamp_manifest "${STD_LEGS[@]}" "build=printf built >$TMP/built-app"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp --bin "$TMP/built-app" 2>/dev/null)
grep -qxF "bin sha256 $(printf built | sha256sum | cut -d' ' -f1) ($TMP/built-app)" <<<"$out" &&
	ok "a --bin the gate builds is hashed after it; outside paths are absolute" || bad "--bin after gate" "$out"
rm -f "$W"/gate-*.txt

# pytest counting ([gate] test_format = "pytest"): fixture outputs.
py_stamp() { # <name> <count output line(s)> <want: "N" counted, or a refusal pattern> [leg ...]
	local name=$1 text=$2 want=$3 out code
	shift 3
	printf '%b' "$text" >"$TMP/py-out.txt"
	COUNT_CMD="cat $TMP/py-out.txt" TEST_FORMAT=pytest stamp_manifest check=true "$@"
	out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$?
	if [[ $want =~ ^[0-9]+$ ]]; then
		[[ $code == 0 ]] && grep -qx "gate PASS: check.*   tests $want passed" <<<"$out" &&
			ok "pytest: $name counts $want" || bad "pytest: $name (exit $code, want $want counted)" "$out"
	else
		[[ $code == 4 ]] && grep -qE -- "$want" <<<"$out" && ! compgen -G "$W/gate-*.txt" >/dev/null &&
			ok "pytest: $name is refused, nothing written" || bad "pytest: $name (exit $code; pattern '$want')" "$out"
	fi
	rm -f "$W"/gate-*.txt
}
py_stamp "passed only (default format)" '============================== 223 passed in 1.23s ==============================' 223
py_stamp "passed only (-q format)" '3 passed in 0.01s' 3
py_stamp "passed and skipped" '=== 3 passed, 1 skipped in 0.5s ===' 3
py_stamp "passed and skipped (-q)" '3 passed, 1 skipped in 0.50s' 3
py_stamp "passed with warnings, xfailed, deselected" '== 5 passed, 2 xfailed, 1 deselected, 1 warning in 0.5s ==' 5
py_stamp "a long run's (h:mm:ss) time" '= 7 passed in 61.23s (0:01:01) =' 7
py_stamp "passed with subtests" '== 3 passed, 2 subtests passed in 0.5s ==' 3
py_stamp "text around the summary" 'collected 3 items\n\ntest_a.py ...  [100%]\n\n3 passed in 0.01s\n' 3
py_stamp "the last summary line wins" '1 passed in 0.1s\n== 4 passed in 0.2s ==' 4
py_stamp "failed" '=== 1 failed, 2 passed in 0.5s ===' 'printed a pytest summary that is not ok: .*1 failed'
py_stamp "failed only (-q)" '1 failed in 0.5s' 'not ok: 1 failed'
py_stamp "one error" '== 1 passed, 1 error in 0.5s ==' 'not ok: .*1 error'
py_stamp "errors" '=== 2 errors in 0.12s ===' 'not ok: .*2 errors'
py_stamp "failed and errors and skipped" '1 failed, 1 passed, 1 skipped, 2 errors in 1.0s' 'not ok'
py_stamp "a summary naming a failure wins over an earlier ok one" '3 passed in 0.1s\n== 1 failed in 0.2s ==' 'not ok'
py_stamp "no summary" 'collected 3 items' "printed no pytest summary"
py_stamp "no output" '' "printed no pytest summary"
py_stamp "skipped only has no passed tests" '== 2 skipped in 0.1s ==' 'no passed tests'
py_stamp "no tests ran" '=== no tests ran in 0.01s ===' 'no passed tests'
py_stamp "a libtest line is not a pytest summary" 'test result: ok. 3 passed; 0 failed;' "printed no pytest summary"
py_stamp "an unfinished summary is not a summary" '3 passed' "printed no pytest summary"
# The cross-check: a gate leg that prints a summary must agree with test_count_cmd.
py_stamp "a gate leg's summary agreeing with the count" '3 passed in 0.1s' 3 "test=echo '== 3 passed in 0.1s =='"
py_stamp "a gate leg's disagreeing summary" '3 passed in 0.1s' 'the gate passed 4 tests but test_count_cmd counted 3' "test=echo '4 passed in 0.1s'"
py_stamp "two gate legs' summaries add up" '5 passed in 0.1s' 5 "unit=echo '2 passed in 0.1s'" "integ=echo '3 passed in 0.1s'"
py_stamp "a test leg is compared with its own summary, not another leg's" '3 passed in 0.1s' 3 "unit=echo '2 passed in 0.1s'" "test=echo '3 passed in 0.1s'"
py_stamp "a gate leg without a summary is not counted" '3 passed in 0.1s' 3 "lint=echo all good"
py_stamp "a gate leg printing a failed summary fails" '3 passed in 0.1s' "gate leg 'test' printed a pytest summary that is not ok" "test=echo '1 failed in 0.1s'"
# libtest is untouched: the default, and the explicit value.
COUNT_CMD="echo '3 passed in 0.1s'" stamp_manifest check=true
stamp_fails "libtest is the default: a pytest line is no libtest summary" "printed no 'test result:' line"
TEST_FORMAT=libtest stamp_manifest "${STD_LEGS[@]}"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
grep -qx 'gate PASS: check/test/clippy/fmt   tests 5 passed' <<<"$out" && ok 'test_format = "libtest" counts as before' || bad "explicit libtest" "$out"
rm -f "$W"/gate-*.txt
COUNT_CMD="echo '3 passed in 0.1s'" TEST_FORMAT=pytest stamp_manifest check=true "test=echo 'test result: ok. 9 passed; 0 failed;'"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
grep -qx 'gate PASS: check/test   tests 3 passed' <<<"$out" && ok "pytest format ignores libtest lines in a leg" || bad "pytest ignores libtest" "$out"
rm -f "$W"/gate-*.txt
printf '%s[gate]\ntest_format = "nose"\n' "$GOOD_MANIFEST" >"$TMP/m.toml"
expect "an unknown test_format is an error" 2 'test_format must be "libtest", "pytest" or "gradle": nose' -- -C "$W" --manifest "$TMP/m.toml" stamp
printf '%s[gate]\ntest_format = "pytest"\ncommand = "true"\n' "$GOOD_MANIFEST" >"$TMP/m.toml"
expect "test_format is a known key" 2 "manifest has no 'gate.test_count_cmd'" -- -C "$W" --manifest "$TMP/m.toml" stamp

# Gradle counting ([gate] test_format = "gradle"): the count is read from the
# JUnit XML reports the test leg wrote, not from output.
GX=$TMP/gx
mkdir -p "$GX"
gx_suite() { # <file> <tests> <failures> <errors> <skipped>
	printf '<?xml version="1.0" encoding="UTF-8"?>\n<testsuite name="s" tests="%s" skipped="%s" failures="%s" errors="%s" timestamp="2026-01-01T00:00:00" hostname="h" time="0.1">\n<testcase name="a" classname="c"/>\n</testsuite>\n' "$2" "$5" "$3" "$4" >"$GX/$1.xml"
}
gx_suite pass 3 0 0 0
gx_suite fail 3 1 0 0
gx_suite err 3 0 1 0
gx_suite skip 4 0 0 1
gx_suite zero 0 0 0 0
gx_suite allskip 2 0 0 2
gx_suite m1 2 0 0 0
gx_suite m2 5 0 0 1
printf '<testsuites>\n<testsuite name="a" tests="2" skipped="0" failures="0" errors="0"/>\n<testsuite name="b" tests="3" skipped="1" failures="0" errors="0"/>\n</testsuites>\n' >"$GX/wrapper.xml"
printf '<testsuite name="a" tests="3"\n' >"$GX/broken.xml"
printf 'build/\nout/\n' >>"$(git -C "$W" rev-parse --path-format=absolute --git-path info/exclude)"
gx_stamp() { # <name> <want: "N" counted, or a refusal pattern> <test leg command> [<old report file> ...]
	local name=$1 want=$2 leg=$3 out code
	shift 3
	rm -rf "$W/build"
	mkdir -p "$W/build/test-results/test"
	for f in "$@"; do
		cp "$GX/$f.xml" "$W/build/test-results/test/old-$f.xml"
		touch -d '2 days ago' "$W/build/test-results/test/old-$f.xml"
	done
	TEST_FORMAT=gradle stamp_manifest "test=$leg"
	out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$?
	if [[ $want =~ ^[0-9]+$ ]]; then
		[[ $code == 0 ]] && grep -qx "gate PASS: test   tests $want passed" <<<"$out" &&
			ok "gradle: $name counts $want" || bad "gradle: $name (exit $code, want $want counted)" "$out"
	else
		[[ $code == 4 ]] && grep -qE -- "$want" <<<"$out" && ! compgen -G "$W/gate-*.txt" >/dev/null &&
			ok "gradle: $name is refused, nothing written" || bad "gradle: $name (exit $code; pattern '$want')" "$out"
	fi
	rm -f "$W"/gate-*.txt
	rm -rf "$W/build"
}
GXD='build/test-results/test'
gx_stamp "one passing report" 3 "mkdir -p $GXD; cp $GX/pass.xml $GXD/a.xml"
gx_stamp "skipped tests do not count as passed" 3 "mkdir -p $GXD; cp $GX/skip.xml $GXD/a.xml"
gx_stamp "a failure" 'not ok: 1 failures, 0 errors' "mkdir -p $GXD; cp $GX/fail.xml $GXD/a.xml"
gx_stamp "an error" 'not ok: 0 failures, 1 errors' "mkdir -p $GXD; cp $GX/err.xml $GXD/a.xml"
gx_stamp "zero tests" 'no passed tests' "mkdir -p $GXD; cp $GX/zero.xml $GXD/a.xml"
gx_stamp "only skipped tests" 'no passed tests' "mkdir -p $GXD; cp $GX/allskip.xml $GXD/a.xml"
gx_stamp "a pass beside a failure" 'not ok' "mkdir -p $GXD; cp $GX/pass.xml $GXD/a.xml; cp $GX/fail.xml $GXD/b.xml"
gx_stamp "a testsuites wrapper does not double count" 4 "mkdir -p $GXD; cp $GX/wrapper.xml $GXD/a.xml"
gx_stamp "a malformed report names the file" 'malformed test report: build/test-results/test/a.xml' "mkdir -p $GXD; cp $GX/broken.xml $GXD/a.xml"
gx_stamp "no report at all" 'no test report newer than its start' "true"
gx_stamp "only an old report (stale)" 'no test report newer than its start under build/test-results/\*\*/\*.xml \(1 stale\)' "true" pass
gx_stamp "an old report beside a fresh one is not counted" 3 "mkdir -p $GXD; cp $GX/pass.xml $GXD/a.xml" m2
# A leg that is not the test leg needs no report; a single [gate] command is the test leg.
TEST_FORMAT=gradle stamp_manifest "lint=true" "test=mkdir -p $GXD; cp $GX/pass.xml $GXD/a.xml"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
grep -qx 'gate PASS: lint/test   tests 3 passed' <<<"$out" && ok "gradle: only the test leg's reports are read" || bad "gradle other leg" "$out"
rm -rf "$W/build" "$W"/gate-*.txt
TEST_FORMAT=gradle stamp_manifest "lint=true" "build=true"
expect "gradle: legs with no test leg are a manifest error" 2 'needs a leg named test or a single \[gate\] command' -- -C "$W" --manifest "$TMP/s.toml" stamp
# Several modules: the adopter's glob reaches each module's reports.
{
	printf '%s[gate]\ntest_format = "gradle"\ntest_results_glob = "*/build/test-results/**/*.xml"\n[gate.legs]\ntest = "mkdir -p m1/build/test-results/test m2/build/test-results/test; cp %s/m1.xml m1/build/test-results/test/a.xml; cp %s/m2.xml m2/build/test-results/test/a.xml"\n' "$GOOD_MANIFEST" "$GX" "$GX"
} >"$TMP/s.toml"
printf 'm1/\nm2/\n' >>"$(git -C "$W" rev-parse --path-format=absolute --git-path info/exclude)"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
grep -qx 'gate PASS: test   tests 6 passed' <<<"$out" && ok "gradle: several modules add up" || bad "gradle modules" "$out"
rm -rf "$W/m1" "$W/m2" "$W"/gate-*.txt
# The glob is configurable and relative to the worktree.
{
	printf '%s[gate]\ntest_format = "gradle"\ntest_results_glob = "out/*.xml"\n[gate.legs]\ntest = "mkdir -p out; cp %s/pass.xml out/r.xml"\n' "$GOOD_MANIFEST" "$GX"
} >"$TMP/s.toml"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
grep -qx 'gate PASS: test   tests 3 passed' <<<"$out" && ok "gradle: test_results_glob names the reports" || bad "gradle glob" "$out"
rm -rf "$W/out" "$W"/gate-*.txt
printf '%s[gate]\ntest_format = "gradle"\ntest_results_glob = "x"\ncommand = "true"\n' "$GOOD_MANIFEST" >"$TMP/m.toml"
expect "test_format gradle is accepted" 4 'no test report newer than its start' -- -C "$W" --manifest "$TMP/m.toml" stamp
printf '%s[gate]\ntest_results_glob = "x"\ncommand = "true"\ntest_count_cmd = "true"\n' "$GOOD_MANIFEST" >"$TMP/m.toml"
expect "test_results_glob needs test_format gradle" 2 'test_results_glob applies to test_format "gradle" only' -- -C "$W" --manifest "$TMP/m.toml" stamp

# Manifest shapes.
mf() {
	printf '%s' "$GOOD_MANIFEST" >"$TMP/s.toml"
	printf '%b' "$1" >>"$TMP/s.toml"
}
mf '[gate]\ncommand = "sh ./fake-test.sh"\ntest_count_cmd = "sh ./fake-test.sh"\n'
expect "a [gate] command alone is one leg named gate" 0 'gate PASS: gate   tests 5 passed' -- -C "$W" --manifest "$TMP/s.toml" stamp
rm -f "$W"/gate-*.txt
mf '[gate]\ncommand = "true"\ntest_count_cmd = "x"\n[gate.legs]\ncheck = "true"\n'
expect "command and legs together are an error" 2 'both define the gate' -- -C "$W" --manifest "$TMP/s.toml" stamp
mf '[gate]\ntest_count_cmd = "x"\n[gate.legs]\n'
expect "an empty [gate.legs] is an error" 2 'names no legs' -- -C "$W" --manifest "$TMP/s.toml" stamp
mf '[gate.legs]\ncheck = 3\n'
expect "a leg must be a string" 2 "leg 'check' needs a non-empty" -- -C "$W" --manifest "$TMP/s.toml" stamp
mf '[gate]\ntest_count_cmd = "x"\n'
expect "no gate is an error" 2 'no gate: set \[gate\] command or \[gate.legs\]' -- -C "$W" --manifest "$TMP/s.toml" stamp
mf '[gate.legs]\ncheck = "true"\n'
expect "no test_count_cmd is an error" 2 "manifest has no 'gate.test_count_cmd'" -- -C "$W" --manifest "$TMP/s.toml" stamp
mf '[gate.other]\ncheck = "true"\n'
expect "other dotted sections are errors" 2 'malformed section header' -- -C "$W" --manifest "$TMP/s.toml" stamp
compgen -G "$W/gate-*.txt" >/dev/null && bad "a manifest error wrote a stamp file" || ok "manifest errors write no stamp file"
stamp_manifest "${STD_LEGS[@]}"
expect "status still reads a manifest with legs" 0 'DOING \(1\)' -- -C "$S" --manifest "$TMP/s.toml" status

# Detached HEAD.
git -C "$S" worktree add -q --detach "$S/.wt/det" item-v1.0.3
stamp_manifest "${STD_LEGS[@]}"
expect "a detached worktree is stamped as detached" 0 "HEAD $(git -C "$W" rev-parse HEAD) \(detached\)" -- -C "$S/.wt/det" --manifest "$TMP/s.toml" stamp

# ---- fresh ----------------------------------------------------------------
F=$TMP/fresh
make_repo "$F"
printf '# Decisions\n' >"$F/docs/DECISIONS.md"
printf '# Rules\n' >"$F/RULES.md"
git -C "$F" add -A && git -C "$F" commit -qm "admin: law files"
FM=$TMP/f.toml
printf '%s' "${GOOD_MANIFEST/'tag = "v{version}"   # comment after a string'/'tag = "v{version}"
admin_prefix = "admin:"
item_commit = "v{version}: {title}"'}" >"$FM"
printf '[docs]\ndecisions = "docs/DECISIONS.md"\nrules = "RULES.md"\n' >>"$FM"
git -C "$F" worktree add -q "$F/.wt/item-v1.0.3" -b item-v1.0.3
git -C "$F/.wt/item-v1.0.3" commit -q --allow-empty -m "v1.0.3: Third"
fsnap() { git -C "$F" for-each-ref; git -C "$F" worktree list --porcelain; git -C "$F" status --porcelain --ignored; git -C "$F/.wt/item-v1.0.3" status --porcelain --ignored; }

expect "a branch based at main's tip is fresh" 0 '^FRESH: item-v1\.0\.3 is based at main tip' -- -C "$F" --manifest "$FM" fresh 1.0.3
expect "a fresh branch lists no main commits" 0 'MAIN SINCE BRANCH POINT \(0\)' -- -C "$F" --manifest "$FM" fresh 1.0.3

# main moves: a ruling, another item, a plain commit, a rules change, a merge.
echo r >>"$F/docs/DECISIONS.md"
git -C "$F" commit -qam "admin: fork ruled B"
git -C "$F" commit -q --allow-empty -m "v1.0.9: Other item"
git -C "$F" commit -q --allow-empty -m "typo fix"
echo r >>"$F/RULES.md"
git -C "$F" commit -qam "admin: rule 13 widened"
git -C "$F" checkout -q -b side
git -C "$F" commit -q --allow-empty -m "side work"
git -C "$F" checkout -q main
git -C "$F" merge -q --no-ff -m "Merge branch 'side'" side
git -C "$F" branch -q -D side

before=$(fsnap)
out=$("$PO" -C "$F" --manifest "$FM" fresh 1.0.3 2>&1)
code=$?
after=$(fsnap)
[[ $code == 5 ]] && grep -q '^REBASE REQUIRED: item-v1\.0\.3 is 6 behind main' <<<"$out" &&
	ok "a branch behind main is REBASE REQUIRED, exit 5" || bad "rebase required (exit $code)" "$out"
want=$(git -C "$F" log --reverse --topo-order --format='%h' item-v1.0.3..main)
got=$(sed -n '/^MAIN SINCE BRANCH POINT (6)$/,/^$/p' <<<"$out" | sed '1d;/^$/d' | awk '{print $1}')
[[ $got == "$want" ]] && ok "every main commit since the base is listed, oldest first" || bad "listed commits" "$got
--- want
$want"
grep -qE '^  [0-9a-f]+  ADMIN RULING +admin: fork ruled B$' <<<"$out" &&
	grep -qE '^  [0-9a-f]+  ITEM v1\.0\.9 +v1\.0\.9: Other item$' <<<"$out" &&
	grep -qE '^  [0-9a-f]+  OTHER +typo fix$' <<<"$out" &&
	grep -qE '^  [0-9a-f]+  ADMIN RULES +admin: rule 13 widened$' <<<"$out" &&
	grep -qE '^  [0-9a-f]+  OTHER +side work$' <<<"$out" &&
	ok "commits are classed by prefix and marked when they change law files" || bad "classes" "$out"
[[ $before == "$after" ]] && ok "fresh changes nothing" || bad "fresh wrote something"
expect "a tag-form version works the same" 5 'REBASE REQUIRED: item-v1\.0\.3' -- -C "$F" --manifest "$FM" fresh v1.0.3
expect "fresh from inside the item worktree reads the same branch" 5 'is 6 behind main' -- -C "$F/.wt/item-v1.0.3" --manifest "$FM" fresh 1.0.3

# A manifest with no admin_prefix or item_commit classes everything OTHER.
expect "without the class keys every commit is OTHER" 5 '  [0-9a-f]+  OTHER +admin: fork ruled B' -- -C "$F" fresh 1.0.3

# The remote-tracking main is noted, never judged.
git -C "$F" update-ref refs/remotes/origin/main "$(git -C "$F" rev-parse main~2)"
expect "a stale remote-tracking main is noted" 5 '^note      origin/main is at [0-9a-f]+ \(as of the last fetch\)' -- -C "$F" --manifest "$FM" fresh 1.0.3
git -C "$F" update-ref -d refs/remotes/origin/main

# A rebase stopped part-way is noted; the branch ref is still behind.
git -C "$F" worktree add -q "$F/.wt/item-v1.0.5" -b item-v1.0.5 main~1
git -C "$F/.wt/item-v1.0.5" commit -q --allow-empty -m "v1.0.5: Fifth"
GIT_SEQUENCE_EDITOR="sed -i 1s/^pick/edit/" git -C "$F/.wt/item-v1.0.5" rebase -q -i --keep-empty main >/dev/null 2>&1
expect "a stopped rebase is noted" 5 '^note      a rebase of item-v1\.0\.5 is stopped part-way' -- -C "$F" --manifest "$FM" fresh 1.0.5
git -C "$F/.wt/item-v1.0.5" rebase --abort

# After a rebase onto main the branch is fresh.
git -C "$F/.wt/item-v1.0.3" rebase -q --keep-empty main
expect "a branch rebased onto main is fresh" 0 '^FRESH: item-v1\.0\.3' -- -C "$F" --manifest "$FM" fresh 1.0.3
expect "the rebased branch is ahead 1 behind 0" 0 'ahead 1  behind 0' -- -C "$F" --manifest "$FM" fresh 1.0.3

expect "fresh needs a version" 1 'fresh needs exactly one <version>' -- -C "$F" --manifest "$FM" fresh
expect "fresh takes one version only" 1 'fresh needs exactly one <version>' -- -C "$F" --manifest "$FM" fresh 1.0.3 1.0.4
expect "fresh rejects options" 1 "fresh: unknown argument '--commit'" -- -C "$F" --manifest "$FM" fresh --commit
expect "fresh rejects a non-version" 1 "'item-v1.0.3' is not a version" -- -C "$F" --manifest "$FM" fresh item-v1.0.3
expect "a missing branch is an error" 2 "no branch 'item-v1.0.8' for version 1.0.8" -- -C "$F" --manifest "$FM" fresh 1.0.8

# ---- open / close ---------------------------------------------------------
BM=$TMP/b.toml
cat >"$BM" <<'EOF'
[gate]
test_count_cmd = "echo 'test result: ok. 1 passed; 0 failed;'"

[gate.legs]
check = "true"

[versioning]
tag = "v{version}"
item_commit = "v{version}: {title}"
admin_prefix = "admin:"
insert_segment = 4

[layout]
backlog = "docs/BACKLOG.md"
specs_dir = "docs/backlog"
worktrees = ".wt"
branch = "item-v{version}"
EOF

# A repo at a boundary: v1.0.3 DOING (heading, table row, prose), v1.0.4 an
# investigation DOING with no branch, v1.0.5 founded TODO; the v1.0.3 branch
# is one item commit with a passing stamp.
make_brepo_build() {
	local dir=$1
	git init -q -b main "$dir"
	git -C "$dir" config user.name "Boundary PO"
	git -C "$dir" config user.email po@example.invalid
	mkdir -p "$dir/docs/backlog"
	cat >"$dir/docs/BACKLOG.md" <<'EOF'
# Backlog

Epic one — **v1.0.3 DOING; spec backlog/v1.md** · E1.2 Study —
**v1.0.4 DOING (study); spec** · E1.3 Parser —
**v1.0.5 parser TODO (queued); spec** · E0 — v1.0.2 DONE (tag v1.0.2).

| Item | Title | Status |
|---|---|---|
| v1.0.1 | First | DONE |
| v1.0.3 | Third | DOING |
EOF
	cat >"$dir/docs/backlog/v1.md" <<'EOF'
# v1 specs

## v1.0.1 — First — DONE

## v1.0.2 — Second — DONE (no bump)

## v1.0.3 — Third — DOING

Body of three.

## v1.0.4 — Fourth study — DOING

## v1.0.5 — Parser — TODO
EOF
	if [[ -n ${BREPO_TABLE:-} ]]; then # a different backlog table, e.g. one with an Owner column
		sed -i '/^| Item/,$d' "$dir/docs/BACKLOG.md"
		printf '%s\n' "$BREPO_TABLE" >>"$dir/docs/BACKLOG.md"
	fi
	git -C "$dir" add -A
	git -C "$dir" commit -qm init
	git -C "$dir" tag v1.0.2
	git -C "$dir" worktree add -q "$dir/.wt/item-v1.0.3" -b item-v1.0.3
	echo three >"$dir/.wt/item-v1.0.3/three.txt"
	git -C "$dir/.wt/item-v1.0.3" add three.txt
	git -C "$dir/.wt/item-v1.0.3" commit -qm "v1.0.3: Third"
	"$PO" -C "$dir/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
}
# make_brepo <dir>: the boundary repo above. It is built and stamped once (the
# 0.204 fixture share); every later call copies that template and repairs the
# worktree links, as the copy's paths differ. A call with BREPO_TABLE set builds
# afresh: its backlog differs.
make_brepo() {
	local dir=$1 tpl=$TMP/brepo-template
	if [[ -n ${BREPO_TABLE:-} ]]; then
		make_brepo_build "$dir"
		return
	fi
	[[ -d $tpl ]] || make_brepo_build "$tpl"
	cp -a "$tpl" "$dir"
	git -C "$dir" worktree repair "$dir/.wt/item-v1.0.3" >/dev/null 2>&1
}
bsnap() { # every ref, worktree, status and file the boundary could touch
	git -C "$1" for-each-ref --format='%(refname) %(objectname)'
	git -C "$1" worktree list --porcelain
	git -C "$1" status --porcelain --untracked-files=all --ignored
	git -C "$1/.wt/item-v1.0.3" status --porcelain --untracked-files=all --ignored 2>/dev/null
	cat "$1/docs/BACKLOG.md" "$1/docs/backlog/v1.md"
}

B=$TMP/b1
make_brepo "$B"
before=$(bsnap "$B")
out=$("$PO" -C "$B" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 && $(bsnap "$B") == "$before" ]] && grep -q 'DRY RUN' <<<"$out" &&
	ok "close without --commit changes nothing" || bad "close dry run (exit $code)" "$out"
grep -qxF -- '-## v1.0.3 — Third — DOING' <<<"$out" && grep -qxF -- '+## v1.0.3 — Third — DONE' <<<"$out" &&
	ok "close plans the heading's status word, nothing else on the line" || bad "heading edit" "$out"
grep -qxF -- '+| v1.0.3 | Third | DONE |' <<<"$out" &&
	ok "close plans the table row's Status cell" || bad "table edit" "$out"
grep -qxF -- '+Epic one — **v1.0.3 DONE (tag v1.0.3); spec backlog/v1.md** · E1.2 Study —' <<<"$out" &&
	ok "close plans the prose mention as DONE (tag …)" || bad "prose edit" "$out"
grep -qxF '  | admin: v1.0.3 DONE (tag v1.0.3)' <<<"$out" &&
	ok "the admin subject names the item and its tag" || bad "admin subject" "$out"
grep -qF "  | HEAD $(git -C "$B" rev-parse item-v1.0.3) (item-v1.0.3)  dirty 0" <<<"$out" &&
	grep -qF '  | Evidence (v1.0.3, po stamp gate-1.txt):' <<<"$out" &&
	ok "the admin message quotes the stamp block" || bad "evidence in message" "$out"
grep -q 'author         Boundary PO <po@example.invalid> (git config)' <<<"$out" &&
	ok "the dry run names the author git will use" || bad "author" "$out"
grep -q 'tag v1.0.3 at [0-9a-f]* (lightweight' <<<"$out" && grep -q 'remove .wt/item-v1.0.3' <<<"$out" &&
	ok "the plan lists tag and worktree removal" || bad "steps" "$out"

expect "close --next takes a TODO item DOING" 0 '  \| admin: v1\.0\.3 DONE \(tag v1\.0\.3\); v1\.0\.5 DOING$' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --next 1.0.5
expect "--next flips the prose mention after one word" 0 '^\+\*\*v1\.0\.5 parser DOING \(queued\); spec\*\* · E0 — v1\.0\.2 DONE \(tag v1\.0\.2\)\.$' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --next 1.0.5
expect "--also-done flips the investigation's prose" 0 '^\+\*\*v1\.0\.4 DONE \(study\); spec\*\* · E1\.3 Parser —$' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --also-done 1.0.4
expect "--also-done closes an investigation in the same subject" 0 '  \| admin: v1\.0\.3 DONE \(tag v1\.0\.3\) \+ v1\.0\.4 DONE$' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --also-done 1.0.4
expect "--next with a title founds a new item" 0 '  \| admin: v1\.0\.3 DONE \(tag v1\.0\.3\); v1\.0\.6 Sixth thing founded DOING for Ann$' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --next 1.0.6 --next-title "Sixth thing" --for Ann
expect "a founded heading goes at the end of the spec file" 0 '^\+## v1\.0\.6 — Sixth thing — DOING$' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --next 1.0.6 --next-title "Sixth thing"
expect "--next out of sequence is refused" 6 'the latest founded is 1\.0\.5, so the next is 1\.0\.6' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --next 1.0.7 --next-title Seven
expect "--next of a new number needs a title" 1 'found it with --next-title' -- -C "$B" --manifest "$BM" close 1.0.3 --next 1.0.6
expect "--next of a DOING item is refused" 6 'v1\.0\.4 is DOING; only a TODO item' -- -C "$B" --manifest "$BM" close 1.0.3 --next 1.0.4
expect "--also-done of a TODO item is refused" 6 'v1\.0\.5 is TODO, not DOING' -- -C "$B" --manifest "$BM" close 1.0.3 --also-done 1.0.5
expect "closing a DONE item is refused" 6 'v1\.0\.2 is DONE, not DOING' -- -C "$B" --manifest "$BM" close 1.0.2
expect "closing an unrecorded item is refused" 6 'v1\.0\.9 is recorded by no backlog source' -- -C "$B" --manifest "$BM" close 1.0.9
expect "close needs a version" 1 'usage: po close' -- -C "$B" --manifest "$BM" close
expect "close rejects unknown options" 1 "close: unknown argument '--force'" -- -C "$B" --manifest "$BM" close 1.0.3 --force
expect "--for without --next is a usage error" 1 'it needs --next' -- -C "$B" --manifest "$BM" close 1.0.3 --for Ann
expect "a title holding the heading separator is refused" 1 "cannot contain ' — '" -- \
	-C "$B" --manifest "$BM" close 1.0.3 --next 1.0.6 --next-title "a — b"
[[ $(bsnap "$B") == "$before" ]] && ok "every close dry run and refusal above changed nothing" || bad "dry runs changed state"

# Pre-flight refusals.
W3=$B/.wt/item-v1.0.3
mv "$W3/gate-1.txt" "$TMP/gate-1.txt"
expect "no stamp evidence is refused" 6 'no po stamp evidence' -- -C "$B" --manifest "$BM" close 1.0.3
sed 's/dirty 0/dirty 1/' "$TMP/gate-1.txt" >"$W3/gate-1.txt"
expect "a stamp of a dirty tree is refused" 6 'does not stamp the branch tip .* clean' -- -C "$B" --manifest "$BM" close 1.0.3
cp "$TMP/gate-1.txt" "$W3/gate-1.txt"
cp "$TMP/gate-1.txt" "$W3/gate-2.txt"
sed -i '2s/.*/gate FAIL/' "$W3/gate-2.txt"
expect "the newest stamp is the one that counts" 6 'gate-2.txt is not a passing gate' -- -C "$B" --manifest "$BM" close 1.0.3
rm -f "$W3/gate-2.txt"
git -C "$W3" commit -q --amend -m "v1.0.3: Third, amended"
expect "a stamp of an earlier tip is refused" 6 'does not stamp the branch tip' -- -C "$B" --manifest "$BM" close 1.0.3
git -C "$W3" commit -q --allow-empty -m "v1.0.3: Third again"
expect "two commits on the branch are refused" 6 'has 2 commits main lacks; one item = one commit' -- -C "$B" --manifest "$BM" close 1.0.3
git -C "$W3" reset -q --hard HEAD~1
git -C "$W3" commit -q --amend -m "Third, no item form"
expect "a commit not in item form is refused" 6 'not in item form' -- -C "$B" --manifest "$BM" close 1.0.3
git -C "$W3" commit -q --amend -m "v1.0.3: Third"
rm -f "$W3"/gate-*.txt
"$PO" -C "$W3" --manifest "$BM" stamp >/dev/null 2>&1
git -C "$B" commit -q --allow-empty -m "admin: main moves on"
expect "a branch behind main is REBASE REQUIRED" 5 'REBASE REQUIRED: item-v1\.0\.3 is 1 behind main' -- -C "$B" --manifest "$BM" close 1.0.3
git -C "$B" reset -q --hard HEAD~1
git -C "$B" tag v1.0.3 item-v1.0.3
expect "an existing tag is refused" 6 'tag v1\.0\.3 already exists' -- -C "$B" --manifest "$BM" close 1.0.3
git -C "$B" tag -d v1.0.3 >/dev/null
git -C "$B" branch -q item-v1.0.6
expect "a taken --next branch is refused" 6 'branch item-v1\.0\.6 already exists' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --next 1.0.6 --next-title Six
git -C "$B" branch -q -D item-v1.0.6
expect "close passes again once repaired" 0 'DRY RUN' -- -C "$B" --manifest "$BM" close 1.0.3
# Memory write-back ([close] memory): the refusal, the plan line, the off switch.
MM=$TMP/mem.toml
{ cat "$BM"; printf '\n[close]\nmemory = true\n'; } >"$MM"
Q=$TMP/mem
make_brepo "$Q"
printf 'Co-Authored-By: Someone <s@example.invalid>\n' >"$TMP/mem-none.txt"
printf 'Memory: nothing new learned\n' >"$TMP/mem-nothing.txt"
printf 'Memory: proposed 20261103-120000-ab12 (next time X, do Y, because Z)\n' >"$TMP/mem-id.txt"
memsnap=$(bsnap "$Q")
expect "memory on: close without a body file is refused" 6 "needs a line 'Memory:" -- -C "$Q" --manifest "$MM" close 1.0.3 --commit
expect "memory on: a body with no Memory line is refused" 6 "needs a line 'Memory:" -- -C "$Q" --manifest "$MM" close 1.0.3 --body-file "$TMP/mem-none.txt" --commit
[[ $(bsnap "$Q") == "$memsnap" ]] && ok "memory on: a refused close changed nothing" || bad "memory refusal changed state"
expect "memory on: the dry run prints the prompt line" 0 "memory    file a proposal or record 'nothing new learned' with the close body" -- -C "$Q" --manifest "$MM" close 1.0.3
expect "memory on: the dry run is not refused for a missing line" 0 'DRY RUN' -- -C "$Q" --manifest "$MM" close 1.0.3 --body-file "$TMP/mem-none.txt"
out=$("$PO" -C "$Q" --manifest "$BM" close 1.0.3 2>&1)
[[ $out == "$("$PO" -C "$Q" --manifest "$MM" close 1.0.3 2>&1 | grep -v '^memory    ')" ]] &&
	! grep -q '^memory ' <<<"$out" &&
	ok "memory key absent: the plan has no memory line and is otherwise identical" || bad "memory key absent plan" "$out"
for form in id nothing; do
	Q2=$TMP/mem-$form
	make_brepo "$Q2"
	expect "memory on: '$form' form is accepted" 0 'closed|tag v1\.0\.3|v1\.0\.3' -- -C "$Q2" --manifest "$MM" close 1.0.3 --body-file "$TMP/mem-$form.txt" --commit
	[[ $(git -C "$Q2" cat-file -t v1.0.3 2>/dev/null) == commit ]] && ok "memory on: '$form' form closes the item" || bad "memory $form did not close"
done
Q2=$TMP/mem-off
make_brepo "$Q2"
expect "memory key absent: close --commit needs no Memory line" 0 'v1\.0\.3' -- -C "$Q2" --manifest "$BM" close 1.0.3 --body-file "$TMP/mem-none.txt" --commit
[[ $(git -C "$Q2" cat-file -t v1.0.3 2>/dev/null) == commit ]] && ok "memory key absent: the item closes as before" || bad "memory off did not close"

# Anchors that are not exactly one: stop, exit 3, nothing planned.
anchor_case() { # <name> <pattern> <sed on BACKLOG.md>
	local q=$TMP/anchor-$((++ANCHOR_N))
	make_brepo "$q"
	sed -i "$3" "$q/docs/BACKLOG.md"
	git -C "$q" commit -qam anchor
	git -C "$q/.wt/item-v1.0.3" rebase -q main
	rm -f "$q/.wt/item-v1.0.3"/gate-*.txt
	"$PO" -C "$q/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
	expect "$1" 3 "$2" -- -C "$q" --manifest "$BM" close 1.0.3
}
ANCHOR_N=0
# shellcheck disable=SC2016 # $a is sed (append after the last line), not a shell expansion
anchor_case "two prose mentions stop the close" 'v1\.0\.3 is followed by a status 2 times' '$a Also v1.0.3 DOING here.'
anchor_case "a prose mention with another status stops it" 'the prose says v1\.0\.3 … TODO, expected DOING' 's/v1.0.3 DOING;/v1.0.3 TODO;/'
anchor_case "a status wrapped onto the next line stops it" 'the status after v1\.0\.3 wraps onto the next line' 's/\*\*v1.0.3 DOING; spec/**v1.0.3\nDOING; spec/'
anchor_case "two table rows stop it" 'v1\.0\.3 has 2 table rows' 's/^| v1.0.3 | Third | DOING |$/&\n&/'
Q=$TMP/paren-b
make_brepo "$Q"
sed -i 's/v1.0.3 DOING; spec/v1.0.3 DOING (Ann); spec/' "$Q/docs/BACKLOG.md"
git -C "$Q" commit -qam paren
git -C "$Q/.wt/item-v1.0.3" rebase -q main
rm -f "$Q/.wt/item-v1.0.3"/gate-*.txt
"$PO" -C "$Q/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
expect "the tag joins a parenthetical already after the status" 0 '^\+Epic one — \*\*v1\.0\.3 DONE \(tag v1\.0\.3; Ann\); spec' -- -C "$Q" --manifest "$BM" close 1.0.3
expect "a founded item notes its BACKLOG prose is the PO's" 0 "^  v1\.0\.6: founded by its heading; a docs/BACKLOG\.md mention is the PO's prose$" -- \
	-C "$Q" --manifest "$BM" close 1.0.3 --next 1.0.6 --next-title Six
# Review regressions. A tag in a later column names another item's row.
Q=$TMP/after-col
make_brepo "$Q"
printf '\n| Item | After | Status |\n|---|---|---|\n| v0.9.0 | v1.0.3 | DOING |\n' >>"$Q/docs/BACKLOG.md"
git -C "$Q" commit -qam aftercol
git -C "$Q/.wt/item-v1.0.3" rebase -q main
rm -f "$Q/.wt/item-v1.0.3"/gate-*.txt
"$PO" -C "$Q/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
out=$("$PO" -C "$Q" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 ]] && grep -qxF -- '+| v1.0.3 | Third | DONE |' <<<"$out" && ! grep -q '^+| v0\.9\.0' <<<"$out" &&
	ok "only the row whose first tag-form cell is the item is edited" || bad "after column (exit $code)" "$out"
# Line-ending conversion in main's checkout: same blobs, other bytes.
Q=$TMP/crlf
make_brepo "$Q"
git -C "$Q" config core.autocrlf true
rm -f "$Q/docs/BACKLOG.md" "$Q/docs/backlog/v1.md"
git -C "$Q" checkout -q -- docs
grep -q $'\r$' "$Q/docs/backlog/v1.md" && ok "the crlf fixture has CRLF bytes in its checkout" || bad "crlf fixture"
out=$("$PO" -C "$Q" --manifest "$BM" close 1.0.3 --commit 2>&1)
code=$?
[[ $code == 0 && $(git -C "$Q" log -1 --format=%s main) == 'admin: v1.0.3 DONE (tag v1.0.3)' ]] &&
	[[ -z $(git -C "$Q" status --porcelain --untracked-files=no) ]] &&
	git -C "$Q" show main:docs/backlog/v1.md | grep -qx '## v1.0.3 — Third — DONE' &&
	ok "close --commit works in a line-ending converted checkout and leaves it clean" || bad "crlf close (exit $code)" "$out"
# Without insert_segment, an insert does not change the sequential numbering.
Q=$TMP/noins
make_brepo "$Q"
printf '\n## v1.0.5.1 — Hotfix — DONE\n' >>"$Q/docs/backlog/v1.md"
git -C "$Q" commit -qam insert
grep -v '^insert_segment' "$BM" >"$TMP/noins.toml"
expect "without insert_segment, next follows the fewest-segment numbers" 0 '  \| admin: v1\.0\.6 X founded DOING$' -- -C "$Q" --manifest "$TMP/noins.toml" open next X
# The founding heading is the last line of the spec file's diff.
out=$("$PO" -C "$TMP/b1" --manifest "$BM" open 1.0.6 Six 2>&1)
grep -A1 -F -- '+## v1.0.6 — Six — DOING' <<<"$out" | tail -1 | grep -qx -- '--- a/docs/BACKLOG.md\|NOTES\|' &&
	ok "a founding heading lands at the end of its spec file" || bad "founding at end" "$out"
# A branch name in prose is not a status mention.
Q=$TMP/branchname
make_brepo "$Q"
sed -i '$a Branch item-v1.0.3 DOING is the worktree.' "$Q/docs/BACKLOG.md"
git -C "$Q" commit -qam branchname
git -C "$Q/.wt/item-v1.0.3" rebase -q main
rm -f "$Q/.wt/item-v1.0.3"/gate-*.txt
"$PO" -C "$Q/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
expect "a branch name in prose is not a second mention" 0 'DRY RUN' -- -C "$Q" --manifest "$BM" close 1.0.3
Q=$TMP/conflict-b
make_brepo "$Q"
sed -i 's/^| v1.0.1 | First | DONE |$/| v1.0.1 | First | DOING |/' "$Q/docs/BACKLOG.md"
git -C "$Q" commit -qam conflict
expect "a backlog that disagrees with itself stops close" 3 'the backlog disagrees with itself' -- -C "$Q" --manifest "$BM" close 1.0.3

# --commit, with a tag-signing config that would make a plain `git tag`
# demand a message or a key.
B=$TMP/b2
make_brepo "$B"
git -C "$B" config tag.gpgSign true
git -C "$B" config gpg.program false
tip=$(git -C "$B" rev-parse item-v1.0.3)
printf 'target/\n' >"$B/.git/info/exclude"
mkdir "$B/.wt/item-v1.0.3/target" # empty and ignored: nothing to lose
printf 'Co-Authored-By: Someone <s@example.invalid>\n' >"$TMP/body.txt"
out=$("$PO" -C "$B" --manifest "$BM" close 1.0.3 --next 1.0.5 --also-done 1.0.4 --body-file "$TMP/body.txt" --commit 2>&1)
code=$?
[[ $code == 0 ]] && ok "close --commit exits 0" || bad "close --commit (exit $code)" "$out"
CLOG=$B/.git/po-events.jsonl # for the gate events tests below
[[ $(git -C "$B" cat-file -t v1.0.3) == commit && $(git -C "$B" rev-parse v1.0.3) == "$tip" ]] &&
	ok "the tag is bare and lightweight at the item commit, despite tag.gpgSign" || bad "tag" "$(git -C "$B" cat-file -t v1.0.3 2>&1)"
# [versioning] tag_style (item D.1).
styled() { sed "s/^admin_prefix = \"admin:\"\$/&\ntag_style = \"$1\"/" "$BM" >"$TMP/style-$1.toml"; }
styled light
styled annotated
styled bogus
expect "an unknown tag_style is a manifest error" 2 'tag_style must be "light" or "annotated": bogus' -- -C "$R" --manifest "$TMP/style-bogus.toml" status
out=$("$PO" -C "$TMP/b1" --manifest "$BM" close 1.0.3 2>&1)
grep -q 'tag v1.0.3 at [0-9a-f]* (lightweight; never signed or annotated)' <<<"$out" &&
	ok "the dry run says a lightweight tag" || bad "light dry run" "$out"
out=$("$PO" -C "$TMP/b1" --manifest "$TMP/style-annotated.toml" close 1.0.3 2>&1)
grep -q 'tag v1.0.3 at [0-9a-f]* (annotated, message "v1.0.3: Third"' <<<"$out" &&
	ok "the dry run says an annotated tag, with its message" || bad "annotated dry run" "$out"
for style in light annotated; do
	A=$TMP/tag-$style
	make_brepo "$A"
	atip=$(git -C "$A" rev-parse item-v1.0.3)
	out=$("$PO" -C "$A" --manifest "$TMP/style-$style.toml" close 1.0.3 --commit 2>&1)
	code=$?
	want=commit
	[[ $style == annotated ]] && want=tag
	[[ $code == 0 && $(git -C "$A" cat-file -t v1.0.3) == "$want" && $(git -C "$A" rev-parse "v1.0.3^{commit}") == "$atip" ]] &&
		ok "tag_style = \"$style\" writes a $want object at the item commit" || bad "tag_style $style (exit $code)" "$out"
done
[[ $(git -C "$TMP/tag-annotated" tag -l --format='%(contents:subject)' v1.0.3) == 'v1.0.3: Third' ]] &&
	ok "the annotated tag's message is '<tag>: <title>'" || bad "annotated message"
[[ $(git -C "$TMP/tag-annotated" rev-parse main^) == "$(git -C "$TMP/tag-annotated" rev-parse "v1.0.3^{commit}")" ]] &&
	ok "the annotated tag stays at the item commit, not the admin commit" || bad "annotated tag place"
out=$("$PO" -C "$TMP/tag-annotated" --manifest "$BM" status 2>&1)
grep -q '^tag       v1.0.3 ' <<<"$out" &&
	ok "po status reads an annotated tag as the latest tag" || bad "status annotated tag" "$out"
# Annotated under a signing config that cannot sign: the close stops at the tag step.
A=$TMP/tag-sign
make_brepo "$A"
git -C "$A" config tag.gpgSign true
git -C "$A" config gpg.program false
out=$("$PO" -C "$A" --manifest "$TMP/style-annotated.toml" close 1.0.3 --commit 2>&1)
code=$?
[[ $code != 0 ]] && grep -q 'could not create tag v1.0.3' <<<"$out" && ! git -C "$A" rev-parse -q --verify refs/tags/v1.0.3 >/dev/null &&
	[[ $(git -C "$A" log -1 --format=%s main) == 'v1.0.3: Third' ]] &&
	ok "an annotated tag that cannot be made stops the close at that step, naming it" || bad "annotated tag failure (exit $code)" "$out"
[[ $(git -C "$B" rev-parse main^) == "$tip" && $(git -C "$B" log -1 --format=%s main) == 'admin: v1.0.3 DONE (tag v1.0.3) + v1.0.4 DONE; v1.0.5 DOING' ]] &&
	ok "main is fast-forwarded to the item, then the admin commit" || bad "main shape" "$(git -C "$B" log --oneline -3 main)"
[[ $(git -C "$B" log -1 --format='%an <%ae>|%cn' main) == 'Boundary PO <po@example.invalid>|Boundary PO' ]] &&
	ok "the admin commit's author is the repo's git config" || bad "author" "$(git -C "$B" log -1 --format='%an <%ae>' main)"
git -C "$B" log -1 --format=%B main | grep -qx 'Co-Authored-By: Someone <s@example.invalid>' &&
	git -C "$B" log -1 --format=%B main | grep -qx "HEAD $tip (item-v1.0.3)  dirty 0" &&
	ok "the admin message carries the evidence and the body file" || bad "admin body" "$(git -C "$B" log -1 --format=%B main)"
[[ $(git -C "$B" diff --name-only main^ main | sort | paste -sd' ' -) == 'docs/BACKLOG.md docs/backlog/v1.md' ]] &&
	grep -qx '## v1.0.3 — Third — DONE' "$B/docs/backlog/v1.md" &&
	grep -qx '## v1.0.4 — Fourth study — DONE' "$B/docs/backlog/v1.md" &&
	grep -qx '## v1.0.5 — Parser — DOING' "$B/docs/backlog/v1.md" &&
	ok "the admin commit holds exactly the planned backlog edits" || bad "admin diff" "$(git -C "$B" show --stat main)"
[[ ! -e $B/.wt/item-v1.0.3 ]] && ! git -C "$B" show-ref -q refs/heads/item-v1.0.3 &&
	ok "the closed item's worktree and branch are gone" || bad "closed worktree" "$out"
[[ $(git -C "$B" rev-parse item-v1.0.5) == "$(git -C "$B" rev-parse main)" && -d $B/.wt/item-v1.0.5 ]] &&
	ok "the --next item's branch and worktree sit at the admin commit" || bad "next worktree" "$out"
[[ -z $(git -C "$B" status --porcelain --untracked-files=no) ]] && ok "main's checkout is clean after --commit" ||
	bad "main dirty" "$(git -C "$B" status --porcelain)"
expect "the new item is fresh" 0 '^FRESH: item-v1\.0\.5' -- -C "$B" --manifest "$BM" fresh 1.0.5
expect "status agrees with the boundary" 0 'DOING \(1\)' -- -C "$B" --manifest "$BM" status
expect "a second close of the same item is refused" 6 'v1\.0\.3 is DONE, not DOING' -- -C "$B" --manifest "$BM" close 1.0.3

# A no-change item (v0.100): the branch has no commit main lacks, the stamp
# names main's tip; the tag goes on the admin commit.
make_nochange() { # <dir>: a boundary repo whose v1.0.3 branch is main's tip, stamped
	make_brepo "$1"
	git -C "$1/.wt/item-v1.0.3" reset -q --hard main
	rm -f "$1/.wt/item-v1.0.3"/gate-*.txt
	"$PO" -C "$1/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
}
N=$TMP/nc1
make_nochange "$N"
before=$(bsnap "$N")
out=$("$PO" -C "$N" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 && $(bsnap "$N") == "$before" ]] && grep -q 'DRY RUN' <<<"$out" &&
	grep -q 'no change: the tag goes on the admin commit' <<<"$out" && ! grep -q 'fast-forward main' <<<"$out" &&
	ok "a no-change close's dry run shows the plan and writes nothing" || bad "no-change dry run (exit $code)" "$out"
mv "$N/.wt/item-v1.0.3/gate-1.txt" "$TMP/nc-gate-1.txt"
expect "a no-change item with no stamp is refused" 6 'no po stamp evidence' -- -C "$N" --manifest "$BM" close 1.0.3
cp "$TMP/nc-gate-1.txt" "$N/.wt/item-v1.0.3/gate-1.txt"
sed '2s/.*/gate FAIL/' "$TMP/nc-gate-1.txt" >"$N/.wt/item-v1.0.3/gate-2.txt"
expect "a no-change item with a failing stamp is refused" 6 'gate-2.txt is not a passing gate' -- -C "$N" --manifest "$BM" close 1.0.3
rm -f "$N/.wt/item-v1.0.3/gate-2.txt"
echo dirt >>"$N/.wt/item-v1.0.3/docs/BACKLOG.md"
expect "a no-change item with uncommitted changes is refused" 6 'has no commit but .* has uncommitted changes \(1\)' -- -C "$N" --manifest "$BM" close 1.0.3
git -C "$N/.wt/item-v1.0.3" checkout -q -- docs/BACKLOG.md
git -C "$N" commit -q --allow-empty -m "admin: main moves on"
git -C "$N/.wt/item-v1.0.3" reset -q --hard main
expect "a no-change stamp of an earlier tip is refused" 6 'does not stamp the branch tip' -- -C "$N" --manifest "$BM" close 1.0.3
rm -f "$N/.wt/item-v1.0.3"/gate-*.txt
"$PO" -C "$N/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
old=$(git -C "$N" rev-parse main)
out=$("$PO" -C "$N" --manifest "$BM" close 1.0.3 --commit 2>&1)
code=$?
admin=$(git -C "$N" rev-parse main)
[[ $code == 0 && $(git -C "$N" rev-list --count "$old..main") == 1 && $(git -C "$N" rev-parse main^) == "$old" ]] &&
	ok "a no-change close --commit exits 0 and adds exactly one commit to main" || bad "no-change commit (exit $code)" "$out"
[[ $(git -C "$N" cat-file -t v1.0.3) == commit && $(git -C "$N" rev-parse v1.0.3) == "$admin" && $admin != "$old" ]] &&
	ok "the no-change tag is lightweight and sits at the admin commit, not the old main tip" || bad "no-change tag" "$(git -C "$N" log --oneline -2 --decorate main)"
[[ $(git -C "$N" log -1 --format=%s main) == 'admin: v1.0.3 DONE (tag v1.0.3)' ]] &&
	grep -qxF '| v1.0.3 | Third | DONE |' "$N/docs/BACKLOG.md" && grep -qF 'v1.0.3 DONE (tag v1.0.3)' "$N/docs/BACKLOG.md" &&
	git -C "$N" log -1 --format=%B main | grep -qx "HEAD $old (item-v1.0.3)  dirty 0" &&
	ok "the no-change admin commit flips the row to DONE (tag …) and carries the evidence" || bad "no-change admin" "$(git -C "$N" show main)"
[[ ! -e $N/.wt/item-v1.0.3 ]] && ! git -C "$N" show-ref -q refs/heads/item-v1.0.3 &&
	ok "the no-change item's worktree and branch are gone" || bad "no-change clean-up" "$out"
expect "po status reads the tag on an admin commit as the latest tag" 0 '^tag       v1\.0\.3 ' -- -C "$N" --manifest "$BM" status
expect "a second no-change close is refused" 6 'v1\.0\.3 is DONE, not DOING' -- -C "$N" --manifest "$BM" close 1.0.3
N=$TMP/nc-annotated
make_nochange "$N"
out=$("$PO" -C "$N" --manifest "$TMP/style-annotated.toml" close 1.0.3 2>&1)
grep -q 'tag v1.0.3 at the admin commit (annotated, message "v1.0.3: Third (no change needed)"' <<<"$out" &&
	ok "the no-change dry run names the annotated tag on the admin commit" || bad "no-change annotated dry run" "$out"
out=$("$PO" -C "$N" --manifest "$TMP/style-annotated.toml" close 1.0.3 --commit 2>&1)
code=$?
[[ $code == 0 && $(git -C "$N" cat-file -t v1.0.3) == tag && $(git -C "$N" rev-parse "v1.0.3^{commit}") == "$(git -C "$N" rev-parse main)" &&
	$(git -C "$N" tag -l --format='%(contents:subject)' v1.0.3) == 'v1.0.3: Third (no change needed)' ]] &&
	ok "a no-change annotated tag sits at the admin commit with the no-change message" || bad "no-change annotated (exit $code)" "$out"

# --commit refuses a main checkout it cannot write in, before any write.
B=$TMP/b3
make_brepo "$B"
echo scratch >>"$B/docs/BACKLOG.md"
before=$(bsnap "$B")
expect "close --commit refuses a dirty main checkout" 6 'refused: --commit: .* has tracked changes \(1\)' -- -C "$B" --manifest "$BM" close 1.0.3 --commit
[[ $(bsnap "$B") == "$before" ]] && ok "the refused --commit wrote nothing" || bad "refused commit wrote"
expect "a dry run names the dirty main checkout" 0 'main checkout  NOT READY: .* has tracked changes' -- -C "$B" --manifest "$BM" close 1.0.3
git -C "$B" checkout -q -- docs/BACKLOG.md
# Ignored files keep the closed item's worktree; the boundary still completes.
printf 'cache/\n' >"$B/.git/info/exclude"
mkdir -p "$B/.wt/item-v1.0.3/cache"
echo c >"$B/.wt/item-v1.0.3/cache/x"
expect "ignored files keep the item worktree, reported" 0 'kept \.wt/item-v1\.0\.3 and branch item-v1\.0\.3: it holds ignored files' -- \
	-C "$B" --manifest "$BM" close 1.0.3 --commit
[[ $(git -C "$B" cat-file -t v1.0.3) == commit && -f $B/.wt/item-v1.0.3/cache/x ]] &&
	ok "the boundary landed and the ignored files survive" || bad "ignored keep"

# [hooks] on_close (item F).
HM=$TMP/hooks.toml
HENV=$TMP/hook.env
hook_manifest() { # <command>: BM plus [hooks] on_close, the command TOML-escaped
	local c=${1//\\/\\\\}
	{ cat "$BM"; printf '\n[hooks]\non_close = "%s"\n' "${c//\"/\\\"}"; } >"$HM"
}
m "$GOOD_MANIFEST"'[hooks]
on_close = "true"
'
expect "[hooks] on_close is a known manifest key" 0 'DOING \(1\)' -- -C "$R" --manifest "$TMP/m.toml" status
m "$GOOD_MANIFEST"'[hooks]
on_close = ""
'
expect "an empty on_close is an error" 2 'on_close needs a non-empty "command"' -- -C "$R" --manifest "$TMP/m.toml" status
m "$GOOD_MANIFEST"'[hooks]
on_open = "true"
'
expect "an unknown [hooks] key is an error" 2 "unknown key 'on_open' in \[hooks\]" -- -C "$R" --manifest "$TMP/m.toml" status

# The dry run lists the hook and the environment, and runs nothing.
hook_manifest "env | sort > $HENV; echo hook-std''out; pwd >> $HENV"
B=$TMP/h1
make_brepo "$B"
before=$(bsnap "$B")
out=$("$PO" -C "$B" --manifest "$HM" close 1.0.3 --next 1.0.5 --body-file "$TMP/body.txt" 2>&1)
code=$?
[[ $code == 0 ]] && grep -q "^HOOK on_close" <<<"$out" && grep -qF "command  env | sort > $HENV" <<<"$out" &&
	grep -q '^           PO_VERSION=1.0.3$' <<<"$out" && grep -q '^           PO_NEXT=1.0.5$' <<<"$out" &&
	grep -q '^  6\. then run the on_close hook' <<<"$out" &&
	ok "the dry run lists the hook, its command and its environment" || bad "hook dry run (exit $code)" "$out"
[[ ! -e $HENV && $(bsnap "$B") == "$before" ]] && ok "the dry run runs nothing and changes nothing" || bad "hook dry run ran or wrote"
out=$("$PO" -C "$B" --manifest "$BM" close 1.0.3 2>&1)
grep -qi 'hook' <<<"$out" && bad "a manifest without [hooks] mentions a hook" "$out" || ok "a manifest without [hooks] prints no hook line"

# --commit: every variable, with the boundary's real values.
tip=$(git -C "$B" rev-parse item-v1.0.3)
printf 'Co-Authored-By: Someone <s@example.invalid>\n' >"$TMP/body.txt"
out=$("$PO" -C "$B" --manifest "$HM" close 1.0.3 --next 1.0.5 --body-file "$TMP/body.txt" --commit 2>"$TMP/hook.err")
code=$?
admin=$(git -C "$B" rev-parse main)
[[ $code == 0 ]] && ok "close --commit with a succeeding hook exits 0" || bad "hook commit (exit $code)" "$out"
henv() { grep "^$1=" "$HENV" | head -1 | cut -d= -f2-; }
[[ $(henv PO_HOOK) == on_close && $(henv PO_VERSION) == 1.0.3 && $(henv PO_TAG) == v1.0.3 && $(henv PO_TITLE) == Third &&
	$(henv PO_ITEM_COMMIT) == "$tip" && $(henv PO_ADMIN_COMMIT) == "$admin" && $(henv PO_NEXT) == 1.0.5 ]] &&
	ok "PO_HOOK, VERSION, TAG, TITLE, ITEM_COMMIT, ADMIN_COMMIT and NEXT carry the boundary's values" ||
	bad "hook env" "$(cat "$HENV")"
[[ $(henv PO_DATE) == "$(git -C "$B" log -1 --format=%aI main)" && $(henv PO_DATE) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}[+-][0-9:]{5}$ ]] &&
	ok "PO_DATE is the admin commit's ISO 8601 date" || bad "PO_DATE" "$(henv PO_DATE)"
[[ $(henv PO_BODY_FILE) == "$TMP/body.txt" && $(henv PO_REPO) == "$B" && $(tail -1 "$HENV") == "$B" ]] &&
	ok "PO_BODY_FILE and PO_REPO are set and the hook runs in the main worktree" || bad "body/repo" "$(cat "$HENV")"
ev=$(henv PO_EVIDENCE)
[[ $ev == */po-evidence.* && ! -e $ev ]] && ok "PO_EVIDENCE is a temporary file, removed after the hook" || bad "evidence file" "$ev"
grep -qx 'hook-stdout' "$TMP/hook.err" && ! grep -q 'hook-stdout' <<<"$out" &&
	ok "the hook's stdout is passed through to stderr" || bad "hook output" "$out / $(cat "$TMP/hook.err")"
# po release <N> (v0.105): the pre-release review row.
RV=$TMP/rv
make_brepo "$RV"
RM=$TMP/rv.toml
{ cat "$BM"; printf '\n[release]\nreview = true\n'; } >"$RM"
rvsnap() { git -C "$RV" rev-parse main; git -C "$RV" status --porcelain --untracked-files=all; cat "$RV/docs/BACKLOG.md"; }
before=$(rvsnap)
base=$(git -C "$RV" rev-parse main)
expect "release: review = true refuses without a review row" 6 'refused: release-7 has no pre-release review row' -- -C "$RV" --manifest "$RM" release 7
[[ $(rvsnap) == "$before" ]] && ok "release: the refusal changes nothing" || bad "release refusal wrote"
expect "release: the dry run of --open-review names the row it would add" 0 '^review    v1\.0\.6  test review: release-7  \(new row, TODO\)$' -- -C "$RV" --manifest "$RM" release 7 --open-review
[[ $(rvsnap) == "$before" ]] && ok "release: --open-review without --commit changes nothing" || bad "release dry run wrote"
out=$("$PO" -C "$RV" --manifest "$RM" release 7 --open-review --commit 2>&1)
code=$?
[[ $code == 0 && $(git -C "$RV" rev-list --count "$base..main") == 1 && $(grep -c 'test review: release-7' "$RV/docs/BACKLOG.md") == 1 ]] &&
	grep -qF '| v1.0.6 | test review: release-7 | TODO |' "$RV/docs/BACKLOG.md" &&
	[[ $(git -C "$RV" log -1 --format=%s) == 'admin: v1.0.6 test review: release-7 founded TODO' ]] &&
	ok "release: --open-review --commit writes exactly one row in one admin commit" || bad "release open-review (exit $code)" "$out"
after=$(rvsnap)
out=$("$PO" -C "$RV" --manifest "$RM" release 7 --open-review --commit 2>&1)
code=$?
[[ $code == 0 && $(rvsnap) == "$after" ]] && grep -q 'review row v1.0.6 exists (TODO)' <<<"$out" &&
	ok "release: --open-review is idempotent and says the row exists" || bad "release idempotent (exit $code)" "$out"
expect "release: accepted once the row exists" 0 '^release-7: review row v1\.0\.6 exists \(TODO\)$' -- -C "$RV" --manifest "$RM" release 7
expect "release: a row for release-7 does not satisfy release-77" 6 'release-77 has no' -- -C "$RV" --manifest "$RM" release 77
expect "release: release-7.1 is not covered by the release-7 row" 6 'release-7\.1 has no' -- -C "$RV" --manifest "$RM" release 7.1
before=$(rvsnap)
out=$("$PO" -C "$RV" --manifest "$BM" release 99 2>&1)
code=$?
[[ $code == 0 && -z $out && $(rvsnap) == "$before" ]] && ok "release: with the key absent it prints nothing, exits 0 and changes nothing" || bad "release key absent (exit $code)" "$out"
{ cat "$BM"; printf '\n[release]\nreview = false\n'; } >"$TMP/rv-off.toml"
out=$("$PO" -C "$RV" --manifest "$TMP/rv-off.toml" release 99 2>&1)
code=$?
[[ $code == 0 && -z $out && $(rvsnap) == "$before" ]] && ok "release: review = false behaves as the key absent" || bad "release key false (exit $code)" "$out"
# po release <N> --setup / --write (v0.106): the Setup after install block from the recorded steps.
RLS=$TMP/rls
make_brepo "$RLS"
rs_set() {
	# helper
	python3 -I - "$RLS/.git/po-setup-steps.json" "$@" <<'PY'
import json, sys
out, rows = sys.argv[1], sys.argv[2:]
steps = []
for r in rows:
    item, n, machine, command, who, check = r.split("@@")
    steps.append({"item": item, "n": int(n), "machine": machine, "command": command, "who": who, "check": check, "status": "open"})
json.dump({"steps": steps}, open(out, "w"))
PY
}
rs_log() { # <entry body>: CHANGELOG with Release 7 whose notes are the given text
	{ printf '# changelog\n\n## Unreleased\n\n### Later (v0.9, 2026-11-02)\n\nLATER\n\n## Release 7 (2026-11-01): seven\n\n'; printf '%s\n' "$1"; } >"$RLS/CHANGELOG.md"
}
rs_log $'### A (v1.0.1, 2026-11-01)\n\nA-NOTE\n\n### B (v1.0.3, 2026-11-01)\n\nB-NOTE\n\n### C (v1.0.4, 2026-11-01)\n\nC-NOTE'
rs_set
out=$("$PO" -C "$RLS" --manifest "$BM" release 7 --setup 2>&1)
[[ $out == $'### Setup after install\n\nNone' ]] && ok "release --setup: no recorded step prints the word None" || bad "release setup none" "$out"
rs_set "1.0.3@@1@@buildhost@@systemctl --user restart po-serve@@opssession@@curl -sI http://x/events.json shows ETag"
out=$("$PO" -C "$RLS" --manifest "$BM" release 7 --setup 2>&1)
want=$'### Setup after install\n\n| # | Machine | Command | Who | Check |\n|---|---|---|---|---|\n| 1 | buildhost | `systemctl --user restart po-serve` (v1.0.3) | opssession | curl -sI http://x/events.json shows ETag |'
[[ $out == "$want" ]] && ok "release --setup: one recorded step is one table row naming its item" || bad "release setup one" "$out"
rs_set "1.0.4@@2@@laptop@@second-of-c@@owner@@c2" "1.0.3@@1@@buildhost@@first-of-b@@opssession@@b1" "1.0.1@@1@@nas@@only-of-a@@operator@@a1" "1.0.4@@1@@buildhost@@first-of-c@@owner@@c1" "9.9@@1@@x@@other-item@@x@@x" "0.9@@1@@x@@unreleased-item@@x@@x"
out=$("$PO" -C "$RLS" --manifest "$BM" release 7 --setup 2>&1)
# shellcheck disable=SC2016 # backticks in markdown, not expansions
got=$(grep -o '`[a-z-]*` (v[0-9.]*)' <<<"$out" | tr '\n' ' ')
# shellcheck disable=SC2016 # backticks in markdown, not expansions
[[ $got == '`only-of-a` (v1.0.1) `first-of-b` (v1.0.3) `first-of-c` (v1.0.4) `second-of-c` (v1.0.4) ' && $(grep -c '^| [0-9] |' <<<"$out") == 4 ]] &&
	grep -q '^| 4 | laptop |' <<<"$out" &&
	ok "release --setup: three or more steps come in item order then step number, and only the entry's items" || bad "release setup order" "$out"
# shellcheck disable=SC2016 # backticks in markdown, not expansions
rs_set "1.0.3@@1@@buildhost@@grep 'a|b' file | wc -l@@opssession@@prints 1" '1.0.3@@2@@buildhost@@echo `date` ``x``@@owner@@a|b'
out=$("$PO" -C "$RLS" --manifest "$BM" release 7 --setup 2>&1)
# shellcheck disable=SC2016 # backticks in markdown, not expansions
grep -qF '| 1 | buildhost | `grep '"'"'a\|b'"'"' file \| wc -l` (v1.0.3) | opssession | prints 1 |' <<<"$out" &&
	grep -qF '| 2 | buildhost | ``` echo `date` ``x`` ``` (v1.0.3) | owner | a\|b |' <<<"$out" &&
	ok "release --setup: a pipe is escaped and a backtick in a command gets a longer fence" || bad "release setup escapes" "$out"
before=$(cat "$RLS/CHANGELOG.md")
out=$("$PO" -C "$RLS" --manifest "$BM" release 7 --setup 2>&1)
[[ $(cat "$RLS/CHANGELOG.md") == "$before" ]] && ok "release --setup writes nothing" || bad "release setup wrote"
rs_set "1.0.3@@1@@buildhost@@restart-it@@opssession@@it runs" "1.0.1@@1@@nas@@reload@@operator@@click"
out=$("$PO" -C "$RLS" --manifest "$BM" release 7 --write 2>&1)
code=$?
first=$(sed -n '/^## Release 7/,$p' "$RLS/CHANGELOG.md" | sed -n '3,4p')
# shellcheck disable=SC2016 # backticks in markdown, not expansions
[[ $code == 0 && $first == '### Setup after install' ]] && grep -q '^| 1 | nas | `reload` (v1.0.1) | operator | click |$' "$RLS/CHANGELOG.md" &&
	[[ $(grep -c '^### Setup after install$' "$RLS/CHANGELOG.md") == 1 && $(grep -c '^## Unreleased$' "$RLS/CHANGELOG.md") == 1 ]] &&
	grep -q '^LATER$' "$RLS/CHANGELOG.md" && grep -q '^C-NOTE$' "$RLS/CHANGELOG.md" &&
	ok "release --write inserts the block right under the Release heading and leaves the rest" || bad "release write (exit $code)" "$out"
once=$(cat "$RLS/CHANGELOG.md")
out=$("$PO" -C "$RLS" --manifest "$BM" release 7 --write 2>&1)
[[ $? == 0 && $(cat "$RLS/CHANGELOG.md") == "$once" && $out == *'already current'* ]] && ok "release --write is idempotent" || bad "release write twice" "$out"
rs_set "1.0.3@@1@@buildhost@@restart-it@@opssession@@it runs"
"$PO" -C "$RLS" --manifest "$BM" release 7 --write >/dev/null 2>&1
[[ $(grep -c '^### Setup after install$' "$RLS/CHANGELOG.md") == 1 && $(grep -c 'reload' "$RLS/CHANGELOG.md") == 0 && $(grep -c 'restart-it' "$RLS/CHANGELOG.md") == 1 ]] &&
	ok "release --write replaces a stale block instead of adding a second" || bad "release write replace"
out=$("$PO" -C "$RLS" --manifest "$BM" release 8 --write 2>&1)
code=$?
[[ $code == 1 || $code == 2 ]] && grep -q 'Release 8' <<<"$out" && ok "release --write without a Release heading refuses and says so" || bad "release write no heading (exit $code)" "$out"
{ cat "$BM"; printf '\n[release]\nreview = true\n'; } >"$RLS/rs.toml"
expect "release --setup under review = true refuses without the review row" 6 'release-7 has no pre-release review row' -- -C "$RLS" --manifest "$RLS/rs.toml" release 7 --setup
expect "release --setup does not combine with --open-review" 1 'do not combine' -- -C "$RLS" --manifest "$BM" release 7 --setup --open-review
# A no-change close hands the hook the admin commit as its item commit (v0.100).
N=$TMP/nc-hook
make_nochange "$N"
rm -f "$HENV"
out=$("$PO" -C "$N" --manifest "$HM" close 1.0.3 --commit 2>&1)
code=$?
[[ $code == 0 && $(henv PO_ITEM_COMMIT) == "$(git -C "$N" rev-parse main)" && $(henv PO_ADMIN_COMMIT) == "$(git -C "$N" rev-parse main)" ]] &&
	ok "a no-change close runs the hook with the admin commit as PO_ITEM_COMMIT" || bad "no-change hook (exit $code)" "$out"
hook_manifest "cat \"\$PO_EVIDENCE\" > $TMP/hook.ev; cat > $TMP/hook.in; printf '%s' \"\$PO_NEXT\" > $TMP/hook.next"
B=$TMP/h2
make_brepo "$B"
tip=$(git -C "$B" rev-parse item-v1.0.3)
"$PO" -C "$B" --manifest "$HM" close 1.0.3 --commit >/dev/null 2>&1
[[ $(head -1 "$TMP/hook.ev") == "HEAD $tip (item-v1.0.3)  dirty 0" && ! -s $TMP/hook.in ]] &&
	grep -qx 'gate PASS: check   tests 1 passed' "$TMP/hook.ev" &&
	ok "PO_EVIDENCE holds the stamp block; stdin is /dev/null" || bad "evidence / stdin" "$(cat "$TMP/hook.ev")"
[[ -f $TMP/hook.next && ! -s $TMP/hook.next ]] &&
	ok "PO_NEXT is empty without --next" || bad "empty PO_NEXT"
hook_manifest "printf '%s|%s' \"\$PO_BODY_FILE\" \"\${PO_NEXT-unset}\" > $TMP/hook.empty"
B=$TMP/h2b
make_brepo "$B"
"$PO" -C "$B" --manifest "$HM" close 1.0.3 --commit >/dev/null 2>&1
[[ $(<"$TMP/hook.empty") == '|' ]] && ok "PO_BODY_FILE and PO_NEXT are set but empty when not given" || bad "empty vars" "$(<"$TMP/hook.empty")"

# A failing hook: exit 7, a warning naming the hook and its code, the boundary intact.
hook_manifest "echo boom; exit 3"
B=$TMP/h3
make_brepo "$B"
tip=$(git -C "$B" rev-parse item-v1.0.3)
out=$("$PO" -C "$B" --manifest "$HM" close 1.0.3 --next 1.0.5 --commit 2>&1)
code=$?
[[ $code == 7 ]] && grep -q 'warning: hook on_close exited 3; the boundary stands' <<<"$out" &&
	ok "a failing hook exits 7 with a warning naming the hook and its code" || bad "failing hook (exit $code)" "$out"
[[ $(git -C "$B" rev-parse v1.0.3) == "$tip" && $(git -C "$B" rev-parse main^) == "$tip" &&
	$(git -C "$B" log -1 --format=%s main) == 'admin: v1.0.3 DONE (tag v1.0.3); v1.0.5 DOING' &&
	! -e $B/.wt/item-v1.0.3 && -d $B/.wt/item-v1.0.5 && -z $(git -C "$B" status --porcelain --untracked-files=no) ]] &&
	ok "after a failing hook the boundary stands: ff, tag, admin, --next, prune" || bad "boundary after failing hook" "$(git -C "$B" log --oneline -3 main)"

# The hook also runs when the closed worktree is kept (the boundary is complete).
hook_manifest "echo ran > $TMP/hook.kept"
B=$TMP/h4
make_brepo "$B"
printf 'cache/\n' >"$B/.git/info/exclude"
mkdir -p "$B/.wt/item-v1.0.3/cache"
echo c >"$B/.wt/item-v1.0.3/cache/x"
out=$("$PO" -C "$B" --manifest "$HM" close 1.0.3 --commit 2>&1)
[[ $? == 0 && -f $TMP/hook.kept ]] && grep -q 'it holds ignored files' <<<"$out" &&
	ok "the hook runs after a boundary that kept the closed worktree" || bad "hook after kept" "$out"

# Never on a refusal or a partial failure.
rm -f "$TMP/hook.kept"
B=$TMP/h5
make_brepo "$B"
echo scratch >>"$B/docs/BACKLOG.md"
out=$("$PO" -C "$B" --manifest "$HM" close 1.0.3 --commit 2>&1)
[[ $? == 6 && ! -e $TMP/hook.kept ]] && ok "a refused --commit runs no hook" || bad "hook after refusal" "$out"
git -C "$B" checkout -q -- docs/BACKLOG.md
printf '#!/bin/sh\nexit 1\n' >"$B/.git/hooks/pre-commit"
chmod +x "$B/.git/hooks/pre-commit"
out=$("$PO" -C "$B" --manifest "$HM" close 1.0.3 --commit 2>&1)
code=$?
[[ $code != 0 && $code != 7 && ! -e $TMP/hook.kept ]] && grep -q 'the admin commit failed' <<<"$out" &&
	ok "a partial failure (admin commit) runs no hook" || bad "hook after partial failure (exit $code)" "$out"

# open.
B=$TMP/b4
make_brepo "$B"
before=$(bsnap "$B")
expect "open next founds the next number" 0 '  \| admin: v1\.0\.6 Sixth founded DOING$' -- -C "$B" --manifest "$BM" open next "Sixth"
expect "open plans the founding heading" 0 '^\+## v1\.0\.6 — Sixth — DOING$' -- -C "$B" --manifest "$BM" open 1.0.6 "Sixth"
expect "open of a TODO item takes it DOING" 0 '  \| admin: v1\.0\.5 DOING for Ann$' -- -C "$B" --manifest "$BM" open 1.0.5 --for Ann
expect "open of a TODO item with its own title" 0 '^\+## v1\.0\.5 — Parser — DOING$' -- -C "$B" --manifest "$BM" open 1.0.5 Parser
expect "open of a TODO item with another title stops" 3 'the title differs' -- -C "$B" --manifest "$BM" open 1.0.5 "Other"
expect "open of a DOING item is refused" 6 'v1\.0\.3 is already founded and DOING' -- -C "$B" --manifest "$BM" open 1.0.3
expect "open out of sequence is refused" 6 'the next is 1\.0\.6' -- -C "$B" --manifest "$BM" open 1.0.8 "Eight"
expect "open of a new number needs a title" 1 'give it a "<title>"' -- -C "$B" --manifest "$BM" open 1.0.6
expect "an insert takes the next free 4th segment" 0 '  \| admin: v1\.0\.3\.1 Hotfix founded DOING$' -- -C "$B" --manifest "$BM" open 1.0.3.1 Hotfix
out=$("$PO" -C "$B" --manifest "$BM" open 1.0.3.1 Hotfix 2>&1)
grep -A3 -F -- '+## v1.0.3.1 — Hotfix — DOING' <<<"$out" | grep -qxF ' ## v1.0.4 — Fourth study — DOING' &&
	ok "an insert's heading goes before the next higher heading" || bad "insert placement" "$out"
expect "an insert skipping a number is refused" 6 'not the next insert under 1\.0\.3: that is 1\.0\.3\.1' -- -C "$B" --manifest "$BM" open 1.0.3.2 X
expect "an insert under an unfounded item is refused" 6 'inserts under 1\.0\.9, which no backlog source records' -- -C "$B" --manifest "$BM" open 1.0.9.1 X
expect "a new epoch needs --epoch" 6 'the next is 1\.0\.6 \(--epoch' -- -C "$B" --manifest "$BM" open 1.1.0 "Epoch"
expect "--epoch allows the next minor" 0 '  \| admin: v1\.1\.0 Epoch founded DOING$' -- -C "$B" --manifest "$BM" open 1.1.0 "Epoch" --epoch
expect "--epoch allows the next major" 0 '  \| admin: v2\.0\.0 Two founded DOING$' -- -C "$B" --manifest "$BM" open 2.0.0 "Two" --epoch
expect "--epoch still refuses a skip" 6 'not an epoch step' -- -C "$B" --manifest "$BM" open 1.2.0 "Skip" --epoch
expect "a five-segment number is refused" 6 'has 5 segments' -- -C "$B" --manifest "$BM" open 1.0.3.1.1 X
expect "open rejects unknown options" 1 "open: unknown argument '--force'" -- -C "$B" --manifest "$BM" open next X --force
[[ $(bsnap "$B") == "$before" ]] && ok "every open dry run above changed nothing" || bad "open dry runs changed state"

before_main=$(git -C "$B" rev-parse main)
out=$("$PO" -C "$B" --manifest "$BM" open next "Sixth" --for Ann --commit 2>&1)
code=$?
[[ $code == 0 && $(git -C "$B" rev-parse main^) == "$before_main" &&
	$(git -C "$B" log -1 --format=%s main) == 'admin: v1.0.6 Sixth founded DOING for Ann' ]] &&
	ok "open --commit writes the founding admin commit" || bad "open --commit (exit $code)" "$out"
[[ $(git -C "$B" rev-parse item-v1.0.6) == "$(git -C "$B" rev-parse main)" && -d $B/.wt/item-v1.0.6 ]] &&
	tail -1 "$B/docs/backlog/v1.md" | grep -qx '## v1.0.6 — Sixth — DOING' &&
	ok "open --commit makes the branch and worktree at the admin commit" || bad "open worktree" "$out"
expect "the opened item is fresh" 0 '^FRESH: item-v1\.0\.6' -- -C "$B" --manifest "$BM" fresh 1.0.6
expect "open next moves on" 0 '  \| admin: v1\.0\.7 Seven founded DOING$' -- -C "$B" --manifest "$BM" open next Seven
mkdir "$B/.wt/item-v1.0.7"
expect "a taken worktree path is refused" 6 '\.wt/item-v1\.0\.7 already exists' -- -C "$B" --manifest "$BM" open next Seven

# [close] checklist (item U).
CM=$TMP/ck.toml
ck_manifest() { # <array text>: BM plus [close] checklist = <array text>
	{ cat "$BM"; printf '\n[close]\nchecklist = %s\n' "$1"; } >"$CM"
}
ck_manifest '["Post the close message.", "", "Say \"hi\" # ok"]   # trailing'
CB=$TMP/c1
make_brepo "$CB"
before=$(bsnap "$CB")
out=$("$PO" -C "$CB" --manifest "$CM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 ]] && grep -q '^CHECKLIST (printed after a complete --commit boundary' <<<"$out" &&
	grep -qx '  Post the close message.' <<<"$out" && grep -qx '  Say "hi" # ok' <<<"$out" &&
	ok "the dry run lists the checklist and says it runs nothing" || bad "checklist dry run (exit $code)" "$out"
[[ $(bsnap "$CB") == "$before" ]] && ok "the checklist dry run changes nothing" || bad "checklist dry run wrote"
out=$("$PO" -C "$CB" --manifest "$CM" close 1.0.3 --commit 2>"$TMP/ck.err")
code=$?
[[ $code == 0 ]] && grep -qx 'CHECKLIST' <<<"$out" && grep -qx '  Post the close message.' <<<"$out" &&
	grep -qx '  Say "hi" # ok' <<<"$out" && ! grep -q 'running checklist' <<<"$out" &&
	[[ $(sed -n '/^CHECKLIST$/,$p' <<<"$out" | wc -l) == 4 ]] &&
	ok "close --commit prints the checklist after the boundary and runs nothing without the flag" || bad "checklist print (exit $code)" "$out"
[[ $(grep -n '^tagged ' <<<"$out" | cut -d: -f1) -lt $(grep -n '^CHECKLIST$' <<<"$out" | cut -d: -f1) ]] &&
	ok "the checklist comes after the boundary's steps" || bad "checklist order" "$out"
# Absent or empty: output unchanged.
CB=$TMP/c2
make_brepo "$CB"
base=$("$PO" -C "$CB" --manifest "$BM" close 1.0.3 2>&1)
ck_manifest '[]'
out=$("$PO" -C "$CB" --manifest "$CM" close 1.0.3 2>&1)
[[ $out == "$base" ]] && ! grep -q CHECKLIST <<<"$out" &&
	ok "an empty checklist leaves the close plan byte-identical" || bad "empty checklist" "$out"
out=$("$PO" -C "$CB" --manifest "$BM" close 1.0.3 2>&1)
[[ $out == "$base" ]] && ok "no [close] section: the close plan is unchanged" || bad "no checklist" "$out"
out=$("$PO" -C "$CB" --manifest "$BM" close 1.0.3 --commit 2>&1)
! grep -qi checklist <<<"$out" && ok "no [close] section: --commit prints no checklist" || bad "checklist without section" "$out"
expect "--run-checklist without a checklist is a usage error" 1 'needs a \[close\] checklist' -- -C "$CB" --manifest "$BM" close 1.0.3 --run-checklist
expect "--run-checklist with an empty checklist is a usage error" 1 'needs a \[close\] checklist' -- -C "$CB" --manifest "$CM" close 1.0.3 --run-checklist
# --run-checklist: runs every non-blank line, environment set, in the main worktree.
CKO=$TMP/ck.out
rm -f "$CKO"
ck_manifest "[\"printf '%s|%s|%s|' \\\"\$PO_VERSION\\\" \\\"\$PO_TAG\\\" \\\"\$PO_TITLE\\\" >> $CKO; pwd >> $CKO\", \"\", \"echo ck-stdout; cat >> $CKO\"]"
CB=$TMP/c3
make_brepo "$CB"
out=$("$PO" -C "$CB" --manifest "$CM" close 1.0.3 --run-checklist 2>&1)
code=$?
[[ $code == 0 && ! -e $CKO ]] && grep -q '^CHECKLIST (printed, then each non-blank line run' <<<"$out" &&
	ok "the dry run with --run-checklist says it would run, and runs nothing" || bad "checklist run dry (exit $code)" "$out"
out=$("$PO" -C "$CB" --manifest "$CM" close 1.0.3 --run-checklist --commit 2>"$TMP/ck.err")
code=$?
[[ $code == 0 && $(head -1 "$CKO") == "1.0.3|v1.0.3|Third|$CB" ]] &&
	ok "--run-checklist runs the lines in the main worktree with PO_VERSION, PO_TAG, PO_TITLE" || bad "checklist run (exit $code)" "$(cat "$CKO") / $out"
grep -qx 'ck-stdout' "$TMP/ck.err" && ! grep -qx 'ck-stdout' <<<"$out" && grep -q '^running checklist: ' <<<"$out" &&
	[[ $(grep -c '^running checklist: ' <<<"$out") == 2 ]] &&
	ok "the lines' stdout goes to stderr, blank lines are not run, stdin is /dev/null" || bad "checklist output" "$out / $(cat "$TMP/ck.err")"
# A failing line: the rest still run, exit 7, the boundary stands, the hook still runs.
rm -f "$CKO" "$TMP/hook.kept"
ck_manifest "[\"exit 3\", \"echo second >> $CKO\"]"
{ cat "$CM"; printf '\n[hooks]\non_close = "echo ran > %s"\n' "$TMP/hook.kept"; } >"$TMP/ck2.toml"
CB=$TMP/c4
make_brepo "$CB"
tip=$(git -C "$CB" rev-parse item-v1.0.3)
out=$("$PO" -C "$CB" --manifest "$TMP/ck2.toml" close 1.0.3 --run-checklist --commit 2>&1)
code=$?
[[ $code == 7 && -f $CKO && -f $TMP/hook.kept ]] && grep -q 'warning: checklist line exited 3: exit 3' <<<"$out" &&
	grep -q 'warning: 1 checklist line(s) failed; the boundary stands' <<<"$out" &&
	ok "a failing checklist line is exit 7; later lines and the hook still run" || bad "failing checklist (exit $code)" "$out"
[[ $(git -C "$CB" rev-parse v1.0.3) == "$tip" && ! -e $CB/.wt/item-v1.0.3 ]] &&
	ok "after a failing checklist line the boundary stands" || bad "boundary after failing checklist"
# Malformed.
ckbad() {
	printf '[close]\nchecklist = %s\n' "$2" | cat "$BM" - >"$TMP/ckb.toml"
	expect "$1" 2 "$3" -- -C "$CB" --manifest "$TMP/ckb.toml" status
}
ckbad "a checklist that is a string, not an array, is a manifest error" '"one line"' 'value must be an array'
ckbad "a checklist with an unquoted element is a manifest error" '[one]' 'array elements must be'
ckbad "a checklist with a missing comma is a manifest error" '["a" "b"]' "expected ',' or ']'"
ckbad "a checklist with a trailing comma is a manifest error" '["a",]' 'trailing comma'
ckbad "a checklist with text after the array is a manifest error" '["a"] x' 'unexpected text after array'
ckbad "a checklist element with a bad escape is a manifest error" '["a\n"]' 'unsupported escape'
ckbad "a checklist given an integer is a manifest error" '3' 'value must be an array'
printf '[close]\nother = "x"\n' | cat "$BM" - >"$TMP/ckb.toml"
expect "an unknown [close] key is a manifest error" 2 "unknown key 'other' in \[close\]" -- -C "$CB" --manifest "$TMP/ckb.toml" status

# [close] require_setup: the "Setup after install" section (item v0.84).
SM=$TMP/su.toml
{ cat "$BM"; printf '\n[close]\nrequire_setup = true\n'; } >"$SM"
{ cat "$SM"; printf '\n[docs]\nrules = "docs/BACKLOG.md"\n'; } >"$TMP/su-k.toml"
{ cat "$BM"; printf '\n[docs]\nrules = "docs/BACKLOG.md"\n'; } >"$TMP/su-k0.toml"
setup_spec() { # <repo> <text>: put <text> in v1.0.3's spec section on its branch, re-stamp
	local w=$1/.wt/item-v1.0.3
	python3 -I -c 'import sys; p=sys.argv[1]; s=open(p).read(); open(p,"w").write(s.replace("Body of three.\n", "Body of three.\n\n"+sys.argv[2]+"\n", 1))' "$w/docs/backlog/v1.md" "$2"
	git -C "$w" commit -q -a --amend -m "v1.0.3: Third"
	rm -f "$w"/gate-*.txt
	"$PO" -C "$w" --manifest "$BM" stamp >/dev/null 2>&1
}
# shellcheck disable=SC2016 # backticks in markdown, not expansions
SU_TABLE='### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | build host | `systemctl --user restart viewer` | operator | the viewer shows the tag |
| 2 | laptop | `viewer-install \| tee log` | owner | the menu entry opens it |
| 3 | build host | - | operator | click Reload; the page says v1.0.3 |'
SU=$TMP/su1
make_brepo "$SU"
before=$(bsnap "$SU")
expect "require_setup: a spec without the section is refused" 6 'refused: v1\.0\.3.s spec has no "Setup after install" section \(looked in: docs/backlog/v1\.md:7-10\); write its steps, or the word None' -- \
	-C "$SU" --manifest "$SM" close 1.0.3
[[ $(bsnap "$SU") == "$before" ]] && ok "require_setup: the refusal changes nothing" || bad "setup refusal wrote"
base=$("$PO" -C "$SU" --manifest "$BM" close 1.0.3 2>&1)
{ cat "$BM"; printf '\n[close]\nrequire_setup = false   # off\n'; } >"$TMP/su-off.toml"
out=$("$PO" -C "$SU" --manifest "$TMP/su-off.toml" close 1.0.3 2>&1)
[[ $out == "$base" ]] && ok "require_setup = false leaves the close plan byte-identical" || bad "require_setup false" "$out"
{ cat "$BM"; printf '\n[close]\nrequire_setup = "true"\n'; } >"$TMP/su-bad.toml"
expect "require_setup as a quoted string is a manifest error" 2 "key 'require_setup' in \[close\] must be true or false, without quotes" -- -C "$SU" --manifest "$TMP/su-bad.toml" status
{ cat "$BM"; printf '\n[close]\nrequire_setup = yes\n'; } >"$TMP/su-bad.toml"
expect "require_setup = yes is a manifest error" 2 'must be true or false' -- -C "$SU" --manifest "$TMP/su-bad.toml" status
{ cat "$BM"; printf '\n[close]\nchecklist = true\n'; } >"$TMP/su-bad.toml"
expect "true for a key that is not a switch is a manifest error" 2 'value must be an array' -- -C "$SU" --manifest "$TMP/su-bad.toml" status
expect "kickoff names the section the close will need" 0 '^setup     this item needs a "Setup after install" section in its spec \(its steps, or None\) before po close$' -- \
	-C "$SU" --manifest "$TMP/su-k.toml" kickoff 1.0.3
out=$("$PO" -C "$SU" --manifest "$TMP/su-k0.toml" kickoff 1.0.3 2>&1)
code=$?
[[ $code == 0 ]] && ! grep -q '^setup ' <<<"$out" && ok "kickoff without require_setup prints no setup line" || bad "kickoff setup line" "$out"
setup_spec "$SU" '### Setup after install

None'
expect "require_setup: a section saying None is accepted" 0 '^setup     None \(docs/backlog/v1\.md:11\)$' -- -C "$SU" --manifest "$SM" close 1.0.3
out=$("$PO" -C "$SU" --manifest "$SM" close 1.0.3 2>&1)
! grep -q '^SETUP' <<<"$out" && ok "a None section has no SETUP block" || bad "None block" "$out"
SU=$TMP/su2
make_brepo "$SU"
setup_spec "$SU" "$SU_TABLE"
out=$("$PO" -C "$SU" --manifest "$SM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx 'setup     3 step(s) (docs/backlog/v1.md:11)' <<<"$out" &&
	ok "require_setup: a table of steps is accepted and counted" || bad "setup table (exit $code)" "$out"
want='SETUP (3 step(s); recorded open by --commit, open until po setup confirm)
  build host · operator
    1. systemctl --user restart viewer
       check: the viewer shows the tag
    3. -
       check: click Reload; the page says v1.0.3
  laptop · owner
    2. viewer-install | tee log
       check: the menu entry opens it'
[[ $(sed -n '/^SETUP (/,/^$/p' <<<"$out" | sed '/^$/d') == "$want" ]] &&
	ok "the close plan groups the steps by machine and who" || bad "SETUP block" "$out"
setup_bad() { # <name> <section> <pattern>
	local q=$TMP/su-bad-$((++SU_N))
	make_brepo "$q"
	setup_spec "$q" "$2"
	expect "$1" 6 "$3" -- -C "$q" --manifest "$SM" close 1.0.3
}
SU_N=0
setup_bad "a step numbered out of order is refused" "${SU_TABLE/| 2 | laptop/| 4 | laptop}" 'steps must be numbered 1, 2, 3\.\.\.; expected 2, found 4'
setup_bad "a step without a Check is refused" "${SU_TABLE/| the menu entry opens it |/| |}" 'line 16: step 2 has no Check'
setup_bad "a command not in backticks is refused" "${SU_TABLE/\`systemctl --user restart viewer\`/systemctl restart}" "step 1's Command must be one \`backticked\` command"
setup_bad "wrong columns are refused" "${SU_TABLE/| Who |/| Owner |}" 'the columns must be \| # \| Machine \| Command \| Who \| Check \|'
setup_bad "prose instead of a table is refused" '### Setup after install

Restart the viewer.' 'not a table row and not the word None'
setup_bad "an empty section is refused" '### Setup after install
' 'the section is empty'
# The section in a file the backlog row names.
SU=$TMP/su3
# shellcheck disable=SC2016 # backticks in markdown, not expansions
BREPO_TABLE='| Item | Title | Status |
|---|---|---|
| v1.0.1 | First | DONE |
| v1.0.3 | Third (`docs/notes/three.md`) | DOING |' make_brepo "$SU"
mkdir -p "$SU/.wt/item-v1.0.3/docs/notes"
printf '# Three\n\nNotes.\n\n## Setup after install\n\nNone\n' >"$SU/.wt/item-v1.0.3/docs/notes/three.md"
git -C "$SU/.wt/item-v1.0.3" add docs/notes/three.md
git -C "$SU/.wt/item-v1.0.3" commit -q --amend -m "v1.0.3: Third"
rm -f "$SU/.wt/item-v1.0.3"/gate-*.txt
"$PO" -C "$SU/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
expect "the section is found in a file the backlog row names" 0 '^setup     None \(docs/notes/three\.md:5\)$' -- -C "$SU" --manifest "$SM" close 1.0.3
# The row's line number is read from the revision it was found at: lines inserted at the top of
# the backlog on the item branch must not make the close read another row (item v0.95).
SU=$TMP/su3b
# shellcheck disable=SC2016 # backticks in markdown, not expansions
BREPO_TABLE='| Item | Title | Status |
|---|---|---|
| v1.0.1 | First | DONE |
| v1.0.3 | Third (`docs/notes/three.md`) | DOING |' make_brepo "$SU"
SW=$SU/.wt/item-v1.0.3
mkdir -p "$SW/docs/notes"
# shellcheck disable=SC2016 # backticks in markdown, not expansions
printf '# Three\n\n## Setup after install\n\n| # | Machine | Command | Who | Check |\n|---|---|---|---|---|\n| 1 | host | `restart it` | operator | it runs |\n' >"$SW/docs/notes/three.md"
sed -i '1i filler one\nfiller two\nfiller three' "$SW/docs/BACKLOG.md"
git -C "$SW" add docs
git -C "$SW" commit -q --amend -m "v1.0.3: Third"
rm -f "$SW"/gate-*.txt
"$PO" -C "$SW" --manifest "$BM" stamp >/dev/null 2>&1
expect "backlog lines inserted on the item branch: the Setup section is still found" 0 '^setup     1 step\(s\) \(docs/notes/three\.md:3\)$' -- -C "$SU" --manifest "$SM" close 1.0.3
"$PO" -C "$SU" --manifest "$SM" close 1.0.3 --commit >/dev/null 2>&1
python3 -I -c 'import json,sys
d = json.load(open(sys.argv[1]))
assert [(x["item"], x["n"], x["command"]) for x in d["steps"]] == [("1.0.3", 1, "restart it")], d' "$SU/.git/po-setup-steps.json" &&
	ok "backlog lines inserted on the item branch: the recorded steps are the item's own" || bad "shifted backlog steps"
# A row naming CHANGELOG.md and the real spec file resolves to the spec file.
SU=$TMP/su3c
# shellcheck disable=SC2016 # backticks in markdown, not expansions
BREPO_TABLE='| Item | Title | Status |
|---|---|---|
| v1.0.1 | First | DONE |
| v1.0.3 | Third (`CHANGELOG.md`, `docs/notes/three.md`) | DOING |' make_brepo "$SU"
SW=$SU/.wt/item-v1.0.3
mkdir -p "$SW/docs/notes"
printf '# Changelog\n\n## Setup after install\n\nNone\n' >"$SW/CHANGELOG.md"
printf '# Three\n\nNotes.\n\n## Setup after install\n\nNone\n' >"$SW/docs/notes/three.md"
git -C "$SW" add docs CHANGELOG.md
git -C "$SW" commit -q --amend -m "v1.0.3: Third"
rm -f "$SW"/gate-*.txt
"$PO" -C "$SW" --manifest "$BM" stamp >/dev/null 2>&1
expect "a row naming CHANGELOG.md and its spec file resolves to the spec file" 0 '^setup     None \(docs/notes/three\.md:5\)$' -- -C "$SU" --manifest "$SM" close 1.0.3
# Exempt: founded before the key was on, judged from the manifest at the founding commit.
SU=$TMP/su4
make_brepo "$SU"
cp "$TMP/su-k0.toml" "$SU/po.toml"
git -C "$SU" add po.toml
git -C "$SU" commit -qm "admin: manifest"
cp "$TMP/su-k.toml" "$SU/po.toml"
git -C "$SU" commit -qam "admin: adopt require_setup"
git -C "$SU/.wt/item-v1.0.3" rebase -q main
rm -f "$SU/.wt/item-v1.0.3"/gate-*.txt
"$PO" -C "$SU/.wt/item-v1.0.3" stamp >/dev/null 2>&1
expect "an item founded before require_setup was on is exempt" 0 '^setup     exempt: founded before \[close\] require_setup$' -- -C "$SU" close 1.0.3
out=$("$PO" -C "$SU" kickoff 1.0.3 2>&1)
code=$?
[[ $code == 0 ]] && ! grep -q '^setup ' <<<"$out" && ok "kickoff prints no setup line for an exempt item" || bad "kickoff exempt" "$out"
"$PO" -C "$SU" open 1.0.5 --commit >/dev/null 2>&1
SU5=$SU/.wt/item-v1.0.5
echo five >"$SU5/five.txt"
git -C "$SU5" add five.txt
git -C "$SU5" commit -qm "v1.0.5: Parser"
"$PO" -C "$SU5" stamp >/dev/null 2>&1
expect "an item founded after require_setup was on needs the section" 6 'v1\.0\.5.s spec has no "Setup after install" section' -- -C "$SU" close 1.0.5
# --commit records the steps; po setup list, confirm, record.
SU=$TMP/su2
out=$("$PO" -C "$SU" --manifest "$SM" close 1.0.3 --commit 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx 'recorded 3 setup step(s) for v1.0.3, open until po setup confirm' <<<"$out" &&
	[[ -f $SU/.git/po-setup-steps.json ]] &&
	ok "close --commit records the steps in the git dir" || bad "setup record at close (exit $code)" "$out"
expect "setup list shows the open steps" 0 '^v1\.0\.3 #2  open  laptop  owner  viewer-install \| tee log$' -- -C "$SU" --manifest "$SM" setup list
expect "setup list shows each step's check" 0 '^    check: the viewer shows the tag$' -- -C "$SU" --manifest "$SM" setup list --item v1.0.3
expect "setup confirm marks a step done" 0 '^confirmed v1\.0\.3 step 2 \(by ann\)$' -- -C "$SU" --manifest "$SM" setup confirm 1.0.3 2 --by ann
out=$("$PO" -C "$SU" --manifest "$SM" setup list 2>&1)
[[ $(grep -c '^v1\.0\.3 #' <<<"$out") == 2 ]] && ! grep -q '#2' <<<"$out" &&
	ok "a confirmed step leaves the open list" || bad "list after confirm" "$out"
expect "setup list --all shows who confirmed it and when" 0 '^v1\.0\.3 #2  confirmed by ann at [0-9-]+T[0-9:]+Z  laptop' -- -C "$SU" --manifest "$SM" setup list --all
python3 -I -c 'import json,sys
d = json.loads(sys.argv[1])
s = {x["n"]: x for x in d["steps"]}
assert set(s) == {1, 2, 3} and s[2]["status"] == "confirmed" and s[2]["confirmed_by"] == "ann", d
assert s[1]["status"] == "open" and s[1]["item"] == "1.0.3" and s[1]["machine"] == "build host" and s[1]["confirmed_by"] is None, d
assert s[3]["command"] == "-" and s[1]["recorded_at"].endswith("Z"), d' "$("$PO" -C "$SU" --manifest "$SM" setup list --all --json)" &&
	ok "setup list --json carries every field of a step" || bad "setup list json"
expect "confirming a confirmed step changes nothing" 0 '^already confirmed by ann at ' -- -C "$SU" --manifest "$SM" setup confirm 1.0.3 2 --by bob
expect "confirming an unknown step is a usage error" 1 'v1\.0\.3 has no recorded step 9' -- -C "$SU" --manifest "$SM" setup confirm 1.0.3 9 --by ann
expect "setup confirm needs --by" 1 'setup confirm: --by <who> is required' -- -C "$SU" --manifest "$SM" setup confirm 1.0.3 1
expect "setup needs a subcommand" 1 'usage: po setup list' -- -C "$SU" --manifest "$SM" setup
# captured first: under pipefail, grep -q quitting early would SIGPIPE po events and fail the pipeline
out=$("$PO" -C "$SU" --manifest "$SM" events --json)
grep -q '"kind":"setup","item":"1.0.3".*"detail":"step 2 confirmed by ann"' <<<"$out" &&
	ok "a confirm is logged as a setup event" || bad "setup event" "$out"
expect "setup record without --commit is a dry run" 0 'po setup record: DRY RUN' -- -C "$SU" --manifest "$SM" setup record 1.0.3
"$PO" -C "$SU" --manifest "$SM" setup record 1.0.3 --commit >/dev/null 2>&1
python3 -I -c 'import json,sys
s = {x["n"]: x for x in json.loads(sys.argv[1])["steps"]}
assert len(s) == 3 and s[2]["confirmed_by"] == "ann" and s[1]["status"] == "open", s' "$("$PO" -C "$SU" --manifest "$SM" setup list --all --json)" &&
	ok "setup record re-writes the open steps and keeps the confirmed ones" || bad "setup record"
expect "setup list in a repo with no steps is empty" 0 '^$' -- -C "$TMP/su1" --manifest "$SM" setup list

# ---- kickoff --------------------------------------------------------------
K=$TMP/kick
git init -q -b main "$K"
git -C "$K" config user.name t
git -C "$K" config user.email t@example.invalid
mkdir -p "$K/docs/backlog"
printf '# Backlog\n\nItems live in the spec files.\n' >"$K/docs/BACKLOG.md"
printf '# Decisions\n' >"$K/docs/DECISIONS.md"
printf '# Rules\n' >"$K/RULES.md"
cat >"$K/docs/backlog/v1.md" <<'EOF'
# v1 era

## v1.0.1 — First — DONE
done.
EOF
git -C "$K" add -A && git -C "$K" commit -qm "v1.0.1: First"
git -C "$K" tag v1.0.1
cat >>"$K/docs/backlog/v1.md" <<'EOF'

## v1.0.2 — Second — DOING

**Founding.** Build the second thing.

### Fixed points
- keep it small

```sh
# a comment, not a heading
## nor this
```

Tail line.

## v1.0.3 — Third — TODO
later.
EOF
git -C "$K" add -A && git -C "$K" commit -qm "admin: v1.0.1 DONE; v1.0.2 founded DOING"
found=$(git -C "$K" rev-parse --short HEAD)
echo r >>"$K/docs/DECISIONS.md"
git -C "$K" commit -qam "fork ruled (no prefix)"
git -C "$K" commit -q --allow-empty -m "v1.0.9: Other item"
git -C "$K" commit -q --allow-empty -m "typo fix"
echo r >>"$K/RULES.md"
git -C "$K" commit -qam "admin: rule widened"
KM=$TMP/k.toml
printf '%s' "${GOOD_MANIFEST/'tag = "v{version}"   # comment after a string'/'tag = "v{version}"
admin_prefix = "admin:"
item_commit = "v{version}: {title}"'}" >"$KM"
printf '[docs]\ndecisions = "docs/DECISIONS.md"\nrules = "RULES.md"\n' >>"$KM"
ksnap() { git -C "$K" for-each-ref; git -C "$K" worktree list --porcelain; git -C "$K" status --porcelain --ignored; }

before=$(ksnap)
out=$("$PO" -C "$K" --manifest "$KM" kickoff 1.0.2 2>&1)
code=$?
got=$(sed -n '/^SPEC SECTION /,/^END SPEC SECTION$/p' <<<"$out" | sed '1d;$d')
want=$(sed -n '6,19p' "$K/docs/backlog/v1.md")
[[ $code == 0 && $got == "$want" ]] &&
	grep -qx 'SPEC SECTION docs/backlog/v1.md:6-19 (heading v1.0.2, from main [0-9a-f]*)' <<<"$out" &&
	ok "kickoff prints the spec section verbatim, fenced headings and subsections inside" ||
	bad "kickoff section (exit $code)" "$out"
grep -qx "boundary  v1.0.1 .. founded DOING at $found" <<<"$out" &&
	grep -qE '^rules     RULES\.md \(blob [0-9a-f]+ on main\)' <<<"$out" &&
	grep -qx 'decisions docs/DECISIONS.md' <<<"$out" &&
	grep -qx 'status    DOING (main [0-9a-f]*)' <<<"$out" &&
	ok "kickoff names the boundaries and the rules pointer" || bad "kickoff header" "$out"
got=$(sed -n '/^ADMIN\/RULING SINCE v1.0.1 /,/^$/p' <<<"$out" | sed '1d;/^$/d')
[[ $(wc -l <<<"$got") == 1 ]] && grep -qE "^  $found  ADMIN +admin: v1\.0\.1 DONE; v1\.0\.2 founded DOING$" <<<"$got" &&
	grep -q '^ADMIN/RULING SINCE v1.0.1 (1 of 1 commits' <<<"$out" &&
	ok "kickoff lists the admin commits from the previous tag to the founding" || bad "kickoff list" "$out"
got=$(sed -n '/^ADMIN\/RULING SINCE THE FOUNDING /,/^$/p' <<<"$out" | sed '1d;/^$/d')
# fresh's classification of the same commits, from a branch at the founding.
git -C "$K" branch -q item-v1.0.2 "$found"
fout=$("$PO" -C "$K" --manifest "$KM" fresh 1.0.2 2>&1)
git -C "$K" branch -q -D item-v1.0.2
want=$(grep -E '^  [0-9a-f]+  (ADMIN|[A-Z0-9. v]+ RUL)' <<<"$fout")
[[ -n $got && $got == "$want" ]] && grep -q 'SINCE THE FOUNDING .*(2 of 4 commits' <<<"$out" &&
	grep -qE 'RULING +fork ruled \(no prefix\)$' <<<"$got" && grep -qE 'ADMIN RULES +admin: rule widened$' <<<"$got" &&
	ok "an open item also lists main since its founding, classed exactly as fresh" || bad "kickoff since founding" "$got
--- fresh
$want"
[[ $(ksnap) == "$before" ]] && ok "kickoff changes nothing" || bad "kickoff wrote something"

out=$("$PO" -C "$K" --manifest "$KM" kickoff v1.0.3 2>&1)
grep -qx 'boundary  v1.0.1 .. main tip [0-9a-f]* (never DOING on main)' <<<"$out" &&
	grep -q '^ADMIN/RULING SINCE v1.0.1 (3 of 5 commits' <<<"$out" &&
	sed -n '/^SPEC SECTION /,/^END SPEC SECTION$/p' <<<"$out" | sed -n 2p | grep -qx '## v1.0.3 — Third — TODO' &&
	ok "an item not yet DOING is listed to main's tip; a section at EOF" || bad "kickoff TODO" "$out"
out=$("$PO" -C "$K" --manifest "$KM" kickoff 1.0.1 2>&1)
grep -q '^ADMIN/RULING SINCE THE ROOT' <<<"$out" && grep -q '^boundary  (no tag) .. main tip' <<<"$out" &&
	! grep -q 'SINCE THE FOUNDING' <<<"$out" &&
	ok "an item's own tag is not its previous boundary; no tag below it lists from the root" || bad "kickoff root" "$out"
expect "no spec section is a missing source" 2 'no spec section for v1\.0\.7 under docs/backlog on main — a founding in progress' -- -C "$K" --manifest "$KM" kickoff 1.0.7
sed '/^rules = /d' "$KM" >"$TMP/k3.toml"
expect "no [docs] rules is a missing source" 2 'names no \[docs\] rules' -- -C "$K" --manifest "$TMP/k3.toml" kickoff 1.0.2
sed 's/RULES.md/NOPE.md/' "$KM" >"$TMP/k2.toml"
expect "a rules file not on main is a missing source" 2 "rules 'NOPE.md' is not a file on main" -- -C "$K" --manifest "$TMP/k2.toml" kickoff 1.0.2
expect "kickoff needs a version" 1 'kickoff needs exactly one' -- -C "$K" --manifest "$KM" kickoff
expect "kickoff takes no options" 1 "kickoff: unknown argument '--commit'" -- -C "$K" --manifest "$KM" kickoff --commit
expect "kickoff rejects a non-version" 1 "kickoff: 'x' is not a version" -- -C "$K" --manifest "$KM" kickoff x
# Uncommitted edits are not read: main is.
echo 'uncommitted' >>"$K/docs/backlog/v1.md"
expect "kickoff reads the spec as committed on main" 0 '^later\.$' -- -C "$K" --manifest "$KM" kickoff 1.0.3
out=$("$PO" -C "$K" --manifest "$KM" kickoff 1.0.3 2>&1)
! grep -q uncommitted <<<"$out" && ok "an uncommitted spec line is not in the section" || bad "kickoff read the checkout" "$out"
git -C "$K" checkout -q -- docs/backlog/v1.md
# A last line without a newline keeps the end marker on its own line.
printf '## v1.0.4 — Fourth — TODO\nno newline' >>"$K/docs/backlog/v1.md"
git -C "$K" commit -qam "admin: v1.0.4 founded TODO"
out=$("$PO" -C "$K" --manifest "$KM" kickoff 1.0.4 2>&1)
grep -qx 'no newline' <<<"$out" && grep -qx 'END SPEC SECTION' <<<"$out" &&
	ok "a section at an unterminated EOF still ends on its own marker line" || bad "kickoff EOF" "$out"

# A table-shaped ledger: sections named by the label left of the id.
T=$TMP/table
git init -q -b main "$T"
git -C "$T" config user.name t
git -C "$T" config user.email t@example.invalid
mkdir -p "$T/docs"
cat >"$T/docs/BACKLOG.md" <<'EOF'
| Item | Tag | Content | Status |
|---|---|---|---|
| A | v0.1 | first | DONE |
| D | v0.4 | open and close | DOING |
| D.1 | v0.4.1 | insert | TODO |
EOF
cat >"$T/SPEC.md" <<'EOF'
# Spec
## Commands
### `a` (item A)
A body.
### `close` (item D — boundary)
Close body.
#### detail
still D.
### `open` (item D, same item)
Open body.
### `tag` (item D.1 — insert)
Insert body.
## Items
| A | first |
EOF
printf 'rules\n' >"$T/README.md"
git -C "$T" add -A && git -C "$T" commit -qm "admin: founded; D DOING"
printf '[versioning]\ntag = "v{version}"\nadmin_prefix = "admin:"\n[layout]\nbacklog = "docs/BACKLOG.md"\nspecs_dir = "."\nworktrees = ".wt"\nbranch = "item-v{version}"\n[docs]\nrules = "README.md"\n' >"$TMP/t.toml"
out=$("$PO" -C "$T" --manifest "$TMP/t.toml" kickoff 0.4 2>&1)
code=$?
[[ $code == 0 && $(grep -c '^SPEC SECTION SPEC\.md:' <<<"$out") == 2 ]] &&
	grep -q '^SPEC SECTION SPEC.md:5-8 (heading names item D,' <<<"$out" &&
	grep -q '^SPEC SECTION SPEC.md:9-10 (heading names item D,' <<<"$out" &&
	! grep -q 'Insert body' <<<"$out" && grep -qx 'still D.' <<<"$out" &&
	ok "a table-shaped ledger: every heading naming the item's label, not D.1's" || bad "kickoff table (exit $code)" "$out"
out=$("$PO" -C "$T" --manifest "$TMP/t.toml" kickoff 0.4.1 2>&1)
grep -q '^SPEC SECTION SPEC.md:11-12 (heading names item D.1,' <<<"$out" && ! grep -q 'Close body' <<<"$out" &&
	ok "an insert's label finds only its own heading" || bad "kickoff table insert" "$out"

# Review regressions. A fence closes only on its own kind and length.
cat >>"$K/docs/backlog/v1.md" <<'EOF'

## v1.0.5 — Fifth — TODO
````
~~~
```
# inside
````
## v1.0.6 — Sixth — TODO
EOF
git -C "$K" commit -qam "admin: v1.0.5 v1.0.6 founded TODO"
out=$("$PO" -C "$K" --manifest "$KM" kickoff 1.0.5 2>&1)
grep -q '^SPEC SECTION docs/backlog/v1.md:24-29 ' <<<"$out" && ! grep -q 'Sixth' <<<"$out" &&
	ok "a fence closed by its own kind ends before the next item's heading" || bad "kickoff fence" "$out"
# A hyphenated label is another label.
printf '| D-2 | v0.6 | other | TODO |\n' >>"$T/docs/BACKLOG.md"
printf '### x (item D-2)\nD-2 body.\n' >>"$T/SPEC.md"
git -C "$T" commit -qam "admin: D-2 founded"
out=$("$PO" -C "$T" --manifest "$TMP/t.toml" kickoff 0.4 2>&1)
! grep -q 'D-2 body' <<<"$out" && [[ $(grep -c '^SPEC SECTION' <<<"$out") == 2 ]] &&
	ok "label D does not match item D-2" || bad "kickoff hyphen label" "$out"
# A trailing slash on specs_dir still reads.
sed 's|specs_dir = "docs/backlog"|specs_dir = "docs/backlog/"|' "$KM" >"$TMP/k4.toml"
expect "specs_dir with a trailing slash" 0 '^SPEC SECTION docs/backlog/v1\.md:6-19 ' -- -C "$K" --manifest "$TMP/k4.toml" kickoff 1.0.2
expect "status with a trailing-slash specs_dir" 0 'DOING \(1\)' -- -C "$K" --manifest "$TMP/k4.toml" status
# A commit before the spec layout existed is skipped and named, not fatal.
P=$TMP/prelayout
git init -q -b main "$P"
git -C "$P" config user.name t
git -C "$P" config user.email t@example.invalid
mkdir -p "$P/docs"
printf 'planned: v1.0.2 later\n' >"$P/docs/BACKLOG.md"
printf 'rules\n' >"$P/RULES.md"
git -C "$P" add -A && git -C "$P" commit -qm "admin: plan"
early=$(git -C "$P" rev-parse --short HEAD)
mkdir -p "$P/docs/backlog"
printf '## v1.0.2 — Two — DOING\nbody\n' >"$P/docs/backlog/s.md"
git -C "$P" add -A && git -C "$P" commit -qm "admin: v1.0.2 founded DOING"
out=$("$PO" -C "$P" --manifest "$KM" kickoff 1.0.2 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx "boundary  (no tag) .. founded DOING at $(git -C "$P" rev-parse --short HEAD)" <<<"$out" &&
	grep -q "^note      $early mentions v1.0.2 but po cannot read its backlog" <<<"$out" &&
	ok "an unreadable older backlog is skipped and named" || bad "kickoff prelayout (exit $code)" "$out"

# [kickoff] preamble: lines at the top of the brief.
base=$("$PO" -C "$K" --manifest "$KM" kickoff 1.0.2 2>&1)
printf '[kickoff]\n# a comment\npreamble = ["Read the rules first.", "", "Say \\"hi\\" \\\\ ok"]   # trailing\n' >"$TMP/kp.toml"
cat "$KM" "$TMP/kp.toml" >"$TMP/kp1.toml"
out=$("$PO" -C "$K" --manifest "$TMP/kp1.toml" kickoff 1.0.2 2>&1)
code=$?
want=$'Read the rules first.\n\nSay "hi" \\ ok\n\n'"$base"
[[ $code == 0 && $out == "$want" ]] &&
	ok "a kickoff preamble prints its lines, verbatim, at the top, then the unchanged brief" || bad "kickoff preamble (exit $code)" "$out"
printf '[kickoff]\npreamble = []\n' | cat "$KM" - >"$TMP/kp2.toml"
out=$("$PO" -C "$K" --manifest "$TMP/kp2.toml" kickoff 1.0.2 2>&1)
[[ $out == "$base" ]] && ok "an empty preamble array leaves the brief byte-identical" || bad "kickoff empty preamble" "$out"
kpbad() {
	printf '[kickoff]\npreamble = %s\n' "$2" | cat "$KM" - >"$TMP/kpb.toml"
	expect "$1" 2 "$3" -- -C "$K" --manifest "$TMP/kpb.toml" kickoff 1.0.2
}
kpbad "a preamble that is a string, not an array, is a manifest error" '"one line"' 'value must be an array'
kpbad "a preamble with an unquoted element is a manifest error" '[one]' 'array elements must be'
kpbad "a preamble with an unterminated array is a manifest error" '["a", "b"' 'unterminated string|expected|array elements'
kpbad "a preamble with a missing comma is a manifest error" '["a" "b"]' "expected ',' or ']'"
kpbad "a preamble with a trailing comma is a manifest error" '["a",]' 'trailing comma'
kpbad "a preamble with text after the array is a manifest error" '["a"] x' 'unexpected text after array'
kpbad "a preamble element with a bad escape is a manifest error" '["a\n"]' 'unsupported escape'
kpbad "a preamble element unterminated is a manifest error" '["a' 'unterminated string'
kpbad "a preamble given an integer is a manifest error" '3' 'value must be an array'
printf '[kickoff]\nother = "x"\n' | cat "$KM" - >"$TMP/kpb.toml"
expect "an unknown [kickoff] key is a manifest error" 2 "unknown key 'other' in \[kickoff\]" -- -C "$K" --manifest "$TMP/kpb.toml" kickoff 1.0.2
printf '[gate]\ncommand = ["a"]\n' >"$TMP/kpg.toml"
expect "an array for a key that is not an array key is a manifest error" 2 'is not an array' -- -C "$K" --manifest "$TMP/kpg.toml" status

# ---- git call count: one process reads every spec file (v0.86) -------------
# A repository with 100 spec files; a counting `git` shim in front of PATH
# logs each call. status and kickoff must stay within a cap that does
# not grow with the number of files (before: about two calls per file).
GC=$TMP/gcount
git init -q -b main "$GC"
git -C "$GC" config user.name t
git -C "$GC" config user.email t@example.invalid
mkdir -p "$GC/docs/backlog" "$TMP/gshim"
printf '# Backlog\n' >"$GC/docs/BACKLOG.md"
printf '# Rules\n' >"$GC/RULES.md"
for _n in $(seq 1 100); do
	printf '# era %s\n\n## v1.%s — Item %s — DONE\nbody %s.\n' "$_n" "$_n" "$_n" "$_n" >"$GC/docs/backlog/v1-$_n.md"
done
printf '\n## v1.101 — Open one — TODO\nlater.\n' >>"$GC/docs/backlog/v1-100.md"
git -C "$GC" add -A && git -C "$GC" commit -qm "admin: founded"
GCM=$TMP/gc.toml
printf '%s' "${GOOD_MANIFEST/'tag = "v{version}"   # comment after a string'/'tag = "v{version}"
admin_prefix = "admin:"
item_commit = "v{version}: {title}"'}" >"$GCM"
printf '[docs]\nrules = "RULES.md"\n' >>"$GCM"
printf '#!/bin/sh\necho x >>"%s"\nexec "%s" "$@"\n' "$TMP/gcalls" "$(command -v git)" >"$TMP/gshim/git"
chmod +x "$TMP/gshim/git"
gcount() {
	: >"$TMP/gcalls"
	PATH="$TMP/gshim:$PATH" "$PO" -C "$GC" --manifest "$GCM" "$@" >"$TMP/gout" 2>&1
	GCODE=$?
	GCALLS=$(wc -l <"$TMP/gcalls")
}
for _cmd in status "kickoff 1.100"; do
	# shellcheck disable=SC2086 # the words of one po command
	gcount $_cmd
	((GCODE == 0 && GCALLS <= 40)) && ok "$_cmd on 100 spec files makes at most 40 git calls ($GCALLS)" ||
		bad "$_cmd on 100 spec files: exit 0 and at most 40 git calls" "$GCALLS calls (exit $GCODE): $(head -3 "$TMP/gout")"
done
gcount kickoff 1.100
grep -q '^SPEC SECTION docs/backlog/v1-100.md:3-5 ' "$TMP/gout" && grep -q '^body 100\.$' "$TMP/gout" &&
	ok "kickoff on 100 spec files still finds its section in the right file" || bad "kickoff 100 files section" "$(cat "$TMP/gout")"
gcount status
((GCODE == 0)) && ok "status on 100 spec files exits 0" || bad "status 100 files" "$(cat "$TMP/gout")"

# ---- report ---------------------------------------------------------------
HR=$TMP/report
make_repo "$HR"
cp "$S/fake-test.sh" "$HR/fake-test.sh"
git -C "$HR" add fake-test.sh && git -C "$HR" commit -qm fake
git -C "$HR" worktree add -q "$HR/.wt/item-v1.0.3" -b item-v1.0.3
HW=$HR/.wt/item-v1.0.3
printf 'a\n' >"$HW/new.txt"
git -C "$HW" add new.txt && git -C "$HW" commit -qm "v1.0.3: Third"
stamp_manifest "${STD_LEGS[@]}"
rp() { "$PO" -C "$HW" --manifest "$TMP/s.toml" report "$@"; }
rp_refuses() { # <name> <stderr pattern> [report args]
	local name=$1 pattern=$2 so code
	shift 2
	so=$(rp "$@" 2>"$TMP/rp.err")
	code=$?
	[[ $code == 4 && -z $so ]] && grep -qE -- "$pattern" "$TMP/rp.err" &&
		ok "$name" || bad "$name (exit $code, stdout '$so')" "$(cat "$TMP/rp.err")"
}
rp_refuses "no stamp: exit 4, empty stdout" 'no stamp: run po stamp'
"$PO" -C "$HW" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
printf 'edit\n' >>"$HW/new.txt"
printf 'b\n' >"$HW/other.txt"
touch -d 2020-01-01 "$HW/new.txt" "$HW/other.txt"
rp_refuses "a dirty count that differs from the stamp's is stale" 'stamp is stale'
rm "$HW/other.txt"
git -C "$HW" checkout -q new.txt
"$PO" -C "$HW" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
rm "$HW/gate-1.txt"
printf 'edit\n' >>"$HW/new.txt"
printf 'b\n' >"$HW/other.txt"
touch -d 2020-01-01 "$HW/new.txt" "$HW/other.txt"
"$PO" -C "$HW" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
NEWEST=$(cd "$HW" && printf '%s\n' gate-*.txt | sort -V | tail -1)
before=$(git -C "$HW" status --porcelain --untracked-files=all; git -C "$HR" for-each-ref)
out=$(rp --note "first, with \`code\`" --note $'second\nline two' 2>"$TMP/rp.err")
code=$?
# shellcheck disable=SC2016 # backticks are markdown, not substitutions
want=$(
	printf 'v1.0.3 report — item-v1.0.3 at %s\n\n' "$(git -C "$HW" rev-parse --short HEAD)"
	printf 'Files changed:\n- M `new.txt`\n- ?? `other.txt`\n- A `new.txt` (committed)\n\n'
	printf 'Stamp (%s):\n```\n%s\n```\n\n' "$NEWEST" "$(cat "$HW/$NEWEST")"
	printf 'PROPOSED:\n1. first, with `code`\n2. second\nline two'
)
[[ $code == 0 && $out == "$want" ]] && ok "report: files, the stamp verbatim, numbered notes" ||
	bad "report block (exit $code)" "$out"$'\n--- want\n'"$want"
[[ $(git -C "$HW" status --porcelain --untracked-files=all; git -C "$HR" for-each-ref) == "$before" ]] &&
	ok "report changes nothing" || bad "report side effects"
out=$(rp 2>&1)
[[ $out != *PROPOSED* ]] && ok "no PROPOSED list without --note" || bad "empty PROPOSED" "$out"
touch "$HW/other.txt"
rp_refuses "a file touched after the stamp is stale" "other.txt is newer than $NEWEST.*stale"
touch -d 2020-01-01 "$HW/other.txt"
touch "$HW/new.txt"
rp_refuses "a modified tracked file touched after the stamp is stale" 'new.txt is newer'
touch -d 2020-01-01 "$HW/new.txt"
rm "$HW/other.txt"
rp_refuses "a file deleted after the stamp is stale" 'stamp is stale'
printf 'b\n' >"$HW/other.txt"
touch -d 2020-01-01 "$HW/other.txt"
git -C "$HW" add other.txt && git -C "$HW" commit -qm "more"
rp_refuses "a stamp that names another HEAD is stale" 'names another HEAD.*stale: run po stamp'
printf 'junk\n' >"$HW/gate-3.txt"
rp_refuses "the newest stamp file decides, and must be a stamp block" 'not a stamp block'
rm "$HW/gate-3.txt"
git -C "$HW" commit -q --amend -m "v1.0.3: Third" --allow-empty
expect "report outside an item branch is an error" 2 'not an item branch' -- -C "$HR" --manifest "$TMP/s.toml" report
expect "--note needs a text" 1 '--note needs a text' -- -C "$HW" --manifest "$TMP/s.toml" report --note
expect "--note rejects blank text" 1 'text is empty' -- -C "$HW" --manifest "$TMP/s.toml" report --note ' '
expect "report rejects unknown arguments" 1 "unknown argument '--commit'" -- -C "$HW" --manifest "$TMP/s.toml" report --commit
# A clean, uncommitted-nothing tree on a branch at main's tip: no files.
git -C "$HR" worktree add -q "$HR/.wt/item-v1.0.4" -b item-v1.0.4
"$PO" -C "$HR/.wt/item-v1.0.4" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
out=$("$PO" -C "$HR/.wt/item-v1.0.4" --manifest "$TMP/s.toml" report 2>&1)
grep -q '^Files changed: none$' <<<"$out" && grep -q '^v1.0.4 report — item-v1.0.4 at ' <<<"$out" &&
	ok "a clean branch at main's tip reports no files" || bad "report clean" "$out"

# ---- status: idle time (item I) ---------------------------------------------
ID=$TMP/idle
make_repo "$ID"
printf '## v1.0.5 — Fifth — DOING\n' >>"$ID/docs/backlog/v1.md"
git -C "$ID" commit -qam "v1.0.5 DOING"
IW=$ID/.wt/item-v1.0.3
git -C "$ID" worktree add -q "$IW" -b item-v1.0.3
echo x >"$IW/new.txt"
git -C "$IW" add new.txt
git -C "$IW" commit -qm "v1.0.3: Third"
ago() { printf '@%s' $(($(date +%s) - $1)); } # a touch -d / git date, <seconds> ago
# idle_set <commit s> <gate s> <file s>: the three sources, that many seconds old.
idle_set() {
	GIT_COMMITTER_DATE=$(ago "$1") git -C "$IW" commit -q --amend --allow-empty --no-edit --reset-author --date="$(ago "$1")"
	rm -f "$IW"/gate-*.txt "$IW/dirty.txt"
	if [[ $2 != none ]]; then
		printf 'HEAD x\n' >"$IW/gate-1.txt"
		touch -d "$(ago "$2")" "$IW/gate-1.txt"
	fi
	if [[ $3 != none ]]; then
		echo d >"$IW/dirty.txt"
		touch -d "$(ago "$3")" "$IW/dirty.txt"
	fi
}
idle_is() { # <name> <want>
	local out
	out=$("$PO" -C "$ID" status 2>&1)
	grep -qE "branch item-v1\.0\.3 .*  idle $2\$" <<<"$out" && ok "$1" || bad "$1 (want idle $2)" "$out"
}
H=3600 M=60
idle_set $((2 * H + 30)) none none
idle_is "idle is the branch tip's commit date when nothing else exists" '2h00m'
idle_set $((9 * H)) $((3 * H + 12 * M + 30)) $((5 * H))
idle_is "idle is the newest gate-N.txt when it is the newest source" '3h12m'
idle_set $((9 * H)) $((8 * H)) $((4 * H + 5 * M + 30))
idle_is "idle is an untracked file's mtime when it is the newest source" '4h05m'
idle_set $((6 * H)) $((7 * H)) $((8 * H))
idle_is "idle is the commit date when the files and stamps are older" '6h00m'
idle_set $((9 * H)) none none
echo more >>"$IW/new.txt"
touch -d "$(ago $((M + 30)))" "$IW/new.txt"
idle_is "a modified tracked file counts, and under an hour reads 0h01m" '0h01m'
git -C "$IW" checkout -q -- new.txt
idle_set $((9 * H)) $((8 * H)) $((7 * H))
out=$("$PO" -C "$ID" status 2>&1)
[[ $(grep -c '^          branch .*  idle ' <<<"$out") == 2 ]] &&
	grep -qE 'branch item-v1\.0\.5  \(none\)  idle -$' <<<"$out" &&
	! grep -qE 'idle .*item-v1\.0\.4' <<<"$out" &&
	ok "an item with no worktree shows 'idle -'; a held item shows none" || bad "idle -" "$out"
[[ $out != *IDLE* ]] && ok "no IDLE section without --idle" || bad "IDLE without flag" "$out"

idle_set $((3 * H + 12 * M + 30)) none none # 192 minutes
expect "--idle over the limit exits 8" 8 'IDLE \(1\)' -- -C "$ID" status --idle 100
expect "--idle lists the idle item" 8 '^  v1\.0\.3 +idle 3h12m' -- -C "$ID" status --idle 100
expect "--idle at or under the limit exits 0" 0 'IDLE \(0\)' -- -C "$ID" status --idle 193
expect "--idle 0 counts any item idle at all" 8 'IDLE \(1\)' -- -C "$ID" status --idle 0
out=$("$PO" -C "$ID" status --idle 100 2>&1)
[[ $out == *'DIRTY WORKTREES'* && $out == *'WORKTREES  '* ]] &&
	ok "--idle prints everything as usual before exiting 8" || bad "--idle output" "$out"
expect "--idle needs a number" 1 '--idle needs a whole number' -- -C "$ID" status --idle
expect "--idle rejects text" 1 '--idle needs a whole number' -- -C "$ID" status --idle soon
expect "status still takes no other arguments" 1 "unknown argument '--bogus'" -- -C "$ID" status --bogus
# v0.130: status --json, idle_hours per DOING item (whole hours, null with no worktree, held items left out)
idle_set $((M * 30)) none none
expect "status --json: idle 30 min is 0 hours, no worktree is null, a held item is left out" 0 '^\[\{"item":"1\.0\.3","idle_hours":0,"needs_rebase":false\},\{"item":"1\.0\.5","idle_hours":null,"needs_rebase":false\}\]$' -- -C "$ID" status --json
idle_set $((5 * H)) none none
expect "status --json: idle 5 h is 5" 0 '"item":"1\.0\.3","idle_hours":5,"needs_rebase":false\}' -- -C "$ID" status --json
idle_set $((72 * H + 20 * M)) none none
expect "status --json: idle 72 h is 72" 0 '"item":"1\.0\.3","idle_hours":72,"needs_rebase":false\}' -- -C "$ID" status --json
isnap() { git -C "$ID" for-each-ref; git -C "$ID" worktree list --porcelain; git -C "$ID" status --porcelain --ignored; git -C "$IW" status --porcelain --ignored; }
before=$(isnap; stat -c '%n %Y' "$IW"/*)
"$PO" -C "$ID" status --idle 1 >/dev/null 2>&1
after=$(isnap; stat -c '%n %Y' "$IW"/*)
[[ $before == "$after" ]] && ok "status --idle is read-only" || bad "idle wrote" "$after"
# A backlog conflict still wins: exit 3, not 8.
printf '| v1.0.3 | Third | DONE | backlog/v1.md |\n' >>"$ID/docs/BACKLOG.md"
git -C "$ID" commit -qam conflict
expect "a backlog conflict (3) outranks idle (8)" 3 'CONFLICTS' -- -C "$ID" status --idle 100

# ---- status: one git probe per worktree (v0.88) -----------------------------
# A git wrapper on PATH logs every `git -C <dir> ... status` call; the open
# item's worktree is dirty (dirty.txt) and shows dirty, idle and the dirty
# section, yet is read once.
idle_set $((2 * H)) none $((H))
GW=$TMP/gitwrap
mkdir -p "$GW"
REAL_GIT=$(command -v git)
# shellcheck disable=SC2016 # the wrapper script expands its own $* and $2
printf '#!/bin/sh\ncase " $* " in *" status "*) echo "$2" >>"$GIT_STATUS_LOG" ;; esac\nexec "%s" "$@"\n' "$REAL_GIT" >"$GW/git"
chmod +x "$GW/git"
export GIT_STATUS_LOG=$TMP/status-calls.log
: >"$GIT_STATUS_LOG"
out=$(PATH=$GW:$PATH "$PO" -C "$ID" status --idle 100000 2>&1)
[[ $(grep -cx "$IW" "$GIT_STATUS_LOG") == 1 ]] &&
	ok "status probes an item's worktree with one git status" ||
	bad "status git status calls on the item worktree" "$(sort "$GIT_STATUS_LOG" | uniq -c)"
[[ $(sort "$GIT_STATUS_LOG" | uniq -d | wc -l) == 0 ]] &&
	ok "status probes no worktree twice" || bad "status probed a worktree twice" "$(sort "$GIT_STATUS_LOG" | uniq -c)"
grep -qE "worktree .*item-v1\.0\.3  dirty 1\$" <<<"$out" && grep -qE "idle 1h00m\$" <<<"$out" &&
	ok "status output with one probe shows the same dirty count and idle" || bad "status probe output" "$out"
unset GIT_STATUS_LOG

# ---- owners from the backlog (item J) -------------------------------------
OM=$TMP/o.toml
{
	cat "$BM"
	printf 'owner_column = "Owner"\n[docs]\nrules = "RULES.md"\n'
} >"$OM"
OTABLE='| Item | Title | Status | Owner |
|---|---|---|---|
| v1.0.1 | First | DONE | Ann |
| v1.0.3 | Third | DOING | Ann |
| v1.0.4 | Fourth study | DOING | Bob |
| v1.0.5 | Parser | TODO | Cy |'
O=$TMP/o1
BREPO_TABLE=$OTABLE make_brepo "$O"
echo rules >"$O/RULES.md"
git -C "$O" add RULES.md
git -C "$O" commit -qm "rules"
# v1.0.4 is held, v1.0.6 is TODO with an empty owner cell.
sed -i 's/^| v1.0.4 | Fourth study | DOING | Bob |$/| v1.0.4 | Fourth study | PAUSED | Bob |/; $a | v1.0.6 | Sixth | TODO |  |' "$O/docs/BACKLOG.md"
sed -i 's/^## v1.0.4 — Fourth study — DOING$/## v1.0.4 — Fourth study — PAUSED/; $a \\n## v1.0.6 — Sixth — TODO' "$O/docs/backlog/v1.md"
sed -i 's/\*\*v1.0.4 DOING (study); spec\*\*/**v1.0.4 PAUSED (study); spec**/' "$O/docs/BACKLOG.md"
git -C "$O" commit -qam "pause v1.0.4, add v1.0.6"
git -C "$O" branch -f item-v1.0.3 item-v1.0.3 >/dev/null 2>&1
git -C "$O/.wt/item-v1.0.3" rebase -q main >/dev/null 2>&1
"$PO" -C "$O/.wt/item-v1.0.3" --manifest "$BM" stamp >/dev/null 2>&1
obefore=$(bsnap "$O")

expect "no owner_column: open names no owner, whatever the table holds" 0 '  \| admin: v1\.0\.5 DOING$' -- -C "$O" --manifest "$BM" open 1.0.5
expect "no owner_column: close --next names no owner" 0 '  \| admin: v1\.0\.3 DONE \(tag v1\.0\.3\); v1\.0\.5 DOING$' -- -C "$O" --manifest "$BM" close 1.0.3 --next 1.0.5
expect "no owner_column: a --for the table disagrees with is taken as typed" 0 '  \| admin: v1\.0\.5 DOING for Ann$' -- -C "$O" --manifest "$BM" open 1.0.5 --for Ann
out=$("$PO" -C "$O" --manifest "$BM" status 2>&1)
! grep -q 'owner' <<<"$out" && ok "no owner_column: status prints no owner" || bad "status owner without the key" "$out"

expect "open takes the owner from the column" 0 '  \| admin: v1\.0\.5 DOING for Cy$' -- -C "$O" --manifest "$OM" open 1.0.5
expect "open --for that agrees with the column is accepted" 0 '  \| admin: v1\.0\.5 DOING for Cy$' -- -C "$O" --manifest "$OM" open 1.0.5 --for Cy
expect "open --for that disagrees with the column exits 3" 3 'owner.*Cy.*Ann|Ann.*Cy' -- -C "$O" --manifest "$OM" open 1.0.5 --for Ann
expect "open --commit with a disagreeing --for exits 3" 3 'owner' -- -C "$O" --manifest "$OM" open 1.0.5 --for Ann --commit
[[ $(bsnap "$O") == "$obefore" ]] && ok "a disagreeing --for writes nothing" || bad "owner refusal wrote something"
expect "an empty owner cell opens with no owner" 0 '  \| admin: v1\.0\.6 DOING$' -- -C "$O" --manifest "$OM" open 1.0.6
expect "an empty owner cell still takes --for" 0 '  \| admin: v1\.0\.6 DOING for Zed$' -- -C "$O" --manifest "$OM" open 1.0.6 --for Zed
expect "close --next takes the owner from the column" 0 '  \| admin: v1\.0\.3 DONE \(tag v1\.0\.3\); v1\.0\.5 DOING for Cy$' -- -C "$O" --manifest "$OM" close 1.0.3 --next 1.0.5
expect "close --next with an empty owner cell names no owner" 0 '  \| admin: v1\.0\.3 DONE \(tag v1\.0\.3\); v1\.0\.6 DOING$' -- -C "$O" --manifest "$OM" close 1.0.3 --next 1.0.6
expect "close --next --for that disagrees with the column exits 3" 3 'owner' -- -C "$O" --manifest "$OM" close 1.0.3 --next 1.0.5 --for Ann
expect "close --next --for that agrees is accepted" 0 '; v1\.0\.5 DOING for Cy$' -- -C "$O" --manifest "$OM" close 1.0.3 --next 1.0.5 --for Cy
expect "close without --next is unchanged by the column" 0 '  \| admin: v1\.0\.3 DONE \(tag v1\.0\.3\)$' -- -C "$O" --manifest "$OM" close 1.0.3
expect "status prints the owner of a DOING item" 0 '^ +owner +Ann$' -- -C "$O" --manifest "$OM" status
out=$("$PO" -C "$O" --manifest "$OM" status 2>&1)
sed -n '/^HELD/,/^ORPHANED/p' <<<"$out" | grep -qE '^ +owner +Bob$' &&
	ok "status prints the owner of a HELD item" || bad "held owner" "$out"
expect "kickoff prints an owner line" 0 '^owner +Ann$' -- -C "$O" --manifest "$OM" kickoff 1.0.3
out=$("$PO" -C "$O" --manifest "$OM" kickoff 1.0.5 2>&1)
grep -qE '^owner +Cy$' <<<"$out" && ok "kickoff prints the owner of a TODO item" || bad "kickoff TODO owner" "$out"
out=$("$PO" -C "$O" --manifest "$BM" kickoff 1.0.3 2>&1)
! grep -q '^owner' <<<"$out" && ok "kickoff without owner_column prints no owner line" || bad "kickoff owner without the key" "$out"
sed 's/^owner_column = "Owner"$/owner_column = ""/' "$OM" >"$TMP/o-empty.toml"
expect "an empty owner_column is a manifest error" 2 'owner_column' -- -C "$O" --manifest "$TMP/o-empty.toml" status

# ---- gate events (item L) ---------------------------------------------------
# The stamp fixture $S has logged every stamp above, passing and failing; $B has
# logged its closes and opens. The log is po-events.jsonl in the common git dir.
SLOG=$S/.git/po-events.jsonl
BLOG=$B/.git/po-events.jsonl
json_ok() { python3 -I -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1])]' "$1" 2>/dev/null; }
jfield() { python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
[[ -s $SLOG ]] && json_ok "$SLOG" && [[ $(wc -l <"$SLOG") == $(grep -c '^{' "$SLOG") ]] &&
	ok "events: the log is in the common git dir, one JSON object per line" || bad "events log shape" "$(cat "$SLOG" 2>&1)"
[[ ! -e $W/po-events.jsonl ]] && ! git -C "$W" status --porcelain | grep -q events &&
	ok "events: the log is not in the worktree, so it is not dirt" || bad "events in worktree"
first=$(grep -m1 '"result":"pass"' "$SLOG")
[[ $(jfield "$first" kind) == stamp && $(jfield "$first" item) == 1.0.3 && $(jfield "$first" project) == stamp &&
	$(jfield "$first" detail) == '' ]] &&
	python3 -I -c 'import json,sys,re; e=json.loads(sys.argv[1]); assert list(e)==["time","kind","item","project","result","agent","legs","seconds","tests","load1","detail"]; assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", e["time"]); assert [(l["name"],l["result"]) for l in e["legs"]]==[(n,"pass") for n in ("check","test","clippy","fmt")] and all(list(l)==["name","result","seconds"] for l in e["legs"])' "$first" &&
	ok "events: a passing stamp logs time (UTC), kind, item, project, result, every leg, the seconds taken, the test count and the load" || bad "pass event" "$first"
fail1=$(grep -m1 '"clippy","result":"fail"' "$SLOG")
[[ -n $fail1 && $(jfield "$fail1" result) == fail && $(jfield "$fail1" detail) == *"gate leg 'clippy'"* ]] &&
	python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert [l["result"] for l in e["legs"]]==["pass","pass","fail","skip"], e["legs"]' "$fail1" &&
	ok "events: a failing stamp logs fail, the reason, the failing leg and skips the legs not reached" || bad "fail event" "$fail1"
[[ $(grep -c '"kind":"stamp"' "$SLOG") == $(grep -c . "$SLOG") ]] &&
	ok "events: every stamp run is logged (passes and fails alike)" || bad "stamp count"
grep -q '"agent":"[^"]' "$SLOG" && [[ $(BUZZ_AGENT=zed "$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1; tail -1 "$SLOG" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["agent"])') == zed ]] &&
	ok "events: the agent is BUZZ_AGENT" || bad "agent from BUZZ_AGENT"
[[ $(env -u BUZZ_AGENT USER=quux "$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1; tail -1 "$SLOG" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["agent"])') == quux ]] &&
	ok "events: without BUZZ_AGENT the agent is the user" || bad "agent from USER"
git -C "$S" checkout -q -b scratch 2>/dev/null
git -C "$S" worktree add -q "$S/.wt/other" -b other
"$PO" -C "$S/.wt/other" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
[[ $(tail -1 "$SLOG" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["item"])') == None ]] &&
	grep -q '"item":null' "$SLOG" && ok "events: a branch that is not an item branch logs item null" || bad "item null"
git -C "$S" worktree remove --force "$S/.wt/other"
git -C "$S" checkout -q main
git -C "$S" branch -q -D scratch other

n_close=$(grep -c '"kind":"close"' "$CLOG")
n_open=$(grep -c '"kind":"open"' "$BLOG")
last_close=$(grep '"kind":"close"' "$CLOG" | tail -1)
[[ $n_close -ge 1 && $n_open -ge 1 && $(jfield "$last_close" result) == pass && $(jfield "$last_close" item) == 1.0.3 &&
	$(jfield "$last_close" legs) == '[]' ]] &&
	json_ok "$BLOG" && json_ok "$CLOG" && ok "events: open --commit and close --commit each log one event" || bad "open/close events" "$(cat "$BLOG")"
n_before=$(grep -c . "$BLOG")
"$PO" -C "$B" --manifest "$BM" open next "Dry" >/dev/null 2>&1
"$PO" -C "$B" --manifest "$BM" close 1.0.5 >/dev/null 2>&1
[[ $(grep -c . "$BLOG") == "$n_before" ]] && ok "events: a dry run of open or close logs nothing" || bad "dry run logged"

# po events: the table, --all, --json.
sha=$(sha256sum "$SLOG")
out=$(TZ=Pacific/Auckland "$PO" -C "$S" --manifest "$TMP/s.toml" events 2>&1)
code=$?
# The table ends at the first blank line; failed stamps' tails follow it.
# It reads all its input, so the writer never sees a closed pipe.
table() { awk 'done { next } /^$/ { done = 1; next } { print }'; }
out=$(table <<<"$out")
rows=$(($(wc -l <<<"$out") - 1))
[[ $code == 0 && $rows == 10 ]] && head -1 <<<"$out" | grep -qE '^TIME +KIND +ITEM +PROJECT +RESULT +AGENT +TOOK +LEGS$' &&
	ok "events: by default the table shows the last 10 events under a header" || bad "events table (exit $code, rows $rows)" "$out"
[[ $(wc -l <"$SLOG") -gt 10 ]] && out_all=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --all 2>&1 | table) &&
	[[ $(($(wc -l <<<"$out_all") - 1)) == "$(wc -l <"$SLOG")" ]] &&
	ok "events: --all lists every event" || bad "events --all" "$out_all"
grep -qE ' (NZDT|NZST) ' <<<"$out" && ! grep -q 'T[0-9:]*Z' <<<"$out" &&
	ok "events: the table shows the viewer's local time" || bad "events local time" "$out"
# Newest first: the last line of the log is the table's first row.
tail_time=$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[-1])["time"])' "$SLOG")
[[ $(TZ=UTC "$PO" -C "$S" --manifest "$TMP/s.toml" events | sed -n 2p | cut -c1-19) == "$(sed "s/T/ /;s/Z//" <<<"$tail_time")" ]] &&
	ok "events: newest first" || bad "events order"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --json 2>&1)
[[ $(wc -l <<<"$out") == 10 ]] && python3 -I -c 'import json,sys; L=[json.loads(l) for l in sys.stdin]; assert [e["time"] for e in L]==sorted((e["time"] for e in L), reverse=True) and all(e["time"].endswith("Z") for e in L)' <<<"$out" &&
	ok "events: --json is the last 10 as JSON lines, UTC, newest first" || bad "events --json" "$out"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --all --json 2>&1)
[[ $(wc -l <<<"$out") == "$(wc -l <"$SLOG")" ]] && python3 -I -c 'import json,sys; [json.loads(l) for l in sys.stdin]' <<<"$out" &&
	ok "events: --all and --json combine" || bad "events --all --json"
[[ $(sha256sum "$SLOG") == "$sha" ]] && ok "events: reading the log changes nothing" || bad "events wrote"
expect "events rejects an unknown argument" 1 "events: unknown argument '--bogus'" -- -C "$S" --manifest "$TMP/s.toml" events --bogus
E=$TMP/empty-events
make_repo "$E"
expect "events with no log says so and exits 0" 0 'none yet' -- -C "$E" --manifest "$TMP/s.toml" events
out=$("$PO" -C "$E" --manifest "$TMP/s.toml" events --json 2>&1)
[[ -z $out ]] && ok "events --json with no log prints nothing" || bad "events --json empty" "$out"
printf 'garbage\n{"torn' >>"$SLOG"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --all --json 2>&1)
json_ok <(printf '%s\n' "$out") && ok "events: lines that are not events are skipped" || bad "events garbage" "$out"
sed -i '/^garbage$/d;/^{"torn$/d' "$SLOG"

# A log that cannot be written warns; the stamp's exit code and evidence stand.
rm -f "$W"/gate-*.txt
want_block=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
rm -f "$W"/gate-*.txt
mv "$SLOG" "$SLOG.keep"
mkdir "$SLOG"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>"$TMP/ev.err")
code=$?
[[ $code == 0 && $out == "$want_block" && -f $W/gate-1.txt ]] && grep -q 'warning: could not write the stamp event' "$TMP/ev.err" &&
	ok "events: an unwritable log warns; the stamp still passes with the same block" || bad "unwritable log (exit $code)" "$(cat "$TMP/ev.err")"
stamp_manifest check=false
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>"$TMP/ev.err"
code=$?
[[ $code == 4 ]] && grep -q 'warning: could not write' "$TMP/ev.err" ||
	bad "unwritable log on a failing stamp (exit $code)" "$(cat "$TMP/ev.err")"
rmdir "$SLOG"
mv "$SLOG.keep" "$SLOG"
stamp_manifest "${STD_LEGS[@]}"
rm -f "$W"/gate-*.txt

# ---- events: archive by age (item v0.77) -----------------------------------
# Events older than [events] live_days (default 10) move to po-events-archive.jsonl
# beside the log. PO_EVENTS_NOW (epoch seconds) stands in for the clock.
AR=$TMP/archive
make_repo "$AR"
ALOG=$AR/.git/po-events.jsonl
AARC=$AR/.git/po-events-archive.jsonl
NOW=1800000000
ar_ev() { # <age in seconds> <detail>
	printf '{"time":"%s","kind":"open","item":"9","project":"demo","result":"pass","agent":"a","legs":[],"detail":"%s"}\n' \
		"$(date -u -d "@$((NOW - $1))" +%Y-%m-%dT%H:%M:%SZ)" "$2"
}
ar_run() { PO_EVENTS_NOW=$NOW "$PO" -C "$AR" --manifest "${AR_MANIFEST:-$TMP/s.toml}" events "$@"; }
{ ar_ev 864001 older; ar_ev 864000 exactly; ar_ev 100 young; printf '{"time":"not a time","kind":"x"}\n{"torn'; } >"$ALOG"
out=$(ar_run --archive-now 2>&1)
[[ $out == *'archived 1 events'* && $(grep -c . "$AARC") == 1 && "$(cat "$AARC")" == *'"detail":"older"'* ]] &&
	ok "archive: an event 10 days and 1 s old moves to the archive file" || bad "archive older" "$out"
[[ $(grep -c '"detail":"exactly"' "$ALOG") == 1 && $(grep -c '"detail":"young"' "$ALOG") == 1 && $(grep -c '"detail":"older"' "$ALOG") == 0 ]] &&
	ok "archive: an event at exactly 10 days stays live, so does a younger one" || bad "archive boundary" "$(cat "$ALOG")"
grep -q 'not a time' "$ALOG" && grep -q '^{"torn' "$ALOG" && ! grep -q 'not a time' "$AARC" &&
	ok "archive: an event with a bad time and a torn line stay live" || bad "archive bad time" "$(cat "$ALOG")"
out=$(ar_run --json 2>&1)
[[ $out != *older* && $out == *young* ]] && ok "archive: po events --json shows live events only" || bad "events --json live" "$out"
out=$(ar_run --archived --json 2>&1)
[[ $out == *older* && $out != *young* && $(wc -l <<<"$out") == 1 ]] && ok "archive: --archived --json shows the archive" || bad "archived json" "$out"
out=$(ar_run --archived 2>&1)
[[ $out == TIME* && $out == *open* ]] && ok "archive: --archived prints the table" || bad "archived table" "$out"
# v0.153: 60 archived events (more than the default cut of 10): --all returns every one, newest first
{ for i in $(seq 1 60); do ar_ev $((900000 + i * 10)) "bulk$i"; done; } >"$AARC.bulk"
cp "$AARC" "$AARC.keep"
cat "$AARC.bulk" >>"$AARC"
out=$(ar_run --archived --all --json 2>&1)
[[ $(grep -c . <<<"$out") == 61 && $(head -1 <<<"$out") == *bulk60* && $(tail -1 <<<"$out") == *older* ]] &&
	ok "archive: --archived --all --json returns every archived event, newest first" || bad "archived all json" "$(wc -l <<<"$out")"
out=$(ar_run --archived --json 2>&1)
[[ $(grep -c . <<<"$out") == 10 ]] && ok "archive: --archived --json without --all keeps the newest 10" || bad "archived json cut" "$(wc -l <<<"$out")"
cp "$AARC.keep" "$AARC"
rm -f "$AARC.bulk" "$AARC.keep"
before=$(cat "$AARC")
out=$(ar_run --archive-now 2>&1)
[[ $out == *'archived 0 events'* && "$(cat "$AARC")" == "$before" ]] && ok "archive: a second --archive-now moves nothing" || bad "archive rerun" "$out"
# crash safety: the archive was written, the live rewrite never happened
ar_ev 900000 crashed >>"$ALOG"
ar_ev 900000 crashed >>"$AARC"
ar_run --archive-now >/dev/null 2>&1
[[ $(grep -c '"detail":"crashed"' "$AARC") == 1 && $(grep -c '"detail":"crashed"' "$ALOG") == 0 ]] &&
	ok "archive: archive written, live rewrite interrupted, the rerun makes no duplicate" || bad "archive crash" "$(cat "$AARC")"
# a failed archive write leaves the live log whole
ar_ev 950000 keepme >>"$ALOG"
cp "$ALOG" "$TMP/alog.before"
mv "$AARC" "$AARC.bak"; mkdir "$AARC"
out=$(ar_run --archive-now 2>&1); rc=$?
rmdir "$AARC"; mv "$AARC.bak" "$AARC"
[[ $rc != 0 && -n $out ]] && cmp -s "$ALOG" "$TMP/alog.before" && ok "archive: when the archive cannot be written it exits non-zero with a message and the live log is untouched" || bad "archive write failure" "rc=$rc out=$out $(diff "$ALOG" "$TMP/alog.before")"
ar_run --archive-now >/dev/null 2>&1
# live_days override
printf '%s\n[events]\nlive_days = 1\n' "$(cat "$TMP/s.toml")" >"$TMP/live1.toml"
AR_MANIFEST=$TMP/live1.toml ar_run --archive-now >/dev/null 2>&1
ar_ev 86401 oneday >>"$ALOG"
AR_MANIFEST=$TMP/live1.toml ar_run --archive-now >/dev/null 2>&1
[[ $(grep -c '"detail":"young"' "$ALOG") == 1 && $(grep -c '"detail":"oneday"' "$AARC") == 1 && $(grep -c '"detail":"exactly"' "$ALOG") == 0 ]] &&
	ok "archive: [events] live_days = 1 moves what is over a day old" || bad "live_days override" "$(cat "$ALOG")"
printf '%s\n[events]\nlive_days = "ten"\n' "$(cat "$TMP/s.toml")" >"$TMP/live-bad.toml"
expect "manifest: a non-integer [events] live_days is refused" 2 'live_days must be an integer' -- -C "$AR" --manifest "$TMP/live-bad.toml" events
expect "events: --archive-now takes no other option" 1 'archive-now takes no other option' -- -C "$AR" --manifest "$TMP/s.toml" events --archive-now --json
EAR=$TMP/archive-none
make_repo "$EAR"
expect "events --archived with no archive says so and exits 0" 0 'none archived' -- -C "$EAR" --manifest "$TMP/s.toml" events --archived
# append time: a stamp ages out an old event
SC=$TMP/archive-stamp
git clone -q "$S" "$SC" 2>/dev/null
git -C "$SC" config user.name t
git -C "$SC" config user.email t@example.invalid
ar_ev 99999999 ancient >"$SC/.git/po-events.jsonl"
"$PO" -C "$SC" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
[[ $(grep -c '"detail":"ancient"' "$SC/.git/po-events-archive.jsonl" 2>/dev/null) == 1 && $(grep -c '"detail":"ancient"' "$SC/.git/po-events.jsonl") == 0 &&
	$(grep -c '"kind":"stamp"' "$SC/.git/po-events.jsonl") -ge 1 ]] &&
	ok "archive: a po stamp moves the old events at append time" || bad "archive at stamp" "$(cat "$SC/.git/po-events.jsonl" | cut -c1-120)"

# ---- failed gates keep their evidence (item Z) ------------------------------
# A failed stamp's event carries the failing leg's last 40 lines, redacted, and
# names a log file of the whole run under po-logs/ in the common git dir.
FL=$S/.git/po-logs
FT=$TMP/ztmp
mkdir -p "$FT"
cat >"$TMP/z-first.sh" <<'SH'
echo "first leg says hello"
SH
cat >"$TMP/z-noisy.sh" <<'SH'
i=1
while [ "$i" -le 50 ]; do echo "noisy line $i"; i=$((i + 1)); done
echo "token=hunter2hunter2 and password: swordfish"
echo "Authorization: Bearer abcdefghijklmnop0123"
echo "curl -H 'X-Note: bearer zyxwvutsrqponm9876'"
echo "clone https://alice:s3cr3tpw@example.invalid/repo.git"
echo "found ghp_abcdefghijklmnopqrstuvwxyz0123456789 in config"
echo "env value $Z_API_TOKEN leaked"
echo "-----BEGIN OPENSSH PRIVATE KEY-----"
echo "b3BlbnNzaC1rZXktdjEAAAAABG5vbmU"
echo "-----END OPENSSH PRIVATE KEY-----"
printf '\033[31mred text\033[0m plain\n'
exit 3
SH
stamp_manifest "first=sh $TMP/z-first.sh" "noisy=sh $TMP/z-noisy.sh" last=true
rm -f "$W"/gate-*.txt
dirt_before=$(git -C "$W" status --porcelain --untracked-files=all)
n_logs=$(find "$FL" -name '*.log' 2>/dev/null | grep -c . || true)
TMPDIR=$FT Z_API_TOKEN=zz-env-secret-value-42 "$PO" -C "$W" --manifest "$TMP/s.toml" stamp >"$TMP/z.out" 2>"$TMP/z.err"
code=$?
zev=$(tail -1 "$SLOG")
ztail=$(python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); print(e["legs"][1].get("tail", "<none>"))' "$zev")
zlog=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1]).get("log") or "")' "$zev")
[[ $code == 4 && ! -s $TMP/z.out ]] && json_ok <(printf '%s\n' "$zev") &&
	python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert [l["result"] for l in e["legs"]]==["pass","fail","skip"]; assert "tail" in e["legs"][1] and "tail" not in e["legs"][0] and "tail" not in e["legs"][2]; assert list(e)[-2:]==["detail","log"]' "$zev" &&
	ok "evidence: a failed stamp's event gives the failing leg, and only it, a tail, and names a log" || bad "evidence event (exit $code)" "$zev"
[[ $(wc -l <<<"$ztail") == 40 && $(head -1 <<<"$ztail") == 'noisy line 21' && $ztail != *'noisy line 20'$'\n'* ]] &&
	ok "evidence: the tail is the failing leg's last 40 lines, one per line" || bad "tail lines" "$ztail"
[[ $ztail == *'red text plain'* && $ztail != *$'\033'* ]] &&
	ok "evidence: the tail drops terminal colour codes" || bad "tail colours" "$ztail"
redacted() {
	[[ $1 != *hunter2hunter2* && $1 != *swordfish* && $1 != *abcdefghijklmnop0123* && $1 != *zyxwvutsrqponm9876* && $1 != *s3cr3tpw* &&
		$1 != *ghp_abcdef* && $1 != *zz-env-secret-value-42* && $1 != *b3BlbnNzaC1rZXktdjEAAAAABG5vbmU* ]] &&
		[[ $1 == *'token=[REDACTED]'* && $1 == *'password: [REDACTED]'* && $1 == *'Authorization: [REDACTED]'* && $1 == *'bearer [REDACTED]'* &&
			$1 == *'https://[REDACTED]@example.invalid/repo.git'* && $1 == *'found [REDACTED] in config'* &&
			$1 == *'env value [REDACTED] leaked'* && $1 == *'noisy line 50'* ]]
}
redacted "$ztail" && ok "evidence: the tail is redacted: key=value secrets, bearer tokens, URL passwords, known token shapes, secret env values, private keys" || bad "tail redaction" "$ztail"
[[ $zlog == "$FL"/stamp-*-1.0.3-*.log && -f $zlog ]] &&
	ok "evidence: the log is a file under po-logs/ in the common git dir, named for the item" || bad "log path" "$zlog"
zfull=$(cat "$zlog" 2>/dev/null)
[[ $zfull == *'first leg says hello'* && $zfull == *'noisy line 1'$'\n'* && $zfull == *"gate leg 'noisy'"* &&
	$zfull == *"== leg noisy: sh $TMP/z-noisy.sh (exit 3)"* ]] &&
	ok "evidence: the log holds the whole run: the reason and every leg's full output under its command and exit" || bad "log content" "$zfull"
redacted "$zfull" && ok "evidence: the log is redacted like the tail" || bad "log redaction" "$zfull"
grep -qF "the full output is in $zlog" "$TMP/z.err" &&
	ok "evidence: a failed stamp says on stderr where the full output is" || bad "stderr log" "$(cat "$TMP/z.err")"
[[ $(git -C "$W" status --porcelain --untracked-files=all) == "$dirt_before" && -z $(ls -A "$FT") ]] &&
	ok "evidence: the capture leaves the worktree untouched and no temporary files" || bad "capture dirt" "$(ls -A "$FT")"
[[ $(find "$FL" -name '*.log' | grep -c .) == $((n_logs + 1)) ]] && rm -f "$W"/gate-*.txt &&
	stamp_manifest "first=sh $TMP/z-first.sh" last=true && TMPDIR=$FT "$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1 &&
	[[ $(find "$FL" -name '*.log' | grep -c .) == $((n_logs + 1)) && -z $(ls -A "$FT") ]] &&
	! tail -1 "$SLOG" | grep -qE '"tail"|"log"' &&
	ok "evidence: a passing stamp writes no log and its event has no tail or log" || bad "pass log"
rm -f "$W"/gate-*.txt
# A long line is cut; a failure that is not a leg's (the count) has a log but no tail.
printf 'printf "%%0600d\\n" 0\nexit 1\n' >"$TMP/z-wide.sh"
stamp_manifest "wide=sh $TMP/z-wide.sh"
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
python3 -I -c 'import json,sys; t=json.loads(sys.argv[1])["legs"][0]["tail"]; assert len(t)==403 and t.endswith("..."), len(t)' "$(tail -1 "$SLOG")" &&
	ok "evidence: a tail line longer than 400 characters is cut and ends in ..." || bad "wide line" "$(tail -1 "$SLOG" | cut -c1-300)"
COUNT_CMD="echo counting; exit 2" stamp_manifest check=true
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
zc=$(tail -1 "$SLOG")
zclog=$(python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert all("tail" not in l for l in e["legs"]); print(e["log"])' "$zc")
[[ -f $zclog ]] && grep -q '^== test count: echo counting; exit 2 (exit 2)$' "$zclog" && grep -q '^counting$' "$zclog" &&
	ok "evidence: a failing test_count_cmd is in the log; no leg gets a tail" || bad "count failure" "$zc"
# po events shows the tail under the table; --json keeps it as one line.
stamp_manifest "first=sh $TMP/z-first.sh" "noisy=sh $TMP/z-noisy.sh" last=true
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
zlog=$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["log"])' "$(tail -1 "$SLOG")")
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events 2>&1)
grep -qF "1.0.3: leg noisy failed; its last lines (full output: $zlog):" <<<"$out" &&
	grep -qx '    noisy line 21' <<<"$out" && grep -qx '    token=\[REDACTED\] and password: \[REDACTED\]' <<<"$out" &&
	! grep -qx '    noisy line 20' <<<"$out" && [[ $(table <<<"$out" | head -2 | tail -1) =~ 'first:pass('[0-9]+'s) noisy:fail('[0-9]+'s) last:skip('[0-9]+'s)' ]] &&
	ok "events: the table is followed by each failed stamp's tail, indented, naming the leg and the log" || bad "events tail" "$out"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --json 2>&1)
[[ $(wc -l <<<"$out") == 10 ]] && python3 -I -c 'import json,sys; e=json.loads(sys.stdin.readline()); assert e["legs"][1]["tail"].count("\n")==39' <<<"$out" &&
	ok "events: --json keeps a tail's lines inside one event line" || bad "events json tail" "$(head -1 <<<"$out" | cut -c1-300)"
# The reason names the leg's command; a secret in it is redacted in the event.
stamp_manifest 'leak=echo password=hunter2secret; echo \"Authorization: Bearer abcdefgh12345678\"; exit 1'
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
zd=$(tail -1 "$SLOG")
zdd=$(jfield "$zd" detail)
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --json 2>&1)
[[ $zd != *hunter2secret* && $zd != *abcdefgh12345678* && $(head -1 <<<"$out") != *hunter2secret* &&
	$(head -1 <<<"$out") != *abcdefgh12345678* && $zdd == *"gate leg 'leak' (echo password=[REDACTED]"* && $zdd == *'exited 1'* ]] &&
	ok "evidence: a secret in the failing leg's command is redacted in the event's detail" || bad "detail redaction" "$zd"
stamp_manifest "${STD_LEGS[@]}"
rm -f "$W"/gate-*.txt

# ---- stamp: time taken (item v0.54) -----------------------------------------
# Each leg and the run record whole wall-clock seconds; readers treat a missing
# value as unknown, never 0.
# A still clock: a bare `date +%s` reads $TMP/tclock-now and never moves on
# its own; a leg that runs `sh $TMP/tclock-tick 2` moves it 2 s, so the leg
# takes exactly 2 s without sleeping.
mkdir -p "$TMP/tclock-bin"
cat >"$TMP/tclock-bin/date" <<EOF
#!/bin/sh
[ "\$*" = "+%s" ] && exec cat "$TMP/tclock-now"
exec $(command -v date) "\$@"
EOF
cat >"$TMP/tclock-tick" <<EOF
echo \$((\$(cat "$TMP/tclock-now") + \$1)) >"$TMP/tclock-now.new"
mv "$TMP/tclock-now.new" "$TMP/tclock-now"
EOF
chmod +x "$TMP/tclock-bin/date"
echo 1000000000 >"$TMP/tclock-now"
rm -f "$W"/gate-*.txt
stamp_manifest check=true "test=sh $TMP/tclock-tick 2; sh ./fake-test.sh"
PATH="$TMP/tclock-bin:$PATH" "$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
tk=$(tail -1 "$SLOG")
python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert e["result"]=="pass"; assert [l["seconds"] for l in e["legs"]]==[0,2] and e["seconds"]==2, e' "$tk" &&
	ok "time taken: a leg the clock sees take 2 s records 2 seconds on the leg and on the run" || bad "stamp seconds" "$tk"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events 2>&1)
[[ $(table <<<"$out" | sed -n 2p) =~ \ 2s\ +check:pass\(0s\)\ test:pass\(2s\)$ ]] &&
	ok "time taken: po events shows the run's time and each leg's seconds" || bad "events took" "$out"
rm -f "$W"/gate-*.txt
SLOW_AFTER=1 stamp_manifest check=true "test=sh $TMP/tclock-tick 2; sh ./fake-test.sh"
PATH="$TMP/tclock-bin:$PATH" "$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events 2>&1)
[[ $(table <<<"$out" | sed -n 2p) =~ \ 2s\ slow\ +check:pass ]] &&
	ok "time taken: slow_after = 1 marks the 2 s run with the word slow" || bad "events slow" "$out"
rm -f "$W"/gate-*.txt
stamp_manifest "${STD_LEGS[@]}"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events 2>&1)
[[ $(table <<<"$out" | sed -n 2p) != *slow* ]] &&
	ok "time taken: without slow_after a quick run is not marked (default 300)" || bad "events not slow" "$out"
rm -f "$W"/gate-*.txt
# Synthetic lines: an old event without the keys, one of 252 s, one over the default 300 s.
printf '%s\n' \
	'{"time":"2026-10-20T10:00:00Z","kind":"stamp","item":"1.0.1","project":"oldfmt","result":"pass","agent":"x","legs":[{"name":"lint","result":"pass"}],"detail":""}' \
	'{"time":"2026-10-20T10:01:00Z","kind":"stamp","item":"1.0.1","project":"mid","result":"pass","agent":"x","legs":[{"name":"lint","result":"pass","seconds":61}],"seconds":252,"detail":""}' \
	'{"time":"2026-10-20T10:02:00Z","kind":"stamp","item":"1.0.1","project":"long","result":"pass","agent":"x","legs":[{"name":"lint","result":"pass","seconds":0}],"seconds":301,"detail":""}' >>"$SLOG"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --all 2>&1 | table)
grep -qE 'oldfmt +pass +x +- +lint:pass$' <<<"$out" &&
	ok "time taken: an old-format event still prints and shows - for its time" || bad "old event" "$out"
grep -qE 'mid +pass +x +4m12s +lint:pass\(1m01s\)$' <<<"$out" && grep -qE 'long +pass +x +5m01s slow +lint:pass\(0s\)$' <<<"$out" &&
	ok "time taken: 252 s reads 4m12s, 301 s reads 5m01s slow" || bad "events format" "$out"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --all --json 2>&1)
grep -qF '"legs":[{"name":"lint","result":"pass"}],"detail":""' <<<"$out" && grep -qF '"seconds":252,"detail"' <<<"$out" &&
	ok "time taken: --json carries the raw keys and leaves an old event as it is" || bad "events json seconds"
sed -i '/"project":"\(oldfmt\|mid\|long\)"/d' "$SLOG"

# ---- stamp and close: a gate over the time budget (item v0.170) -----------
# [stamp] slow_after (default 300) is the project's gate time budget: a run
# over it adds `gate time: ..., over budget ... (slow_after)` to the block, and
# po close flags the item's newest passing stamp event when it was over.
# secs_fmt <n>: whole seconds as the block writes them (57s, 4m12s, 1h02m03s).
secs_fmt() {
	if (($1 >= 3600)); then printf '%dh%02dm%02ds' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
	elif (($1 >= 60)); then printf '%dm%02ds' $(($1 / 60)) $(($1 % 60))
	else printf '%ds' "$1"; fi
}
# A stubbed clock: each bare `date +%s` reads 301 s later than the one
# before, so any run that reads it twice is past the default 300 s budget.
mkdir -p "$TMP/clock-bin"
cat >"$TMP/clock-bin/date" <<EOF
#!/bin/sh
if [ "\$*" = "+%s" ]; then
	n=\$(cat "$TMP/clock-now" 2>/dev/null || $(command -v date) +%s)
	n=\$((n + 301))
	echo "\$n" >"$TMP/clock-now"
	echo "\$n"
else
	exec $(command -v date) "\$@"
fi
EOF
chmod +x "$TMP/clock-bin/date"
rm -f "$W"/gate-*.txt "$TMP/clock-now"
SLOW_AFTER=1 stamp_manifest check=true "test=sh ./fake-test.sh"
blk=$(PATH="$TMP/clock-bin:$PATH" "$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
sec=$(jfield "$(tail -1 "$SLOG")" seconds)
want="gate time: $(secs_fmt "$sec"), over budget 1s (slow_after)"
[[ $sec -ge 2 && $(sed -n 4p <<<"$blk") == "$want" && $(sed -n 4p "$W/gate-1.txt") == "$want" ]] &&
	ok "budget: slow_after = 1 and a 2 s leg add the exact 'gate time ... over budget 1s (slow_after)' line, its seconds the event's" ||
	bad "budget line (event seconds $sec)" "$blk"$'\n--- want line 4\n'"$want"
rm -f "$W"/gate-*.txt
stamp_manifest "${STD_LEGS[@]}"
blk=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
want=$(
	printf 'HEAD %s (item-v1.0.3)  dirty 0\n' "$(git -C "$W" rev-parse HEAD)"
	printf 'gate PASS: check/test/clippy/fmt   tests 5 passed\n'
	printf 'diffstat vs merge-base(main): %s\n' "$(git -C "$W" diff --shortstat "$(git -C "$W" merge-base main HEAD)" HEAD | sed 's/^ //')"
)
[[ $blk == "$want" ]] && ok "budget: a fast run under the default 300 s leaves the block as it was" ||
	bad "budget fast block" "$blk"$'\n--- want\n'"$want"
rm -f "$W"/gate-*.txt "$TMP/clock-now"
blk=$(PATH="$TMP/clock-bin:$PATH" "$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
sec=$(jfield "$(tail -1 "$SLOG")" seconds)
want="gate time: $(secs_fmt "$sec"), over budget 5m00s (slow_after)"
[[ $sec -gt 300 && $(sed -n 4p <<<"$blk") == "$want" ]] &&
	ok "budget: slow_after unset and a clock past 300 s add the line with the 5m00s default budget" ||
	bad "budget default line (event seconds $sec)" "$blk"$'\n--- want line 4\n'"$want"
rm -f "$W"/gate-*.txt "$TMP/clock-now"

# po close: the flag reads the item's newest passing stamp event.
B170=$TMP/b170
make_brepo "$B170"
W170=$B170/.wt/item-v1.0.3
L170=$B170/.git/po-events.jsonl
rm -f "$W170"/gate-*.txt
PATH="$TMP/clock-bin:$PATH" "$PO" -C "$W170" --manifest "$BM" stamp >/dev/null 2>&1
sec=$(jfield "$(tail -1 "$L170")" seconds)
want="flag: item v1.0.3 gate took $(secs_fmt "$sec"), over budget 5m00s"
out=$("$PO" -C "$B170" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 && $sec -gt 300 ]] && grep -qxF "$want" <<<"$out" && grep -q 'DRY RUN' <<<"$out" &&
	ok "budget: po close's dry run flags a stamp over the budget, exit 0" || bad "close flag (exit $code, seconds $sec)" "$out"$'\n--- want\n'"$want"
rm -f "$W170"/gate-*.txt "$TMP/clock-now"
"$PO" -C "$W170" --manifest "$BM" stamp >/dev/null 2>&1
out=$("$PO" -C "$B170" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 && $out != *'flag: item '* ]] && grep -q 'DRY RUN' <<<"$out" &&
	ok "budget: after a fast stamp (the newest) po close prints no flag" || bad "close no flag after fast (exit $code)" "$out"
cp "$L170" "$TMP/l170.keep"
printf '%s\n' \
	'{"time":"2026-11-10T10:00:00Z","kind":"stamp","item":"1.0.3","project":"b170","result":"fail","agent":"x","legs":[{"name":"check","result":"pass","seconds":900}],"seconds":900,"detail":"slow and failed","log":null}' \
	'{"time":"2026-11-10T10:01:00Z","kind":"stamp","item":"1.0.4","project":"b170","result":"pass","agent":"x","legs":[{"name":"check","result":"pass","seconds":900}],"seconds":900,"tests":1,"detail":""}' >"$L170"
out=$("$PO" -C "$B170" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 && $out != *'flag: item '* ]] &&
	ok "budget: an item with only a failed stamp over the budget (and another item's slow pass) gets no flag" || bad "close flag failed stamp (exit $code)" "$out"
printf '%s\n' \
	'{"time":"2026-10-20T10:00:00Z","kind":"stamp","item":"1.0.3","project":"b170","result":"pass","agent":"x","legs":[{"name":"check","result":"pass"}],"detail":""}' >"$L170"
out=$("$PO" -C "$B170" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 && $out != *'flag: item '* ]] &&
	ok "budget: an old passing event without seconds is unknown, never 0: no flag" || bad "close flag old event (exit $code)" "$out"
: >"$L170"
out=$("$PO" -C "$B170" --manifest "$BM" close 1.0.3 2>&1)
code=$?
[[ $code == 0 && $out != *'flag: item '* ]] && ok "budget: no stamp event at all: no flag" || bad "close flag no event (exit $code)" "$out"
cp "$TMP/l170.keep" "$L170"
{ cat "$BM"; printf '\n[stamp]\nslow_after = 1\n'; } >"$TMP/b170.toml"
rm -f "$W170"/gate-*.txt
"$PO" -C "$W170" --manifest "$TMP/b170.toml" stamp >/dev/null 2>&1
printf '%s\n' '{"time":"2026-11-10T10:02:00Z","kind":"stamp","item":"1.0.3","project":"b170","result":"pass","agent":"x","legs":[{"name":"check","result":"pass","seconds":2}],"seconds":2,"tests":1,"detail":""}' >>"$L170"
out=$("$PO" -C "$B170" --manifest "$TMP/b170.toml" close 1.0.3 --commit 2>&1)
code=$?
[[ $code == 0 ]] && grep -qxF 'flag: item v1.0.3 gate took 2s, over budget 1s' <<<"$out" && [[ -n $(git -C "$B170" tag -l v1.0.3) ]] &&
	ok "budget: po close --commit prints the flag against the project's slow_after and still closes" || bad "close --commit flag (exit $code)" "$out"

# ---- events: test count, load and the trend (item v0.168) ------------------
# A passing stamp's event carries "tests" (the gate block's number) and "load1"
# (/proc/loadavg's first field) after the run's seconds; a failed one has
# neither. `po events --trend` sums PASS stamps per local day.
rm -f "$W"/gate-*.txt
stamp_manifest "${STD_LEGS[@]}"
blk=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
tc=$(sed -n 's/^gate PASS: .*   tests \([0-9]*\) passed$/\1/p' <<<"$blk")
tl=$(tail -1 "$SLOG")
[[ -n $tc ]] && python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert e["result"]=="pass"; assert list(e)==["time","kind","item","project","result","agent","legs","seconds","tests","load1","detail"], list(e); assert e["tests"]==int(sys.argv[2]), (e["tests"], sys.argv[2]); assert isinstance(e["load1"], (int, float)) and e["load1"] >= 0, e["load1"]' "$tl" "$tc" &&
	ok "trend: a passing stamp's event carries tests equal to the gate block's number and a numeric load1, after seconds" || bad "stamp tests/load1" "$blk"$'\n'"$tl"
rm -f "$W"/gate-*.txt
stamp_manifest check=true "test=sh ./fake-test.sh" "clippy=exit 3" fmt=true
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
tl=$(tail -1 "$SLOG")
python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert e["result"]=="fail"; assert "tests" not in e and "load1" not in e, list(e)' "$tl" &&
	ok "trend: a failed stamp's event has neither tests nor load1" || bad "fail tests/load1" "$tl"
stamp_manifest "${STD_LEGS[@]}"
rm -f "$W"/gate-*.txt
printf '%s\n' \
	'{"time":"2026-10-20T10:00:00Z","kind":"stamp","item":"1.0.1","project":"oldkeys","result":"pass","agent":"x","legs":[{"name":"lint","result":"pass"}],"detail":""}' \
	'{"time":"2026-10-20T10:01:00Z","kind":"stamp","item":"1.0.1","project":"newkeys","result":"pass","agent":"x","legs":[{"name":"lint","result":"pass","seconds":61}],"seconds":252,"tests":9,"load1":1.5,"detail":""}' >>"$SLOG"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --all 2>&1 | table)
grep -qE 'oldkeys +pass +x +- +lint:pass$' <<<"$out" && grep -qE 'newkeys +pass +x +4m12s +lint:pass\(1m01s\)$' <<<"$out" &&
	ok "trend: plain po events lists an old event without the keys with -, and reads the time of one with them" || bad "events with tests/load1" "$out"
sed -i '/"project":"\(oldkeys\|newkeys\)"/d' "$SLOG"

# Fixture: three days with stamps in the window (two live, one archived), one
# day outside it, a failed stamp, an open and a close. TZ=UTC; the clock is
# 2026-11-10 12:00 UTC.
TR=$TMP/trend
make_repo "$TR"
TRLOG=$TR/.git/po-events.jsonl
TRARC=$TR/.git/po-events-archive.jsonl
TRNOW=$(date -u -d 2026-11-10T12:00:00Z +%s)
tr_ev() { # <time> <result> <test leg seconds|-> [<tests> <load1>]
	local leg='{"name":"lint","result":"pass","seconds":2}' extra=''
	[[ $3 == - ]] || leg+=',{"name":"test","result":"pass","seconds":'$3'}'
	[[ -z ${4:-} ]] || extra=',"tests":'$4',"load1":'$5
	printf '{"time":"%s","kind":"stamp","item":"1.0.1","project":"demo","result":"%s","agent":"a","legs":[%s],"seconds":99%s,"detail":""}\n' \
		"$1" "$2" "$leg" "$extra"
}
{
	tr_ev 2026-10-20T09:00:00Z pass 10 50 0.10
	tr_ev 2026-11-05T09:00:00Z pass 30 100 1.00
	tr_ev 2026-11-05T10:00:00Z pass 50 100 2.00
} >"$TRARC"
{
	tr_ev 2026-11-05T10:00:00Z pass 50 100 2.00 # also in the archive: counted once
	tr_ev 2026-11-09T08:00:00Z pass 40
	tr_ev 2026-11-09T09:00:00Z pass 44
	tr_ev 2026-11-10T01:00:00Z pass 50 120 2.00
	tr_ev 2026-11-10T02:00:00Z fail 999
	printf '{"time":"2026-11-10T02:30:00Z","kind":"open","item":"9","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}\n'
	tr_ev 2026-11-10T03:00:00Z pass 70 120 4.00
	printf '{"time":"2026-11-10T03:30:00Z","kind":"close","item":"9","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}\n'
	tr_ev 2026-11-10T04:00:00Z pass 60 118 3.00
} >"$TRLOG"
tr_run() { TZ=UTC PO_EVENTS_NOW=$TRNOW "$PO" -C "$TR" --manifest "$TMP/s.toml" events "$@"; }
want='DAY         STAMPS  TESTS  TEST-LEG  PER-TEST  LOAD
2026-11-10  3       120    1m00s     500 ms    3.00
2026-11-09  2       -      42s       -         -
2026-11-05  2       100    40s       400 ms    1.50
change since 2026-11-05: tests +20 (+20%), test leg +20 s (+50%), per test +100 ms'
sha=$(cat "$TRLOG" "$TRARC" | sha256sum)
out=$(tr_run --trend 2>&1)
code=$?
[[ $code == 0 && $out == "$want" ]] &&
	ok "trend: three days from the log and the archive -> the exact table, medians, ms per test and the change line" || bad "trend table (exit $code)" "$out"
[[ $(sed -n 3p <<<"$out") == '2026-11-09  2       -      42s       -         -' ]] &&
	ok "trend: a day whose stamps have no tests key shows - in TESTS and PER-TEST (no divide by zero)" || bad "trend no tests" "$out"
[[ $(sed -n 2p <<<"$out") == '2026-11-10  3       120    1m00s     500 ms    3.00' ]] &&
	ok "trend: open, close and failed stamp events are not counted" || bad "trend ignores" "$out"
[[ $(tr_run --trend --days 14 2>&1) == "$want" && $(cat "$TRLOG" "$TRARC" | sha256sum) == "$sha" ]] &&
	ok "trend: --days 14 is the default, and the trend changes no file" || bad "trend --days 14"
out=$(tr_run --trend --days 2 2>&1)
[[ $out == 'DAY         STAMPS  TESTS  TEST-LEG  PER-TEST  LOAD
2026-11-10  3       120    1m00s     500 ms    3.00
2026-11-09  2       -      42s       -         -
change: - (fewer than two days with a TESTS value)' ]] &&
	ok "trend: --days 2 shows today and yesterday only; one day with tests has no change to show" || bad "trend --days 2" "$out"
out=$(tr_run --trend --json 2>&1)
python3 -I -c '
import json, sys
got = json.loads(sys.argv[1])
want = [
    {"day": "2026-11-10", "stamps": 3, "tests": 120, "test_leg": 60, "per_test_ms": 500, "load1": 3.0},
    {"day": "2026-11-09", "stamps": 2, "tests": None, "test_leg": 42, "per_test_ms": None, "load1": None},
    {"day": "2026-11-05", "stamps": 2, "tests": 100, "test_leg": 40, "per_test_ms": 400, "load1": 1.5},
]
assert got == want, got
' "$out" && ok "trend: --json is an array of one object per day matching the table, null for -" || bad "trend --json" "$out"
TE=$TMP/trend-empty
make_repo "$TE"
printf '{"time":"2026-11-10T02:30:00Z","kind":"open","item":"9","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}\n' >"$TE/.git/po-events.jsonl"
out=$(TZ=UTC PO_EVENTS_NOW=$TRNOW "$PO" -C "$TE" --manifest "$TMP/s.toml" events --trend 2>&1)
code=$?
[[ $code == 0 && $out == 'no stamps in the last 14 days' ]] &&
	ok "trend: no PASS stamp in the window -> no stamps in the last 14 days, exit 0" || bad "trend empty (exit $code)" "$out"
out=$(TZ=UTC PO_EVENTS_NOW=$TRNOW "$PO" -C "$TE" --manifest "$TMP/s.toml" events --trend --json 2>&1)
[[ $out == '[]' ]] && ok "trend: --json with no stamps is an empty array" || bad "trend empty json" "$out"
expect "trend: --trend --archive-now is a usage error" 1 'trend combines only with --days and --json' -- -C "$TR" --manifest "$TMP/s.toml" events --trend --archive-now
expect "trend: --trend --all is a usage error" 1 'trend combines only with --days and --json' -- -C "$TR" --manifest "$TMP/s.toml" events --trend --all
expect "trend: --days without --trend is a usage error" 1 'days needs --trend' -- -C "$TR" --manifest "$TMP/s.toml" events --days 3
expect "trend: --days 0 is a usage error" 1 'days takes a whole number of days, 1 or more' -- -C "$TR" --manifest "$TMP/s.toml" events --trend --days 0

# ---- stamp: prepare lines (item AA) -----------------------------------------
# A formatter fixes the tree before the gate looks at it.
rm -f "$W"/gate-*.txt "$TMP/order"
printf '  messy\n' >"$W/messy.txt"
FMT_LEGS=(check=true "test=sh ./fake-test.sh" "fmt=! grep -q '^ ' messy.txt")
stamp_manifest "${FMT_LEGS[@]}"
expect "prepare: without it, a format-only failure fails the stamp" 4 "gate leg 'fmt'" -- -C "$W" --manifest "$TMP/s.toml" stamp
PREPARE="[\"sed -i 's/^ *//' messy.txt\", \"echo p2 >>$TMP/order; echo 'test result: ok. 9 passed; 0 failed;'\"]" \
	stamp_manifest "${FMT_LEGS[@]}" "order=echo leg >>$TMP/order"
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>"$TMP/p.err")
code=$?
want=$(
	printf 'HEAD %s (item-v1.0.3)  dirty 1\n' "$(git -C "$W" rev-parse HEAD)"
	printf 'gate PASS: check/test/fmt/order   tests 5 passed\n'
	printf 'diffstat vs merge-base(main): %s\n' "$(git -C "$W" diff --shortstat "$(git -C "$W" merge-base main HEAD)" HEAD | sed 's/^ //')"
	printf "prepare ran: sed -i 's/^ *//' messy.txt\n"
	printf "prepare ran: echo p2 >>%s/order; echo 'test result: ok. 9 passed; 0 failed;'\n" "$TMP"
)
[[ $code == 0 && $out == "$want" && $(<"$W/messy.txt") == messy ]] &&
	ok "prepare: its lines fix the tree before the gate, and the block names each line that ran, after the diffstat" || bad "prepare block (exit $code)" "$out"$'\n'"$(cat "$TMP/p.err")"
[[ $(<"$TMP/order") == $'p2\nleg' ]] &&
	ok "prepare: the lines run in order, before every gate leg" || bad "prepare order" "$(cat "$TMP/order")"
pev=$(tail -1 "$SLOG")
python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert e["result"]=="pass"; assert [(l["name"],l["result"]) for l in e["legs"]]==[(n,"pass") for n in ("prepare","check","test","fmt","order")], e["legs"]' "$pev" &&
	ok "prepare: the stamp event records it as a leg named prepare, ahead of the gate's" || bad "prepare event" "$pev"
# The state is taken after prepare: what it writes is counted dirty and is not a change during the gate.
rm -f "$W"/gate-*.txt
PREPARE='["echo made >prepared.txt"]' stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
[[ $? == 0 && $out == *'dirty 2'* && $out == *'prepare ran: echo made >prepared.txt'* ]] &&
	ok "prepare: the dirty count and the unchanged-tree check are taken after it" || bad "prepare state" "$out"
rm -f "$W"/gate-*.txt "$W/prepared.txt"
PREPARE='["echo one", "", "   "]' stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
[[ $(grep -c '^prepare ran: ' <<<"$out") == 1 && $out == *'prepare ran: echo one'* ]] &&
	ok "prepare: blank lines are skipped" || bad "prepare blanks" "$out"
rm -f "$W"/gate-*.txt
PREPARE='[]' stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>/dev/null)
[[ $? == 0 && $out != *prepare* ]] && ! tail -1 "$SLOG" | grep -q '"prepare"' &&
	ok "prepare: an empty array is no prepare: no line in the block, no leg in the event" || bad "prepare empty" "$out"
# A failing line fails the stamp, keeping its tail as a failed leg does.
rm -f "$W"/gate-*.txt "$TMP/order"
PREPARE="[\"echo first-prep\", \"echo prep says why; exit 7\", \"echo never >>$TMP/order\"]" \
	stamp_manifest "order=echo leg >>$TMP/order" check=true
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >"$TMP/p.out" 2>"$TMP/p.err"
code=$?
pev=$(tail -1 "$SLOG")
[[ $code == 4 && ! -s $TMP/p.out && ! -e $TMP/order && -z $(find "$W" -maxdepth 1 -name 'gate-*.txt') ]] &&
	grep -qF "prepare line 'echo prep says why; exit 7' exited 7" "$TMP/p.err" &&
	ok "prepare: a failing line fails the stamp with exit 4, names the line, runs nothing after it and writes no evidence" || bad "prepare fail (exit $code)" "$(cat "$TMP/p.err")"
python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert e["result"]=="fail"; assert [(l["name"],l["result"]) for l in e["legs"]]==[("prepare","fail"),("order","skip"),("check","skip")]; t=e["legs"][0]["tail"]; assert t.splitlines()==["first-prep","prep says why"], t; assert "tail" not in e["legs"][1]; assert "prepare line" in e["detail"]' "$pev" &&
	ok "prepare: a failing line's event fails the prepare leg with its tail and skips the gate's legs" || bad "prepare fail event" "$pev"
plog=$(jfield "$pev" log)
[[ -f $plog ]] && grep -qx '== prepare: echo prep says why; exit 7 (exit 7)' "$plog" && grep -qx 'prep says why' "$plog" &&
	ok "prepare: a failing line's full output is in the stamp log" || bad "prepare fail log" "$(cat "$plog" 2>/dev/null)"
PREPARE='"cargo fmt"' stamp_manifest check=true
expect "prepare: a value that is not an array is a manifest error" 2 'not an array|must be an array' -- -C "$W" --manifest "$TMP/s.toml" stamp
mf '[stamp]\nprepares = ["x"]\n[gate]\ncommand = "true"\n'
expect "prepare: another key under [stamp] is a manifest error" 2 "unknown key 'prepares' in \[stamp\]" -- -C "$W" --manifest "$TMP/s.toml" stamp
rm -f "$W"/gate-*.txt "$W/messy.txt" "$TMP/order"
stamp_manifest "${STD_LEGS[@]}"

# ---- stamp: tests added and removed (v0.169) -------------------------------
# [stamp] test_files and test_def: the block counts the test definitions the
# item's diff adds and removes, and flags a code change that removes none.
# One fixture repo; each case is a branch off main with its own worktree.
TC=$TMP/tcount
make_repo "$TC"
cp "$S/fake-test.sh" "$TC/"
mkdir -p "$TC/tests" "$TC/src"
printf 'case "one"\ncase "two"\ncase "three"\nhelper() { :; }\n' >"$TC/tests/t.sh"
printf 'echo code\n' >"$TC/src/c.sh"
git -C "$TC" add -A && git -C "$TC" commit -qm "tests and code"
TC_FLAG='flag: code changed, no test removed or rewritten (PO: check for pins on replaced behaviour)'
# tc_case <name> <shell run in the new worktree>: a branch c-<name> off main,
# the shell's changes committed on it (none: the branch stays at main).
tc_case() {
	local wt=$TC/.wt/c-$1
	git -C "$TC" worktree add -q "$wt" -b "c-$1" main
	(cd "$wt" && eval "$2")
	git -C "$wt" add -A
	git -C "$wt" diff --cached --quiet || git -C "$wt" commit -qm "c-$1"
	TCW=$wt
}
# tc_want <extra block line>...: today's three lines for TCW, then the extras.
tc_want() {
	printf 'HEAD %s (%s)  dirty 0\n' "$(git -C "$TCW" rev-parse HEAD)" "$(git -C "$TCW" symbolic-ref --short HEAD)"
	printf 'gate PASS: test   tests 5 passed\n'
	local ds
	ds=$(git -C "$TCW" diff --shortstat "$(git -C "$TCW" merge-base main HEAD)" HEAD | sed 's/^ //')
	printf 'diffstat vs merge-base(main): %s\n' "${ds:-no changes}"
	[[ $# == 0 ]] || printf '%s\n' "$@"
}
# tc_is <test name> <extra block line>...: stamp TCW, the block is exactly tc_want's.
tc_is() {
	local name=$1 out code want
	shift
	out=$("$PO" -C "$TCW" --manifest "$TMP/s.toml" stamp 2>"$TMP/tc.err")
	code=$?
	want=$(tc_want "$@")
	[[ $code == 0 && $out == "$want" && $(<"$(compgen -G "$TCW/gate-*.txt" | tail -1)") == "$want" ]] &&
		ok "$name" || bad "$name (exit $code)" "$out"$'\n--- want\n'"$want"$'\n--- stderr\n'"$(tail -5 "$TMP/tc.err")"
}
TC_ADD3='printf '\''case "four"\ncase "five"\ncase "six"\n'\'' >>tests/t.sh; printf '\''echo more\ncase "not a test file"\n'\'' >>src/c.sh'
tc_case add3 "$TC_ADD3"
stamp_manifest "test=sh ./fake-test.sh"
tc_is "test counts: keys unset, the block is today's three lines, nothing more"
TEST_FILES='["tests/"]' TEST_DEF='"^case \""' stamp_manifest "test=sh ./fake-test.sh"
tc_is "test counts: 3 definitions added with a code change -> +3 -0 and the flag line, exactly; a definition outside test_files does not count" \
	'tests vs merge-base(main): +3 -0' "$TC_FLAG"
tc_case add2rm1 'sed -i "/^case \"two\"/d" tests/t.sh; printf '\''case "four"\ncase "five"\n'\'' >>tests/t.sh; echo more >>src/c.sh'
tc_is "test counts: 2 added, 1 removed, with a code change -> +2 -1, no flag" 'tests vs merge-base(main): +2 -1'
tc_case rewrite 'sed -i "s/^case \"two\"/case \"two, better\"/" tests/t.sh; echo more >>src/c.sh'
tc_is "test counts: a rewritten definition (one line changed) counts in both -> +1 -1, no flag" 'tests vs merge-base(main): +1 -1'
tc_case nondef 'echo "other() { :; }" >>tests/t.sh; sed -i "/^helper/d" tests/t.sh; echo more >>src/c.sh'
tc_is "test counts: lines in test_files that define no test count for nothing; a code change then gets the flag" \
	'tests vs merge-base(main): +0 -0' "$TC_FLAG"
tc_case docs 'echo more >>README.md; mkdir -p docs/notes; echo x >docs/notes/n.txt; echo y >CHANGELOG.md; mkdir sub; echo z >sub/NOTES.md'
tc_is "test counts: a docs-only diff (*.md, docs/, CHANGELOG.md) -> +0 -0, no flag" 'tests vs merge-base(main): +0 -0'
tc_case testsonly 'printf '\''case "four"\ncase "five"\n'\'' >>tests/t.sh; printf '\''case "x"\n'\'' >tests/u.sh'
TEST_FILES='["tests/*.sh"]' TEST_DEF='"^case \""' stamp_manifest "test=sh ./fake-test.sh"
tc_is "test counts: a tests-only diff counts its definitions (test_files as a glob) -> +3 -0, no flag" 'tests vs merge-base(main): +3 -0'
tc_case rust 'printf '\''#[test]\nfn a() {}\n#[test]\nfn b() {}\n#[tests]\n'\'' >tests/r.rs; echo "[test]" >>src/c.sh'
TEST_FILES='["tests/"]' TEST_DEF='"^#\\[test\\]$"' stamp_manifest "test=sh ./fake-test.sh"
tc_is "test counts: a test_def with backslash escapes is matched as grep -E reads it -> +2 -0, the flag" \
	'tests vs merge-base(main): +2 -0' "$TC_FLAG"
tc_case nodiff ':'
tc_is "test counts: no diff -> +0 -0, no flag" 'tests vs merge-base(main): +0 -0'
mkdir -p "$TC/more" && printf 'case "m1"\ncase "m2"\n' >"$TC/more/m.sh"
git -C "$TC" add -A && git -C "$TC" commit -qm "a second test path"
tc_case multipath 'sed -i "/^case \"m2\"/d" more/m.sh; printf '\''case "four"\n'\'' >>tests/t.sh; echo more >>src/c.sh'
TEST_FILES='["tests/", "more/"]' TEST_DEF='"^case \""' stamp_manifest "test=sh ./fake-test.sh"
tc_is "test counts: every test_files path counts; a removal in the second path -> +1 -1, no flag" 'tests vs merge-base(main): +1 -1'
TCW=$TC/.wt/c-add3
rm -f "$TCW"/gate-*.txt
TEST_DEF='"^case \""' stamp_manifest "test=sh ./fake-test.sh"
expect "test counts: test_def without test_files is a manifest error, exit 2" 2 'test_def and test_files go together' -- -C "$TCW" --manifest "$TMP/s.toml" stamp
TEST_FILES='["tests/"]' stamp_manifest "test=sh ./fake-test.sh"
expect "test counts: test_files without test_def is a manifest error, exit 2" 2 'test_def and test_files go together' -- -C "$TCW" --manifest "$TMP/s.toml" stamp
TEST_FILES='"tests/"' TEST_DEF='"^case \""' stamp_manifest "test=sh ./fake-test.sh"
expect "test counts: test_files that is not an array is a manifest error" 2 'not an array|must be an array' -- -C "$TCW" --manifest "$TMP/s.toml" stamp
TEST_FILES='[]' TEST_DEF='"^case \""' stamp_manifest "test=sh ./fake-test.sh"
expect "test counts: an empty test_files is a manifest error" 2 'test_files needs at least one path' -- -C "$TCW" --manifest "$TMP/s.toml" stamp
TEST_FILES='["tests/"]' TEST_DEF='"(ok"' stamp_manifest "test=sh ./fake-test.sh"
expect "test counts: a test_def that is not a valid ERE is a manifest error" 2 'test_def is not a valid extended regular expression' -- -C "$TCW" --manifest "$TMP/s.toml" stamp
[[ -z $(compgen -G "$TCW/gate-*.txt") ]] && ok "test counts: a manifest error writes no stamp file" || bad "test counts: manifest error wrote a stamp" "$(ls "$TCW")"
stamp_manifest "${STD_LEGS[@]}"

# ---- releases and adopters (item K) ---------------------------------------
# Every install below runs with a throwaway HOME; the real symlink must not move.
REAL_PO_LINK=$(readlink -f "$HOME/.local/bin/po" 2>/dev/null || true)
KH=$TMP/kh
mkdir -p "$KH/.config/po-kit"
KITROOT=$(dirname "$(dirname "$PO")")
FX=$TMP/kit
git init -q -b main "$FX"
git -C "$FX" config user.name t
git -C "$FX" config user.email t@example.invalid
cp -r "$KITROOT/bin" "$KITROOT/lib" "$FX/"
git -C "$FX" add -A
git -C "$FX" commit -qm "v0.1"
git -C "$FX" tag v0.1
INST=$FX/bin/po-install
KPO=$KH/.local/bin/po
hpo() { HOME=$KH "$@"; }
klink() { readlink "$KPO" 2>/dev/null || echo none; }

# Adopters: two good (one by ~/), one with a manifest only a newer po rejects
# comes later; a broken one, a missing one.
make_repo "$KH/ad1"
make_repo "$TMP/ad2"
printf 'owner_column = "Owner"\n' >>"$TMP/ad2/po.toml"
git -C "$TMP/ad2" commit -qam owner
make_repo "$TMP/ad3"
printf 'bogus = 1\n' >>"$TMP/ad3/po.toml"
git -C "$TMP/ad3" commit -qam broken

# po version.
out=$(hpo "$PO" version 2>&1)
[[ $? == 0 && -n $out && $out != *$'\n'* ]] && ok "po version prints one line" || bad "po version" "$out"
expect "po version takes no arguments" 1 'version takes no arguments' -- version now
expect "po version works outside any repository" 0 '.' -- -C / version

# po doctor.
expect "doctor with no adopters list is exit 2" 2 'no adopters list' -- doctor
printf '# the adopters\n\n~/ad1\n  %s  \n' "$TMP/ad2" >"$KH/.config/po-kit/adopters"
dsnap() { git -C "$KH/ad1" status --porcelain --ignored; git -C "$TMP/ad2" status --porcelain --ignored; git -C "$KH/ad1" for-each-ref; find "$KH" -type f | sort; }
before=$(dsnap)
out=$(HOME=$KH "$PO" doctor 2>&1)
code=$?
[[ $code == 0 ]] && grep -qE "^adopter +$KH/ad1\$" <<<"$out" && grep -qE "^adopter +$TMP/ad2\$" <<<"$out" &&
	ok "doctor lists each adopter (~/ expanded, comments and blanks skipped), exit 0" || bad "doctor adopters (exit $code)" "$out"
[[ $(grep -cE '^  manifest +ok$' <<<"$out") == 2 && $(grep -cE '^  status +ok$' <<<"$out") == 2 ]] &&
	ok "doctor says the manifest parses and status runs" || bad "doctor ok lines" "$out"
adopter_block() { awk -v p="$1" '$1 == "adopter" { on = ($2 == p) } on' <<<"$out"; }
adopter_block "$KH/ad1" | grep -q '^  adopt  *\[hooks\] on_close$' && adopter_block "$KH/ad1" | grep -q '^  adopt  *\[layout\] owner_column$' &&
	ok "doctor lists the optional keys a manifest does not set" || bad "doctor adopt keys" "$out"
adopter_block "$KH/ad1" | grep -q '^  adopt  *\[kickoff\] preamble$' &&
	ok "doctor offers [kickoff] preamble to a manifest without it" || bad "doctor kickoff adopt" "$out"
adopter_block "$KH/ad1" | grep -q '^  adopt  *\[close\] checklist$' &&
	ok "doctor offers [close] checklist to a manifest without it" || bad "doctor close adopt" "$out"
adopter_block "$KH/ad1" | grep -q '^  adopt  *\[stamp\] prepare$' &&
	ok "doctor offers [stamp] prepare to a manifest without it" || bad "doctor stamp adopt" "$out"
! adopter_block "$TMP/ad2" | grep -q 'owner_column' && adopter_block "$TMP/ad2" | grep -q '^  adopt  *\[hooks\] on_close$' &&
	ok "a key the manifest sets is not offered" || bad "doctor offered a set key" "$out"
[[ $(dsnap) == "$before" ]] && ok "doctor is read-only" || bad "doctor wrote something"
printf '%s\n%s\n/nonexistent/adopter\n' "$KH/ad1" "$TMP/ad3" >"$KH/.config/po-kit/adopters"
out=$(HOME=$KH "$PO" doctor 2>&1)
code=$?
[[ $code == 2 ]] && grep -qE "^  manifest +FAIL.*unknown key 'bogus'" <<<"$out" && grep -qE '^  manifest +FAIL.*(not|no)' <<<"$out" &&
	grep -qE '^  manifest +ok$' <<<"$out" && ok "a broken or missing adopter is reported FAIL; doctor exits 2" || bad "doctor failures (exit $code)" "$out"
expect "doctor takes no arguments" 1 'doctor takes no arguments' -- doctor now
expect "doctor refuses --manifest" 1 'adopter.*own manifest' -- --manifest "$TMP/ad3/po.toml" doctor

# po-install.
out=$("$INST" --help 2>&1)
code=$?
[[ $code == 0 ]] && grep -q 'usage: po-install' <<<"$out" && ok "po-install --help exits 0" || bad "po-install help" "$out"
out=$(HOME=$KH "$INST" a b 2>&1)
[[ $? == 1 ]] && grep -q 'usage: po-install' <<<"$out" && ok "po-install takes at most one tag" || bad "po-install arity" "$out"
rm -f "$KH/.config/po-kit/adopters"
out=$(HOME=$KH "$INST" v0.1 2>&1)
code=$?
[[ $code == 0 && $(klink) == "$KH/.local/share/po-kit/v0.1/bin/po" ]] && grep -qE '\(none\) -> v0\.1' <<<"$out" &&
	ok "po-install <tag> points the symlink at the tag's checkout and prints old and new" || bad "install v0.1 (exit $code)" "$out"
[[ $(git -C "$KH/.local/share/po-kit/v0.1" rev-parse HEAD) == "$(git -C "$FX" rev-parse "v0.1^{commit}")" &&
	$(git -C "$KH/.local/share/po-kit/v0.1" symbolic-ref -q HEAD || echo detached) == detached ]] &&
	ok "the tag is a detached worktree of the po-kit repository" || bad "install worktree"
[[ $(hpo "$KPO" version) == v0.1 ]] && ok "the installed po reports its tag" || bad "installed version" "$(hpo "$KPO" version 2>&1)"
grep -q 'no adopters' <<<"$out" && ok "no adopters list: noted, install still succeeds" || bad "no-adopters note" "$out"

echo two >"$FX/mark2"
git -C "$FX" add mark2
git -C "$FX" commit -qm "v0.2"
git -C "$FX" tag v0.2
printf '%s\n%s\n' "$KH/ad1" "$TMP/ad2" >"$KH/.config/po-kit/adopters"
echo dirt >>"$FX/lib/po/manifest.sh" # a dirty main checkout changes nothing live
out=$(HOME=$KH "$INST" 2>&1)
code=$?
[[ $code == 0 && $(klink) == "$KH/.local/share/po-kit/v0.2/bin/po" ]] && grep -qE 'v0\.1 -> v0\.2' <<<"$out" &&
	ok "po-install with no tag installs the newest tag" || bad "install newest (exit $code)" "$out"
grep -qE "^adopter +$KH/ad1\$" <<<"$out" && grep -qE '^  manifest +ok$' <<<"$out" &&
	ok "po-install runs po doctor after switching" || bad "install doctor" "$out"
[[ -f $KH/.local/share/po-kit/v0.2/mark2 ]] && git -C "$KH/.local/share/po-kit/v0.2" diff --quiet &&
	cmp -s "$KH/.local/share/po-kit/v0.2/lib/po/manifest.sh" <(git -C "$FX" show v0.2:lib/po/manifest.sh) &&
	ok "a dirty main checkout is not what gets installed" || bad "dirty main leaked"
git -C "$FX" checkout -q -- lib/po/manifest.sh

out=$(HOME=$KH "$INST" v0.1 2>&1)
[[ $? == 0 && $(klink) == "$KH/.local/share/po-kit/v0.1/bin/po" ]] && grep -qE 'v0\.2 -> v0\.1' <<<"$out" &&
	ok "an older tag can be installed again; its checkout is reused" || bad "reinstall v0.1" "$out"

git -C "$FX" branch topic
before=$(klink)
out=$(HOME=$KH "$INST" topic 2>&1)
code=$?
[[ $code == 6 && $(klink) == "$before" ]] && grep -q "'topic' is not a tag" <<<"$out" &&
	ok "po-install refuses a branch, symlink unchanged" || bad "install branch (exit $code)" "$out"
out=$(HOME=$KH "$INST" v9.9 2>&1)
[[ $? == 6 && $(klink) == "$before" ]] && ok "po-install refuses an unknown tag" || bad "install unknown tag" "$out"
echo dirt >"$KH/.local/share/po-kit/v0.1/stray"
out=$(HOME=$KH "$INST" v0.1 2>&1)
[[ $? == 6 && $(klink) == "$before" ]] && grep -q 'not a clean checkout' <<<"$out" &&
	ok "po-install refuses a dirty install directory" || bad "install dirty dir" "$out"
rm -f "$KH/.local/share/po-kit/v0.1/stray"

# A tag whose po rejects a manifest the installed one accepts.
printf '[hooks]\non_close = "true"\n' >>"$TMP/ad2/po.toml"
git -C "$TMP/ad2" commit -qam hooks
git -C "$FX" rm -q --cached mark2 >/dev/null
rm -f "$FX/mark2"
sed -i '/\[hooks.on_close\]=0/d' "$FX/lib/po/manifest.sh"
git -C "$FX" commit -qam "v0.3 drops hooks"
git -C "$FX" tag v0.3
HOME=$KH "$INST" v0.2 >/dev/null 2>&1
before=$(klink)
out=$(HOME=$KH "$INST" v0.3 2>&1)
code=$?
[[ $code == 6 && $(klink) == "$before" ]] && grep -q "$TMP/ad2" <<<"$out" &&
	[[ ! -e $KH/.local/share/po-kit/v0.3 ]] && ! git -C "$FX" worktree list | grep -q 'po-kit/v0.3' &&
	ok "a tag that breaks an adopter's manifest is refused: symlink unchanged, nothing left behind" || bad "install breaking tag (exit $code)" "$out"

# An adopter already broken under the old po does not block the switch; doctor
# then fails and po-install says so (exit 7, the switch stands).
printf '%s\n%s\n' "$KH/ad1" "$TMP/ad3" >"$KH/.config/po-kit/adopters"
out=$(HOME=$KH "$INST" v0.3 2>&1)
code=$?
[[ $code == 7 && $(klink) == "$KH/.local/share/po-kit/v0.3/bin/po" ]] && grep -qE '^  manifest +FAIL' <<<"$out" &&
	ok "an adopter already broken does not block; a failing doctor exits 7 with the switch standing" || bad "install then doctor fail (exit $code)" "$out"
[[ $(readlink -f "$HOME/.local/bin/po" 2>/dev/null || true) == "$REAL_PO_LINK" ]] &&
	ok "the real ~/.local/bin/po was never touched" || bad "real symlink moved"

# ---- the event viewer (item M) ---------------------------------------------
# po serve reads events only through `po events --json`; a fake po on PATH
# prints fixture JSON, so these tests hold with or without the real command.
SV="$TMP/serve"
mkdir -p "$SV/bin" "$SV/repo"
make_repo "$SV/repo"
# helper
python3 -I - "$SV/events.json" <<'PY'
import json, sys
ev = [{"time": "2026-10-23T%02d:00:00Z" % i, "kind": "stamp", "item": "1.%d" % i, "project": "demo",
       "result": "pass" if i % 4 else "fail",
       "legs": [{"name": "lint", "result": "pass"}, {"name": "test", "result": "pass" if i % 4 else "fail"}],
       "agent": "dev%d" % i, "detail": "d%d" % i} for i in range(12)]
ev[3]["item"] = '<script>alert("x")</script>&'
ev[4]["agent"] = '"><img src=x>'
ev[5]["item"] = None
ev[5]["detail"] = "<b>boom</b>"
ev[6]["kind"] = "open"
ev[6]["legs"] = []
ev[7]["detail"] = ""
ev[8]["legs"][1]["tail"] = "tail one\ntail <two>"
ev[8]["log"] = "/repo/.git/po-logs/stamp-x.log"
# real po events --json: one object per line, keys in this order
KEYS = ("time", "kind", "item", "project", "result", "agent", "legs", "detail", "log")
with open(sys.argv[1], "w") as f:  # oldest first: the viewer must sort newest first
    for e in ev:
        f.write(json.dumps({k: e[k] for k in KEYS if k in e}, separators=(",", ":")) + "\n")
PY
cat >"$SV/bin/po" <<'EOF'
#!/usr/bin/env bash
[[ $1 == events && $* == *--json* ]] || { echo "fake po: unexpected: $*" >&2; exit 9; }
# like the real po: without --all only the newest 10 (here: 1) come back
if [[ $* == *--archived* ]]; then
	if [[ $* == *--all* ]]; then cat "$FAKE_ARCHIVE"; else tail -n 1 "$FAKE_ARCHIVE"; fi
else cat "$FAKE_EVENTS"; fi
EOF
chmod +x "$SV/bin/po"
# the archive the fake serves: two older events, oldest first like the real file
printf '%s\n%s\n' \
	'{"time":"2026-09-01T10:00:00Z","kind":"open","item":"0.1","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}' \
	'{"time":"2026-09-02T10:00:00Z","kind":"close","item":"0.1","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}' >"$SV/archive.json"

# sv_start [po serve args...]: sets SV_URL and SV_PID, or SV_URL empty.
sv_start() {
	: >"$SV/out"
	(cd "$SV/repo" && PATH="$SV/bin:$PATH" FAKE_EVENTS="$SV/events.json" FAKE_ARCHIVE="$SV/archive.json" exec "$PO" serve --port 0 "$@" >"$SV/out" 2>"$SV/err") &
	SV_PID=$!
	SV_URL=
	local _
	for _ in $(seq 1 100); do
		SV_URL=$(sed -nE 's/^po serve: listening on (http:\/\/[^ ]+)\/$/\1/p' "$SV/out")
		[[ -n $SV_URL ]] && return
		kill -0 "$SV_PID" 2>/dev/null || return
		sleep 0.1
	done
}
sv_stop() { kill "$SV_PID" 2>/dev/null; wait "$SV_PID" 2>/dev/null; }
# sv_req <method> <path>: first line "<status>", then the body.
sv_req() {
	# helper
	python3 -I - "$1" "$SV_URL$2" <<'PY'
import sys, urllib.request, urllib.error
req = urllib.request.Request(sys.argv[2], method=sys.argv[1], data=b"x" if sys.argv[1] in ("POST", "PUT", "PATCH") else None)
try:
    r = urllib.request.urlopen(req, timeout=10)
except urllib.error.HTTPError as e:
    r = e
print(r.status)
sys.stdout.write(r.read().decode())
PY
}

sv_start
if [[ -z $SV_URL ]]; then
	bad "po serve starts and prints its URL" "$(cat "$SV/out" "$SV/err")"
else
	[[ $SV_URL == http://127.0.0.1:* ]] && ok "po serve binds 127.0.0.1 by default" || bad "default bind" "$SV_URL"
	out=$(sv_req GET /)
	[[ $(head -1 <<<"$out") == 200 && $(grep -c '<td class="c-time"' <<<"$out") == 10 && $(grep -c '^<tr ' <<<"$out") == 10 ]] &&
		ok "/ shows 10 rows after 12 events" || bad "/ rows" "$out"
	first=$(grep -m1 '^<tr ' <<<"$out")
	[[ $first == *1.11* && $first == *dev11* && $first == *demo* && $first == *stamp* && $first == *'class="r-pass"'* ]] &&
		ok "/ lists item, project, kind, result, agent and time, newest on top" || bad "/ newest row" "$first"
	[[ $out != *'>1.0<'* && $out != *'>1.1<'* && $out == *'>1.2<'* ]] &&
		ok "/ drops the two oldest events" || bad "/ cut" "$out"
	[[ $out == *'onclick="location=&apos;/all&apos;"'* || $out == *"onclick=\"location='/all'\""* ]] &&
		ok "each / row links to /all" || bad "row link" "$first"
	out=$(sv_req GET /all)
	[[ $(head -1 <<<"$out") == 200 && $(grep -c '^<tr ' <<<"$out") == 12 && $(grep -m1 '^<tr ' <<<"$out") == *1.11* && $out == *'>lint:pass test:pass</td>'* && $out == *'>lint:pass test:fail</td>'* ]] &&
		ok "/all lists all 12 events, newest on top, with legs" || bad "/all" "$out"
	out=$(sv_req GET /events.json)
	[[ $(head -1 <<<"$out") == 200 ]] &&
		[[ $(tail -n +2 <<<"$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(len(d), d[0]["item"], d[-1]["item"])') == "12 1.11 1.0" ]] &&
		ok "/events.json serves all events, newest first" || bad "/events.json" "$out"
	out=$(sv_req GET /archive.json)
	[[ $(head -1 <<<"$out") == 200 ]] &&
		[[ $(tail -n +2 <<<"$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(len(d), d[0]["kind"], d[-1]["kind"])') == "2 close open" ]] &&
		ok "/archive.json serves the archive, newest first, from po events --archived" || bad "/archive.json" "$out"
	out=$(sv_req GET /events.json)
	[[ $(tail -n +2 <<<"$out" | python3 -I -c 'import json,sys; print(sum(1 for e in json.load(sys.stdin) if e["item"]=="0.1"))') == 0 ]] &&
		ok "/events.json stays live only: no archived event in it" || bad "/events.json live only" "$out"
	[[ $(sv_req POST /archive.json | head -1) == 405 ]] &&
		ok "/archive.json is read-only: POST is 405" || bad "archive POST"
	out=$(sv_req GET /all)
	[[ $out == *'<script>alert'* ]] && bad "item name reached the page unescaped" "$out" ||
		{ [[ $out == *'&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&amp;'* && $out == *'&quot;&gt;&lt;img src=x&gt;'* ]] &&
			ok "every field is HTML-escaped (names are data, not markup)" || bad "escaping" "$out"; }
	[[ $out == *'<td class="c-item" title="-">-</td>'* && $out == *'<td class="c-kind" title="open">open</td>'* && $out == *'&lt;b&gt;boom&lt;/b&gt;'* && $out != *'<b>boom'* ]] &&
		ok "item null shows -, kind shows, detail is escaped" || bad "null item, kind, detail" "$out"
	rows=$(grep -c '^<tr ' <<<"$out")
	[[ $rows == 12 && $(grep -c '<td class="c-result"' <<<"$out") == 12 && $(grep -c '<td class="c-checks"' <<<"$out") == 12 &&
		$(grep -c '<td class="c-note"' <<<"$out") == 12 ]] &&
		ok "every row has the same eight columns, one row per event" || bad "columns" "$out"
	[[ $(grep -c 'class="note"' <<<"$out") == 11 && $out == *'<td class="c-note"></td>'* ]] &&
		ok "the note icon is on events with a detail and the slot is empty without" || bad "note slot" "$out"
	[[ $out == *'<span class="note" role="img" tabindex="0" title="d3" aria-label="d3">'* && $out == *'title="&lt;b&gt;boom&lt;/b&gt;" aria-label="&lt;b&gt;boom&lt;/b&gt;"'* ]] &&
		ok "the note icon carries the detail as title and aria-label, escaped" || bad "note attrs" "$out"
	[[ $out == *'title="d8'$'\n\n''leg test, last lines:'$'\n''tail one'$'\n''tail &lt;two&gt;'$'\n\n''full output: /repo/.git/po-logs/stamp-x.log"'* ]] &&
		ok "a failed stamp's note adds the failing leg's tail and the log, escaped" || bad "note tail" "$out"
	[[ $out == *'if (e.log) parts.push("full output: "'* && $out == *'", last lines:\n"'* ]] &&
		ok "the live redraw builds the same note with the tail and the log" || bad "page script note"
	[[ $out == *'<span class="r-fail">'$'\u2718'' fail</span>'* && $out == *'<span class="r-pass">'$'\u2714'' pass</span>'* ]] &&
		ok "pass and fail carry a symbol and a word" || bad "result cues" "$out"
	[[ $out == *'fetch("/events.json"'* && $out == *'aria-label'* && $out == *"for (const c of cols)"* ]] &&
		ok "the live redraw builds the same columns and note icon" || bad "page script columns" "$out"
	[[ $out == *'fetch("/events.json"'* && $out == *toLocaleString* && $out == *textContent* ]] &&
		ok "pages poll /events.json and render times locally with textContent" || bad "page script"
	for m in POST PUT DELETE PATCH OPTIONS; do
		out=$(sv_req "$m" /)
		[[ $(head -1 <<<"$out") == 405 ]] && ok "$m is 405" || bad "$m" "$out"
	done
	out=$(sv_req HEAD /)
	[[ $(head -1 <<<"$out") == 405 ]] && ok "HEAD is 405" || bad "HEAD" "$out"
	out=$(sv_req GET /nope)
	[[ $(head -1 <<<"$out") == 404 ]] && ok "an unknown path is 404" || bad "404" "$out"
	out=$(sv_req GET '/?x=1')
	[[ $(head -1 <<<"$out") == 200 ]] && ok "a query string is ignored" || bad "query" "$out"
	sv_stop
fi

# The viewer is live: a new event shows on the next request without a restart.
cp "$SV/events.json" "$SV/events-live.json"
(cd "$SV/repo" && PATH="$SV/bin:$PATH" FAKE_EVENTS="$SV/events-live.json" exec "$PO" serve --port 0 >"$SV/out" 2>"$SV/err") &
SV_PID=$!
for _ in $(seq 1 100); do
	SV_URL=$(sed -nE 's/^po serve: listening on (http:\/\/[^ ]+)\/$/\1/p' "$SV/out")
	[[ -n $SV_URL ]] && break
	sleep 0.1
done
before=$(sv_req GET /events.json | tail -n +2 | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))')
# helper
python3 -I - "$SV/events-live.json" <<'PY'
import json, sys
e = {"time": "2026-10-24T00:00:00Z", "kind": "close", "item": "9.9", "project": "demo", "result": "pass", "agent": "x", "legs": [], "detail": ""}
open(sys.argv[1], "a").write(json.dumps(e) + "\n")
PY
out=$(sv_req GET /)
[[ $before == 12 && $(grep -m1 '^<tr ' <<<"$out") == *9.9* ]] &&
	ok "a new event shows on the next request, newest on top" || bad "live update" "$out"
# One JSON object per line is read as well as one array.
# helper
python3 -I - "$SV/events-live.json" <<'PY'
import json, sys
d = [json.loads(l) for l in open(sys.argv[1])]
json.dump(d[:3], open(sys.argv[1], "w"))
PY
out=$(sv_req GET /events.json)
[[ $(tail -n +2 <<<"$out" | python3 -I -c 'import json,sys; print(len(json.load(sys.stdin)))') == 3 ]] &&
	ok "po events --json as one array is read too" || bad "json lines" "$out"
printf 'not json\n' >"$SV/events-live.json"
out=$(sv_req GET /events.json)
[[ $(head -1 <<<"$out") == 502 && $out == *'not JSON'* ]] && ok "unreadable po events output is a 502, not a crash" || bad "bad json" "$out"
out=$(sv_req GET /)
[[ $(head -1 <<<"$out") == 200 && $out == *'id="err">po events --json is not JSON'* ]] && ok "the page shows the error" || bad "page error" "$out"
sv_stop

# /events.json is conditional and incremental (v0.93): an ETag of the whole feed, 304 on a
# matching If-None-Match, ?since= at or after a time (X-Po-Since: partial), full without.
printf '%s\n' \
	'{"time":"2026-10-23T01:00:00Z","kind":"stamp","item":"1.1","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}' \
	'{"time":"2026-10-23T02:00:00Z","kind":"stamp","item":"1.2","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}' \
	'{"time":"2026-10-23T03:00:00Z","kind":"stamp","item":"1.3","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}' \
	'{"kind":"stamp","item":"1.x","project":"demo","result":"pass","agent":"a","legs":[],"detail":""}' >"$SV/events-cond.json"
(cd "$SV/repo" && PATH="$SV/bin:$PATH" FAKE_EVENTS="$SV/events-cond.json" exec "$PO" serve --port 0 >"$SV/out" 2>"$SV/err") &
SV_PID=$!
SV_URL=
for _ in $(seq 1 100); do
	SV_URL=$(sed -nE 's/^po serve: listening on (http:\/\/[^ ]+)\/$/\1/p' "$SV/out")
	[[ -n $SV_URL ]] && break
	sleep 0.1
done
if [[ -z $SV_URL ]]; then
	bad "po serve (conditional) starts" "$(cat "$SV/out" "$SV/err")"
else
	block serve-conditional python3 -B -I - "$SV_URL" "$(dirname "$PO")/../lib/po" "$SV/events-cond.json" <<'PY'
import json, sys, urllib.error, urllib.request
url = sys.argv[1] + "/events.json"
sys.path.insert(0, sys.argv[2])
import dashboard_core as c

def check(name, cond, detail=""):
    print("%s\t%s\t%s" % ("ok" if cond else "FAIL", name, str(detail).replace("\n", " | ")))

def get(u, inm=None):
    req = urllib.request.Request(u)
    if inm:
        req.add_header("If-None-Match", inm)
    try:
        r = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as e:
        r = e
    return r.status, r.headers, r.read().decode()

s1, h1, b1 = get(url)
s2, h2, b2 = get(url)
etag = h1.get("ETag")
check("po serve: /events.json carries a quoted ETag, stable across two identical requests",
      s1 == s2 == 200 and etag and etag.startswith('"') and etag.endswith('"') and h2.get("ETag") == etag and b1 == b2, (etag, h2.get("ETag")))
check("po serve: /events.json without since is X-Po-Since: full, every event", h1.get("X-Po-Since") == "full" and len(json.loads(b1)) == 4, h1.get("X-Po-Since"))
s, h, b = get(url, etag)
check("po serve: a matching If-None-Match is 304 with the ETag and no body", s == 304 and b == "" and h.get("ETag") == etag, (s, b))
s, h, b = get(url + "?since=2026-10-23T01:00:00Z", etag)
check("po serve: the 304 check comes first and uses the whole feed's ETag (a ?since= request too)", s == 304 and b == "", s)
s, h, b = get(url, '"other"')
check("po serve: a stale If-None-Match gets the whole feed", s == 200 and len(json.loads(b)) == 4, s)
s, h, b = get(url + "?since=2026-10-23T02:00:00Z")
items = sorted(e["item"] for e in json.loads(b)) if s == 200 else b
check("po serve: ?since= returns the events at or after it (an event at since itself included) and those with no time, partial",
      s == 200 and items == ["1.2", "1.3", "1.x"] and h.get("X-Po-Since") == "partial" and h.get("ETag") == etag, (s, items, h.get("X-Po-Since")))

# The dashboard's Feed against po serve: a 304 and a partial.
f = c.Feed(url)
whole = f.load(c.parse_events)
check("po serve: the dashboard Feed takes the whole feed, keeps the ETag and sees ?since= offered", whole[0] and whole[2] is False and f.etag == etag and f.since_ok, (f.etag, f.since_ok))
check("po serve: the dashboard Feed's second whole fetch does not send If-None-Match and returns 200",
      f.load(c.parse_events) == (True, whole[1], False))
with open(sys.argv[3], "a") as fh:
    fh.write(json.dumps({"time": "2026-10-23T04:00:00Z", "kind": "close", "item": "1.4", "project": "demo", "result": "pass", "agent": "a", "legs": [], "detail": ""}) + "\n")
f.fetches = 1
since = f.since_for(whole[1])
part = f.load(c.parse_events, since)
check("po serve: the dashboard Feed takes a partial and merges it", since == "2026-10-23T03:00:00Z" and part[0] and part[2] is True
      and sorted(e["item"] for e in part[1]) == ["1.3", "1.4", "1.x"] and len(c.merge_since(whole[1], part[1])) == 5, (since, part))
with open(sys.argv[3], "w") as fh:
    fh.write("not json\n")
s, h, b = get(url)
check("po serve: a 502 error body carries no ETag", s == 502 and h.get("ETag") is None and h.get("X-Po-Since") is None, (s, h.get("ETag")))
print("BLOCK-END serve-conditional")
PY
	if command -v curl >/dev/null; then
		cp "$SV/events.json" "$SV/events-cond.json"
		out=$(curl -s -D - -o /dev/null "$SV_URL/events.json")
		grep -qi '^ETag: "' <<<"$out" && ok "the setup check: curl -s -D - -o /dev/null <serve-url>/events.json shows an ETag header" || bad "curl -D - ETag" "$out"
	fi
	sv_stop
fi

# Refusals and usage.
for a in 0.0.0.0 :: '[::]' 0; do
	out=$(cd "$SV/repo" && PATH="$SV/bin:$PATH" "$PO" serve --bind "$a" --port 0 2>&1)
	[[ $? == 1 ]] && grep -q 'refusing to bind' <<<"$out" && ok "--bind $a is refused" || bad "bind $a" "$out"
done
sv_start --bind ::1
if [[ -n $SV_URL ]]; then
	[[ $SV_URL == 'http://[::1]:'* ]] && [[ $(sv_req GET / | head -1) == 200 ]] && ok "--bind ::1 serves over IPv6" || bad "ipv6 bind" "$SV_URL"
	sv_stop
else
	ok "--bind ::1 skipped: no IPv6 loopback here"
fi
expect "serve rejects an unknown argument" 1 "serve: unknown argument" -- -C "$SV/repo" serve --nope
expect "serve --port needs a value" 1 "needs a value" -- -C "$SV/repo" serve --port
out=$(cd "$SV/repo" && PATH="$SV/bin:$PATH" "$PO" serve --port 99999 2>&1)
[[ $? == 1 ]] && ok "an out-of-range port is a usage error" || bad "port range" "$out"

# ---- the web view (v0.112): node tests, then /app/ served by a real po serve ----
if command -v node >/dev/null 2>&1; then
	block web-core env TZ=UTC node "$(dirname "$PO")/../tests/web-core.test.js"
else
	bad "web-core needs node" "node is not installed"
fi
WV=$TMP/webview
mkdir -p "$WV"
make_repo "$WV/repo"
block serve-web python3 -B -I - "$PO" "$WV" "$SV/bin" "$SV/events.json" "$SV/archive.json" <<'PY'
import json, os, re, subprocess, sys, threading, time, urllib.error, urllib.request
import http.server
po, wv, fakebin, events, archive = sys.argv[1:6]

def check(name, cond, detail=""):
    print("%s\t%s\t%s" % ("ok" if cond else "FAIL", name, str(detail).replace("\n", " | ")))

seen = []  # (path, headers) of each upstream request
class Up(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        seen.append((self.path, dict(self.headers)))
        if self.path.startswith("/down"):
            self.send_response(500); self.end_headers(); return
        if self.path.startswith("/notjson"):
            self.send_response(200); self.end_headers(); self.wfile.write(b"<html>"); return
        if self.headers.get("If-None-Match") == '"u1"':
            self.send_response(304); self.send_header("ETag", '"u1"'); self.end_headers(); return
        body = json.dumps([{"time": "2026-11-01T10:00:00Z", "item": "9"}]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json"); self.send_header("ETag", '"u1"')
        self.send_header("X-Po-Since", "partial" if "since=" in self.path else "full")
        self.send_header("Set-Cookie", "secret=1"); self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
up = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Up)
threading.Thread(target=up.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d" % up.server_address[1]
repo = os.path.join(wv, "repo")
with open(os.path.join(repo, "po.toml"), "a") as f:
    f.write('\n[serve.web]\ndecisions_url = "%s/dec.json"\nteam_url = "%s/down/team.json"\nprojects_url = "%s/notjson/p.json"\n'
            'events_url = "%s/ev.json"\nanswer_url = "http://sink.example:9000/answers"\nstall_minutes = 45\n' % (base, base, base, base))
env = dict(os.environ, PATH=fakebin + ":" + os.environ["PATH"], FAKE_EVENTS=events, FAKE_ARCHIVE=archive)
proc = subprocess.Popen([po, "serve", "--port", "0"], cwd=repo, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
line = proc.stdout.readline()
m = re.search(r"listening on (http://\S+)/", line)
if not m:
    check("po serve starts with [serve.web]", False, line + proc.stderr.read()); print("BLOCK-END serve-web"); sys.exit(0)
url = m.group(1)

def get(path, method="GET", hdr=None):
    req = urllib.request.Request(url + path, method=method, data=b"x" if method in ("POST", "PUT", "PATCH") else None, headers=hdr or {})
    try:
        r = urllib.request.urlopen(req, timeout=10)
    except urllib.error.HTTPError as e:
        r = e
    return r.status, r.headers, r.read().decode()

try:
    check("po serve starts with [serve.web] in po.toml", True)
    for p, ctype in (("/app/", "text/html"), ("/app/core.js", "text/javascript"), ("/app/app.js", "text/javascript"), ("/app/style.css", "text/css")):
        s, h, b = get(p)
        etag = h.get("ETag")
        s2, h2, b2 = get(p, hdr={"If-None-Match": etag or "-"})
        check("web: C2 %s is 200 with %s, a quoted ETag, and 304 on a match" % (p, ctype),
              s == 200 and h.get("Content-Type", "").startswith(ctype) and re.fullmatch(r'"[0-9a-f]{16}"', etag or "") is not None and s2 == 304 and b2 == "", (s, h.get("Content-Type"), etag, s2))
    s, h, b = get("/app/", hdr={"If-None-Match": '"stale"'})
    check("web: a stale If-None-Match gets the whole file", s == 200 and "<title>po</title>" in b, s)
    s, h, b = get("/app"); check("web: /app redirects to /app/", s == 200 and "<title>po</title>" in b, s)
    s, h, b = get("/app/nope.js"); check("web: an unknown /app/ file is 404", s == 404, s)
    s, h, b = get("/app/../lib/po/serve.py"); check("web: /app/ does not serve a path outside its four files", s == 404, s)
    s, h, b = get("/")
    check("web: C2 / is the gate-events page, unchanged", s == 200 and "Last 10 events" in b and "/app/" not in b, s)
    s, h, b = get("/all"); check("web: C2 /all is unchanged", s == 200 and "All events" in b, s)
    bad_methods = [(m_, p) for p in ("/app/", "/app/core.js", "/app/config.json", "/app/feeds/decisions.json") for m_ in ("POST", "PUT", "DELETE", "PATCH", "OPTIONS")
                   if get(p, m_)[0] != 405]
    check("web: C2 any non-GET on /app/* is 405", not bad_methods, bad_methods)
    s, h, b = get("/app/", "HEAD"); check("web: HEAD on /app/ is refused as read-only", s == 405, s)
    # C4: headers on every /app/ answer
    miss = []
    for p, m_ in (("/app/", "GET"), ("/app/core.js", "GET"), ("/app/config.json", "GET"), ("/app/feeds/decisions.json", "GET"), ("/app/feeds/team.json", "GET"), ("/app/nope", "GET"), ("/app/", "POST")):
        s, h, b = get(p, m_)
        csp = h.get("Content-Security-Policy", "")
        if not (csp.startswith("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'self' http://sink.example:9000;")
                and "base-uri 'none'" in csp and "form-action 'none'" in csp and "frame-ancestors 'none'" in csp
                and h.get("Referrer-Policy") == "no-referrer" and h.get("X-Content-Type-Options") == "nosniff"):
            miss.append((p, m_))
    check("web: C4 every /app/* answer carries the CSP (with the sink origin), Referrer-Policy and nosniff", not miss, miss)
    s, h, b = get("/events.json"); check("web: /events.json carries no CSP (unchanged)", s == 200 and "Content-Security-Policy" not in h, s)
    # C7
    s, h, b = get("/app/config.json")
    cfg = json.loads(b)
    check("web: C7 config.json lists the configured feeds, answer_url and stall_minutes, nothing else",
          s == 200 and set(cfg) == {"feeds", "answer_url", "stall_minutes"} and cfg["stall_minutes"] == 45 and cfg["feeds"] == ["decisions", "projects", "team", "events"] and cfg["answer_url"] == "http://sink.example:9000/answers", b)
    # C3
    del seen[:]
    s, h, b = get("/app/feeds/decisions.json?evil=http://x&since=1", hdr={"If-None-Match": '"old"', "Cookie": "a=b", "Authorization": "Bearer t", "X-Other": "1"})
    p, uh = seen[-1]
    check("web: C3 a feed is the configured URL's body, ETag and X-Po-Since", s == 200 and json.loads(b)[0]["item"] == "9" and h.get("ETag") == '"u1"' and h.get("X-Po-Since") == "full" and "Set-Cookie" not in h, (s, dict(h)))
    check("web: C3 only the configured path reaches the upstream, no query on a non-events feed", p == "/dec.json", p)
    low = {k.lower() for k in uh}
    check("web: C3 no request header but If-None-Match goes up (no cookie, authorization or custom header)",
          uh.get("If-None-Match") == '"old"' and not ({"cookie", "authorization", "x-other"} & low), sorted(low))
    s, h, b = get("/app/feeds/decisions.json", hdr={"If-None-Match": '"u1"'})
    check("web: C3 an upstream 304 is a 304 with the ETag and no body", s == 304 and b == "" and h.get("ETag") == '"u1"', (s, b))
    del seen[:]
    s, h, b = get("/app/feeds/events.json?since=2026-11-01T00:00:00Z&x=1")
    check("web: C3 only ?since= goes up on events, X-Po-Since comes down", s == 200 and seen[-1][0] == "/ev.json?since=2026-11-01T00%3A00%3A00Z" and h.get("X-Po-Since") == "partial", (seen[-1][0], dict(h)))
    s, h, b = get("/app/feeds/team.json")
    check("web: C3 an upstream error is 502 with {error}", s == 502 and "error" in json.loads(b), (s, b))
    s, h, b = get("/app/feeds/projects.json")
    check("web: C3 an upstream that is not JSON is 502 with {error}", s == 502 and "error" in json.loads(b), (s, b))
    s, h, b = get("/app/feeds/other.json"); check("web: C3 an unknown feed name is 404", s == 404, s)
    s, h, b = get("/app/feeds/decisions.json/../../etc/passwd"); check("web: a feed path with extra segments is 404", s == 404, s)
finally:
    proc.terminate(); proc.wait(); up.shutdown()

# a po serve with no [serve.web]: no feeds but its own events, read-only Decisions hidden, CSP without a sink
repo2 = os.path.join(wv, "repo2")
subprocess.run(["cp", "-a", repo, repo2], check=True)
toml = open(os.path.join(repo2, "po.toml")).read().split("\n[serve.web]")[0] + "\n"
open(os.path.join(repo2, "po.toml"), "w").write(toml)
proc = subprocess.Popen([po, "serve", "--port", "0"], cwd=repo2, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
m = re.search(r"listening on (http://\S+)/", proc.stdout.readline())
url = m.group(1)
try:
    s, h, b = get("/app/config.json")
    check("web: with no [serve.web] only the events view is offered and answer_url is null and stall_minutes is 30", json.loads(b) == {"feeds": ["events"], "answer_url": None, "stall_minutes": 30}, b)
    s, h, b = get("/app/feeds/events.json")
    check("web: with no events_url, events are po serve's own, with an ETag", s == 200 and len(json.loads(b)) == 12 and h.get("ETag"), (s, len(b)))
    s, h, b = get("/app/feeds/decisions.json"); check("web: an unconfigured feed is 404", s == 404, s)
    s, h, b = get("/app/")
    check("web: without answer_url the CSP is connect-src 'self' alone", "connect-src 'self'; base-uri" in h.get("Content-Security-Policy", ""), h.get("Content-Security-Policy"))
finally:
    proc.terminate(); proc.wait()
print("BLOCK-END serve-web")
PY
# a bad URL in [serve.web] is refused at start, and an unknown key is a manifest error
make_repo "$WV/repo3"
printf '\n[serve.web]\ndecisions_url = "ftp://x/y"\n' >>"$WV/repo3/po.toml"
out=$(cd "$WV/repo3" && PATH="$SV/bin:$PATH" "$PO" serve --port 0 2>&1)
[[ $? == 1 && $out == *"--decisions-url must be an http(s) URL"* ]] && ok "a non-http feed URL is refused at start" || bad "bad feed url" "$out"
printf '%s\n[serve.web]\nbogus_url = "http://x"\n' "$GOOD_MANIFEST" >"$WV/m2.toml"
expect "an unknown key in [serve.web] is a manifest error" 2 "unknown key 'bogus_url' in \[serve.web\]" -- -C "$WV/repo" --manifest "$WV/m2.toml" status

# ---- po team, the Team-view feed (item AR) ---------------------------------
TM=$TMP/team
mkdir -p "$TM/docs" "$TM/bin"
git init -q -b main "$TM"
git -C "$TM" config user.name t
git -C "$TM" config user.email t@example.invalid
cat >"$TM/docs/BACKLOG.md" <<'MD'
# Backlog

| Item | Status | Owner |
|---|---|---|
| v1.1 | DOING | Ada |
| v1.2 | PAUSED | Bo |
| v1.3 | DOING | Di |
| v1.4 | DONE | Ada |
| v1.5 | TODO | Cy |
MD
team_manifest() { # [extra [team] lines...]
	cat <<'TOML'
[versioning]
tag = "v{version}"

[layout]
backlog = "docs/BACKLOG.md"
specs_dir = "docs"
worktrees = ".wt"
branch = "item-v{version}"
owner_column = "Owner"

TOML
	if (($# > 0)); then
		printf '[team]\n'
		printf '%s\n' "$@"
		printf '\n'
	fi
	cat <<'TOML'
[[team.agent]]
name = "ada"
model = "Big Model (API)"
role = "dev"

[[team.agent]]
name = "bo"
role = "dev"

[[team.agent]]
name = "cy"

[[team.agent]]
name = "di"
model = "small-model (local GPU)"

[[team.agent]]
name = "ed"
TOML
}
team_manifest 'limits_file = "limits.json"' 'usage_file = "usage.json"' >"$TM/po.toml"
printf '{"ada": null, "di": "2099-01-01T15:30:00Z", "ghost": "2099-01-01T00:00:00Z"}\n' >"$TM/limits.json"
printf '{"ada": {"five_hour": 0.42, "seven_day": 0.18}, "di": {"five_hour": 1.0}}\n' >"$TM/usage.json"
git -C "$TM" add -A
git -C "$TM" commit -qm init
# The gate event log: ada 2 min ago, bo 40 min, cy and di 3 h; ed has none.
tev() { printf '{"time":"%s","kind":"stamp","item":"%s","project":"team","result":"pass","agent":"%s","legs":[],"detail":""}\n' \
	"$(date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%SZ)" "$2" "$3"; }
{
	tev "3 hours" 1.3 di
	tev "3 hours" 1.0 cy
	tev "40 minutes" 1.2 bo
	tev "2 minutes" 1.1 ada
} >"$TM/.git/po-events.jsonl"
tjson() { python3 -I -c '
import json, sys
d = json.load(sys.stdin)
a = {e["agent"]: e for e in d}
print(" ".join(str(x) for x in eval(sys.argv[1])))' "$1"; }
TJ=$("$PO" -C "$TM" team --json 2>&1)
[[ $(tjson 'list(a)' <<<"$TJ") == "ada bo cy di ed" ]] &&
	ok "team --json lists the roster in manifest order" || bad "team roster order" "$TJ"
[[ $(tjson '[a["ada"]["state"], a["ada"]["now"], a["ada"]["owns"], a["ada"]["free"]]' <<<"$TJ") == "WORKING 1.1 ['1.1'] False" ]] &&
	ok "team: an owner of a DOING item with a fresh event is WORKING, now names the item" || bad "team WORKING" "$TJ"
[[ $(tjson '[a["bo"]["state"], a["bo"]["now"], a["bo"]["owns"], a["bo"]["free"]]' <<<"$TJ") == "idle 40m None ['1.2'] True" ]] &&
	ok "team: idle 15+ minutes owning only a held item is idle and FREE" || bad "team held-only free" "$TJ"
[[ $(tjson '[a["cy"]["state"], a["cy"]["owns"], a["cy"]["free"]]' <<<"$TJ") == "idle 3h [] True" ]] &&
	ok "team: owning nothing (a TODO row is not owned) is FREE, idle in hours" || bad "team nothing owned" "$TJ"
[[ $(tjson '[a["di"]["state"], a["di"]["owns"], a["di"]["free"]]' <<<"$TJ") == "idle 3h ['1.3'] False" ]] &&
	ok "team: idle with a DOING item is not FREE" || bad "team DOING idle" "$TJ"
[[ $(tjson '[a["ed"]["state"], a["ed"]["free"]]' <<<"$TJ") == "idle never True" ]] &&
	ok "team: an agent with no events is idle never and FREE when it owns nothing" || bad "team no events" "$TJ"
[[ $(tjson '["model" in a["bo"], a["ada"]["model"], a["di"]["model"]]' <<<"$TJ") == "False Big Model (API) small-model (local GPU)" ]] &&
	ok "team: model comes from the roster, absent when not given" || bad "team model" "$TJ"
[[ $(tjson '[a["ada"]["limit_until"], a["ada"]["usage"], a["di"]["limit_until"], a["di"]["usage"], "limit_until" in a["bo"], "usage" in a["bo"], "ghost" in a]' <<<"$TJ") == "None {'five_hour': 0.42, 'seven_day': 0.18} 2099-01-01T15:30:00Z {'five_hour': 1.0} False False False" ]] &&
	ok "team: limits_file and usage_file are merged by agent name" || bad "team merge" "$TJ"
out=$("$PO" -C "$TM" team 2>&1)
[[ $out == AGENT*STATE* && $out == *ada*WORKING*1.1* && $out == *bo*'idle 40m'* ]] &&
	ok "team prints a table without --json" || bad "team table" "$out"
team_manifest 'limits_file = "no-such.json"' 'usage_file = "nor-this.json"' >"$TM/po.toml"
out=$("$PO" -C "$TM" team --json 2>&1)
[[ $out == *'"agent":"ada"'* && $out != *limit_until* && $out != *usage* && $out != *warning* ]] &&
	ok "team: a missing limits or usage file is ignored" || bad "team missing files" "$out"
printf 'not json\n' >"$TM/limits.json"
team_manifest 'limits_file = "limits.json"' >"$TM/po.toml"
out=$("$PO" -C "$TM" team --json 2>&1)
[[ $out == *'warning'*limits.json* && $out == *'"agent":"ada"'* && $out != *limit_until* ]] &&
	ok "team: an unreadable limits file warns and is left out" || bad "team broken limits" "$out"
team_manifest >"$TM/po.toml"
before=$(git -C "$TM" status --porcelain; cat "$TM/.git/po-events.jsonl")
"$PO" -C "$TM" team >/dev/null 2>&1
[[ $before == "$(git -C "$TM" status --porcelain; cat "$TM/.git/po-events.jsonl")" ]] &&
	ok "team is read-only" || bad "team wrote"
expect "team rejects an unknown argument" 1 "team: unknown argument" -- -C "$TM" team --nope
sed '/^\[\[team.agent\]\]/,$d' "$TM/po.toml" >"$TMP/team-none.toml"
expect "team without a roster is an error" 2 'no \[\[team.agent\]\]' -- -C "$TM" --manifest "$TMP/team-none.toml" team
{ cat "$TM/po.toml"; printf '[[team.agent]]\nname = "ada"\n'; } >"$TMP/team-dup.toml"
expect "a duplicate roster name is a manifest error" 2 "name 'ada' appears twice" -- -C "$TM" --manifest "$TMP/team-dup.toml" team
{ cat "$TM/po.toml"; printf '[[team.agent]]\nmodel = "x"\n'; } >"$TMP/team-noname.toml"
expect "a roster entry without a name is a manifest error" 2 'needs a non-empty "name"' -- -C "$TM" --manifest "$TMP/team-noname.toml" team
{ cat "$TM/po.toml"; printf '[[team.agent]]\nname = "zed"\nsize = "big"\n'; } >"$TMP/team-key.toml"
expect "an unknown roster key is a manifest error" 2 "unknown key 'size' in \[\[team.agent\]\]" -- -C "$TM" --manifest "$TMP/team-key.toml" team
# po serve exposes it at /team.json (real po, found on PATH as `po`).
ln -sf "$PO" "$TM/bin/po"
(cd "$TM" && PATH="$TM/bin:$PATH" exec "$PO" serve --port 0 >"$TM/out" 2>"$TM/err") &
TM_PID=$!
TM_URL=
for _ in $(seq 1 100); do
	TM_URL=$(sed -nE 's/^po serve: listening on (http:\/\/[^ ]+)\/$/\1/p' "$TM/out")
	[[ -n $TM_URL ]] && break
	kill -0 "$TM_PID" 2>/dev/null || break
	sleep 0.1
done
if [[ -n $TM_URL ]]; then
	# helper
	out=$(python3 -I - "$TM_URL/team.json" <<'PY'
import json, sys, urllib.request
r = urllib.request.urlopen(sys.argv[1], timeout=10)
d = json.load(r)
print(r.status, [e["agent"] for e in d], d[0]["state"])
PY
)
	[[ $out == "200 ['ada', 'bo', 'cy', 'di', 'ed'] WORKING" ]] &&
		ok "po serve serves the feed at /team.json" || bad "/team.json" "$out"
	kill "$TM_PID" 2>/dev/null
	wait "$TM_PID" 2>/dev/null
else
	bad "po serve (team) starts" "$(cat "$TM/out" "$TM/err")"
fi

# ---- the desktop viewer (item N) -------------------------------------------
# The logic is lib/po/dashboard_core.py (no GTK); bin/po-dashboard draws it.
DB="$(dirname "$PO")/po-dashboard"
DBLIB="$(dirname "$PO")/../lib/po"
export PO_DASHBOARD_TEAM_ORDER="$TMP/no-team-order.json"  # never the tester's own saved order
unset PO_DASHBOARD_DECISIONS_URL  # never the tester's own decisions feed
block dashboard-core python3 -B -I - "$DBLIB" <<'PY'
import datetime, http.server, json, os, subprocess, sys, tempfile, threading
sys.path.insert(0, sys.argv[1])
import dashboard_core as c
import dashboard_reports as r

def check(name, cond, detail=""):
    print("%s\t%s\t%s" % ("ok" if cond else "FAIL", name, detail.replace("\n", " | ")))

KEYS = ("time", "kind", "item", "project", "result", "agent", "legs", "detail")
ev = [{"time": "2026-10-23T%02d:00:00Z" % i, "kind": "stamp", "item": "1.%d" % i, "project": "demo",
       "result": "pass" if i % 4 else "fail", "agent": "dev%d" % i,
       "legs": [{"name": "lint", "result": "pass"}, {"name": "test", "result": "pass" if i % 4 else "fail"}],
       "detail": "d%d" % i} for i in range(12)]
ev[5]["item"] = None
ev[6].update(kind="open", legs=[])
lines = "".join(json.dumps({k: e[k] for k in KEYS}) + "\n" for e in ev)

check("dashboard: one object per line is parsed", len(c.parse_events(lines)) == 12)
check("dashboard: a JSON array is parsed", len(c.parse_events(json.dumps(ev))) == 12)
check("dashboard: one lone object is one event", len(c.parse_events(json.dumps(ev[0]))) == 1)
check("dashboard: empty input is no events", c.parse_events("  \n") == [])
try:
    c.parse_events("not json\n")
    check("dashboard: bad JSON is a DashboardError", False)
except c.DashboardError as e:
    check("dashboard: bad JSON is a DashboardError", "not JSON" in str(e))
try:
    c.parse_events('"text"')
    check("dashboard: JSON that is not a list is refused", False)
except c.DashboardError:
    check("dashboard: JSON that is not a list is refused", True)
check("dashboard: non-object entries are dropped", len(c.parse_events('[1, {"time": "x"}, null]')) == 1)

shuffled = ev[::-1][6:] + ev[::-1][:6]
check("dashboard: sorted newest first", [e["time"] for e in c.sort_events(shuffled)] == sorted((e["time"] for e in ev), reverse=True))
same = [{"time": "t", "item": "a"}, {"time": "t", "item": "b"}]
check("dashboard: equal times keep the source order", [e["item"] for e in c.sort_events(same)] == ["a", "b"])
check("dashboard: the default view is the last 10", len(c.visible(ev, False)) == 10 and c.visible(ev, False)[0]["item"] == "1.11")
check("dashboard: Show all lists every event", len(c.visible(ev, True)) == 12)
_now = c.parse_time("2026-10-25T12:00:00Z")
_re = [{"time": "2026-10-25T11:00:00Z"}, {"time": "2026-10-22T12:00:00Z"}, {"time": "2026-09-30T12:00:00Z"}, {"time": "junk"}, {}]
check("dashboard reports: ranges are 24 h, 7 d, 30 d with 7 d the default", [r[0] for r in c.REPORT_RANGES] == ["24 h", "7 d", "30 d"] and c.REPORT_RANGES[c.REPORT_DEFAULT][0] == "7 d")
check("dashboard reports: 24 h keeps only the last day", len(c.in_range(_re, 86400, _now)) == 1)
check("dashboard reports: 7 d keeps the last week", len(c.in_range(_re, 7 * 86400, _now)) == 2)
check("dashboard reports: 30 d keeps the last month, unreadable times left out", len(c.in_range(_re, 30 * 86400, _now)) == 3)
check("dashboard reports: empty-state text and five charts", c.REPORT_EMPTY == "no events in this range" and len(c.REPORT_CHARTS) == 5)

# The report charts' data (dashboard_reports.py): buckets, empty, one agent, ranges.
def _st(t, agent="a", result="pass", item="1", project="p", kind="stamp"):
    return {"time": t, "kind": kind, "agent": agent, "result": result, "item": item, "project": project}
_n = c.parse_time("2026-10-25T12:30:00Z")
check("dashboard reports: 24 h is 24 hourly buckets ending in the current hour", len(r.bucket_starts(86400, _n)) == 24 and r.bucket_starts(86400, _n)[-1] == c.parse_time("2026-10-25T12:00:00Z") and r.bucket_starts(86400, _n)[0] == c.parse_time("2026-10-24T13:00:00Z"))
check("dashboard reports: 7 d and 30 d are 7 and 30 daily buckets from midnight", [len(r.bucket_starts(s, _n)) for s in (7 * 86400, 30 * 86400)] == [7, 30] and r.bucket_starts(7 * 86400, _n)[-1] == c.parse_time("2026-10-25T00:00:00Z"))
_g = r.gate_runs([_st("2026-10-25T12:10:00Z"), _st("2026-10-25T12:20:00Z", result="fail"), _st("2026-10-25T11:59:59Z", agent="b"),
                  _st("2026-10-25T12:05:00Z", kind="open"), _st("2026-10-23T12:00:00Z"), _st("junk"), _st("2026-10-26T00:00:00Z")], 86400, _n)
check("dashboard reports: gate runs split pass and fail in the right hour", _g["series"]["a"][-1] == (1, 1) and _g["series"]["b"][-2] == (1, 0) and _g["total"] == 3)
check("dashboard reports: gate runs ignore non-stamps, old, future and unreadable times", _g["total"] == 3 and _g["agents"] == ["a", "b"] and _g["hourly"] and _g["labels"][-1] == "12:00")
check("dashboard reports: 7 d gate runs bucket by day, labelled by date", r.gate_runs([_st("2026-10-23T12:00:00Z")], 7 * 86400, _n)["series"]["a"][-3] == (1, 0) and r.gate_runs([], 7 * 86400, _n)["labels"][-1] == "10-25")
check("dashboard reports: 30 d reaches back where 7 d does not", r.gate_runs([_st("2026-10-10T12:00:00Z")], 7 * 86400, _n)["total"] == 0 and r.gate_runs([_st("2026-10-10T12:00:00Z")], 30 * 86400, _n)["total"] == 1)
check("dashboard reports: empty feed gives empty data and text", r.gate_runs([], 86400, _n)["agents"] == [] and r.first_try([], 86400, _n)["rows"] == [] and r.closed([], 86400, _n)["total"] == 0
      and "none in this range" in r.first_try_text(r.first_try([], 86400, _n)) and "none in this range" in r.closed_text(r.closed([], 86400, _n)))
_o = r.gate_runs([_st("2026-10-25T12:10:00Z", agent="solo")], 86400, _n)
check("dashboard reports: one agent still draws the fail-rate chart", r.layout_fail_rate(r.fail_rate(_o), 600)[0] > 0)
_f = r.first_try([_st("2026-10-25T10:00:00Z", result="fail"), _st("2026-10-25T11:00:00Z"),
                  _st("2026-10-25T10:00:00Z", item="2"), _st("2026-10-25T10:00:00Z", item="3", project="q"),
                  _st("2026-10-25T10:00:00Z", agent="b", result="fail"), _st("2026-10-25T10:00:00Z", kind="close")], 86400, _n)
check("dashboard reports: first-try counts only the first stamp per project, item and agent", {x["agent"]: (x["n"], x["passed"]) for x in _f["rows"]} == {"a": (3, 2), "b": (1, 0)})
check("dashboard reports: first-try rate, best first", [x["agent"] for x in _f["rows"]] == ["a", "b"] and abs(_f["rows"][0]["rate"] - 2 / 3) < 1e-9)
check("dashboard reports: a first stamp before the range is not a first try inside it", r.first_try([_st("2026-10-01T10:00:00Z", result="fail"), _st("2026-10-25T10:00:00Z")], 86400, _n)["rows"] == [])
_c = r.closed([_st("2026-10-25T01:00:00Z", kind="close", project="x"), _st("2026-10-25T02:00:00Z", kind="close", project="x", item="2"), _st("2026-10-24T23:00:00Z", kind="close", project="y"),
               _st("2026-10-25T03:00:00Z", kind="close", project="y", result="fail"), _st("2026-10-25T03:00:00Z", project="y"), _st("2026-10-20T03:00:00Z", kind="close", project="y")], 86400, _n)
check("dashboard reports: closes per day by project, passing closes only, two days for 24 h", _c["labels"] == ["10-24", "10-25"] and _c["series"] == {"x": [0, 2], "y": [1, 0]} and _c["projects"] == ["x", "y"] and _c["total"] == 3)
check("dashboard reports: 7 d closes reach the older day", r.closed([_st("2026-10-20T03:00:00Z", kind="close", project="y")], 7 * 86400, _n)["total"] == 1 and len(r.closed([], 30 * 86400, _n)["labels"]) == 30)
check("dashboard reports: a time zone moves the day boundary", r.closed([_st("2026-10-25T02:00:00Z", kind="close")], 86400, _n, datetime.timezone(datetime.timedelta(hours=-4)))["series"]["p"] == [1, 0])
check("dashboard reports: events with no agent or project are 'unknown'", r.gate_runs([{"time": "2026-10-25T12:10:00Z", "kind": "stamp", "result": "pass"}], 86400, _n)["agents"] == ["unknown"])
check("dashboard reports: the text alternative carries the numbers", "a 67\u00a0% of 3 items, too few to rank" in r.first_try_text(_f) and "3 in all; x 2; y 1" in r.closed_text(_c))
check("dashboard reports: charts() gives the five charts in order with text", [x["topic"] for x in r.charts([], 86400, _n)] == list(c.REPORT_CHARTS) and all(x["text"] for x in r.charts([], 86400, _n)))
def _lg(t, legs, **k):
    e = _st(t, **k)
    e["legs"] = [{"name": n, "result": x} for n, x in legs]
    return e
_ct = [_st("2026-10-25T08:00:00Z", kind="open", agent="po"), _st("2026-10-25T09:00:00Z", agent="a"), _st("2026-10-25T10:00:00Z", kind="close", agent="po"),
       _st("2026-10-25T08:00:00Z", kind="open", item="2", agent="po"), _st("2026-10-25T09:00:00Z", item="2", agent="a"), _st("2026-10-25T12:00:00Z", kind="close", item="2", agent="po"),
       _st("2026-10-25T07:00:00Z", kind="open", item="3", agent="po"), _st("2026-10-25T09:00:00Z", item="3", agent="b"), _st("2026-10-25T09:30:00Z", kind="close", item="3", agent="po"),
       _st("2026-10-25T08:00:00Z", kind="open", item="4", agent="po"), _st("2026-10-25T09:00:00Z", item="4", agent="a"),
       _st("2026-10-25T09:00:00Z", kind="close", item="5", agent="po"),
       _st("2026-10-25T08:00:00Z", kind="open", item="6", agent="po"), _st("2026-10-25T09:00:00Z", kind="close", item="6", agent="po", result="fail")]
_t = r.cycle_time(_ct, 86400, _n)
_ar = {x["agent"]: x for x in _t["rows"]}
check("dashboard reports: cycle time is open to close per agent, five numbers and n", _ar["a"]["n"] == 2 and _ar["a"]["min"] == 7200 and _ar["a"]["max"] == 14400 and _ar["a"]["median"] == 10800 and _ar["a"]["q1"] == 9000 and _ar["a"]["q3"] == 12600 and _ar["b"]["n"] == 1 and _ar["b"]["min"] == _ar["b"]["max"] == 9000)
check("dashboard reports: cycle time leaves out unclosed, failed-close and open-less items", sum(x["n"] for x in _t["rows"]) == 3)
check("dashboard reports: cycle time rows run longest median first and the unit fits", [x["agent"] for x in _t["rows"]] == ["a", "b"] and _t["unit"] == "hour" and r.cycle_time([], 86400, _n) == {"rows": [], "unit": "minute", "n": 0, "median": None})
check("dashboard reports: cycle time counts a close only inside the range", r.cycle_time(_ct, 600, _n)["rows"] == [] and len(r.cycle_time(_ct, 3600, _n)["rows"]) == 1 and r.cycle_time([_st("2026-10-01T08:00:00Z", kind="open"), _st("2026-10-25T12:00:00Z", kind="close")], 86400, _n)["rows"][0]["n"] == 1)
check("dashboard reports: cycle time falls back to the close event's agent without a stamp", r.cycle_time([_st("2026-10-25T08:00:00Z", kind="open"), _st("2026-10-25T08:10:00Z", kind="close", agent="po")], 86400, _n)["rows"][0]["agent"] == "po")
_fl = r.failed_legs([_lg("2026-10-25T12:10:00Z", [("lint", "pass"), ("test", "fail")]), _lg("2026-10-25T12:20:00Z", [("test", "fail"), ("fmt", "fail")], result="fail"),
                     _lg("2026-10-25T11:10:00Z", [("test", "fail")]), _lg("2026-10-20T11:10:00Z", [("test", "fail")]), _st("2026-10-25T12:00:00Z"),
                     {"time": "2026-10-25T12:00:00Z", "legs": "junk"}], 86400, _n)
check("dashboard reports: failed legs count only failing legs, per name and hour", _fl["legs"] == ["test", "fmt"] and _fl["series"]["test"][-1] == 2 and _fl["series"]["test"][-2] == 1 and _fl["series"]["fmt"][-1] == 1 and _fl["total"] == 4 and _fl["hourly"])
_seven = r.failed_legs([_lg("2026-10-25T12:10:00Z", [("l%d" % i, "fail")] * (9 - i)) for i in range(8)], 86400, _n)
check("dashboard reports: v0.143 past three leg names the rest group as other, last", len(_seven["legs"]) == 4 and _seven["legs"][-1] == "other" and _seven["legs"][:3] == ["l0", "l1", "l2"] and sum(_seven["series"]["other"]) == 6 + 5 + 4 + 3 + 2 and _seven["total"] == sum(9 - i for i in range(8)))
check("dashboard reports: failed legs bucket daily for 7 d and are empty without failures", r.failed_legs([_lg("2026-10-23T12:00:00Z", [("t", "fail")])], 7 * 86400, _n)["series"]["t"][-3] == 1 and r.failed_legs([_st("2026-10-25T12:00:00Z")], 86400, _n)["total"] == 0)
check("dashboard reports: the new charts' text alternatives carry the numbers", "a 2 items, median 3.0 h" in r.cycle_time_text(_t) and "4 in all; test 3; fmt 1" in r.failed_legs_text(_fl) and "none in this range" in r.cycle_time_text(r.cycle_time([], 86400, _n)) and "none in this range" in r.failed_legs_text(r.failed_legs([], 86400, _n)))
_cs = r.layout_cycle_time(_t, 640)[1] + r.layout_failed_legs(_fl, 640)[1] + r.layout_failed_legs(_seven, 640)[1]
check("dashboard reports: cycle time shows the median and n as text and boxes for each agent", any(s[0] == "text" and s[3] == "3.0 h  n=2" for s in _cs) and sum(1 for s in r.layout_cycle_time(_t, 640)[1] if s[0] == "rect" and s[5] == "edge") == 2)
check("dashboard reports: other is hatched muted, and no leg takes a project's colour", any(s[0] == "rect" and s[5] == "muted" and s[6] for s in r.layout_failed_legs(_seven, 640)[1]) and not any(s[0] == "rect" and isinstance(s[5], tuple) and s[5][0] == "series" for s in r.layout_failed_legs(_seven, 640)[1]))
check("dashboard reports: new charts stay inside the width", all(s[1] >= 0 and s[1] + (s[3] if s[0] == "rect" else 0) <= 640 + 1e-6 for s in _cs if s[0] in ("rect", "line")))
check("dashboard reports: nice axis tops sit just above the value", [r.nice_max(v) for v in (0, 1, 3, 7, 11, 20, 21, 51, 101)] == [1, 1, 3, 8, 12, 20, 24, 60, 120])
# v0.141 (8): the cycle-time unit comes from the medians (hours while every median is under a day), not from the one
# longest item; ticks run from 0 to the end of the range in steps of whole days of hours
def _cy(agent, item, hours):
    return [_st("2026-10-20T00:00:00Z", kind="open", item=item, agent="po"), _st("2026-10-20T00:30:00Z", item=item, agent=agent),
            {"time": (c.parse_time("2026-10-20T00:00:00Z") + datetime.timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             "kind": "close", "result": "pass", "item": item, "project": "p", "agent": "po"}]
_cyev = _cy("ana", "1", 2) + _cy("ana", "2", 3) + _cy("ana", "3", 108) + _cy("bo", "4", 1.5) + _cy("cy", "5", 0.75) + _cy("cy", "6", 5)
_cyt = r.cycle_time(_cyev, 7 * 86400, c.parse_time("2026-10-25T12:00:00Z"))
check("dashboard reports: v0.141 cycle time medians under a day give the hour unit despite a 4.5 d item", _cyt["unit"] == "hour", _cyt["unit"])
_cyx = r.cycle_time_text(_cyt)
check("dashboard reports: v0.141 cycle time medians read in hours, never 0.0 d",
      "ana 3 items, median 3.0 h" in _cyx and "bo 1 item, median 1.5 h" in _cyx and "cy 2 items, median 2.9 h" in _cyx and "0.0 d" not in _cyx, _cyx)
_cyl = r.layout_cycle_time(_cyt, 640)[1]
_tk = [s[3] for s in _cyl if s[0] == "text" and s[4] == "muted" and s[5] == "middle"]
check("dashboard reports: v0.141 cycle time ticks run 0 to 120 h (the 5 d range) a day apart", _tk == ["0", "24 h", "48 h", "72 h", "96 h", "120 h"], str(_tk))
check("dashboard reports: v0.141 cycle time row values are hours too", any(s[0] == "text" and s[3] == "3.0 h  n=3" for s in _cyl), str([s[3] for s in _cyl if s[0] == "text"]))
check("dashboard reports: v0.141 a median of a day or more gives days; a short chart stays in minutes",
      r.cycle_unit([{"median": 86400, "max": 86400}]) == "day" and r.cycle_unit([{"median": 600, "max": 3600}]) == "minute"
      and r.cycle_unit([{"median": 600, "max": 3 * 3600}]) == "hour" and r.cycle_unit([]) == "minute")
check("dashboard reports: v0.141 axis ticks: hours step by whole parts of a day, the end a whole number of steps",
      [r.axis_ticks(t, u) for t, u in ((108, "hour"), (7, "hour"), (4.5, "day"), (90, "minute"))] == [(120, 24), (8, 2), (5, 1), (90, 15)])
_hid = r.fail_rate(r.gate_runs([_st("2026-10-25T12:10:00Z"), _st("2026-10-25T12:20:00Z", result="fail"), _st("2026-10-25T09:10:00Z", agent="b")], 86400, _n))
_hs = r.layout_fail_rate(_hid, 640)[1]
check("dashboard reports: v0.143 the fail rate per hour is failed over all runs, an hour with no run None",
      _hid["rates"][-1] == 0.5 and _hid["rates"][-4] == 0 and _hid["rates"][-2] is None and _hid["rate"] == 1 / 3, str(_hid["rates"][-4:]))
_brk = r.layout_fail_rate(r.fail_rate(r.gate_runs([_st("2026-10-25T09:10:00Z"), _st("2026-10-25T10:10:00Z", result="fail"), _st("2026-10-25T12:10:00Z")], 86400, _n)), 640)[1]
check("dashboard reports: v0.143 the fail-rate line breaks at an hour with no run: one 2-point line, a lone point after the gap",
      [len(s[1]) for s in _brk if s[0] == "path" and s[2] == "fail" and s[1][0][0] >= r.AXIS_W + r.PAD] == [2]
      and sum(1 for s in _brk if s[0] == "rect" and s[5] == "fail") == 3)
check("dashboard reports: v0.143 the fail rate says what a point is", any(s[0] == "text" and s[3] == "each point = one hour; an hour with no run is a gap" for s in _hs)
      and any(s[0] == "text" and s[3] == "each point = one day; a day with no run is a gap" for s in r.layout_fail_rate(r.fail_rate(r.gate_runs([_st("2026-10-23T12:00:00Z")], 7 * 86400, _n)), 640)[1]))
_cl = r.layout_closed(_c, 640)[1]
check("dashboard reports: closed per day hides empty days, labels bars and says how many were hidden", any(s[0] == "text" and s[3] == "each bar = one day" for s in _cl) and not any(s[0] == "text" and "hidden" in s[3] for s in _cl)
      and any(s[0] == "text" and s[3] == "29 empty days hidden" for s in r.layout_closed(r.closed([_st("2026-10-25T01:00:00Z", kind="close")], 30 * 86400, _n), 640)[1])
      and any(s[0] == "text" and s[3] == "1 empty day hidden" for s in r.layout_closed(r.closed([_st("2026-10-25T01:00:00Z", kind="close")], 86400, _n), 640)[1]))
_fh = r.layout_failed_legs(r.failed_legs([_lg("2026-10-25T12:10:00Z", [("t", "fail")])], 86400, _n), 640)[1]
check("dashboard reports: failed legs hide empty hours, label the bar and count it above", any(s[0] == "text" and s[3] == "23 empty hours hidden" for s in _fh) and any(s[0] == "text" and s[3] == "12" and s[5] == "middle" and s[4] == "muted" for s in _fh) and any(s[0] == "text" and s[3] == "1" and s[4] == "text" for s in _fh))
check("dashboard reports: charts with nothing to draw stay empty", r.layout_fail_rate(r.fail_rate(r.gate_runs([], 86400, _n)), 640)[0] > 0
      and not any(s[0] == "rect" for s in r.layout_fail_rate(r.fail_rate(r.gate_runs([], 86400, _n)), 640)[1])
      and r.layout_closed(r.closed([], 86400, _n), 640)[0] > 0 and r.layout_failed_legs(r.failed_legs([], 86400, _n), 640)[0] > 0)
_tall = r.layout_closed(r.closed([_st("2026-10-25T%02d:00:00Z" % h, kind="close", item=str(h)) for h in range(11)], 86400, _n), 640)[1]
check("dashboard reports: the axis top is the closer round step above the tallest bar", any(s[0] == "text" and s[3] == "12" and s[4] == "muted" and s[5] == "end" for s in _tall))
_shapes = r.layout_first_try(_f, 640)[1]
check("dashboard reports: v0.143 a not-ranked first-try row is hatched muted, a ranked one solid, so colour is not the only cue",
      any(s[0] == "rect" and s[5] == "muted" and s[6] for s in _shapes) and any(s[0] == "rect" and s[5] == "pass" and not s[6] for s in r.layout_first_try(r.first_try([_st("2026-10-25T10:00:00Z", item=str(i)) for i in range(5)], 86400, _n), 640)[1]))
check("dashboard reports: first-try rows carry the share and n as text", any(s[0] == "text" and s[3] == "67\u00a0%  n=3" for s in r.layout_first_try(_f, 640)[1]))
check("dashboard reports: shapes stay inside the width", all(s[1] >= 0 and s[1] + (s[3] if s[0] == "rect" else 0) <= 640 + 1e-6 for s in r.layout_fail_rate(r.fail_rate(_g), 640)[1] + r.layout_closed(_c, 640)[1] if s[0] in ("rect", "line"))
      and all(0 <= x <= 640 for s in r.layout_fail_rate(r.fail_rate(_g), 640)[1] if s[0] == "path" for x, _y in s[1]))
_many = r.closed([_st("2026-10-25T01:00:00Z", kind="close", project="p%d" % i) for i in range(8)], 86400, _n)
check("dashboard reports: a project past the palette reuses a colour hatched", r.series_colour(0) == (("series", 0), False) and r.series_colour(5) == (("series", 0), True) and len(r.layout_closed(_many, 400)[1]) > 8)
for _v, _p in sorted(c.PALETTES.items()):
    _lo = min(c.contrast_ratio(x, _p["base"]) for x in _p["series"] + _p["legs"] + [_p["pass"], _p["fail"]])
    check("dashboard reports %s: chart colours reach 3:1 against the base (%.2f)" % (_v, _lo), _lo >= 3 and len(_p["series"]) == r.SERIES_COLOURS)
    _steps = [abs(c.lightness(x) - c.lightness(y)) for k in ("series", "legs") for i, x in enumerate(_p[k]) for y in _p[k][i + 1:]]
    check("dashboard reports %s: v0.143 series and leg colours differ in lightness by %s L* or more, so greyscale still reads (least %.1f)" % (_v, c.CHART_LIGHTNESS_STEP, min(_steps)),
          min(_steps) >= c.CHART_LIGHTNESS_STEP and len(_p["legs"]) == r.LEG_SHADES and not set(_p["legs"]) & set(_p["series"]))
    check("dashboard reports %s: v0.143 ink inside a segment is black or white, whichever reads, at 4.5:1" % _v,
          all(c.contrast_ratio(c.chart_colour(_v, ("ink", ("series", i))), _p["series"][i]) >= 4.5 for i in range(r.SERIES_COLOURS))
          and c.chart_colour(_v, ("legs", 0)) == _p["legs"][0] and c.chart_colour(_v, "muted") == _p["muted"])
# v0.143: Reports redesign. A fixture of two 7 d periods: the range ending _hn and the 7 days before it.
_hn = c.parse_time("2026-10-25T12:30:00Z")
def _at(days_ago, hour=10):
    return (_hn - datetime.timedelta(days=days_ago)).replace(hour=hour, minute=0).strftime("%Y-%m-%dT%H:%M:%SZ")
_two = ([_st(_at(1), item="1"), _st(_at(1, 11), item="2", result="fail"), _st(_at(2), item="3"), _st(_at(2, 11), item="3"),
         _st(_at(1, 12), kind="close", project="x"), _st(_at(2, 12), kind="close", project="y", item="3")]
        + [_st(_at(9), item="9"), _st(_at(9, 11), item="8"), _st(_at(10), item="7", result="fail"), _st(_at(10, 11), item="6", result="fail"),
           _st(_at(9, 12), kind="close", project="x", item="9")])
_hd = {t["key"]: t for t in r.headline(_two, 7 * 86400, _hn)}
check("dashboard reports: v0.143 headline: four numbers, gate runs, fail rate, first try, closed, in that order",
      [t["label"] for t in r.headline(_two, 7 * 86400, _hn)] == ["gate runs", "fail rate", "first try", "closed"]
      and (_hd["runs"]["text"], _hd["fail"]["text"], _hd["first"]["text"], _hd["closed"]["text"]) == ("4", "25 %", "67 %", "2"),
      str([(t["key"], t["text"]) for t in _hd.values()]))
check("dashboard reports: v0.143 headline: each number has the previous period beside it, in words and an arrow",
      _hd["runs"]["change"] == "same as the previous 7 d (4)" and _hd["fail"]["change"] == "▼ down 25 points from 50 %, previous 7 d"
      and _hd["first"]["change"] == "▲ up 17 points from 50 %, previous 7 d" and _hd["closed"]["change"] == "▲ up 1 from 1, previous 7 d",
      str([t["change"] for t in _hd.values()]))
_one = [e for e in _two if c.parse_time(e["time"]) > _hn - datetime.timedelta(days=7)]
check("dashboard reports: v0.143 headline: an empty previous period says no previous period",
      all(t["change"] == "no previous period" and t["previous"] is None for t in r.headline(_one, 7 * 86400, _hn)))
check("dashboard reports: v0.143 headline: events that do not reach back (covered False) give no previous period either",
      all(t["change"] == "no previous period" for t in r.headline(_two, 7 * 86400, _hn, covered=False)))
check("dashboard reports: v0.143 headline: a rate with nothing to divide reads in words", [t["text"] for t in r.headline([], 86400, _hn)] == ["0", "no runs", "no items", "0"])
check("dashboard reports: v0.143 report_reach reads the range and its previous period", c.report_reach(7 * 86400) == 14 * 86400)
_ch = r.charts(_two, 7 * 86400, _hn, tz=datetime.timezone.utc)
check("dashboard reports: v0.143 titles state the finding", [x["title"] for x in _ch] == [
      "Fail rate fell to 25 %", "First-try rate rose to 67 %", "2 items closed, most in x (1)",
      "No items closed with an open event in this range", "No failed legs in this range"], str([x["title"] for x in _ch]))
check("dashboard reports: v0.143 a title says held at, and was with no previous period",
      r._trend("Fail rate", 0.25, 0.25, r.pct) == "Fail rate held at 25 %" and r._trend("Fail rate", 0.25, None, r.pct) == "Fail rate was 25 %")
check("dashboard reports: v0.143 every chart's text alternative carries its title, the previous period, the source and as of",
      all(x["text"].startswith(x["title"] + ".") and (x["context"].startswith("Previous 7 d: ") or x["context"] == "No previous period.") and x["context"] in x["text"]
          and "Source: po gate event log" in x["text"] and "as of 12:30 PM UTC" in x["text"] for x in _ch)
      and _ch[0]["context"] == "Previous 7 d: 50 % of 4 runs failed." and _ch[2]["context"] == "Previous 7 d: 1 closed.", str([x["text"] for x in _ch][:1]))
check("dashboard reports: v0.143 with no previous period every chart says so",
      all(x["context"] == "No previous period." and "No previous period." in x["text"] for x in r.charts(_one, 7 * 86400, _hn)))
# first try: n < 5 not ranked, a team average, the previous period, the roster
_ft = r.first_try([_st("2026-10-25T10:00:00Z", agent="ana", item=str(i), result="pass" if i else "fail") for i in range(6)]
                  + [_st("2026-10-25T10:00:00Z", agent="lo", item="x")] + [_st("2026-10-25T10:00:00Z", agent="zed", item="y", result="fail")], 86400, _n)
check("dashboard reports: v0.143 first-try has a team average over every row", _ft["n"] == 8 and _ft["passed"] == 6 and _ft["team"] == 0.75)
_ftl = r.layout_first_try(dict(_ft, previous={"ana": 0.5}, team_previous=0.6), 640)[1]
_ftx = [s[3] for s in _ftl if s[0] == "text"]
check("dashboard reports: v0.143 first-try ranks n >= 5 first, then n < 5 under a 'not ranked' line, hatched",
      _ftx.index("ana") < _ftx.index("fewer than 5 items, not ranked") < _ftx.index("lo")
      and any(s[0] == "rect" and s[5] == "muted" and s[6] for s in _ftl) and r.MIN_N == 5, str(_ftx))
check("dashboard reports: v0.143 first-try draws the team average as a dashed line through the rows, labelled with the previous period",
      "team average 75 %, was 60 %" in _ftx and any(s[0] == "path" and s[4] and s[1][0][0] == s[1][1][0] for s in _ftl))
check("dashboard reports: v0.143 first-try shows an agent's previous rate as words and a tick",
      "83 %  n=6 · was 50 %" in _ftx and any(s[0] == "rect" and s[5] == "text" and s[3] == 2 for s in _ftl), str(_ftx))
check("dashboard reports: v0.143 with the Team roster, the owner's own stamps (zed) are no agent's row",
      [x["agent"] for x in r.first_try([_st("2026-10-25T10:00:00Z", agent="zed", item="y"), _st("2026-10-25T10:00:00Z", agent="ana")], 86400, _n, agents={"ana", "lo"})["rows"]] == ["ana"]
      and "zed" in [x["agent"] for x in _ft["rows"]])
check("dashboard reports: v0.143 the text alternative marks the agents too few to rank and gives the average",
      "lo 100 % of 1 item, too few to rank" in r.first_try_text(_ft) and r.first_try_text(_ft).endswith("team average 75 %."))
# fixed project colours and labelled segments
_pc = [_st("2026-10-25T01:00:00Z", kind="close", project=p, item=p) for p in ("zeta", "alpha", "mid")] + [_st("2026-10-10T01:00:00Z", project="beta")]
def _swatches(data):
    sh = r.layout_closed(data, 640)[1]
    return {sh[k + 1][3].split()[0]: sh[k][5] for k in range(len(sh) - 1) if sh[k][0] == "rect" and sh[k][3] == 12 and sh[k + 1][0] == "text"}
_s1 = _swatches(dict(r.closed(_pc, 86400, _n), colours=r.project_colours(_pc)))
_s2 = _swatches(dict(r.closed(_pc[:1], 30 * 86400, _n), colours=r.project_colours(list(reversed(_pc)))))
check("dashboard reports: v0.143 a project keeps its colour between two renders, whatever the range, order or other closes",
      r.project_colours(_pc) == {"alpha": 0, "beta": 1, "mid": 2, "zeta": 3} and _s1["zeta"] == _s2["zeta"] == ("series", 3) and _s1["alpha"] == ("series", 0), str((_s1, _s2)))
_big = r.layout_closed(dict(r.closed([_st("2026-10-25T%02d:00:00Z" % h, kind="close", project="x", item=str(h)) for h in range(9)]
                                     + [_st("2026-10-25T10:30:00Z", kind="close", project="y")], 86400, _n), colours={"x": 0, "y": 1}), 640)[1]
check("dashboard reports: v0.143 the biggest segment carries its count inside, the legend gives each total and share",
      any(s[0] == "text" and s[3] == "9" and s[4] == ("ink", ("series", 0)) for s in _big) and any(s[0] == "text" and s[3] == "x 9 (90 %)" for s in _big))
_lf = r.failed_legs([_lg("2026-10-25T12:10:00Z", [("test", "fail")] * 40 + [("lint", "fail")] * 2 + [("fmt", "fail")])], 86400, _n)
check("dashboard reports: v0.143 a leg under 5 % of failures folds into other; a lone leftover leg keeps its name",
      _lf["legs"] == ["test", "other"] and sum(_lf["series"]["other"]) == 3
      and r.failed_legs([_lg("2026-10-25T12:10:00Z", [("test", "fail")] * 40 + [("lint", "fail")])], 86400, _n)["legs"] == ["test", "lint"])
check("dashboard reports: v0.143 legs take the leg shades, never a project colour", [r.leg_colour(["a", "b", "other"], j) for j in range(3)] == [(("legs", 0), False), (("legs", 1), False), ("muted", True)])
_nar = r.layout_first_try(_ft, 300)[1] + r.layout_cycle_time(_t, 300)[1] + r.layout_fail_rate(r.fail_rate(_g), 300)[1] + r.layout_closed(_c, 300)[1]
check("dashboard reports: v0.143 on a narrow width rows put name and value above a full-width track, all inside the width",
      all(s[1] >= 0 and s[1] + (s[3] if s[0] == "rect" else 0) <= 300 + 1e-6 for s in _nar if s[0] in ("rect", "line"))
      and any(s[0] == "text" and s[3] == "ana  83 %  n=6" for s in _nar))
check("dashboard: fewer than 10 events show them all", len(c.visible(ev[:3], False)) == 3)

utc = datetime.timezone.utc
est = datetime.timezone(datetime.timedelta(hours=-4))
check("dashboard: time is shown in the given zone", c.local_time("2026-10-23T22:36:42Z", est) == "2026-10-23 18:36:42")
check("dashboard: an unparseable time is kept as text", c.local_time("soon", utc) == "soon")
check("dashboard: a missing time is empty", c.local_time(None, utc) == "")
r = c.row(ev[5], utc)
check("dashboard: item null is shown as -", r["item"] == "-")
check("dashboard: legs are name:result", c.row(ev[0], utc)["legs"] == "lint:pass test:fail")
check("dashboard: no legs is empty", c.row(ev[6], utc)["legs"] == "")
check("dashboard: kind is shown", c.row(ev[6], utc)["kind"] == "open")
check("dashboard: pass has a symbol and a word", c.row(ev[1], utc)["result"] == "✔ pass")
check("dashboard: fail has a symbol and a word", c.row(ev[0], utc)["result"] == "✘ fail" and c.row(ev[0], utc)["result_class"] == "fail")
check("dashboard: an unknown result keeps its word", c.row({"result": "weird"}, utc)["result"] == "– weird")
keys = [col[0] for col in c.COLUMNS]
check("dashboard: the columns are result item project kind checks agent took time", keys == ["result", "item", "project", "kind", "legs", "agent", "took", "time"])
check("dashboard: every column key is a row field", all(k in c.row(ev[0], utc) for k in keys))
check("dashboard: only project and checks grow", [col[0] for col in c.COLUMNS if col[4]] == ["project", "legs"])
check("dashboard: fixed columns are as wide as they may get", all(col[2] == col[3] for col in c.COLUMNS if not col[4]))
tl = {"detail": "why", "legs": [{"name": "a", "result": "pass"}, {"name": "b", "result": "fail", "tail": "x\ny"}], "log": "/g/po-logs/s.log"}
check("dashboard: a failed stamp's note adds the failing leg's tail and the log",
      c.row(tl, utc)["detail"] == "why\n\nleg b, last lines:\nx\ny\n\nfull output: /g/po-logs/s.log")
check("dashboard: a note is the detail, empty when there is none", c.row(ev[5], utc)["detail"] == "d5" and c.row({"detail": None}, utc)["detail"] == "" and c.row({}, utc)["detail"] == "")
check("dashboard: the note icon has a theme fallback", len(c.NOTE_ICONS) >= 2 and c.NOTE_FALLBACK)
check("dashboard: markup in a field stays text", c.row({"item": "<b>x</b>"}, utc)["item"] == "<b>x</b>")

check("dashboard: --url wins over the environment", c.resolve_url("http://a/x", {"PO_DASHBOARD_URL": "http://b"}) == "http://a/x")
check("dashboard: the environment is used without --url", c.resolve_url(None, {"PO_DASHBOARD_URL": "http://b/e"}) == "http://b/e")
for env, name in (({}, "dashboard: no URL is a clear error"), ({"PO_DASHBOARD_URL": " "}, "dashboard: a blank URL is a clear error")):
    try:
        c.resolve_url(None, env)
        check(name, False)
    except c.DashboardError as e:
        check(name, "PO_DASHBOARD_URL" in str(e) and "--url" in str(e))
for bad_url in ("file:///etc/passwd", "ftp://h/x", "notaurl"):
    try:
        c.resolve_url(bad_url, {})
        check("dashboard: %s is refused" % bad_url, False)
    except c.DashboardError:
        check("dashboard: %s is refused" % bad_url, True)

# The team view: feed parsing and the URL option/environment precedence.
team = [{"agent": "ada", "state": "WORKING", "now": "1.4", "owns": ["1.4", "1.5"], "free": False},
        {"agent": "bo", "state": "idle 22m", "now": None, "owns": [], "free": True}]
check("dashboard team: --team-url wins over the environment", c.resolve_team_url("http://a/t", {"PO_DASHBOARD_TEAM_URL": "http://b/t"}) == "http://a/t")
check("dashboard team: the environment is used without --team-url", c.resolve_team_url(None, {"PO_DASHBOARD_TEAM_URL": "http://b/t"}) == "http://b/t")
check("dashboard team: no option and no environment is no feed", c.resolve_team_url(None, {}) is None and c.resolve_team_url(" ", {"PO_DASHBOARD_TEAM_URL": " "}) is None)
check("dashboard team: a file:// feed is accepted", c.resolve_team_url("file:///tmp/t.json", {}) == "file:///tmp/t.json")
for bad_url in ("ftp://h/x", "no-such-file.json"):
    try:
        c.resolve_team_url(bad_url, {})
        check("dashboard team: %s is refused" % bad_url, False)
    except c.DashboardError:
        check("dashboard team: %s is refused" % bad_url, True)
check("dashboard team: the events variable is not the team variable", c.resolve_team_url(None, {"PO_DASHBOARD_URL": "http://b/e"}) is None)
check("dashboard team: a feed array is parsed", c.parse_team(json.dumps(team)) == team)
check("dashboard team: empty input is no agents", c.parse_team(" \n") == [])
check("dashboard team: non-object entries are dropped", len(c.parse_team('[1, {"agent": "x"}, null]')) == 1)
for bad_feed, name in (("{not json", "bad JSON"), ('{"agent": "x"}', "an object instead of an array")):
    try:
        c.parse_team(bad_feed)
        check("dashboard team: %s is a DashboardError" % name, False)
    except c.DashboardError:
        check("dashboard team: %s is a DashboardError" % name, True)
tr = c.team_rows(team)
check("dashboard team: WORKING is working, FREE is free", tr[0]["kind"] == "working" and tr[0]["status"] == "WORKING" and tr[1]["kind"] == "free" and tr[1]["status"] == "FREE")
check("dashboard team: an idle agent shows its state as given", c.team_row({"agent": "x", "state": "idle 22m"})["status"] == "idle 22m" and c.team_row({"agent": "x", "state": "idle 22m"})["kind"] == "idle")
check("dashboard team: owns are joined, none is empty", tr[0]["owns"] == "1.4, 1.5" and tr[1]["owns"] == "")
check("dashboard team: a null now is empty", tr[1]["now"] == "" and tr[0]["now"] == "1.4")
check("dashboard team: a sparse entry still has a row", c.team_row({})["agent"] == "?" and c.team_row({})["status"] == "?")
check("dashboard team: check lines show name status now and owns", c.team_check_lines(team) == ["ada | WORKING | now: 1.4 | owns: 1.4, 1.5", "bo | FREE | now: - | owns: -"])
mt = c.team_rows([{"agent": "ada", "model": " Big Model (API) ", "state": "WORKING"}, {"agent": "bo", "state": "idle"}, {"agent": "cy", "model": None}, {"agent": "di", "model": 4}])
check("dashboard team: a model string is kept, trimmed", mt[0]["model"] == "Big Model (API)")
check("dashboard team: an absent, null or non-string model is empty", mt[1]["model"] == "" and mt[2]["model"] == "" and mt[3]["model"] == "")
check("dashboard team: a check line shows the model after the name", c.team_check_lines([{"agent": "ada", "model": "Big Model (API)", "state": "WORKING", "now": "1.4", "owns": ["1.4"]}]) == ["ada \u00b7 Big Model (API) | WORKING | now: 1.4 | owns: 1.4"])
check("dashboard team: a check line without a model is unchanged", c.team_check_lines([{"agent": "bo", "model": "", "state": "idle 22m"}]) == ["bo | idle 22m | now: - | owns: -"])
check("dashboard team: the example feed parses, with and without a model", [r["model"] != "" for r in c.team_rows(c.parse_team(open(sys.argv[1] + "/../../examples/team-feed.json").read()))] == [True, True, False, True])
# Status: LIMIT wins; the time is the viewer's local time; usage only when present.
import datetime as dt
NOW = dt.datetime(2030, 5, 1, 14, 0, tzinfo=dt.timezone.utc)
EST = dt.timezone(dt.timedelta(hours=-5))
lim = {"agent": "a", "state": "WORKING", "free": True, "limit_until": "2030-05-01T18:30:00Z"}
lr = c.team_row(lim, NOW, EST)
# v0.142 (15): the one time format, with the zone: `LIMIT until 7:00 PM EST Nov 30` (was `2026-11-30 19:00`)
check("dashboard team: LIMIT wins over WORKING and FREE", lr["kind"] == "limit" and lr["status"] == "LIMIT until 1:30 PM UTC-05:00", lr["status"])
check("dashboard team: LIMIT shows the viewer's local time", c.team_row(lim, NOW, dt.timezone.utc)["status"] == "LIMIT until 6:30 PM UTC")
check("dashboard team: LIMIT on another day shows the date", c.team_row(dict(lim, limit_until="2030-05-02T03:00:00Z"), NOW, EST)["status"] == "LIMIT until 10:00 PM UTC-05:00" and c.team_row(dict(lim, limit_until="2030-05-02T12:00:00Z"), NOW, EST)["status"] == "LIMIT until 7:00 AM UTC-05:00 May 2")
from zoneinfo import ZoneInfo
_tor = ZoneInfo("America/Toronto")
check("dashboard team: v0.142 LIMIT names the zone and its daylight time: `7:00 PM EST Nov 29`, `10:00 AM EDT`",
      c.team_row(dict(lim, limit_until="2030-11-30T00:00:00Z"), NOW, _tor)["status"] == "LIMIT until 7:00 PM EST Nov 29"
      and c.team_row(dict(lim, limit_until="2030-05-01T14:00:01Z"), NOW, _tor)["status"] == "LIMIT until 10:00 AM EDT")
check("dashboard: v0.142 clock_text writes midnight and noon as 12, minutes two digits",
      c.clock_text(dt.datetime(2030, 5, 1, 0, 5, tzinfo=dt.timezone.utc), NOW, dt.timezone.utc) == "12:05 AM UTC"
      and c.clock_text(dt.datetime(2030, 5, 1, 12, 0, tzinfo=dt.timezone.utc), NOW, dt.timezone.utc) == "12:00 PM UTC"
      and c.clock_text(dt.datetime(2031, 1, 1, 12, 0, tzinfo=dt.timezone.utc), NOW, dt.timezone.utc) == "12:00 PM UTC Jan 1 2031")
# v0.142 (15): one subscription's usage is said once in the Team header, each line drops it; usages that differ stay per line
_shared = [{"agent": a, "usage": {"five_hour": 0.22, "seven_day": 0.64}} for a in ("p", "q", "r")] + [{"agent": "s", "state": "idle"}]
_sr2 = c.team_rows(_shared)
check("dashboard team: v0.142 a usage every agent shares is the header's, once", c.team_shared_usage(_sr2) == "5h 22% · 7d 64%"
      and c.team_status(_sr2) == "4 agents · subscription 5h 22% · 7d 64%" and c.team_status(_sr2).count("22%") == 1)
check("dashboard team: v0.142 usages that differ, or none, give no shared usage and a plain count",
      c.team_shared_usage(c.team_rows(_shared + [{"agent": "t", "usage": {"five_hour": 0.5}}])) == "" and c.team_status(c.team_rows([{"agent": "x"}])) == "1 agent")
for name, v in (("null", None), ("absent", "ABSENT"), ("past", "2030-05-01T13:00:00Z"), ("unparseable", "soon"), ("non-string", 5)):
    e = {"agent": "a", "state": "idle 3h", "free": True}
    if v != "ABSENT":
        e["limit_until"] = v
    check("dashboard team: a %s limit_until is no limit" % name, c.team_row(e, NOW, EST)["status"] == "FREE")
check("dashboard team: usage is shown as muted percentages", c.team_row({"usage": {"five_hour": 0.42, "seven_day": 0.185}})["usage"] == "5h 42% \u00b7 7d 18%")
check("dashboard team: only the usage parts present are shown", c.team_row({"usage": {"seven_day": 1}})["usage"] == "7d 100%" and c.team_row({"usage": {"five_hour": 0}})["usage"] == "5h 0%")
check("dashboard team: no, empty or bad usage shows nothing", all(c.team_row({"usage": u})["usage"] == "" for u in (None, {}, [], "x", {"five_hour": "a", "seven_day": 2}, {"five_hour": True, "seven_day": -1})) and c.team_row({})["usage"] == "")
check("dashboard team: a check line shows LIMIT and usage", c.team_check_lines([dict(lim, usage={"five_hour": 1, "seven_day": 0.5})], NOW, EST) == ["a | LIMIT until 1:30 PM UTC-05:00 (5h 100% \u00b7 7d 50%) | now: - | owns: -"])
check("dashboard team: an old feed row shows as before", c.team_row({"agent": "a", "state": "idle 3h", "free": False}, NOW, EST)["status"] == "idle 3h")
# The Team view's saved order: where it lives, load and save, merged with the feed.
import os, tempfile
check("dashboard order: PO_DASHBOARD_TEAM_ORDER names the file", c.team_order_path({"PO_DASHBOARD_TEAM_ORDER": "/t/o.json", "XDG_CONFIG_HOME": "/x"}) == "/t/o.json")
check("dashboard order: XDG_CONFIG_HOME is honoured", c.team_order_path({"XDG_CONFIG_HOME": "/x"}) == "/x/po-dashboard/team-order.json")
check("dashboard order: the default is ~/.config, a relative XDG_CONFIG_HOME is ignored",
      c.team_order_path({}) == os.path.join(os.path.expanduser("~"), ".config", "po-dashboard", "team-order.json") == c.team_order_path({"XDG_CONFIG_HOME": "rel"}))
od = tempfile.mkdtemp()
op = os.path.join(od, "sub", "dir", "team-order.json")
check("dashboard order: a missing file is no order", c.load_team_order(op) == [])
for name, body in (("corrupt JSON", "{not json"), ("a non-list", '"ada"'), ("an empty file", "")):
    with open(os.path.join(od, "bad.json"), "w") as f:
        f.write(body)
    check("dashboard order: %s is no order" % name, c.load_team_order(os.path.join(od, "bad.json")) == [])
with open(os.path.join(od, "mixed.json"), "w") as f:
    f.write('{"order": ["bo", 3, null, "ada", "bo"]}')
check("dashboard order: non-names and repeats are dropped", c.load_team_order(os.path.join(od, "mixed.json")) == ["bo", "ada"])
c.save_team_order(op, ["cy", "ada"])
check("dashboard order: a saved order survives a restart (written, directory made, read back)", c.load_team_order(op) == ["cy", "ada"] and not os.path.exists(op + ".tmp"))
try:
    c.save_team_order(os.path.join(od, "mixed.json", "x.json"), ["ada"])
    check("dashboard order: a failed save is a DashboardError", False)
except c.DashboardError:
    check("dashboard order: a failed save is a DashboardError", True)
feed = [{"agent": "ada"}, {"agent": "bo"}, {"agent": "cy"}, {"agent": "di"}]
names = lambda es: [e["agent"] for e in es]
check("dashboard order: no saved order keeps the feed's order", names(c.apply_team_order(feed, [])) == ["ada", "bo", "cy", "di"])
check("dashboard order: the saved order wins over the feed's", names(c.apply_team_order(feed, ["di", "cy", "bo", "ada"])) == ["di", "cy", "bo", "ada"])
check("dashboard order: agents not in the saved order go last, in the feed's order", names(c.apply_team_order(feed, ["cy", "gone"])) == ["cy", "ada", "bo", "di"])
check("dashboard order: applying it leaves the feed untouched", names(feed) == ["ada", "bo", "cy", "di"] and c.apply_team_order(feed, ["bo"])[0] is feed[1])
check("dashboard order: a line moves to the place it is dropped on, up or down",
      c.move_agent(["a", "b", "c"], "a", 2) == ["b", "c", "a"] and c.move_agent(["a", "b", "c"], "c", 0) == ["c", "a", "b"] and c.move_agent(["a", "b", "c"], "a", 1) == ["b", "a", "c"])
check("dashboard order: Alt+Up on the first line and Alt+Down on the last change nothing",
      c.move_agent(["a", "b"], "a", -1) == ["a", "b"] and c.move_agent(["a", "b"], "b", 2) == ["a", "b"])
check("dashboard order: moving an agent not shown changes nothing", c.move_agent(["a", "b"], "z", 0) == ["a", "b"])
check("dashboard order: the saved order keeps agents not shown now, after the shown ones", c.merge_team_order(["b", "a"], ["a", "x", "b"]) == ["b", "a", "x"])
# The Decisions view: the feed option, parsing, oldest asked first, the asked time, the thread URL.
check("dashboard decisions: --decisions-url wins over the environment", c.resolve_decisions_url("http://a/d", {"PO_DASHBOARD_DECISIONS_URL": "http://b/d"}) == "http://a/d")
check("dashboard decisions: the environment is used without --decisions-url", c.resolve_decisions_url(None, {"PO_DASHBOARD_DECISIONS_URL": "http://b/d"}) == "http://b/d")
check("dashboard decisions: no option and no environment is no feed (no default)", c.resolve_decisions_url(None, {}) is None and c.resolve_decisions_url(" ", {"PO_DASHBOARD_DECISIONS_URL": " "}) is None)
check("dashboard decisions: the team variable is not the decisions variable", c.resolve_decisions_url(None, {"PO_DASHBOARD_TEAM_URL": "http://b/t"}) is None)
check("dashboard decisions: a file:// feed is accepted", c.resolve_decisions_url("file:///tmp/d.json", {}) == "file:///tmp/d.json")
try:
    c.resolve_decisions_url("ftp://h/d", {})
    check("dashboard decisions: ftp://h/d is refused", False)
except c.DashboardError:
    check("dashboard decisions: ftp://h/d is refused", True)
dec = [{"project": "orchard", "item": "2.3", "title": "Pick a format", "waiting_for": "a ruling", "asked_at": "2026-10-24T09:00:00Z", "thread_url": "https://chat.example.org/t/1"},
       {"project": "harbor", "item": "0.7", "title": "Accept the screen", "waiting_for": "an acceptance", "asked_at": "2026-10-24T11:30:00Z"},
       {"project": "orchard", "item": "2.5", "title": "Unblock", "waiting_for": "a block to clear", "asked_at": "2026-10-23T12:00:00Z"}]
check("dashboard decisions: a feed array is parsed", c.parse_decisions(json.dumps(dec)) == dec)
check("dashboard decisions: empty input is no decisions", c.parse_decisions(" \n") == [])
check("dashboard decisions: non-object entries are dropped", len(c.parse_decisions('[1, {"item": "x"}, null]')) == 1)
for bad_feed, name in (("{not json", "bad JSON"), ('{"item": "x"}', "an object, not a list")):
    try:
        c.parse_decisions(bad_feed)
        check("dashboard decisions: %s is a DashboardError" % name, False)
    except c.DashboardError:
        check("dashboard decisions: %s is a DashboardError" % name, True)
now = datetime.datetime(2026, 10, 24, 12, 0, 0, tzinfo=utc)
dr = c.decision_rows(dec, now, utc)
check("dashboard decisions: oldest asked first", [r["item"] for r in dr] == ["2.5", "2.3", "0.7"])
check("dashboard decisions: zones are compared as instants", [e["item"] for e in c.sort_decisions([{"item": "a", "asked_at": "2026-10-24T10:00:00+02:00"}, {"item": "b", "asked_at": "2026-10-24T09:00:00Z"}])] == ["a", "b"])
check("dashboard decisions: a missing or unreadable asked_at goes last, in the feed's order",
      [e["item"] for e in c.sort_decisions([{"item": "x"}, {"item": "y", "asked_at": "soon"}, {"item": "z", "asked_at": "2026-10-24T09:00:00Z"}])] == ["z", "x", "y"])
ka, kb = c.decision_key({"project": "p", "item": "1"}), c.decision_key({"project": "q", "item": "1"})
check("dashboard decisions: the key is project and item", ka != kb and ka == ("p", "1"))
ex = c.toggle_expanded(set(), ka)
check("dashboard decisions: toggling opens then closes an entry", ex == {ka} and c.toggle_expanded(ex, ka) == set())
check("dashboard decisions: an expanded entry stays across a refresh", c.prune_expanded({ka, kb}, [{"project": "p", "item": "1"}, {"project": "q", "item": "1"}]) == {ka, kb})
check("dashboard decisions: an entry that left the feed drops out", c.prune_expanded({ka, kb}, [{"project": "q", "item": "1"}]) == {kb})
# v0.71: an open card stays open, with its text, cursor and focus, across feed refreshes; only its item line closes it.
_f1 = [{"project": "p", "item": "1", "id": "a1", "kind": "unformatted", "asked_at": "2026-10-30T10:00:00Z"},
       {"project": "q", "item": "1", "id": "b1", "kind": "choice", "asked_at": "2026-10-30T11:00:00Z"}]
_f1b = json.loads(json.dumps([dict(reversed(list(e.items()))) for e in _f1]))  # the same feed, keys in another order
_f2 = _f1 + [{"project": "r", "item": "2", "id": "c1", "kind": "unformatted", "asked_at": "2026-10-30T12:00:00Z"}]
check("dashboard decisions: a refresh with the same feed is the same (no rebuild), key order aside", c.decisions_same(_f1, _f1b))
check("dashboard decisions: a changed feed, or the first one, is not the same (rebuild)", not c.decisions_same(_f1, _f2) and not c.decisions_same(None, _f1) and not c.decisions_same(_f1, _f1[:1]))
def _type_across_refresh(new_feed):
    """The window state while typing into card p/1 when the feed refreshes: what redraw_decisions keeps."""
    expanded = c.toggle_expanded(set(), ka)  # the owner clicked the item line: open
    typed = "two words "  # trailing space: a draft is kept as typed
    picks = {"text": typed}
    drafts = {"a1": dict(picks)}
    focus = ("a1", "text", len(typed))  # the box has the focus, the cursor after the last character
    if c.decisions_same(_f1, new_feed):
        return expanded, drafts["a1"]["text"], focus, False  # nothing rebuilt: the same widgets
    ids = {e["id"] for e in new_feed}
    return (c.prune_expanded(expanded, new_feed), {k: v for k, v in drafts.items() if k in ids}["a1"]["text"],
            c.answer_focus(focus, new_feed, {}), True)
for _name, _feed in (("the same", _f1b), ("a changed", _f2)):
    _exp, _text, _focus, _rebuilt = _type_across_refresh(_feed)
    check("dashboard decisions: typing across a refresh with %s feed keeps the card open, the text, the cursor and the focus" % _name,
          ka in _exp and _text == "two words " and _focus == ("a1", "text", 10) and _rebuilt == (_name != "the same"))
    check("dashboard decisions: after a refresh with %s feed, a click on the item line closes the card" % _name, ka not in c.toggle_expanded(_exp, ka))
check("dashboard decisions: the focus is not given back to a card that left the feed or was answered",
      c.answer_focus(("a1", "text", 3), _f1[1:], {}) is None and c.answer_focus(("a1", "text", 3), _f1, {"a1": {"display": "sending…"}}) is None
      and c.answer_focus(None, _f1, {}) is None and c.answer_focus(("b1", "note", 0), _f1, {}) == ("b1", "note", 0))
check("dashboard answers: a draft kept as typed is trimmed only on the way out",
      c.answer_params("unformatted", {"text": " two words \n"}) == {"text": "two words"}
      and c.answer_params("choice", {"choice": None, "note": "mine "})["text"] == "mine"
      and c.answer_params("action", {"result": "Pass", "note": "  "})["note"] is None)
check("dashboard answers: spaces alone are not ready", not c.answer_ready("unformatted", {"text": "   "}) and not c.answer_ready("choice", {"choice": None, "note": " \n "}))
check("dashboard decisions: asked_at is shown relative to now", [r["asked"] for r in dr] == ["1d ago", "3h ago", "30m ago"])
check("dashboard decisions: under a minute, or ahead of the clock, is just now",
      c.ago(now, now) == "just now" and c.ago(now - datetime.timedelta(seconds=59), now) == "just now" and c.ago(now + datetime.timedelta(hours=1), now) == "just now")
check("dashboard decisions: the local time is kept for the tooltip", dr[1]["asked_local"] == "2026-10-24 09:00:00" and c.decision_row(dec[0], now, est)["asked_local"] == "2026-10-24 05:00:00")
check("dashboard decisions: an unreadable asked_at is kept as text", c.decision_row({"asked_at": "soon"}, now)["asked"] == "soon" and c.decision_row({"asked_at": "soon"}, now)["asked_local"] == "")
check("dashboard decisions: a sparse entry still has a row", c.decision_row({}, now) == {"kind": "legacy", "id": "", "project": "", "item": "-", "title": "", "waiting_for": "?", "asked": "?", "asked_local": "", "thread_url": "", "asked_by": ""})
check("dashboard decisions: thread_url is kept as text, trimmed; absent or not a string is empty",
       dr[1]["thread_url"] == "https://chat.example.org/t/1" and dr[0]["thread_url"] == "" and c.decision_row({"thread_url": 4}, now)["thread_url"] == ""
       and c.decision_row({"thread_url": " https://x/t "}, now)["thread_url"] == "https://x/t")
check("dashboard decisions: asked_by is trimmed when a string, empty otherwise",
       c.decision_row({"asked_by": " ana "}, now)["asked_by"] == "ana" and c.decision_row({"asked_by": 4}, now)["asked_by"] == "")
check("dashboard decisions: markup in a field stays text", c.decision_row({"title": "<b>x</b>"}, now)["title"] == "<b>x</b>")
# v0.141 (17): the desktop card's thread_url is a real link named like the web's, never a scheme other than http(s)
check("dashboard decisions: v0.141 a thread_url becomes an `Open thread` link, its URL escaped for the attribute",
      c.thread_link_markup("https://chat.example.org/t/1") == '<a href="https://chat.example.org/t/1">Open thread</a>'
      and c.thread_link_markup(' http://x/t?a=1&b="2" ') == '<a href="http://x/t?a=1&amp;b=&quot;2&quot;">Open thread</a>'
      and c.THREAD_LINK_TEXT == "Open thread")
check("dashboard decisions: v0.141 a chat app's own deep link is a link too (the feed may carry no web URL)",
      c.thread_link_markup("chat://message?channel=c1&id=e1&thread=r1") == '<a href="chat://message?channel=c1&amp;id=e1&amp;thread=r1">Open thread</a>')
check("dashboard decisions: v0.141 no link for a scheme that runs code or reads local data, a URL with no host, text, or nothing",
      all(c.thread_link_markup(u) == "" for u in ("javascript" + ":alert(1)", "JavaScript://x%0aalert(1)", "vbscript://x", "data://x",
                                                   "file:///etc/passwd", "blob://x", "about://blank", "mailto:a@b", "https://", "chat thread",
                                                   "chat://a b", "", None, 4)))
check("dashboard decisions: v0.141 every card kind with an http(s) thread_url gets the link (choice, action, unformatted, legacy)",
      all(c.thread_link_markup(c.decision_row(dict(e, thread_url="https://h/t/9"), now)["thread_url"]) for e in
          [{"kind": "choice", "id": "a", "question": "q", "options": [{"label": "x"}, {"label": "y"}]},
           {"kind": "action", "id": "b", "machine": "m", "done_when": "pass", "steps": [{"text": "s", "expect": "x"}]}, {"kind": "z", "id": "c"}, {}]))
check("dashboard decisions: short_title cuts at 80 and keeps short text", c.short_title("x" * 100) == "x" * 80 and c.short_title("abc") == "abc" and c.short_title(None) == "")
check("dashboard decisions: a long title is cut in the row", len(c.decision_row({"title": "y" * 120}, now)["title"]) == 80)
check("dashboard decisions: check lines show kind item project title waiting asked and the URL when there is one",
      c.decision_check_lines(dec[:2], now, utc) == ["legacy | 2.3 | orchard | Pick a format | waiting for: a ruling | asked 3h ago (2026-10-24 09:00:00) | https://chat.example.org/t/1",
                                                   "legacy | 0.7 | harbor | Accept the screen | waiting for: an acceptance | asked 30m ago (2026-10-24 11:30:00)"])
check("dashboard decisions: the feed is never changed", [e["item"] for e in dec] == ["2.3", "0.7", "2.5"])
ex = c.parse_decisions(open(sys.argv[1] + "/../../examples/decisions-feed.json").read())
check("dashboard decisions: the example feed parses, with and without a thread URL",
      len(ex) == 6 and all(k in e for e in ex for k in ("project", "item", "title", "waiting_for", "asked_at")) and sorted(bool(r["thread_url"]) for r in c.decision_rows(ex)) == [False] * 4 + [True] * 2)
_long = [e for e in ex if e.get("id") == "ask-0909"][0]
_desc = [e for e in ex if e.get("id") == "ask-0206"][0]
check("dashboard decisions: the example feed has a choice with 200+ char labels and one with descriptions",
      c.decision_shape(_long) == "choice" and all(len(o["label"]) > 200 for o in _long["options"]) and c.decision_shape(_desc) == "choice" and any(o.get("description") for o in _desc["options"]))
check("dashboard answers: option_has_description is true only for non-blank text",
      [c.option_has_description(o) for o in _desc["options"]] == [True, True, False] and not c.option_has_description({"label": "x", "description": "  "}) and not c.option_has_description({"label": "x", "description": None}))
_short_b = c.answer_body(dict(_long, item="0.9"), "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41", option="Yes")
_long_b = c.answer_body(dict(_long, item="0.9"), "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41", option=_long["options"][0]["label"])
check("dashboard answers: the body for a long-label choice has the same shape as for a short label",
      set(_short_b) == set(_long_b) and _long_b["option"] == _long["options"][0]["label"] and {k: v for k, v in _long_b.items() if k != "option"} == {k: v for k, v in _short_b.items() if k != "option"})
# v0.36: kinds, group order, the Actions filter.
CH = {"kind": "choice", "id": "a1", "question": "Approve?", "options": [{"label": "Yes", "recommended": True}, {"label": "No", "description": "back to spec"}]}
AC = {"kind": "action", "id": "a2", "machine": "host", "steps": [{"text": "restart", "command": "systemctl restart x", "expect": "no output"}, {"text": "look", "expect": "it is up"}], "done_when": "pass"}
check("dashboard decisions: a choice is a choice", c.decision_shape(CH) == "choice")
check("dashboard decisions: an action is an action", c.decision_shape(AC) == "action")
check("dashboard decisions: no kind is legacy", c.decision_shape({"item": "1"}) == "legacy")
check("dashboard decisions: an unknown kind is unformatted", c.decision_shape(dict(CH, kind="poll")) == "unformatted")
check("dashboard decisions: a kind without an id is unformatted", c.decision_shape({k: v for k, v in CH.items() if k != "id"}) == "unformatted" and c.decision_shape(dict(AC, id="  ")) == "unformatted")
check("dashboard decisions: one option is unformatted", c.decision_shape(dict(CH, options=[{"label": "Yes"}])) == "unformatted")
check("dashboard decisions: an option without a label is unformatted", c.decision_shape(dict(CH, options=[{"label": "Yes"}, {"description": "x"}])) == "unformatted")
check("dashboard decisions: two recommended options are unformatted", c.decision_shape(dict(CH, options=[{"label": "a", "recommended": True}, {"label": "b", "recommended": True}])) == "unformatted")
check("dashboard decisions: a choice without a question is unformatted", c.decision_shape({k: v for k, v in CH.items() if k != "question"}) == "unformatted")
check("dashboard decisions: a step without text is unformatted", c.decision_shape(dict(AC, steps=[{"command": "x"}])) == "unformatted")
check("dashboard decisions: an action without steps, machine or done_when is unformatted",
      c.decision_shape(dict(AC, steps=[])) == "unformatted" and c.decision_shape({k: v for k, v in AC.items() if k != "machine"}) == "unformatted" and c.decision_shape({k: v for k, v in AC.items() if k != "done_when"}) == "unformatted")
check("dashboard decisions: a field of the wrong type is unformatted", c.decision_shape(dict(CH, options="yes")) == "unformatted" and c.decision_shape(dict(AC, steps=[{"text": "x", "command": 4}])) == "unformatted")
check("dashboard decisions: unknown extra fields are ignored", c.decision_shape(dict(CH, channel="c", thread="t")) == "choice")
gs = [dict(AC, item="g1", asked_at="2026-10-24T01:00:00Z"), {"item": "g2", "asked_at": "2026-10-24T02:00:00Z"}, dict(CH, item="g3", asked_at="2026-10-24T05:00:00Z"),
      dict(CH, item="g4", asked_at="2026-10-24T03:00:00Z"), dict(CH, item="g5", kind="poll", asked_at="2026-10-24T00:00:00Z")]
check("dashboard decisions: choices, then actions, then unformatted and legacy, oldest first in each group", [e["item"] for e in c.sort_decisions(gs)] == ["g4", "g3", "g1", "g5", "g2"])
gr = c.decision_row(dict(CH, item="g"), now)
check("dashboard decisions: a choice row carries the kind, id, question and options in feed order, the recommended marked",
      gr["kind"] == "choice" and gr["id"] == "a1" and gr["question"] == "Approve?" and gr["options"] == [{"label": "Yes", "description": "", "recommended": True}, {"label": "No", "description": "back to spec", "recommended": False}])
ar = c.decision_row(dict(AC, item="g"), now)
check("dashboard decisions: an action row carries the machine, numbered steps with their commands, and done_when",
      ar["kind"] == "action" and ar["machine"] == "host" and ar["steps"] == [{"n": 1, "text": "restart", "command": "systemctl restart x", "expect": "no output"}, {"n": 2, "text": "look", "command": "", "expect": "it is up"}] and ar["done_when"] == "pass")
check("dashboard decisions: an unformatted row has no kind fields", "options" not in c.decision_row(dict(CH, kind="poll"), now) and c.decision_row(dict(CH, kind="poll"), now)["kind"] == "unformatted")
check("dashboard decisions: the key stays project and item, not the id", c.decision_key(dict(CH, project="p", item="1")) == ("p", "1"))
kl = c.decision_check_lines([dict(CH, item="g4", project="p", title="T", waiting_for="w", asked_at="2026-10-24T09:00:00Z"), {"item": "g2", "project": "p", "title": "T", "waiting_for": "w", "asked_at": "2026-10-24T08:00:00Z"}], now, utc)
check("dashboard decisions: check lines start with the kind, legacy for none", kl[0].startswith("choice | g4 | p | T") and kl[1].startswith("legacy | g2 | p | T"))
check("dashboard decisions: check lines ignore the filter", len(c.decision_check_lines([AC, CH], now, utc)) == 2)
check("dashboard decisions: both filters on shows everything", c.filter_decisions([AC, CH, {}], True, True) == ([AC, CH, {}], 0, 0))
check("dashboard decisions: actions off hides actions and counts them", c.filter_decisions([AC, CH, dict(AC, id="a3")], False, True) == ([CH], 2, 0))
check("dashboard decisions: decisions off hides choices and counts them", c.filter_decisions([AC, CH, dict(CH, id="c2")], True, False) == ([AC], 0, 2))
check("dashboard decisions: unformatted and legacy stay under both", c.filter_decisions([AC, CH, {}], False, False) == ([{}], 1, 1))
check("dashboard decisions: status line with both hidden", c.decisions_status(3, 1, 2) == "3 waiting \u00b7 1 action hidden \u00b7 2 decisions hidden")
check("dashboard decisions: status line omits zero parts", c.decisions_status(3, 0, 0) == "3 waiting" and c.decisions_status(3, 1, 0) == "3 waiting \u00b7 1 action hidden")
check("dashboard decisions: check lines ignore the filters", len(c.decision_check_lines([AC, CH], now, utc)) == 2)
# v0.69: cards name the build with `requires`, the dashboard writes the install command.
SHA, SHB = "0123456789abcdef" * 4, "fedcba9876543210" * 4
RQ = {"package": "orchard-1.9.39.r1-1-x86_64.pkg.tar.zst", "sha256": SHA}
check("dashboard install: --install-dir wins over the environment, the environment is used without it, neither is None",
      c.resolve_install_dir("/a/pkgs", {"PO_DASHBOARD_INSTALL_DIR": "/b"}) == "/a/pkgs" and c.resolve_install_dir(None, {"PO_DASHBOARD_INSTALL_DIR": "/b/"}) == "/b"
      and c.resolve_install_dir(None, {}) is None and c.resolve_install_dir(" ", {"PO_DASHBOARD_INSTALL_DIR": " "}) is None)
for bad_dir in ("pkgs", "~/pkgs", "/a b", "/<dir>", "/a;rm"):
    try:
        c.resolve_install_dir(bad_dir, {})
        check("dashboard install: install_dir %r is refused" % bad_dir, False)
    except c.DashboardError:
        check("dashboard install: install_dir %r is refused" % bad_dir, True)
check("dashboard install: install_commands happy path, exact strings",
      c.install_commands("/home/me/pkgs", RQ) == ("cd /home/me/pkgs && sha256sum -c <<< '%s  orchard-1.9.39.r1-1-x86_64.pkg.tar.zst'" % SHA,
                                                  "sudo pacman -U /home/me/pkgs/orchard-1.9.39.r1-1-x86_64.pkg.tar.zst"))
check("dashboard install: a trailing slash on install_dir gives the same commands", c.install_commands("/home/me/pkgs/", RQ) == c.install_commands("/home/me/pkgs", RQ))
for name, d, rq in (("a relative dir", "pkgs", RQ), ("a home-relative dir", "~/pkgs", RQ), ("an unset dir", None, RQ), ("an empty dir", "", RQ),
                    ("a placeholder dir", "/<install dir>", RQ), ("a dir with a space", "/a b", RQ),
                    ("a package with a path", "/p", dict(RQ, package="sub/orchard.pkg.tar.zst")), ("a package that is an absolute path", "/p", dict(RQ, package="/p/orchard.pkg.tar.zst")),
                    ("a placeholder package", "/p", dict(RQ, package="<orchard-1.9.39.r1 package>")), ("a package with angle brackets", "/p", dict(RQ, package="orchard-<v>.pkg.tar.zst")),
                    ("a package with whitespace", "/p", dict(RQ, package="orchard 1.pkg.tar.zst")), ("a package with a quote", "/p", dict(RQ, package="a'b.pkg")),
                    ("an empty package", "/p", dict(RQ, package="")), ("a package that is not text", "/p", dict(RQ, package=4)),
                    ("a short sha", "/p", dict(RQ, sha256=SHA[:63])), ("an uppercase sha", "/p", dict(RQ, sha256=SHA.upper())), ("a non-hex sha", "/p", dict(RQ, sha256="g" * 64)),
                    ("a missing sha", "/p", {"package": RQ["package"]}), ("no requires", "/p", None), ("requires not an object", "/p", "orchard.pkg")):
    check("dashboard install: install_commands refuses %s" % name, c.install_commands(d, rq) is None)
check("dashboard install: an action with a good requires is an action, the row passes it through",
      c.decision_shape(dict(AC, requires=RQ)) == "action" and c.decision_row(dict(AC, requires=RQ), now)["requires"] == RQ)
check("dashboard install: an action without requires has requires None", c.decision_row(AC, now)["requires"] is None)
check("dashboard install: an action with a bad requires is unformatted, as other bad fields",
      all(c.decision_shape(dict(AC, requires=bad)) == "unformatted" for bad in (dict(RQ, package="<pkg>"), dict(RQ, package="a/b"), dict(RQ, sha256="x"), {}, "pkg", None)))
def card(item, req, at, project="orchard"):
    return dict(AC, id="id-" + item, project=project, item=item, asked_at=at, steps=[{"text": "look at the sidebar", "expect": "the sidebar shows"}], **({"requires": req} if req else {}))
agree = [card("1.9.39", RQ, "2026-10-29T10:00:00Z"), card("1.9.49", RQ, "2026-10-29T11:00:00Z"), card("1.10.7", RQ, "2026-10-29T12:00:00Z")]
pl = c.install_plan(agree, "/home/me/pkgs")
check("dashboard install: cards agreeing give one block with both commands and no mark",
      list(pl) == ["orchard"] and pl["orchard"]["package"] == RQ["package"] and pl["orchard"]["commands"] == c.install_commands("/home/me/pkgs", RQ)
      and pl["orchard"]["note"] == "" and pl["orchard"]["mismatched"] == {})
RQB = {"package": "orchard-1.10.7.r1-1-x86_64.pkg.tar.zst", "sha256": SHB}
differ = [card("1.9.39", RQ, "2026-10-29T10:00:00Z"), card("1.10.7", RQB, "2026-10-29T12:00:00Z"), card("1.9.49", RQ, "2026-10-29T11:00:00Z")]
pl = c.install_plan(differ, "/home/me/pkgs")
check("dashboard install: cards disagreeing give one block, the newest asked build",
      list(pl) == ["orchard"] and pl["orchard"]["package"] == RQB["package"] and pl["orchard"]["commands"] == c.install_commands("/home/me/pkgs", RQB))
check("dashboard install: each card on another build is marked needs <package>: install it first",
      pl["orchard"]["mismatched"] == {("orchard", "1.9.39"): "needs %s: install it first" % RQ["package"], ("orchard", "1.9.49"): "needs %s: install it first" % RQ["package"]})
check("dashboard install: the same package with another sha256 is another build",
      c.install_plan([card("a", RQ, "2026-10-29T10:00:00Z"), card("b", dict(RQ, sha256=SHB), "2026-10-29T11:00:00Z")], "/p")["orchard"]["mismatched"] == {("orchard", "a"): "needs %s: install it first" % RQ["package"]})
pl = c.install_plan(agree, None)
check("dashboard install: unset install_dir keeps the block with no command and says set install_dir",
      pl["orchard"]["commands"] is None and pl["orchard"]["note"] == "set install_dir" and pl["orchard"]["package"] == RQ["package"])
check("dashboard install: one block per project", sorted(c.install_plan(agree + [card("2.0", RQB, "2026-10-29T09:00:00Z", project="harbor")], "/p")) == ["harbor", "orchard"])
check("dashboard install: cards without requires, choices and unformatted entries make no block",
      c.install_plan([card("x", None, "2026-10-29T10:00:00Z"), dict(CH, project="orchard", requires=RQ), dict(AC, project="orchard", requires={"package": "<p>", "sha256": SHA})], "/p") == {})
check("dashboard install: check lines give the package, each command, then the marks",
      c.install_check_lines(differ, "/p") == ["install | orchard | " + RQB["package"]] + ["install | orchard | " + x for x in c.install_commands("/p", RQB)]
      + ["install | orchard | 1.9.39 | needs %s: install it first" % RQ["package"], "install | orchard | 1.9.49 | needs %s: install it first" % RQ["package"]]
      and c.install_check_lines(agree, None) == ["install | orchard | " + RQ["package"], "install | orchard | set install_dir"])
# No produced command holds a placeholder (<, > beyond the here-string's <<<) or names the package by a bare file name.
produced = [cmd for d in ("/home/me/pkgs", "/", "/a/b/") for rq in (RQ, RQB) for cmd in c.install_commands(d, rq)]
def bare(cmd, d, pkg):
    rest = cmd.replace(d.rstrip("/") + "/" + pkg, "")
    if cmd.startswith("cd %s && sha256sum -c <<< '" % (d.rstrip("/") or "/")):
        rest = rest.split("<<<", 1)[0]  # the here-string's line is read inside install_dir
    return pkg in rest
check("dashboard install: no produced command holds < or > besides the here-string", produced and all("<" not in x.replace("<<<", "", 1) and ">" not in x for x in produced))
check("dashboard install: no produced command names the package by a bare file name",
      all(not bare(cmd, d, rq["package"]) for d in ("/home/me/pkgs", "/", "/a/b/") for rq in (RQ, RQB) for cmd in c.install_commands(d, rq)))
check("dashboard install: no produced command holds a pipe", all("|" not in x for x in produced))
# v0.81: a look card (an action with requires) is shown only when ready: step-checked on its build, every step
# concrete with its expect, fixtures stated and present, and the build installed and checked on the viewer's machine.
PK81 = "orchard-1.9.70-1-x86_64.pkg.tar.zst"
LK = dict(AC, id="lk", project="orchard", item="1.9.70", asked_at="2026-11-01T02:00:00Z",
          steps=[{"text": "click Bookmarks in the menu bar", "expect": "a menu with three bookmarks"},
                 {"text": "type 'example.org/live' in the address bar and press Enter", "command": "", "expect": "the stream plays"}],
          requires={"package": PK81, "sha256": SHA}, checked_by="rev", check_sha256=SHA,
          fixtures=[{"name": "profile", "kind": "path", "target": "~/.config/orchard/profile.json", "present": True},
                    {"name": "stream", "kind": "url", "target": "https://example.org/live", "present": True}],
          ready={"build": "orchard 1.9.70-1", "commit": "abc1234", "checked_at": "2026-11-01T03:00:00Z"},
          snapshot="/home/me/orchard-data-snapshot-20261031-2320")
LKNOW = datetime.datetime(2026, 11, 1, 3, 5, 0, tzinfo=utc)  # five minutes after LK's checked_at
check("look: package_nvr reads name and ver-rel from a package file name",
      c.package_nvr(PK81) == ("orchard", "1.9.70-1") and c.package_nvr("lib-x-2.0.r3.g1a2b-2-any.pkg.tar.xz") == ("lib-x", "2.0.r3.g1a2b-2"))
check("look: package_nvr refuses names that are not package files",
      all(c.package_nvr(x) is None for x in ("a-1-x86_64.pkg.tar.zst", "orchard.pkg.tar.zst", "a/b-1-1-any.pkg.tar.zst", "<p>-1-1-any.pkg.tar.zst", None, 3)))
check("look: matching build shown with the Ready line (local time)",
      c.look_ready(LK, utc, LKNOW) == (True, "Ready: orchard 1.9.70-1 installed, checked 2026-11-01 03:00:00"))
_lr = c.decision_row(LK, LKNOW, utc)
check("look: the row carries the Ready line, each step's expect, the fixtures and the snapshot",
      _lr["ready"] == "Ready: orchard 1.9.70-1 installed, checked 2026-11-01 03:00:00" and [st["expect"] for st in _lr["steps"]] == ["a menu with three bookmarks", "the stream plays"]
      and _lr["fixtures"] == [{"name": "profile", "present": True}, {"name": "stream", "present": True}] and _lr["snapshot"] == LK["snapshot"])
_wrong = dict(LK, ready=dict(LK["ready"], build="orchard 1.9.69-1"))
_lk_at = lambda secs: c.look_ready(LK, utc, LKNOW + datetime.timedelta(seconds=secs))
check("look: checked_at 20 minutes old is held stale", _lk_at(20 * 60 - 300) == (False, "stale"))
check("look: checked_at 10 seconds old is ready", _lk_at(10 - 300)[0] is True)
check("look: checked_at 5 minutes ahead is held in the future", _lk_at(-600) == (False, "in the future"))
_wall = lambda secs: (datetime.datetime.now(utc) - datetime.timedelta(seconds=secs)).strftime("%Y-%m-%dT%H:%M:%SZ")
check("look: with no now given the clock is read: 10 s old ready, 1 h old stale",
      c.look_ready(dict(LK, ready=dict(LK["ready"], checked_at=_wall(10))), utc)[0] is True
      and c.look_ready(dict(LK, ready=dict(LK["ready"], checked_at=_wall(3600))), utc) == (False, "stale"))
check("look: wrong build held", c.look_ready(_wrong, utc, LKNOW) == (False, "installed is orchard 1.9.69-1, the card needs orchard 1.9.70-1"))
check("look: hold_looks shows the ready card and holds the wrong build", c.hold_looks([LK, _wrong, CH], utc, LKNOW) == ([LK, CH], 1))
check("look: a held card is absent from the check lines once held out",
      [l.split(" | ")[1] for l in c.decision_check_lines(c.hold_looks([LK, dict(_wrong, item="1.9.69")], utc, LKNOW)[0], LKNOW, utc)] == ["1.9.70"])
_nr = {k: v for k, v in LK.items() if k != "ready"}
check("look: no report from the install machine is held", c.look_ready(_nr, None, LKNOW)[0] is False and c.decision_row(_nr, LKNOW)["ready"] == "")
check("look: an unreadable checked_at is held", c.look_ready(dict(LK, ready=dict(LK["ready"], checked_at="soon")), None, LKNOW)[0] is False)
check("look: no step check is held", c.look_ready({k: v for k, v in LK.items() if k != "checked_by"}, None, LKNOW) == (False, "no step check"))
check("look: a step check on another build is held", c.look_ready(dict(LK, check_sha256=SHB), None, LKNOW) == (False, "the step check ran on another build"))
check("look: a fixture not present is held",
      c.look_ready(dict(LK, fixtures=[dict(LK["fixtures"][0], present=False), LK["fixtures"][1]]), None, LKNOW) == (False, "fixture not in place: profile"))
check("look: a card without fixtures is held", c.look_ready({k: v for k, v in LK.items() if k != "fixtures"}, None, LKNOW) == (False, "fixtures missing: list them, or write [] for none"))
check("look: fixtures [] is a stated none", c.look_ready(dict(LK, fixtures=[]), None, LKNOW)[0] is True)
check("look: a vague step is held", c.look_ready(dict(LK, steps=[{"text": "right-click the page and look around", "expect": "a menu"}]), None, LKNOW)[0] is False)
check("look: a card that is not a look card is not held", c.look_ready(AC) == (True, "") and c.look_ready(CH) == (True, ""))
check("look: step_problems names a missing expect, a short step and a vague phrase",
      c.step_problems([{"text": "open the Downloads panel"}, {"text": "look", "expect": "x"}, {"text": "right-click the page", "expect": "a menu"}])
      == ["step 1 has no expect (what the owner should see)", "step 2 is too short to follow", "step 3 is vague ('the page'): say exactly where to click or what to type"])
check("look: a quoted target clears a vague phrase", c.step_problems([{"text": "right-click the page 'Settings' tab", "expect": "a menu"}]) == [])
check("look: a vague word inside another word or a path is not vague",
      c.step_problems([{"text": "click Retry in the sync bar", "expect": "a"}, {"text": "open the registry panel", "expect": "a"},
                       {"text": "press F5 to fetch new mail", "expect": "a"}, {"text": "open /etc/hosts in the editor", "expect": "a"}]) == [])
check("look: apostrophes inside words are not a quoted target",
      c.step_problems([{"text": "don't worry, click somewhere it's fine", "expect": "a"}]) == ["step 1 is vague ('somewhere'): say exactly where to click or what to type"])
check("look: fixture_problems refuses a name used twice, a long name and too many fixtures",
      c.fixture_problems([{"name": "s", "kind": "path", "target": "~/a"}, {"name": "s", "kind": "path", "target": "~/b"}])
      == ["fixture 1: the name 's' is used twice", "fixture 2: the name 's' is used twice"]
      and c.fixture_problems([{"name": "n" * 61, "kind": "path", "target": "~/a"}]) == ["fixture 1: a name is at most 60 characters"]
      and c.fixture_problems([{"name": "f%d" % i, "kind": "path", "target": "~/a"} for i in range(21)]) == ["more than 20 fixtures"])
check("look: step_problems on no steps", c.step_problems([]) == ["no steps"] and c.step_problems(None) == ["no steps"])
check("look: fixture_problems refuses a bad kind, a path outside ~/, a .. and a plain http url",
      c.fixture_problems([{"name": "a", "kind": "cmd", "target": "x"}, {"name": "b", "kind": "path", "target": "/etc/x"},
                          {"name": "c", "kind": "path", "target": "~/../x"}, {"name": "d", "kind": "url", "target": "http://x"}])
      == ["fixture 1 needs name, kind (path or url) and target", "fixture b: a path starts ~/ with no ..", "fixture c: a path starts ~/ with no ..", "fixture d: a url is https"])
class _P:
    def __init__(self, rc, out):
        self.returncode, self.stdout = rc, out
_calls = []
def _run_ok(cmd, **kw):
    _calls.append(cmd)
    return _P(0, "orchard 1.9.70-1\n")
def _run_raise(cmd, **kw):
    raise FileNotFoundError("pacman")
check("look: installed_build asks pacman -Q for the package name", c.installed_build(LK["requires"], _run_ok) == "orchard 1.9.70-1" and _calls == [["pacman", "-Q", "orchard"]])
check("look: installed_build is None when pacman does not know it, is absent, or the name is unreadable",
      c.installed_build(LK["requires"], lambda cmd, **kw: _P(1, "")) is None and c.installed_build(LK["requires"], _run_raise) is None
      and c.installed_build({"package": "x.pkg", "sha256": SHA}, _run_ok) is None and c.installed_build(None, _run_ok) is None)
check("look: answer_body carries installed (null by default)",
      c.answer_body(LK, "6bde9c70-bd8f-4ae0-a2c7-9f6d8bebde07", result="pass", installed="orchard 1.9.70-1")["installed"] == "orchard 1.9.70-1"
      and c.answer_body(AC, "6bde9c70-bd8f-4ae0-a2c7-9f6d8bebde07", result="pass")["installed"] is None)
check("dashboard decisions: the filter file is under the config dir, or named by the environment",
      c.decisions_filter_path({"XDG_CONFIG_HOME": "/x/cfg"}) == "/x/cfg/po-dashboard/decisions.json" and c.decisions_filter_path({"PO_DASHBOARD_DECISIONS_FILTER": "/y/f.json", "XDG_CONFIG_HOME": "/x"}) == "/y/f.json")
import tempfile, json
with tempfile.TemporaryDirectory() as _d:
    _f = os.path.join(_d, "sub", "decisions.json")
    check("dashboard decisions: a missing filter file is on (both)", c.load_actions_shown(_f) is True and c.load_decisions_shown(_f) is True)
    c.save_actions_shown(_f, False)
    check("dashboard decisions: writing actions keeps decisions on", c.load_actions_shown(_f) is False and c.load_decisions_shown(_f) is True)
    c.save_decisions_shown(_f, False)
    check("dashboard decisions: writing decisions keeps actions off", c.load_actions_shown(_f) is False and c.load_decisions_shown(_f) is False)
    open(_f, "w").write("{broken")
    check("dashboard decisions: a broken filter file is on (both)", c.load_actions_shown(_f) is True and c.load_decisions_shown(_f) is True)
    open(_f, "w").write('{"actions": "no"}')
    check("dashboard decisions: only false turns the filter off", c.load_actions_shown(_f) is True and c.load_decisions_shown(_f) is True)
    open(_f, "w").write('{"actions": false, "decisions": false}')
    check("dashboard decisions: saved file has both keys", json.load(open(_f)) == {"actions": False, "decisions": False})

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/ok":
            body = json.dumps(ev).encode()
            self.send_response(200)
        else:
            body = b"boom"
            self.send_response(502)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d" % srv.server_address[1]
check("dashboard: fetch and parse a served list", len(c.parse_events(c.fetch(base + "/ok"))) == 12)
try:
    c.fetch(base + "/bad")
    check("dashboard: an HTTP error is a DashboardError", False)
except c.DashboardError as e:
    check("dashboard: an HTTP error is a DashboardError", "502" in str(e))
srv.shutdown()
srv.server_close()
try:
    c.fetch(base + "/ok", timeout=2)
    check("dashboard: an unreachable URL is a DashboardError", False)
except c.DashboardError as e:
    check("dashboard: an unreachable URL is a DashboardError", "cannot reach" in str(e))

# v0.49: answering decisions.
check("dashboard answers: --answer-url wins over the environment", c.resolve_answer_url("http://a/x", {"PO_DASHBOARD_ANSWER_URL": "http://b/x"}) == "http://a/x")
check("dashboard answers: the environment is used without --answer-url", c.resolve_answer_url(None, {"PO_DASHBOARD_ANSWER_URL": "http://b/x"}) == "http://b/x")
check("dashboard answers: no option and no environment is None (read-only)", c.resolve_answer_url(None, {}) is None and c.resolve_answer_url(" ", {"PO_DASHBOARD_ANSWER_URL": " "}) is None)
check("dashboard answers: the decisions variable is not the answer variable", c.resolve_answer_url(None, {"PO_DASHBOARD_DECISIONS_URL": "http://b/d"}) is None)
for bad_url in ("ftp://h/x", "file:///etc/passwd", "notaurl"):
    try:
        c.resolve_answer_url(bad_url, {})
        check("dashboard answers: %s is refused" % bad_url, False)
    except c.DashboardError:
        check("dashboard answers: %s is refused" % bad_url, True)
_check_entry_choice = {"id": "ask-0707", "project": "harbor", "item": "0.7", "kind": "choice", "question": "?", "options": [{"label": "Yes", "description": "", "recommended": True}, {"label": "No", "description": ""}]}
_check_entry_action = {"id": "ask-0205", "project": "orchard", "item": "2.5", "kind": "action", "machine": "m", "done_when": "pass", "steps": [{"text": "s", "command": "", "expect": "x"}]}
_b = c.answer_body(_check_entry_choice, "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41", option="Yes", text="")
check("dashboard answers: answer_body for a choice without text",
      _b["answer_id"] == "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41" and _b["id"] == "ask-0707" and _b["project"] == "harbor" and _b["item"] == "0.7"
      and _b["kind"] == "choice" and _b["option"] == "Yes" and _b["text"] == ""
      and _b["result"] is None and _b["step"] is None and _b["note"] is None
      and "answered_at" in _b and _b["client"] == c.CLIENT)
_bv = c.answer_body(_check_entry_choice, "1c8f4d2b-6e3a-4b9f-8d72-4a1e3c9b8f52", option="Yes", text="good idea")
check("dashboard answers: answer_body for a choice with text", _bv["option"] == "Yes" and _bv["text"] == "good idea")
_bp = c.answer_body(_check_entry_action, "2d9a5e3c-7f4b-4cae-ae83-5b2f4dac9a63", result="pass")
check("dashboard answers: answer_body for an action pass", _bp["result"] == "pass" and _bp["step"] is None and _bp["note"] is None and _bp["option"] is None and _bp["text"] is None)
_bf = c.answer_body(_check_entry_action, "3eab6f4d-8a5c-4dbf-bf94-6c3a5ebdab74", result="failed", step=1, note="the key was missing")
check("dashboard answers: answer_body for an action failed with step and note", _bf["result"] == "failed" and _bf["step"] == 1 and _bf["note"] == "the key was missing" and _bf["option"] is None and _bf["text"] is None)
_bu = c.answer_body({"id": "ask-0808", "project": "harbor", "item": "0.8", "kind": "unformatted"}, "4fbc7a5e-9b6d-4ec0-80a5-7d4b6fcebc85", text="custom answer")
check("dashboard answers: answer_body for unformatted text", _bu["text"] == "custom answer" and _bu["kind"] == "unformatted" and _bu["option"] is None and _bu["result"] is None and _bu["step"] is None)
import glob, importlib.machinery, importlib.util, re
UUID4_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")
HEX64_RE = re.compile(r"^[0-9a-f]{64}$")
_ids = [c.answer_id() for _ in range(50)]
check("dashboard answers: answer_id is a lowercase dashed uuid4, unique per call", all(UUID4_RE.match(i) for i in _ids) and len(set(_ids)) == 50, repr(_ids[0]))
# v0.67: the client's real body as posted (README format), then through the receiver's check_body.
_eid = "9f3c" * 16  # a 64-hex entry id, as in the feed
_real = [("choice", c.answer_body(dict(_check_entry_choice, id=_eid), c.answer_id(), option="Yes", text="")),
         ("action", c.answer_body(dict(_check_entry_action, id=_eid), c.answer_id(), result="failed", step=1, note="n"))]
_FIELDS = {"answer_id", "id", "project", "item", "kind", "option", "text", "result", "step", "note", "answered_at", "client", "installed"}
for _k, _rb in _real:
    _rb = json.loads(json.dumps(_rb).encode("utf-8"))
    check("dashboard answers: the real %s body has the README fields and formats" % _k,
          set(_rb) == _FIELDS and UUID4_RE.match(_rb["answer_id"]) is not None and HEX64_RE.match(_rb["id"]) is not None
          and _rb["kind"] == _k and _rb["client"] == "po-dashboard", repr(_rb))
_recv = sorted(glob.glob(os.path.join(sys.argv[1], "..", "..", "private", "*", "bin", "answer-receiver")))
if _recv:
    _spec = importlib.util.spec_from_loader("answer_receiver", importlib.machinery.SourceFileLoader("answer_receiver", _recv[0]))
    _rm = importlib.util.module_from_spec(_spec)
    _spec.loader.exec_module(_rm)
    def _accepts(body):
        try:
            _rm.check_body(json.dumps(body).encode("utf-8"))
            return "ok"
        except _rm.Reply as e:
            return "%d %s" % (e.code, e.why)
    for _k, _rb in _real:
        _got = _accepts(_rb)
        check("dashboard answers: the receiver's check_body accepts the client's real %s body" % _k, _got == "ok", "%s %s" % (_got, json.dumps(_rb)))
    _got = _accepts(dict(_real[0][1], answer_id=_real[0][1]["answer_id"].replace("-", "")))
    check("dashboard answers: the receiver's check_body refuses a 32-hex answer_id", _got == "400 answer_id", _got)
else:
    check("dashboard answers: receiver check_body cross-check skipped (receiver absent)", True)
check("dashboard answers: answer_state maps 200/201 to answered · sent", c.answer_state(200) == "answered \u00b7 sent" and c.answer_state(201) == "answered \u00b7 sent")
check("dashboard answers: answer_state maps 409 to already answered", c.answer_state(409) == "already answered")
check("dashboard answers: answer_state maps 404 to no longer waiting", c.answer_state(404) == "no longer waiting")
check("dashboard answers: answer_state maps 401/403 to refused by host", c.answer_state(401, host="h") == "refused by h: 401" and c.answer_state(403, host="h") == "refused by h: 403")
check("dashboard answers: answer_state maps other codes to not sent", c.answer_state(500) == "not sent" and c.answer_state(0) == "not sent")
check("dashboard answers: answer_state takes a reason for other codes", c.answer_state(500, "Internal Server Error") == "not sent: Internal Server Error")
check("dashboard answers: answer_needs_retry distinguishes states",
      c.answer_needs_retry("refused by h: 401") and c.answer_needs_retry("not sent: boom")
      and not c.answer_needs_retry("answered \u00b7 sent") and not c.answer_needs_retry("already answered")
      and not c.answer_needs_retry("no longer waiting"))
check("dashboard answers: answer_state_class maps states to CSS",
      c.answer_state_class("answered \u00b7 sent") == "po-answered" and c.answer_state_class("already answered") == "po-already"
      and c.answer_state_class("no longer waiting") == "po-fail" and c.answer_state_class("refused by h: 401") == "po-fail"
      and c.answer_state_class("not sent") == "po-fail" and c.answer_state_class("not sent: boom") == "po-fail")
check("dashboard answers: po-answered and po-already colours are in the CSS", ".po-answered" in c.css("light") and ".po-already" in c.css("dark"))
class AnswerH(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        self.rfile.read(length)
        token = self.headers.get("Authorization", "")
        code = int(self.path[1:4])
        if code == 401 and token:
            self.send_response(201)  # a bearer token is accepted
        else:
            self.send_response(code)
        if code == 400 and self.path == "/400":
            self.send_header("X-Reason", "kind")
        if self.path == "/409wb":
            self.send_header("X-Reason", "wrong build")
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a):
        pass
asrv = http.server.HTTPServer(("127.0.0.1", 0), AnswerH)
threading.Thread(target=asrv.serve_forever, daemon=True).start()
abase = "http://127.0.0.1:%d" % asrv.server_address[1]
# v0.72: Send builds the body from the display row; an action card without requires must still be kind action.
_row_action = c.decision_row(_check_entry_action)
check("dashboard answers: a row of an action card without requires keeps kind action in the body",
      c.answer_body(_row_action, "6bde9c70-bd8f-4ae0-a2c7-9f6d8bebde07", kind=_row_action["kind"], result="pass")["kind"] == "action")
ab = c.answer_body(_check_entry_choice, "5acd8b6f-ac7e-4fd1-91b6-8e5c7adfcd96", option="Yes", text="")
check("dashboard answers: 201 is answered · sent", c.post_answer(abase + "/201", ab) == "answered \u00b7 sent")
check("dashboard answers: 200 is answered · sent", c.post_answer(abase + "/200", ab) == "answered \u00b7 sent")
check("dashboard answers: 409 is already answered", c.post_answer(abase + "/409", ab) == "already answered")
check("dashboard answers: 404 is no longer waiting", c.post_answer(abase + "/404", ab) == "no longer waiting")
check("dashboard answers: 401 without a token is refused", c.post_answer(abase + "/401", ab).startswith("refused by"))
check("dashboard answers: 401 with a token is answered · sent", c.post_answer(abase + "/401", ab, token="secret") == "answered \u00b7 sent")
check("dashboard answers: 500 is not sent", c.post_answer(abase + "/500", ab).startswith("not sent:"))
check("dashboard answers: an X-Reason header is shown next to the reason", c.post_answer(abase + "/400", ab) == "not sent: bad request (kind)")
check("dashboard answers: a 400 without an X-Reason keeps the old status text",
      c.post_answer(abase + "/400n", ab) == "not sent: Bad Request")
check("dashboard answers: the POST waits up to 20 s", c.ANSWER_TIMEOUT == 20)
# v0.81: the receiver refuses a look answer from another build with 409 and X-Reason: wrong build.
_wb = c.post_answer(abase + "/409wb", ab)
check("dashboard answers: 409 with X-Reason wrong build is not sent: wrong build, with Retry",
      _wb == "not sent: wrong build" and c.answer_needs_retry(_wb) and c.answer_state_class(_wb) == "po-fail", _wb)
check("dashboard answers: answer_state 409 without the wrong build reason stays already answered",
      c.answer_state(409, "other") == "already answered" and c.answer_state(409, "wrong build") == "not sent: wrong build")
check("dashboard answers: a connection failure is not sent", c.post_answer("http://127.0.0.1:1/", ab).startswith("not sent:"))
asrv.shutdown()
asrv.server_close()

# v0.61 (a): a redirect is a failure and the bearer token is never forwarded.
import socket
seen_auth = []
class SinkH(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        seen_auth.append(self.headers.get("Authorization"))
        self.send_response(201); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a):
        pass
sink = http.server.HTTPServer(("127.0.0.1", 0), SinkH)
threading.Thread(target=sink.serve_forever, daemon=True).start()
sink_url = "http://127.0.0.1:%d/sink" % sink.server_address[1]
class RedirH(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        self.send_response(307); self.send_header("Location", sink_url); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a):
        pass
redir = http.server.HTTPServer(("127.0.0.1", 0), RedirH)
threading.Thread(target=redir.serve_forever, daemon=True).start()
shown = c.post_answer("http://127.0.0.1:%d/" % redir.server_address[1], c.answer_body(_check_entry_choice, c.answer_id(), option="Yes"), token="secret")
check("dashboard answers: a redirect is not sent, never answered", shown.startswith("not sent"))
check("dashboard answers: a redirect never forwards the bearer token (nothing reaches the target)", seen_auth == [])
redir.shutdown(); redir.server_close(); sink.shutdown(); sink.server_close()
# v0.61 (b): a bad status line is a Retry state, not an exception.
junk = socket.socket(); junk.bind(("127.0.0.1", 0)); junk.listen(1)
def junk_serve():
    conn, _ = junk.accept()
    conn.recv(65536); conn.sendall(b"NOT-HTTP garbage\r\n\r\n"); conn.close()
threading.Thread(target=junk_serve, daemon=True).start()
try:
    shown = c.post_answer("http://127.0.0.1:%d/" % junk.getsockname()[1], ab)
    check("dashboard answers: a bad status line is not sent (Retry), no exception", shown.startswith("not sent") and c.answer_needs_retry(shown))
except Exception as e:
    check("dashboard answers: a bad status line is not sent (Retry), no exception", False)
junk.close()
# v0.61 (c): the readiness rule and the payload fields.
ar = c.answer_ready
check("dashboard answers: choice with a write-in alone is ready", ar("choice", {"choice": None, "note": "mine"}) and not ar("choice", {"choice": None, "note": ""}) and ar("choice", {"choice": "Yes", "note": ""}))
check("dashboard answers: action Pass with a note is ready", ar("action", {"result": "Pass", "note": "fine"}) and ar("action", {"result": "Pass", "note": ""}))
check("dashboard answers: action Failed needs a step", not ar("action", {"result": "Failed", "step": None}) and ar("action", {"result": "Failed", "step": 2}) and not ar("action", {"result": None}))
check("dashboard answers: unformatted needs text", ar("unformatted", {"text": "x"}) and not ar("unformatted", {"text": ""}))
# v0.68: the 2000-character limit, the counter and multi-line text kept verbatim.
M = c.ANSWER_MAX_TEXT
check("dashboard answers: the limit is 2000", M == 2000)
check("dashboard answers: choice write-in ready at 2000, not at 2001", ar("choice", {"choice": None, "note": "x" * M}) and not ar("choice", {"choice": None, "note": "x" * (M + 1)}))
check("dashboard answers: a picked option with an over-limit write-in is not ready", not ar("choice", {"choice": "Yes", "note": "x" * (M + 1)}))
check("dashboard answers: action note ready at 2000, not at 2001", ar("action", {"result": "Pass", "note": "x" * M}) and not ar("action", {"result": "Pass", "note": "x" * (M + 1)}))
check("dashboard answers: unformatted text ready at 2000, not at 2001", ar("unformatted", {"text": "x" * M}) and not ar("unformatted", {"text": "x" * (M + 1)}))
check("dashboard answers: the limit counts the stripped text", ar("unformatted", {"text": "  " + "x" * M + "\n "}))
check("dashboard answers: counter reads n / 2000 and flags over the limit",
      c.answer_counter("") == ("0 / 2000", False) and c.answer_counter("hello world!") == ("12 / 2000", False)
      and c.answer_counter("x" * M) == ("2000 / 2000", False) and c.answer_counter("x" * (M + 1)) == ("2001 / 2000", True)
      and c.answer_counter("  ab \n") == ("2 / 2000", False))
ml = "line one\n\nline three\n  indented"
check("dashboard answers: multi-line text is kept verbatim (choice, action, unformatted)",
      c.answer_params("choice", {"choice": None, "note": ml})["text"] == ml
      and c.answer_params("action", {"result": "Failed", "step": 1, "note": ml})["note"] == ml
      and c.answer_params("unformatted", {"text": ml})["text"] == ml)
ap = c.answer_params
check("dashboard answers: a write-in alone sends option null and the text", ap("choice", {"choice": None, "note": "mine"}) == {"option": None, "text": "mine"})
check("dashboard answers: Pass sends lowercase pass, step null even after a Failed step", ap("action", {"result": "Pass", "step": 2, "note": ""}) == {"result": "pass", "step": None, "note": None})
check("dashboard answers: Failed sends lowercase failed with its step and note", ap("action", {"result": "Failed", "step": 2, "note": "n"}) == {"result": "failed", "step": 2, "note": "n"})
check("dashboard answers: the body client is exactly po-dashboard", c.answer_body(_check_entry_choice, c.answer_id())["client"] == "po-dashboard")
# v0.61 (f): the slow mark reads digits only, as the manifest schema does.
for raw, want in (("45", 45), ("-5", 300), ("1_0", 300), ("x", 300), ("", 300)):
    os.environ["PO_SLOW_AFTER"] = raw
    check("dashboard slow_after %r reads %d" % (raw, want), c.slow_after() == want)
del os.environ["PO_SLOW_AFTER"]

# The style: contrast of the palette, read back from the generated CSS.
for variant in sorted(c.PALETTES):
    props = c.css_properties(c.css(variant))
    for fg, bg, role in c.CONTRAST_PAIRS:
        ratio = c.contrast_ratio(props[fg]["color"], props[bg]["background-color"])
        check("dashboard css %s: %s has contrast >= 4.5 (%.2f)" % (variant, role, ratio), ratio >= 4.5)
    # v0.142 (6): a pressed (checked) control is filled with the accent, not only inset (1.7:1 light, 1.2:1 dark)
    check("dashboard css %s: cards and toggle are raised, a checked toggle is filled with the accent" % variant,
          "inset" not in props[".po-card"]["box-shadow"] and "inset" not in props[".po-toggle"]["box-shadow"]
          and props[".po-toggle:checked"]["background-color"] == c.PALETTES[variant]["accent"])
    _base = props["window.po-dashboard"]["background-color"]
    for sel, prop, role in c.EDGE_PAIRS:
        col = c.css_color(props[sel][prop])
        ratio = c.contrast_ratio(col, _base) if col else 0
        check("dashboard css %s: v0.142 %s reaches 3:1 on the surface (%.2f)" % (variant, role, ratio), ratio >= 3)
    for sel in (".po-view:checked", ".po-small:checked", ".po-toggle:checked"):
        check("dashboard css %s: v0.142 %s is the accent fill with its own text colour, not an inset shadow alone" % (variant, sel),
              props[sel]["background-color"] == c.PALETTES[variant]["accent"] and props[sel]["color"] == c.PALETTES[variant]["on_accent"]
              and props[sel]["box-shadow"] == "none")
    # v0.154: a small button's border box is 24 px tall (ui-guidelines 1.10, WCAG 2.2 2.5.8), read from the generated CSS:
    # GTK applies min-height to the content box, so the target is min-height + padding + border, never min-height alone
    _sm = props[".po-small"]
    _px = lambda v: [int(x) for x in re.findall(r"(\d+)px", v)]
    _tall = _px(_sm["min-height"])[0] + 2 * _px(_sm["padding"])[0] + 2 * _px(_sm["border"])[0]
    check("dashboard css %s: v0.154 .po-small min-height, padding and border add up to a 24 px button (%d)" % (variant, _tall), _tall == 24)
    check("dashboard css %s: v0.154 .po-small keeps its checked, disabled and focus states" % variant,
          props[".po-small:checked"]["background-color"] == c.PALETTES[variant]["accent"] and props[".po-small:checked"]["color"] == c.PALETTES[variant]["on_accent"]
          and props[".po-small:disabled"]["color"] == c.PALETTES[variant]["muted"] and props[".po-small:focus-visible"]["outline"] == "2px solid " + props[".po-small"]["color"])
    # v0.142 (7): one raised panel per list, the rows inside it flat (no shadow, no radius) with a hairline between them
    check("dashboard css %s: v0.142 a list panel is raised, with the base colour" % variant,
          props[".po-panel"]["background-color"] == _base and "inset" not in props[".po-panel"]["box-shadow"] and props[".po-panel"]["box-shadow"] != "none")
    _row = props[".po-panel .po-row"]
    check("dashboard css %s: v0.142 a row in a panel is flat, a hairline above it, none above the first" % variant,
          _row["box-shadow"] == "none" and _row["border-radius"] == "0" and _row["margin"].startswith("0 ")
          and c.css_color(_row["border-top"]) == c.PALETTES[variant]["hairline"] and props[".po-panel .po-row:first-child"]["border-top-color"] == "transparent")
    # v0.142 (19): header, panels, cards and charts carry a rim whose top edge is lighter than the surface; in the dark theme
    # (shadows 1.2:1) it is the edge you see, so it must stand out: 2:1 at least, and lighter than the base
    for sel in (".po-header", ".po-panel", ".po-card", ".po-chart"):
        top = props[sel]["border-top-color"]
        r = c.contrast_ratio(top, _base)
        check("dashboard css %s: v0.142 %s has a lighter top edge (%.2f)" % (variant, sel, r),
              c.luminance(top) > c.luminance(_base) and (r >= 2 if variant == "dark" else True))
    check("dashboard css %s: one base colour for window, header, card, toggle" % variant,
          len({props[s]["background-color"] for s in ("window.po-dashboard", ".po-header", ".po-card", ".po-toggle")}) == 1)
# The new-event highlight: the maths, and AA text at every step read back from the CSS.
check("dashboard fade: a first fetch has no new events", c.new_keys(None, ev) == [])
seen = {c.event_key(e) for e in ev[:10]}
check("dashboard fade: only events not seen before are new", c.new_keys(seen, ev) == [c.event_key(e) for e in ev[10:]])
check("dashboard fade: an event is its content, key order aside", c.event_key({"a": 1, "b": 2}) == c.event_key({"b": 2, "a": 1}))
check("dashboard fade: starts at full strength", c.fade_step(0) == c.FADE_STEPS)
check("dashboard fade: back to normal after 60 s", c.fade_step(60) == 0 and c.fade_step(600) == 0 and c.FADE_SECONDS == 60)
check("dashboard fade: halfway is half the steps", c.fade_step(30) == c.FADE_STEPS // 2)
check("dashboard fade: the steps only go down", all(c.fade_step(t / 4) >= c.fade_step((t + 1) / 4) for t in range(240)))
check("dashboard fade: reduced motion keeps the full highlight until 60 s", c.fade_step(0, True) == c.fade_step(59.9, True) == c.FADE_STEPS and c.fade_step(60, True) == 0)
check("dashboard fade: light cards start 25% darker", c.card_color("light", c.FADE_STEPS) == c.mix(c.PALETTES["light"]["base"], "#000000", 0.25))
check("dashboard fade: dark cards start 25% lighter", c.card_color("dark", c.FADE_STEPS) == c.mix(c.PALETTES["dark"]["base"], "#ffffff", 0.25))
check("dashboard fade: step 0 is the normal card colour", all(c.card_color(v, 0) == c.PALETTES[v]["base"] for v in c.PALETTES))
for variant in sorted(c.PALETTES):
    props = c.css_properties(c.css(variant))
    lum = [c.luminance(props[".po-card.po-fade-%d" % n]["background-color"]) for n in range(1, c.FADE_STEPS + 1)]
    check("dashboard fade css %s: the card colour eases monotonically to the base" % variant,
          lum == sorted(lum, reverse=variant == "light") and lum[-1] != c.luminance(c.PALETTES[variant]["base"]))
    for n in (c.FADE_STEPS, c.FADE_STEPS // 2, 1):
        bg = props[".po-card.po-fade-%d" % n]["background-color"]
        for cls, _key in c.FADE_TEXT:
            ratio = c.contrast_ratio(props[".po-fade-%d .%s" % (n, cls)]["color"], bg)
            check("dashboard fade css %s: %s keeps contrast >= 4.5 at step %d (%.2f)" % (variant, cls, n, ratio), ratio >= 4.5)
    worst = min(c.contrast_ratio(props[".po-fade-%d .%s" % (n, cls)]["color"], props[".po-card.po-fade-%d" % n]["background-color"])
                for n in range(1, c.FADE_STEPS + 1) for cls, _k in c.FADE_TEXT)
    check("dashboard fade css %s: every step, every text colour is >= 4.5 (%.2f)" % (variant, worst), worst >= 4.5)
# po serve pages: the same highlight, as a CSS animation with a reduced-motion fallback.
import serve as sv
pg = sv.page(ev[:3], None, False)
check("serve page: a row that appears fades over 60 s, from the page's own animation", "animation:fade 60s linear" in pg and sv.FADE_SECONDS == 60)
check("serve page: reduced motion drops the animation but keeps the highlight", pg.count("prefers-reduced-motion:reduce") == 2 and "tr.new td{animation:none}" in pg)
check("serve page: rows rendered by the server start normal", 'class="new"' not in pg and "<tr class" not in pg)
check("serve page: the script marks only events seen after the first fetch", "if (seen) for (const k of keys) if (!seen.has(k)) born.set" in pg)
# time taken (item v0.54): the dashboard column and the po serve page
tk_old, tk_mid, tk_long = ev[0], dict(ev[1], seconds=252), dict(ev[2], seconds=301)
check("dashboard took: 57 s reads 57s, 252 s reads 4m12s, 3723 s reads 1h02m03s, unknown reads -",
      [c.row(dict(ev[0], seconds=n), utc)["took"] for n in (57, 252, 3723)] == ["57s", "4m12s", "1h02m03s"] and c.row(tk_old, utc)["took"] == "-")
check("dashboard took: only a run over slow_after (default 300) is slow; unknown never", [c.row(dict(ev[0], seconds=n), utc)["slow"] for n in (300, 301)] == [False, True] and not c.row(tk_old, utc)["slow"])
os.environ["PO_SLOW_AFTER"] = "1"
check("dashboard took: PO_SLOW_AFTER moves the threshold", c.row(dict(ev[0], seconds=2), utc)["slow"] and not c.row(dict(ev[0], seconds=1), utc)["slow"])
del os.environ["PO_SLOW_AFTER"]
check("dashboard sort: took sorts by seconds, not text, unknown first", [e.get("seconds") for e in c.sorted_events([dict(ev[0], seconds=252), dict(ev[1], seconds=57), ev[2]], ("took", False))] == [None, 57, 252])
check("dashboard took: a boolean or negative seconds is unknown", c.row(dict(ev[0], seconds=True), utc)["took"] == "-" and c.row(dict(ev[0], seconds=-3), utc)["took"] == "-")
pg = sv.page([tk_long, tk_mid, tk_old], None, True)
check("serve page: the took column has a header and shows 5m01s, 4m12s and -", '<th class="c-took">took</th>' in pg and '>5m01s<' in pg and '>4m12s<' in pg and '<td class="c-took" title="-">-</td>' in pg)
check("serve page: a run over slow_after is marked slow, others are not", pg.count('<td class="c-took slow"') == 1)
for variant, base, target, normal in (("light", "#ffffff", "#000000", {"text": "#222222", "muted": "#555555"}), ("dark", "#181818", "#ffffff", {"text": "#dddddd", "muted": "#aaaaaa"})):
    start = c.mix(base, target, 0.25)
    for role, col in sv.NEW_TEXT[variant].items():
        ratio = c.contrast_ratio(col, start)
        check("serve page %s: %s text keeps contrast >= 4.5 on the strongest highlight (%.2f)" % (variant, role, ratio), ratio >= 4.5)
        check("serve page %s: %s text is in the page's CSS" % (variant, role), col in pg)
# sortable columns (item v0.31)
sv_ev = [{"time": t, "item": i, "project": pr, "result": r, "kind": "stamp", "agent": ag, "legs": []} for t, i, pr, r, ag in (
    ("2026-10-23T09:00:00-04:00", "1.9", "beta", "pass", "x"), ("2026-10-23T12:00:00Z", "1.11", "Alpha", "fail", "y"),
    ("2026-10-23T08:00:00Z", "1.2", "gamma", "pass", "z"))]
check("dashboard sort: no sort keeps the given order", [e["item"] for e in c.sorted_events(sv_ev, None)] == ["1.9", "1.11", "1.2"])
check("dashboard sort: time sorts by instant, not text (09:00-04:00 is 13:00Z)", [e["item"] for e in c.sorted_events(sv_ev, ("time", False))] == ["1.2", "1.11", "1.9"])
check("dashboard sort: descending reverses", [e["item"] for e in c.sorted_events(sv_ev, ("time", True))] == ["1.9", "1.11", "1.2"])
check("dashboard sort: item compares numbers inside the text (1.9 < 1.11)", [e["item"] for e in c.sorted_events(sv_ev, ("item", False))] == ["1.2", "1.9", "1.11"])
check("dashboard sort: project ignores case", [e["project"] for e in c.sorted_events(sv_ev, ("project", False))] == ["Alpha", "beta", "gamma"])
check("dashboard sort: an unreadable time sorts first ascending", c.sorted_events(sv_ev + [{"time": "soon", "item": "q"}], ("time", False))[0]["item"] == "q")
check("dashboard sort: rows() sorts the last 10 it shows, not the whole feed", [r["item"] for r in c.rows(ev, False, None, ("item", False))] == sorted((r["item"] for r in c.rows(ev, False)), key=c.natural_key))
check("dashboard sort: every events column can be sorted", all(c.sorted_events(ev, (k[0], False)) is not None for k in c.COLUMNS))
check("dashboard sort: click cycles ascending, descending, default", c.next_sort(None, "item") == ("item", False) and c.next_sort(("item", False), "item") == ("item", True) and c.next_sort(("item", True), "item") is None)
check("dashboard sort: a click on another column starts it ascending", c.next_sort(("item", True), "time") == ("time", False))
check("dashboard sort: the mark is an arrow on the sorted column only", c.sort_mark(("time", False), "time") == "\u25b2" and c.sort_mark(("time", True), "time") == "\u25bc" and c.sort_mark(("time", True), "item") == "" and c.sort_mark(None, "time") == "")
tm = [{"agent": "b", "state": "idle 5m", "now": "1.10", "owns": []}, {"agent": "A", "state": "WORKING", "now": "1.9", "owns": ["x"], "model": "m"}]
check("dashboard sort: team None keeps the saved order", [e["agent"] for e in c.sorted_team(tm, None)] == ["b", "A"])
check("dashboard sort: team agent ignores case, now compares numbers", [e["agent"] for e in c.sorted_team(tm, ("agent", False))] == ["A", "b"] and [e["agent"] for e in c.sorted_team(tm, ("now", False))] == ["A", "b"])
check("dashboard sort: team columns are the line's fields", c.TEAM_COLUMNS == ("agent", "model", "status", "now", "owns") and all(k in c.team_row(tm[0]) for k in c.TEAM_COLUMNS))
check("dashboard sort: sorting does not change the list it is given", [e["agent"] for e in tm] == ["b", "A"])
check("dashboard css: the column header style exists with a focus ring", ".po-colhead" in c.css("light") and ".po-colhead:focus-visible" in c.css("dark"))
check("dashboard css: the two variants differ", c.css("light") != c.css("dark"))
check("dashboard: contrast of black on white is 21", round(c.contrast_ratio("#000000", "#ffffff")) == 21)
check("dashboard: the old pale grey on white fails AA (v0.108)", c.contrast_ratio("#aab2bf", "#ffffff") < 4.5)
for variant in sorted(c.PALETTES):
    _p = c.PALETTES[variant]
    _h = c.css_properties(c.css(variant))[".po-dhead"]
    check("dashboard css %s: the collapsed decision header takes the theme base and text (v0.108)" % variant,
          _h["background-color"] == _p["base"] and _h["color"] == _p["text"])
# Projects feed (v0.37): parse, counts, light, filter, failed fetch.
pr = c.parse_projects('[{"project":"p","items":[{"item":"1","status":"TODO","agents":"x"},{"item":"2","status":"DONE","agents":["a","b"],"title":"T"}]}, 42, "s", {"items":"nope"}, {"project":"q","last_event":null}]')
check("dashboard projects: a broken entry is skipped, a missing field defaults",
      [p["project"] for p in pr] == ["p", "", "q"] and pr[1]["items"] == [] and pr[2]["last_event"] is None and pr[0]["items"][0]["title"] == "")
check("dashboard projects: agents is always a list, in the feed's order", pr[0]["items"][0]["agents"] == [] and pr[0]["items"][1]["agents"] == ["a", "b"])
check("dashboard projects: a non-dict item is skipped", len(c.parse_projects('[{"project":"p","items":[1,null,{"item":"1","status":"TODO"}]}]')[0]["items"]) == 1)
check("dashboard projects: empty text is no projects", c.parse_projects("  ") == [])
for name, text in (("not JSON", "{oops"), ("a JSON object", '{"project":"p"}')):
    try:
        c.parse_projects(text)
        check("dashboard projects: %s is a DashboardError" % name, False)
    except c.DashboardError:
        check("dashboard projects: %s is a DashboardError" % name, True)
st = lambda *words: [{"status": w} for w in words]
check("dashboard projects: PAUSED and BLOCKED count as DOING, HELD counts nowhere",
      c.project_counts(st("TODO", "DOING", "PAUSED", "BLOCKED", "DONE", "HELD", "", "weird")) == {"todo": 1, "doing": 3, "done": 1, "released": 0})
check("dashboard projects: an empty or missing item list counts zero", c.project_counts([]) == c.project_counts(None) == {"todo": 0, "doing": 0, "done": 0, "released": 0})
pnow = datetime.datetime(2026, 10, 26, 12, 0, 0, tzinfo=utc)
ago = lambda **kw: (pnow - datetime.timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")
check("dashboard projects: the light thresholds are 30 minutes and 24 hours", c.PROJECT_ACTIVE_MINUTES == 30 and c.PROJECT_IDLE_HOURS == 24)
check("dashboard projects: exactly 30 minutes old is active, one second more is idle",
      c.project_light(ago(minutes=30), pnow) == "active" and c.project_light(ago(minutes=30, seconds=1), pnow) == "idle" and c.project_light(ago(), pnow) == "active")
check("dashboard projects: exactly 24 hours old is idle, one second more is inactive",
      c.project_light(ago(hours=24), pnow) == "idle" and c.project_light(ago(hours=24, seconds=1), pnow) == "inactive")
check("dashboard projects: null, absent and unparseable are inactive",
      c.project_light(None, pnow) == c.project_light("", pnow) == c.project_light("soon", pnow) == "inactive")
check("dashboard projects: a time ahead of the clock is active within a minute, inactive beyond",
      c.project_light(ago(seconds=-60), pnow) == "active" and c.project_light(ago(seconds=-61), pnow) == "inactive")
check("dashboard projects: a zone is compared as an instant", c.project_light("2026-10-26T07:50:00-04:00", pnow) == "active")
fi = [{"item": "a", "status": "TODO"}, {"item": "b", "status": "DONE"}, {"item": "c", "status": "DOING"}, {"item": "d", "status": "HELD"}, {"item": "e", "status": "BLOCKED"}, {"item": "f", "status": "TODO"}]
fl = lambda f: [x["item"] for x in c.filter_items(fi, f)]
check("dashboard projects: All keeps every item in the feed's order, HELD included", fl("All") == list("abcdef"))
check("dashboard projects: TODO and DONE keep the feed's order", fl("TODO") == ["a", "f"] and fl("DONE") == ["b"])
check("dashboard projects: DOING includes PAUSED and BLOCKED, not HELD", fl("DOING") == ["c", "e"])
_nc = [{"item": "57", "status": "DONE (no change needed: x)"}, {"item": "58", "status": "held: later"}, {"item": "59", "status": "doing."}, {"item": "60", "status": "todo"}]
check("dashboard projects: status_word is the first word, upper-cased, punctuation stripped",
      c.status_word("DONE (no change needed: x)") == "DONE" and c.status_word("doing") == "DOING" and c.status_word("DONE:") == "DONE" and c.status_word("") == c.status_word(None) == "")
check("dashboard projects: `DONE (no change needed: x)` counts as DONE and shows under the DONE filter",
      c.project_counts(_nc)["done"] == 1 and [x["item"] for x in c.filter_items(_nc, "done")] == ["57"])
check("dashboard projects: lowercase and a trailing colon count by the status word", c.project_counts(_nc) == {"todo": 1, "doing": 1, "done": 1, "released": 0} and [x["item"] for x in c.filter_items(_nc, "doing")] == ["59"])
check("dashboard projects: HELD counts in All only and counts_add_up names it", [x["item"] for x in c.filter_items(_nc, "all")] == ["57", "58", "59", "60"] and [x["item"] for x in c.counts_add_up(_nc)] == ["58"])
check("dashboard projects: the not-in-a-filter line names the items, empty when none", c.not_in_filter_line(_nc) == "1 not in a filter: 58" and c.not_in_filter_line(_nc[:1]) == "" and c.counts_add_up(None) == [])
_feed = [{"status": w} for w in ["TODO"] * 2 + ["DOING"] + ["DONE"] * 3 + ["DONE (no change needed: y)", "HELD"]]
_fc = c.project_counts(_feed)
check("dashboard projects: the feed shape, todo + doing + done + unlisted = All", _fc["todo"] + _fc["doing"] + _fc["done"] + len(c.counts_add_up(_feed)) == len(_feed) == 8)
_sr = c.project_screen({"project": "p", "items": _nc}, "all", pnow)
check("dashboard project screen: a row keeps the full status, word and muted note, and the screen carries the lost line",
      _sr["rows"][-1]["status"] == "DONE" and _sr["rows"][-1]["note"] == "(no change needed: x)" and _sr["rows"][-1]["full"] == "DONE (no change needed: x)" and _sr["lost"] == "1 not in a filter: 58")
check("dashboard projects: the list given is not changed", [x["item"] for x in fi] == list("abcdef"))
pf = c.parse_projects(open(sys.argv[1] + "/../../examples/projects-feed.json").read())
pcl = c.project_check_lines(pf, datetime.datetime(2026, 10, 26, 1, 10, 0, tzinfo=utc))
check("dashboard projects: the example feed has one project per light, items in every status",
      [l.split(" | ")[1] for l in pcl] == ["active", "idle", "inactive"] and {i["status"] for p in pf for i in p["items"]} >= {"TODO", "DOING", "PAUSED", "HELD", "DONE"})
check("dashboard projects: the example's DONE agents are in order", [i["agents"] for i in pf[0]["items"] if i["status"] == "DONE"] == [["dee", "cy", "ana"]])
check("dashboard projects: --check prints name, light, todo/doing/done/released, the release and open setup steps", pcl == ["orchard | active | 1/1/1/0 | release-3 | setup open 2", "harbor | idle | 0/1/0/0 | no release", "meadow | inactive | 0/0/1/1 | v2.1 | setup open 1 | feed error: po released --json: exit 1"])
_pn = datetime.datetime(2026, 10, 26, 1, 10, 0, tzinfo=utc)
_st0 = c.project_view_state()
check("dashboard project screen: the state starts on the overview with no filters", _st0 == {"open": None, "filters": {}})
_st1 = c.project_state_open(_st0, "orchard")
check("dashboard project screen: opening a project records it and leaves the old state alone", _st1["open"] == "orchard" and _st0["open"] is None)
check("dashboard project screen: back returns to the overview", c.project_state_back(_st1)["open"] is None)
check("dashboard project screen: v0.142 the filter starts at DOING (was All)", c.project_state_filter(_st1, "orchard") == "doing" and c.PROJECT_DEFAULT_FILTER == "doing")
_st2 = c.project_state_set_filter(_st1, "orchard", "DONE")
check("dashboard project screen: a filter choice is kept for that project only", c.project_state_filter(_st2, "orchard") == "done" and c.project_state_filter(_st2, "harbor") == "doing")
check("dashboard project screen: the filter survives back and reopening", c.project_state_filter(c.project_state_open(c.project_state_back(_st2), "orchard"), "orchard") == "done")
check("dashboard project screen: v0.142 an unknown filter reads as the default, DOING", c.project_state_filter(c.project_state_set_filter(_st1, "orchard", "bogus"), "orchard") == "doing")
check("dashboard project screen: a refresh keeps the open project and filter while it is in the feed", c.project_state_reconcile(_st2, pf) == _st2)
_gone = c.project_state_reconcile(_st2, pf[1:])
check("dashboard project screen: a project that left the feed returns to the overview and drops its filter", _gone["open"] is None and _gone["filters"] == {})
check("dashboard project screen: no feed yet keeps nothing open", c.project_state_reconcile(_st2, None)["open"] is None)
_ps = c.project_screen(pf[0], "all", _pn)
check("dashboard project screen: the header has the name and the light in words", _ps["name"] == "orchard" and _ps["light"] == "active" and "active" in _ps["text"])
check("dashboard project screen: filter buttons are All, TODO, DOING, DONE, RELEASED with their counts", [(f["label"], f["count"]) for f in _ps["filters"]] == [("All", 3), ("TODO", 1), ("DOING", 1), ("DONE", 1), ("RELEASED", 0)])
check("dashboard project screen: HELD counts in All only", [(f["label"], f["count"]) for f in c.project_screen(pf[1], "all", _pn)["filters"]] == [("All", 13), ("TODO", 0), ("DOING", 1), ("DONE", 0), ("RELEASED", 0)])
check("dashboard project screen: v0.142 rows are newest first (the feed's order reversed) with id, title and status badge", [(r["item"], r["title"], r["status"]) for r in _ps["rows"]] == [("3.3", "Harvest", "DONE"), ("3.2", "Water", "DOING"), ("3.1", "Plant", "TODO")])
check("dashboard project screen: TODO lists the agents that could take it", _ps["rows"][2]["agents"] == ["ana", "ben"] and not _ps["rows"][2]["live"])
check("dashboard project screen: DOING marks the current agent live", _ps["rows"][1]["agents"] == ["cy"] and _ps["rows"][1]["live"])
check("dashboard project screen: DONE lists every agent in the feed's order, not live", _ps["rows"][0]["agents"] == ["dee", "cy", "ana"] and not _ps["rows"][0]["live"])
check("dashboard project screen: no agent is a muted dash", c.project_screen(pf[1], "all", _pn)["rows"][-2]["dash"] and not _ps["rows"][0]["dash"])
check("dashboard project screen: a DOING row with no agent is not live", not c.project_screen({"project": "p", "items": [{"item": "1", "status": "DOING", "agents": []}]}, "all", _pn)["rows"][0]["live"])
check("dashboard project screen: the filter narrows the rows, counts stay", [r["item"] for r in c.project_screen(pf[0], "done", _pn)["rows"]] == ["3.3"] and c.project_screen(pf[0], "done", _pn)["filters"][0]["count"] == 3)
check("dashboard project screen: PAUSED shows under DOING", [r["item"] for r in c.project_screen(pf[1], "doing", _pn)["rows"]] == ["1.1"])
check("dashboard project screen: a project with no items has no rows", c.project_screen({"project": "p"}, "all", _pn)["rows"] == [] and c.project_screen({"project": "p"}, "all", _pn)["filters"][0]["count"] == 0)
pdir = tempfile.mkdtemp()
pfile = os.path.join(pdir, "projects.json")
open(pfile, "w").write(open(sys.argv[1] + "/../../examples/projects-feed.json").read())
got, note = c.load_projects("file://" + pfile)
check("dashboard projects: a good fetch gives the projects and no note", len(got) == 3 and note == "")
open(pfile, "w").write("{oops")
got2, note2 = c.load_projects("file://" + pfile, got)
check("dashboard projects: a failed fetch keeps the last data and says so", got2 is got and "showing the last projects data" in note2)
os.remove(pfile)
got3, note3 = c.load_projects("file://" + pfile, got)
check("dashboard projects: a missing file keeps the last data too", got3 is got and "showing the last projects data" in note3)
got4, note4 = c.load_projects("file://" + pfile)
check("dashboard projects: a failed first fetch has no data and the plain reason", got4 is None and note4 and "last projects data" not in note4)
os.rmdir(pdir)
# The Projects card (v0.38): the text a card's tooltip and accessible label carry names the light in words.
_pc = c.project_card(pf[0], pnow)
check("dashboard projects: a card carries name, light and the four counts", _pc["name"] == pf[0]["project"] and _pc["light"] in ("active", "idle", "inactive") and sorted(_pc["counts"]) == ["doing", "done", "released", "todo"])
_pl = {"project": "p", "last_event": "2026-10-26T11:50:00Z", "items": [{"item": "1", "status": "TODO"}, {"item": "2", "status": "DOING"}, {"item": "3", "status": "DONE"}, {"item": "4", "status": "DONE"}]}
check("dashboard projects: the card text names the light in words, not only colour", c.project_card(_pl, pnow)["text"] == "p, active, TODO 1, DOING 1, DONE 2, RELEASED 0, no release")
check("dashboard projects: the card text names an idle and an inactive light too", ", idle," in c.project_card(dict(_pl, last_event="2026-10-26T01:00:00Z"), pnow)["text"] and ", inactive," in c.project_card(dict(_pl, last_event=None), pnow)["text"])
# v0.130: idle_hours per DOING item: `idle 3h` (`active` under 1 h), stalled from 2 h; a feed without the key reads as before.
_ih = c.parse_projects(json.dumps([{"project": "p", "items": [
    {"item": "1", "status": "DOING", "agents": ["a"], "idle_hours": 0}, {"item": "2", "status": "DOING", "agents": ["a"], "idle_hours": 5.9},
    {"item": "3", "status": "DOING", "agents": ["a"], "idle_hours": 72}, {"item": "4", "status": "DOING", "agents": ["a"], "idle_hours": None},
    {"item": "5", "status": "DOING", "agents": ["a"]}, {"item": "6", "status": "DOING", "agents": ["a"], "idle_hours": "x"},
    {"item": "7", "status": "DOING", "agents": ["a"], "idle_hours": 1}, {"item": "8", "status": "DOING", "agents": ["a"], "idle_hours": 2},
    {"item": "9", "status": "TODO", "idle_hours": 9}]}]))[0]
_ihr = [(r["idle"], r["stalled"]) for r in reversed(c.project_screen(_ih, "all", pnow)["rows"])]  # back to feed order
check("v0.130 dashboard projects: a row says active under 1 h, else idle Nh rounded down", _ihr[0] == ("active", False) and _ihr[1] == ("idle 5h", True) and _ihr[2] == ("idle 72h", True) and _ihr[6] == ("idle 1h", False), repr(_ihr))
check("v0.130 dashboard projects: a row is stalled from 2 h", _ihr[7] == ("idle 2h", True))
check("v0.130 dashboard projects: no, null or unreadable idle_hours shows nothing, and a TODO row shows none", _ihr[3] == _ihr[4] == _ihr[5] == _ihr[8] == ("", False), repr(_ihr))
# v0.142 (16): status is never colour alone: a stalled row says so in words, and every light has its words beside the dot
_ihw = [r["idle_words"] for r in reversed(c.project_screen(_ih, "all", pnow)["rows"])]
check("dashboard projects: v0.142 a stalled row says `stalled` in words, an active or idle one does not",
      _ihw[0] == "active" and _ihw[1] == "idle 5h, stalled" and _ihw[6] == "idle 1h" and _ihw[7] == "idle 2h, stalled" and _ihw[3] == _ihw[8] == "", repr(_ihw))
_lw = lambda **kw: c.project_light_word((pnow - datetime.timedelta(**kw)).isoformat(), pnow)
check("dashboard projects: v0.142 the light's words: `active`, `idle 45 min`, `idle 3 h`, `stalled 4 d`",
      [_lw(minutes=5), _lw(minutes=45), _lw(hours=3, minutes=59), _lw(hours=24), _lw(days=4, hours=6)] == ["active", "idle 45 min", "idle 3 h", "idle 24 h", "stalled 4 d"],
      repr([_lw(minutes=5), _lw(minutes=45), _lw(hours=3, minutes=59), _lw(hours=24), _lw(days=4, hours=6)]))
check("dashboard projects: v0.142 a day and a second past the idle limit is `stalled 1 d`, no or a future time `no events`",
      _lw(hours=24, seconds=1) == "stalled 1 d" and c.project_light_word(None, pnow) == c.project_light_word("soon", pnow) == "no events"
      and c.project_light_word((pnow + datetime.timedelta(hours=2)).isoformat(), pnow) == "no events")
check("dashboard projects: v0.142 a project switched off is not called stalled: `last event 4 d ago`",
      c.project_light_word((pnow - datetime.timedelta(days=4)).isoformat(), pnow, active=False) == "last event 4 d ago"
      and c.project_light_word((pnow - datetime.timedelta(days=4)).isoformat(), pnow, active=True) == "stalled 4 d")
_states = {"active": dict(minutes=1), "idle": dict(hours=2), "inactive": dict(days=3)}
check("dashboard projects: v0.142 every light state has its words on the card and the screen, and they begin with the state's word",
      all(c.project_card(dict(_pl, last_event=(pnow - datetime.timedelta(**kw)).isoformat()), pnow)["word"].split()[0] == {"active": "active", "idle": "idle", "inactive": "stalled"}[st]
          and c.project_card(dict(_pl, last_event=(pnow - datetime.timedelta(**kw)).isoformat()), pnow)["light"] == st
          and c.project_screen(dict(_pl, last_event=(pnow - datetime.timedelta(**kw)).isoformat()), "all", pnow)["word"]
          == c.project_card(dict(_pl, last_event=(pnow - datetime.timedelta(**kw)).isoformat()), pnow)["word"] for st, kw in _states.items())
      and c.project_card(dict(_pl, last_event=None), pnow)["word"] == "no events")
check("dashboard projects: v0.142 the desktop puts the words beside the dot on the card and on the screen",
      'top.append(self.label(c["word"], "po-muted"))' in open(sys.argv[1] + "/../../bin/po-dashboard").read()
      and 'head.append(self.label(screen["word"], "po-muted"))' in open(sys.argv[1] + "/../../bin/po-dashboard").read())
check("dashboard project screen: v0.142 an empty filter says which, an empty project says no items",
      c.project_screen({"project": "p", "items": [{"item": "1", "status": "TODO"}]}, "doing", pnow)["empty"] == "no DOING items"
      and c.project_screen({"project": "p"}, "doing", pnow)["empty"] == "no items")
# v0.142 (12): the Reports header is `Reports` over `7 d · as of <time>`, not the Events count line
_asof = datetime.datetime(2030, 5, 1, 18, 32, tzinfo=utc)
check("dashboard reports: v0.142 the header status is `7 d · as of 6:32 PM UTC`, the title `Reports`",
      c.reports_status(1, _asof, _asof, utc) == "7 d · as of 6:32 PM UTC" and c.reports_status(0, _asof, _asof, utc).startswith("24 h · ")
      and c.reports_status(2, None) == "30 d · loading…" and c.REPORTS_TITLE == "Reports" and "events" not in c.reports_status(1, _asof, _asof, utc))
check("v0.130 dashboard projects: parse keeps idle_hours as whole hours, else None", [it["idle_hours"] for it in _ih["items"]] == [0, 5, 72, None, None, None, 1, 2, 9])
# v0.109: a feed error greys the card and says so; counts and light come from the last good data in the entry.
_ep = dict(_pl, error="po released --json: exit 1")
_ec = c.project_card(c.parse_projects(json.dumps([_ep]))[0], pnow)
check("v0.109 dashboard projects: parse keeps a string error", c.parse_projects(json.dumps([_ep]))[0]["error"] == "po released --json: exit 1")
check("v0.109 dashboard projects: parse ignores a non-string, empty or absent error", [e["error"] for e in c.parse_projects(json.dumps([dict(_pl, error=5), dict(_pl, error=["x"]), dict(_pl, error=" "), dict(_pl, error=None), _pl]))] == [None] * 5)
check("v0.109 dashboard projects: an errored card says feed error in its text and keeps counts and light from the last good data",
      _ec["error"] == "po released --json: exit 1" and _ec["text"] == "p, active, TODO 1, DOING 1, DONE 2, RELEASED 0, no release, feed error: po released --json: exit 1" and _ec["counts"]["done"] == 2)
check("v0.109 dashboard projects: a card with no error has error None and the old text", c.project_card(_pl, pnow)["error"] is None and "feed error" not in c.project_card(_pl, pnow)["text"])
check("v0.109 dashboard projects: --check adds the feed error to the project's line", c.project_check_lines(c.parse_projects(json.dumps([_ep])), pnow)[0].endswith(" | feed error: po released --json: exit 1"))
check("v0.109 dashboard projects: the example feed carries one error project", [p["project"] for p in pf if p["error"]] == ["meadow"])
# v0.139: the project switch: `active` from the feed, the inactive badge, the switch body and its states.
_sw = c.parse_projects(json.dumps([dict(_pl, active=False), dict(_pl, active=True), _pl, dict(_pl, active="no"), dict(_pl, active=None)]))
check("v0.139 dashboard projects: parse keeps a boolean active, anything else (absent, string, null) is None",
      [e["active"] for e in _sw] == [False, True, None, None, None], repr([e["active"] for e in _sw]))
_swc = [c.project_card(e, pnow) for e in _sw]
check("v0.139 dashboard projects: an inactive project's card has the inactive badge and says it in its text",
      _swc[0]["badge"] == "inactive" and _swc[0]["active"] is False
      and _swc[0]["text"] == "p, active, TODO 1, DOING 1, DONE 2, RELEASED 0, no release, switched off (inactive): nothing new is opened", repr(_swc[0]))
check("v0.139 dashboard projects: an active project's card has no badge and the old text",
      _swc[1]["badge"] == "" and _swc[1]["active"] is True and _swc[1]["text"] == c.project_card(_pl, pnow)["text"])
check("v0.139 dashboard projects: a feed without the key still renders: no badge, active None, the old text",
      _swc[2]["badge"] == "" and _swc[2]["active"] is None and _swc[2]["text"] == "p, active, TODO 1, DOING 1, DONE 2, RELEASED 0, no release")
check("v0.139 dashboard projects: the badge is in the CSS of both themes", ".po-badge" in c.css("light") and ".po-badge" in c.css("dark"))
_swb = c.project_active_body("orchard", False, "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41")
check("v0.139 dashboard switch: the body is {answer_id, kind project-active, project, active, answered_at, client}",
      set(_swb) == {"answer_id", "kind", "project", "active", "answered_at", "client"} and _swb["kind"] == "project-active"
      and _swb["project"] == "orchard" and _swb["active"] is False and _swb["client"] == c.CLIENT
      and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", _swb["answered_at"]) is not None, repr(_swb))
if _recv:
    _sb = c.project_active_body("orchard", True, c.answer_id())
    try:
        _rm.check_active_body(json.dumps(_sb).encode("utf-8"))
        _sok = "ok"
    except _rm.Reply as e:
        _sok = "%d %s" % (e.code, e.why)
    check("v0.139 dashboard switch: the receiver's check_active_body accepts the client's real body", _sok == "ok", _sok)
check("v0.139 dashboard switch: switch_state is empty on 200/201 and names the refusal otherwise",
      c.switch_state(201) == "" and c.switch_state(200) == "" and c.switch_state(404, "unknown project") == "not switched: unknown project"
      and c.switch_state(401, host="h") == "not switched: refused by h: 401" and c.switch_state(429).startswith("not switched: rate limit")
      and c.switch_state(0, "timed out") == "not switched: timed out" and c.switch_state(500) == "not switched: status 500")
check("v0.139 dashboard switch: a pending switch shows until the feed agrees or its hold runs out",
      c.switch_shown(True, (False, 1000.0), 1010.0) is False and c.switch_shown(True, (False, 1000.0), 1000.0 + c.SWITCH_HOLD_SECONDS) is True
      and c.switch_shown(True, None, 5.0) is True and c.switch_shown(False, (False, 1000.0), 1010.0) is False)
check("v0.139 dashboard switch: a pending switch is settled when the feed agrees or the hold ran out, not before",
      c.switch_settled(False, (False, 1000.0), 1001.0) and c.switch_settled(True, (False, 1000.0), 1000.0 + c.SWITCH_HOLD_SECONDS)
      and not c.switch_settled(True, (False, 1000.0), 1001.0) and c.switch_settled(True, None, 0.0))
_swseen = []
class SwitchH(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        _swseen.append((self.headers.get("Authorization"), json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))))
        code = int(self.path[1:4])
        self.send_response(code)
        if code == 404:
            self.send_header("X-Reason", "unknown project")
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a):
        pass
_swsrv = http.server.HTTPServer(("127.0.0.1", 0), SwitchH)
threading.Thread(target=_swsrv.serve_forever, daemon=True).start()
_swbase = "http://127.0.0.1:%d" % _swsrv.server_address[1]
check("v0.139 dashboard switch: post_switch sends the body with the bearer token; 201 is switched (empty note)",
      c.post_switch(_swbase + "/201", _swb, token="tok") == "" and _swseen[-1] == ("Bearer tok", _swb), repr(_swseen[-1:]))
check("v0.139 dashboard switch: a 404 with X-Reason unknown project says not switched: unknown project",
      c.post_switch(_swbase + "/404", _swb) == "not switched: unknown project")
check("v0.139 dashboard switch: an unreachable sink says not switched", c.post_switch("http://127.0.0.1:1/", _swb).startswith("not switched:"))
_swsrv.shutdown()
_swsrv.server_close()
# v0.140: the Release button: N from the feed (DONE and not released), the dialog title, the body and its states.
_rl = {"project": "orchard", "release": "release-23", "items": [
    {"item": "v1", "status": "DONE", "released": True}, {"item": "v2", "status": "DONE"}, {"item": "v3", "status": "DONE (tag v3)"},
    {"item": "v4", "status": "DONE", "released": True, "setup_open": 1}, {"item": "v5", "status": "TODO"},
    {"item": "v6", "status": "DOING"}, {"item": "v7", "status": "done", "released": False}]}
_rlp = c.parse_projects(json.dumps([_rl, dict(_rl, project="grove", items=[{"item": "v1", "status": "DONE", "released": True}]),
                                    dict(_rl, project="meadow", release=None, items=[{"item": "v1", "status": "DONE"}]),
                                    dict(_rl, project="heath", active=False)]))
check("v0.140 dashboard release: N counts DONE rows not released (any DONE word; a released one with setup open is released)",
      c.unreleased_done(_rlp[0]["items"]) == 3 and c.unreleased_done(None) == 0, repr(c.unreleased_done(_rlp[0]["items"])))
_rv = c.release_view(_rlp[0])
check("v0.140 dashboard release: the dialog title carries N and the last release name from the feed",
      _rv["title"] == "Release orchard: 3 DONE items since release-23" and _rv["n"] == 3 and _rv["enabled"] and _rv["why"] == "", repr(_rv))
_rv0 = c.release_view(_rlp[1])
check("v0.140 dashboard release: the button is off at N = 0 and says why",
      _rv0["n"] == 0 and not _rv0["enabled"] and _rv0["why"] == "nothing to release: no DONE item since release-23", repr(_rv0))
check("v0.140 dashboard release: one item is singular; no release yet says so",
      c.release_view(_rlp[2])["title"] == "Release meadow: 1 DONE item since the start (no release yet)", repr(c.release_view(_rlp[2])))
check("v0.140 dashboard release: an inactive project's button stays on", _rlp[3]["active"] is False and c.release_view(_rlp[3])["enabled"])
check("v0.140 dashboard release: without an answer sink the button is off and says read-only",
      not c.release_view(_rlp[0], sink=False)["enabled"] and c.release_view(_rlp[0], sink=False)["why"] == "read-only: no answer URL")
check("v0.140 dashboard release: the note counter flags more than 2000 characters (trimmed)",
      c.release_counter("  " + "x" * 2000 + "\n") == ("2000 / 2000", False) and c.release_counter("x" * 2001)[1] is True)
_rb = c.release_body("orchard", "line one\nline two ", "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41")
check("v0.140 dashboard release: the body is {answer_id, kind release-request, project, note, answered_at, client}, the note as typed",
      set(_rb) == {"answer_id", "kind", "project", "note", "answered_at", "client"} and _rb["kind"] == "release-request"
      and _rb["note"] == "line one\nline two " and _rb["client"] == c.CLIENT
      and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", _rb["answered_at"]) is not None, repr(_rb))
if _recv:
    try:
        _rm.check_release_body(json.dumps(c.release_body("orchard", "", c.answer_id())).encode("utf-8"))
        _rok = "ok"
    except _rm.Reply as e:
        _rok = "%d %s" % (e.code, e.why)
    check("v0.140 dashboard release: the receiver's check_release_body accepts the client's real body", _rok == "ok", _rok)
    check("v0.140 dashboard release: the client's note limit is the receiver's", c.RELEASE_NOTE_MAX == _rm.RELEASE_NOTE_MAX)
check("v0.140 dashboard release: release_state says sent on 200/201 and names the refusal otherwise",
      c.release_state(201) == c.RELEASE_SENT and c.release_state(200) == c.RELEASE_SENT and c.release_state(400, "note too long") == "not sent: note too long"
      and c.release_state(401, host="h") == "not sent: refused by h: 401" and c.release_state(429).startswith("not sent: rate limit")
      and c.release_state(0, "timed out") == "not sent: timed out" and c.release_state(500) == "not sent: status 500")
_rlseen = []
class ReleaseH(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        _rlseen.append((self.headers.get("Authorization"), self.rfile.read(int(self.headers.get("Content-Length", 0)))))
        code = int(self.path[1:4])
        self.send_response(code)
        if code == 400:
            self.send_header("X-Reason", "note too long")
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a):
        pass
_rlsrv = http.server.HTTPServer(("127.0.0.1", 0), ReleaseH)
threading.Thread(target=_rlsrv.serve_forever, daemon=True).start()
_rlbase = "http://127.0.0.1:%d" % _rlsrv.server_address[1]
_rbu = c.release_body("orchard", "caf\u00e9 \u2014 ok", "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41")
check("v0.140 dashboard release: post_release sends the body (UTF-8, not escaped) with the bearer token; 201 is sent",
      c.post_release(_rlbase + "/201", _rbu, token="tok") == c.RELEASE_SENT and _rlseen[-1][0] == "Bearer tok"
      and json.loads(_rlseen[-1][1]) == _rbu and "\u2014".encode() in _rlseen[-1][1], repr(_rlseen[-1:]))
check("v0.140 dashboard release: a 400 with X-Reason note too long says not sent: note too long",
      c.post_release(_rlbase + "/400", _rbu) == "not sent: note too long")
check("v0.140 dashboard release: an unreachable sink says not sent", c.post_release("http://127.0.0.1:1/", _rbu).startswith("not sent:"))
_rlsrv.shutdown()
_rlsrv.server_close()
check("dashboard projects: a card for an entry with no items counts zero", c.project_card({"project": "q"}, pnow)["text"] == "q, inactive, TODO 0, DOING 0, DONE 0, RELEASED 0, no release")
check("dashboard projects: the card lost line carries every item name, no truncation",
      c.project_card({"project": "p", "items": [{"item": "a1"}, {"item": "b2"}, {"item": "c3"}]}, pnow)["lost"] == "3 not in a filter: a1, b2, c3")
# v0.83: RELEASED and the release label.
_rp = c.parse_projects('[{"project":"p","release":"release-2","items":[{"item":"1","status":"DONE","released":true},{"item":"2","status":"DONE","released":true,"setup_open":2},{"item":"3","status":"DONE"},{"item":"4","status":"TODO","released":true},{"item":"5","status":"DONE (no change needed: x)","released":true},{"item":"6","status":"HELD"}]},{"project":"q","release":7,"items":[{"item":"1","status":"DONE","released":"yes","setup_open":"x"}]},{"project":"r","release":""}]')
check("dashboard released: parse keeps release, released and setup_open", _rp[0]["release"] == "release-2" and _rp[0]["items"][0]["released"] is True and _rp[0]["items"][1]["setup_open"] == 2 and _rp[0]["items"][2]["released"] is False and _rp[0]["items"][2]["setup_open"] == 0)
check("dashboard released: a wrong-typed or empty release, released or setup_open reads as absent", _rp[1]["release"] is None and _rp[2]["release"] is None and _rp[1]["items"][0]["released"] is False and _rp[1]["items"][0]["setup_open"] == 0)
check("dashboard released: released_items is DONE + released + no setup step open, in feed order", [x["item"] for x in c.released_items(_rp[0]["items"])] == ["1", "5"] and c.released_items(None) == [])
check("dashboard released: setup_open absent counts as none open (the v0.84 stub)", c.setup_open({"status": "DONE"}) == 0 and c.setup_open({"setup_open": True}) == 0 and c.setup_open({"setup_open": 3}) == 3)
check("dashboard released: a released item with setup open stays DONE", c.item_word(_rp[0]["items"][1]) == "DONE" and c.item_word(_rp[0]["items"][0]) == "RELEASED" and c.item_word(_rp[0]["items"][3]) == "TODO")
_rc = c.project_counts(_rp[0]["items"])
check("dashboard released: counts move released items out of DONE", _rc == {"todo": 1, "doing": 0, "done": 2, "released": 2})
check("dashboard released: the filters add up to All with RELEASED and a HELD item",
      _rc["todo"] + _rc["doing"] + _rc["done"] + _rc["released"] + len(c.counts_add_up(_rp[0]["items"])) == len(_rp[0]["items"]) and c.not_in_filter_line(_rp[0]["items"]) == "1 not in a filter: 6")
check("dashboard released: the RELEASED filter sits right after DONE", [k for _l, k in c.PROJECT_FILTERS] == ["all", "todo", "doing", "done", "released"])
check("dashboard released: the RELEASED filter lists released items, DONE the rest", [x["item"] for x in c.filter_items(_rp[0]["items"], "released")] == ["1", "5"] and [x["item"] for x in c.filter_items(_rp[0]["items"], "done")] == ["2", "3"])
_rs = c.project_screen(_rp[0], "all", pnow)
check("dashboard released: the screen row shows RELEASED, and `released, setup N open` muted on a DONE row with steps open",
      [r["status"] for r in _rs["rows"]][::-1] == ["RELEASED", "DONE", "DONE", "TODO", "RELEASED", "HELD"] and _rs["rows"][-2]["note"] == "released, setup 2 open" and _rs["rows"][-3]["note"] == "" and _rs["rows"][1]["note"] == "(no change needed: x)")
check("dashboard released: a status note and the setup-open note go together", c.project_screen({"project": "p", "items": [{"item": "1", "status": "DONE (tag v1)", "released": True, "setup_open": 1}]}, "all", pnow)["rows"][0]["note"] == "(tag v1), released, setup 1 open")
check("dashboard released: the screen filter counts include RELEASED", [(f["label"], f["count"]) for f in _rs["filters"]] == [("All", 6), ("TODO", 1), ("DOING", 0), ("DONE", 2), ("RELEASED", 2)])
check("dashboard released: release_label gives the name, plain", c.release_label(_rp[0]) == {"text": "release-2", "muted": False} and c.release_label({"release": " v1.8.2 "}) == {"text": "v1.8.2", "muted": False})
check("dashboard released: release_label is a muted `no release` for null, absent, empty or not a string",
      all(c.release_label(x) == {"text": "no release", "muted": True} for x in ({"release": None}, {}, {"release": ""}, {"release": "  "}, {"release": 3}, None)))
check("dashboard released: the card and the screen carry the label, the card text names it", c.project_card(_rp[0], pnow)["release"] == c.release_label(_rp[0]) and _rs["release"]["text"] == "release-2" and c.project_card(_rp[0], pnow)["text"].endswith(", RELEASED 2, release-2, setup open 2"))
_sp = {"project": "p", "last_event": None, "items": [{"item": "1", "status": "DONE", "setup_open": 2}, {"item": "2", "status": "DONE", "released": True, "setup_open": 1}, {"item": "3", "status": "TODO"}]}
check("dashboard setup: setup_badge is `setup N open`, None when no step is open",
      c.setup_badge({"setup_open": 2}) == "setup 2 open" and c.setup_badge({"setup_open": 1}) == "setup 1 open" and c.setup_badge({}) is None and c.setup_badge({"setup_open": "x"}) is None)
check("dashboard setup: project_setup_open sums the items' open steps", c.project_setup_open(_sp) == 3 and c.project_setup_open({"project": "q"}) == 0 and c.project_setup_open(None) == 0)
_ss = c.project_screen(_sp, "all", pnow)
check("dashboard setup: a screen row with steps open carries its badge; a released one says the count in its note instead",
      [r["setup"] for r in _ss["rows"]] == [None, None, "setup 2 open"] and _ss["rows"][1]["note"] == "released, setup 1 open")
_sc = c.project_card(_sp, pnow)
check("dashboard setup: the card counts the open steps in a muted line and its text", _sc["setup"] == "setup open 3" and _sc["text"].endswith(", no release, setup open 3"))
check("dashboard setup: a project without open steps has no setup line, its text unchanged",
      c.project_card({"project": "q"}, pnow)["setup"] == "" and c.project_card({"project": "q"}, pnow)["text"] == "q, inactive, TODO 0, DOING 0, DONE 0, RELEASED 0, no release")
check("dashboard setup: --check adds ` | setup open N` only when steps are open",
      c.project_check_lines([_sp, {"project": "q", "last_event": None, "items": []}], pnow) == ["p | inactive | 1/0/2/0 | no release | setup open 3", "q | inactive | 0/0/0/0 | no release"])
check("dashboard projects: the three lights have a colour class in both themes", all(".po-light-%s" % l in c.css_properties(c.css(v)) for l in ("active", "idle", "inactive") for v in ("light", "dark")))
check("dashboard projects: the lights are green, yellow and red, three different colours", len({c.css_properties(c.css("light"))[".po-light-%s" % l]["color"] for l in ("active", "idle", "inactive")}) == 3)
srv_proc = subprocess.Popen([sys.executable, "-I", sys.argv[1] + "/../../examples/events-demo-server.py", "--port", "0"], stdout=subprocess.PIPE, text=True)
try:
    port = int(srv_proc.stdout.readline().split("127.0.0.1:")[1].split("/")[0])
    served = c.parse_projects(c.fetch("http://127.0.0.1:%d/projects.json" % port))
    check("dashboard projects: the demo server serves the example feed, one project per light now",
          [p["project"] for p in served] == [p["project"] for p in pf] and [c.project_light(p["last_event"]) for p in served] == ["active", "idle", "inactive"])
finally:
    srv_proc.kill()
    srv_proc.wait()
# v0.75 prune_records
ev0 = [{"time":"t1","item":"a"}]
k0 = c.event_key(ev0[0])
pr = c.prune_records({k0}, {k0: 5.0}, ev0, 5.0)
check("prune_records: kept event keeps born", pr == ({k0}, {k0: 5.0}))
pr2 = c.prune_records({k0}, {k0: 5.0}, [], 5.0)
check("prune_records: left the feed drops", pr2 == (set(), {}))
pr3 = c.prune_records(None, {}, ev0, 5.0)
check("prune_records: seen None safe", pr3[0] == {k0})
pr4 = c.prune_records({k0}, {k0: 0.0}, ev0, 100.0)
check("prune_records: expired born dropped", pr4 == ({k0}, {}))
pr5 = c.prune_records(set(), {}, [], 1.0)
check("prune_records: empty", pr5 == (set(), {}))

# v0.76 paging and the card diff
_pe = [{"time": "2026-01-01T%02d:%02d:00Z" % (i // 60, i % 60), "item": str(i)} for i in range(120)]
check("page_events: under the page size holds all", len(c.page_events(_pe[:30], 50)) == 30)
check("page_events: exactly the page size holds all", len(c.page_events(_pe[:50], 50)) == 50)
check("page_events: over the page size is cut at it", c.page_events(_pe, 50) == _pe[:50])
check("page_events: a second page holds 100", c.page_events(_pe, 100) == _pe[:100])
check("page_events: empty is empty", c.page_events([], 50) == [])
check("shown_events: Show all pages after the sort (newest first by default)", [e["item"] for e in c.shown_events(_pe, True, None, 50)[0]][:2] == ["119", "118"] and c.shown_events(_pe, True, None, 50)[1] == 120)
check("shown_events: a sort applies to the whole set before the page", c.shown_events(_pe, True, ("time", False), 50)[0][0]["item"] == "0")
check("shown_events: Show all off is the last 10", len(c.shown_events(_pe, False, None, 50)[0]) == 10)
check("events_status: Show all says N of M", c.events_status(50, 120, True) == "50 of 120 events \u00b7 all" and c.events_status(7, 7, True) == "7 of 7 events \u00b7 all")
check("events_status: Show all off is unchanged", c.events_status(10, 120, False) == "120 events \u00b7 last 10")
check("diff_cards: new and gone keys", c.diff_cards(["a", "b"], ["b", "c"]) == (["c"], ["a"]))
check("diff_cards: same keys is nothing", c.diff_cards(["a", "b"], ["b", "a"]) == ([], []))
check("diff_cards: first fill adds all, empty drops all", c.diff_cards([], ["a"]) == (["a"], []) and c.diff_cards(["a"], []) == ([], ["a"]))
_ci, _dropped = c.CardIndex(), []
_evs = [{"time": "t%d" % i} for i in range(5)]
_keys = [c.event_key(e) for e in _evs]
_ci.sync(_keys, lambda k: object(), _dropped.append)
_first = dict(_ci.cards)
check("CardIndex: the first fetch builds one card per key", _ci.built == 5)
_ci.sync(list(_keys), lambda k: object(), _dropped.append)
check("CardIndex: a refresh with an unchanged feed builds zero cards", _ci.built == 5 and _dropped == [] and _ci.cards == _first)
_k6 = c.event_key({"time": "t9"})
_ci.sync([_k6] + _keys[:-1], lambda k: object(), _dropped.append)
check("CardIndex: one new and one gone builds one and drops one, reusing the rest", _ci.built == 6 and _dropped == [_first[_keys[-1]]] and all(_ci.cards[k] is _first[k] for k in _keys[:-1]))

# memory log line
line = c.memory_log_line("2026-01-01T00:00:00Z", 12, 3, 4, 5, 6)
check("memory log line format", "12MB" in line and "3 events" in line and "4 cards" in line and "seen=5" in line and "born=6" in line)

# memory log line with None rss
line2 = c.memory_log_line("2026-01-01T00:00:00Z", None, 3, 4, 5, 6)
check("memory log line None rss", "?" in line2)

# cap drops oldest half
d2 = tempfile.mkdtemp()
path2 = os.path.join(d2, "memory.log")
c.memory_log_append(path2, "FIRSTLINE")
# pad to force cap
c.memory_log_append(path2, "x" * 1100000)
content2 = open(path2).read()
check("memory log cap drops oldest", "FIRSTLINE" not in content2 and content2.endswith("\n"))

# many short lines
d3 = tempfile.mkdtemp()
path3 = os.path.join(d3, "memory.log")
for i in range(600):
    c.memory_log_append(path3, "line %d %s" % (i, "a"*50), cap=20000)
content3 = open(path3, "rb").read()
check("memory log many lines cap", len(content3) <= 20000)
check("memory log many lines last present", b"line 599" in content3 and b"line 0 " not in content3)


# write failure returns False
# make notadir a file
with open(os.path.join(d2, "notadir"), "w") as f:
    f.write("x")
try:
    r = c.memory_log_append(os.path.join(d2, "notadir", "x"), "line")
    check("memory log write failure", r is False)
except Exception:
    check("memory log write failure", False)


# ---- v0.208: the stall probe (PO_DASHBOARD_STALL_LOG) ----
check("dashboard-stall-probe-off: no PO_DASHBOARD_STALL_LOG is no probe, so nothing is written",
      c.StallProbe.from_env({}) is None and c.StallProbe.from_env({"PO_DASHBOARD_STALL_LOG": "  "}) is None)
_sd = tempfile.mkdtemp()
_sp_path = os.path.join(_sd, "sub", "stall.log")
_clock = [0.0]
_sp = c.StallProbe.from_env({"PO_DASHBOARD_STALL_LOG": _sp_path}, clock=lambda: _clock[0], now=lambda: "T")
def _slow(ms):
    _clock[0] += ms / 1000.0
    return "r"
_red = _sp.wrap("redraw", _slow)
_dat = _sp.wrap("on_data", lambda: _red(900) and _slow(5))
check("dashboard-stall-probe: the first beat logs nothing", _sp.check() is None and not os.path.exists(_sp_path))
_clock[0] += 0.05
check("dashboard-stall-probe: a 50 ms gap logs nothing", _sp.check() is None and not os.path.exists(_sp_path))
_clock[0] += 0.149
check("dashboard-stall-probe: a 149 ms gap logs nothing", _sp.check() is None and not os.path.exists(_sp_path))
_clock[0] += 0.151
_ln = _sp.check()
check("dashboard-stall-probe: a 151 ms gap logs the line", _ln == "T stall 151 ms after start (ran: none over 10 ms)", _ln)
os.remove(_sp_path)
_dat()
_ln = _sp.check()
check("dashboard-stall-probe: a gap over 150 ms logs stall <ms> ms after <callback>, naming the long callbacks inner first",
      _ln == "T stall 905 ms after on_data (ran: redraw 900, on_data 905)" and open(_sp_path).read() == _ln + "\n", _ln)
_clock[0] += 0.4
_ln = _sp.check()
check("dashboard-stall-probe: a gap no wrapped callback accounts for says so", _ln == "T stall 400 ms after on_data (ran: none over 10 ms)", _ln)
check("dashboard-stall-probe: beat keeps the GLib timeout going", _sp.beat() is True)
check("dashboard-stall-probe: the wrapped callback returns what it returned", _sp.wrap("tick", lambda: True)() is True)
_sp.note("active 1")
check("dashboard-stall-probe: a note is one line", open(_sp_path).read().splitlines()[-1] == "T active 1")
_bad = open(os.path.join(_sd, "afile"), "w"); _bad.close()
_spb = c.StallProbe(os.path.join(_sd, "afile", "stall.log"), clock=lambda: _clock[0], now=lambda: "T")
try:
    _spb.check(); _clock[0] += 1.0; _spb.check(); _spb.note("active 0")
    check("dashboard-stall-probe: an unwritable path does not raise", True)
except Exception as e:
    check("dashboard-stall-probe: an unwritable path does not raise", False, repr(e))


# ---- v0.77: the archive in the dashboard ----
_lv = [{"time": "2026-10-30T10:00:00Z", "kind": "open", "item": "1"}, {"time": "2026-10-29T10:00:00Z", "kind": "open", "item": "2"}]
_ar = [{"time": "2026-09-01T10:00:00Z", "kind": "open", "item": "7"}, {"time": "2026-10-29T10:00:00Z", "kind": "open", "item": "2"}, {"time": "2026-09-02T10:00:00Z", "kind": "close", "item": "7"}]
_w = c.with_archive(_lv, _ar)
check("with_archive: live plus archive, newest first, an event in both once", [e["item"] for e in _w] == ["1", "2", "7", "7"] and len(_w) == 4)
check("with_archive: no archive is the live events sorted", c.with_archive(_lv, None) == _lv and c.with_archive([], []) == [])
check("with_archive: an archive alone", len(c.with_archive([], _ar)) == 3)
check("archive_only: the archived events that are not live, newest first", [e["time"] for e in c.archive_only(_lv, _ar)] == ["2026-09-02T10:00:00Z", "2026-09-01T10:00:00Z"])
_lv40 = [{"time": "2026-10-%02dT10:00:00Z" % (i % 28 + 1), "kind": "stamp", "item": "L%d" % i} for i in range(60)]
_ar40 = [{"time": "2026-08-%02dT10:00:00Z" % (i % 28 + 1), "kind": "stamp", "item": "A%d" % i} for i in range(60)]
_sh, _held = c.shown_events(_lv40, True, None, 50, archive=_ar40)
check("shown_events: live events fill the first pages and the archive follows, held counts both", _held == 120 and all(e["item"].startswith("L") for e in _sh) and len(_sh) == 50)
_sh, _held = c.shown_events(_lv40, True, None, 100, archive=_ar40)
check("shown_events: the second page reaches the archive, below every live event", [e["item"][0] for e in _sh] == ["L"] * 60 + ["A"] * 40)
_sh, _held = c.shown_events(_lv40, True, ("item", False), 120, archive=_ar40)
check("shown_events: a sort sorts live and archive apart, the archive stays below", [e["item"][0] for e in _sh] == ["L"] * 60 + ["A"] * 60)
_sh, _held = c.shown_events(_lv40, False, None, 50, archive=_ar40)
check("shown_events: with Show all off the archive is not shown", len(_sh) == 10 and _held == 10)
_sh, _held = c.shown_events(_lv40, True, None, 50)
check("shown_events: no archive is the live events paged: first L27, 50 shown, held 60", _held == 60 and len(_sh) == 50 and all(e["item"].startswith("L") for e in _sh) and _sh[0]["item"] == "L27")
check("shown_events: an empty archive is the same as none", c.shown_events(_lv40, True, None, 50, archive=[]) == c.shown_events(_lv40, True, None, 50))
check("report_plan: the 24 h and 7 d ranges never need the archive", [c.report_plan(s, "u", None) for s in (86400, 7 * 86400)] == ["live", "live"])
check("report_plan: 30 d with no archive url is unconfigured", c.report_plan(30 * 86400, None, None) == "unconfigured")
check("report_plan: 30 d with a url and nothing fetched says fetch", c.report_plan(30 * 86400, "u", None) == "fetch")
check("report_plan: 30 d with the archive fetched is merged", c.report_plan(30 * 86400, "u", []) == "merged")
check("report_events: 24 h and 7 d read the live events only", c.report_events(_lv, _ar, 7 * 86400) == _lv and c.report_events(_lv, _ar, 86400) == _lv)
check("report_events: 30 d reads live plus archive", len(c.report_events(_lv, _ar, 30 * 86400)) == 4)
check("report_events: 30 d without the archive reads live", c.report_events(_lv, None, 30 * 86400) == _lv)
check("archive url: unset is None, set is kept, a bad one is an error",
      c.resolve_archive_url(None, {}) is None and c.resolve_archive_url("http://x/archive.json", {}) == "http://x/archive.json"
      and c.resolve_archive_url(None, {"PO_DASHBOARD_ARCHIVE_URL": "http://y/a"}) == "http://y/a"
      and c.resolve_archive_url("http://z/a", {"PO_DASHBOARD_ARCHIVE_URL": "http://y/a"}) == "http://z/a")
try:
    c.resolve_archive_url("nope", {})
    check("archive url: a bad one is an error", False)
except c.DashboardError:
    check("archive url: a bad one is an error", True)
import dashboard_reports as rep77
_n = c.parse_time("2026-10-31T12:00:00Z")
_g = lambda evs: rep77.reports(evs, 30 * 86400, _n)["charts"][0]["data"]
_stamp = lambda t, i: {"time": t, "kind": "stamp", "item": i, "project": "p", "result": "pass", "agent": "ada", "legs": [], "detail": ""}
_L = [_stamp("2026-10-30T10:00:00Z", "1")]
_A = [_stamp("2026-10-15T10:00:00Z", "2"), _stamp("2026-10-05T10:00:00Z", "3")]
check("reports 30 d: the aggregation reads live plus archive; live alone leaves the older runs out",
      len(c.in_range(c.report_events(_L, _A, 30 * 86400), 30 * 86400, _n)) == 3 and len(c.in_range(c.report_events(_L, None, 30 * 86400), 30 * 86400, _n)) == 1
      and _g(c.report_events(_L, _A, 30 * 86400))["total"] == 3 and _g(_L)["total"] == 1)
check("reports 7 d: the archive never changes the 7 d aggregation", rep77.reports(c.report_events(_L, _A, 7 * 86400), 7 * 86400, _n)["charts"][0]["data"] == rep77.reports(_L, 7 * 86400, _n)["charts"][0]["data"])


# ---- v0.173: the agent switch in the Team view ----
_off = {"agent": "bo", "state": "idle 3h", "now": None, "owns": [], "free": False, "inactive": True}
_offr = c.team_row(_off)
check("v0.173 dashboard team: an inactive entry is kind off with status OFF", _offr["kind"] == "off" and _offr["status"] == "OFF", repr(_offr))
_offw = c.team_row(dict(_off, state="WORKING", now="1.4", owns=["1.4"]))
_offf = c.team_row(dict(_off, free=True))
check("v0.173 dashboard team: OFF wins over working and free", _offw["kind"] == "off" and _offw["status"] == "OFF" and _offf["kind"] == "off" and _offf["status"] == "OFF",
      repr((_offw, _offf)))
_NOW173 = datetime.datetime(2030, 5, 1, 14, 0, tzinfo=datetime.timezone.utc)
_offl = c.team_row(dict(_off, limit_until="2030-05-01T18:30:00Z"), _NOW173, datetime.timezone.utc)
check("v0.173 dashboard team: an inactive agent at its limit is OFF and still shows the LIMIT time",
      _offl["kind"] == "off" and _offl["status"].startswith("OFF") and "LIMIT until 6:30 PM UTC" in _offl["status"], repr(_offl))
check("v0.173 dashboard team: inactive false or absent changes nothing",
      c.team_row(dict(_off, inactive=False, free=True))["kind"] == "free" and c.team_row({"agent": "x", "state": "idle 22m"})["kind"] == "idle"
      and c.team_row(dict(_off, inactive="yes", free=True))["kind"] == "free")
check("v0.173 dashboard team: a check line says OFF", c.team_check_lines([_off]) == ["bo | OFF | now: - | owns: -"], repr(c.team_check_lines([_off])))
_ab = c.agent_active_body("bo", False, "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41")
check("v0.173 dashboard switch: the agent body is {answer_id, kind agent-active, agent, active, answered_at, client}",
      set(_ab) == {"answer_id", "kind", "agent", "active", "answered_at", "client"} and _ab["kind"] == "agent-active" == c.AGENT_ACTIVE
      and _ab["agent"] == "bo" and _ab["active"] is False and _ab["client"] == c.CLIENT and _ab["answer_id"] == "0b7e3c1a-5d2f-4a8e-9c61-3f0d2b8a7e41"
      and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", _ab["answered_at"]) is not None, repr(_ab))
check("v0.173 dashboard switch: active True is sent as true", c.agent_active_body("bo", 1, "x")["active"] is True)
for _v in sorted(c.PALETTES):
    _p = c.css_properties(c.css(_v))
    check("v0.173 dashboard css %s: the OFF badge and the muted OFF row have rules" % _v,
          ".po-off-badge" in _p and ".po-off .po-text" in _p and _p[".po-off .po-text"]["color"] == _p[".po-muted"]["color"])
check("v0.173 dashboard css: the OFF badge and the muted row are in the contrast table",
      {(".po-off-badge", ".po-card"), (".po-off .po-text", ".po-card")} <= {(f, b) for f, b, _r in c.CONTRAST_PAIRS})
check("v0.173 dashboard switch: an agent switch target is at least 24 px", c.AGENT_SWITCH_TARGET_PX >= 24)
# v0.178: the Reports view redraws only when its events changed, on the minute tick, or when it comes on
# screen after a change; never on a 304 or an unchanged fetch, never hidden. A stub app counts the redraws.
class _App178:
    def __init__(self, view="events", reports_on=True):
        self.view, self.reports_on, self.n = view, reports_on, 0
        self.events, self.last_text = [], None
        self.gate = c.ReportsRedraw(self.redraw_reports, lambda: self.view == "events" and self.reports_on)
    def redraw_reports(self):  # as bin/po-dashboard: every redraw clears the dirty mark
        self.gate.dirty = False
        self.n += 1
    def fetch(self, text, events, partial=False):  # as on_data
        changed, self.events, self.last_text = c.fetch_change(self.events, self.last_text, text, events, partial)
        self.gate.fetched(changed)
    def switch(self, view=None, reports_on=None):  # as on_view / on_reports
        self.view = self.view if view is None else view
        self.reports_on = self.reports_on if reports_on is None else reports_on
        self.gate.shown()
_E178 = [{"time": "2026-11-11T2%d:00:00Z" % i, "kind": "stamp", "item": "x%d" % i} for i in range(3)]
_T178 = json.dumps(_E178)
_a = _App178(); _a.fetch(_T178, _E178); _a.n = 0
_a.fetch(None, None)
check("v0.178 reports: a 304 fetch redraws Reports 0 times", _a.n == 0, repr(_a.n))
_a.fetch(_T178, json.loads(_T178))
check("v0.178 reports: an unchanged whole fetch redraws Reports 0 times", _a.n == 0, repr(_a.n))
_a.fetch(None, [_E178[0]], partial=True)
check("v0.178 reports: a ?since= answer with nothing new redraws Reports 0 times", _a.n == 0, repr(_a.n))
_a.fetch(_T178 + " ", _E178 + [{"time": "2026-11-11T23:30:00Z", "kind": "close", "item": "x9"}])
check("v0.178 reports: a changed fetch with Reports visible redraws once", _a.n == 1, repr(_a.n))
_b = _App178(reports_on=False); _b.fetch(_T178, _E178)
check("v0.178 reports: a changed fetch with Events visible redraws 0 times and marks Reports dirty", _b.n == 0 and _b.gate.dirty, repr((_b.n, _b.gate.dirty)))
_b.switch(reports_on=True)
check("v0.178 reports: switching to Reports after a hidden change redraws once", _b.n == 1 and not _b.gate.dirty, repr(_b.n))
_b.switch(reports_on=False); _b.switch(reports_on=True)
check("v0.178 reports: switching to Reports with nothing changed redraws 0 times", _b.n == 1, repr(_b.n))
_t = _App178(view="team"); _t.fetch(_T178, _E178); _t.switch(view="events")
check("v0.178 reports: a change seen from another view redraws once on the switch back to Events with Reports on", _t.n == 1, repr(_t.n))
_a.n = 0
for _i in range(12):  # 60 s of 5 s fetches, half 304, half the same whole feed
    _a.fetch(None, None) if _i % 2 else _a.fetch(_a.last_text, list(_a.events))
check("v0.178 reports: 12 five-second no-change fetches redraw Reports 0 times", _a.n == 0, repr(_a.n))
_a.n = 0
check("v0.178 reports: the 60 s tick with Reports visible redraws once and keeps ticking", _a.gate.tick() is True and _a.n == 1, repr(_a.n))
_h = _App178(view="events", reports_on=False)
check("v0.178 reports: the 60 s tick with Reports hidden redraws 0 times", _h.gate.tick() is True and _h.n == 0, repr(_h.n))
_h.switch(reports_on=True)
check("v0.178 reports: Reports shown after a hidden tick redraws once (its window moved)", _h.n == 1, repr(_h.n))
check("v0.178 reports: the tick is one minute", c.REPORTS_TICK_SECONDS == 60)
_r = _App178(); _r.redraw_reports()  # a range or variant change calls redraw_reports directly, as before
check("v0.178 reports: a range or variant change redraws once", _r.n == 1, repr(_r.n))
_r2 = _App178(reports_on=False); _r2.fetch(_T178, _E178); _r2.redraw_reports(); _r2.switch(reports_on=True)
check("v0.178 reports: a direct redraw clears the dirty mark, so the switch does not redraw again", _r2.n == 1, repr(_r2.n))
_ch, _ev, _tx = c.fetch_change([{"time": "t1", "item": "a"}], "old", None, [{"time": "t2", "item": "b"}], True)
check("v0.178 reports: fetch_change keeps the merge rule (a partial with news drops the text)", _ch and len(_ev) == 2 and _tx is None, repr((_ch, _ev, _tx)))
print("BLOCK-END dashboard-core")

PY
# v0.178: the window wires the counted gate above: on_data hands it `changed` and never redraws Reports itself,
# one 60 s tick, and both ways onto Reports (the view buttons and the Reports toggle) call shown().
_od=$(awk '/def on_data\(/,/def on_key\(/' "$DB")
[[ $_od == *'self.reports_redraw.fetched(changed)'* && $_od != *'self.redraw_reports()'* ]] &&
	ok "v0.178 po-dashboard: on_data hands the change to the Reports gate and never redraws Reports itself" || bad "v0.178 on_data" "$_od"
grep -q 'GLib.timeout_add_seconds(core.REPORTS_TICK_SECONDS, self.reports_redraw.tick)' "$DB" &&
	[[ $(awk '/def on_view\(/,/def fetch_worker\(/' "$DB") == *'self.reports_redraw.shown()'* && $(awk '/def on_reports\(/,/def on_toggle\(/' "$DB") == *'self.reports_redraw.shown()'* ]] &&
	grep -q 'return self.view == "events" and self.reports_on' "$DB" &&
	ok "v0.178 po-dashboard: the minute tick is armed and the view switch and Reports toggle redraw a dirty Reports" || bad "v0.178 tick/shown"
[[ $(awk '/def on_range\(/,/def on_report_archive\(/' "$DB") == *'self.redraw_reports()'* && $(awk '/def apply_css\(/,/def step_of\(/' "$DB") == *'self.redraw_reports()'* ]] &&
	ok "v0.178 po-dashboard: a range or variant change still redraws Reports directly" || bad "v0.178 range/variant"

# v0.159: the card rules (card_rule_problems), one case per rule, and the reference card passes unchanged
block card-rules python3 -B -I - "$DBLIB" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
import dashboard_core as c

def check(name, cond, detail=""):
    print("%s\t%s\t%s" % ("ok" if cond else "FAIL", name, detail.replace("\n", " | ")))

REF = json.load(open(sys.argv[1] + "/../../tests/fixtures/card-v1.9.64.1.json"))
DW = 'Answer "pass", or the name of the site that failed.'
CH = "step 1 chains commands: one command per step"
SU = "step 1: sudo must be a step of its own, first word"
DWP = 'done_when must be one line asking for "pass" or the name of what failed'

def card(steps, done_when=DW, machine="the laptop"):
    return {"kind": "action", "id": "c1", "machine": machine, "steps": steps, "done_when": done_when}

def st(text="t", command=None, expect="x"):
    s = {"text": text}
    if command is not None:
        s["command"] = command
    if expect is not None:
        s["expect"] = expect
    return s

check("v0.159 card rules: the reference card (v1.9.64.1 shape) has no problem", c.card_rule_problems(REF) == [], str(c.card_rule_problems(REF)))
check("v0.159 card rules: the reference card is an Action", c.decision_shape(dict(REF, id="ref-1")) == "action")
CASES = [
    ("R1 && in a command", card([st(command="a && b")]), [CH]),
    ("R1 ; in a text", card([st(text="do a; then b")]), [CH]),
    ("R1 ; inside single quotes is not a chain", card([st(command="echo 'a ; b'")]), []),
    ("R1 ; inside double quotes is not a chain", card([st(command='echo "a ; b"')]), []),
    ("R1 ; inside backticks is not a chain", card([st(command="echo `a ; b`")]), []),
    ("R1 newline in a command", card([st(command="a\nb")]), [CH]),
    ("R1 one pipe is not a chain", card([st(command="x | y")]), []),
    ("R1 || is a chain", card([st(command="a || b")]), [CH]),
    ("R2 sudo after a pipe", card([st(command="echo hi | sudo tee f")]), [SU]),
    ("R1 and R2 sudo a && b", card([st(command="sudo a && b")]), [CH, SU]),
    ("R2 sudo pacman -U f alone passes", card([st(command="sudo pacman -U f")]), []),
    ("R3 a step without expect", card([st(expect=None)]), ["step 1 has no expect"]),
    ("R3 a blank expect", card([st(expect="  ")]), ["step 1 has no expect"]),
    ("R4 a placeholder", card([st(command="pacman -U <package>")]), ["step 1 holds a placeholder <package>"]),
    ("R5 done_when on two lines", card([st()], "pass\nor name it"), [DWP]),
    ("R5 done_when of 121 characters", card([st()], "pass" + "x" * 117), [DWP]),
    ("R5 done_when of 120 characters passes", card([st()], "pass" + "x" * 116), []),
    ("R5 done_when without pass", card([st()], "the page shows the new tag"), [DWP]),
    ("R5 done_when with PASS in capitals", card([st()], "Answer PASS"), []),
    ("R6 an empty machine", card([st()], machine=""), ["machine must name one machine"]),
    ("R6 a machine on two lines", card([st()], machine="a\nb"), ["machine must name one machine"]),
    ("a choice card has no problem", {"kind": "choice", "question": "q", "options": [{"label": "a"}, {"label": "b"}]}, []),
]
for name, cd, want in CASES:
    got = c.card_rule_problems(cd)
    check("v0.159 card rules: " + name, got == want, "%s != %s" % (got, want))
for name, cd, want in CASES:
    if want and cd["kind"] == "action":
        check("v0.159 card rules: unformatted on the dashboard: " + name, c.decision_shape(cd) == "unformatted")
print("BLOCK-END card-rules")
PY

# v0.87: the feeds are fetched conditionally (ETag, 304, ?since=) and never twice at once.
block dashboard-feeds python3 -B -I - "$DBLIB" "$DB" "$(dirname "$PO")/../README.md" <<'PY'
import hashlib, http.server, json, os, subprocess, sys, tempfile, threading, time
sys.path.insert(0, sys.argv[1])
import dashboard_core as c

def check(name, cond, detail=""):
    print("%s\t%s\t%s" % ("ok" if cond else "FAIL", name, str(detail).replace("\n", " | ")))

class Srv(http.server.ThreadingHTTPServer):
    daemon_threads = True

def serve(handler):
    srv = Srv(("127.0.0.1", 0), handler)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, "http://127.0.0.1:%d/events.json" % srv.server_address[1]

# A slow feed: each answer takes 0.4 s; the server counts the requests running at once.
state = {"now": 0, "max": 0, "hits": 0}
lock = threading.Lock()
class Slow(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            state["now"] += 1; state["hits"] += 1; state["max"] = max(state["max"], state["now"])
        time.sleep(0.4)
        body = b"[]"
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(body)
        with lock:
            state["now"] -= 1
    def log_message(self, *a): pass
srv, url = serve(Slow)
feed = c.Feed(url)
started = skipped = 0
for _ in range(30):  # a tick every 0.05 s for 1.5 s, much faster than the feed answers
    if feed.start(feed.load, c.parse_events):
        started += 1
    else:
        skipped += 1
    time.sleep(0.05)
deadline = time.time() + 3
while feed.busy and time.time() < deadline:
    time.sleep(0.05)
check("feeds: a slow feed never has two fetches in flight", state["max"] == 1 and state["hits"] == started, state)
check("feeds: a tick while the feed's fetch is in flight is skipped, and the feed is free again after", skipped > 20 and 2 <= started <= 6 and not feed.busy, (started, skipped))
srv.shutdown()
def quiet_load(f):
    try:
        f.load(c.parse_events, timeout=1)
    except c.DashboardError:
        pass
gone = c.Feed("http://127.0.0.1:9/x.json")
gone_started = gone.start(quiet_load, gone)
deadline = time.time() + 3
while gone.busy and time.time() < deadline:
    time.sleep(0.05)
check("feeds: a fetch that fails still frees the feed", gone_started and not gone.busy)

# An ETag feed: 304 when If-None-Match matches.
seen = []
body = {"v": json.dumps([{"time": "2026-11-01T01:00:00Z", "item": "1"}])}
class Tagged(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = body["v"].encode()
        tag = '"%s"' % hashlib.sha256(b).hexdigest()[:12]
        seen.append(self.headers.get("If-None-Match"))
        if self.headers.get("If-None-Match") == tag:
            self.send_response(304); self.send_header("ETag", tag); self.end_headers(); return
        self.send_response(200); self.send_header("ETag", tag); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
srv, url = serve(Tagged)
parsed = []
def parse(t):
    parsed.append(t)
    return c.parse_events(t)
feed = c.Feed(url)
first = feed.load(parse)
second = feed.load(parse)
check("feeds: the first fetch sends no If-None-Match and is the whole feed", seen[0] is None and first[0] is True and first[1][0]["item"] == "1" and first[2] is False, (seen, first))
check("feeds: a fetch sends If-None-Match with the ETag last accepted", seen[1] is not None and seen[1] == feed.etag, seen)
check("feeds: 304 leaves the data untouched (no data back, the body not parsed again)", second == (False, None, False) and len(parsed) == 1, (second, len(parsed)))
body["v"] = json.dumps([{"time": "2026-11-01T02:00:00Z", "item": "2"}])
third = feed.load(parse)
check("feeds: a changed feed answers 200 with the new data and a new ETag", third[0] is True and third[1][0]["item"] == "2" and len(parsed) == 2, third)
fp = c.Feed(url)
def bad(t):
    raise c.DashboardError("not JSON")
try:
    fp.load(bad)
except c.DashboardError:
    pass
check("feeds: an ETag is kept only once the body parsed, so a bad body is fetched whole again", fp.etag is None)
last = [{"project": "kept"}]
pfeed = c.Feed(url)
pfeed.load(lambda t: t)
got, note = c.load_projects(url, last, pfeed)
check("feeds: load_projects with a Feed keeps the last projects on 304", got is last and note == "", (got, note))
srv.shutdown()
with tempfile.TemporaryDirectory() as td:
    with open(os.path.join(td, "events.json"), "w") as fh:
        fh.write("[]")
    ffile = c.Feed("file://" + os.path.join(td, "events.json"))
    check("feeds: a feed without ETag (a file) is fetched whole each time", ffile.load(c.parse_events)[0] and ffile.load(c.parse_events)[0] and ffile.etag is None and not ffile.since_ok)

# ?since=: only when the server offers it, the newest time held, whole every FULL_EVERY-th fetch.
evs = [{"time": "2026-11-01T01:00:00Z", "item": "a"}, {"time": "2026-11-01T03:00:00Z", "item": "b"}, {"time": "2026-11-01T02:00:00Z", "item": "c"}]
f = c.Feed("http://h/events.json")
check("feeds: no ?since= while the server has not offered it", f.since_for(evs) is None)
f.since_ok, f.fetches = True, 1
check("feeds: ?since= is the newest event time held once offered", f.since_for(evs) == "2026-11-01T03:00:00Z")
check("feeds: no ?since= with nothing held", f.since_for([]) is None)
f.fetches = c.FULL_EVERY
check("feeds: every FULL_EVERY-th fetch is whole", f.since_for(evs) is None and c.FULL_EVERY == 60)
check("feeds: feed_url_since adds since to the query", c.feed_url_since("http://h/e.json", "2026-11-01T03:00:00Z") == "http://h/e.json?since=2026-11-01T03%3A00%3A00Z"
      and c.feed_url_since("http://h/e.json?x=1", "t") == "http://h/e.json?x=1&since=t")
m = c.merge_since(evs, [evs[1], {"time": "2026-11-01T04:00:00Z", "item": "d"}])
check("feeds: merge_since adds only the events not held", [e["item"] for e in m] == ["a", "b", "c", "d"] and c.merge_since(evs, []) == evs)

# The demo server: ETag, X-Po-Since full and partial, through Feed.
proc = subprocess.Popen([sys.executable, "-I", sys.argv[1] + "/../../examples/events-demo-server.py", "--port", "0", "--every", "999"], stdout=subprocess.PIPE, text=True)
try:
    port = int(proc.stdout.readline().split("127.0.0.1:")[1].split("/")[0])
    df = c.Feed("http://127.0.0.1:%d/events.json" % port)
    whole = df.load(c.parse_events)
    check("feeds: the demo server's events carry an ETag and X-Po-Since: full", whole[0] and whole[2] is False and df.etag and df.since_ok, df.etag)
    check("feeds: the demo server's second whole fetch does not send If-None-Match and returns 200",
          df.load(c.parse_events) == (True, whole[1], False))
    # ?since= with no cached ETag returns the events since, marked partial.
    df2 = c.Feed("http://127.0.0.1:%d/events.json" % port)
    newest = whole[1][-1]["time"]
    part = df2.load(c.parse_events, newest)
    check("feeds: the demo server answers ?since= with the events since, marked partial", part[0] and part[2] is True and 0 < len(part[1]) < len(whole[1]) and all(e["time"] >= newest for e in part[1]), len(part[1]))
    # FULL_EVERY-th fetch: no If-None-Match, 200 whole body.
    seen_fe = []
    body_fe = {"v": json.dumps([{"time": "2026-11-01T01:00:00Z", "item": "1"}])}
    class SinceFeed(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            b = body_fe["v"].encode()
            tag = '"whole"'
            seen_fe.append(self.headers.get("If-None-Match"))
            if self.headers.get("If-None-Match") == tag:
                self.send_response(304); self.send_header("ETag", tag); self.end_headers(); return
            self.send_response(200); self.send_header("ETag", tag); self.send_header("X-Po-Since", "full"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        def log_message(self, *a): pass
    srv_fe = Srv(("127.0.0.1", 0), SinceFeed)
    threading.Thread(target=srv_fe.serve_forever, daemon=True).start()
    try:
        fe = c.Feed("http://127.0.0.1:%d/events.json" % srv_fe.server_address[1])
        fe.load(c.parse_events)
        whole_fe = fe.load(c.parse_events)
        check("feeds: the whole fetch sends no If-None-Match and returns the full body", whole_fe[0] and whole_fe[2] is False and seen_fe[-1] is None and len(whole_fe[1]) == 1)
        # A server that never offers ?since= (no X-Po-Since) still gets If-None-Match and 304.
        seen_no = []
        class NoSince(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                b = body_fe["v"].encode()
                tag = '"whole"'
                seen_no.append(self.headers.get("If-None-Match"))
                if self.headers.get("If-None-Match") == tag:
                    self.send_response(304); self.send_header("ETag", tag); self.end_headers(); return
                self.send_response(200); self.send_header("ETag", tag); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
            def log_message(self, *a): pass
        srv_ns = Srv(("127.0.0.1", 0), NoSince)
        threading.Thread(target=srv_ns.serve_forever, daemon=True).start()
        try:
            ns = c.Feed("http://127.0.0.1:%d/events.json" % srv_ns.server_address[1])
            ns.load(c.parse_events)
            seen_no.clear()
            ns304 = ns.load(c.parse_events)
            check("feeds: a server that never offers ?since= still gets If-None-Match and 304", ns304 == (False, None, False) and seen_no[-1] == '"whole"')
        finally:
            srv_ns.shutdown()
    finally:
        srv_fe.shutdown()
    # A stub server that writes less than Content-Length makes Feed.load raise DashboardError.
    class ShortBody(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200); self.send_header("Content-Length", "99"); self.end_headers(); self.wfile.write(b"short")
        def log_message(self, *a): pass
    srv_sb = Srv(("127.0.0.1", 0), ShortBody)
    threading.Thread(target=srv_sb.serve_forever, daemon=True).start()
    try:
        sb = c.Feed("http://127.0.0.1:%d/events.json" % srv_sb.server_address[1])
        try:
            sb.load(c.parse_events)
            check("feeds: a short body is a DashboardError", False)
        except c.DashboardError as e:
            check("feeds: a short body is a DashboardError", "cannot reach" in str(e))
    finally:
        srv_sb.shutdown()
finally:
    proc.kill()
    proc.wait()

db = open(sys.argv[2]).read()
check("po-dashboard starts each feed's fetch through Feed.start (no bare fetch thread per tick)",
      "threading.Thread(target=self.fetch_worker" not in db and 'feeds["events"].start(self.fetch_worker' in db
      and 'feeds["team"].start(self.team_worker)' in db and 'feeds["decisions"].start(self.decisions_worker)' in db and 'feeds["projects"].start(self.projects_worker)' in db)
readme = open(sys.argv[3]).read()
check("README documents the in-flight skip, If-None-Match/304 and ?since=",
      "still in flight skips that tick" in readme and "If-None-Match" in readme and "304 Not Modified" in readme and "?since=<time>" in readme and "X-Po-Since" in readme)
print("BLOCK-END dashboard-feeds")
PY

grep -q 'sort by %s' "$DB" && grep -q 'Gtk.Button' "$DB" && ok "po-dashboard headers are buttons labelled sort by <column>" || bad "dashboard header buttons"
# bin/po-dashboard: argument handling needs no display.
out=$(env -u PO_DASHBOARD_URL python3 -B "$DB" 2>&1)
[[ $? == 1 && $out == *'no URL'* && $out == *PO_DASHBOARD_URL* ]] &&
	ok "po-dashboard without a URL is a usage error naming --url and PO_DASHBOARD_URL" || bad "dashboard no url" "$out"
# one loop: each feed option, and the answer variable, refuses a non-http URL at the CLI with exit 1 (the core resolvers carry the cases)
for _flag in --url --team-url --decisions-url --answer-url; do
	if [[ $_flag == --url ]]; then out=$(timeout 10 python3 -B "$DB" --url ftp://h/x --check 2>&1); else out=$(timeout 10 python3 -B "$DB" --url http://h/x "$_flag" ftp://h/x --check 2>&1); fi
	[[ $? == 1 && $out == *'not an http'* ]] && ok "po-dashboard refuses a non-http $_flag" || bad "dashboard non-http $_flag" "$out"
done
out=$(PO_DASHBOARD_ANSWER_URL=ftp://h/x timeout 10 python3 -B "$DB" --url http://h/x --check 2>&1)
[[ $? == 1 && $out == *'not an http'* ]] && ok "po-dashboard refuses a non-http PO_DASHBOARD_ANSWER_URL" || bad "dashboard answer url env" "$out"
out=$(python3 -B "$DB" --theme neon --url http://h/x 2>&1)
[[ $? == 2 && $out == *'--theme'* ]] && ok "po-dashboard rejects an unknown theme" || bad "dashboard theme" "$out"
out=$(python3 -B "$DB" --size 10x10 --url http://h/x 2>&1)
[[ $? == 2 && $out == *'--size'* ]] && ok "po-dashboard rejects a window size below 200" || bad "dashboard size" "$out"
# --team-url: a bad value is a usage error; --check prints the team lines after the events.
printf '[{"agent":"ada","state":"WORKING","now":"1.4","owns":["1.4"],"free":false},{"agent":"cy","state":"idle 3h","now":null,"owns":[],"free":true}]\n' >"$TMP/team.json"
# --check prints the rows without a display (and needs no GTK).
# helper
python3 -I - "$SV/events.json" "$TMP/chk.port" <<'PY' &
import http.server, sys, threading, time
body = open(sys.argv[1], "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[2], "w").write(str(srv.server_address[1]))
srv.serve_forever()
PY
CHK_PID=$!
for _ in $(seq 1 50); do [[ -s $TMP/chk.port ]] && break; sleep 0.1; done
CHK_URL="http://127.0.0.1:$(cat "$TMP/chk.port")/"
out=$(env -u PO_DASHBOARD_TEAM_URL python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(wc -l <<<"$out") == 10 ]] &&
	[[ $(head -1 <<<"$out") == "1.11 | demo | stamp | "* ]] && ok "po-dashboard --check prints the last 10 rows, newest first" || bad "dashboard check" "$out"
out=$(python3 -B "$DB" --url "$CHK_URL" --check --all 2>&1)
[[ $(wc -l <<<"$out") == 12 ]] && ok "po-dashboard --check --all prints every event" || bad "dashboard check all" "$out"
# --check exits before the window exists, so the 60 s timer never runs and no run writes the log here:
# the flag is proved by the empty state dir plus the one place that arms the timer being guarded by it.
mkdir -p "$TMP/xdg-state"
out=$(XDG_STATE_HOME="$TMP/xdg-state" python3 -B "$DB" --url "$CHK_URL" --check --no-memory-log 2>&1)
[[ $(wc -l <<<"$out") == 10 && -z $(find "$TMP/xdg-state" -type f) ]] &&
	grep -q 'if not getattr(a, "no_memory_log", False):' "$DB" && grep -A1 'if not getattr(a, "no_memory_log", False):' "$DB" | grep -q 'timeout_add_seconds(60, self.log_memory)' &&
	ok "po-dashboard --check --no-memory-log is accepted, writes no memory log, and guards the 60 s timer" || bad "dashboard no-memory-log" "$out"
[[ $(python3 -B "$DB" --help 2>&1) == *--no-memory-log* ]] && ok "po-dashboard --help lists --no-memory-log" || bad "dashboard help no-memory-log"
out=$(PO_DASHBOARD_TEAM_URL="$TMP/team.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -2 <<<"$out" | head -1) == "ada | WORKING | now: 1.4 | owns: 1.4" && $(tail -1 <<<"$out") == "cy | FREE | now: - | owns: -" ]] &&
	ok "po-dashboard --check lists the team after the events when a team feed is set" || bad "dashboard check team" "$out"
printf '[{"agent":"ada","state":"WORKING","owns":[],"usage":{"five_hour":0.5}},{"agent":"cy","state":"idle 3h","free":true,"limit_until":"2099-01-01T12:00:00Z","usage":{"seven_day":0.25}}]\n' >"$TMP/team-limit.json"
out=$(TZ=UTC PO_DASHBOARD_TEAM_ORDER="$TMP/none-order.json" PO_DASHBOARD_TEAM_URL="$TMP/team-limit.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -2 <<<"$out" | head -1) == "ada | WORKING (5h 50%) | now: - | owns: -" && $(tail -1 <<<"$out") == "cy | LIMIT until 12:00 PM UTC Jan 1 2099 (7d 25%) | now: - | owns: -" ]] &&
	ok "po-dashboard --check shows LIMIT in local time and usage when present" || bad "dashboard check limit" "$out"
printf '{"order": ["cy"]}\n' >"$TMP/team-order.json"
out=$(PO_DASHBOARD_TEAM_ORDER="$TMP/team-order.json" PO_DASHBOARD_TEAM_URL="$TMP/team.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -2 <<<"$out" | head -1) == "cy | FREE | now: - | owns: -" && $(tail -1 <<<"$out") == "ada | WORKING | now: 1.4 | owns: 1.4" ]] &&
	ok "po-dashboard --check applies the saved team order" || bad "dashboard check team order" "$out"
out=$(env -u PO_DASHBOARD_TEAM_URL python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $out != *'team:'* ]] && ok "po-dashboard --check without a team feed prints no team section" || bad "dashboard no team" "$out"
# --decisions-url: no default; --check prints the decisions, oldest asked first, after the events (and team).
printf '[{"project":"harbor","item":"0.7","title":"Accept","waiting_for":"an acceptance","asked_at":"2026-10-24T11:30:00Z"},{"project":"orchard","item":"2.3","title":"Pick","waiting_for":"a ruling","asked_at":"2026-10-24T09:00:00Z","thread_url":"https://chat.example.org/t/1"}]\n' >"$TMP/decisions.json"
out=$(python3 -B "$DB" --url http://h/x --view bogus 2>&1)
[[ $? -ne 0 && $out == *"invalid choice"* ]] && ok "po-dashboard --view accepts reports and rejects an unknown view" || bad "dashboard view bogus" "$out"
out=$(env -u PO_DASHBOARD_DECISIONS_URL python3 -B "$DB" --url http://h/x --view decisions 2>&1)
[[ $? == 1 && $out == *'--decisions-url'* && $out == *PO_DASHBOARD_DECISIONS_URL* ]] &&
	ok "po-dashboard --view decisions without a decisions feed is a usage error" || bad "dashboard view decisions" "$out"
out=$(env -u PO_DASHBOARD_PROJECTS_URL python3 -B "$DB" --url http://h/x --view projects 2>&1)
[[ $? == 1 && $out == *'--projects-url'* && $out == *PO_DASHBOARD_PROJECTS_URL* ]] &&
	ok "po-dashboard --view projects without a projects feed is a usage error" || bad "dashboard view projects" "$out"
out=$(PO_DASHBOARD_DECISIONS_URL="$TMP/decisions.json" PO_DASHBOARD_TEAM_URL="$TMP/team.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -3 <<<"$out" | head -1) == "decisions:" && $(tail -2 <<<"$out" | head -1) == "legacy | 2.3 | orchard | Pick | waiting for: a ruling | asked "*" | https://chat.example.org/t/1" &&
	$(tail -1 <<<"$out") == "legacy | 0.7 | harbor | Accept | waiting for: an acceptance | asked "* && $out == *'team:'* ]] &&
	ok "po-dashboard --check lists the decisions, oldest asked first, after the events and the team" || bad "dashboard check decisions" "$out"
out=$(XDG_CONFIG_HOME="$TMP/cfg" python3 -B "$DB" --url "$CHK_URL" --decisions-url "$(dirname "$PO")/../examples/decisions-feed.json" --check 2>&1)
[[ $(tail -4 <<<"$out" | head -1) == "choice | 2.6 | orchard |"* && $(tail -3 <<<"$out" | head -1) == "action | 2.5 | orchard |"* &&
	$(tail -2 <<<"$out" | head -1) == "legacy | 2.3 |"* && $(tail -1 <<<"$out") == "unformatted | 0.8 |"* ]] &&
	ok "po-dashboard --check prints the kind first, choices, actions, then legacy and unformatted" || bad "dashboard check kinds" "$out"
mkdir -p "$TMP/cfg/po-dashboard" && echo '{"actions": false}' >"$TMP/cfg/po-dashboard/decisions.json"
out2=$(XDG_CONFIG_HOME="$TMP/cfg" python3 -B "$DB" --url "$CHK_URL" --decisions-url "$(dirname "$PO")/../examples/decisions-feed.json" --check 2>&1)
[[ $out2 == "$out" ]] && ok "po-dashboard --check ignores the Actions filter" || bad "dashboard check filter" "$out2"
# v0.69: --install-dir / PO_DASHBOARD_INSTALL_DIR; --check prints the Install block after the decisions.
sha=$(printf '%064d' 0)
# v0.81: a look card is shown (and so makes the block) only when ready: checked, fixtures stated, build installed.
printf '[{"project":"orchard","item":"1.9.39","title":"Look","waiting_for":"a look","asked_at":"2026-10-29T10:00:00Z","kind":"action","id":"i1","machine":"laptop","steps":[{"text":"open the Bookmarks menu","expect":"three bookmarks"}],"done_when":"pass","requires":{"package":"a-1-1-x86_64.pkg.tar.zst","sha256":"%s"},"fixtures":[],"checked_by":"rev","check_sha256":"%s","ready":{"build":"a 1-1","checked_at":"%s"}}]\n' "$sha" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TMP/install.json"
out=$(env -u PO_DASHBOARD_INSTALL_DIR python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/install.json" --install-dir /x/pkgs --check 2>&1)
[[ $(tail -3 <<<"$out") == "install | orchard | a-1-1-x86_64.pkg.tar.zst
install | orchard | cd /x/pkgs && sha256sum -c <<< '$sha  a-1-1-x86_64.pkg.tar.zst'
install | orchard | sudo pacman -U /x/pkgs/a-1-1-x86_64.pkg.tar.zst" ]] &&
	ok "po-dashboard --check prints the Install block from --install-dir after the decisions" || bad "dashboard check install" "$out"
out=$(PO_DASHBOARD_INSTALL_DIR=/y python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/install.json" --check 2>&1)
[[ $(tail -1 <<<"$out") == "install | orchard | sudo pacman -U /y/a-1-1-x86_64.pkg.tar.zst" ]] && ok "po-dashboard reads PO_DASHBOARD_INSTALL_DIR" || bad "dashboard install env" "$out"
out=$(env -u PO_DASHBOARD_INSTALL_DIR python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/install.json" --check 2>&1)
[[ $(tail -1 <<<"$out") == "install | orchard | set install_dir" ]] && ok "po-dashboard without install_dir shows set install_dir and no command" || bad "dashboard install unset" "$out"
# installed is another build: held
sed -e 's/"item":"1.9.39"/"item":"1.9.40"/' -e 's/"build":"a 1-1"/"build":"a 0-1"/' "$TMP/install.json" >"$TMP/held.json"
out=$(env -u PO_DASHBOARD_INSTALL_DIR python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/held.json" --install-dir /x/pkgs --check 2>&1)
[[ $out == *"decisions:"* && $out != *"1.9.40"* && $out != *"install |"* ]] &&
	ok "po-dashboard --check leaves out a held look card, and its Install block" || bad "dashboard check held" "$out"
out=$(python3 -B "$DB" --url http://h/x --install-dir pkgs --check 2>&1)
[[ $? == 1 && $out == *'install_dir is not an absolute plain path'* ]] && ok "po-dashboard refuses a relative --install-dir" || bad "dashboard install relative" "$out"
out=$(env -u PO_DASHBOARD_DECISIONS_URL python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $out != *'decisions:'* ]] && ok "po-dashboard --check without a decisions feed prints no decisions section" || bad "dashboard no decisions" "$out"
out=$(python3 -B "$DB" --url "$CHK_URL" --decisions-url "http://127.0.0.1:1/" --check 2>&1)
[[ $? == 2 && $out == *'cannot reach'* ]] && ok "po-dashboard --check with an unreachable decisions feed exits 2" || bad "dashboard check decisions unreachable" "$out"
# --answer-url: http(s) only; none is read-only (no error); flag wins over env.
# one loop: the option beats its environment variable at the CLI (the core resolvers carry the rest)
for _p in "--team-url|PO_DASHBOARD_TEAM_URL|$TMP/team.json|team:" "--decisions-url|PO_DASHBOARD_DECISIONS_URL|$TMP/decisions.json|decisions:" "--answer-url|PO_DASHBOARD_ANSWER_URL|http://h/a|"; do
	IFS='|' read -r _flag _var _good _mark <<<"$_p"
	out=$(env "$_var=ftp://h/x" python3 -B "$DB" --url "$CHK_URL" "$_flag" "$_good" --check 2>&1)
	[[ $? == 0 && -n $out && $out == *"$_mark"* ]] && ok "po-dashboard $_flag wins over $_var" || bad "dashboard $_flag precedence" "$out"
done
out=$(python3 -B "$DB" --url "$CHK_URL" --answer-url http://h/a --check 2>&1)
[[ $? == 0 && -n "$out" ]] && ok "po-dashboard --answer-url is accepted, --check runs (read-only)" || bad "dashboard answer check" "$out"
out=$(python3 -B "$DB" --url "$CHK_URL" --answer-url " " --check 2>&1)
[[ $? == 0 && -n "$out" ]] && ok "po-dashboard --answer-url blank is read-only (no error)" || bad "dashboard answer blank" "$out"
kill "$CHK_PID" 2>/dev/null
wait "$CHK_PID" 2>/dev/null
out=$(python3 -B "$DB" --url "http://127.0.0.1:1/" --check 2>&1)
[[ $? == 2 && $out == *'cannot reach'* ]] && ok "po-dashboard --check with an unreachable URL exits 2" || bad "dashboard check unreachable" "$out"
if python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
	if [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
		# UI smoke: the window comes up with data and saves a screenshot.
		# helper
		python3 -I - "$SV/events.json" "$TMP/shot.png" "$DB" "$TMP/decisions.json" "$TMP/shot-decisions.png" "$TMP/team-limit.json" "$TMP/shot-team.png" "$TMP/shot-reports.png" "$(dirname "$PO")/../examples/projects-feed.json" "$TMP/shot-projects.png" <<'PY' &&
import http.server, subprocess, sys, threading
body = open(sys.argv[1], "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
r = subprocess.run([sys.executable, sys.argv[3], "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--screenshot", sys.argv[2]], timeout=60)
if r.returncode == 0 and len(sys.argv) > 4:
    r = subprocess.run([sys.executable, sys.argv[3], "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--decisions-url", sys.argv[4], "--view", "decisions", "--screenshot", sys.argv[5]], timeout=60)
if r.returncode == 0 and len(sys.argv) > 6:
    r = subprocess.run([sys.executable, sys.argv[3], "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--team-url", sys.argv[6], "--view", "team", "--screenshot", sys.argv[7]], timeout=60)
if r.returncode == 0 and len(sys.argv) > 8:
    r = subprocess.run([sys.executable, sys.argv[3], "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--view", "reports", "--screenshot", sys.argv[8]], timeout=60)
if r.returncode == 0 and len(sys.argv) > 10:
    r = subprocess.run([sys.executable, sys.argv[3], "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--projects-url", sys.argv[9], "--view", "projects", "--screenshot", sys.argv[10]], timeout=60)
sys.exit(r.returncode)
PY
			[[ -s $TMP/shot-projects.png ]] && ok "po-dashboard --view projects --screenshot saves the Projects pane" || bad "dashboard projects screenshot"
		# Activating a Projects card (child-activated, as Enter/Space do) opens that project's screen.
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: timeout 60 python3 -I - "$DB" "$SV/events.json" "$(dirname "$PO")/../examples/projects-feed.json" 2>/dev/null <<'PY'
import http.server, importlib.machinery, importlib.util, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed = sys.argv[1:4]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sys.argv = [db, "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--projects-url", feed, "--view", "projects"]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
result = {"n": 0}
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def tick():
    result["n"] += 1
    wins = Gtk.Window.list_toplevels()
    nodes = [n for w in wins for n in walk(w)]
    stacks = [n for n in nodes if isinstance(n, Gtk.Stack) and n.get_child_by_name("screen")]
    cards = [n for n in nodes if isinstance(n, Gtk.FlowBoxChild)]
    if stacks and cards and stacks[0].get_visible_child_name() == "overview":
        cards[0].get_parent().emit("child-activated", cards[0])
        GLib.timeout_add(200, check, stacks[0])
        return False
    if result["n"] > 100:
        print("no project cards"); sys.exit(1)
    return True
def check(stack):
    ok = stack.get_visible_child_name() == "screen"
    print("opened" if ok else "stayed on " + str(stack.get_visible_child_name()))
    sys.stdout.flush()
    import os; os._exit(0 if ok else 1)
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		[[ $out == opened ]] && ok "po-dashboard Projects card activation opens the project screen" || bad "dashboard projects activate" "$out"
		# v0.139/v0.179: the switch is a 44 px touch area, only the switch flips (a click beside it opens the project),
		# and without a sink the reason is said on the card next to the switch, not only in a tooltip.
		python3 -c 'import json, sys; p = json.load(open(sys.argv[1]))
for e, a in zip(p, (True, False, True)): e["active"] = a
json.dump(p, open(sys.argv[2], "w"))' "$(dirname "$PO")/../examples/projects-feed.json" "$TMP/v139-projects.json"
		for _sink in slow ""; do
			# helper
			out=$(DBUS_SESSION_BUS_ADDRESS=disabled: timeout 60 python3 -I - "$DB" "$SV/events.json" "$TMP/v139-projects.json" "$_sink" 2>/dev/null <<'PY'
import http.server, importlib.machinery, importlib.util, os, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed, sink = sys.argv[1:5]
from gi.repository import Graphene
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sys.argv = [db, "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--projects-url", feed, "--view", "projects"]
if sink:  # a sink that holds the POST, so the flipped switch is still shown when it is looked at
    class Slow(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            threading.Event().wait(5)
        def log_message(self, *a): pass
    slow = http.server.HTTPServer(("127.0.0.1", 0), Slow)
    threading.Thread(target=slow.serve_forever, daemon=True).start()
    sys.argv += ["--answer-url", "http://127.0.0.1:%d/answers" % slow.server_address[1]]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
n = {"t": 0}
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def nodes():
    return [x for w in Gtk.Window.list_toplevels() for x in walk(w)]
def line_of(name):
    for child in (x for x in nodes() if isinstance(x, Gtk.FlowBoxChild) and getattr(x, "project_name", None) == name):
        return next((x for x in walk(child) if x.has_css_class("po-switch-line")), None)
def out(*a):
    print(*a); sys.stdout.flush()
def tick():
    n["t"] += 1
    lines = [x for x in nodes() if isinstance(x, Gtk.Box) and x.has_css_class("po-switch-line")]
    if len(lines) < 3 or lines[0].get_height() == 0:
        if n["t"] > 100:
            out("no switch lines"); os._exit(1)
        return True
    sizes = [(x.get_width(), x.get_height()) for x in lines]
    out("sizes", "ok" if all(w >= 44 and h >= 44 for w, h in sizes) else sizes)
    texts = [[y.get_label() for y in walk(x) if isinstance(y, Gtk.Label) and y.get_mapped()] for x in lines]
    out("reason", "inline" if all("read-only: no answer URL" in t for t in texts) else "none" if not any("read-only: no answer URL" in t for t in texts) else texts)
    if not sink:
        os._exit(0)
    harbor = line_of("harbor")
    sw = next(y for y in walk(harbor) if isinstance(y, Gtk.Switch))
    ctrls = [harbor.observe_controllers().get_item(i) for i in range(harbor.observe_controllers().get_n_items())]
    out("line", "noclick" if not any(isinstance(c, Gtk.GestureClick) for c in ctrls) else "click")
    out("swsize", "ok" if sw.get_size_request()[1] >= 44 and sw.get_width() < harbor.get_width() else (sw.get_size_request(), sw.get_width(), harbor.get_width()))
    sw.activate()  # the keyboard path: state-set -> on_switch
    GLib.timeout_add(300, after)
    return False
def after():
    harbor = line_of("harbor")
    sw = next(y for y in walk(harbor) if isinstance(y, Gtk.Switch))
    stack = next(x for x in nodes() if isinstance(x, Gtk.Stack) and x.get_child_by_name("screen"))
    out("flip", "on" if sw.get_active() else "off", stack.get_visible_child_name())
    os._exit(0)
GLib.timeout_add(100, tick)
mod.main()
PY
			)
			if [[ -n $_sink ]]; then
				[[ $out == *"sizes ok"* ]] && ok "v0.139/v0.179 po-dashboard: each GTK switch line is at least 44x44 px" || bad "v0.139 GTK switch target" "$out"
				[[ $out == *"reason none"* && $out == *"flip on overview"* ]] &&
					ok "v0.179 po-dashboard: the switch flips by its own activation (keyboard path); no reason shown with a sink" ||
					bad "v0.179 GTK switch activation flips" "$out"
				[[ $out == *"line noclick"* ]] &&
					ok "v0.179 po-dashboard: the switch line has no click gesture, so a click beside the switch does not flip it (it opens the project)" ||
					bad "v0.179 GTK switch line has no click gesture" "$out"
				! grep -q "on_switch_line" "$DB" &&
					ok "v0.179 po-dashboard: the whole-line handlers on_switch_line and on_switch_line_press are gone" ||
					bad "v0.179 GTK line handlers gone" "$out"
				[[ $out == *"swsize ok"* ]] &&
					ok "v0.179 po-dashboard: the switch itself has a 44 px touch area and is narrower than its line" ||
					bad "v0.179 GTK switch own touch area" "$out"
			else
				[[ $out == *"sizes ok"* && $out == *"reason inline"* ]] &&
					ok "v0.139 po-dashboard: without a sink the GTK card says read-only: no answer URL next to the switch" ||
					bad "v0.139 GTK disabled reason inline" "$out"
			fi
		done
		# v0.140: the GTK Release button: one per card, off with its reason at N = 0, on for an inactive project; its
		# dialog's title carries N and the last release; Release posts one release-request body and the card says sent.
		python3 -c 'import json, sys
json.dump([{"project": "orchard", "release": "release-23", "active": False, "last_event": None, "items": [
    {"item": "v1", "status": "DONE", "released": True}, {"item": "v2", "status": "DONE"}, {"item": "v3", "status": "DONE"}]},
    {"project": "grove", "release": "release-23", "last_event": None, "items": [{"item": "v1", "status": "DONE", "released": True}]}],
    open(sys.argv[1], "w"))' "$TMP/v140-projects.json"
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: timeout 60 python3 -I - "$DB" "$SV/events.json" "$TMP/v140-projects.json" 2>/dev/null <<'PY'
import http.server, importlib.machinery, importlib.util, json, os, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed = sys.argv[1:4]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
seen = []
class Sink(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        seen.append(json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0)))))
        self.send_response(201); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
sink = http.server.HTTPServer(("127.0.0.1", 0), Sink)
threading.Thread(target=sink.serve_forever, daemon=True).start()
sys.argv = [db, "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--projects-url", feed, "--view", "projects",
            "--answer-url", "http://127.0.0.1:%d/answers" % sink.server_address[1]]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
n = {"t": 0}
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def nodes():
    return [x for w in Gtk.Window.list_toplevels() for x in walk(w)]
def card(name):
    return next((x for x in nodes() if isinstance(x, Gtk.FlowBoxChild) and getattr(x, "project_name", None) == name), None)
def button(w, label):
    return next((y for y in walk(w) if isinstance(y, Gtk.Button) and y.get_label() == label and y.get_mapped()), None)
def labels(w):
    return [y.get_label() for y in walk(w) if isinstance(y, Gtk.Label) and y.get_mapped()]
def out(*a):
    print(*a); sys.stdout.flush()
def tick():
    n["t"] += 1
    o, g = card("orchard"), card("grove")
    if o is None or g is None or button(o, "Release") is None or button(o, "Release").get_height() == 0:
        if n["t"] > 100:
            out("no release buttons"); os._exit(1)
        return True
    ob, gb = button(o, "Release"), button(g, "Release")
    tall = ob.compute_bounds(ob.get_parent())[1].get_height()  # the allocation, padding and border included
    out("buttons", "ok" if ob.get_sensitive() and not gb.get_sensitive() and tall >= 44 else (ob.get_sensitive(), gb.get_sensitive(), tall))
    out("reason", "inline" if "nothing to release: no DONE item since release-23" in labels(g) else labels(g))
    ob.emit("clicked")
    GLib.timeout_add(300, dialog)
    return False
def dialog():
    dlg = next((w for w in Gtk.Window.list_toplevels() if w.get_title() == "Release orchard"), None)
    if dlg is None:
        out("no dialog"); os._exit(1)
    out("title", "ok" if "Release orchard: 2 DONE items since release-23" in labels(dlg) else labels(dlg))
    view = next(y for y in walk(dlg) if isinstance(y, Gtk.TextView))
    view.get_buffer().set_text("line one\nline two")
    button(dlg, "Release").emit("clicked")
    GLib.timeout_add(1500, after)
    return False
def after():
    stack = next(x for x in nodes() if isinstance(x, Gtk.Stack) and x.get_child_by_name("screen"))
    gone = not any(w.get_title() == "Release orchard" and w.get_visible() for w in Gtk.Window.list_toplevels())
    b = seen[0] if len(seen) == 1 else {}
    out("post", "ok" if b.get("kind") == "release-request" and b.get("project") == "orchard" and b.get("note") == "line one\nline two" else seen)
    out("after", "ok" if gone and "release asked · sent" in labels(card("orchard")) and stack.get_visible_child_name() == "overview"
        else (gone, labels(card("orchard")), stack.get_visible_child_name()))
    os._exit(0)
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		[[ $out == *"buttons ok"* && $out == *"reason inline"* ]] &&
			ok "v0.140 po-dashboard: each GTK card has a 44 px Release button, on for an inactive project with DONE items, off at N = 0 saying why" ||
			bad "v0.140 GTK release button" "$out"
		[[ $out == *"title ok"* ]] && ok "v0.140 po-dashboard: the GTK Release dialog's title carries N and the last release" || bad "v0.140 GTK release dialog title" "$out"
		[[ $out == *"post ok"* && $out == *"after ok"* ]] &&
			ok "v0.140 po-dashboard: the GTK dialog's Release posts one release-request with the note, closes, and the card says release asked" ||
			bad "v0.140 GTK release post" "$out"
		# v0.109: the errored project's card is greyed (po-errored) and says `feed error`; the others do not (the example feed's Projects screenshot above shows it).
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: timeout 60 python3 -I - "$DB" "$SV/events.json" "$(dirname "$PO")/../examples/projects-feed.json" 2>/dev/null <<'PY'
import http.server, importlib.machinery, importlib.util, os, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed = sys.argv[1:4]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sys.argv = [db, "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--projects-url", feed, "--view", "projects"]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
n = {"n": 0}
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def labels(card):
    return [x.get_text() for x in walk(card) if isinstance(x, Gtk.Label)]
def tick():
    n["n"] += 1
    nodes = [x for w in Gtk.Window.list_toplevels() for x in walk(w)]
    cards = [x for x in nodes if isinstance(x, Gtk.FlowBoxChild)]
    if len(cards) == 3:
        res = []
        for ch in cards:
            card = ch.get_child()
            res.append((card.has_css_class("po-errored"), "feed error" in labels(card), "feed error" in (ch.get_tooltip_text() or "")))
        print("errored-only" if res == [(False, False, False), (False, False, False), (True, True, True)] else "wrong %r" % res)
        sys.stdout.flush()
        os._exit(0)
    if n["n"] > 100:
        print("no cards"); os._exit(1)
    return True
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		[[ $out == errored-only ]] && ok "v0.109 po-dashboard greys only the errored project's card, says feed error and carries it in the tooltip" || bad "v0.109 errored card" "$out"
		# v0.83: the release label is the last widget of the card's top row and of the screen header, right-aligned; `no release` is muted.
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: timeout 60 python3 -I - "$DB" "$SV/events.json" "$(dirname "$PO")/../examples/projects-feed.json" 2>/dev/null <<'PY'
import http.server, importlib.machinery, importlib.util, os, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed = sys.argv[1:4]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sys.argv = [db, "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--projects-url", feed, "--view", "projects", "--project", "harbor"]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
n = {"t": 0}
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def right(lab):
    return lab.get_next_sibling() is None and lab.get_halign() == Gtk.Align.END and lab.get_xalign() == 1
def tick():
    n["t"] += 1
    nodes = [x for w in Gtk.Window.list_toplevels() for x in walk(w)]
    labs = {}
    for x in nodes:
        if isinstance(x, Gtk.Label):
            labs.setdefault(x.get_label(), []).append(x)
    if "release-3" in labs and "no release" in labs and len(labs["no release"]) >= 2:
        r3, nr = labs["release-3"][0], labs["no release"]
        ok = right(r3) and r3.has_css_class("po-text") and not r3.has_css_class("po-muted") and all(right(x) and x.has_css_class("po-muted") for x in nr)
        print("labels ok" if ok else "labels wrong")
        sys.stdout.flush()
        os._exit(0 if ok else 1)
    if n["t"] > 100:
        print("no labels"); sys.stdout.flush(); os._exit(1)
    return True
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		[[ $out == 'labels ok' ]] && ok "po-dashboard: the release label sits right-aligned last on the card and the screen header, \`no release\` muted" || bad "dashboard release label" "$out"
		# v0.58: an unsent answer draft survives the Decisions redraw (the feed refresh) and goes with its entry or its Send.
		cat >"$TMP/drafts-feed.json" <<'JSON'
[{"project":"p","item":"1","title":"c","waiting_for":"a ruling","asked_at":"2026-10-24T09:00:00Z","kind":"choice","id":"d-choice","question":"Ok?","options":[{"label":"Yes"},{"label":"No"}]},
 {"project":"p","item":"2","title":"t","waiting_for":"a ruling","asked_at":"2026-10-24T10:00:00Z","kind":"choice","id":"d-text"},
 {"project":"p","item":"3","title":"a","waiting_for":"a block","asked_at":"2026-10-24T11:00:00Z","kind":"action","id":"d-action","machine":"m","steps":[{"text":"one","expect":"x"},{"text":"two","expect":"y"}],"done_when":"pass"}]
JSON
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: XDG_CONFIG_HOME="$TMP/xdg-drafts" timeout 60 python3 -I - "$DB" "$SV/events.json" "$TMP/drafts-feed.json" 2>/dev/null <<'PY'
import gc, http.server, importlib.machinery, importlib.util, os, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed = sys.argv[1:4]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d/" % srv.server_address[1]
sys.argv = [db, "--url", base, "--decisions-url", feed, "--answer-url", base, "--view", "decisions"]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def cards(win):
    out, c = {}, win.decisions_list.get_first_child()
    while c:
        nodes = list(walk(c))
        labels = {n.get_label() for n in nodes if isinstance(n, (Gtk.ToggleButton, Gtk.Button))}
        ents = [n for n in nodes if isinstance(n, Gtk.TextView)]
        if "Pass" in labels:
            out["action"] = nodes
        elif "Yes" in labels:
            out["choice"] = nodes
        elif ents:
            out["text"] = nodes
        c = c.get_next_sibling()
    return out
def btn(nodes, label, cls=Gtk.Button):
    return next(n for n in nodes if isinstance(n, cls) and n.get_label() == label)
class Box:
    def __init__(self, v): self.v = v; self.b = v.get_buffer()
    def set_text(self, t): self.b.set_text(t)
    def get_text(self): return self.b.get_text(self.b.get_start_iter(), self.b.get_end_iter(), False)
def entry(nodes):
    return Box(next(n for n in nodes if isinstance(n, Gtk.TextView)))
def counter(nodes):
    return next(n.get_text() for n in nodes if isinstance(n, Gtk.Label) and " / 2000" in n.get_text())
def state(cs):
    c, t, a = cs["choice"], cs["text"], cs["action"]
    steps = {n.get_label(): n.get_active() for n in a if isinstance(n, Gtk.ToggleButton) and n.get_label() in ("1", "2")}
    return {
        "choice": (btn(c, "No", Gtk.ToggleButton).get_active(), entry(c).get_text(), btn(c, "Send").get_sensitive()),
        "text": (entry(t).get_text(), btn(t, "Send").get_sensitive()),
        "action": (btn(a, "Failed", Gtk.ToggleButton).get_active(), steps, entry(a).get_text(), btn(a, "Send").get_sensitive()),
    }
res = {"n": 0}
def finish(code):
    sys.stdout.flush(); os._exit(code)
def tick():
    res["n"] += 1
    win = next((o for o in gc.get_objects() if type(o).__name__ == "Dashboard" and hasattr(o, "drafts")), None)  # the window object is not a toplevel
    if win is not None and len(win.decisions) == 3 and len(cards(win)) == 3:
        GLib.idle_add(run, win)
        return False
    if res["n"] > 100:
        print("FAIL no decisions"); finish(1)
    return True
def run(win):
    try:
        cs = cards(win)
        # v0.61 (c): "or write your own" alone sends; Pass + a note sends; Pass then Failed without a step does not.
        entry(cs["choice"]).set_text("mine alone")
        print("PASS writein" if btn(cs["choice"], "Send").get_sensitive() else "FAIL writein")
        entry(cs["choice"]).set_text("")
        print("PASS writein-empty" if not btn(cs["choice"], "Send").get_sensitive() else "FAIL writein-empty")
        btn(cs["action"], "Pass", Gtk.ToggleButton).set_active(True)
        entry(cs["action"]).set_text("fine")
        print("PASS passnote" if btn(cs["action"], "Send").get_sensitive() else "FAIL passnote")
        btn(cs["action"], "Failed", Gtk.ToggleButton).set_active(True)
        print("PASS failednostep" if not btn(cs["action"], "Send").get_sensitive() else "FAIL failednostep")
        entry(cs["action"]).set_text("")
        btn(cs["choice"], "No", Gtk.ToggleButton).set_active(True)
        entry(cs["choice"]).set_text("because")
        entry(cs["text"]).set_text("my answer")
        btn(cs["action"], "Failed", Gtk.ToggleButton).set_active(True)
        btn(cs["action"], "2", Gtk.ToggleButton).set_active(True)
        entry(cs["action"]).set_text("it broke")
        before = state(cs)
        win.redraw_decisions()
        after = state(cards(win))
        print("PASS choice" if after["choice"] == before["choice"] == (True, "because", True) else "FAIL choice %r %r" % (before["choice"], after["choice"]))
        print("PASS text" if after["text"] == before["text"] == ("my answer", True) else "FAIL text %r %r" % (before["text"], after["text"]))
        print("PASS action" if after["action"] == before["action"] == (True, {"1": False, "2": True}, "it broke", True) else "FAIL action %r %r" % (before["action"], after["action"]))
        # v0.68: multi-line text keeps its breaks over a redraw, the counter reads right, 2001 characters turn Send off.
        entry(cs["text"]).set_text("l1\nl2\n" + "\n".join("x" * 5 for _ in range(30)))
        win.redraw_decisions()
        t2 = cards(win)["text"]
        print("PASS multiline" if entry(t2).get_text().startswith("l1\nl2\nxxxxx\n") and entry(t2).get_text().count("\n") == 31 else "FAIL multiline")
        print("PASS counter" if counter(t2) == "%d / 2000" % len(entry(t2).get_text().strip()) else "FAIL counter %r" % counter(t2))
        entry(t2).set_text("y" * 2000)
        print("PASS at2000" if btn(t2, "Send").get_sensitive() and counter(t2) == "2000 / 2000" else "FAIL at2000")
        entry(t2).set_text("y" * 2001)
        print("PASS over2001" if not btn(t2, "Send").get_sensitive() and counter(t2) == "2001 / 2000" and entry(t2).get_text() == "y" * 2001 else "FAIL over2001")
        entry(t2).set_text("my answer")
        win.decisions = [e for e in win.decisions if e["id"] != "d-text"]
        win.redraw_decisions()
        print("PASS dropped" if set(win.drafts) == {"d-choice", "d-action"} else "FAIL dropped %r" % sorted(win.drafts))
        btn(cards(win)["choice"], "Send").emit("clicked")
        print("PASS sent" if set(win.drafts) == {"d-action"} else "FAIL sent %r" % sorted(win.drafts))
    except Exception as e:
        print("FAIL error %r" % (e,))
    finish(0)
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		for t in writein writein-empty passnote failednostep choice text action multiline counter at2000 over2001 dropped sent; do
			case $t in
			writein) m="a write-in alone enables Send" ;;
			writein-empty) m="an empty write-in with no option leaves Send off" ;;
			passnote) m="Pass with a note keeps Send enabled" ;;
			failednostep) m="Pass then Failed without a step turns Send off" ;;
			choice) m="a choice pick and its write-in text survive the redraw, Send still enabled" ;;
			text) m="typed answer text survives the redraw, Send still enabled" ;;
			action) m="Failed + step + note survive the redraw, the step shows picked, Send still enabled" ;;
			multiline) m="a pasted multi-line text keeps its line breaks over a redraw" ;;
			counter) m="the counter reads the stripped length as n / 2000" ;;
			at2000) m="2000 characters leave Send on" ;;
			over2001) m="2001 characters turn Send off and the box keeps every character" ;;
			dropped) m="a decision that leaves the feed drops its draft" ;;
			sent) m="pressing Send clears that decision's draft" ;;
			esac
			grep -qx "PASS $t" <<<"$out" && ok "po-dashboard draft: $m" || bad "dashboard draft $t" "$out"
		done
		# v0.97: Send on a look card reads the installed build in the worker thread; a slow pacman never holds the main loop.
		mkdir -p "$TMP/slow-bin" && printf '#!/bin/sh\nsleep 3\necho "a 1-1"\n' >"$TMP/slow-bin/pacman" && chmod +x "$TMP/slow-bin/pacman"
		printf '[{"project":"p","item":"1","title":"Look","waiting_for":"a look","asked_at":"2026-10-29T10:00:00Z","kind":"action","id":"sl1","machine":"laptop","steps":[{"text":"open the Bookmarks menu","expect":"three bookmarks"}],"done_when":"pass","requires":{"package":"a-1-1-x86_64.pkg.tar.zst","sha256":"%s"},"fixtures":[],"checked_by":"rev","check_sha256":"%s","ready":{"build":"a 1-1","checked_at":"%s"}}]\n' "$sha" "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$TMP/slow-feed.json"
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: PATH="$TMP/slow-bin:$PATH" XDG_CONFIG_HOME="$TMP/xdg-slow" timeout 60 python3 -I - "$DB" "$SV/events.json" "$TMP/slow-feed.json" 2>&1 <<'PY'
import gc, http.server, importlib.machinery, importlib.util, os, sys, threading, time
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed = sys.argv[1:4]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d/" % srv.server_address[1]
sys.argv = [db, "--url", base, "--decisions-url", feed, "--answer-url", base, "--view", "decisions"]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
res = {"n": 0}
def finish(code):
    sys.stdout.flush(); os._exit(code)
def tick():
    res["n"] += 1
    win = next((o for o in gc.get_objects() if type(o).__name__ == "Dashboard" and hasattr(o, "drafts")), None)
    if win is not None and len(win.decisions) == 1 and win.decisions_list.get_first_child() is not None:
        GLib.idle_add(run, win)
        return False
    if res["n"] > 100:
        print("FAIL no decisions"); finish(1)
    return True
def run(win):
    try:
        nodes = list(walk(win.decisions_list))
        next(n for n in nodes if isinstance(n, Gtk.ToggleButton) and n.get_label() == "Pass").set_active(True)
        send = next(n for n in nodes if isinstance(n, Gtk.Button) and n.get_label() == "Send")
        t0 = time.monotonic()
        send.emit("clicked")
        GLib.idle_add(lambda: (res.__setitem__("back", time.monotonic() - t0), False)[1])
        GLib.timeout_add(1000, lambda: (print("PASS offthread" if res.get("back", 9) < 0.5 else "FAIL offthread %r" % res.get("back")), finish(0)))
    except Exception as e:
        print("FAIL error %r" % (e,)); finish(0)
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		grep -qx "PASS offthread" <<<"$out" && ok "po-dashboard Send on a look card returns to the main loop while a 3 s pacman runs" || bad "dashboard send offthread" "$out"
		# v0.63: the Decisions toggle hides the choice cards and keeps the action cards; the choice is saved next to the Actions one.
		cat >"$TMP/toggle-feed.json" <<'JSON'
[{"project":"p","item":"1","title":"c","waiting_for":"a ruling","asked_at":"2026-10-24T09:00:00Z","kind":"choice","id":"t-choice","question":"Ok?","options":[{"label":"Yes"},{"label":"No"}]},
 {"project":"p","item":"3","title":"a","waiting_for":"a block","asked_at":"2026-10-24T11:00:00Z","kind":"action","id":"t-action","machine":"m","steps":[{"text":"one","expect":"x"},{"text":"two","expect":"y"}],"done_when":"pass"}]
JSON
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: XDG_CONFIG_HOME="$TMP/xdg-toggle" timeout 60 python3 -I - "$DB" "$SV/events.json" "$TMP/toggle-feed.json" "$TMP/xdg-toggle" 2>&1 <<'PY'
import gc, http.server, importlib.machinery, importlib.util, json, os, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, feed, xdg = sys.argv[1:5]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        self.send_response(200); self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
base = "http://127.0.0.1:%d/" % srv.server_address[1]
sys.argv = [db, "--url", base, "--decisions-url", feed, "--answer-url", base, "--view", "decisions"]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def kinds(win):
    out, c = set(), win.decisions_list.get_first_child()
    while c:
        labels = {n.get_label() for n in walk(c) if isinstance(n, (Gtk.ToggleButton, Gtk.Button))}
        if "Pass" in labels:
            out.add("action")
        elif "Yes" in labels:
            out.add("choice")
        c = c.get_next_sibling()
    return out
res = {"n": 0}
def finish(code):
    sys.stdout.flush(); os._exit(code)
def tick():
    res["n"] += 1
    win = next((o for o in gc.get_objects() if type(o).__name__ == "Dashboard" and hasattr(o, "decisions_toggle")), None)
    if win is not None and len(win.decisions) == 2 and kinds(win) == {"choice", "action"}:
        GLib.idle_add(run, win)
        return False
    if res["n"] > 100:
        print("FAIL no decisions"); finish(1)
    return True
def run(win):
    try:
        win.decisions_toggle.set_active(False)
        k = kinds(win)
        print("PASS choices-hidden" if "choice" not in k else "FAIL choices-hidden %r" % sorted(k))
        print("PASS actions-kept" if k == {"action"} else "FAIL actions-kept %r" % sorted(k))
        win.decisions_toggle.set_active(True)
        k = kinds(win)
        print("PASS choices-back" if k == {"choice", "action"} else "FAIL choices-back %r" % sorted(k))
        win.actions_toggle.set_active(False)
        win.actions_toggle.set_active(True)
        d = os.path.join(xdg, "po-dashboard")
        got = [json.load(open(os.path.join(d, f))) for f in sorted(os.listdir(d))]
        print("PASS saved-file" if got == [{"actions": True, "decisions": True}] else "FAIL saved-file %r" % (got,))
    except Exception as e:
        print("FAIL error %r" % (e,))
    finish(0)
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		for t in choices-hidden actions-kept choices-back saved-file; do
			case $t in
			choices-hidden) m="Decisions off hides the choice cards" ;;
			actions-kept) m="Decisions off keeps the action cards" ;;
			choices-back) m="Decisions back on brings the choice cards back" ;;
			saved-file) m="the saved filter file is {actions: true, decisions: true}" ;;
			esac
			grep -qx "PASS $t" <<<"$out" && ok "po-dashboard toggle: $m" || bad "dashboard toggle $t" "$out"
		done
		# v0.142: the window itself: one panel per list with flat rows, usage once in the Team header, the Reports header,
		# the project screen on DOING newest first with the same small buttons as every other control.
		printf '[{"agent":"ada","state":"WORKING","now":"1.4","owns":["1.4"],"usage":{"five_hour":0.22,"seven_day":0.64}},{"agent":"bo","state":"idle 3h","owns":[],"usage":{"five_hour":0.22,"seven_day":0.64}},{"agent":"cy","state":"idle 1h","owns":[]}]\n' >"$TMP/v142-team.json"
		# helper
		out=$(DBUS_SESSION_BUS_ADDRESS=disabled: timeout 90 python3 -I - "$DB" "$SV/events.json" "$TMP/v142-team.json" "$(dirname "$PO")/../examples/projects-feed.json" 2>/dev/null <<'PY'
import gc, http.server, importlib.machinery, importlib.util, os, sys, threading
sys.dont_write_bytecode = True
import gi
gi.require_version("Gtk", "4.0")
from gi.repository import GLib, Gtk
db, events, team, projects = sys.argv[1:5]
body = open(events, "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
sys.argv = [db, "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--team-url", team, "--projects-url", projects,
            "--decisions-url", os.path.join(os.path.dirname(projects), "decisions-feed.json"), "--archive-url", events, "--view", "team", "--no-memory-log"]
loader = importlib.machinery.SourceFileLoader("po_dashboard", db)
mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("po_dashboard", loader))
loader.exec_module(mod)
def walk(w):
    yield w
    c = w.get_first_child()
    while c:
        yield from walk(c)
        c = c.get_next_sibling()
def kids(box):
    out, c = [], box.get_first_child()
    while c:
        out.append(c); c = c.get_next_sibling()
    return out
def say(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name + ("" if cond else " " + repr(detail)))
res = {"n": 0}
def finish(code):
    sys.stdout.flush(); os._exit(code)
def tick():
    res["n"] += 1
    win = next((o for o in gc.get_objects() if type(o).__name__ == "Dashboard" and hasattr(o, "team_list")), None)
    if win is not None and win.team and win.events and win.projects and kids(win.list):
        GLib.timeout_add(300, run, win)
        return False
    if res["n"] > 200:
        print("FAIL no data"); finish(1)
    return True
def run(win):
    try:
        rows = kids(win.team_list) + kids(win.list)
        say("panels", all(b.has_css_class("po-panel") for b in (win.list, win.team_list, win.decisions_list)))
        say("flat-rows", rows and all(r.has_css_class("po-row") for r in rows), [r.get_css_classes() for r in rows[:3]])
        texts = [n.get_label() for n in walk(win.team_list) if isinstance(n, Gtk.Label)]
        say("usage-once", win.status.get_label() == "3 agents · subscription 5h 22% · 7d 64%" and not any("22%" in t for t in texts), (win.status.get_label(), texts))
        say("tab-selected", win.view_buttons["team"].get_active() and win.view_buttons["team"].has_css_class("po-view"))
        def smalls():
            return [n for n in walk(win.win) if n.has_css_class("po-small") and n.get_mapped()]
        def small_check(state):  # the measured minimum is the border box (padding and border in, no margin on .po-small)
            s = smalls()
            tall = [n.measure(Gtk.Orientation.VERTICAL, -1)[0] for n in s]
            say("small-" + state, len(s) >= 2 and 24 <= min(tall) and max(tall) <= 26, (state, len(s), sorted(set(tall))))
            return [n.get_label() for n in s]
        win.view_buttons["events"].set_active(True)
        win.reports_button.set_active(False)
        say("small-archive", "Archive" in small_check("toolbar"))
        end = GLib.get_monotonic_time() + 500000  # let the frame clock allocate the toolbar after the view switch
        while GLib.get_monotonic_time() < end:
            GLib.MainContext.default().iteration(False)
        # the allocated border box of the built toolbar buttons (get_height() is the content box and leaves out padding and border)
        boxes = [n.compute_bounds(n.get_parent())[1] for n in smalls()]
        heights = sorted(set(round(b.get_height()) for b in boxes))
        say("small-allocated", len(boxes) >= 2 and 24 <= heights[0] and heights[-1] <= 26 and min(b.get_width() for b in boxes) >= 24, heights)
        win.reports_button.set_active(True)
        small_check("reports")
        st = win.status.get_label()
        say("reports-header", win.title_label.get_label() == "Reports" and st.startswith("7 d · as of ") and "events" not in st, (win.title_label.get_label(), st))
        win.reports_button.set_active(False)
        say("events-header", win.title_label.get_label() == "Gate events", win.title_label.get_label())
        win.view_buttons["projects"].set_active(True)
        win.open_project(win.projects[0]["project"])
        small_check("project-screen")
        win.view_buttons["decisions"].set_active(True)
        say("small-actions", {"Actions", "Decisions"} <= set(small_check("decisions")))
        toggles = [n for n in walk(win.pscreen) if isinstance(n, Gtk.ToggleButton)]
        on = [t.get_label() for t in toggles if t.get_active()]
        say("screen-doing", len(on) == 1 and on[0].startswith("DOING "), on)
        say("screen-buttons", toggles and all(t.has_css_class("po-small") for t in toggles), [t.get_css_classes() for t in toggles])
        panels = [n for n in walk(win.pscreen) if isinstance(n, Gtk.Box) and n.has_css_class("po-panel")]
        say("screen-panel", len(panels) == 1 and all(r.has_css_class("po-row") for r in kids(panels[0])), len(panels))
    except Exception as e:
        print("FAIL error %r" % (e,))
    finish(0)
GLib.timeout_add(100, tick)
mod.main()
PY
		)
		for t in panels flat-rows usage-once tab-selected reports-header events-header screen-doing screen-buttons screen-panel small-toolbar small-archive small-allocated small-reports small-project-screen small-decisions small-actions; do
			case $t in
			panels) m="Events, Team and Decisions each draw one raised panel (po-panel)" ;;
			flat-rows) m="the Team and Events lines inside it are flat rows (po-row), not cards of their own" ;;
			usage-once) m="a usage every agent shares is in the Team header once, on no line" ;;
			tab-selected) m="the selected view tab is checked (its accent fill is the CSS's)" ;;
			reports-header) m="Reports says Reports over 7 d · as of <time>, not the Events count" ;;
			events-header) m="Reports off gives the Gate events title back" ;;
			screen-doing) m="a project screen opens on DOING" ;;
			screen-buttons) m="the project screen's filter buttons are the small po buttons, not stock GTK" ;;
			screen-panel) m="the project screen's items are flat rows in one panel" ;;
			small-toolbar) m="every small button of the Events toolbar measures 24 to 26 px tall, border included (ui-guidelines 1.10)" ;;
			small-allocated) m="the built toolbar's small buttons are allocated 24 to 26 px tall and at least 24 px wide, border included" ;;
			small-reports) m="the Reports header's small buttons measure 24 to 26 px tall" ;;
			small-project-screen) m="the project screen's small buttons measure 24 to 26 px tall" ;;
			small-archive) m="the Archive button (shown with an archive feed) is one of the measured small buttons" ;;
			small-decisions) m="the Decisions view's small buttons measure 24 to 26 px tall" ;;
			small-actions) m="the Actions and Decisions filter buttons are among them" ;;
			esac
			grep -qx "PASS $t" <<<"$out" && ok "po-dashboard v0.142: $m" || bad "dashboard v0.142 $t" "$out"
		done
			[[ -s $TMP/shot.png && -s $TMP/shot-decisions.png && -s $TMP/shot-team.png && -s $TMP/shot-reports.png ]] && ok "po-dashboard opens, loads events and saves a screenshot, also in the Decisions, Team (LIMIT and usage rows) and Reports views" || bad "dashboard ui smoke"
	else
		ok "po-dashboard UI smoke skipped: no display"
	fi
else
\tok "po-dashboard UI smoke skipped: GTK 4 or PyGObject missing"
fi

# demo server POST /answers (v0.49).
DEMO_OUT="$TMP/demo.out"
python3 -B "$(dirname "$PO")/../examples/events-demo-server.py" --port 0 --every 999 >"$DEMO_OUT" 2>&1 &
DEMO_PID=$!
for _ in $(seq 1 50); do [[ -s "$DEMO_OUT" ]] && break; sleep 0.1; done
DEMO_PORT=$(sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p' "$DEMO_OUT" | head -1)
if [[ -n "$DEMO_PORT" ]]; then
    # helper
    if demo_out=$(python3 -B -I - "$DEMO_PORT" <<'PY'
import http.client, json, sys
port = int(sys.argv[1])
def post(body, token=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    c.request("POST", "/answers", json.dumps(body).encode(), h)
    r = c.getresponse(); r.read(); c.close()
    return r.status
b = {"project": "harbor", "id": "ask-0808", "answer_id": "6bde9c7a-bd8f-4ae2-a2c7-9f6d8beade07", "kind": "choice", "option": "Yes", "text": ""}
assert post(b) == 401, "no token should be 401"
assert post(b, "secret") == 201, "first answer should be 201"
assert post(b, "secret") == 200, "repeat answer_id should be 200"
assert post({"project": "harbor", "answer": "Yes"}, "secret") == 404, "missing id should be 404"
PY
    ); then
    ok "demo server: POST /answers (401, 201, 200, 404)"
else
    bad "demo server: POST /answers" "$demo_out"
fi
else
    ok "demo server: POST /answers skipped (server did not start)"
fi
kill $DEMO_PID 2>/dev/null; wait $DEMO_PID 2>/dev/null

# po-dashboard-install.
INST2=""$(cd "$(dirname "$PO")/.." && pwd)/bin/po-dashboard-install""
tmp=$(mktemp -d)
"$INST2" --prefix "$tmp" >/dev/null 2>&1
[[ -f "$tmp/applications/po-dashboard.desktop" ]] && ok "dashboard-install: .desktop created" || bad "dashboard-install desktop"
grep -q "^Exec=$(cd "$(dirname "$PO")/.." && pwd)/bin/po-dashboard$" "$tmp/applications/po-dashboard.desktop" && ok "dashboard-install: Exec is absolute path" || bad "dashboard-install exec"
[[ -f "$tmp/icons/hicolor/512x512/apps/po-dashboard.png" ]] && ok "dashboard-install: 512 icon" || bad "dashboard-install 512"
[[ -f "$tmp/icons/hicolor/scalable/apps/po-dashboard.svg" ]] && ok "dashboard-install: svg icon" || bad "dashboard-install svg"
# idempotence: same file list after re-run
before=$(find "$tmp" -type f | sort)
"$INST2" --prefix "$tmp" >/dev/null 2>&1
after=$(find "$tmp" -type f | sort)
[[ "$before" == "$after" ]] && ok "dashboard-install: idempotent file list" || bad "dashboard-install idempotent"
# uninstall removes all
"$INST2" --prefix "$tmp" --uninstall >/dev/null 2>&1
[[ -z "$(find "$tmp" -name '*po-dashboard*' -print -quit)" ]] && ok "dashboard-install: uninstall removes all" || bad "dashboard-install uninstall"
rm -rf "$tmp"
if command -v desktop-file-validate >/dev/null 2>&1; then
	tmp=$(mktemp -d)
	"$INST2" --prefix "$tmp" >/dev/null 2>&1
	desktop-file-validate "$tmp/applications/po-dashboard.desktop" >/dev/null 2>&1 && ok "dashboard-install: desktop-file-validate clean" || bad "dashboard-install validate"
	rm -rf "$tmp"
else
	ok "dashboard-install: desktop-file-validate not installed (skipped)"
fi

# ---- the runner fails when a block dies (item AV) --------------------------
# Throwaway copies of this runner's own prelude and tail around a deliberately
# broken body: each must exit non-zero, never print "0 failed", and say why.
RUNNER=$(readlink -f "${BASH_SOURCE[0]}")
mkdir -p "$TMP/crash"
mini() { # <name> <body>: a copy of the runner with <body> as its only content
	{
		sed -n '1,/^# expect <name>/p' "$RUNNER"
		printf '%s\n' "$2"
		sed -n '/^# ---- run end/,$p' "$RUNNER"
	} >"$TMP/crash/$1.sh"
}
crash_case() { # <name> <want pattern> <body>
	local out code
	mini "$1" "$3"
	out=$(bash "$TMP/crash/$1.sh" 2>&1)
	code=$?
	[[ $code != 0 ]] && ! grep -qE '[0-9] passed, 0 failed$' <<<"$out" && grep -qE -- "$2" <<<"$out" &&
		ok "runner: $1 gives a non-zero exit, no '0 failed' line and '$2'" || bad "runner: $1 (exit $code)" "$out"
}
crash_case "a python block that raises" '^FAIL .*aborted \(exit 1\)' "block py python3 -I -c 'import sys; print(\"ok\tx\t\"); raise RuntimeError(\"boom\")'"
crash_case "a shell block that exits 3" '^FAIL .*aborted \(exit 3\)' "block sh bash -c 'printf \"ok\tx\t\n\"; exit 3'"
crash_case "a block that exits 0 without its marker" '^FAIL .*aborted \(no BLOCK-END marker\)' "block early bash -c 'printf \"ok\tx\t\n\"; exit 0'"
crash_case "a block that ends with another name's marker" '^FAIL .*aborted \(no BLOCK-END marker\)' "block one bash -c 'echo \"BLOCK-END two\"'"
# shellcheck disable=SC2016 # the body is the text of a broken runner
crash_case "an unbound variable" '^RUN-ABORTED$' 'ok before; printf "%s\n" "$never_set_anywhere"; ok after'
crash_case "an exit 0 in the runner" '^RUN-ABORTED$' 'ok before; exit 0'
crash_case "an exit 3 in the runner" '^RUN-ABORTED$' 'ok before; exit 3'
crash_case "a signal" '^RUN-ABORTED$' 'ok before; kill -TERM $$; sleep 5'
mini clean 'ok first
block good bash -c '"'"'printf "ok\tsecond\t\nok\tthird\t\nBLOCK-END good\n"'"'"
out=$(bash "$TMP/crash/clean.sh" 2>&1)
code=$?
[[ $code == 0 && $(tail -1 <<<"$out") == '3 passed, 0 failed' && $(tail -2 <<<"$out" | head -1) == 'RUN-END 3 0 1' ]] &&
	! grep -q '^RUN-ABORTED' <<<"$out" &&
	ok "runner: a clean copy ends RUN-END 3 0 1 then '3 passed, 0 failed', exit 0" || bad "runner: clean copy (exit $code)" "$out"

# po stamp on a fixture whose test count comes from such a runner.
crash_count() { # the po-kit count command, run on the runner copy $1
	printf 'bash -o pipefail -c '"'"'bash %s 2>&1 | sed -nE \\"s/^([0-9]+) passed, 0 failed$/test result: ok. \\\\1 passed; 0 failed/p; /^(RUN-END|RUN-ABORTED)/p\\"'"'"'' "$1"
}
rm -f "$W"/gate-*.txt
for c in "a python block that raises" "a shell block that exits 3" "a block that exits 0 without its marker" "an unbound variable" "an exit 0 in the runner" "a signal"; do
	f=${c// /_}
	cp "$TMP/crash/$c.sh" "$TMP/crash/$f.sh"
	COUNT_CMD=$(crash_count "$TMP/crash/$f.sh") SENTINEL=1 stamp_manifest check=true
	out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
	code=$?
	[[ $code == 4 ]] && grep -qE 'test_count_cmd .*(exited|printed)' <<<"$out" && ! compgen -G "$W/gate-*.txt" >/dev/null &&
		ok "stamp refuses (exit 4) a test count from a runner with $c, nothing written" || bad "stamp: $c (exit $code)" "$out"
done
COUNT_CMD=$(crash_count "$TMP/crash/clean.sh") SENTINEL=1 stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx 'gate PASS: check   tests 3 passed' <<<"$out" &&
	ok "stamp counts a clean copy of the runner (3 passed)" || bad "stamp: clean copy (exit $code)" "$out"
rm -f "$W"/gate-*.txt
# The sentinel rule itself, on canned output.
COUNT_CMD="echo 'test result: ok. 5 passed; 0 failed'" SENTINEL=1 stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 4 ]] && grep -q 'printed no RUN-END sentinel' <<<"$out" && ! compgen -G "$W/gate-*.txt" >/dev/null &&
	ok "stamp refuses (exit 4) a count with no RUN-END, naming why" || bad "stamp: no sentinel (exit $code)" "$out"
COUNT_CMD="echo 'test result: ok. 5 passed; 0 failed'; echo 'RUN-END 5 0 1'; echo RUN-ABORTED" SENTINEL=1 stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 4 ]] && grep -q 'printed RUN-ABORTED' <<<"$out" && ! compgen -G "$W/gate-*.txt" >/dev/null &&
	ok "stamp refuses (exit 4) a count beside a RUN-ABORTED line" || bad "stamp: RUN-ABORTED (exit $code)" "$out"
COUNT_CMD="echo 'test result: ok. 5 passed; 0 failed'; echo 'RUN-END 5 0 1'" SENTINEL=1 stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx 'gate PASS: check   tests 5 passed' <<<"$out" &&
	ok "stamp takes a count that has RUN-END" || bad "stamp: sentinel present" "$out"
rm -f "$W"/gate-*.txt
COUNT_CMD="echo 'test result: ok. 5 passed; 0 failed'" stamp_manifest check=true
out=$("$PO" -C "$W" --manifest "$TMP/s.toml" stamp 2>&1)
code=$?
[[ $code == 0 ]] && grep -qx 'gate PASS: check   tests 5 passed' <<<"$out" &&
	ok "without run_sentinel a count needs no RUN-END (other projects' runners)" || bad "stamp: no run_sentinel key" "$out"
rm -f "$W"/gate-*.txt
printf '%s[gate]\ntest_count_cmd = "true"\nrun_sentinel = "yes"\n' "$GOOD_MANIFEST" >"$TMP/m.toml"
expect "run_sentinel must be \"required\"" 2 'run_sentinel must be "required": yes' -- -C "$W" --manifest "$TMP/m.toml" stamp

# Self-audit: a multi-check heredoc or `bash -c` block must go through `block`.
audit=$(awk '
	{ line = $0 }
	line ~ /^[ \t]*#/ { prev = line; next }
	(line ~ ("python" "3 ([^<]* )?- [^<]*<<") || line ~ ("bash" " -c ")) && line !~ /^[ \t]*(block|crash_case) / && prev !~ /^[ \t]*# helper$/ {
		printf "%d: %s\n", NR, line
	}
	{ prev = line }
' "$RUNNER")
[[ -z $audit ]] && ok "self-audit: every python and shell block goes through block (or is marked # helper)" ||
	bad "self-audit: a block is not run through block" "$audit"

# ---- po ready tests -------------------------------------------------------
R2=$TMP/readyrepo
make_repo "$R2"
# add a candidate file + ready config
cat >"$R2/ready.jsonl" <<'EOF'
{"item":"v1.0.5","title":"Fifth","agents":["a"],"depends":["v1.0.2"],"needs_note":"docs/backlog/v1.md"}
{"item":"v1.0.4","title":"Fourth","depends":["v1.0.9"],"needs_note":"docs/nope.md"}
{"item":"v1.0.1","title":"done one"}
{"item":"v1.0.5","title":"absent"}
{"item":"v1.0.5","title":"corrected fifth"}
malformed line here
EOF
# configure ready.file and project filter
# helper
python3 - "$R2/po.toml" <<'PY2'
import re,sys
p=sys.argv[1]
s=open(p).read()
s=s.replace('[versioning]','[ready]\nfile = "ready.jsonl"\n\n[versioning]',1)
open(p,'w').write(s)
PY2
# add a TODO item to the backlog
# helper
python3 - "$R2" <<'PY2'
import sys
d=sys.argv[1]
# backlog table row
bp=d+"/docs/BACKLOG.md"
s=open(bp).read()
s=s.replace("| v1.0.2 | Second | DONE | backlog/v1.md |","| v1.0.2 | Second | DONE | backlog/v1.md |\n| v1.0.5 | Fifth | TODO | backlog/v1.md |")
open(bp,"w").write(s)
# spec heading
sp=d+"/docs/backlog/v1.md"
s=open(sp).read()
s+="\n## v1.0.5 — Fifth — TODO\n"
open(sp,"w").write(s)
PY2
git -C "$R2" add -A && git -C "$R2" commit -qm readycfg >/dev/null 2>&1

# DONE excluded: v1.0.1 not in output
out=$(cd "$R2" && "$PO" ready 2>&1); code=$?
if grep -q "v1.0.1" <<<"$out"; then bad "ready: DONE excluded"; else ok "ready: DONE excluded"; fi
# TODO with met depends + present note listed (v1.0.3 corrected)
if grep -q "v1.0.5" <<<"$out" && grep -q "corrected fifth" <<<"$out"; then ok "ready: ready item listed"; else bad "ready: ready item listed" "$out"; fi
# unmet depends excluded
if grep -q "v1.0.4" <<<"$out"; then bad "ready: unmet depends excluded"; else ok "ready: unmet depends excluded"; fi
# --json
out=$(cd "$R2" && "$PO" ready --json 2>/dev/null)
if python3 -c "import json,sys; d=json.load(sys.stdin); assert any(x['item']=='v1.0.5' for x in d)" <<<"$out" 2>/dev/null; then ok "ready: --json valid"; else bad "ready: --json valid" "$out"; fi
# --explain reports reasons
out=$(cd "$R2" && "$PO" ready --explain 2>&1)
if grep -q "depends" <<<"$out" || grep -q "missing note" <<<"$out" || grep -q "absent" <<<"$out"; then ok "ready: --explain reasons"; else bad "ready: --explain reasons" "$out"; fi
# malformed line reported with line number
if grep -q "malformed line" <<<"$out"; then ok "ready: malformed line reported"; else bad "ready: malformed line reported" "$out"; fi
# last-line-wins: corrected third title present already checked
# v0.149: no [ready] file, or one missing on disk, is a configuration error
# (exit 1) that says why, for ready and for dispatch.
grep -v '^file = "ready.jsonl"$' "$R2/po.toml" | sed '/^\[ready\]$/d' >"$TMP/ready-none.toml"
for args in "" "--json" "--explain"; do
	# shellcheck disable=SC2086
	out=$("$PO" -C "$R2" --manifest "$TMP/ready-none.toml" ready $args 2>"$TMP/ready-err"); code=$?
	[[ $code == 1 && -z $out && $(cat "$TMP/ready-err") == 'po: no [ready] file configured in po.toml' ]] &&
		ok "ready ${args:-(plain)}: no [ready] file exits 1 naming [ready] file on stderr" ||
		bad "ready ${args:-(plain)} no [ready] (exit $code)" "$out / $(cat "$TMP/ready-err")"
done
for mode in --plan --commit; do
	out=$("$PO" -C "$R2" --manifest "$TMP/ready-none.toml" dispatch $mode 2>"$TMP/ready-err"); code=$?
	[[ $code == 1 && -z $out && $(cat "$TMP/ready-err") == 'po dispatch: no [ready] file configured in po.toml' ]] &&
		ok "dispatch $mode: no [ready] file exits 1, one 'po dispatch:' line on stderr, stdout empty" ||
		bad "dispatch $mode no [ready] (exit $code)" "$out / $(cat "$TMP/ready-err")"
done
sed 's|^file = "ready.jsonl"$|file = "gone.jsonl"|' "$R2/po.toml" >"$TMP/ready-gone.toml"
out=$("$PO" -C "$R2" --manifest "$TMP/ready-gone.toml" ready 2>"$TMP/ready-err"); code=$?
[[ $code == 1 && -z $out && $(cat "$TMP/ready-err") == 'po: ready file gone.jsonl not found' ]] &&
	ok "ready: a [ready] file missing on disk exits 1 naming the path" || bad "ready missing file (exit $code)" "$out / $(cat "$TMP/ready-err")"
out=$("$PO" -C "$R2" --manifest "$TMP/ready-gone.toml" dispatch --plan 2>"$TMP/ready-err"); code=$?
[[ $code == 1 && -z $out && $(cat "$TMP/ready-err") == 'po dispatch: ready file gone.jsonl not found' ]] &&
	ok "dispatch --plan: a [ready] file missing on disk exits 1 naming the path" || bad "dispatch missing file (exit $code)" "$out / $(cat "$TMP/ready-err")"
git -C "$R2" status --porcelain | grep -q . && bad "ready/dispatch config errors changed the repo" "$(git -C "$R2" status --porcelain)" ||
	ok "ready/dispatch config errors change nothing in the repo"
# [project] name (v0.46): the manifest accepts it, and po ready keeps the
# shared file's lines for this project and those that name none.
printf '{"item":"v1.0.5","title":"ours","project":"alpha"}\n{"item":"v1.0.5","title":"theirs","project":"beta"}\n' >"$TMP/ready-shared.jsonl"
sed "s|^file = \"ready.jsonl\"|file = \"$TMP/ready-shared.jsonl\"|" "$R2/po.toml" >"$TMP/ready-project.toml"
printf '\n[project]\nname = "alpha"\n' >>"$TMP/ready-project.toml"
out=$("$PO" -C "$R2" --manifest "$TMP/ready-project.toml" ready 2>&1); code=$?
[[ $code == 0 && $out == *'v1.0.5  ours'* && $out != *theirs* ]] &&
	ok "ready: [project] name is a manifest key and filters a shared ready file" || bad "ready: [project] name (exit $code)" "$out"
printf '\n[project]\nnmae = "alpha"\n' >"$TMP/ready-typo.toml"
expect "manifest: a typo in [project] is an error" 2 "nmae" -- -C "$R2" --manifest "$TMP/ready-typo.toml" status

# ---- po dispatch (item AS) -------------------------------------------------
# A fake roster and ready list: ada is WORKING on 1.1, bo and cy are free, di
# is free but only eligible where named. Order: cy first, then bo, then ada.
DP=$TMP/dispatch
mkdir -p "$DP/docs" "$DP/bin"
git init -q -b main "$DP"
git -C "$DP" config user.name t
git -C "$DP" config user.email t@example.invalid
cat >"$DP/docs/BACKLOG.md" <<'MD'
# Backlog

| Item | Status | Owner |
|---|---|---|
| v1.1 | DOING | ada |
| v1.2 | TODO |  |
| v1.3 | TODO |  |
| v1.4 | TODO |  |
| v1.5 | TODO |  |
| v1.6 | TODO |  |
MD
cat >"$DP/ready.jsonl" <<'JL'
{"item":"v1.2","title":"Two","agents":["ada","bo","cy"]}
{"item":"v1.3","title":"Three","agents":["cy","bo"]}
{"item":"v1.4","title":"Four","agents":["cy"]}
{"item":"v1.5","title":"Five","agents":["nobody"]}
{"item":"v1.6","title":"Six"}
JL
cat >"$DP/po.toml" <<'TOML'
[versioning]
tag = "v{version}"
admin_prefix = "admin:"
insert_segment = 2

[layout]
backlog = "docs/BACKLOG.md"
specs_dir = "docs"
worktrees = ".wt"
branch = "item-v{version}"
owner_column = "Owner"

[ready]
file = "ready.jsonl"

[dispatch]
order = ["cy", "bo", "ada"]
notify = "printf '%s|%s|%s\\n' \"$1\" \"$2\" \"$(basename \"$3\")\" >>notified.txt; test -s \"$3\""

[[team.agent]]
name = "ada"

[[team.agent]]
name = "bo"

[[team.agent]]
name = "cy"

[[team.agent]]
name = "di"
TOML
echo notified.txt >"$DP/.gitignore"
git -C "$DP" add -A
git -C "$DP" commit -qm init
printf '{"time":"%s","kind":"stamp","item":"v1.1","project":"dispatch","result":"pass","agent":"ada","legs":[],"detail":""}\n' \
	"$(date -u -d "1 minute ago" +%Y-%m-%dT%H:%M:%SZ)" >"$DP/.git/po-events.jsonl"
dp_before=$(git -C "$DP" rev-parse main)
DPLAN=$("$PO" -C "$DP" dispatch --plan 2>&1)
[[ $DPLAN == *'assign    v1.2  to cy'* && $DPLAN == *'assign    v1.3  to bo'* ]] &&
	ok "dispatch --plan: cheapest free eligible agent first, in [dispatch] order" || bad "dispatch plan order" "$DPLAN"
[[ $DPLAN == *'skip      v1.4  no free eligible agent'* ]] &&
	ok "dispatch --plan: an agent already given an item this run gets no second" || bad "dispatch no double assignment" "$DPLAN"
[[ $DPLAN == *'skip      v1.5  no roster agent is eligible'* ]] &&
	ok "dispatch --plan: an item no roster agent may take is skipped with the reason" || bad "dispatch ineligible reason" "$DPLAN"
[[ $DPLAN == *'assign    v1.6  to di'* && $DPLAN != *'to ada'* ]] &&
	ok "dispatch --plan: an item with no agents list goes to any free agent; a WORKING agent gets nothing" || bad "dispatch open item, working agent" "$DPLAN"
[[ $(git -C "$DP" rev-parse main) == "$dp_before" && ! -e $DP/.wt ]] &&
	ok "dispatch --plan changes nothing" || bad "dispatch plan wrote"
expect "dispatch needs --plan or --commit" 1 'give --plan or --commit' -- -C "$DP" dispatch
expect "dispatch refuses both modes" 1 'not both' -- -C "$DP" dispatch --plan --commit
# A failed open is reported and the others still go: v1.3 is made unopenable
# (a taken worktree path) before the run.
mkdir -p "$DP/.wt/item-v1.3"
DCOM=$("$PO" -C "$DP" dispatch --commit 2>&1); dcode=$?
[[ $dcode == 6 && $DCOM == *'FAILED    v1.3  to bo'* && $DCOM == *'opened    v1.2  for cy'* && $DCOM == *'opened    v1.6  for di'* ]] &&
	ok "dispatch --commit: a failed open is reported (exit 6) and the run continues" || bad "dispatch failed open (exit $dcode)" "$DCOM"
rmdir "$DP/.wt/item-v1.3"
[[ $("$PO" -C "$DP" status 2>&1) == *v1.2* && -d $DP/.wt/item-v1.2 && -d $DP/.wt/item-v1.6 ]] &&
	ok "dispatch --commit: opens through po open (worktrees made)" || bad "dispatch open effect"
DEV=$(python3 -I -c '
import json, sys
for l in open(sys.argv[1]):
    e = json.loads(l)
    if e["kind"] == "open":
        print(e["item"], e["agent"])' "$DP/.git/po-events.jsonl" | sort | paste -sd, -)
[[ $DEV == '1.2 dispatcher,1.6 dispatcher' ]] &&
	ok "dispatch --commit: the open events carry the agent dispatcher" || bad "dispatcher tag" "$DEV"
[[ $(sort "$DP/notified.txt" | paste -sd, -) == 'v1.2|cy|v1.2.md,v1.6|di|v1.6.md' ]] &&
	ok "dispatch --commit: notify runs once per opened item with item, agent and a prompt file" || bad "dispatch notify" "$(cat "$DP/notified.txt" 2>&1)"
# po open --for fills the empty owner cell, so with no manual write a second run opens
# only what is left: v1.3 for bo, and cy (now owning v1.2) gets no more.
DAGAIN=$("$PO" -C "$DP" dispatch --commit 2>&1)
[[ $(grep -c '^opened' <<<"$DAGAIN") == 1 && $DAGAIN == *'opened    v1.3  for bo'* && $DAGAIN == *'skip      v1.4  no free eligible agent'* && $(wc -l <"$DP/notified.txt") == 3 ]] &&
	ok "dispatch --commit: a second run does not reopen what is open, nor give an owner a second item" || bad "dispatch idempotent" "$DAGAIN"
DNONE=$("$PO" -C "$DP" dispatch --commit 2>&1)
[[ $DNONE == *'dispatch: 0 opened'* && $(wc -l <"$DP/notified.txt") == 3 ]] &&
	ok "dispatch --commit: with nothing left to give it is a no-op" || bad "dispatch no-op" "$DNONE"
[[ $(grep -c '^| v1.[236] | DOING | \(cy\|bo\|di\) |$' "$DP/docs/BACKLOG.md") == 3 ]] &&
	ok "dispatch --commit: po open --for wrote the owner cells itself" || bad "owner cells" "$(cat "$DP/docs/BACKLOG.md")"
# Two consecutive runs on a clean repository: each agent at most once, then nothing.
DQ=$TMP/dispatch2
git clone -q "$DP" "$DQ" 2>/dev/null
git -C "$DQ" reset -q --hard "$dp_before"
git -C "$DQ" config user.name t
git -C "$DQ" config user.email t@example.invalid
printf '{"item":"v1.2","agents":["cy","bo"]}\n{"item":"v1.3","agents":["cy","bo"]}\n{"item":"v1.4","agents":["cy","bo"]}\n' >"$DQ/ready.jsonl"
git -C "$DQ" commit -qam "ready"
Q1=$("$PO" -C "$DQ" dispatch --commit 2>&1)
Q2=$("$PO" -C "$DQ" dispatch --commit 2>&1)
[[ $(grep -c '^opened' <<<"$Q1") == 2 && $Q1 == *'opened    v1.2  for cy'* && $Q1 == *'opened    v1.3  for bo'* && $Q1 == *'skip      v1.4  no free eligible agent'* ]] &&
	ok "dispatch --commit twice: the first run gives each agent one item" || bad "dispatch run 1" "$Q1"
[[ $(grep -c '^opened' <<<"$Q2") == 0 && $Q2 == *'dispatch: 0 opened, 1 skipped, 0 failed'* ]] &&
	ok "dispatch --commit twice: the second run, with no owner written by hand, does nothing" || bad "dispatch run 2" "$Q2"

# v0.61 (i): the prompt file is written even with no [dispatch] notify.
DN=$TMP/dispatch3
git clone -q "$DP" "$DN" 2>/dev/null
git -C "$DN" reset -q --hard "$dp_before"
git -C "$DN" config user.name t
git -C "$DN" config user.email t@example.invalid
printf '{"item":"v1.2","agents":["cy","bo"]}\n' >"$DN/ready.jsonl"
sed -i '/^notify = /d' "$DN/po.toml"
git -C "$DN" commit -qam "no notify"
"$PO" -C "$DN" dispatch --commit >/dev/null 2>&1
[[ $(head -n 1 "$DN/.git/po-dispatch/v1.2.md" 2>/dev/null) == 'v1.2 → '*' · PROMPT' ]] &&
	ok "dispatch --commit: the prompt file is written without a [dispatch] notify" || bad "dispatch prompt without notify" "$(ls "$DN/.git/po-dispatch" 2>&1)"

# v0.61 (e): no bash-5-only EPOCHSECONDS in the kit (README promises bash 4.4).
! grep -rq 'EPOCHSECONDS' "$KITROOT/bin" "$KITROOT/lib" &&
	ok "no EPOCHSECONDS in bin/ or lib/ (bash 4.4)" || bad "EPOCHSECONDS still used" "$(grep -rn EPOCHSECONDS "$KITROOT/bin" "$KITROOT/lib")"

# v0.61 (f): a non-integer [stamp] slow_after is a manifest error.
printf '%s[stamp]\nslow_after = "soon"\n' "$GOOD_MANIFEST" >"$TMP/slow-bad.toml"
expect "manifest: a non-integer [stamp] slow_after is refused" 2 'slow_after must be an integer' -- -C "$W" --manifest "$TMP/slow-bad.toml" status
printf '%s[stamp]\nslow_after = 45\n' "$GOOD_MANIFEST" >"$TMP/slow-ok.toml"
expect "manifest: an integer [stamp] slow_after is accepted" 0 '.' -- -C "$W" --manifest "$TMP/slow-ok.toml" status

# v0.61 (g): po team without [layout] owner_column is refused, not every agent free.
sed '/^owner_column/d' "$TM/po.toml" >"$TMP/team-noowner.toml"
expect "team without owner_column is refused (exit 2)" 2 'needs \[layout\] owner_column' -- -C "$TM" --manifest "$TMP/team-noowner.toml" team

# v0.61 (g): po dispatch still plans for a manifest without owner_column (the refusal is po team's alone).
sed '/^owner_column/d' "$DP/po.toml" >"$TMP/dispatch-noowner.toml"
out=$("$PO" -C "$DP" --manifest "$TMP/dispatch-noowner.toml" dispatch --plan 2>&1); code=$?
[[ $code == 0 && $out == *'assign '* ]] &&
	ok "dispatch --plan works for a manifest without owner_column" || bad "dispatch --plan without owner_column (exit $code)" "$out"

# v0.61 (h): po ready checks needs_note on main, and refuses .. and absolute paths.
echo note >"$R2/docs/untracked-note.md"
for nn in docs/untracked-note.md ../outside.md /etc/passwd; do
	printf '{"item":"v1.0.5","title":"Fifth","needs_note":"%s"}\n' "$nn" >"$R2/ready.jsonl"
	out=$(cd "$R2" && "$PO" ready --explain 2>&1)
	[[ $out != *'v1.0.5  Fifth'* && $out == *needs_note* ]] &&
		ok "ready: needs_note '$nn' (not a file on main, or outside the repo) excludes the item" || bad "ready: needs_note $nn" "$out"
done
printf '{"item":"v1.0.5","title":"Fifth","needs_note":"docs/backlog/v1.md"}\n' >"$R2/ready.jsonl"
out=$(cd "$R2" && "$PO" ready 2>&1)
[[ $out == *'v1.0.5  Fifth'* ]] &&
	ok "ready: needs_note that is a file on main keeps the item" || bad "ready: needs_note on main" "$out"

# v0.80: AGENTS.md states the release rule (a pre-release review never holds release N; fixes ship as N.1).
agents_md="$KITROOT/AGENTS.md"
grep -q '^## Releases and the pre-release review' "$agents_md" && grep -q 'release-N\.1' "$agents_md" &&
	grep -q 'never holds release N' "$agents_md" &&
	ok "AGENTS.md has the 'Releases and the pre-release review' section and release-N.1" || bad "AGENTS.md release rule section"

# ---- po released (v0.83) ---------------------------------------------------
RL=$TMP/relrepo
[[ -n ${TMP:?} && -d $TMP && $TMP != "$KITROOT"* ]] || { printf 'released tests: TMP is not a scratch dir: %s\n' "$TMP" >&2; exit 2; }
git init -q -b main "${RL:?}"
[[ $(git -C "$RL" rev-parse --show-toplevel 2>/dev/null) == "$RL" ]] || { printf 'released tests: RL is not its own repo: %s\n' "$RL" >&2; exit 2; }
git -C "$RL" config user.name t
git -C "$RL" config user.email t@example.invalid
mkdir -p "$RL/docs/backlog"
cat >"$RL/docs/BACKLOG.md" <<'EOF'
# Backlog

| Item | Title | Status | Spec |
|---|---|---|---|
| v0.1 | One | DONE | backlog/v0.md |
| v0.2 | Two | DONE | backlog/v0.md |
| v0.3 | Three | DONE (no change needed: x) | backlog/v0.md |
| v0.4 | Four | TODO | backlog/v0.md |
EOF
printf '%s' "$GOOD_MANIFEST" >"$RL/po.toml"
printf '## v0.4 — Four — TODO\n' >"$RL/docs/backlog/v0.md"
git -C "$RL" add -A && git -C "$RL" commit -qm one && git -C "$RL" tag v0.1 && git -C "$RL" tag release-10
git -C "$RL" commit -q --allow-empty -m two && git -C "$RL" tag v0.2 && git -C "$RL" tag release-2 && git -C "$RL" tag v0.4
rel_m() { printf '%s\n[release]\n%s\n' "$GOOD_MANIFEST" "$1" >"$TMP/rel.toml"; }
rel() { "$PO" -C "$RL" --manifest "$TMP/rel.toml" released "$@"; }
rel_m 'source = "tag"'
out=$(rel --json 2>&1)
[[ $out == '{"source":"tag","release":"release-10","released":["0.1","0.3"]}' ]] &&
	ok "released: source tag takes the newest release tag by version order and lists only its ancestors" || bad "released tag newest" "$out"
out=$(rel 2>&1)
[[ $out == $'release: release-10\n0.1\n0.3' ]] && ok "released: plain output names the release, then one version per line" || bad "released plain" "$out"
git -C "$RL" tag release-11
out=$(rel --json 2>&1)
[[ $out == '{"source":"tag","release":"release-11","released":["0.1","0.2","0.3"]}' ]] &&
	ok "released: a DONE item whose tag is an ancestor is released; an untagged DONE row last touched before the release is too (v0.134); a TODO row is not" || bad "released ancestor" "$out"
git -C "$RL" tag -d release-11 >/dev/null
expect "released: --release is refused for source tag" 1 'source "github" only' -- -C "$RL" --manifest "$TMP/rel.toml" released --release release-2
rel_m $'source = "tag"\npattern = "nothing-*"'
out=$(rel --json 2>&1)
[[ $out == '{"source":"tag","release":null,"released":[]}' ]] && ok "released: no tag matching the pattern is release null" || bad "released no match" "$out"
rel_m 'source = "none"'
out=$(rel --json 2>&1)
[[ $out == '{"source":"none","release":null,"released":[]}' ]] && ok "released: source none has no release and nothing released" || bad "released none" "$out"
expect "released: --release is refused for source none" 1 'source "github" only' -- -C "$RL" --manifest "$TMP/rel.toml" released --release release-2
printf '%s' "$GOOD_MANIFEST" >"$TMP/rel.toml"
out=$(rel --json 2>&1)
[[ $out == '{"source":"none","release":null,"released":[]}' ]] && ok "released: no [release] section means source none" || bad "released default" "$out"
rel_m 'source = "github"'
out=$(rel --json --release release-2 2>&1)
[[ $out == '{"source":"github","release":"release-2","released":["0.1","0.2","0.3"]}' ]] &&
	ok "released: source github takes the tag the producer gives and checks ancestry" || bad "released github" "$out"
out=$(rel --json 2>&1)
[[ $out == '{"source":"github","release":null,"released":[]}' ]] && ok "released: source github without --release is release null" || bad "released github none" "$out"
expect "released: source github with a tag not in the repository is exit 2" 2 "release tag 'v9.9' is not in this repository" -- -C "$RL" --manifest "$TMP/rel.toml" released --release v9.9
rel_m 'source = "tags"'
expect "released: a [release] source other than tag, github or none is a manifest error" 2 'source must be "tag", "github" or "none"' -- -C "$RL" --manifest "$TMP/rel.toml" released
rel_m $'source = "github"\npattern = "release-*"'
expect "released: [release] pattern without source tag is a manifest error" 2 'pattern applies to source "tag" only' -- -C "$RL" --manifest "$TMP/rel.toml" released

# v0.99: one DONE rule (first word, upper-cased, trailing punctuation stripped)
printf '| v0.5 | Five | DONE: shipped | backlog/v0.md |\n| v0.6 | Six | done | backlog/v0.md |\n| v0.7 | Seven | DONE (tag x) | backlog/v0.md |\n' >>"$RL/docs/BACKLOG.md"
git -C "$RL" commit -qam five && for _v in v0.5 v0.6 v0.7; do git -C "$RL" tag "$_v"; done && git -C "$RL" tag release-99
rel_m 'source = "github"'
out=$(rel --json --release release-99 2>&1)
[[ $out == '{"source":"github","release":"release-99","released":["0.1","0.2","0.3","0.5","0.6","0.7"]}' ]] &&
	ok "released: rows 'DONE:' and 'done' count as DONE, and 'DONE (tag x)' still does" || bad "released DONE words" "$out"

# ---- po released: untagged DONE rows by their DONE commit (v0.134) ----------
UR=$TMP/relrepo-untagged
git init -q -b main "${UR:?}"
git -C "$UR" config user.name t
git -C "$UR" config user.email t@example.invalid
mkdir -p "$UR/docs/backlog"
printf '## v0.1 — One — TODO\n' >"$UR/docs/backlog/v0.md"
printf '%s' "$GOOD_MANIFEST" >"$UR/po.toml"
ur_rows() { printf '# Backlog\n\n| Item | Title | Status | Spec |\n|---|---|---|---|\n%s\n' "$1" >"$UR/docs/BACKLOG.md"; }
ur() { git -C "$UR" "$@"; }
urel() { "$PO" -C "$UR" --manifest "$TMP/rel.toml" released "$@"; }
rel_m 'source = "tag"'
# T1 tagged and merged; T2 tagged on a side branch the release lacks;
# 1.9.3 untagged with an admin commit before the release; 2.0 untagged with no
# admin commit, row last touched before the release.
ur_rows $'| v1.0 | T1 | TODO | backlog/v0.md |\n| v1.9.3 | Pre | TODO | backlog/v0.md |\n| v1.9.30 | Pre30 | TODO | backlog/v0.md |\n| v2.0 | R1 | TODO | backlog/v0.md |\n| v3.0 | N | TODO | backlog/v0.md |'
ur add -A && ur commit -qm base
ur_rows $'| v1.0 | T1 | DONE | backlog/v0.md |\n| v1.9.3 | Pre | DONE | backlog/v0.md |\n| v1.9.30 | Pre30 | TODO | backlog/v0.md |\n| v2.0 | R1 | DONE | backlog/v0.md |\n| v3.0 | N | TODO | backlog/v0.md |'
ur commit -qam 'rows done'
ur tag v1.0
ur commit -q --allow-empty -m 'admin: v1.9.3 DONE'
ur checkout -q -b side
ur_rows $'| v1.0 | T1 | DONE | backlog/v0.md |\n| v1.9.3 | Pre | DONE | backlog/v0.md |\n| v1.9.30 | Pre30 | TODO | backlog/v0.md |\n| v2.0 | R1 | DONE | backlog/v0.md |\n| v3.0 | N | TODO | backlog/v0.md |\n| v4.0 | T2 | DONE | backlog/v0.md |'
ur commit -qam 'side work'
ur tag v4.0
ur checkout -q main
ur tag release-1
out=$(urel --json 2>&1)
[[ $out == '{"source":"tag","release":"release-1","released":["1.0","1.9.3","2.0"]}' ]] &&
	ok "released: tagged and merged is released; an untagged row with an admin: DONE commit, or last touched, before the release is released; 1.9.30 (still TODO) is not matched by the 1.9.3 commit" ||
	bad "released untagged before" "$out"
ur_rows $'| v1.0 | T1 | DONE | backlog/v0.md |\n| v1.9.3 | Pre | DONE | backlog/v0.md |\n| v1.9.30 | Pre30 | DONE | backlog/v0.md |\n| v2.0 | R1 | DONE | backlog/v0.md |\n| v3.0 | N | DONE | backlog/v0.md |\n| v4.0 | T2 | DONE | backlog/v0.md |'
ur commit -qam 'rows after'
ur commit -q --allow-empty -m 'admin: 1.9.30 DONE'
out=$(urel --json 2>&1)
[[ $out == '{"source":"tag","release":"release-1","released":["1.0","1.9.3","2.0"]}' ]] &&
	ok "released: untagged DONE rows whose DONE commit or last edit comes after the release are not released; a tag not under the release is not released and the DONE commit is not tried" ||
	bad "released untagged after" "$out"
ur tag release-2
out=$(urel --json 2>&1)
[[ $out == '{"source":"tag","release":"release-2","released":["1.0","1.9.3","1.9.30","2.0","3.0"]}' ]] &&
	ok "released: the next release takes them; 1.9.3 and 1.9.30 match exactly; --json keeps source, release, released" ||
	bad "released untagged next" "$out"
ur_rows $'| v1.0 | T1 | DONE | backlog/v0.md |\n| v7.0 | Absent | TODO | backlog/v0.md |'
ur commit -qam 'rows reduced'
out=$(urel 2>&1)
[[ $out == $'release: release-2\n1.0' ]] && ok "released: a non-DONE row is never listed, and a DONE row that is gone from the backlog is not listed" || bad "released non-done" "$out"

# ---- po released: an untagged heading item in specs_dir by its heading's last change (v0.140) ----
HR=$TMP/relrepo-headings
git init -q -b main "${HR:?}"
git -C "$HR" config user.name t
git -C "$HR" config user.email t@example.invalid
mkdir -p "$HR/docs/backlog"
printf '%s' "$GOOD_MANIFEST" >"$HR/po.toml"
printf '# Backlog\n\n| Item | Title | Status | Spec |\n|---|---|---|---|\n| v0.9 | Row | TODO | backlog/v5.md |\n' >"$HR/docs/BACKLOG.md"
hr() { git -C "$HR" "$@"; }
hrel() { "$PO" -C "$HR" --manifest "$TMP/rel.toml" released "$@"; }
printf '## v5.0 — Five — TODO\n\n## v5.1 — FiveOne — TODO\n\n## v5.10 — FiveTen — TODO\n' >"$HR/docs/backlog/v5.md"
hr add -A && hr commit -qm base
printf '## v5.0 — Five — DONE (spike)\n\n## v5.1 — FiveOne — TODO\n\n## v5.10 — FiveTen — DONE\n' >"$HR/docs/backlog/v5.md"
hr commit -qam 'admin: v5.0 Five DONE (old subject form, title before DONE)'
hr tag release-1
printf '## v5.0 — Five — DONE (spike)\n\n## v5.1 — FiveOne — DONE\n\n## v5.10 — FiveTen — DONE\n' >"$HR/docs/backlog/v5.md"
hr commit -qam 'backlog: v5.1 closed'
out=$(hrel --json 2>&1)
[[ $out == '{"source":"tag","release":"release-1","released":["5.0","5.10"]}' ]] &&
	ok "released: an untagged DONE heading in specs_dir with no admin: <v> DONE commit is judged by its heading's last change; 5.1 done after the release is not released and does not match 5.10" ||
	bad "released headings" "$out"

# ---- po released: one git scan, a bounded number of git calls (v0.152) ------
# 13 DONE items: v1.1-v1.3 tagged under the release (v1.1 annotated), v1.4
# tagged after it, v1.5 tagged on a side branch (its admin commit before the
# release is not tried); v2.1, v2.2 (subject and row with text after DONE) and
# v2.4 (bare `admin: 2.4 DONE`) have admin commits before the release, v2.3
# after it, v2.6 a bare one before and a `v` one after (the `v` form wins);
# v3.1 and the heading v3.3 were last touched before the release, v3.2 after.
# The expected list is the unchanged code's answer on this repo (v0.151).
SR=$TMP/relrepo-scan
git init -q -b main "${SR:?}"
[[ $(git -C "$SR" rev-parse --show-toplevel 2>/dev/null) == "$SR" ]] || { printf 'released scan tests: SR is not its own repo: %s\n' "$SR" >&2; exit 2; }
sr() { git -C "$SR" "$@"; }
sr config user.name t
sr config user.email t@example.invalid
mkdir -p "$SR/docs/backlog"
printf '%s' "$GOOD_MANIFEST" >"$SR/po.toml"
sr_rows() {
	local v st
	{
		printf '# Backlog\n\n| Item | Title | Status | Spec |\n|---|---|---|---|\n'
		for v in 1.1 1.2 1.3 1.4 1.5 2.1 2.2 2.3 2.4 2.6 3.1 3.2 9.0 "$@"; do
			st=TODO
			[[ " $SR_DONE " == *" $v "* ]] && st=DONE
			[[ $v == 2.2 && $st == DONE ]] && st='DONE (no change needed: dup)'
			printf '| v%s | Item %s | %s | backlog/v3.md |\n' "$v" "$v" "$st"
		done
	} >"$SR/docs/BACKLOG.md"
}
SR_DONE=''
sr_rows
printf '## v3.3 — Heading — TODO\n' >"$SR/docs/backlog/v3.md"
sr add -A && sr commit -qm base
SR_DONE='1.1 1.2 1.3 1.5 2.1 2.2 2.4 2.6 3.1'
sr_rows
printf '## v3.3 — Heading — DONE\n' >"$SR/docs/backlog/v3.md"
sr commit -qam 'rows done'
sr tag -a -m one v1.1 && sr tag v1.2 && sr tag v1.3
for _s in 'admin: v1.5 DONE' 'admin: v2.1 DONE' 'admin: v2.2 DONE (tag skipped)' 'admin: 2.4 DONE' 'admin: 2.6 DONE' 'admin: v2.3 DONEX not a done subject'; do
	sr commit -q --allow-empty -m "$_s"
done
sr checkout -q -b side && sr commit -q --allow-empty -m side && sr tag v1.5 && sr checkout -q main
sr tag -a -m rel release-1
SR_DONE="$SR_DONE 1.4 2.3 3.2"
sr_rows
sr commit -qam 'rows after'
sr tag v1.4
sr commit -q --allow-empty -m 'admin: v2.3 DONE'
sr commit -q --allow-empty -m 'admin: v2.6 DONE'
rel_m 'source = "tag"'
srel() { "$PO" -C "$SR" --manifest "$TMP/rel.toml" released "$@"; }
SR_WANT='{"source":"tag","release":"release-1","released":["1.1","1.2","1.3","2.1","2.2","2.4","3.1","3.3"]}'
out=$(srel --json 2>&1)
[[ $out == "$SR_WANT" ]] &&
	ok "v0.152 released: one scan gives the unchanged code's list on 13 DONE items (tagged, side-branch tag, admin before/after, bare and v forms, touched rows, a heading)" ||
	bad "v0.152 released golden" "$out"
[[ $out == *'"2.2"'* ]] && ok "v0.152 released: a DONE row with text after DONE is still read" || bad "v0.152 released DONE text" "$out"
[[ $out != *'"2.3"'* && $out != *'"2.6"'* ]] &&
	ok "v0.152 released: an untagged item whose DONE commit is after the release is not released" || bad "v0.152 released DONE after" "$out"
# A counting git on PATH: the calls after the backlog load (its last call is
# `cat-file --batch`) are the scan's own, at most 6, and ten more DONE items
# add none.
GW=$TMP/gitcount
mkdir -p "$GW"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/calls"\nexec %s "$@"\n' "$GW" "$(command -v git)" >"$GW/git"
chmod +x "$GW/git"
: >"$GW/calls"
out=$(PATH=$GW:$PATH srel --json 2>&1)
n_all=$(wc -l <"$GW/calls")
n_scan=$(sed -n '/^cat-file --batch$/,$p' "$GW/calls" | sed 1d | wc -l)
[[ $out == "$SR_WANT" && $(grep -c '^cat-file --batch$' "$GW/calls") == 1 && $n_scan -le 6 ]] &&
	ok "v0.152 released: the scan makes at most 6 git calls ($n_scan after the backlog load, $n_all in all)" ||
	bad "v0.152 released git calls" "scan=$n_scan all=$n_all out=$out $(cat "$GW/calls")"
SR_DONE="$SR_DONE 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10"
sr_rows 4.1 4.2 4.3 4.4 4.5 4.6 4.7 4.8 4.9 4.10
sr commit -qam 'ten more'
for _v in 4.1 4.2 4.3 4.4 4.5; do sr commit -q --allow-empty -m "admin: v$_v DONE"; done
: >"$GW/calls"
out=$(PATH=$GW:$PATH srel --json 2>&1)
[[ $out == "$SR_WANT" && $(wc -l <"$GW/calls") == "$n_all" ]] &&
	ok "v0.152 released: ten more DONE items after the release make no more git calls" ||
	bad "v0.152 released git calls grow" "was $n_all, now $(wc -l <"$GW/calls") out=$out"

# po status without python3 fails clearly and leaves no temp dir (v0.99)
NOPY=$TMP/nopy-bin
NOPYTMP=$TMP/nopy-tmp
mkdir -p "$NOPY" "$NOPYTMP"
for _c in bash git sh env dirname basename cat grep sed awk sort tr head tail mktemp rm mkdir date wc cut tee uniq printf readlink ls cp mv sleep id uname find xargs; do
	_p=$(command -v "$_c" 2>/dev/null) && [[ $_p == /* ]] && ln -sf "$_p" "$NOPY/$_c"
done
out=$(PATH=$NOPY TMPDIR=$NOPYTMP "$BASH" "$PO" -C "$RL" --manifest "$TMP/rel.toml" status 2>&1)
rc=$?
[[ $rc -ne 0 && $out == *python3* && $(printf '%s\n' "$out" | wc -l) -eq 1 && -z $(ls -A "$NOPYTMP") ]] &&
	ok "status: no python3 on PATH is a one-line error naming python3 and leaves no temp dir" || bad "status no python3" "rc=$rc out=$out left=$(ls -A "$NOPYTMP")"

# ---- po lint-founding (item AU) ---------------------------------------------
LF=$TMP/lintf
mkdir -p "$LF/docs/specs"
git init -q -b main "$LF"
git -C "$LF" config user.name t
git -C "$LF" config user.email t@example.invalid
cat >"$LF/po.toml" <<'TOML'
[versioning]
tag = "v{version}"

[layout]
backlog = "docs/BACKLOG.md"
specs_dir = "docs/specs"
worktrees = ".wt"
branch = "item-v{version}"

[project]
name = "lf"

[ready]
file = "ready.jsonl"

[[team.agent]]
name = "ada"

[[team.agent]]
name = "bo"
TOML
lf_clean() {
	cat >"$LF/docs/BACKLOG.md" <<'MD'
# Backlog

| Item | Title | Status |
|---|---|---|
| v1.1 | One | DONE |
| v1.2 | Two | TODO |
| v1.3 | Three | TODO |
| v1.4 | Four | HELD |
MD
	cat >"$LF/docs/specs/v1.md" <<'MD'
## v1.1 — One — DONE
Old.
## v1.2 — Two — TODO
Spec two.
## v1.3 — Three — TODO
Spec three.
## v1.4 — Four — HELD
Spec four.
MD
	cat >"$LF/ready.jsonl" <<'JL'
{"item":"v1.1","title":"One","agents":["ada"]}
{"item":"v1.2","title":"Two","agents":["ada","bo"]}
{"item":"v1.3","title":"Three"}
{"item":"v1.2","title":"Two, corrected","agents":["bo"]}
{"project":"other","item":"v9.9","agents":["nobody"]}
JL
	git -C "$LF" add -A
	git -C "$LF" commit -qm "lf state"
}
lf_clean
echo ready.jsonl >"$LF/.gitignore"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 0 && -z $out ]] &&
	ok "lint-founding: a clean backlog, specs and ready file print nothing and exit 0 (a corrected line, DONE history and another project's line are fine)" ||
	bad "lint-founding clean (exit $code)" "$out"

# 1. missing status
sed -i 's/^| v1.3 | Three | TODO |$/| v1.3 | Three |  |/; s/^## v1.2 — Two — TODO$/## v1.2 — Two/' "$LF/docs/BACKLOG.md" "$LF/docs/specs/v1.md"
git -C "$LF" commit -qam "break statuses"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 1 && $out == *'docs/BACKLOG.md:7: v1.3: status '"''"' is missing'* && $out == *'docs/specs/v1.md:3: v1.2: heading has no status segment'* &&
	$(wc -l <<<"$out") == 2 ]] &&
	ok "lint-founding: a row with no status and a heading with no status are one finding each, with file:line" ||
	bad "lint-founding missing status (exit $code)" "$out"
git -C "$LF" reset -q --hard HEAD~1

# 2. missing spec
sed -i '/^## v1.3 — Three — TODO$/,/^Spec three.$/d' "$LF/docs/specs/v1.md"
git -C "$LF" commit -qam "drop spec three"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 1 && $out == 'docs/BACKLOG.md:7: v1.3 (TODO) has no spec section under docs/specs' ]] &&
	ok "lint-founding: an open item with no spec section is a finding; a DONE one would not be" || bad "lint-founding missing spec (exit $code)" "$out"
git -C "$LF" reset -q --hard HEAD~1

# v0.150: the status is the cell's or segment's first word, as for po's other readers.
sed -i 's/^| v1.1 | One | DONE |$/| v1.1 | One | DONE (no change needed: x) |/; s/^## v1.1 — One — DONE$/## v1.1 — One — DONE (note)/' "$LF/docs/BACKLOG.md" "$LF/docs/specs/v1.md"
git -C "$LF" commit -qam "statuses with notes"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 0 && -z $out ]] &&
	ok "lint-founding: a status cell 'DONE (no change needed: x)' and a heading segment 'DONE (note)' are clean" ||
	bad "lint-founding status with a note (exit $code)" "$out"
git -C "$LF" reset -q --hard HEAD~1
sed -i 's/^| v1.3 | Three | TODO |$/| v1.3 | Three | DOING (waiting) |/; /^## v1.3 — Three — TODO$/,/^Spec three.$/d' "$LF/docs/BACKLOG.md" "$LF/docs/specs/v1.md"
git -C "$LF" commit -qam "doing with a note, no spec"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 1 && $out == 'docs/BACKLOG.md:7: v1.3 (DOING) has no spec section under docs/specs' ]] &&
	ok "lint-founding: 'DOING (waiting)' is DOING: with no spec heading it is an open item without a spec" ||
	bad "lint-founding DOING with a note (exit $code)" "$out"
git -C "$LF" reset -q --hard HEAD~1
sed -i 's/^| v1.1 | One | DONE |$/| v1.1 | One | done |/' "$LF/docs/BACKLOG.md"
git -C "$LF" commit -qam "lowercase status"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 1 && $out == "docs/BACKLOG.md:5: v1.1: status 'done' is missing or not one ALL-CAPS word" ]] &&
	ok "lint-founding: a lowercase status 'done' is still a finding with today's message" || bad "lint-founding lowercase status (exit $code)" "$out"
git -C "$LF" reset -q --hard HEAD~1
sed -i 's/^| v1.1 | One | DONE |$/| v1.1 | One | (DONE) later |/' "$LF/docs/BACKLOG.md"
git -C "$LF" commit -qam "no leading caps word"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 1 && $out == "docs/BACKLOG.md:5: v1.1: status '(DONE) later' is missing or not one ALL-CAPS word" ]] &&
	ok "lint-founding: a cell whose first word is not ALL-CAPS is still a finding" || bad "lint-founding no leading caps word (exit $code)" "$out"
git -C "$LF" reset -q --hard HEAD~1
sed -i 's/^## v1.2 — Two — TODO$/## v1.2 — Two — TODO — DONE (note)/' "$LF/docs/specs/v1.md"
git -C "$LF" commit -qam "two status segments"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 1 && $out == 'docs/specs/v1.md:3: v1.2: heading has two status-like segments' ]] &&
	ok "lint-founding: a heading with two ALL-CAPS segments (one with a note) is still two status-like segments" ||
	bad "lint-founding two segments (exit $code)" "$out"
git -C "$LF" reset -q --hard HEAD~1

# 3. ready-file lines
git -C "$LF" status --short >/dev/null
cat >"$LF/ready.jsonl" <<'JL'
{"item":"v1.2","title":"Two","agents":["ada","zed"]}
{"item":"v1.4","title":"Four","agents":["ada"]}
{"item":"v1.3","title":"Three","agents":["bo"]}
{"item":"v1.3","title":"Three","agents":["bo"]}
{"item":"v8.8","title":"Absent"}
not json
JL
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 1 && $out == *"ready.jsonl:1: v1.2: unknown agent 'zed'"* && $out == *'ready.jsonl:2: v1.4 is HELD, not TODO'* &&
	$out == *'ready.jsonl:4: duplicate of line 3'* && $out == *'ready.jsonl:5: v8.8 is not in the backlog'* &&
	$out == *'ready.jsonl:6: not valid JSON'* && $(wc -l <<<"$out") == 5 ]] &&
	ok "lint-founding: an unknown agent, a HELD entry, a duplicate line, an absent item and bad JSON are one finding each" ||
	bad "lint-founding ready findings (exit $code)" "$out"
out=$("$PO" -C "$LF" lint-founding --ready "$LF/none.jsonl" 2>&1); code=$?
[[ $code == 1 && $out == *'cannot read the ready file'* ]] &&
	ok "lint-founding: an unreadable ready file is a finding" || bad "lint-founding unreadable ready (exit $code)" "$out"
out=$("$PO" -C "$LF" lint-founding --agents zed 2>&1)
[[ $out != *'unknown agent'* ]] &&
	ok "lint-founding: --agents adds known names" || bad "lint-founding --agents" "$out"
sed -i '/^\[ready\]/,/^$/d; /^\[\[team/,$d' "$LF/po.toml"
out=$("$PO" -C "$LF" lint-founding 2>&1); code=$?
[[ $code == 0 && -z $out ]] &&
	ok "lint-founding: with no ready file configured only the backlog is checked" || bad "lint-founding no ready file (exit $code)" "$out"
LF_BEFORE=$(git -C "$LF" rev-parse HEAD)
"$PO" -C "$LF" lint-founding >/dev/null 2>&1
[[ $(git -C "$LF" rev-parse HEAD) == "$LF_BEFORE" ]] &&
	ok "lint-founding writes nothing" || bad "lint-founding wrote"
expect "lint-founding: an unknown argument is a usage error" 1 'unknown argument' -- -C "$LF" lint-founding --nope

# ---- row split (v0.160): one rule for a pipe in a table cell ------------------
# Three splitters read a table row: po_split_row (lib/po/backlog.sh), split_row
# (lib/po/setup.py) and cells() (the python in lib/po/lint.sh). Each fixture row
# goes through all three; every one must give the expected cells.
RS=$TMP/rowsplit
mkdir -p "$RS"
US=$'\x1f'
# shellcheck disable=SC2016 # the backticks are fixture text
{
	printf '%s\t%s\n' '| a | b | c |' "a${US}b${US}c"
	printf '%s\t%s\n' '   | a | b |' "a${US}b"
	printf '%s\t%s\n' '| a | `x|y` | c |' "a${US}\`x|y\`${US}c"
	printf '%s\t%s\n' '| a | x\|y | c |' "a${US}x|y${US}c"
	printf '%s\t%s\n' '| `a|b` | `c` | d |' "\`a|b\`${US}\`c\`${US}d"
	printf '%s\t%s\n' '| a | `b | c |' "a${US}\`b${US}c"
	printf '%s\t%s\n' '| a | b\|' "a${US}b|"
	printf '%s\t%s\n' '| a |  | c |' "a${US}${US}c"
	printf '%s\t%s\n' '| `a|b` | `c|d` | e | f | `g|h` |' "\`a|b\`${US}\`c|d\`${US}e${US}f${US}\`g|h\`"
} >"$RS/fixtures.tsv"
rs_bash() { # the bash splitter, one line per row
	(
		set +u
		# shellcheck source=/dev/null
		source "$KITROOT/lib/po/backlog.sh"
		while IFS=$'\t' read -r row _; do
			po_split_row "$(po_trim "$row")"
			(
				IFS=$US
				printf '%s\n' "${PO_CELLS[*]}"
			)
		done <"$RS/fixtures.tsv"
	)
}
rs_python() { # setup.py's split_row, then lint.sh's cells() cut out of its source
	# helper
	python3 -B -I - "$KITROOT" "$RS/fixtures.tsv" "$1" <<'PY'
import sys, importlib.util
kit, fx, which = sys.argv[1:4]
if which == "setup":
    spec = importlib.util.spec_from_file_location("po_setup", kit + "/lib/po/setup.py")
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    f = m.split_row
else:
    src = open(kit + "/lib/po/lint.sh").read()
    a = src.index("BT = chr(96)")
    b = src.index("def decorated")
    ns = {}
    exec(src[a:b], ns)
    f = ns["cells"]
for line in open(fx).read().split("\n"):
    if line:
        print("\x1f".join(f(line.split("\t")[0])))
PY
}
rs_check() {
	local name=$1 got=$2 want
	want=$(cut -f2 "$RS/fixtures.tsv")
	if [[ $got == "$want" ]]; then
		ok "row split: $name agrees with the expected cells on every fixture row"
	else
		bad "row split: $name differs from the expected cells" "$(diff <(printf '%s\n' "$want" | tr "$US" '#') <(printf '%s\n' "$got" | tr "$US" '#'))"
	fi
}
rs_check "po_split_row (backlog.sh)" "$(rs_bash 2>&1)"
rs_check "split_row (setup.py)" "$(rs_python setup 2>&1)"
rs_check "cells() (lint.sh)" "$(rs_python lint 2>&1)"

# End to end: a backlog row with a backtick pipe and a backslash-pipe.
RE=$TMP/rowsplit-e2e
mkdir -p "$RE/docs"
git init -q -b main "$RE"
git -C "$RE" config user.name t
git -C "$RE" config user.email t@example.invalid
cat >"$RE/po.toml" <<'TOML'
[versioning]
tag = "v{version}"

[layout]
backlog = "docs/BACKLOG.md"
specs_dir = "."
worktrees = ".wt"
branch = "item-v{version}"

[project]
name = "rs"
TOML
cat >"$RE/docs/BACKLOG.md" <<'MD'
# Backlog

| Item | Title | Content | Status |
|---|---|---|---|
| v1.1 | One | DONE row | DONE |
| v1.2 | Two | uses `a|b` and x\|y here | DOING |
MD
git -C "$RE" add -A
git -C "$RE" commit -q -m init
RS_OUT=$("$PO" -C "$RE" status 2>&1)
RS_CODE=$?
if ((RS_CODE == 0)) && grep -q 'v1.2' <<<"$RS_OUT"; then
	ok "row split: po status exits 0 on a row holding a backtick pipe and a backslash-pipe and lists the item"
else
	bad "row split: po status on a row with pipes in a cell (exit $RS_CODE)" "$RS_OUT"
fi
if RS_LINT=$("$PO" -C "$RE" lint-founding 2>&1) && [[ -z $RS_LINT ]]; then
	ok "row split: po lint-founding is clean on the same backlog"
else
	bad "row split: po lint-founding on the same backlog" "$RS_LINT"
fi
RS_BAD=$(sed 's/| DOING |/| x | DOING |/' "$RE/docs/BACKLOG.md" >"$RE/b2" && mv "$RE/b2" "$RE/docs/BACKLOG.md" && git -C "$RE" commit -qam bad && "$PO" -C "$RE" status 2>&1)
if grep -q 'not a separator' <<<"$RS_BAD" && grep -q 'not a separator' <<<"$("$PO" -C "$RE" lint-founding 2>&1)"; then
	ok "row split: a row with the wrong cell count says why in po status and po lint-founding"
else
	bad "row split: the wrong-count message lacks the pipe sentence" "$RS_BAD"
fi

# ---- backlog load (v0.161): no subshell per heading or cell ------------------
# The golden dumps and die messages below were written against the loader as it
# was before v0.161 (memory 20261031-050608-0864): the parse must not change.
BL=$TMP/bl
bl_repo() { # <dir>: a backlog with tables (owner column, odd shapes) and heading specs
	local d=$1
	rm -rf "$d"
	git init -q -b main "$d"
	git -C "$d" config user.name t
	git -C "$d" config user.email t@example.invalid
	mkdir -p "$d/docs/backlog"
	printf '[versioning]\ntag = "v{version}"\n\n[layout]\nbacklog = "docs/BACKLOG.md"\nspecs_dir = "docs/backlog"\nworktrees = ".wt"\nbranch = "item-v{version}"\nowner_column = "Owner"\n\n[project]\nname = "bl"\n' >"$d/po.toml"
	# shellcheck disable=SC2016 # the backticks are fixture text
	printf '%s\n' '# Backlog' '' 'Intro line.' \
		'  | Item | Title | Owner | Status |  ' '|---|---|---|---|' \
		'| v1.1 | One | ann | DONE |' '| v1.2 |  | bob | DOING |' '| note | not an item | x | TODO |' \
		'| v1.1 | One again | carl | DONE |' '| `v1.3` | Coded | dee | TODO |' \
		'| v1.4 | Pipe `a|b` and x\|y | eve | PAUSED |' '| v1.7 | Seven |  | DONE (no change) |' '' \
		'| Status | Item |' '|---|---|' '| BLOCKED | v1.5 |' '' \
		'| Item | Title |' '|---|---|' '| v9.9 | no status column |' 'Para' \
		'| Item | Status | Title |' '|:-|:-:|-:|' '| v1.6 | TODO | after status |' >"$d/docs/BACKLOG.md"
	printf '%s\n' '# Specs a' '## v2.1 — Heading one — DONE' 'text' '## v2.2 — Two — parts — DOING extra words' \
		'### v2.5 — sub heading ignored — DOING' '## Not an item' '## v2.3 — T — NOTE — later' >"$d/docs/backlog/a.md"
	printf '%s\n' '## v2.4 — T — wait — PAUSED — x' $'## v2.6 — Tab\there — TODO' '## v2.10 — Ten — DONE' >"$d/docs/backlog/b.md"
	printf '%s\n' '## v8.8 — not markdown — DOING' >"$d/docs/backlog/c.txt"
	git -C "$d" add -A
	git -C "$d" commit -qm init
}
bl_dump() { # <dir>: PO_ITEMS then PO_OWNERS (sorted) after the load, tabs shown as ">"
	(
		set +u
		cd "$1" || exit 1
		# shellcheck source=/dev/null
		source "$KITROOT/lib/po/manifest.sh"
		# shellcheck source=/dev/null
		source "$KITROOT/lib/po/backlog.sh"
		po_manifest_load "$1/po.toml"
		po_backlog_load
		printf 'I %s\n' "${PO_ITEMS[@]}"
		for k in "${!PO_OWNERS[@]}"; do printf 'O %s=%s\n' "$k" "${PO_OWNERS[$k]}"; done | LC_ALL=C sort
	) 2>&1 | tr '\t' '>'
}
bl_repo "$BL"
# shellcheck disable=SC2016 # the backticks are fixture text
BL_WANT='I 1.1>DONE>One>docs/BACKLOG.md:6
I 1.2>DOING>>docs/BACKLOG.md:7
I 1.1>DONE>One again>docs/BACKLOG.md:9
I 1.4>PAUSED>Pipe `a|b` and x|y>docs/BACKLOG.md:11
I 1.7>DONE (no change)>Seven>docs/BACKLOG.md:12
I 1.5>BLOCKED>>docs/BACKLOG.md:16
I 1.6>TODO>>docs/BACKLOG.md:24
I 2.1>DONE>Heading one>docs/backlog/a.md:2
I 2.2>DOING>Two — parts>docs/backlog/a.md:4
I 2.3>NOTE>T>docs/backlog/a.md:7
I 2.4>PAUSED>T — wait>docs/backlog/b.md:1
I 2.6>TODO>Tab	here>docs/backlog/b.md:2
I 2.10>DONE>Ten>docs/backlog/b.md:3
O 1.1=ann
O 1.2=bob
O 1.4=eve
O 1.7='
BL_WANT=${BL_WANT//	/>}
BL_GOT=$(bl_dump "$BL")
[[ $BL_GOT == "$BL_WANT" ]] &&
	ok "v0.161 backlog load: PO_ITEMS and PO_OWNERS match the unchanged loader's golden (tables, owner column, odd rows, headings)" ||
	bad "v0.161 backlog load golden" "$(diff <(printf '%s\n' "$BL_WANT") <(printf '%s\n' "$BL_GOT"))"

# Each die of the loader, word for word: <file> <line to append> <message>.
bl_die() {
	local file=$1 add=$2 want=$3 got
	bl_repo "$BL"
	if [[ $file == - ]]; then
		git -C "$BL" rm -rq "$add" && git -C "$BL" commit -qm gone
	else
		printf '%s\n' "$add" >>"$BL/$file" && git -C "$BL" commit -qam case
	fi
	got=$(bl_dump "$BL")
	[[ $got == "po: $want" ]] &&
		ok "v0.161 backlog load: dies with the unchanged message: $want" ||
		bad "v0.161 backlog load die: $want" "got: $got"
}
bl_die docs/BACKLOG.md $'\n| Item | status |' "docs/BACKLOG.md:26: column header 'status' is not written exactly as Status"
bl_die docs/BACKLOG.md $'\n| Status | Item | Status |' "docs/BACKLOG.md:26: two Status columns"
bl_die docs/BACKLOG.md $'\n| Owner | Item | Status | Owner |' "docs/BACKLOG.md:26: two Owner columns"
bl_die docs/BACKLOG.md '| v3.1 | TODO | T | x |' "docs/BACKLOG.md:25: row has 4 cells, header has 3; a pipe inside a code span or written as backslash-pipe is not a separator"
bl_die docs/BACKLOG.md '| v3.1 | **DOING** | T |' "docs/BACKLOG.md:25: status '**DOING**' is not written exactly as DOING"
bl_die docs/BACKLOG.md '| x3.1 | DOING | T |' "docs/BACKLOG.md:25: DOING row has no cell in tag form (v{version})"
bl_die docs/backlog/b.md '## v3x — T — DONE' "docs/backlog/b.md:4: heading id 'v3x' is not in tag form (v{version})"
bl_die docs/backlog/b.md '## v3.1 T DONE' "docs/backlog/b.md:4: heading has no ' — ' after its id"
bl_die docs/backlog/b.md '## v3.1 — T' "docs/backlog/b.md:4: heading has no status segment"
bl_die docs/backlog/b.md '## v3.1 — T — DONE — TODO' "docs/backlog/b.md:4: two status-like segments ('DONE', 'TODO')"
bl_die docs/backlog/b.md '## v3.1 — T — done' "docs/backlog/b.md:4: heading has no ALL-CAPS status segment"
bl_die docs/backlog/b.md '## v3.1 — T — Doing now' "docs/backlog/b.md:4: status 'Doing now' is not written exactly as DOING"
bl_die - docs/BACKLOG.md "backlog 'docs/BACKLOG.md' not found on main"
bl_die - docs/backlog "specs_dir 'docs/backlog' not found on main"

# Forks: 300 more headings add no process. Counted as the PID gap across the
# load inside a fresh PID namespace (unshare), where every fork takes the next
# PID; without unshare, the smallest gap of 5 runs on the host.
bl_repo "$BL"
for _i in $(seq 1 300); do printf '## v5.%s — Item %s — TODO\n' "$_i" "$_i"; done >"$BL/docs/backlog/many.md"
git -C "$BL" add -A && git -C "$BL" commit -qm many
bl_forks() {
	(
		set +u
		cd "$BL" || exit 1
		# shellcheck source=/dev/null
		source "$KITROOT/lib/po/manifest.sh"
		# shellcheck source=/dev/null
		source "$KITROOT/lib/po/backlog.sh"
		po_manifest_load "$BL/po.toml"
		local a b
		a=$(printf '%s' "$BASHPID")
		po_backlog_load
		b=$(printf '%s' "$BASHPID")
		((${#PO_ITEMS[@]} >= 313)) || { printf 'only %s items\n' "${#PO_ITEMS[@]}"; exit 1; }
		printf '%s\n' "$((b - a - 1))"
	)
}
if unshare -rpf --mount-proc true 2>/dev/null; then
	BL_HOW='in a PID namespace'
	# helper
	BL_FORKS=$(KITROOT=$KITROOT BL=$BL unshare -rpf --mount-proc bash -c "$(declare -f bl_forks); bl_forks" 2>&1)
else
	BL_HOW='on the host, least of 5 runs'
	BL_FORKS=$(for _i in 1 2 3 4 5; do bl_forks; done 2>&1 | sort -n | head -1)
fi
[[ $BL_FORKS =~ ^[0-9]+$ ]] && ((BL_FORKS <= 20)) &&
	ok "v0.161 backlog load: 313 items load with $BL_FORKS forks, at most 20 ($BL_HOW)" ||
	bad "v0.161 backlog load forks ($BL_HOW): want at most 20" "$BL_FORKS"

# po_unfill_into gives what po_unfill gives; po_trim_into what po_trim gives.
bl_unfill() {
	(
		set +u
		# shellcheck source=/dev/null
		source "$KITROOT/lib/po/manifest.sh"
		# shellcheck source=/dev/null
		source "$KITROOT/lib/po/backlog.sh"
		local tpl text want a rc_a b rc_b
		while IFS='|' read -r tpl text want; do
			a=$(po_unfill "$tpl" "$text")
			rc_a=$?
			b=keep
			po_unfill_into "$tpl" "$text" b
			rc_b=$?
			((rc_b != 0)) && b=-
			((rc_a != 0)) && a=-
			[[ $a == "$want" && $b == "$want" ]] &&
				printf 'ok\tv0.161 po_unfill_into: %s on %s gives %s, as po_unfill\t\n' "$tpl" "${text:-(empty)}" "$want" ||
				printf 'FAIL\tv0.161 po_unfill_into: %s on %s\twant %s, po_unfill %s, po_unfill_into %s\n' "$tpl" "$text" "$want" "$a" "$b"
		done <<<'v{version}|v1.2.3|1.2.3
v{version}|v1.2|1.2
v{version}|v1|-
v{version}|vX.Y|-
v{version}|v1.x|-
v{version}|x1.2|-
v{version}||-
{version}|1.10|1.10
item-v{version}|item-v0.161|0.161
item-v{version}|v0.161|-
rel-{version}-final|rel-2.0-final|2.0
rel-{version}-final|rel-2.0|-'
		local s t
		for s in '' '  a b  ' $'\t x \t' 'none' '   '; do
			t=keep
			po_trim_into "$s" t
			[[ $t == "$(po_trim "$s")" ]] &&
				printf 'ok\tv0.161 po_trim_into: %q trims as po_trim\t\n' "$s" ||
				printf 'FAIL\tv0.161 po_trim_into: %q\tgot %q\n' "$s" "$t"
		done
		printf 'BLOCK-END bl_unfill\n'
	)
}
block bl_unfill bl_unfill

# ---- the agent switch (v0.173): [team] inactive_file, po team off|on --------
# An agent named in the switch file is OFF: inactive in the feed, never free,
# never given an item by dispatch. po team off|on writes the file in place.
AS=$TMP/agent-switch
mkdir -p "$AS/docs"
git init -q -b main "$AS"
git -C "$AS" config user.name t
git -C "$AS" config user.email t@example.invalid
cat >"$AS/docs/BACKLOG.md" <<'MD'
# Backlog

| Item | Status | Owner |
|---|---|---|
| v1.1 | DOING | ada |
| v1.2 | TODO |  |
| v1.3 | TODO |  |
MD
cat >"$AS/ready.jsonl" <<'JL'
{"item":"v1.2","title":"Two","agents":["bo"]}
JL
as_manifest() { # [extra [team] lines...]
	cat <<'TOML'
[versioning]
tag = "v{version}"
admin_prefix = "admin:"
insert_segment = 2

[layout]
backlog = "docs/BACKLOG.md"
specs_dir = "docs"
worktrees = ".wt"
branch = "item-v{version}"
owner_column = "Owner"

[ready]
file = "ready.jsonl"

TOML
	if (($# > 0)); then
		printf '[team]\n'
		printf '%s\n' "$@"
		printf '\n'
	fi
	cat <<'TOML'
[[team.agent]]
name = "ada"

[[team.agent]]
name = "Bo"

[[team.agent]]
name = "cy"

[[team.agent]]
name = "di"
TOML
}
as_manifest 'inactive_file = "inactive-agents"' >"$AS/po.toml"
printf '# agents switched off\n\n  BO  \nada\n# cy\n' >"$AS/inactive-agents"
git -C "$AS" add -A
git -C "$AS" commit -qm init
# ada works on v1.1 (fresh event); bo, cy and di are idle and own nothing.
printf '{"time":"%s","kind":"stamp","item":"v1.1","project":"as","result":"pass","agent":"ada","legs":[],"detail":""}\n' \
	"$(date -u -d "1 minute ago" +%Y-%m-%dT%H:%M:%SZ)" >"$AS/.git/po-events.jsonl"
AJ=$("$PO" -C "$AS" team --json 2>&1)
[[ $(tjson '[a["Bo"].get("inactive"), a["Bo"]["free"], a["Bo"]["state"], a["Bo"]["owns"]]' <<<"$AJ") == "True False idle never []" ]] &&
	ok "v0.173 team: a listed idle agent that owns nothing is inactive and not free, its state unchanged" || bad "v0.173 team listed idle" "$AJ"
[[ $(tjson '[a["ada"].get("inactive"), a["ada"]["free"], a["ada"]["state"], a["ada"]["now"]]' <<<"$AJ") == "True False WORKING 1.1" ]] &&
	ok "v0.173 team: a listed WORKING agent is inactive, keeps its state and its item" || bad "v0.173 team listed working" "$AJ"
[[ $(tjson '["inactive" in a["cy"], a["cy"]["free"], "inactive" in a["di"], a["di"]["free"]]' <<<"$AJ") == "False True False True" ]] &&
	ok "v0.173 team: an unlisted agent (and a commented-out name) has no inactive key and stays free" || bad "v0.173 team unlisted" "$AJ"
out=$("$PO" -C "$AS" team 2>&1)
[[ $(awk '$1 == "Bo" {print $(NF-2)}' <<<"$out") == OFF && $(awk '$1 == "ada" {print $(NF-2)}' <<<"$out") == OFF && $(awk '$1 == "cy" {print $(NF-2)}' <<<"$out") == true && $(head -n 1 <<<"$out") == AGENT*STATE*NOW*OWNS*FREE*LIMIT*USAGE ]] &&
	ok "v0.173 team: the table prints OFF in the FREE column, no new column" || bad "v0.173 team table OFF" "$out"
mv "$AS/inactive-agents" "$TMP/as-saved"
out=$("$PO" -C "$AS" team --json 2>&1)
[[ $out != *inactive* && $out != *warning* && $(tjson '[a["Bo"]["free"]]' <<<"$out") == True ]] &&
	ok "v0.173 team: a missing switch file means nobody is inactive" || bad "v0.173 team missing file" "$out"
mv "$TMP/as-saved" "$AS/inactive-agents"
# dispatch: v1.2 may go only to bo, who is OFF.
out=$("$PO" -C "$AS" dispatch --plan 2>&1)
[[ $out == *'skip      v1.2  no free eligible agent (Bo is inactive)'* ]] &&
	ok "v0.173 dispatch --plan: the only eligible agent inactive is a skip that names it" || bad "v0.173 dispatch skip inactive" "$out"
printf '{"item":"v1.2","title":"Two","agents":["bo","cy"]}\n' >"$AS/ready.jsonl"
out=$("$PO" -C "$AS" dispatch --plan 2>&1)
[[ $out == *'assign    v1.2  to cy'* && $out != *inactive* ]] &&
	ok "v0.173 dispatch --plan: with a second free eligible agent the item goes to it" || bad "v0.173 dispatch second agent" "$out"
git -C "$AS" checkout -q -- ready.jsonl
# The CLI. Fixture: no final newline, comments and a blank line kept.
SWF=$AS/inactive-agents
printf '# agents switched off\n\nada' >"$SWF"
cp "$SWF" "$TMP/as-orig"
as_ino=$(stat -c %i "$SWF")
out=$("$PO" -C "$AS" team off cy 2>&1); code=$?
[[ $code == 0 && $out == *'would switch cy off'* ]] && cmp -s "$SWF" "$TMP/as-orig" &&
	ok "v0.173 team off without --commit prints the plan and writes nothing" || bad "v0.173 team off dry run (exit $code)" "$out"
out=$("$PO" -C "$AS" team on ada 2>&1); code=$?
[[ $code == 0 && $out == *'would switch ada on'* ]] && cmp -s "$SWF" "$TMP/as-orig" &&
	ok "v0.173 team on without --commit prints the plan and writes nothing" || bad "v0.173 team on dry run (exit $code)" "$out"
out=$("$PO" -C "$AS" team off cy --commit 2>&1); code=$?
[[ $code == 0 && $out == *'cy is now inactive'* && $(tail -n 1 "$SWF") == cy ]] &&
	ok "v0.173 team off --commit appends the agent as the last line" || bad "v0.173 team off commit (exit $code)" "$out / $(cat "$SWF")"
[[ $(stat -c %i "$SWF") == "$as_ino" ]] &&
	ok "v0.173 team off --commit rewrites the file in place (same inode)" || bad "v0.173 team off inode"
out=$("$PO" -C "$AS" team off CY --commit 2>&1); code=$?
[[ $code == 0 && $out == *'cy is already inactive'* && $(grep -ci '^cy$' "$SWF") == 1 ]] &&
	ok "v0.173 team off twice is already, no duplicate line (names match without case)" || bad "v0.173 team off twice (exit $code)" "$out / $(cat "$SWF")"
out=$("$PO" -C "$AS" team on cy --commit 2>&1); code=$?
[[ $code == 0 && $out == *'cy is now active'* ]] && cmp -s "$SWF" "$TMP/as-orig" &&
	ok "v0.173 team off then on of the last line is byte-exact (no final newline kept)" || bad "v0.173 team round trip (exit $code)" "$out / $(od -c "$SWF")"
[[ $(stat -c %i "$SWF") == "$as_ino" ]] &&
	ok "v0.173 team on --commit rewrites the file in place (same inode)" || bad "v0.173 team on inode"
out=$("$PO" -C "$AS" team on cy --commit 2>&1); code=$?
[[ $code == 0 && $out == *'cy is already active'* ]] && cmp -s "$SWF" "$TMP/as-orig" &&
	ok "v0.173 team on of an active agent is already, nothing written" || bad "v0.173 team on twice (exit $code)" "$out"
printf 'ada\nbo\ncy\n' >"$SWF"
"$PO" -C "$AS" team on Bo --commit >/dev/null 2>&1
"$PO" -C "$AS" team off bo --commit >/dev/null 2>&1
[[ $(cat "$SWF") == $'ada\ncy\nBo' && $(tail -c 1 "$SWF" | od -An -c | tr -d ' ') == '\n' ]] &&
	ok "v0.173 team on then off of a middle line brings it back at the end (roster spelling)" || bad "v0.173 team middle line" "$(od -c "$SWF")"
printf 'ada\n' >"$SWF"
cp "$SWF" "$TMP/as-orig"
out=$("$PO" -C "$AS" team off ghost --commit 2>&1); code=$?
[[ $code == 2 && $out == *ghost* ]] && cmp -s "$SWF" "$TMP/as-orig" &&
	ok "v0.173 team off of an agent not in the roster exits 2 and writes nothing" || bad "v0.173 team unknown agent (exit $code)" "$out"
rm -f "$SWF"
out=$("$PO" -C "$AS" team off di --commit 2>&1); code=$?
[[ $code == 0 && $(cat "$SWF") == di ]] &&
	ok "v0.173 team off with no switch file yet creates it" || bad "v0.173 team off creates (exit $code)" "$out"
as_manifest >"$AS/po.toml"
out=$("$PO" -C "$AS" team off di --commit 2>&1); code=$?
[[ $code == 2 && $out == *'no [team] inactive_file'* ]] &&
	ok "v0.173 team off without [team] inactive_file exits 2" || bad "v0.173 team no inactive_file (exit $code)" "$out"
expect "v0.173 team off needs an agent" 1 "team off: give an agent" -- -C "$AS" team off
expect "v0.173 team off takes one agent" 1 "team: unknown argument" -- -C "$AS" team off di cy
git -C "$AS" checkout -q -- po.toml

# ---- po land (v0.181): rebase, stamp, close, changelog, push in one command ----
# Stubs live outside every fixture repo: a gate that records each run (and
# whether the item's tag exists yet) and fails on demand, and a push command
# that records what it was given. Both append to one order file.
LD=$TMP/land
mkdir -p "$LD"
cat >"$LD/gate.sh" <<EOF
printf 'stamp %s tag=%s\n' "\$(git rev-parse HEAD)" "\$(git tag -l v1.0.3 | grep -c .)" >>"$LD/order"
[ -e "$LD/gate.fail" ] && { echo "stub gate: failing as told"; exit 1; }
exit 0
EOF
cat >"$LD/push.sh" <<EOF
printf 'push repo=%s tag=%s env=%s/%s/%s\n' "\$1" "\$(git -C "\$1" tag -l v1.0.3 | grep -c .)" "\$PO_VERSION" "\$PO_TAG" "\$(git -C "\$1" rev-parse --short "\$PO_ADMIN_COMMIT")" >>"$LD/order"
[ -e "$LD/push.fail" ] && { echo "stub push: failing as told" >&2; exit 3; }
exit 0
EOF
# land_manifest <file> <with-push> <with-changelog>
land_manifest() {
	{
		printf '[gate]\ntest_count_cmd = "echo '"'"'test result: ok. 1 passed; 0 failed;'"'"'"\n\n[gate.legs]\ncheck = "sh %s/gate.sh"\n\n' "$LD"
		printf '[versioning]\ntag = "v{version}"\nitem_commit = "v{version}: {title}"\nadmin_prefix = "admin:"\ninsert_segment = 4\n\n'
		printf '[layout]\nbacklog = "docs/BACKLOG.md"\nspecs_dir = "docs/backlog"\nworktrees = ".wt"\nbranch = "item-v{version}"\n\n'
		printf '[close]\nmemory = true\n'
		[[ $3 == 0 ]] || printf 'changelog = "CHANGELOG.md"\n'
		[[ $2 == 0 ]] || printf '\n[land]\npush = "sh %s/push.sh {repo}"\n' "$LD"
	} >"$1"
}
LM=$LD/land.toml && land_manifest "$LM" 1 1
LM_NOPUSH=$LD/nopush.toml && land_manifest "$LM_NOPUSH" 0 1
LM_NOCL=$LD/nochangelog.toml && land_manifest "$LM_NOCL" 1 0
# make_lrepo <dir> [behind]: make_brepo's backlog plus a CHANGELOG.md, the
# v1.0.3 branch one item commit with a passing stamp; with `behind`, main
# then moves on by one commit (the branch needs a rebase).
make_lrepo() {
	local dir=$1
	git init -q -b main "$dir"
	git -C "$dir" config user.name "Boundary PO"
	git -C "$dir" config user.email po@example.invalid
	mkdir -p "$dir/docs/backlog"
	cat >"$dir/docs/BACKLOG.md" <<'EOF'
# Backlog

Epic one — **v1.0.3 DOING; spec backlog/v1.md** · E0 — v1.0.2 DONE (tag v1.0.2).

| Item | Title | Status |
|---|---|---|
| v1.0.1 | First | DONE |
| v1.0.3 | Third | DOING |
EOF
	cat >"$dir/docs/backlog/v1.md" <<'EOF'
# v1 specs

## v1.0.1 — First — DONE

## v1.0.2 — Second — DONE (no bump)

## v1.0.3 — Third — DOING

Body of three.
EOF
	printf '# Changelog\n\n## Unreleased\n\n### An older entry (v1.0.2)\n\n- the second thing.\n\n## Release 1 (2026-01-01): first\n\n- the first thing.\n' >"$dir/CHANGELOG.md"
	git -C "$dir" add -A
	git -C "$dir" commit -qm init
	git -C "$dir" tag v1.0.2
	git -C "$dir" worktree add -q "$dir/.wt/item-v1.0.3" -b item-v1.0.3
	echo three >"$dir/.wt/item-v1.0.3/three.txt"
	git -C "$dir/.wt/item-v1.0.3" add three.txt
	git -C "$dir/.wt/item-v1.0.3" commit -qm "v1.0.3: Third"
	"$PO" -C "$dir/.wt/item-v1.0.3" --manifest "$LM" stamp >/dev/null 2>&1
	if [[ ${2:-} == behind ]]; then
		echo other >"$dir/other.txt"
		git -C "$dir" add other.txt
		git -C "$dir" commit -qm "admin: main moves on"
	fi
	: >"$LD/order"
	rm -f "$LD/gate.fail" "$LD/push.fail"
}
lsnap() { # everything a land could touch, in and around one fixture
	git -C "$1" for-each-ref --format='%(refname) %(objectname)'
	git -C "$1" worktree list --porcelain
	git -C "$1" status --porcelain --untracked-files=all --ignored
	git -C "$1/.wt/item-v1.0.3" status --porcelain --untracked-files=all --ignored 2>/dev/null
	git -C "$1/.wt/item-v1.0.3" rev-parse HEAD 2>/dev/null
	ls "$1/.wt/item-v1.0.3" 2>/dev/null
	cat "$1/docs/BACKLOG.md" "$1/docs/backlog/v1.md" "$1/CHANGELOG.md"
	find "$1/.git/po-land" 2>/dev/null | sort
	cat "$LD/order"
}
printf 'v1.0.3 report — item-v1.0.3\n\nFiles changed: three.txt\n\nPROPOSED:\n1. the number three is the best one\n\nMemory: proposed 20261103-120000-ab12 (next time X, do Y, because Z)\n' >"$LD/report.md"
printf '### Third thing lands (v1.0.3)\n\n- three.txt added.\n' >"$LD/changelog.md"

# po land record: the trigger record, outside the worktree.
L1=$TMP/land-1
make_lrepo "$L1" behind
expect "land record refuses an item that is not DOING" 6 'v1\.0\.2 is DONE, not DOING' -- -C "$L1" --manifest "$LM" land record 1.0.2 --spec-met --by dante
expect "land record needs --spec-met" 1 'needs --spec-met' -- -C "$L1" --manifest "$LM" land record 1.0.3 --by dante
expect "land record needs --by" 1 'needs --by' -- -C "$L1" --manifest "$LM" land record 1.0.3 --spec-met
expect "land refuses an item with no SPEC MET record (exit 6, land: REFUSED on stdout)" 6 '^land: REFUSED no SPEC MET recorded for v1\.0\.3' -- -C "$L1" --manifest "$LM" land 1.0.3
[[ ! -s $LD/order ]] && ok "land with no record ran no gate" || bad "land without a record ran the gate" "$(cat "$LD/order")"
expect "land record writes the SPEC MET record" 0 'recorded SPEC MET for v1\.0\.3 by first' -- -C "$L1" --manifest "$LM" land record 1.0.3 --spec-met --by first --ref msg-1
grep -q '^by=first at=[0-9T:-]*Z ref=msg-1$' "$L1/.git/po-land/1.0.3/spec-met" &&
	ok "the record is one line (by, at, ref) in the common git dir, not the worktree" || bad "record file" "$(cat "$L1/.git/po-land/1.0.3/spec-met" 2>&1)"
! git -C "$L1/.wt/item-v1.0.3" status --porcelain --untracked-files=all | grep -qv 'gate-' &&
	ok "the record leaves the worktree clean" || bad "record dirtied the worktree"
"$PO" -C "$L1" --manifest "$LM" land record 1.0.3 --spec-met --by dante --ref msg-2 --report-file "$LD/report.md" --changelog-file "$LD/changelog.md" >/dev/null 2>&1
grep -q '^by=dante at=.* ref=msg-2$' "$L1/.git/po-land/1.0.3/spec-met" && [[ -f $L1/.git/po-land/1.0.3/report.md && -f $L1/.git/po-land/1.0.3/changelog.md ]] &&
	ok "a second land record replaces the first (a new SPEC MET after a FIX?)" || bad "record overwrite" "$(cat "$L1/.git/po-land/1.0.3/spec-met")"

# --dry-run: every pre-flight check as a plan line, then the steps; nothing runs, nothing is written.
before=$(lsnap "$L1")
out=$("$PO" -C "$L1" --manifest "$LM" land 1.0.3 --dry-run 2>&1)
code=$?
[[ $code == 0 && $(lsnap "$L1") == "$before" ]] && ok "land --dry-run exits 0 and writes nothing (refs, trees, record, order file all equal)" || bad "land dry run (exit $code)" "$out"
grep -q 'DRY RUN' <<<"$out" && grep -q 'record *ok: SPEC MET by dante' <<<"$out" && grep -q 'commits *ok: 1 commit' <<<"$out" &&
	ok "land --dry-run reports each pre-flight check as ok" || bad "dry run checks" "$out"
grep -qE 'rebase: needed, main at [0-9a-f]+ vs merge-base [0-9a-f]+' <<<"$out" && grep -q 'stamp: would run check' <<<"$out" &&
	grep -q 'SPEC MET: dante' <<<"$out" && grep -q 'Memory: proposed 20261103-120000-ab12' <<<"$out" &&
	grep -qF "push: sh $LD/push.sh $L1" <<<"$out" &&
	ok "land --dry-run prints the rebase, stamp, close body and push plan" || bad "dry run steps" "$out"
L2=$TMP/land-2
make_lrepo "$L2"
out=$("$PO" -C "$L2" --manifest "$LM" land 1.0.3 --dry-run 2>&1)
code=$?
[[ $code == 0 ]] && grep -q 'would refuse: no SPEC MET recorded for v1\.0\.3' <<<"$out" && grep -q 'rebase: not needed' <<<"$out" && grep -q 'stamp: not needed' <<<"$out" &&
	ok "land --dry-run on a DOING item with no record exits 0, says 'would refuse' and prints the rest" || bad "dry run no record (exit $code)" "$out"
expect "the real run on the same item exits 6" 6 '^land: REFUSED no SPEC MET recorded' -- -C "$L2" --manifest "$LM" land 1.0.3
[[ ! -s $LD/order ]] && ok "neither dry run ran the gate" || bad "dry run ran the gate" "$(cat "$LD/order")"

# The happy path, behind main: rebase -> stamp -> close (changelog in the admin commit) -> push.
old_tip=$(git -C "$L1" rev-parse item-v1.0.3)
out=$("$PO" -C "$L1" --manifest "$LM" land 1.0.3 2>"$LD/land-1.err")
code=$?
[[ $code == 0 && $out =~ ^land:\ OK\ v1\.0\.3 ]] && [[ $(wc -l <<<"$out") == 1 ]] &&
	ok "land exits 0 with one 'land: OK' line on stdout" || bad "land happy path (exit $code)" "$out
$(cat "$LD/land-1.err")"
mapfile -t order <"$LD/order"
new_tip=$(git -C "$L1" rev-parse 'v1.0.3^{commit}')
[[ ${#order[@]} == 2 && ${order[0]} == "stamp $new_tip tag=0" && ${order[1]} == "push repo=$L1 tag=1 env=1.0.3/v1.0.3/$(git -C "$L1" rev-parse --short main)" ]] &&
	ok "the order is rebase, stamp (of the rebased tip, before the tag), close, push (with PO_VERSION, PO_TAG, PO_ADMIN_COMMIT)" || bad "land order" "$(printf '%s\n' "${order[@]}")"
[[ $new_tip != "$old_tip" && $(git -C "$L1" rev-parse "$new_tip^") == "$(git -C "$L1" rev-parse main~2)" ]] &&
	ok "the item commit was rebased onto main's tip" || bad "rebase" "$(git -C "$L1" log --oneline main)"
[[ $(git -C "$L1" rev-list --count "v1.0.3..main") == 1 ]] && git -C "$L1" log -1 --format=%s main | grep -q '^admin: v1.0.3 DONE (tag v1.0.3)$' &&
	ok "main moved once past the item commit: the close's admin commit" || bad "one admin commit" "$(git -C "$L1" log --oneline main)"
stat=$(git -C "$L1" show --stat --format= main)
grep -q 'CHANGELOG.md' <<<"$stat" && grep -q 'docs/BACKLOG.md' <<<"$stat" && grep -q 'docs/backlog/v1.md' <<<"$stat" &&
	ok "the changelog block and the backlog edits are in the same admin commit" || bad "admin commit files" "$stat"
cl=$(git -C "$L1" show main:CHANGELOG.md)
[[ $cl == $'# Changelog\n\n## Unreleased\n\n### Third thing lands (v1.0.3)\n\n- three.txt added.\n\n### An older entry (v1.0.2)'* ]] &&
	ok "the block sits right under the Unreleased heading, one blank line each side" || bad "changelog content" "$cl"
msg=$(git -C "$L1" log -1 --format=%B main)
grep -q '^SPEC MET: dante .* msg-2$' <<<"$msg" && grep -q '^Memory: proposed 20261103-120000-ab12' <<<"$msg" && grep -q 'the number three is the best one' <<<"$msg" &&
	grep -q "^Stamp: gate PASS, 1 tests, HEAD $(git -C "$L1" rev-parse --short "$new_tip") (item-v1.0.3), gate-2.txt, rebased onto main" <<<"$msg" &&
	ok "the close body carries the stamp line, SPEC MET, the PROPOSED notes and the REPORT's Memory line" || bad "close body" "$msg"
[[ ! -d $L1/.wt/item-v1.0.3 ]] && ! git -C "$L1" show-ref -q refs/heads/item-v1.0.3 && [[ ! -e $L1/.git/po-land/1.0.3 ]] &&
	ok "after the land the worktree, the branch and the record are gone" || bad "cleanup" "$(git -C "$L1" worktree list; ls "$L1/.git/po-land")"
grep -q '"kind":"close","item":"1.0.3"' "$L1/.git/po-events.jsonl" && grep -q '"kind":"stamp","item":"1.0.3"' "$L1/.git/po-events.jsonl" &&
	ok "the land's stamp and close show in po events" || bad "events" "$(cat "$L1/.git/po-events.jsonl")"

# Not behind, dev's stamp names the tip: no second stamp; no [land] push: exit 0 and the none-configured line.
L3=$TMP/land-3
make_lrepo "$L3"
"$PO" -C "$L3" --manifest "$LM_NOPUSH" land record 1.0.3 --spec-met --by dante >/dev/null 2>&1
out=$("$PO" -C "$L3" --manifest "$LM_NOPUSH" land 1.0.3 2>&1)
code=$?
[[ $code == 0 ]] && grep -q '^land: OK v1\.0\.3 .*push none' <<<"$out" && grep -q 'push: none configured; pushing is the PO'"'"'s step' <<<"$out" &&
	ok "no [land] push: the land closes, says the push is the PO's step, exit 0" || bad "no push key (exit $code)" "$out"
[[ ! -s $LD/order ]] && ok "a branch at main's tip whose stamp names it is not stamped again" || bad "duplicate stamp" "$(cat "$LD/order")"
grep -q '^Memory: nothing new learned$' <<<"$(git -C "$L3" log -1 --format=%B main)" &&
	ok "with no REPORT recorded the body says 'Memory: nothing new learned'" || bad "default memory line" "$(git -C "$L3" log -1 --format=%B main)"

# Refusals before any write: dirty tree, two commits.
L4=$TMP/land-4
make_lrepo "$L4" behind
"$PO" -C "$L4" --manifest "$LM" land record 1.0.3 --spec-met --by dante >/dev/null 2>&1
before=$(lsnap "$L4")
echo dirt >"$L4/.wt/item-v1.0.3/dirt.txt"
expect "a dirty worktree is refused, naming the path" 6 '^land: REFUSED .*dirt\.txt' -- -C "$L4" --manifest "$LM" land 1.0.3
rm "$L4/.wt/item-v1.0.3/dirt.txt"
git -C "$L4/.wt/item-v1.0.3" commit -q --allow-empty -m "v1.0.3: Third again"
expect "two commits are refused, naming both subjects" 6 '^land: REFUSED .*2 commits.*one item = one commit.*v1\.0\.3: Third.*v1\.0\.3: Third again' -- -C "$L4" --manifest "$LM" land 1.0.3
git -C "$L4/.wt/item-v1.0.3" reset -q --hard HEAD~1
[[ $(lsnap "$L4") == "$before" && ! -s $LD/order ]] && ok "refusals ran no rebase and no gate, and wrote nothing" || bad "refusal side effects" "$(cat "$LD/order")"
echo '- three, in the item commit' >>"$L4/.wt/item-v1.0.3/CHANGELOG.md"
git -C "$L4/.wt/item-v1.0.3" commit -q -a --amend --no-edit
expect "a record with a changelog block for an item whose commit touches CHANGELOG.md is refused" 6 'land twice' -- -C "$L4" --manifest "$LM" land record 1.0.3 --spec-met --by dante --changelog-file "$LD/changelog.md"

# A rebase conflict: abort, exit 5, the worktree exactly as the dev left it.
L5=$TMP/land-5
make_lrepo "$L5"
echo clash >"$L5/three.txt"
git -C "$L5" add three.txt
git -C "$L5" commit -qm "admin: main adds three.txt too"
"$PO" -C "$L5" --manifest "$LM" land record 1.0.3 --spec-met --by dante >/dev/null 2>&1
: >"$LD/order"
before=$(lsnap "$L5")
out=$("$PO" -C "$L5" --manifest "$LM" land 1.0.3 2>/dev/null)
code=$?
[[ $code == 5 && $out == 'land: CONFLICT three.txt' ]] && ok "a rebase conflict exits 5 with 'land: CONFLICT <path>'" || bad "conflict (exit $code)" "$out"
[[ $(lsnap "$L5") == "$before" ]] && ok "after the conflict HEAD, the tree, the stamps and main are byte-equal to before (rebase aborted)" || bad "conflict left state" "$(diff <(echo "$before") <(lsnap "$L5"))"
[[ -z $(git -C "$L5/.wt/item-v1.0.3" rev-parse --git-path rebase-merge | xargs -I{} sh -c 'test -e {} && echo busy') ]] && ok "no rebase is left in progress" || bad "rebase in progress"

# A failed post-rebase stamp: exit 4, no tag, main unmoved, the worktree at the rebased tip (R6).
L6=$TMP/land-6
make_lrepo "$L6" behind
"$PO" -C "$L6" --manifest "$LM" land record 1.0.3 --spec-met --by dante >/dev/null 2>&1
old_tip=$(git -C "$L6" rev-parse item-v1.0.3)
main_before=$(git -C "$L6" rev-parse main)
touch "$LD/gate.fail"
out=$("$PO" -C "$L6" --manifest "$LM" land 1.0.3 2>"$LD/land-6.err")
code=$?
rm -f "$LD/gate.fail"
[[ $code == 4 && $out =~ ^land:\ STAMP\ FAILED\ leg\ check,\ log\ /.*stamp-.*\.log$ ]] && ok "a failed stamp exits 4 with 'land: STAMP FAILED leg <leg>, log <path>'" || bad "failed stamp (exit $code)" "$out
$(cat "$LD/land-6.err")"
new_tip=$(git -C "$L6" rev-parse item-v1.0.3)
[[ $(git -C "$L6" rev-parse main) == "$main_before" ]] && ! git -C "$L6" show-ref -q refs/tags/v1.0.3 &&
	ok "a failed stamp closes nothing: main unmoved, no tag" || bad "failed stamp wrote" "$(git -C "$L6" log --oneline main)"
[[ $new_tip != "$old_tip" && $(git -C "$L6" rev-parse "$new_tip^") == "$main_before" ]] && ! git -C "$L6/.wt/item-v1.0.3" status --porcelain | grep -qv 'gate-1.txt' &&
	grep -q "was $(git -C "$L6" rev-parse --short "$old_tip")" "$LD/land-6.err" &&
	ok "the worktree stays at the rebased tip, clean, and the old tip is printed" || bad "R6 worktree state" "$(cat "$LD/land-6.err")"
[[ ! -e $L6/.wt/item-v1.0.3/gate-2.txt ]] && ok "the failed stamp wrote no gate file" || bad "gate file written on failure"

# A failing push: exit 7, the boundary stands.
L7=$TMP/land-7
make_lrepo "$L7"
"$PO" -C "$L7" --manifest "$LM" land record 1.0.3 --spec-met --by dante >/dev/null 2>&1
touch "$LD/push.fail"
out=$("$PO" -C "$L7" --manifest "$LM" land 1.0.3 2>/dev/null)
code=$?
rm -f "$LD/push.fail"
[[ $code == 7 && $out == 'land: PUSH FAILED (exit 3)' ]] && git -C "$L7" show-ref -q refs/tags/v1.0.3 && [[ ! -d $L7/.wt/item-v1.0.3 ]] &&
	ok "a failing push exits 7 with 'land: PUSH FAILED (exit n)'; the close stands" || bad "push failure (exit $code)" "$out"

# po close --changelog-file on its own.
L8=$TMP/land-8
make_lrepo "$L8"
printf 'Memory: nothing new learned\n' >"$LD/body.txt"
expect "close --changelog-file without [close] changelog is refused" 6 'needs \[close\] changelog' -- -C "$L8" --manifest "$LM_NOCL" close 1.0.3 --body-file "$LD/body.txt" --changelog-file "$LD/changelog.md"
out=$("$PO" -C "$L8" --manifest "$LM" close 1.0.3 --body-file "$LD/body.txt" --changelog-file "$LD/changelog.md" 2>&1)
grep -qxF -- '+### Third thing lands (v1.0.3)' <<<"$out" && grep -qxF -- '+++ b/CHANGELOG.md' <<<"$out" && grep -q 'EDITS (3 files)' <<<"$out" &&
	ok "close plans the changelog block as one more edited file in the same admin commit" || bad "changelog plan" "$out"
printf '### An older entry (v1.0.2)\n\n- again\n' >"$LD/dup.md"
expect "a block whose heading the changelog already has is refused" 6 'changelog already has ### An older entry' -- -C "$L8" --manifest "$LM" close 1.0.3 --body-file "$LD/body.txt" --changelog-file "$LD/dup.md"
expect "close without --changelog-file plans the backlog edits only, as before" 0 'EDITS \(2 files\)' -- -C "$L8" --manifest "$LM" close 1.0.3 --body-file "$LD/body.txt"
# No Unreleased heading yet: the heading and the block go before the first release heading.
sed -i '/^## Unreleased$/,/^## Release 1/{/^## Release 1/!d}' "$L8/CHANGELOG.md"
git -C "$L8" commit -qam "admin: changelog without Unreleased"
git -C "$L8/.wt/item-v1.0.3" rebase -q main && "$PO" -C "$L8/.wt/item-v1.0.3" --manifest "$LM" stamp >/dev/null 2>&1
"$PO" -C "$L8" --manifest "$LM" close 1.0.3 --body-file "$LD/body.txt" --changelog-file "$LD/changelog.md" --commit >/dev/null 2>&1
cl=$(git -C "$L8" show main:CHANGELOG.md)
[[ $cl == $'# Changelog\n\n## Unreleased\n\n### Third thing lands (v1.0.3)\n\n- three.txt added.\n\n## Release 1 (2026-01-01): first'* ]] &&
	ok "with no Unreleased heading, close inserts the heading and the block before the first release" || bad "changelog without heading" "$cl"

# po status: a DOING branch behind main is marked, in the table and in --json.
L9=$TMP/land-9
make_lrepo "$L9"
expect "status: a branch at main's tip carries no mark" 0 'branch item-v1\.0\.3  [0-9a-f]+  ahead 1  behind 0  idle [0-9hm]+$' -- -C "$L9" --manifest "$LM" status
expect "status --json: needs_rebase false at main's tip" 0 '^\[\{"item":"1\.0\.3","idle_hours":0,"needs_rebase":false\}\]$' -- -C "$L9" --manifest "$LM" status --json
git -C "$L9" commit -q --allow-empty -m "admin: main moves on"
expect "status: a DOING branch behind main carries 'needs rebase' after its behind count, idle still last" 0 'branch item-v1\.0\.3  [0-9a-f]+  ahead 1  behind 1  needs rebase  idle [0-9hm]+$' -- -C "$L9" --manifest "$LM" status
expect "status --json: needs_rebase true behind main" 0 '"item":"1\.0\.3","idle_hours":0,"needs_rebase":true\}' -- -C "$L9" --manifest "$LM" status --json
expect "prune lists no land record while the item is DOING with a branch" 0 '^KEPT' -- -C "$L9" --manifest "$LM" prune
"$PO" -C "$L9" --manifest "$LM" land record 1.0.3 --spec-met --by dante >/dev/null 2>&1
out=$("$PO" -C "$L9" --manifest "$LM" prune 2>&1)
! grep -q 'STALE LAND RECORDS' <<<"$out" && ok "a record for a DOING item with a branch is not stale" || bad "prune listed a live record" "$out"
mkdir -p "$L7/.git/po-land/1.0.3" && printf 'by=dante at=2026-11-12T00:00:00Z ref=hand\n' >"$L7/.git/po-land/1.0.3/spec-met"
expect "prune lists a land record whose item is DONE (listed, not removed)" 0 '^  v1\.0\.3  item is DONE, not DOING  \(.*/po-land/1\.0\.3\)$' -- -C "$L7" --manifest "$LM" prune
"$PO" -C "$L7" --manifest "$LM" prune --commit >/dev/null 2>&1
[[ -f $L7/.git/po-land/1.0.3/spec-met ]] && ok "prune --commit leaves the stale record alone" || bad "prune removed a record"
expect "land takes one version" 1 'usage: po land' -- -C "$L9" --manifest "$LM" land
expect "land rejects unknown options" 1 "land: unknown argument '--force'" -- -C "$L9" --manifest "$LM" land 1.0.3 --force

# ---- tiered gate (v0.182): po stamp --tier fast|full, # covers: lines, full at close/land/release ----
# A fixture repo whose [stamp] test_files are t/suite.sh and the files of t/d/; the fake suite
# records the units it was given in $TG/args and passes one check per unit, so the count says how
# many units ran. Units: t/suite.sh covers lib/, a.sh covers lib/x.sh, b.sh covers lib/ (a // leader), c.sh has no covers
# line, d.sh covers etc/thing (a -- leader). The full suite is all five.
TG=$TMP/tier
mkdir -p "$TG"
# helper
cat >"$TG/suite.sh" <<EOF
printf '%s\n' "\$*" >"$TG/args"
echo "test result: ok. \$# passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s"
EOF
TG_FULL='t/suite.sh t/d/a.sh t/d/b.sh t/d/c.sh t/d/d.sh'
# tier_manifest <file> [tier=<v>] [fast=0] [always=<toml array>] [ignore=<toml array>] [command=<v>]
tier_manifest() {
	local f=$1 tier='' fast=1 always='["t/suite.sh"]' ignore='["CHANGELOG.md", "docs/"]' command="sh $TG/suite.sh {selected}" a
	shift
	for a; do
		case $a in
		tier=*) tier=${a#tier=} ;;
		fast=*) fast=${a#fast=} ;;
		always=*) always=${a#always=} ;;
		ignore=*) ignore=${a#ignore=} ;;
		command=*) command=${a#command=} ;;
		esac
	done
	{
		printf '[gate.legs]\nlint = "true"\ntest = "sh %s/suite.sh %s"\n\n' "$TG" "$TG_FULL"
		printf '[versioning]\ntag = "v{version}"\nitem_commit = "v{version}: {title}"\nadmin_prefix = "admin:"\ninsert_segment = 4\n\n'
		printf '[layout]\nbacklog = "docs/BACKLOG.md"\nspecs_dir = "docs/backlog"\nworktrees = ".wt"\nbranch = "item-v{version}"\n\n'
		printf '[close]\nmemory = true\n\n'
		printf '[stamp]\ntest_files = ["t/suite.sh", "t/d/"]\ntest_def = "^ok "\n'
		[[ -z $tier ]] || printf 'tier = "%s"\n' "$tier"
		if ((fast)); then
			printf '\n[stamp.fast]\ncommand = "%s"\n' "$command"
			[[ $always == none ]] || printf 'always = %s\n' "$always"
			[[ $ignore == none ]] || printf 'ignore = %s\n' "$ignore"
		fi
	} >"$f"
}
# make_trepo <dir>: main with the units, lib/ and etc/, tag v1.0.2, and the v1.0.3 branch one item
# commit that changes lib/x.sh, in .wt/item-v1.0.3; no stamp yet.
make_trepo() {
	local dir=$1
	git init -q -b main "$dir"
	git -C "$dir" config user.name "Boundary PO"
	git -C "$dir" config user.email po@example.invalid
	mkdir -p "$dir/docs/backlog" "$dir/t/d" "$dir/lib" "$dir/etc"
	printf '# Backlog\n\nEpic one — **v1.0.3 DOING; spec backlog/v1.md** · E0 — v1.0.2 DONE (tag v1.0.2).\n\n| Item | Title | Status |\n|---|---|---|\n| v1.0.1 | First | DONE |\n| v1.0.3 | Third | DOING |\n' >"$dir/docs/BACKLOG.md"
	printf '# v1 specs\n\n## v1.0.1 — First — DONE\n\n## v1.0.2 — Second — DONE (no bump)\n\n## v1.0.3 — Third — DOING\n\nBody of three.\n' >"$dir/docs/backlog/v1.md"
	printf '# Changelog\n\n## Unreleased\n\n## Release 1 (2026-01-01): first\n\n### First (v1.0.1)\n\n- the first thing.\n' >"$dir/CHANGELOG.md"
	printf '# the suite\n# covers: lib/\nok one\n' >"$dir/t/suite.sh"
	printf '# unit a\n# covers: lib/x.sh\nok a\n' >"$dir/t/d/a.sh"
	printf '# unit b\n  // covers: lib/\nok b\n' >"$dir/t/d/b.sh"
	printf '# unit c, no covers line\nok c\n' >"$dir/t/d/c.sh"
	printf -- '-- unit d\n-- covers: etc/thing\nok d\n' >"$dir/t/d/d.sh"
	echo x >"$dir/lib/x.sh"
	echo y >"$dir/lib/y.sh"
	echo thing >"$dir/etc/thing"
	git -C "$dir" add -A
	git -C "$dir" commit -qm init
	git -C "$dir" tag v1.0.2
	git -C "$dir" worktree add -q "$dir/.wt/item-v1.0.3" -b item-v1.0.3
	echo x2 >"$dir/.wt/item-v1.0.3/lib/x.sh"
	git -C "$dir/.wt/item-v1.0.3" commit -qam "v1.0.3: Third"
}
TR=$TMP/tier-1
TW=$TR/.wt/item-v1.0.3
make_trepo "$TR"
TM=$TG/tier.toml && tier_manifest "$TM" tier=fast
TM_PLAIN=$TG/plain.toml && tier_manifest "$TM_PLAIN"
tstamp() { "$PO" -C "$TW" --manifest "${TMF:-$TM}" stamp "$@" 2>/dev/null; }
tier_line() { grep '^tier:' <<<"$1"; }

# 1: the item changes only lib/x.sh: a.sh and b.sh cover it, c.sh has no line (runs always), the
# always unit; no full stamp on record yet, then the denominator is the newest full stamp's count.
out=$(tstamp)
[[ $(cat "$TG/args") == 't/suite.sh t/d/a.sh t/d/b.sh t/d/c.sh' && $(tier_line "$out") == 'tier: fast, 4 checks, no full count on record' ]] &&
	grep -q '^gate PASS: lint/test   tests 4 passed$' <<<"$out" &&
	ok "tier: a fast stamp runs the units that cover the changed file, the unmapped units and the always set, in test_files order" ||
	bad "tier fast selection" "$out"$'\n--- args\n'"$(cat "$TG/args")"
out=$(tstamp --tier full)
[[ $(cat "$TG/args") == "$TG_FULL" && $(tier_line "$out") == 'tier: full' ]] &&
	ok "tier: --tier full runs the manifest's own test command and names the tier" || bad "tier full" "$out"
out=$(tstamp)
[[ $(tier_line "$out") == 'tier: fast, 4 of 5 checks' ]] &&
	ok "tier: a fast stamp names its count of the newest full stamp's checks" || bad "tier denominator" "$out"
awk '/^diffstat vs/ { d = NR } /^tests vs/ { v = NR } /^flag:/ { f = NR } /^tier:/ { t = NR } END { exit !(d && v && f && t == f + 1 && t == NR) }' <<<"$out" &&
	ok "tier: the tier line follows the diffstat, tests-vs-merge-base and flag lines" || bad "tier line place" "$out"

# 2: a changed path no unit covers falls back to full and says which.
echo other >"$TW/etc/other"
out=$(tstamp)
[[ $(cat "$TG/args") == "$TG_FULL" && $(tier_line "$out") == 'tier: full (fast fell back: etc/other is covered by no test)' ]] &&
	ok "tier: an unmapped changed file (untracked too) makes the fast stamp run full and name the file" || bad "tier fallback" "$out"
rm -f "$TW/etc/other"

# 3: a changed test file is selected itself, whatever it covers.
echo 'ok d2' >>"$TW/t/d/d.sh"
out=$(tstamp)
[[ $(cat "$TG/args") == 't/suite.sh t/d/a.sh t/d/b.sh t/d/c.sh t/d/d.sh' ]] &&
	ok "tier: a changed test file is selected and runs whole" || bad "tier changed unit" "$out"$'\n--- args\n'"$(cat "$TG/args")"
git -C "$TW" checkout -q -- t/d/d.sh

# 4: an ignored path selects nothing and does not fall back; with no always set, nothing selected
# falls back.
git -C "$TW" reset -q --hard main
echo note >>"$TW/CHANGELOG.md"
echo note >"$TW/docs/notes.md"
out=$(tstamp)
[[ $(cat "$TG/args") == 't/suite.sh t/d/c.sh' && $(tier_line "$out") == 'tier: fast, 2 of 5 checks' ]] &&
	ok "tier: ignored paths (a file and a dir/ prefix) select nothing and do not fall back" || bad "tier ignore" "$out"$'\n--- args\n'"$(cat "$TG/args")"
git -C "$TW" checkout -q -- CHANGELOG.md && rm -f "$TW/docs/notes.md"
printf '# unit c, now mapped\n# covers: lib/y.sh\nok c\n' >"$TR/t/d/c.sh"
git -C "$TR" commit -qam "admin: c is mapped" && git -C "$TW" reset -q --hard main
echo note >>"$TW/CHANGELOG.md"
tier_manifest "$TG/noalways.toml" tier=fast always=none
out=$(TMF=$TG/noalways.toml tstamp)
[[ $(cat "$TG/args") == "$TG_FULL" && $(tier_line "$out") == 'tier: full (fast fell back: no test selected)' ]] &&
	ok "tier: an empty selection falls back to full" || bad "tier empty selection" "$out"
git -C "$TW" checkout -q -- CHANGELOG.md
echo x3 >"$TW/lib/x.sh" && git -C "$TW" commit -qam "v1.0.3: Third"

# 5: without the key and the flag the block has no tier line (the byte-identical pin of the stamp
# section above is the proof for a manifest without [stamp.fast]).
out=$(TMF=$TM_PLAIN tstamp)
[[ -z $(tier_line "$out") && $(cat "$TG/args") == "$TG_FULL" ]] &&
	ok "tier: no [stamp] tier and no --tier: a full run and no tier line" || bad "tier default" "$out"
out=$(TMF=$TM_PLAIN tstamp --tier fast)
[[ $(tier_line "$out") == 'tier: fast, 3 of 5 checks' ]] && ok "tier: --tier fast overrides a manifest without [stamp] tier" || bad "tier flag fast" "$out"

# 6: the fast stamp's event says so; po events marks it; --trend counts full stamps only.
ev=$(git -C "$TR" rev-parse --path-format=absolute --git-common-dir)/po-events.jsonl
grep '"kind":"stamp"' "$ev" | tail -n 1 | grep -qE '"tests":3,"tier":"fast",' &&
	ok "tier: a fast stamp's event carries \"tier\":\"fast\" after tests" || bad "tier event" "$(tail -n 2 "$ev")"
grep '"kind":"stamp"' "$ev" | sed -n 2p | grep -q '"tests":5,"load1":' &&
	ok "tier: a full stamp's event is unchanged (no tier key)" || bad "tier full event" "$(cat "$ev")"
out=$("$PO" -C "$TR" --manifest "$TM" events 2>&1)
grep -qE '^[0-9-]+ [0-9:]+ [A-Z+0-9-]+ +stamp +1\.0\.3 +tier-1 +pass +[^ ]+ +[0-9]+s fast ' <<<"$out" &&
	ok "tier: po events prints fast after a fast stamp's time" || bad "tier events table" "$out"
TE=$TMP/tier-ev && git init -q -b main "$TE"
{
	printf '{"time":"2026-11-10T10:00:00Z","kind":"stamp","item":"1.0","project":"tier-ev","result":"pass","agent":"a","legs":[{"name":"test","result":"pass","seconds":100}],"seconds":110,"tests":10,"load1":1.0,"detail":""}\n'
	printf '{"time":"2026-11-10T11:00:00Z","kind":"stamp","item":"1.1","project":"tier-ev","result":"pass","agent":"a","legs":[{"name":"test","result":"pass","seconds":10}],"seconds":12,"tests":3,"tier":"fast","load1":1.0,"detail":""}\n'
} >"$TE/.git/po-events.jsonl"
out=$(PO_EVENTS_NOW=$(date -u -d 2026-11-11 +%s) "$PO" -C "$TE" --manifest "$TM" events --trend --days 30 --json 2>&1)
grep -q '"day":"2026-11-10","stamps":1,"tests":10,"test_leg":100' <<<"$out" &&
	ok "tier: po events --trend skips fast stamps (one full stamp of 10, one fast of 3: 1 stamp, 10, its test leg)" || bad "tier trend" "$out"

# 7: po close wants a full stamp at the tip; a newer fast one beside it is fine.
rm -f "$TW"/gate-*.txt
tstamp >/dev/null
out=$("$PO" -C "$TR" --manifest "$TM" close 1.0.3 2>&1)
[[ $? == 6 && $out == *'gate-1.txt is a fast stamp; run po stamp --tier full in .wt/item-v1.0.3 (po land does this)'* ]] &&
	ok "tier: po close with only a fast stamp is refused (6) and names the command" || bad "tier close fast only" "$out"
tstamp --tier full >/dev/null && tstamp >/dev/null
out=$("$PO" -C "$TR" --manifest "$TM" close 1.0.3 2>&1)
[[ $? == 0 && -f $TW/gate-3.txt ]] && ok "tier: po close reuses a full stamp at the tip under a newer fast one" || bad "tier close reuse" "$out"
echo x4 >"$TW/lib/x.sh" && git -C "$TW" commit -q --amend -am "v1.0.3: Third"
tstamp >/dev/null
out=$("$PO" -C "$TR" --manifest "$TM" close 1.0.3 2>&1)
[[ $? == 6 && $out == *'gate-2.txt does not stamp the branch tip'* ]] &&
	ok "tier: po close refuses a stale full stamp with the usual message, a newer fast one notwithstanding" || bad "tier close stale full" "$out"

# 8: po land: the dev's fast stamp at the tip is evidence, the land stamps full.
"$PO" -C "$TR" --manifest "$TM" land record 1.0.3 --spec-met --by dante >/dev/null 2>&1
out=$("$PO" -C "$TR" --manifest "$TM" land 1.0.3 --dry-run 2>&1)
grep -q 'stamp *ok' <<<"$out" && grep -qE '9\. stamp: would run lint/test \(full\) in \.wt/item-v1\.0\.3$' <<<"$out" &&
	ok "tier: land --dry-run accepts a fast stamp at the tip and plans a full stamp" || bad "tier land dry fast" "$out"
tstamp --tier full >/dev/null && tstamp >/dev/null
out=$("$PO" -C "$TR" --manifest "$TM" land 1.0.3 --dry-run 2>&1)
grep -q '9\. stamp: not needed (gate-5\.txt names the tip)' <<<"$out" &&
	ok "tier: land --dry-run needs no stamp when a full stamp names the tip (a newer fast one notwithstanding)" || bad "tier land dry full" "$out"
rm -f "$TW/gate-5.txt" "$TW/gate-6.txt"
tstamp >/dev/null
: >"$TG/args"
printf 'Memory: nothing new learned\n' >"$TG/report.md"
"$PO" -C "$TR" --manifest "$TM" land record 1.0.3 --spec-met --by dante --report-file "$TG/report.md" >/dev/null 2>&1
out=$("$PO" -C "$TR" --manifest "$TM" land 1.0.3 2>&1)
code=$?
[[ $code == 0 && $(cat "$TG/args") == "$TG_FULL" ]] && git -C "$TR" rev-parse -q --verify refs/tags/v1.0.3 >/dev/null &&
	grep '"kind":"stamp"' "$ev" | tail -n 1 | grep -q '"agent":.*"tests":5,"load1"' &&
	ok "tier: po land runs the full tier (the manifest's default is fast) and closes on it" || bad "tier land (exit $code)" "$out"$'\n--- args\n'"$(cat "$TG/args")"

# 9: po release <N> --write wants a full stamp at main's tip in the main checkout.
out=$("$PO" -C "$TR" --manifest "$TM" release 1 --write 2>&1)
[[ $? == 6 && $out == *"release-1 needs a full stamp at $(git -C "$TR" rev-parse --short main): run po stamp --tier full in $TR"* ]] &&
	ok "tier: release --write refuses without a full stamp at main's tip" || bad "tier release refuse" "$out"
"$PO" -C "$TR" --manifest "$TM" stamp --tier full >/dev/null 2>&1
"$PO" -C "$TR" --manifest "$TM" stamp >/dev/null 2>&1
out=$("$PO" -C "$TR" --manifest "$TM" release 1 --write 2>&1)
code=$?
[[ $code == 0 ]] && grep -q '^### Setup after install' "$TR/CHANGELOG.md" &&
	ok "tier: release --write runs with a full stamp at main's tip (a newer fast one notwithstanding)" || bad "tier release ok" "$out"
git -C "$TR" checkout -q -- CHANGELOG.md
git -C "$TR" commit -q --allow-empty -m "admin: main moves on"
out=$("$PO" -C "$TR" --manifest "$TM" release 1 --write 2>&1)
[[ $? == 6 && $out == *'needs a full stamp at'* ]] && ok "tier: release --write refuses a full stamp of an older main tip" || bad "tier release stale" "$out"

# 10: the keys are checked: --tier fast needs [stamp.fast] command; tier is fast or full; the
# command names {selected}; po doctor offers the keys.
tier_manifest "$TG/nofast.toml" fast=0
out=$("$PO" -C "$TR" --manifest "$TG/nofast.toml" stamp --tier fast 2>&1)
[[ $? == 2 && $out == *'[stamp.fast] command is needed for the fast tier'* ]] && ok "tier: --tier fast without [stamp.fast] command is exit 2" || bad "tier no command" "$out"
out=$("$PO" -C "$TR" --manifest "$TG/nofast.toml" release 1 --write 2>&1)
[[ $out != *'needs a full stamp'* ]] && ok "tier: a project without [stamp] tier or [stamp.fast] releases as before" || bad "tier release not opted in" "$out"
tier_manifest "$TG/badtier.toml" tier=medium
expect "tier: [stamp] tier other than fast or full is exit 2" 2 'tier must be "fast" or "full"' -- -C "$TR" --manifest "$TG/badtier.toml" status
tier_manifest "$TG/nosel.toml" command="sh $TG/suite.sh"
expect "tier: [stamp.fast] command without {selected} is exit 2" 2 'command must contain \{selected\}' -- -C "$TR" --manifest "$TG/nosel.toml" status
expect "tier: --tier takes fast or full" 1 "stamp: --tier must be fast or full" -- -C "$TR" --manifest "$TM" stamp --tier half
out=$(HOME=$KH "$PO" doctor 2>&1)
adopter_block "$KH/ad1" | grep -q '^  adopt  *\[stamp\] tier$' && adopter_block "$KH/ad1" | grep -q '^  adopt  *\[stamp.fast\] command$' &&
	ok "tier: doctor offers [stamp] tier and [stamp.fast] command" || bad "tier doctor" "$out"

# ---- private test blocks (absent from a public snapshot) -------------------
# only_wanted <file>...: with --only, every private file named and, in turn,
# every file a wanted file's "# needs:" lines name, one repo-relative path per line.
only_wanted() {
	local -A seen=()
	local -a todo=("$@")
	local f n
	while ((${#todo[@]} > 0)); do
		f=${todo[0]}
		todo=("${todo[@]:1}")
		[[ -z ${seen[$f]:-} ]] || continue
		seen[$f]=1
		printf '%s\n' "$f"
		[[ $f == private/tests.d/* && -f $KITROOT/$f ]] || continue
		for n in $(head -n 30 "$KITROOT/$f" | sed -n 's/^# needs: //p'); do todo+=("$n"); done
	done
}
_want=''
((ONLY_SET == 0)) || _want=$(only_wanted "${ONLY[@]}")
for _t in "$KITROOT"/private/tests.d/*.sh; do
	((ONLY_SET == 0)) || grep -qxF "private/tests.d/${_t##*/}" <<<"$_want" || continue
	# shellcheck source=/dev/null
	[[ -f "$_t" ]] && source "$_t"
done

# ---- run end ---------------------------------------------------------------
printf '\nRUN-END %s %s %s\n' "$pass" "$fail" "$nblocks"
RUN_DONE=1
printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
