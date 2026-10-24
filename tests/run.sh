#!/usr/bin/env bash
# po-kit self-tests: small throwaway repositories under a temp dir.
# shellcheck disable=SC2015 # ok/bad always return 0, so "A && ok || bad" is a true if/else here
# Usage: tests/run.sh    (exit 0 when every case passes)
set -uo pipefail
# Hermetic: no inherited GIT_* variable (an exported GIT_DIR — a git hook
# sets one — would point every `git -C <fixture>` below at that repository,
# making fixture branches and commits there), and no user or system git
# config (signing, hooks, default branch).
for v in $(compgen -e | grep '^GIT_'); do unset "$v"; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

PO="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)/bin/po"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

ok() {
	pass=$((pass + 1))
	printf 'ok   %s\n' "$1"
}
bad() {
	fail=$((fail + 1))
	printf 'FAIL %s\n' "$1"
	[[ -n ${2:-} ]] && printf '%s\n' "$2" | sed 's/^/     /'
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
# "name=command"; COUNT_CMD overrides the test count command.
stamp_manifest() {
	local leg
	{
		printf '%s' "$GOOD_MANIFEST"
		printf '[gate]\ntest_count_cmd = "%s"\n' "${COUNT_CMD:-sh ./fake-test.sh 2>&1}"
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
grep -q 'gate-' <<<"${out%%Stamp (*}" && bad "report lists a stamp file as changed" || ok "stamp files are not in Files changed"
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
	python3 -I -c 'import json,sys,re; e=json.loads(sys.argv[1]); assert list(e)==["time","kind","item","project","result","agent","legs","detail"]; assert re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", e["time"]); assert e["legs"]==[{"name":n,"result":"pass"} for n in ("check","test","clippy","fmt")]' "$first" &&
	ok "events: a passing stamp logs time (UTC), kind, item, project, result and every leg" || bad "pass event" "$first"
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
rows=$(($(wc -l <<<"$out") - 1))
[[ $code == 0 && $rows == 10 ]] && head -1 <<<"$out" | grep -qE '^TIME +KIND +ITEM +PROJECT +RESULT +AGENT +LEGS$' &&
	ok "events: by default the table shows the last 10 events under a header" || bad "events table (exit $code, rows $rows)" "$out"
[[ $(wc -l <"$SLOG") -gt 10 ]] && out_all=$("$PO" -C "$S" --manifest "$TMP/s.toml" events --all 2>&1) &&
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
[[ $code == 4 ]] && ok "events: an unwritable log leaves a failing stamp's exit code at 4" || true
rmdir "$SLOG"
mv "$SLOG.keep" "$SLOG"
stamp_manifest "${STD_LEGS[@]}"
rm -f "$W"/gate-*.txt

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
block() { awk -v p="$1" '$1 == "adopter" { on = ($2 == p) } on' <<<"$out"; }
block "$KH/ad1" | grep -q '^  adopt  *\[hooks\] on_close$' && block "$KH/ad1" | grep -q '^  adopt  *\[layout\] owner_column$' &&
	ok "doctor lists the optional keys a manifest does not set" || bad "doctor adopt keys" "$out"
! block "$TMP/ad2" | grep -q 'owner_column' && block "$TMP/ad2" | grep -q '^  adopt  *\[hooks\] on_close$' &&
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
# real po events --json: one object per line, keys in this order
KEYS = ("time", "kind", "item", "project", "result", "agent", "legs", "detail")
with open(sys.argv[1], "w") as f:  # oldest first: the viewer must sort newest first
    for e in ev:
        f.write(json.dumps({k: e[k] for k in KEYS}, separators=(",", ":")) + "\n")
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
	[[ $(head -1 <<<"$out") == 200 && $(grep -c '<td><time' <<<"$out") == 10 && $(grep -c '^<tr ' <<<"$out") == 10 ]] &&
		ok "/ shows 10 rows after 12 events" || bad "/ rows" "$out"
	first=$(grep -m1 '^<tr ' <<<"$out")
	[[ $first == *1.11* && $first == *dev11* && $first == *demo* && $first == *stamp* && $first == *'class="r-pass"'* ]] &&
		ok "/ lists item, project, kind, result, agent and time, newest on top" || bad "/ newest row" "$first"
	[[ $out != *'>1.0<'* && $out != *'>1.1<'* && $out == *'>1.2<'* ]] &&
		ok "/ drops the two oldest events" || bad "/ cut" "$out"
	[[ $out == *'onclick="location=&apos;/all&apos;"'* || $out == *"onclick=\"location='/all'\""* ]] &&
		ok "each / row links to /all" || bad "row link" "$first"
	out=$(sv_req GET /all)
	[[ $(head -1 <<<"$out") == 200 && $(grep -c '^<tr ' <<<"$out") == 12 && $(grep -m1 '^<tr ' <<<"$out") == *1.11* && $out == *'<td>lint:pass test:pass</td>'* && $out == *'<td>lint:pass test:fail</td>'* ]] &&
		ok "/all lists all 12 events, newest on top, with legs" || bad "/all" "$out"
	out=$(sv_req GET /events.json)
	[[ $(head -1 <<<"$out") == 200 ]] &&
		[[ $(tail -n +2 <<<"$out" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print(len(d), d[0]["item"], d[-1]["item"])') == "12 1.11 1.0" ]] &&
		ok "/events.json serves all events, newest first" || bad "/events.json" "$out"
	out=$(sv_req GET /all)
	[[ $out == *'<script>alert'* ]] && bad "item name reached the page unescaped" "$out" ||
		{ [[ $out == *'&lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;&amp;'* && $out == *'&quot;&gt;&lt;img src=x&gt;'* ]] &&
			ok "every field is HTML-escaped (names are data, not markup)" || bad "escaping" "$out"; }
	[[ $out == *'<td>-</td>'* && $out == *'<td>open</td>'* && $out == *'&lt;b&gt;boom&lt;/b&gt;'* && $out != *'<b>boom'* ]] &&
		ok "item null shows -, kind shows, detail is escaped" || bad "null item, kind, detail" "$out"
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
python3 -I - "$SV/events-live.json" <<'PY'
import json, sys
e = {"time": "2026-10-24T00:00:00Z", "kind": "close", "item": "9.9", "project": "demo", "result": "pass", "agent": "x", "legs": [], "detail": ""}
open(sys.argv[1], "a").write(json.dumps(e) + "\n")
PY
out=$(sv_req GET /)
[[ $before == 12 && $(grep -m1 '^<tr ' <<<"$out") == *9.9* ]] &&
	ok "a new event shows on the next request, newest on top" || bad "live update" "$out"
# One JSON object per line is read as well as one array.
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

# ---- the desktop viewer (item N) -------------------------------------------
# The logic is lib/po/dashboard_core.py (no GTK); bin/po-dashboard draws it.
DB="$(dirname "$PO")/po-dashboard"
DBLIB="$(dirname "$PO")/../lib/po"
while IFS=$'\t' read -r status name detail; do
	[[ $status == ok ]] && ok "$name" || bad "$name" "$detail"
done < <(python3 -B -I - "$DBLIB" <<'PY'
import datetime, http.server, json, sys, threading
sys.path.insert(0, sys.argv[1])
import dashboard_core as c

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
check("dashboard css: the two variants differ", c.css("light") != c.css("dark"))
check("dashboard: contrast of black on white is 21", round(c.contrast("#000000", "#ffffff")) == 21)
PY
)

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
# --check prints the rows without a display (and needs no GTK).
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
out=$(python3 -B "$DB" --url "$CHK_URL" --check 2>&1)
[[ $(wc -l <<<"$out") == 10 ]] &&
	[[ $(head -1 <<<"$out") == "1.11 | demo | stamp | "* ]] && ok "po-dashboard --check prints the last 10 rows, newest first" || bad "dashboard check" "$out"
out=$(python3 -B "$DB" --url "$CHK_URL" --check --all 2>&1)
[[ $(wc -l <<<"$out") == 12 ]] && ok "po-dashboard --check --all prints every event" || bad "dashboard check all" "$out"
kill "$CHK_PID" 2>/dev/null
wait "$CHK_PID" 2>/dev/null
out=$(python3 -B "$DB" --url "http://127.0.0.1:1/" --check 2>&1)
[[ $? == 2 && $out == *'cannot reach'* ]] && ok "po-dashboard --check with an unreachable URL exits 2" || bad "dashboard check unreachable" "$out"
if python3 -c 'import gi; gi.require_version("Gtk", "4.0"); from gi.repository import Gtk' >/dev/null 2>&1; then
	if [[ -n ${DISPLAY:-}${WAYLAND_DISPLAY:-} ]]; then
		# UI smoke: the window comes up with data and saves a screenshot.
		python3 -I - "$SV/events.json" "$TMP/shot.png" "$DB" <<'PY' &&
import http.server, subprocess, sys, threading
body = open(sys.argv[1], "rb").read()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
threading.Thread(target=srv.serve_forever, daemon=True).start()
r = subprocess.run([sys.executable, sys.argv[3], "--url", "http://127.0.0.1:%d/" % srv.server_address[1], "--screenshot", sys.argv[2]], timeout=60)
sys.exit(r.returncode)
PY
			[[ -s $TMP/shot.png ]] && ok "po-dashboard opens, loads events and saves a screenshot" || bad "dashboard ui smoke"
	else
		ok "po-dashboard UI smoke skipped: no display"
	fi
else
	ok "po-dashboard UI smoke skipped: GTK 4 or PyGObject missing"
fi

printf '\n%s passed, %s failed\n' "$pass" "$fail"
((fail == 0))
