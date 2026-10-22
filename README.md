# po-kit

`po` is a small command-line tool for running a software backlog one item at a
time, with a gate, evidence and a clean git history. It scripts the mechanical
parts of a gated, one-item-one-commit workflow, so the people and coding agents
working the backlog run instruments instead of re-deriving the procedure each
time: open an item in its own worktree, stamp the gate's result, check the
branch is fresh, close the item (fast-forward, tag, record), and prune.

It suits a workflow with a product owner (a person or an agent) who opens and
closes items, and developers (people or agents) who each work one item in its
own branch and worktree. It is opinionated: one item is one commit is one tag.

Three laws, non-negotiable:
- **Dry-run is the default mode, not a flag.** Nothing writes without
  `--commit`; a full dry-run pass leaves `git status --porcelain` empty.
- **Manifest-driven.** Everything project-specific lives in the adopting
  repo's `po.toml`; the same scripts serve every project.
- **Never pushes, never writes prose.** The only words the kit ever edits
  are an item's STATUS tokens, wherever the backlog keeps them: a table
  cell, a status word in backlog prose, or a spec heading's status word.
  Close records, rulings, founding text and decisions stay human.

## Why it saves tokens

An AI coding agent pays for its whole working context on every step it takes:
each tool call re-sends the conversation so far, typically tens of thousands of
tokens, while the command's own output is a few hundred. So what a workflow
costs is mostly the **number of steps**, not the size of each step.

Done by hand, the boundaries of an item are many small steps: check the branch,
compare it with main, run each gate leg, count the tests, edit the backlog, commit,
fast-forward, tag, remove the worktree, delete the branch. Each one is a model
round trip, and each is a chance to get something slightly wrong (a missed status,
a mistyped tag, a hand-copied test count), which costs more round trips to notice
and repair. po turns each boundary into one command plus its dry run, with the same
result every time, and refuses instead of half-doing. The agent spends its steps on
the item itself.

How much that saves depends on your agent, model and context size. To measure it
for your setup, run one boundary twice on throwaway clones, once with po and once
by hand from the same instructions, and compare the two sessions' token counts.

## Requirements

- Linux (or WSL). bash 4.4 or newer, GNU coreutils (`stat -c`, `readlink -f`,
  `sort -V`) and a recent git (tested with git 2.56). Nothing else: no network, no services.
- macOS is not supported yet: its stock bash 3.2 and BSD tools differ. With
  Homebrew's `bash` and `coreutils` first on `PATH` it may work, untested.
- `shellcheck` only to run the kit's own lint.

## Install

```sh
git clone https://github.com/MK-xOne/po-kit-for-ai-agent.git ~/src/po-kit
ln -s ~/src/po-kit/bin/po ~/.local/bin/po      # or: ~/src/po-kit/bin/po-install
po version
```

`bin/po-install [<tag>]` installs a tagged version in its own worktree and
points `~/.local/bin/po` at it, so work in progress on the kit's main branch
is never the live `po`.

## Quick start

1. Copy an example manifest to your repo root as `po.toml` and adjust it:
   `examples/rust.po.toml` (cargo) or `examples/python.po.toml` (pytest).
2. Keep a backlog table in `docs/BACKLOG.md` with an item column and a
   `Status` column (`TODO`, `DOING`, `DONE`, ...), and item specs whose
   headings read `## v1.2 — Title — STATUS` in `[layout] specs_dir`.
3. `po status` shows open items. `po open next "Title"` (dry run) shows what
   founding the next item would do; add `--commit` to do it. In the item's
   worktree, `po stamp` runs the gate and prints the evidence block;
   `po close <version> --commit` lands it.

## Usage

```sh
po [-C <repo>] [--manifest <file>] status [--idle <minutes>]
po [-C <repo>] [--manifest <file>] prune [--commit]
po [-C <worktree>] [--manifest <file>] stamp [--bin <path>]
po [-C <repo>] [--manifest <file>] fresh <version>
po [-C <worktree>] [--manifest <file>] report [--note <text>]...
po [-C <repo>] [--manifest <file>] open <version|next> [<title>] [--for <name>] [--epoch] [--body-file <f>] [--commit]
po [-C <repo>] [--manifest <file>] close <version> [--next <version> [--next-title <title>] [--for <name>]]
                                         [--also-done <version>]... [--body-file <f>] [--commit]
po [-C <repo>] [--manifest <file>] kickoff <version>
po version
po doctor
bin/po-install [<tag>]
```

The manifest defaults to `po.toml` at the root of the repository's main
worktree; `examples/` has two to start from. po always works from the
main worktree and reads the backlog as committed on `main`, so it answers
the same from any worktree.

- `[layout] owner_column` — an optional manifest key naming a backlog table
  column (`"Owner"`, matched exactly like `Status`). Absent, every command
  behaves as before, byte for byte. Set, the owner of an item is the cell of
  that column in its table row: `po open` and `po close --next` use it for
  the admin subject's `… for <owner>` when `--for` is absent, a `--for` that
  differs from a non-empty cell refuses with exit 3 and writes nothing, an
  empty cell with no `--for` names no owner, `po status` prints `owner
  <name>` under each DOING and held item, and `po kickoff` prints an `owner
  <name>` line. A table without that column gives no owner; a header naming
  it twice is an error (2); an empty `owner_column` is a manifest error (2).
- `po status` — DOING and held (PAUSED/BLOCKED) items from the backlog
  tables and the spec-file headings, each with its branch (ahead/behind
  main) and worktree (dirty count); the latest tag; orphaned and dirty
  worktrees; unmerged branches no open item claims. Exits 3 when the
  backlog's sources disagree about an item.
  Each DOING item's branch line ends in `idle 3h12m`: now minus the newest
  of the branch tip's commit date, the newest `gate-<n>.txt`, and the
  newest mtime among the worktree's changed and untracked files (`idle -`
  with no worktree). `--idle <minutes>` also lists the DOING items idle
  longer under `IDLE (n)` and exits 8 after printing everything; without
  it the exit codes are unchanged (3 outranks 8). Read-only.
- `po prune` — worktrees and branches merged into main, minus the main
  worktree, open items' branches, and anything dirty, locked or outside
  `[layout] worktrees` (each listed with its reason). `--commit` removes
  them with `git worktree remove` (never `--force`) and a compare-and-delete
  of each branch ref.
- `po stamp` — runs the gate in the current worktree (`[gate.legs]` in
  order, or `[gate] command` as one leg), then `test_count_cmd`, and
  prints the evidence block:

  ```
  HEAD <sha> (<branch>)  dirty <n>
  gate PASS: check/test/clippy/fmt   tests <n> passed
  diffstat vs merge-base(main): <summary>
  bin sha256 <hash> (<path>)        # with --bin
  ```

  The count is the sum of every libtest `test result: ok. N passed` line
  `test_count_cmd` prints, and must equal the gate's own when the gate
  prints any. The block is also written to `gate-<n>.txt` at the
  worktree root, `<n>` one past the highest there; nothing is ever
  overwritten. All or nothing: a failing leg (named), a missing or
  disagreeing count, a non-ok summary, or a worktree that changed while
  the gate ran exits 4 and writes no file. `dirty` and that last check
  ignore the stamp files themselves; don't commit them.

  With `[gate] test_format = "pytest"` (default `"libtest"`) the count is
  instead the `N passed` of the last pytest summary line the output has
  (`223 passed in 1.23s`, `== 3 passed, 1 skipped in 0.5s ==`), counted per
  leg and cross-checked the same way. A summary naming `failed` or
  `error`/`errors`, or no passed tests, exits 4; so does output with no
  pytest summary.
- `po fresh <version>` — the item branch (`[layout] branch`) against the
  local main: ahead/behind, the merge-base, and every main commit since
  it, oldest first, classed ADMIN (`admin_prefix`), ITEM vX
  (`item_commit` form) or OTHER, and marked RULING / RULES when it
  changes `[docs] decisions` / `rules`. Exit 0 and `FRESH` when main is an
  ancestor of the branch; exit 5 and `REBASE REQUIRED` when it is not.
  Read-only: it never fetches, rebases or writes. A remote-tracking main
  that differs from the local one is noted, not judged.
- `po close <version>` — the closing boundary. Pre-flight, all before any
  write: every backlog source says the item is DOING and none disagrees
  (else exit 3); its branch is exactly one item-form commit on main (6);
  `po fresh` passes (5); the newest `gate-<n>.txt` in its worktree names
  the branch tip, `dirty 0`, `gate PASS` (6); its tag is free (6). Then, with
  `--commit`: fast-forward main; a lightweight tag (written with
  `update-ref`, so `tag.gpgSign` never turns it into a signed one) or,
  with `[versioning] tag_style = "annotated"` (default `"light"`; any other
  value is a manifest error, exit 2), an annotated one (`git tag -a`, message
  `<tag>: <title>`, signing as the repo's git config says — po adds no `-s`;
  a tag that cannot be created stops the close there, naming what is owed),
  still create-only and at the item commit; the
  backlog edits as the `admin:` commit, author from git's own config, the
  stamp block quoted in its body (`--body-file` appends more); the
  `--next` item's branch and worktree at that commit; the closed item's
  stamp files, worktree (`git worktree remove`, never `--force`; kept and
  reported when it holds ignored files) and branch. `--next` takes a TODO
  item DOING, or with `--next-title` founds a new number (same law as
  `po open`); `--also-done` closes an investigation (DOING, no commits)
  in the same commit, with no merge and no tag.
- `[hooks] on_close` — an optional manifest command (`sh -c`) that
  `po close --commit` runs once the whole boundary is complete (ff, tag,
  admin, `--next`, prune), in the main worktree with stdin `/dev/null` and
  its output passed to stderr. Environment: `PO_HOOK=on_close`,
  `PO_VERSION`, `PO_TAG`, `PO_TITLE`, `PO_ITEM_COMMIT`, `PO_ADMIN_COMMIT`,
  `PO_DATE` (the admin commit's author date, ISO 8601), `PO_EVIDENCE` (a
  temporary file holding the stamp block, removed afterwards),
  `PO_BODY_FILE` and `PO_NEXT` (empty when not given), `PO_REPO`. A dry run
  lists the command and environment and runs nothing; a refusal or partial
  failure runs no hook. A non-zero exit warns and makes `po close` exit 7
  — the boundary stands, nothing is rolled back. No `[hooks]`, no change.
- `po report [--note <text>]...` — the item report, read-only, run in an
  item worktree. One markdown block: `<tag> report — <branch> at <short
  HEAD>`; `Files changed:` with a line per `git status` entry (code and path in backticks; stamp files left out) and, when the branch is ahead of main,
  the item commit's files marked `(committed)`; the newest `gate-<n>.txt`
  verbatim between fences; and `PROPOSED:` with each `--note` numbered, in
  order (the caller's words, passed through). Fresh stamp only: with no
  stamp, a newest one naming another HEAD or another dirty count, or any
  changed file newer than it, it exits 4 and prints nothing on stdout. It
  never runs the gate and posts nothing; the tag comes from the branch
  name via `[layout] branch`.
- `po open <version|next> [<title>]` — the founding boundary. A new number
  must be latest founded + 1 (`next`), an epoch step with `--epoch`
  (1.10.0, 2.0.0), or the next insert in the `insert_segment`-th segment
  under a founded item; its heading `## <tag> — <title> — DOING` goes into
  the spec file of the closest lower version, before the first higher
  heading. A number already founded TODO goes DOING. With `--commit`: the
  edits as the `admin:` commit, then the branch and worktree at it.
- `po kickoff <version>` — the mechanical half of a founding brief,
  read-only. The item's spec section verbatim from main, between
  `SPEC SECTION <file>:<a>-<b>` and `END SPEC SECTION`: from its heading
  to the next heading of the same or a higher level (fenced code is not
  read for headings). The heading is the `## <id> — …` one the backlog
  parser reads; failing that, in a table-shaped ledger, any heading
  naming `item <label>`, the label being a cell left of the id in the
  item's table row (`| E | v0.5 |` finds `### … (item E — …)`). Every
  matching heading is printed. Then the `[docs] rules` pointer (its blob
  on main), and every admin or ruling commit on main from the previous
  boundary — the highest tag below the item reachable from its founding —
  to its founding, the oldest first-parent commit where a backlog source
  says DOING; each line is `po fresh`'s for that commit. An item not yet
  DOING is listed to main's tip; an open one also lists what main gained
  since its founding. The judgment layer stays the PO's. Exit 2 when a
  source is missing: no spec section (a founding in progress), no
  `[docs] rules`, or one not on main.
- The backlog edits both make are status words only — a spec heading's
  status word, a table row's Status cell, the one status word after the
  item's id in BACKLOG prose (`v1.9.11 parser TODO` → `DOING`; a close
  writes `DONE (tag vX)`) — plus a founding heading line. Each is anchored
  on the id and the status it expects; two candidates, another status or a
  status wrapped onto the next line stop with exit 3. Prose (close records,
  rulings, founding text) stays the PO's. Without `--commit` both print the
  whole plan — steps, the edits as a diff, the admin message, `--commit`
  readiness — and change nothing. Exit 6: refused by the item law.

- `po version` — the tag this po-kit checkout is at (`git describe --tags
  --exact-match`; else `git describe --tags --always --dirty`). Works from
  anywhere, reads no manifest.
- `po doctor` — read-only, for every repository (an absolute path, or `~/…`)
  listed in `~/.config/po-kit/adopters` (one per line; blank lines and lines
  starting with `#` skipped): reads its `po.toml` with this po's reader
  (`manifest ok` or `FAIL` with the reader's message), runs `po -C <repo>
  status` (`ok`, also for exit 3 and 8, which are reports; any other exit
  `FAIL`), and lists each optional manifest key the adopter does not set as
  `adopt [section] key`. Exit 2 when any adopter fails or the list is
  missing; `--manifest` does not apply. The kit never edits an adopter's
  `po.toml`: turning a key on is that project's admin commit.
- `bin/po-install [<tag>]` — makes a po-kit tag the live `po`, so main's
  half-done changes never are. The tag (default: the newest `v<number>`) is
  checked out with `git worktree add --detach` under
  `~/.local/share/po-kit/<tag>` (an existing one is reused only when clean
  and at that tag) and `~/.local/bin/po` is pointed at its `bin/po`
  atomically; it prints `old -> new`. Refuses (exit 6) a branch or unknown
  name, a dirty install directory, a non-symlink at `~/.local/bin/po`, and a
  tag whose `po -C <adopter> status` exits 2 for an adopter the installed po
  reads without exit 2 — the symlink stays and a worktree it just made is
  removed. After switching it runs `po doctor` (skipped, with a note, when
  there is no adopters list or the tag predates `po doctor`); a failing
  doctor exits 7, the switch standing. It never pushes. In po-kit's own
  `po.toml`, `[hooks] on_close = "bin/po-install \"$PO_TAG\""` runs it at
  each close.

## Development

Tests: `tests/run.sh` (throwaway repos in a temp dir). Lint:
`shellcheck -x bin/po bin/po-install lib/po/*.sh tests/run.sh`.
`AGENTS.md` is a short guide for coding agents that use po;
`CHANGELOG.md` lists what each release changed.

## License

MIT; see `LICENSE`. Provided as-is.
