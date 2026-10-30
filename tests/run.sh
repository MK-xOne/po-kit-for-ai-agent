#!/usr/bin/env bash
# po-kit self-tests: small throwaway repositories under a temp dir.
# shellcheck disable=SC2015 # ok/bad always return 0, so "A && ok || bad" is a true if/else here
# shellcheck disable=SC2034 # RUN_DONE is read by the EXIT trap
# Usage: tests/run.sh    (exit 0 when every case passes)
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
# the raw value of [stamp] prepare.
stamp_manifest() {
	local leg
	{
		printf '%s' "$GOOD_MANIFEST"
		[[ -z ${PREPARE:-}${SLOW_AFTER:-} ]] || printf '[stamp]\n'
		[[ -z ${PREPARE:-} ]] || printf 'prepare = %s\n' "$PREPARE"
		[[ -z ${SLOW_AFTER:-} ]] || printf 'slow_after = %s\n' "$SLOW_AFTER"
		printf '[gate]\ntest_count_cmd = "%s"\n' "${COUNT_CMD:-sh ./fake-test.sh 2>&1}"
		[[ -z ${SENTINEL:-} ]] || printf 'run_sentinel = "required"\n'
		[[ -z ${TEST_FORMAT:-} ]] || printf 'test_format = "%s"\n' "$TEST_FORMAT"
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
expect "an unknown test_format is an error" 2 'test_format must be "libtest" or "pytest": nose' -- -C "$W" --manifest "$TMP/m.toml" stamp
printf '%s[gate]\ntest_format = "pytest"\ncommand = "true"\n' "$GOOD_MANIFEST" >"$TMP/m.toml"
expect "test_format is a known key" 2 "manifest has no 'gate.test_count_cmd'" -- -C "$W" --manifest "$TMP/m.toml" stamp

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
make_brepo() {
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
isnap() { git -C "$ID" for-each-ref; git -C "$ID" worktree list --porcelain; git -C "$ID" status --porcelain --ignored; git -C "$IW" status --porcelain --ignored; }
before=$(isnap; stat -c '%n %Y' "$IW"/*)
"$PO" -C "$ID" status --idle 1 >/dev/null 2>&1
after=$(isnap; stat -c '%n %Y' "$IW"/*)
[[ $before == "$after" ]] && ok "status --idle is read-only" || bad "idle wrote" "$after"
# A backlog conflict still wins: exit 3, not 8.
printf '| v1.0.3 | Third | DONE | backlog/v1.md |\n' >>"$ID/docs/BACKLOG.md"
git -C "$ID" commit -qam conflict
expect "a backlog conflict (3) outranks idle (8)" 3 'CONFLICTS' -- -C "$ID" status --idle 100

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
	python3 -I -c 'import json,sys,re; e=json.loads(sys.argv[1]); assert list(e)==["time","kind","item","project","result","agent","legs","seconds","detail"]; assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", e["time"]); assert [(l["name"],l["result"]) for l in e["legs"]]==[(n,"pass") for n in ("check","test","clippy","fmt")] and all(list(l)==["name","result","seconds"] for l in e["legs"])' "$first" &&
	ok "events: a passing stamp logs time (UTC), kind, item, project, result, every leg and the seconds taken" || bad "pass event" "$first"
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
	! grep -qx '    noisy line 20' <<<"$out" && [[ $(table <<<"$out" | head -2 | tail -1) == *'first:pass(0s) noisy:fail(0s) last:skip(0s)'* ]] &&
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
rm -f "$W"/gate-*.txt
stamp_manifest check=true "test=sleep 2; sh ./fake-test.sh"
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
tk=$(tail -1 "$SLOG")
python3 -I -c 'import json,sys; e=json.loads(sys.argv[1]); assert e["result"]=="pass"; assert e["legs"][1]["seconds"]>=2, e; assert e["seconds"]>=e["legs"][1]["seconds"]>=2, e; assert e["legs"][0]["seconds"]<2, e' "$tk" &&
	ok "time taken: a leg that sleeps 2 s records seconds >= 2 on the leg and on the run" || bad "stamp seconds" "$tk"
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events 2>&1)
[[ $(table <<<"$out" | sed -n 2p) =~ \ [0-9]+s\ +check:pass\([0-9]+s\)\ test:pass\([0-9]+s\)$ ]] &&
	ok "time taken: po events shows the run's time and each leg's seconds" || bad "events took" "$out"
rm -f "$W"/gate-*.txt
SLOW_AFTER=1 stamp_manifest check=true "test=sleep 2; sh ./fake-test.sh"
"$PO" -C "$W" --manifest "$TMP/s.toml" stamp >/dev/null 2>&1
out=$("$PO" -C "$S" --manifest "$TMP/s.toml" events 2>&1)
[[ $(table <<<"$out" | sed -n 2p) =~ \ [0-9]+s\ slow\ +check:pass ]] &&
	ok "time taken: slow_after = 1 marks the sleeping run with the word slow" || bad "events slow" "$out"
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
cat "$FAKE_EVENTS"
EOF
chmod +x "$SV/bin/po"

# sv_start [po serve args...]: sets SV_URL and SV_PID, or SV_URL empty.
sv_start() {
	: >"$SV/out"
	(cd "$SV/repo" && PATH="$SV/bin:$PATH" FAKE_EVENTS="$SV/events.json" exec "$PO" serve --port 0 "$@" >"$SV/out" 2>"$SV/err") &
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
      and "none in this range" in r.gate_runs_text(r.gate_runs([], 86400, _n)) and "none in this range" in r.first_try_text(r.first_try([], 86400, _n)) and "none in this range" in r.closed_text(r.closed([], 86400, _n)))
_o = r.gate_runs([_st("2026-10-25T12:10:00Z", agent="solo")], 86400, _n)
check("dashboard reports: one agent gives one row", _o["agents"] == ["solo"] and len(_o["series"]["solo"]) == 24 and r.layout_gate_runs(_o, 600)[0] > 0)
check("dashboard reports: busiest agent first, ties by name", r.gate_runs([_st("2026-10-25T12:10:00Z", agent="z"), _st("2026-10-25T12:11:00Z", agent="z"), _st("2026-10-25T12:12:00Z", agent="b"), _st("2026-10-25T12:13:00Z", agent="a")], 86400, _n)["agents"] == ["z", "a", "b"])
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
check("dashboard reports: the text alternative carries the numbers", "a 2 runs, 1 passed, 1 failed" in r.gate_runs_text(_g) and "a 67% of 3 items" in r.first_try_text(_f) and "3 in all; x 2; y 1" in r.closed_text(_c))
check("dashboard reports: reports() gives the five charts in order with text", [t for t, _d, _x in r.reports([], 86400, _n)] == list(c.REPORT_CHARTS) and all(x for _t, _d, x in r.reports([], 86400, _n)))
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
check("dashboard reports: cycle time rows run longest median first and the unit fits", [x["agent"] for x in _t["rows"]] == ["a", "b"] and _t["unit"] == "hour" and r.cycle_time([], 86400, _n) == {"rows": [], "unit": "minute"})
check("dashboard reports: cycle time counts a close only inside the range", r.cycle_time(_ct, 600, _n)["rows"] == [] and len(r.cycle_time(_ct, 3600, _n)["rows"]) == 1 and r.cycle_time([_st("2026-10-01T08:00:00Z", kind="open"), _st("2026-10-25T12:00:00Z", kind="close")], 86400, _n)["rows"][0]["n"] == 1)
check("dashboard reports: cycle time falls back to the close event's agent without a stamp", r.cycle_time([_st("2026-10-25T08:00:00Z", kind="open"), _st("2026-10-25T08:10:00Z", kind="close", agent="po")], 86400, _n)["rows"][0]["agent"] == "po")
_fl = r.failed_legs([_lg("2026-10-25T12:10:00Z", [("lint", "pass"), ("test", "fail")]), _lg("2026-10-25T12:20:00Z", [("test", "fail"), ("fmt", "fail")], result="fail"),
                     _lg("2026-10-25T11:10:00Z", [("test", "fail")]), _lg("2026-10-20T11:10:00Z", [("test", "fail")]), _st("2026-10-25T12:00:00Z"),
                     {"time": "2026-10-25T12:00:00Z", "legs": "junk"}], 86400, _n)
check("dashboard reports: failed legs count only failing legs, per name and hour", _fl["legs"] == ["test", "fmt"] and _fl["series"]["test"][-1] == 2 and _fl["series"]["test"][-2] == 1 and _fl["series"]["fmt"][-1] == 1 and _fl["total"] == 4 and _fl["hourly"])
_seven = r.failed_legs([_lg("2026-10-25T12:10:00Z", [("l%d" % i, "fail")] * (9 - i)) for i in range(8)], 86400, _n)
check("dashboard reports: past six leg names the rest group as other, last", len(_seven["legs"]) == 7 and _seven["legs"][-1] == "other" and _seven["legs"][:6] == ["l0", "l1", "l2", "l3", "l4", "l5"] and sum(_seven["series"]["other"]) == 3 + 2 and _seven["total"] == sum(9 - i for i in range(8)))
check("dashboard reports: failed legs bucket daily for 7 d and are empty without failures", r.failed_legs([_lg("2026-10-23T12:00:00Z", [("t", "fail")])], 7 * 86400, _n)["series"]["t"][-3] == 1 and r.failed_legs([_st("2026-10-25T12:00:00Z")], 86400, _n)["total"] == 0)
check("dashboard reports: the new charts' text alternatives carry the numbers", "a 2 items, median 3.0 h" in r.cycle_time_text(_t) and "4 in all; test 3; fmt 1" in r.failed_legs_text(_fl) and "none in this range" in r.cycle_time_text(r.cycle_time([], 86400, _n)) and "none in this range" in r.failed_legs_text(r.failed_legs([], 86400, _n)))
_cs = r.layout_cycle_time(_t, 640)[1] + r.layout_failed_legs(_fl, 640)[1] + r.layout_failed_legs(_seven, 640)[1]
check("dashboard reports: cycle time shows the median and n as text and boxes for each agent", any(s[0] == "text" and s[3] == "3.0 h  n=2" for s in _cs) and sum(1 for s in r.layout_cycle_time(_t, 640)[1] if s[0] == "rect" and s[5] == ("series", 0)) == 2)
check("dashboard reports: other is hatched muted, never one of the six colours", any(s[0] == "rect" and s[5] == "muted" and s[6] for s in r.layout_failed_legs(_seven, 640)[1]) and not any(s[0] == "rect" and s[5] == ("series", 6 % 6) and s[6] for s in r.layout_failed_legs(_seven, 640)[1]))
check("dashboard reports: new charts stay inside the width", all(s[1] >= 0 and s[1] + (s[3] if s[0] == "rect" else 0) <= 640 + 1e-6 for s in _cs if s[0] in ("rect", "line")))
check("dashboard reports: nice axis tops sit just above the value", [r.nice_max(v) for v in (0, 1, 3, 7, 11, 20, 21, 51, 101)] == [1, 1, 3, 8, 12, 20, 24, 60, 120])
_hid = r.gate_runs([_st("2026-10-25T12:10:00Z"), _st("2026-10-25T12:20:00Z", result="fail"), _st("2026-10-25T09:10:00Z", agent="b")], 86400, _n)
_hs = r.layout_gate_runs(_hid, 640)[1]
check("dashboard reports: gate runs draw only the hours with runs", len({round(s[1], 3) for s in _hs if s[0] == "rect" and s[5] == "pass" and s[3] > 20}) == 2 and sum(1 for s in _hs if s[0] == "text" and s[3] == "09") == 2)
check("dashboard reports: hidden empty hours are counted in a muted note", any(s[0] == "text" and s[3] == "22 empty hours hidden" and s[4] == "muted" for s in _hs) and not any(s[0] == "text" and "hidden" in s[3] for s in r.layout_gate_runs(r.gate_runs([_st("2026-10-25T%02d:10:00Z" % h) for h in range(13)] + [_st("2026-10-24T%02d:10:00Z" % h) for h in range(13, 24)], 86400, _n), 640)[1]))
check("dashboard reports: gate runs label every bar with its count above and its hour below, in every row", sum(1 for s in _hs if s[0] == "text" and s[3] == "12") == 2 and sorted(s[3] for s in _hs if s[0] == "text" and s[4] == "text" and s[5] == "middle") == ["1", "2"])
check("dashboard reports: gate runs say what a bar is", any(s[0] == "text" and s[3] == "each bar = one hour" for s in _hs) and any(s[0] == "text" and s[3] == "each bar = one day" for s in r.layout_gate_runs(r.gate_runs([_st("2026-10-23T12:00:00Z")], 7 * 86400, _n), 640)[1]))
_cl = r.layout_closed(_c, 640)[1]
check("dashboard reports: closed per day hides empty days, labels bars and says how many were hidden", any(s[0] == "text" and s[3] == "each bar = one day" for s in _cl) and not any(s[0] == "text" and "hidden" in s[3] for s in _cl)
      and any(s[0] == "text" and s[3] == "29 empty days hidden" for s in r.layout_closed(r.closed([_st("2026-10-25T01:00:00Z", kind="close")], 30 * 86400, _n), 640)[1])
      and any(s[0] == "text" and s[3] == "1 empty day hidden" for s in r.layout_closed(r.closed([_st("2026-10-25T01:00:00Z", kind="close")], 86400, _n), 640)[1]))
_fh = r.layout_failed_legs(r.failed_legs([_lg("2026-10-25T12:10:00Z", [("t", "fail")])], 86400, _n), 640)[1]
check("dashboard reports: failed legs hide empty hours, label the bar and count it above", any(s[0] == "text" and s[3] == "23 empty hours hidden" for s in _fh) and any(s[0] == "text" and s[3] == "12" and s[5] == "middle" and s[4] == "muted" for s in _fh) and any(s[0] == "text" and s[3] == "1" and s[4] == "text" for s in _fh))
check("dashboard reports: charts with nothing to draw stay empty", all(r.layout_gate_runs(r.gate_runs([], 86400, _n), 640)[0] > 0 and not any(s[0] == "rect" and s[5] in ("pass", "fail") and s[3] > 20 for s in r.layout_gate_runs(r.gate_runs([], 86400, _n), 640)[1]) for _ in (0,)) and r.layout_closed(r.closed([], 86400, _n), 640)[0] > 0 and r.layout_failed_legs(r.failed_legs([], 86400, _n), 640)[0] > 0)
_tall = r.layout_closed(r.closed([_st("2026-10-25T%02d:00:00Z" % h, kind="close", item=str(h)) for h in range(11)], 86400, _n), 640)[1]
check("dashboard reports: the axis top is the closer round step above the tallest bar", any(s[0] == "text" and s[3] == "12" and s[4] == "muted" and s[5] == "end" for s in _tall))
_shapes = r.layout_gate_runs(_g, 640)[1] + r.layout_first_try(_f, 640)[1] + r.layout_closed(_c, 640)[1]
check("dashboard reports: fail is hatched, pass solid, so colour is not the only cue", any(s[0] == "rect" and s[5] == "fail" and s[6] for s in _shapes) and any(s[0] == "rect" and s[5] == "pass" and not s[6] for s in _shapes))
check("dashboard reports: first-try rows carry the share and n as text", any(s[0] == "text" and s[3] == "67%  n=3" for s in r.layout_first_try(_f, 640)[1]))
check("dashboard reports: shapes stay inside the width", all(s[1] >= 0 and s[1] + (s[3] if s[0] == "rect" else 0) <= 640 + 1e-6 for s in r.layout_gate_runs(_g, 640)[1] + r.layout_closed(_c, 640)[1] if s[0] in ("rect", "line")))
_many = r.closed([_st("2026-10-25T01:00:00Z", kind="close", project="p%d" % i) for i in range(8)], 86400, _n)
check("dashboard reports: a project past the palette reuses a colour hatched", r.series_colour(0) == (("series", 0), False) and r.series_colour(6) == (("series", 0), True) and len(r.layout_closed(_many, 400)[1]) > 8)
for _v, _p in sorted(c.PALETTES.items()):
    _lo = min(c.contrast(x, _p["base"]) for x in _p["series"] + [_p["pass"], _p["fail"]])
    check("dashboard reports %s: chart colours reach 3:1 against the base (%.2f)" % (_v, _lo), _lo >= 3 and len(_p["series"]) == r.SERIES_COLOURS)
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
check("dashboard team: LIMIT wins over WORKING and FREE", lr["kind"] == "limit" and lr["status"] == "LIMIT until 13:30")
check("dashboard team: LIMIT shows the viewer's local time", c.team_row(lim, NOW, dt.timezone.utc)["status"] == "LIMIT until 18:30")
check("dashboard team: LIMIT on another day shows the date", c.team_row(dict(lim, limit_until="2030-05-02T03:00:00Z"), NOW, EST)["status"] == "LIMIT until 22:00" and c.team_row(dict(lim, limit_until="2030-05-02T12:00:00Z"), NOW, EST)["status"] == "LIMIT until 2030-05-02 07:00")
for name, v in (("null", None), ("absent", "ABSENT"), ("past", "2030-05-01T13:00:00Z"), ("unparseable", "soon"), ("non-string", 5)):
    e = {"agent": "a", "state": "idle 3h", "free": True}
    if v != "ABSENT":
        e["limit_until"] = v
    check("dashboard team: a %s limit_until is no limit" % name, c.team_row(e, NOW, EST)["status"] == "FREE")
check("dashboard team: usage is shown as muted percentages", c.team_row({"usage": {"five_hour": 0.42, "seven_day": 0.185}})["usage"] == "5h 42% \u00b7 7d 18%")
check("dashboard team: only the usage parts present are shown", c.team_row({"usage": {"seven_day": 1}})["usage"] == "7d 100%" and c.team_row({"usage": {"five_hour": 0}})["usage"] == "5h 0%")
check("dashboard team: no, empty or bad usage shows nothing", all(c.team_row({"usage": u})["usage"] == "" for u in (None, {}, [], "x", {"five_hour": "a", "seven_day": 2}, {"five_hour": True, "seven_day": -1})) and c.team_row({})["usage"] == "")
check("dashboard team: a check line shows LIMIT and usage", c.team_check_lines([dict(lim, usage={"five_hour": 1, "seven_day": 0.5})], NOW, EST) == ["a | LIMIT until 13:30 (5h 100% \u00b7 7d 50%) | now: - | owns: -"])
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
check("dashboard decisions: short_title cuts at 80 and keeps short text", c.short_title("x" * 100) == "x" * 80 and c.short_title("abc") == "abc" and c.short_title(None) == "")
check("dashboard decisions: a long title is cut in the row", len(c.decision_row({"title": "y" * 120}, now)["title"]) == 80)
check("dashboard decisions: check lines show kind item project title waiting asked and the URL when there is one",
      c.decision_check_lines(dec[:2], now, utc) == ["legacy | 2.3 | orchard | Pick a format | waiting for: a ruling | asked 3h ago (2026-10-24 09:00:00) | https://chat.example.org/t/1",
                                                   "legacy | 0.7 | harbor | Accept the screen | waiting for: an acceptance | asked 30m ago (2026-10-24 11:30:00)"])
check("dashboard decisions: the feed is never changed", [e["item"] for e in dec] == ["2.3", "0.7", "2.5"])
ex = c.parse_decisions(open(sys.argv[1] + "/../../examples/decisions-feed.json").read())
check("dashboard decisions: the example feed parses, with and without a thread URL",
      len(ex) == 4 and all(k in e for e in ex for k in ("project", "item", "title", "waiting_for", "asked_at")) and sorted(bool(r["thread_url"]) for r in c.decision_rows(ex)) == [False, False, True, True])
# v0.36: kinds, group order, the Actions filter.
CH = {"kind": "choice", "id": "a1", "question": "Approve?", "options": [{"label": "Yes", "recommended": True}, {"label": "No", "description": "back to spec"}]}
AC = {"kind": "action", "id": "a2", "machine": "host", "steps": [{"text": "restart", "command": "systemctl restart x"}, {"text": "look"}], "done_when": "it is up"}
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
      ar["kind"] == "action" and ar["machine"] == "host" and ar["steps"] == [{"n": 1, "text": "restart", "command": "systemctl restart x"}, {"n": 2, "text": "look", "command": ""}] and ar["done_when"] == "it is up")
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
    return dict(AC, id="id-" + item, project=project, item=item, asked_at=at, steps=[{"text": "look at the sidebar"}], **({"requires": req} if req else {}))
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
_check_entry_action = {"id": "ask-0205", "project": "orchard", "item": "2.5", "kind": "action", "machine": "m", "done_when": "d", "steps": [{"text": "s", "command": ""}]}
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
_FIELDS = {"answer_id", "id", "project", "item", "kind", "option", "text", "result", "step", "note", "answered_at", "client"}
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
        code = int(self.path[1:])
        if code == 401 and token:
            self.send_response(201)  # a bearer token is accepted
        else:
            self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()
    def log_message(self, *a):
        pass
asrv = http.server.HTTPServer(("127.0.0.1", 0), AnswerH)
threading.Thread(target=asrv.serve_forever, daemon=True).start()
abase = "http://127.0.0.1:%d" % asrv.server_address[1]
ab = c.answer_body(_check_entry_choice, "5acd8b6f-ac7e-4fd1-91b6-8e5c7adfcd96", option="Yes", text="")
check("dashboard answers: 201 is answered · sent", c.post_answer(abase + "/201", ab) == "answered \u00b7 sent")
check("dashboard answers: 200 is answered · sent", c.post_answer(abase + "/200", ab) == "answered \u00b7 sent")
check("dashboard answers: 409 is already answered", c.post_answer(abase + "/409", ab) == "already answered")
check("dashboard answers: 404 is no longer waiting", c.post_answer(abase + "/404", ab) == "no longer waiting")
check("dashboard answers: 401 without a token is refused", c.post_answer(abase + "/401", ab).startswith("refused by"))
check("dashboard answers: 401 with a token is answered · sent", c.post_answer(abase + "/401", ab, token="secret") == "answered \u00b7 sent")
check("dashboard answers: 500 is not sent", c.post_answer(abase + "/500", ab).startswith("not sent:"))
check("dashboard answers: the POST waits up to 20 s", c.ANSWER_TIMEOUT == 20)
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
        ratio = c.contrast(props[fg]["color"], props[bg]["background-color"])
        check("dashboard css %s: %s has contrast >= 4.5 (%.2f)" % (variant, role, ratio), ratio >= 4.5)
    check("dashboard css %s: cards and toggle are raised, a pressed toggle is inset" % variant,
          "inset" not in props[".po-card"]["box-shadow"] and "inset" not in props[".po-toggle"]["box-shadow"]
          and "inset" in props[".po-toggle:checked"]["box-shadow"])
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
            ratio = c.contrast(props[".po-fade-%d .%s" % (n, cls)]["color"], bg)
            check("dashboard fade css %s: %s keeps contrast >= 4.5 at step %d (%.2f)" % (variant, cls, n, ratio), ratio >= 4.5)
    worst = min(c.contrast(props[".po-fade-%d .%s" % (n, cls)]["color"], props[".po-card.po-fade-%d" % n]["background-color"])
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
        ratio = c.contrast(col, start)
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
check("dashboard: contrast of black on white is 21", round(c.contrast("#000000", "#ffffff")) == 21)
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
      c.project_counts(st("TODO", "DOING", "PAUSED", "BLOCKED", "DONE", "HELD", "", "weird")) == {"todo": 1, "doing": 3, "done": 1})
check("dashboard projects: an empty or missing item list counts zero", c.project_counts([]) == c.project_counts(None) == {"todo": 0, "doing": 0, "done": 0})
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
check("dashboard projects: the list given is not changed", [x["item"] for x in fi] == list("abcdef"))
pf = c.parse_projects(open(sys.argv[1] + "/../../examples/projects-feed.json").read())
pcl = c.project_check_lines(pf, datetime.datetime(2026, 10, 26, 1, 10, 0, tzinfo=utc))
check("dashboard projects: the example feed has one project per light, items in every status",
      [l.split(" | ")[1] for l in pcl] == ["active", "idle", "inactive"] and {i["status"] for p in pf for i in p["items"]} >= {"TODO", "DOING", "PAUSED", "HELD", "DONE"})
check("dashboard projects: the example's DONE agents are in order", [i["agents"] for i in pf[0]["items"] if i["status"] == "DONE"] == [["dee", "cy", "ana"]])
check("dashboard projects: --check prints name, light and todo/doing/done", pcl[0] == "orchard | active | 1/1/1" and pcl[1] == "harbor | idle | 0/1/0")
_pn = datetime.datetime(2026, 10, 26, 1, 10, 0, tzinfo=utc)
_st0 = c.project_view_state()
check("dashboard project screen: the state starts on the overview with no filters", _st0 == {"open": None, "filters": {}})
_st1 = c.project_state_open(_st0, "orchard")
check("dashboard project screen: opening a project records it and leaves the old state alone", _st1["open"] == "orchard" and _st0["open"] is None)
check("dashboard project screen: back returns to the overview", c.project_state_back(_st1)["open"] is None)
check("dashboard project screen: the filter starts at All", c.project_state_filter(_st1, "orchard") == "all")
_st2 = c.project_state_set_filter(_st1, "orchard", "DOING")
check("dashboard project screen: a filter choice is kept for that project only", c.project_state_filter(_st2, "orchard") == "doing" and c.project_state_filter(_st2, "harbor") == "all")
check("dashboard project screen: the filter survives back and reopening", c.project_state_filter(c.project_state_open(c.project_state_back(_st2), "orchard"), "orchard") == "doing")
check("dashboard project screen: an unknown filter reads as All", c.project_state_filter(c.project_state_set_filter(_st1, "orchard", "bogus"), "orchard") == "all")
check("dashboard project screen: a refresh keeps the open project and filter while it is in the feed", c.project_state_reconcile(_st2, pf) == _st2)
_gone = c.project_state_reconcile(_st2, pf[1:])
check("dashboard project screen: a project that left the feed returns to the overview and drops its filter", _gone["open"] is None and _gone["filters"] == {})
check("dashboard project screen: no feed yet keeps nothing open", c.project_state_reconcile(_st2, None)["open"] is None)
_ps = c.project_screen(pf[0], "all", _pn)
check("dashboard project screen: the header has the name and the light in words", _ps["name"] == "orchard" and _ps["light"] == "active" and "active" in _ps["text"])
check("dashboard project screen: filter buttons are All, TODO, DOING, DONE with their counts", [(f["label"], f["count"]) for f in _ps["filters"]] == [("All", 3), ("TODO", 1), ("DOING", 1), ("DONE", 1)])
check("dashboard project screen: HELD counts in All only", [(f["label"], f["count"]) for f in c.project_screen(pf[1], "all", _pn)["filters"]] == [("All", 2), ("TODO", 0), ("DOING", 1), ("DONE", 0)])
check("dashboard project screen: rows are in the feed's order with id, title and status badge", [(r["item"], r["title"], r["status"]) for r in _ps["rows"]] == [("3.1", "Plant", "TODO"), ("3.2", "Water", "DOING"), ("3.3", "Harvest", "DONE")])
check("dashboard project screen: TODO lists the agents that could take it", _ps["rows"][0]["agents"] == ["ana", "ben"] and not _ps["rows"][0]["live"])
check("dashboard project screen: DOING marks the current agent live", _ps["rows"][1]["agents"] == ["cy"] and _ps["rows"][1]["live"])
check("dashboard project screen: DONE lists every agent in the feed's order, not live", _ps["rows"][2]["agents"] == ["dee", "cy", "ana"] and not _ps["rows"][2]["live"])
check("dashboard project screen: no agent is a muted dash", c.project_screen(pf[1], "all", _pn)["rows"][1]["dash"] and not _ps["rows"][0]["dash"])
check("dashboard project screen: a DOING row with no agent is not live", not c.project_screen({"project": "p", "items": [{"item": "1", "status": "DOING", "agents": []}]}, "all", _pn)["rows"][0]["live"])
check("dashboard project screen: the filter narrows the rows, counts stay", [r["item"] for r in c.project_screen(pf[0], "done", _pn)["rows"]] == ["3.3"] and c.project_screen(pf[0], "done", _pn)["filters"][0]["count"] == 3)
check("dashboard project screen: PAUSED shows under DOING", [r["item"] for r in c.project_screen(pf[1], "doing", _pn)["rows"]] == ["1.4"])
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
check("dashboard projects: a card carries name, light and the three counts", _pc["name"] == pf[0]["project"] and _pc["light"] in ("active", "idle", "inactive") and sorted(_pc["counts"]) == ["doing", "done", "todo"])
_pl = {"project": "p", "last_event": "2026-10-26T11:50:00Z", "items": [{"item": "1", "status": "TODO"}, {"item": "2", "status": "DOING"}, {"item": "3", "status": "DONE"}, {"item": "4", "status": "DONE"}]}
check("dashboard projects: the card text names the light in words, not only colour", c.project_card(_pl, pnow)["text"] == "p, active, TODO 1, DOING 1, DONE 2")
check("dashboard projects: the card text names an idle and an inactive light too", ", idle," in c.project_card(dict(_pl, last_event="2026-10-26T01:00:00Z"), pnow)["text"] and ", inactive," in c.project_card(dict(_pl, last_event=None), pnow)["text"])
check("dashboard projects: a card for an entry with no items counts zero", c.project_card({"project": "q"}, pnow)["text"] == "q, inactive, TODO 0, DOING 0, DONE 0")
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
print("BLOCK-END dashboard-core")
PY

grep -q 'sort by %s' "$DB" && grep -q 'Gtk.Button' "$DB" && ok "po-dashboard headers are buttons labelled sort by <column>" || bad "dashboard header buttons"
# bin/po-dashboard: argument handling needs no display.
out=$(env -u PO_DASHBOARD_URL python3 -B "$DB" 2>&1)
[[ $? == 1 && $out == *'no URL'* && $out == *PO_DASHBOARD_URL* ]] &&
	ok "po-dashboard without a URL is a usage error naming --url and PO_DASHBOARD_URL" || bad "dashboard no url" "$out"
out=$(python3 -B "$DB" --url ftp://h/x 2>&1)
[[ $? == 1 && $out == *'not an http'* ]] && ok "po-dashboard refuses a non-http URL" || bad "dashboard bad url" "$out"
out=$(python3 -B "$DB" --theme neon --url http://h/x 2>&1)
[[ $? == 2 && $out == *'--theme'* ]] && ok "po-dashboard rejects an unknown theme" || bad "dashboard theme" "$out"
out=$(python3 -B "$DB" --size 10x10 --url http://h/x 2>&1)
[[ $? == 2 && $out == *'--size'* ]] && ok "po-dashboard rejects a window size below 200" || bad "dashboard size" "$out"
# --team-url: a bad value is a usage error; --check prints the team lines after the events.
out=$(python3 -B "$DB" --url http://h/x --team-url ftp://h/x 2>&1)
[[ $? == 1 && $out == *'not an http'* ]] && ok "po-dashboard refuses a non-http team URL" || bad "dashboard team url" "$out"
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
out=$(PO_DASHBOARD_TEAM_URL="$TMP/team.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -2 <<<"$out" | head -1) == "ada | WORKING | now: 1.4 | owns: 1.4" && $(tail -1 <<<"$out") == "cy | FREE | now: - | owns: -" ]] &&
	ok "po-dashboard --check lists the team after the events when a team feed is set" || bad "dashboard check team" "$out"
printf '[{"agent":"ada","state":"WORKING","owns":[],"usage":{"five_hour":0.5}},{"agent":"cy","state":"idle 3h","free":true,"limit_until":"2099-01-01T12:00:00Z","usage":{"seven_day":0.25}}]\n' >"$TMP/team-limit.json"
out=$(TZ=UTC PO_DASHBOARD_TEAM_ORDER="$TMP/none-order.json" PO_DASHBOARD_TEAM_URL="$TMP/team-limit.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -2 <<<"$out" | head -1) == "ada | WORKING (5h 50%) | now: - | owns: -" && $(tail -1 <<<"$out") == "cy | LIMIT until 2099-01-01 12:00 (7d 25%) | now: - | owns: -" ]] &&
	ok "po-dashboard --check shows LIMIT in local time and usage when present" || bad "dashboard check limit" "$out"
printf '{"order": ["cy"]}\n' >"$TMP/team-order.json"
out=$(PO_DASHBOARD_TEAM_ORDER="$TMP/team-order.json" PO_DASHBOARD_TEAM_URL="$TMP/team.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -2 <<<"$out" | head -1) == "cy | FREE | now: - | owns: -" && $(tail -1 <<<"$out") == "ada | WORKING | now: 1.4 | owns: 1.4" ]] &&
	ok "po-dashboard --check applies the saved team order" || bad "dashboard check team order" "$out"
out=$(PO_DASHBOARD_TEAM_URL="$TMP/none.json" python3 -B "$DB" --url "$CHK_URL" --team-url "$TMP/team.json" --check 2>&1)
[[ $out == *'team:'* ]] && ok "po-dashboard --team-url wins over PO_DASHBOARD_TEAM_URL" || bad "dashboard team precedence" "$out"
out=$(env -u PO_DASHBOARD_TEAM_URL python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $out != *'team:'* ]] && ok "po-dashboard --check without a team feed prints no team section" || bad "dashboard no team" "$out"
# --decisions-url: no default; --check prints the decisions, oldest asked first, after the events (and team).
printf '[{"project":"harbor","item":"0.7","title":"Accept","waiting_for":"an acceptance","asked_at":"2026-10-24T11:30:00Z"},{"project":"orchard","item":"2.3","title":"Pick","waiting_for":"a ruling","asked_at":"2026-10-24T09:00:00Z","thread_url":"https://chat.example.org/t/1"}]\n' >"$TMP/decisions.json"
out=$(python3 -B "$DB" --url http://h/x --decisions-url ftp://h/x 2>&1)
[[ $? == 1 && $out == *'not an http'* ]] && ok "po-dashboard refuses a non-http decisions URL" || bad "dashboard decisions url" "$out"
out=$(python3 -B "$DB" --url http://h/x --view bogus 2>&1)
[[ $? -ne 0 && $out == *"invalid choice"* ]] && ok "po-dashboard --view accepts reports and rejects an unknown view" || bad "dashboard view bogus" "$out"
out=$(env -u PO_DASHBOARD_DECISIONS_URL python3 -B "$DB" --url http://h/x --view decisions 2>&1)
[[ $? == 1 && $out == *'--decisions-url'* && $out == *PO_DASHBOARD_DECISIONS_URL* ]] &&
	ok "po-dashboard --view decisions without a decisions feed is a usage error" || bad "dashboard view decisions" "$out"
out=$(env -u PO_DASHBOARD_PROJECTS_URL python3 -B "$DB" --url http://h/x --view projects 2>&1)
[[ $? == 1 && $out == *'--projects-url'* && $out == *PO_DASHBOARD_PROJECTS_URL* ]] &&
	ok "po-dashboard --view projects without a projects feed is a usage error" || bad "dashboard view projects" "$out"
grep -q 'Gtk.AccessibleProperty.LABEL\], \[c\["text"\]' "$DB" && grep -q 'set_tooltip_text(c\["text"\])' "$DB" && ok "po-dashboard Projects cards carry the light in tooltip and accessible label" || bad "dashboard projects label"
out=$(PO_DASHBOARD_DECISIONS_URL="$TMP/decisions.json" PO_DASHBOARD_TEAM_URL="$TMP/team.json" python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(tail -3 <<<"$out" | head -1) == "decisions:" && $(tail -2 <<<"$out" | head -1) == "legacy | 2.3 | orchard | Pick | waiting for: a ruling | asked "*" | https://chat.example.org/t/1" &&
	$(tail -1 <<<"$out") == "legacy | 0.7 | harbor | Accept | waiting for: an acceptance | asked "* && $out == *'team:'* ]] &&
	ok "po-dashboard --check lists the decisions, oldest asked first, after the events and the team" || bad "dashboard check decisions" "$out"
out=$(XDG_CONFIG_HOME="$TMP/cfg" python3 -B "$DB" --url "$CHK_URL" --decisions-url "$(dirname "$PO")/../examples/decisions-feed.json" --check 2>&1)
[[ $(tail -4 <<<"$out" | head -1) == "choice | 0.7 | harbor |"* && $(tail -3 <<<"$out" | head -1) == "action | 2.5 | orchard |"* &&
	$(tail -2 <<<"$out" | head -1) == "legacy | 2.3 |"* && $(tail -1 <<<"$out") == "unformatted | 0.8 |"* ]] &&
	ok "po-dashboard --check prints the kind first, choices, actions, then legacy and unformatted" || bad "dashboard check kinds" "$out"
mkdir -p "$TMP/cfg/po-dashboard" && echo '{"actions": false}' >"$TMP/cfg/po-dashboard/decisions.json"
out2=$(XDG_CONFIG_HOME="$TMP/cfg" python3 -B "$DB" --url "$CHK_URL" --decisions-url "$(dirname "$PO")/../examples/decisions-feed.json" --check 2>&1)
[[ $out2 == "$out" ]] && ok "po-dashboard --check ignores the Actions filter" || bad "dashboard check filter" "$out2"
# v0.69: --install-dir / PO_DASHBOARD_INSTALL_DIR; --check prints the Install block after the decisions.
sha=$(printf '%064d' 0)
printf '[{"project":"orchard","item":"1.9.39","title":"Look","waiting_for":"a look","asked_at":"2026-10-29T10:00:00Z","kind":"action","id":"i1","machine":"laptop","steps":[{"text":"open it"}],"done_when":"seen","requires":{"package":"a-1-x86_64.pkg.tar.zst","sha256":"%s"}}]\n' "$sha" >"$TMP/install.json"
out=$(env -u PO_DASHBOARD_INSTALL_DIR python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/install.json" --install-dir /x/pkgs --check 2>&1)
[[ $(tail -3 <<<"$out") == "install | orchard | a-1-x86_64.pkg.tar.zst
install | orchard | cd /x/pkgs && sha256sum -c <<< '$sha  a-1-x86_64.pkg.tar.zst'
install | orchard | sudo pacman -U /x/pkgs/a-1-x86_64.pkg.tar.zst" ]] &&
	ok "po-dashboard --check prints the Install block from --install-dir after the decisions" || bad "dashboard check install" "$out"
out=$(PO_DASHBOARD_INSTALL_DIR=/y python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/install.json" --check 2>&1)
[[ $(tail -1 <<<"$out") == "install | orchard | sudo pacman -U /y/a-1-x86_64.pkg.tar.zst" ]] && ok "po-dashboard reads PO_DASHBOARD_INSTALL_DIR" || bad "dashboard install env" "$out"
out=$(env -u PO_DASHBOARD_INSTALL_DIR python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/install.json" --check 2>&1)
[[ $(tail -1 <<<"$out") == "install | orchard | set install_dir" ]] && ok "po-dashboard without install_dir shows set install_dir and no command" || bad "dashboard install unset" "$out"
out=$(python3 -B "$DB" --url http://h/x --install-dir pkgs --check 2>&1)
[[ $? == 1 && $out == *'install_dir is not an absolute plain path'* ]] && ok "po-dashboard refuses a relative --install-dir" || bad "dashboard install relative" "$out"
out=$(PO_DASHBOARD_DECISIONS_URL="$TMP/none.json" python3 -B "$DB" --url "$CHK_URL" --decisions-url "$TMP/decisions.json" --check 2>&1)
[[ $out == *'decisions:'* ]] && ok "po-dashboard --decisions-url wins over PO_DASHBOARD_DECISIONS_URL" || bad "dashboard decisions precedence" "$out"
out=$(env -u PO_DASHBOARD_DECISIONS_URL python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $out != *'decisions:'* ]] && ok "po-dashboard --check without a decisions feed prints no decisions section" || bad "dashboard no decisions" "$out"
out=$(python3 -B "$DB" --url "$CHK_URL" --decisions-url "http://127.0.0.1:1/" --check 2>&1)
[[ $? == 2 && $out == *'cannot reach'* ]] && ok "po-dashboard --check with an unreachable decisions feed exits 2" || bad "dashboard check decisions unreachable" "$out"
# --answer-url: http(s) only; none is read-only (no error); flag wins over env.
out=$(python3 -B "$DB" --url "$CHK_URL" --answer-url ftp://h/x --check 2>&1)
[[ $? == 1 && $out == *'not an http'* ]] && ok "po-dashboard refuses a non-http answer URL" || bad "dashboard answer url" "$out"
out=$(PO_DASHBOARD_ANSWER_URL=ftp://h/x python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $? == 1 && $out == *'not an http'* ]] && ok "po-dashboard refuses a non-http PO_DASHBOARD_ANSWER_URL" || bad "dashboard answer url env" "$out"
out=$(PO_DASHBOARD_ANSWER_URL=ftp://h/x python3 -B "$DB" --url "$CHK_URL" --answer-url http://h/a --check 2>&1)
[[ $? == 0 && -n "$out" ]] && ok "po-dashboard --answer-url wins over PO_DASHBOARD_ANSWER_URL" || bad "dashboard answer precedence" "$out"
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
		out=$(timeout 60 python3 -I - "$DB" "$SV/events.json" "$(dirname "$PO")/../examples/projects-feed.json" 2>/dev/null <<'PY'
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
		# v0.58: an unsent answer draft survives the Decisions redraw (the feed refresh) and goes with its entry or its Send.
		cat >"$TMP/drafts-feed.json" <<'JSON'
[{"project":"p","item":"1","title":"c","waiting_for":"a ruling","asked_at":"2026-10-24T09:00:00Z","kind":"choice","id":"d-choice","question":"Ok?","options":[{"label":"Yes"},{"label":"No"}]},
 {"project":"p","item":"2","title":"t","waiting_for":"a ruling","asked_at":"2026-10-24T10:00:00Z","kind":"choice","id":"d-text"},
 {"project":"p","item":"3","title":"a","waiting_for":"a block","asked_at":"2026-10-24T11:00:00Z","kind":"action","id":"d-action","machine":"m","steps":[{"text":"one"},{"text":"two"}],"done_when":"done"}]
JSON
		# helper
		out=$(XDG_CONFIG_HOME="$TMP/xdg-drafts" timeout 60 python3 -I - "$DB" "$SV/events.json" "$TMP/drafts-feed.json" 2>/dev/null <<'PY'
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
		# v0.63: the Decisions toggle hides the choice cards and keeps the action cards; the choice is saved next to the Actions one.
		cat >"$TMP/toggle-feed.json" <<'JSON'
[{"project":"p","item":"1","title":"c","waiting_for":"a ruling","asked_at":"2026-10-24T09:00:00Z","kind":"choice","id":"t-choice","question":"Ok?","options":[{"label":"Yes"},{"label":"No"}]},
 {"project":"p","item":"3","title":"a","waiting_for":"a block","asked_at":"2026-10-24T11:00:00Z","kind":"action","id":"t-action","machine":"m","steps":[{"text":"one"},{"text":"two"}],"done_when":"done"}]
JSON
		# helper
		out=$(XDG_CONFIG_HOME="$TMP/xdg-toggle" timeout 60 python3 -I - "$DB" "$SV/events.json" "$TMP/toggle-feed.json" "$TMP/xdg-toggle" 2>&1 <<'PY'
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

# ---- private test blocks (absent from a public snapshot) -------------------
for _t in "$KITROOT"/private/tests.d/*.sh; do
	# shellcheck source=/dev/null
	[[ -f "$_t" ]] && source "$_t"
done

# ---- run end ---------------------------------------------------------------
printf '\nRUN-END %s %s %s\n' "$pass" "$fail" "$nblocks"
RUN_DONE=1
printf '%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
