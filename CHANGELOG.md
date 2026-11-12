# po-kit changelog

Items and releases are different things. Every item close tags its item
(`v0.8`, `v0.9`, ...); that is po's boundary law. A **release** bundles the
items of one backlog scope and is cut once that scope is done, as the
annotated tag `release-N`. A pre-release review never holds a release; its
fixes ship as the patch release `release-N.1` (then `release-N.2`).

Each item's notes say what changed, what agents must now do (**Agents**), and
which optional manifest keys a project may turn on (**Adopt**, by its PO's
admin commit). At each item close they go under **Unreleased**; at a release,
Unreleased becomes `## Release N (YYYY-MM-DD): <theme>`. Each release entry opens with a
`### Setup after install` block: every setup step of the release's items in order, or
`None`. The steps are a markdown table with the columns #, Machine, Command, Who, Check:
one row per step or per group of steps.

## Unreleased

## Release 29 (2026-11-12): a tiered gate and `po land`; the host lands finished items; a test review and faster tests

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the host | `the host install script` (v0.162, v0.167, v0.175, v0.176, v0.177, v0.180, v0.205) | the host operator | `systemctl --user is-active land-queue.timer` prints `active` |
| 2 | each machine that shows the dashboard | restart `po-dashboard` (v0.178, v0.179) | the machine's operator | a project card's switch flips only on the switch |

**Agents:** on po-kit your `po stamp` is fast (v0.182): a new test file gets a `# covers:` line, and a `STAMP FAILED` from `po land` after a fast pass means widen it. Devs in a `[land]` project commit as the item commit, stamp at dirty 0 and REPORT; no commit prompt follows (v0.181). **Adopt:** `[stamp] tier = "fast"` with `[stamp.fast] command`, and `[land] push`, `[close] changelog` (v0.182, v0.181; `po doctor` lists them). Also in this release without notes of their own: v0.172 (auto-dispatch reads Nous agents from the roster), v0.200 and v0.201 (two private tests wait on files, not sleeps).

### The projects-feed private tests stub team-status (v0.185, 2026-11-12)

- 40-v0.50, 45-v0.83, 98-v0.94 and 99-v0.130 pass `TEAM_STATUS_BIN` a stub that prints `[]` instead of the real `team-status` (3.5-4 s a call under the suite): about 127 s of team-status time per run gone, same 3599 checks.
- **Agents**: none. **Adopt**: none.

### The over-budget gate test no longer sleeps (v0.187, 2026-11-12)

- tests/run.sh: the v0.170 over-budget block runs `po stamp` under the fake `date` instead of a real `sleep 2`; about 2 s less wall time per run, same 3599 checks.
- **Agents**: none. **Adopt**: none.

### Tiered gate: a fast po stamp per item, the full suite at land and release (v0.182, 2026-11-12)

- `po stamp --tier fast|full` (default `[stamp] tier`): the fast tier runs the test files whose `# covers:` line names a changed path, plus `[stamp.fast] always`; an uncovered path or an empty selection falls back to full. The block names the tier; `po events` marks fast runs, `--trend` skips them.
- `po close` and `po land` want a full stamp at the tip (land stamps `--tier full` itself); `po release <N> --write` wants one at main's tip.
- **Agents:** on po-kit your `po stamp` is fast after this release; a new test file gets a `# covers:` line (and `# needs:` for a fixture it reuses); a `STAMP FAILED` from `po land` after a fast pass means widen your covers line.
- **Adopt:** `[stamp] tier = "fast"` and `[stamp.fast] command = "... {selected}"` (`po doctor` lists them).

### The heartbeat tells the PO when a finished item waits for the close (v0.180, 2026-11-12)

- `the PO-pending` raises `CLOSE WAITING <item>` when a DOING item's newest message is a dev REPORT or COMMIT, or dante's SPEC MET, and the PO has not answered for `close_wait` minutes (default 20); other waiting items are listed on the same wake. It posts nothing.
- **Agents**: none. **Adopt**: the host operator runs `the host install script`.

### Test review of po-kit: timing, overlaps and 20 follow-up rows (v0.183, 2026-11-12)

- Read-only review: the suite is 3420 checks and 322 s; the slow private files are slow because the projects-feed tests call the real `team-status` at `SNAPSHOT_TTL=0` (3.6 s a call against 0.46 s). Findings and rows are in `docs/notes/test-review-v0.183.md` and the backlog (v0.185-v0.204).
- **Agents**: none. **Adopt**: none.

### The heartbeat raises a stalled-item finding from the dashboard's idle number (v0.162, 2026-11-12)

- `the PO-pending` raises one `STALLED ITEM` finding for every DOING item the dashboard already shows as "idle Nh, stalled", from the same number, instead of a separate rule.
- **Agents**: none. **Adopt**: the host operator runs `the host install script`.

### A project card's switch flips only on the switch (v0.179, 2026-11-11)

- In the GTK Projects view a click on the word, the reason or the empty part of the switch line opens the project like a click on the card; only the switch itself flips (click or keyboard). The switch keeps a 44 px touch area. The web card is unchanged: its card opens nothing and its switch is already a single button.
- **Agents**: none. **Adopt**: restart `po-dashboard` on each machine.

### `po land`: rebase, stamp, close, changelog and push in one command (v0.181, 2026-11-12)

- `po land <version> [--dry-run]` takes a finished item the whole way with nobody at the keyboard: refused (6) unless its SPEC MET is recorded, every backlog source says DOING, its worktree is clean, its branch is one item commit (or none) and the newest `gate-<n>.txt` names that tip clean and passing; then rebase onto main when behind (a conflict is aborted and the worktree verified back at the dev's tip, exit 5, `land: CONFLICT <paths>`), `po stamp` (a failure is exit 4, `land: STAMP FAILED leg <l>, log <p>`, the worktree left at the rebased tip with the old tip printed), `po close --commit` with a body built from fixed parts (the stamp line, `SPEC MET: <by> <at> <ref>`, the REPORT's `PROPOSED:` notes and `Memory:` line, else `Memory: nothing new learned`), then the `[land] push` command (`sh -c` in the main worktree with `PO_VERSION`, `PO_TAG`, `PO_REPO`, `PO_ADMIN_COMMIT`; a failure is exit 7, the close stands; no key: no push). stdout is exactly one line, `land: OK|REFUSED|CONFLICT|STAMP FAILED|CLOSE FAILED|PUSH FAILED ...`, for a queue to read; `--dry-run` prints each check as `ok` / `would refuse: <reason>` and the steps as a plan, runs no gate, writes nothing, exit 0.
- `po land record <version> --spec-met --by <name> [--ref <id>] [--report-file <f>] [--changelog-file <f>]` writes the trigger record under `<git common dir>/po-land/<version>/` (never in the worktree); a DOING item only; a new record replaces the old; refused when the block would land an entry the item commit already carries. `po prune` lists a record whose item is no longer DOING (`STALE LAND RECORDS`), removes nothing.
- `po close --changelog-file <f>`: the file's text becomes one more planned edit of the close's admin commit, inserted into `[close] changelog` right under the `[close] changelog_heading` line (default `## Unreleased`; heading and block go before the first `## ` heading when it is missing), one blank line each side; refused (6) without the key or when the changelog already has the block's first line. Main moves once per close. Without the flag `po close` is unchanged.
- `po status`: a DOING branch behind main carries `  needs rebase` after its behind count (the idle time stays last, what the host's parsers read); `--json` carries `"needs_rebase": true|false` (the v0.130 pin updated: `status --json: idle 30 min ...`).
- **Agents**: devs in a `[land]` project commit as the item commit, `po stamp` at dirty 0 and then REPORT; no commit prompt follows. Run `po status` before stamping: `needs rebase` means `git rebase <main>` first. A `Changelog:` fenced block in the REPORT is the entry `po land` lands (never when the commit edits the changelog too). **Adopt**: `[land] push = "the push command {repo}"` (the push command `po land` runs; `{repo}` is the main worktree), `[close] changelog = "CHANGELOG.md"`, `[close] changelog_heading = "## Unreleased"` (po-kit's `po.toml` by the PO's admin commit; other projects after po-kit has used it for a week). The host queue (`the land-queue script`) is the row's step 3, a separate build.

### The feed's idle time counts the owner's real activity (v0.176, 2026-11-11)

- `projects-feed` reports a DOING item's `idle_hours` as the smallest of the worktree's idle time, the owner's last action and the newest message in the item's thread, and adds `idle_source` (`worktree`, `agent` or `thread`). `po status` is unchanged.
- **Agents**: none. **Adopt**: the host operator runs `the host install script`.

### The sweep records a handoff nobody picked up (v0.177, 2026-11-11)

- `report-sweep` records a handoff to a dev that went unanswered while the dev's session was idle (kind `HANDOFF`, state only, nothing posted); `projects-feed` passes it into `stalled`, so the dashboard shows it.
- **Agents**: none. **Adopt**: the host operator runs `the host install script`.

### Concurrent stamps queue on the display lock (v0.175, 2026-11-11)

- `run-scoped` queues every run that uses the same display behind one host lock, so concurrent `po stamp` runs no longer collide on Xvfb :99 and fail the same GUI tests.
- **Agents**: none. **Adopt**: the host operator runs `the host install script`.

### The host dispatcher hands orphaned items to a free dev and honours an exclusion file (v0.167, 2026-11-11)

- `the dispatch exclusion file` (one agent name per line, `#` comments; absent = nobody excluded) names agents that get no new item and are never a reassign target; they leave the roster and every ready line (logged `skipped <agent>: excluded`, `ready: <item> names excluded agent <agent>, dropped`). After the resume step, a DOING item is ORPHANED when its owner is excluded, at its limit, or silent in the item's thread for 24 h while the item sat idle 24 h or more (`po status --json` idle hours; `local`'s items never). Oldest idle first, it goes to the first free agent in the cost order with role `dev` (level 1) or `senior-dev` (level 2 and up) that took nothing this run: one empty admin commit `admin: <item> DOING for <agent> (reassigned from <old>)` on the project's main checkout as the PO, then `<item> → <agent> · PROMPT (reassigned from <old>)` in the item's thread with the old worktree. One reassign per agent per run; a state marker holds a second reassign of the item for 24 h; without `--commit` the plan prints `would reassign:` and writes nothing.
- **Agents**: a `· PROMPT (reassigned from <old>)` means the item is yours now: check `po status` in the named worktree, keep what is sound, redo the rest, REPORT with the quoted stamp. **Adopt**: none (the host operator creates `the dispatch exclusion file`; the owner edits it).

### The dashboard Reports view redraws only on change (v0.178, 2026-11-11)

- The Reports view no longer rebuilds all its charts on every 5-second fetch: a 304 or an unchanged feed redraws nothing, a changed feed redraws once (or marks Reports dirty while another view is on screen and redraws on switching to it), and a 60-second tick moves the range clock only while Reports is visible. Output of the redraw is unchanged. This removes the steady CPU load and the widget churn behind the dashboard's memory growth.
- **Agents**: none. **Adopt**: restart `po-dashboard` on each machine that shows it.

## Release 28 (2026-11-11): an agent can be switched off; the dispatcher resumes parked items; local best-of-N

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the host | `the host install script` (v0.123, v0.163, v0.166, v0.173, v0.174) | the host operator | `ls the agent switch file` exists |
| 2 | the host | `systemctl --user restart answer-receiver.service` (v0.174) | the host operator | `systemctl --user is-active answer-receiver.service` prints `active` |
| 3 | each machine that shows the dashboard | restart `po-dashboard` (v0.154, v0.173) | the machine's operator | the Team view shows an OFF switch per agent |

**Agents:** a `· PROMPT (resume)` means finish that item before anything new (v0.166); an agent shown OFF gets no item until switched on (v0.173, v0.174). **Adopt:** set `[team] inactive_file` to the agent switch file (v0.173); write `n=3` to `the best-of-N config file` for local best-of-N (v0.123).

### The PO heartbeat raises a finding for an item stuck at a PO step (v0.163, 2026-11-11)

- `the PO-pending` raises one `OPEN` finding line for an item whose last handoff is waiting on the PO's own step (verify, commit prompt or close) so it shows up instead of sitting silent.
- **Agents**: none. **Adopt**: none.

### The host honours the agent switch (v0.174, 2026-11-11)

- `the agent switch file` is the agent switch file: the answer receiver takes kind `agent-active` (off appends, on removes), `team-status` hands it to `po team`, `auto-dispatch` logs `skipped <agent>: inactive` and drops the agent, `the PO-pending` raises one `OFF <agent>` line instead of QUIET, and `dante-pending` does not count it free.
- **Agents**: none. **Adopt**: none.

### Local best-of-N with the gate as verifier (v0.123, 2026-11-11)

- `private/the host/bin/local-bestofn` (new) makes N sibling worktrees `item-<v>-cand1..N` of an item, runs one local session in each at temperature 1.0 (one at a time), gates each with `gate-brief` and keeps the first that passes: its diff is applied to the item worktree with `git apply --index` (never a merge). When none passes, the candidate with the fewest failure lines is applied and the v0.118 retry loop takes it. Every candidate worktree and branch is pruned after; `po status` never lists one as ORPHANED. `local-pending` starts it, detached behind a lock, for an item's first attempt only when `the best-of-N config file` has `n=2..5`; with no file or `n=1` its output is byte-identical to before. Design: `docs/notes/local-best-of-n.md`.
- **Agents**: none. **Adopt**: write `n=3` to `the best-of-N config file` to switch it on (the host operator runs `the host install script` first).

### The host dispatcher resumes parked items before it opens new ones (v0.166, 2026-11-11)

- Before any new item, each free agent that owns a DOING item idle 2 h or more (`po status --json` idle hours, the dashboard's stalled rule) is re-sent its longest-idle one: one `<item> → <agent> · PROMPT (resume)` in the item's thread (top level, logged, when no thread is found), and that agent takes no new item that run. An item whose thread ends with the owner's own REPORT, BLOCKED or TESTS handoff waits on someone else and is skipped (logged). A state marker holds a second resume of the same item for 2 h; without `--commit` the plan prints `would resume:` and sends nothing.
- **Agents**: a `· PROMPT (resume)` means finish that item before anything new: report in its thread (REPORT with the quoted stamp, or BLOCKED with what you wait on). **Adopt**: none.

### An agent switch: switch an agent off so nothing is dispatched to it (v0.173, 2026-11-11)

- `[team] inactive_file` names an agent switch file (one agent per line, `#` comments, names without case; missing means nobody is off). `po team` / `--json` / `/team.json` give a listed agent `"inactive": true` and `free: false` (its state and items untouched) and print `OFF` in the FREE column; `po dispatch` never gives it an item and its `--plan` skip says `(<agent> is inactive)`. `po team off|on <agent> [--commit]` switches it, in place, every other byte kept (off then on of the last line is byte-exact). The dashboard Team view (desktop and web) shows a muted line with an `OFF` badge and, with an answer URL, an on/off switch per line that posts the answer kind `agent-active` on the answer path; your receiver applies it.
- **Agents**: none. **Adopt**: set `[team] inactive_file` to your agent switch file to switch the feature on; teach your answer receiver the `agent-active` kind to use the dashboard switch.

### Desktop small buttons are at least 24 px tall (v0.154, 2026-11-11)

- The `.po-small` buttons of the desktop dashboard (the range, Show all, Reports, Archive and Actions buttons, the project screen's filters) measured 21 px tall; `css()` now gives them `min-height: 18px`, which GTK applies to the content box, so with the unchanged 2 px padding and 1 px border each button is 24 px tall, the target size of WCAG 2.2 criterion 2.5.8; every one is already wider than 24 px. Colours, fonts and the `:checked`, `:disabled` and `:focus-visible` states are unchanged.
- **Agents**: none. **Adopt**: restart `po-dashboard` on each machine that shows it.

### The backlog loads without a subshell per heading or cell (v0.161, 2026-11-10)

- `po_backlog_load` (every `po` command that reads the backlog) no longer forks per table line, cell or heading: `po_unfill_into` and `po_trim_into` set a variable instead of printing into a command substitution, the tag template is read once per load, and a spec file is read in one `mapfile`. A backlog with 440 spec headings loads in about half the time; the parse result and every loader error are unchanged. `po_unfill` and `po_trim` keep their output for their other callers.

- **Agents**: none. **Adopt**: none.

### The suite retires its duplicate and replaced tests (v0.171, 2026-11-10)

- The self-test suite drops tests that repeated another test or pinned text a later item replaced: the per-agent gate-run text (and its dead function), repeated receiver auth and replay cases, per-item install and rollback re-tests (one generic test now checks that every file under `bin/` and `units/` is tracked), a repeated journal and CORS check, and source-text greps that a behaviour check already covers. No behaviour changed.
- **Agents**: none. **Adopt**: none.

## Release 27 (2026-11-10): the gate shows its growth; one rule for table rows; action cards follow six rules

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the host running the dashboard | `systemctl --user restart po-dashboard.service` | the host's operator | `systemctl --user is-active po-dashboard.service` prints `active` |

**Agents:** the PO reads the `tests vs merge-base` line and the slow-gate flag at verify (v0.169, v0.170); build action cards by the six rules in AGENTS.md "Asking the owner" (v0.159); write a pipe in a backlog cell as backslash-pipe or inside one closed backtick span (v0.160). **Adopt:** `[stamp] test_files` and `test_def` (v0.169), `[stamp] slow_after` (v0.170), both optional.

### One rule for splitting a markdown table row (v0.160, 2026-11-10)

- `po_split_row` (`po status`, `kickoff`, `release`, `edit`), the `po lint` cells and the setup table's `split_row` now agree: a pipe separates cells unless it sits inside a backtick span closed on the same row or is written as backslash-pipe; an unclosed backtick is literal. A backlog row with a pipe in backticks no longer kills `po status`. The wrong-cell-count messages say so. GitHub does not protect backticks, so only backslash-pipe renders right there.
- **Agents**: write a pipe in a backlog cell as backslash-pipe or inside one closed backtick span. **Adopt**: none.

### The host install sweep installs when `install --check` exits 5 (v0.165, 2026-11-10)

- A wanted timer that is inactive (check exit 5, `inactive:` lines) is pending work like exit 3: the sweep runs `install` (main checkout clean) and re-checks, and reports a line that is still `inactive:` as `still pending after install`. Exits 1, 2, 3 and 4 behave as before; exit 4 (no Heartbeat identity) is a different case that `install` cannot fix.
- **Agents**: none. **Adopt**: none.

### Sleep-cycle wake re-sends every DOING item to its owner (v0.156, 2026-11-10)

- After the agent starts and the hand-over, `wake` posts one `<item> → <owner> · PROMPT (after sleep)` per started agent and DOING item in that item's thread (top level, logged, when no thread root is found), with the worktree and the sleep window; guarded like the hand-over (errors logged, never raised), `--dry-run` sends nothing, a marker keeps a second wake in the same hour from posting twice.
- **Agents**: none. **Adopt**: none.

### A gate over the time budget is flagged at stamp and close (v0.170, 2026-11-10)

- `[stamp] slow_after` (default 300 s) is the project's gate time budget. A `po stamp` run over it adds `gate time: <time>, over budget <budget> (slow_after)` to its gate block after `diffstat` (and after v0.169's test lines when set), with the same seconds its event carries; at or under the budget the block is byte-identical to before.
- `po close <v>` (dry run and `--commit`) prints `flag: item <tag> gate took <time>, over budget <budget>` when the item's newest passing stamp event took longer than `slow_after`. No such event, or one without `seconds`, prints nothing. The flag changes no exit code and blocks nothing.
- **Agents**: a flagged close is the PO's cue to ask for the trim or the tiered gate (README, the `slow` trigger). **Adopt**: none.

### `po stamp` shows the tests an item adds and removes (v0.169, 2026-11-10)

- Two optional `[stamp]` keys, set together: `test_files` (an array of git pathspecs, the files that hold the tests) and `test_def` (one `grep -E` pattern matching one line per test definition). With both, the stamp block gains `tests vs merge-base(<main>): +<A> -<R>` after the diffstat: the definitions the item's diff adds and removes in `test_files` (a rewritten definition counts in both). When the diff also changes a file outside `test_files` and the docs (`*.md`, `docs/`, `CHANGELOG.md`) and R is 0, the line `flag: code changed, no test removed or rewritten (PO: check for pins on replaced behaviour)` follows. Information only: no exit code changes. With neither key the block is as before; one without the other, an empty `test_files` or an invalid `test_def` is a manifest error (2).
- po-kit's own manifest sets them for `tests/run.sh`.
- **Agents**: the PO reads the `tests vs merge-base` line and the flag at verify; on the flag, check that no test still pins the behaviour the item replaced. **Adopt**: set `[stamp] test_files` and `test_def`.

### `po events --trend`: the gate's growth per day (v0.168, 2026-11-10)

- A passing `po stamp` event now carries `tests` (the number its gate block prints) and `load1` (the machine's one-minute load average when the run ended, left out when `/proc/loadavg` cannot be read), after the run's `seconds`. A failed stamp and the other kinds have neither; older events stay valid and readers show `-`.
- `po events --trend [--days <n>] [--json]` sums the PASS stamps of the live log and the archive per local day (default 14 days): stamps, the highest test count, the median test leg, that median per test in ms and the median load, then the change from the oldest to the newest day with a test count.
- **Agents**: none. **Adopt**: none.

### Action cards follow six rules (v0.159, 2026-11-10)

- An action card must now be followable step by step: R1 one command or click per step (no `&&`, `||`, `;`, newline), R2 `sudo` is a step of its own and its first word, R3 every step has an `expect`, R4 no `<...>` placeholder, R5 `done_when` is one line of at most 120 characters asking for "pass", R6 `machine` names one machine. `card_rule_problems` is mirrored in the dashboard core, the web core, `mk-queue`, `look-check` and `ask-mk`; a card that breaks a rule is shown `unformatted` and `ask-mk`/`mk-queue` refuse it.
- **Agents**: build action cards by the six rules in AGENTS.md "Asking the owner". **Adopt**: none.

### Web Decisions: no badge on a card without kind (v0.155)
A card with no `kind` (or an empty one) that is not a look card no longer shows a `LOOK` badge in the web view; the `.kind` element is not created. A card with a `kind` keeps its badge.

### `/archive.json` serves the whole archive (v0.153, 2026-11-09)

- `po serve` ran `po events --archived --json`, which keeps only the newest 10 without `--all`, so `/archive.json` (and the dashboard's Reports previous period) held a fraction of the archive. It now runs `po events --archived --all --json`. `po events` itself is unchanged.

### `po lint-founding` reads the status by its first word (v0.150, 2026-11-09)

- A backlog status cell is now valid when its first word is ALL-CAPS, as `po status`, `po released` and the other readers take it: `DONE (no change needed: ...)` is DONE and `DOING (waiting on v0.2)` is DOING for every later check. A cell with no leading ALL-CAPS word, or an empty one, is still a finding with the same message. Headings already read each segment's first word. po-kit's own main now lints clean (release-25 review R8).
- **Agents**: none. **Adopt**: none.

### `po released` scans git once; the projects feed caches its answer (v0.152, 2026-11-08)

- `po released` (every form) now computes the released set in a constant number of git calls, whatever the number of DONE items: one `cat-file --batch-check` for the item tags, one `rev-list` of the release, one `log` of main's subjects for the `admin: <v> DONE` commits and, only when an untagged item has no such commit, one `log -p` of the backlog and `specs_dir` for the last change of its row or heading; the rules are joined in text. The rules and the output are unchanged (old and new `--json` were diffed over 39 release tags in four repositories: no difference). On a repository with 410 released items one run went from 910 git calls and 10.5 s to 13 git calls and about 1.4 s, most of what is left being the backlog parse.
- The host glue's projects feed caches each repository's `po released --json` answer in its cache dir, keyed on the release source and pattern, the main and backlog blob shas, a digest of every tag ref, the github tag and po's `released.sh`; any change recomputes, and a corrupt cache file counts as absent.
- **Agents**: none. **Adopt**: none.

## Release 26 (2026-11-08): the pending check finds an unanswered report; heartbeat setup is checked

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the build host (private host glue; nothing in the public kit) | create the host glue's Heartbeat keypair and its env file (mode 600), add its pubkey to the agent pubkey list, run the host glue's `install`, then one run of each heartbeat wake script that sends (v0.147, v0.158) | the session on that host | `install --check` passes (exit 0, no `missing:  heartbeat identity` line), `the pending-reports script --all` runs without error, and each wake script's run exits 0, printing `sent N finding(s)` (or nothing when nothing is pending), with no `no Heartbeat identity`, `no DM` or `send ... failed` line |

**Agents:** the heartbeat now raises REPORT WAITING (1 hour) and UNTAGGED REPORT (15 minutes) for a DOING item whose newest REPORT nobody answered (v0.158). **Adopt:** none.

### The pending check finds a report nobody answered (v0.158, 2026-11-08)

- The host glue's pending check gained two findings for a DOING item whose newest REPORT (first line `<item> → <who> · REPORT`) has no first check, no SPEC MET and no FIX? after it: REPORT WAITING at 1 hour (hand the first check to a free checker, or ask for SPEC MET directly), and UNTAGGED REPORT at 15 minutes when the text addresses the PO but carries no p-tag for it. Same hold mechanics as the other findings (2 hours, held until sent). A `local` item, or an item no longer DOING, raises neither.
- **Agents**: none. **Adopt**: none.

Setup after install:

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the build host (private host glue; nothing in the public kit) | run the host glue's `install` (the script is copied into the agents' bin) | the host's operator | `the pending-reports script --all` runs without error |

### `po ready` and `po dispatch` say why when there is no ready file (v0.149, 2026-11-09)

- `po ready` with no `[ready] file` in po.toml exited 2 with no output: the key lookup ran in a command substitution with its stderr dropped, and its abort ended the command before the intended message. It now prints `po: no [ready] file configured in po.toml` and exits 1; a `[ready] file` that names no file prints `po: ready file <path> not found` and exits 1 (it was a Python traceback). `po dispatch --plan` and `--commit` print the same lines prefixed `po dispatch:`, exit 1 and change nothing. With the file present nothing changes (release-25 review R3).
- **Agents**: none. **Adopt**: none.

### Heartbeat setup is checked and its DM is looked up, not written in (v0.147, 2026-11-07)

- The host glue's `install --check` now lists `missing:  heartbeat identity (<path>)` and exits 4 when the Heartbeat env file (`$HEARTBEAT_ENV`, else its default path in the host user's config) is absent or not mode 600; it never reads the file. Before, a check that compares files only passed while the heartbeat could not sign anything (release-25 review R1).
- The heartbeat wake scripts no longer carry DM channel ids: one shared lookup, signed as Heartbeat, lists the DMs and takes the one whose participants include the destination (fewest participants first, then the first listed), and opens a DM when none is listed. A destination with no DM, or a send that fails, prints an error line (the send's exit code and the first line of its error output), holds nothing so the next tick retries, and makes the run exit 1; the other destination still goes (release-25 review R2).
- **Agents**: none. **Adopt**: none.

Setup after install:

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the build host (private host glue; nothing in the public kit) | create the host glue's Heartbeat keypair and its env file (mode 600), add its pubkey to the agent pubkey list, run the host glue's `install`, then one run of each heartbeat wake script that sends | the session on that host | the identity check of `install --check` passes (exit 0, no `missing:  heartbeat identity` line), and each wake script's run exits 0, printing `sent N finding(s)` (or nothing when nothing is pending), with no `no Heartbeat identity`, `no DM` or `send ... failed` line |

### Dispatch: a project's first checker never builds its items (v0.157)

The host dispatcher leaves a project's first checker out of that project's build roster and ready lines, and the dev prompt for that project names the first check. Other projects are unchanged.

#### Setup after install

1. On the machine that runs auto-dispatch, install the release package.

## Release 25 (2026-11-05): dashboard overhaul, project switch and Release button, no bot posts in project channels, release counting

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the build host (private host glue; nothing in the public kit) | add `[release_due]` / `po-kit = 24` to the sweep config (v0.138), run the host glue's `install`, then `systemctl --user restart answer-receiver.service` (v0.139, v0.140) and the units it flags `restart needed` (v0.137, v0.144, v0.145) | the session on that host | `install --check` prints every script as current |
| 2 | the machine that shows the dashboard | install the release package (`pacman -Q` shows the release build), then `systemctl --user restart po-dashboard.service` (v0.139 to v0.143, v0.146) | the session on that machine | `po-dashboard` shows the Release button on each Projects card |
| 3 | the build host (private host glue; nothing in the public kit) | added in 25.1 (v0.144's host step, missing here): create the host glue's Heartbeat keypair and its env file (mode 600), add its pubkey to the agent pubkey list, run the host glue's `install`, then one run of each heartbeat wake script that sends | the session on that host | the identity check of `install --check` passes (exit 0, no `missing:  heartbeat identity` line), and each wake script's run exits 0, printing `sent N finding(s)` (or nothing when nothing is pending), with no `no Heartbeat identity`, `no DM` or `send ... failed` line |

**Agents:** no bot posts into a project channel or thread any more: a stalled item, a QUIET finding or a BLOCKED ping reaches you as a DM or on the dashboard (v0.144, v0.145); QUIET and OWED-by-dev findings are routed to the second PO, the rest to the first (v0.137). A release request from the Projects page carries a note: put it verbatim in the release's close message and notes (v0.140). **Adopt:** a projects-feed producer sets `active` per project (v0.139); an answer receiver handles `project-active` and `release-request`.

### Heartbeat routing: findings carry a destination (v0.137, 2026-11-05)

- The heartbeat marks each finding with a destination column (`dest=`): QUIET and OWED-by-dev findings go to the second PO, every other finding to the first; one send per destination, the hold after a send kept per destination.
- **Agents**: none. **Adopt**: none. Setup: run the host glue's `install`.

### No bot posts into a project channel or thread (v0.144, 2026-11-04)

- `swept:` lines, `REPEATED x<n>:` posts and OWED/NO THREAD findings are no longer posted into project channels or threads by a timer: they go to the heartbeat's DM and to the dashboard's state (`projects-feed`), and the heartbeat no longer counts an automated post as OWED.
- **Agents**: none. **Adopt**: none. Setup: run the host glue's `install` and restart the units it flags.

### Releases by count: RELEASE DUE finding (v0.138, 2026-11-05)

- the heartbeat raises `RELEASE DUE <project>: <N> DONE unreleased >= <threshold>` (key `release:<project>`, 2 h hold) when the DONE rows of the backlog not in `po released --json` reach the project's `[release_due]` threshold in the sweep config (po.toml's manifest check rejects the key). `report-sweep` sweep 3 records it in the state file only (v0.144).
- **Agents**: none. **Adopt**: none. Setup: add `[release_due]` / `po-kit = 24` to the sweep config, then run the host glue's `install`.

### mk-queue --flag sends FIX? and BLOCKED as DMs (v0.145, 2026-11-04)

- `mk-queue --flag` no longer posts into item threads: the `FIX? — your ask to the owner is not shown` note goes to the asker's DM and the 2 h `BLOCKED — the look card is held` ping to the first PO's DM, signed by the Heartbeat identity, no reply-to, with `Thread root: <id>`. No DM or no identity: error line, nothing posted, dedupe not marked.
- **Agents**: none. **Adopt**: none. Setup: run the host glue's `install` after v0.144's Heartbeat identity exists.

### Dashboard: an Events card with no item names its project alone (v0.146, 2026-11-04)

- Web `/app/`: an Events card whose item is empty or `-` reads `demo` (All) or nothing (one project), never `demo v-`;
  the `v` now comes from the same rule as the Team view, so an item already starting with `v` keeps it. The desktop
  window has no such prefix (its item column shows the value as it is) and is unchanged.

### Projects page: active/inactive switch on each project card (v0.139, 2026-11-04)

- Each Projects card, desktop and web, has a switch when the projects feed carries the new optional `active`
  boolean; it posts the answer kind `project-active` (`{answer_id, kind, project, active, answered_at, client}`)
  through the authenticated answer path (same sink, same device token). An inactive project shows a muted
  `inactive` badge in words. A feed without `active` renders as before (no switch, no badge).
- **Adopt:** a projects-feed producer sets `active` per project from its project switch file; an answer receiver
  handles `project-active` (validate the project, remove or append its line, keep every other byte).

### Dashboard: wrong or hidden data (v0.141, 2026-11-04)

- Web `/app/`: an Events card's head shows its newest event's result as a mark and a word (`✔ pass`, `✘ fail`)
  and its kind; Team no longer prints `on vproject v1.2` (a bare version gets its `v`, a `project vX` value is
  kept); a greyed Projects card keeps its text colours (no opacity) and says why it is grey.
- Decisions, both screens: every card ends in an `Open thread` link (desktop: a real link, not URL text), an
  http(s) URL or a chat app's own `<scheme>://` deep link (a code-running or local scheme never links); the web
  page sorts like the desktop: Choices, then Actions, then the rest, oldest asked first.
- Reports: the gate-runs rows share one y top, the largest single agent's bucket (not the busiest bucket of all
  agents), so small agents are no longer flat lines; cycle time takes its unit from the medians (hours while
  they are under a day, never `0.0 d`) and ticks its axis at every whole step from 0.

### Dashboard: controls and surfaces (v0.142, 2026-11-04)

- Selected state: a selected view tab, Reports range (24 h / 7 d / 30 d), Show all, Reports, Archive, Actions and the
  project screen's filter is filled with the accent colour, its text in the accent's own colour (was an inset shadow
  only, 1.7:1 light and 1.2:1 dark). Every desktop button and every web control has a border at 3:1 against its surface.
- Desktop lists (events, team, decisions, a project's items) are one raised panel with flat rows and a hairline between
  them, not a raised card per row. In the dark theme the header, panels, cards and charts have a lighter top edge.
- Status in words: each project light has its words beside the dot (`active`, `idle 3 h`, `stalled 4 d`, `no events`;
  `last event 4 d ago` for a project switched off); a stalled DOING item says `stalled` on the project screen and on
  the web card. The web idle warning names the cause (`idle: its 2 items wait on someone else`, or `owns 3 items and
  works on none`) and no longer shows on an agent at its usage limit.
- Team: a usage every agent shares (one subscription) is said once in the header, not on every line. One time format
  with the zone on both screens: `LIMIT until 7:00 PM EST Nov 30` (desktop was `2026-11-30 19:00`; the web page said it
  twice in two formats).
- Web: once a device token is set, `Set device token` becomes a small `device token set · change` link beside the views.
- Project screen: opens on DOING, newest first (was All, oldest first); its Back, filter and Release buttons are the
  window's own buttons, not stock GTK. Reports: the header reads `Reports` over `7 d · as of 6:42 AM EST`, not the
  Events count.

### Dashboard: Reports redesign (v0.143, 2026-11-04)

- Reports opens with four numbers: gate runs, fail rate, first-try rate and items closed, each with the previous
  period beside it in words and an arrow (`▲ up 24 from 188, previous 7 d`; `no previous period` when there is none).
- One fail-rate line (failed runs over all runs, a gap where no run happened, the previous period dashed) replaces the
  per-agent gate-run rows; the page is about a third shorter.
- Every chart's title states its finding (`First-try rate fell to 61 %`), and a line at its foot gives the previous
  period, the source and `as of`; the text alternative carries all of them.
- First-try: agents under 5 items are not ranked (below a muted line, hatched), a dashed team average runs through the
  rows, each agent shows its previous rate; with a Team feed only the roster's agents count.
- Colours: five colour-blind-safe project hues stepped in lightness (9 L* apart or more, so greyscale reads), a fixed
  colour per project whatever the range, failed legs in shades of the fail colour (at most three named, the rest
  `other`), the cycle-time box neutral; each bar's biggest segment carries its count and the legend each share.
- **Adopt:** nothing to configure. With an archive URL the dashboard now fetches the archive for 7 d too (for its
  previous period); without one, 7 d says `no previous period`.

### Projects page: Release button on each project card (v0.140, 2026-11-04)

- Each Projects card, desktop and web, has a `Release` button: a confirm dialog `Release <project>: N DONE items
  since <last release>` (N: DONE rows the feed does not mark `released`) with an optional note (2000 characters at
  most), Cancel and Release (Ctrl+Enter in the note sends it too). Release posts the answer kind `release-request`
  (`{answer_id, kind, project, note, answered_at, client}`) through the authenticated answer path (same sink, same
  device token). Off at N = 0 and without a sink, saying why; on for an inactive project; one POST at a time, a
  Retry re-posts the same `answer_id`. It only asks: the kit never tags, pushes or runs `po release` from it.
- `po released`: an untagged DONE item kept as a `## <tag> — ... — DONE` heading in `specs_dir`, with no
  `admin: <v> DONE` commit, is judged by the newest commit that changed that heading (before: only a backlog table
  row was looked for, so such items never counted as released and inflated N).
- **Agents:** the PO carries a release request's note verbatim into the release's close message and release notes.
  **Adopt:** an answer receiver handles `release-request` (validate the project, cap the note, post the ask in the
  project's own channel for the PO).

## Release 24 (2026-11-03): memory write-back at close, founding lint, idle time on the dashboard

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the build host (private host glue; nothing in the public kit) | `install the host glue && systemctl --user daemon-reload && systemctl --user enable --now` the timers it added (v0.136), restart the units it flags `restart needed` (v0.126, v0.127), restart the sessions whose prompts it rebuilt (v0.120, v0.121, v0.122) | the session on that host | `install --check` prints nothing and exits 0; `systemctl --user list-timers` lists each added timer with a next run |
| 2 | the machine that shows the dashboard | install the release package (`pacman -Q` shows the release build), then restart `po-dashboard` (v0.130 idle time) | the session on that machine | `po-dashboard --check` prints one line per project |

**Agents:** write a `Memory:` line in every close body when `[close] memory = true` (v0.129); run `po lint-founding` after a founding or spec commit (v0.124); `po status --json` carries `idle_hours` per DOING item (v0.130). **Adopt:** `[close] memory = true` in `po.toml` (v0.129); a projects-feed producer copies `idle_hours` into each DOING item (v0.130). Items: v0.117-v0.122, v0.124-v0.127, v0.129, v0.130, v0.133, v0.135, v0.136 (the entries below; every item but v0.124, v0.129 and v0.130 touches only private files: host-glue upkeep, with no public notes).

### Memory write-back prompt at close and failed stamp (v0.129, 2026-11-03)

With `[close] memory = true`, `po close --commit` refuses without a `Memory:` line in the close body (a memory id, a proposed note, or "nothing new learned"), and the dry run prints a plan line for it. A failed `po stamp` prints the same prompt on stderr after "no evidence written"; its exit code and evidence block are unchanged.

**Agents:** write a `Memory:` line in every close body; on a failed stamp, record what the failure taught. **Adopt:** `[close] memory = true` in `po.toml`; absent, close and stamp behave as before.

### po lint-founding and the refused-entry ping (v0.124, 2026-11-03)

`po lint-founding` checks, against main, that every backlog row and item heading carries its status, that every open item has its spec heading, and that every line of the ready file names an existing item that is not held, with known agents and no repeated line. One finding per line, exit 1 when there are any. Private host glue also gained a refused-entry ping and a post-commit lint hook.

**Agents:** run `po lint-founding` after a founding or spec commit and fix what it lists. **Adopt:** nothing; `[ready] file` and `[dispatch] order` are read when set, `--ready`, `--project` and `--agents` override them.

### Idle time per DOING item on the dashboard (v0.130, 2026-11-03)

`po status --json` prints the DOING items with `idle_hours` (the idle time `po status` shows, in whole hours; null with no worktree). A projects feed may carry it per item: the desktop project screen and the web Projects card then show `idle 3h` (`active` under 1 h) and mark an item idle 2 hours or more as stalled. A feed without the key renders as before.

**Agents:** nothing. **Adopt:** a feed producer of your own copies `idle_hours` from `po status --json` into each DOING item.

## Release 23 (2026-11-02): web dashboard on the phone, release counting by DONE commit, stamp drain

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the build host (private host glue; nothing in the public kit) | `install the host glue && systemctl --user daemon-reload && systemctl --user enable --now` the timers it added (v0.102, v0.103, v0.107, v0.132) | the session on that host | `systemctl --user list-timers` lists each added timer with a next run |
| 2 | the machine that shows the dashboard | install the release package (`pacman -Q` shows the release build), then restart `po-dashboard` (v0.97 look-card freshness, no `pacman` on the GTK thread) | the session on that machine | `po-dashboard --check` prints one line per project |
| 3 | the host where `po serve` runs | restart `po-serve` so `/app/` is served and `/events.json` answers ETag/304 and `?since=` (v0.93, v0.112-v0.116) | the session on that host | `curl -sI <serve-url>/app/` answers 200 |

**Agents:** `po released` now counts an untagged DONE row as released when its DONE commit is an ancestor of the release tag (v0.134); `po stamp` no longer hangs on a test that leaks a process holding the output (v0.128, `[gate] drain_secs`); `po release <N> --setup` prints the Setup block from recorded steps (v0.106) and `po release <N> --open-review` opens the pre-release review (v0.105); `po close` closes a no-change item (v0.100). **Adopt:** `po serve` serves the phone page at `/app/` and answers ETag/304 and `?since=` (v0.93, v0.112-v0.116; its auth design is `docs/design/web-dashboard-auth.md`, v0.111). Items: v0.90-v0.116, v0.128, v0.131, v0.132, v0.134 (the entries below; v0.90, v0.94, v0.101, v0.131 and v0.132 touch only private files).

### `po released` counts untagged DONE rows by their DONE commit (v0.134, 2026-11-02)

A DONE row whose item tag does not exist (none filled in `[versioning] tag`, or absent from the repository) is released when its DONE commit is an ancestor of the release tag. The DONE commit is the newest commit on the main branch whose subject starts `admin: <v> DONE`, else the newest commit that changed the item's row in the backlog; none found means not released. A tag that exists keeps the old rule (ancestor of the release tag) and the DONE commit is not tried. Output shape is unchanged; the `released` list has more members. **Agents**: nothing. **Adopt**: nothing. Setup after install: in a project with `[release] source = "tag"`, run `po released --json` and check older untagged DONE rows are listed.

### `po stamp` no longer hangs on leaked test processes (v0.128, 2026-11-02)

`po stamp` reads a command's output only until the command exits plus `[gate] drain_secs` (default 5), so a process the test left holding the output cannot keep the stamp waiting. Each command also runs in a transient user scope (`systemd-run --user --scope`); processes still alive there afterwards fail the stamp with `po stamp: <n> process(es) left behind by <leg>: <names>`, and the scope is stopped (killed after 2 seconds if it ignores SIGTERM). Applies to every leg, `[stamp] prepare` line and the count command. **Agents**: a gate whose run leaves processes now fails; clean them up in the test. **Adopt**: optionally `drain_secs` and `scope = false` under `[gate]`; `PO_STAMP_NO_SCOPE=1` turns the scope off. Setup after install: on a machine running gates with browser tests, run one gate whose test leaves a background process and check `po stamp` ends with the leftover line.

### The dashboard feed server versioned and fixed (v0.104, 2026-11-02)

`serve-all.py` and `po-dashboard.service` are now in `private/hostglue/` (`bin/`, `units/`), tracked by `install --check` and covered by `--rollback`. Defects fixed: `/archive.json` crashed (`load_all` took no `cmd`); one malformed `channel-repos.json` entry hid every project but one; feeds were rebuilt inside the request (projects-feed ~18 s against a 5 s timeout, 1998 BrokenPipe tracebacks in 24 h), now a TTL cache per feed rebuilt by its own background thread; team, decisions and projects answer an ETag and 304; `/looks.json` is served (one `mk-queue` run feeds both); a feed failing, recovering, a repo left out and a producer's stderr are logged once per change; the unit runs the installed copy and has `CacheDirectory=projects-feed`. A broken feed degrades to its own 502 while the others answer. **Agents**: nothing. **Adopt**: nothing. Setup after install: on the build host run `private/hostglue/install` then `systemctl --user restart po-dashboard`; check `curl -s -D - -o /dev/null http://100.106.128.3:8790/projects.json` returns 200 with an ETag in well under 1 s, `/looks.json` returns 200, and `install --check` lists neither file.

### Web dashboard 5/5: answering from the phone (v0.116, 2026-11-02)

The page's Decisions view now answers a card exactly as the desktop does (same body and kind): choice radios with wrapping labels, a write-in box, Pass/Failed with a step for actions, Send always in view and disabled until the sink replies, a draft kept per card across reloads and refreshes, `sent <time>` or `not sent: <class>`; look cards stay held unless ready. The sink (`answer-receiver`) gains the device layer of `docs/design/web-dashboard-auth.md`: a per-device bearer token bound to its tailnet node, an Origin allow-list, a content-type and size cap, a per-device rate limit, replay and closed-card refusal, an audit line, and a start-up refusal of a wildcard or non-tailnet `--bind`. New `answer-device` command: `issue`, `list`, `revoke` (token stored as sha256 only, revocation effective on the next request). **Agents**: nothing. **Adopt**: set `answer_url` under `[serve.web]` once the sink is installed. Setup after install: on the build host run `private/hostglue/install`, issue a device token with `answer-device issue`, restart `answer-receiver` and `po serve`, install the token on the phone (the host session, the owner); check a test card can be answered from the phone over Tailscale and a revoked token is refused.

### `sleep-cycle` and its watchdog versioned and fixed (v0.103, 2026-11-02)

`private/hostglue/bin/sleep-cycle` and the units `sleep-cycle.service`, `sleep-cycle.timer`, `sleep-cycle-watchdog.service`, `sleep-cycle-watchdog.timer` are now in `private/hostglue/`, tracked by `install --check` and covered by `--rollback`. Defects fixed: a failed hand-over no longer keeps the state file (every later 1 AM run refused); a unit is saved to the state before its stop; any error inside a run wakes everyone at once; the 7 AM watchdog stops a still-running cycle first; a unit that fails to start on wake stays in the state for retry and the owner is told once; run and wake share a flock; a failing 3 AM alert post is logged; `--dry-run` rehearses the wake; the watchdog timer is `Persistent=true`. **Agents:** nothing. **Adopt:** nothing. Setup: on the build host run `private/hostglue/install` then `systemctl daemon-reload` (never during the 1 AM window); check `install --check` is silent on the five files and `systemctl list-timers sleep-cycle.timer sleep-cycle-watchdog.timer` shows the next runs unchanged.

### Web dashboard 3/5: Projects overview names the DOING items with their last-event age (v0.114, 2026-11-02)

The web Projects card now matches the GTK card (release label, count line, `setup open N`, wrapped `n not in a filter`, greyed `feed error`) and lists its DOING items one per line as `v0.99 - budy - 2m ago`, amber when the item's own last event is older than `[serve.web] stall_minutes` (default 30) or absent (`no events`); at most 5 lines, then `+n more`. `private/hostglue/bin/projects-feed` fills an optional per-item `last_event` (ISO time) and `parse_projects` accepts it. **Agents**: nothing. **Adopt**: optionally `stall_minutes` under `[serve.web]` (see `examples/web.po.toml`). Setup after install: on the build host run `private/hostglue/install`, then check that `curl -s <projects-feed-url> | grep -c last_event` is not 0.

### Web dashboard 4/5: the Team view in words (v0.115, 2026-11-01)

The Team view now shows each agent's usage in words (`5h 42% · weekly 61% · limit until 5:46 PM`, parts left out when missing or non-numeric), splits what an agent works on from what it merely owns (`working_on?` in the shared team feed), and puts agents that are idle while owning items first, in amber with a warning mark (`team_sort`). The usage words are the card's accessible label. **Agents**: nothing. **Adopt**: none. Setup after install: reload `/app/`.

### Web dashboard 2/5: the Events view (v0.113, 2026-11-01)

The page's Events view now groups consecutive events of the same project and item into one card (newest first, at most 50 groups), shows each card's age as a viewer-local relative time (absolute time as the line's tooltip), and has a project filter bar (All plus one chip per project) kept in `localStorage`; the view stays in the URL hash. On a phone (under 800 px) a group shows its header line only until tapped. Decisions, Projects and Team are unchanged. **Agents**: nothing. **Adopt**: none. Setup after install: reload `/app/`.

### Web dashboard 1/5: the page at /app/ and the Decisions home view (v0.112, 2026-11-01)

`po serve` now also serves a phone-ready page at `/app/` (four fixed files from `share/po-web/`, ETag and 304, a Content-Security-Policy and `Referrer-Policy: no-referrer` on every `/app` answer), `/app/config.json`, and read-only same-origin proxies `/app/feeds/<name>.json` of the feeds named in the manifest's `[serve.web]` section (`decisions_url`, `projects_url`, `team_url`, `events_url`, `answer_url`; see `examples/web.po.toml`). A feed URL is fetched as configured and never follows a redirect. The page opens on Decisions with a count on every toggle, keeps the chosen view in the URL hash, refreshes every 10 s, shows a banner when a fetch fails, and pauses in a hidden tab; feed text is only ever rendered as text. Events, Projects and Team are minimal until the next items. **Agents**: nothing. **Adopt**: add `[serve.web]` to a project's manifest to turn the page's views on. Setup after install: restart `po serve` where it runs and open `/app/`; the page is read-only until answering is added.

### A failing project stays in the projects feed (v0.109, 2026-11-01)

When one repository fails while the projects feed is built, the producer now keeps its entry with an `error` line and its last good data (kept in `<cache dir>/projects-last-good.json`) instead of dropping it; a failing `po ready` sets `error: "ready list: ..."`. The dashboard accepts the optional `error` string and shows that project's card greyed with `feed error`, still opening with its last good items. A failure in the release or setup lookup stays non-fatal and sets no `error`. **Agents**: nothing. **Adopt**: none. Setup after install: `private/hostglue/install` on the producing host, then `install --check` is silent; restart `po-dashboard` where it is shown.

### report-sweep re-pings unprocessed REPORTs and idle-owner DOING items (v0.107, 2026-11-01)

`private/hostglue/bin/report-sweep` with `report-sweep.service` and `.timer` (every 15 minutes) re-pings the PO once, in the thread, for a developer REPORT, COMMIT or BLOCKED older than 30 minutes with no later PO message, and once for a DOING item whose owner has been idle 45 minutes; one escalation line after 2 hours; a state file keeps it to once per stall and re-arms it when the cause is gone; `--dry-run` posts nothing. **Agents**: nothing. **Adopt**: none. Setup after install: `private/hostglue/install`, then `systemctl --user enable --now report-sweep.timer`, check `systemctl --user list-timers report-sweep.timer` (the host session). The first run posts about 13 pings for the items already idle.

### `po release` assembles the Setup block (v0.106, 2026-11-01)

New `po release <N> --setup` prints the entry's `### Setup after install` block from the recorded steps (`po setup list`) of the items the `## Release N` entry names (else `## Unreleased`): `None`, or the five-column table, one row per step, the item after the command. `--write` inserts it under the `## Release N` heading and replaces a block already there (idempotent). A `|` is escaped `\|`, a command with backticks gets a longer fence. **Agents**: write the entry's notes first, then run `po release <N> --write` instead of hand-writing the block. **Adopt**: none. Setup after install: None.

### Dashboard: the whole fetch is unconditional, a short body is a note (v0.92, 2026-11-01)

The dashboard's periodic whole fetch no longer sends `If-None-Match`, so a 304 cannot keep events the server has archived; a server that does not offer `?since=` keeps the plain conditional fetch. A short or malformed HTTP body is now a "not updated" note instead of an unhandled error. **Agents**: nothing. **Adopt**: none. Setup after install: restart `po-dashboard` on the machine that shows it.

### `po release` opens the pre-release review (v0.105, 2026-11-01)

New `po release <N> [--open-review] [--commit]`. With `[release] review = true` in the manifest it refuses (exit 6) unless the backlog has a TODO, DOING or DONE row titled `test review: ... release-N`; `--open-review` adds that row as one admin commit (a dry run without `--commit`; idempotent). With the key absent or false and no flag it prints nothing. **Agents**: nothing. **Adopt**: `[release] review = true` turns the refusal on (a project's PO decides). Setup after install: None.

### Projects: the not-in-a-filter line wraps (v0.110, 2026-11-01)

The `n not in a filter` line on a Projects card and on the project screen of `po-dashboard` is a wrapping label with the full text (no ellipsis), growing the card in height only. **Agents**: nothing. **Adopt**: none. Setup after install: restart `po-dashboard` on the machine that shows it.

### Web dashboard auth design accepted (v0.111, 2026-11-01)

`docs/design/web-dashboard-auth.md` fixes how the phone dashboard is served and how its answers are authorised (two listeners, per-device token bound to its tailnet node, plain HTTP inside the tailnet, rate limit). Design only; v0.112 to v0.116 build on it. **Agents**: nothing. **Adopt**: none. Setup after install: None.

### po status without python3, one DONE rule, row CB words (v0.99, 2026-11-01)

`po status` without `python3` on PATH now stops with one line naming python3 and leaves no temp dir (the guard runs before `mktemp -d`). `po released` and the dashboard share one status-word rule: `DONE`, `DONE:`, `done` and `DONE (tag x)` all count as released. Row CB (v0.84) now says the setup-steps key is off by default and the state file is `<git common dir>/po-setup-steps.json`. **Agents**: nothing. **Adopt**: none. Setup after install: None.

### Decisions view: collapsed Action cards readable in dark (v0.108, 2026-11-01)

The collapsed header row of a decision card in `po-dashboard` takes the theme's own base and text colours (class `po-dhead`) instead of the GTK button strip, so it meets WCAG AA (4.5:1) in light and dark. `contrast` in `dashboard_core` is now `contrast_ratio`; the header pairs are in `CONTRAST_PAIRS`. **Agents**: nothing. **Adopt**: none. Setup after install: restart `po-dashboard` on the machine that shows it.

### Setup block is one table format; `the release announcer` accepts it (v0.91, 2026-11-01)

A release entry's `### Setup after install` block is the word `None` or a markdown table with the columns #, Machine, Command, Who, Check (one row per step or group of steps). `the release announcer` checks that table (and refuses prose or the old numbered lines), and its cross-check against `po setup list` is stated in table terms. **Agents:** nothing. **Adopt:** nothing. Setup after install: on the build host, install the host glue (as v0.89); `the release announcer release-22` (dry run) exits 0.

### Test-browser reaper versioned (v0.102, 2026-11-01)

`private/hostglue/bin/reap-test-browsers` and the units `test-reaper.service` / `test-reaper.timer` are now in `private/hostglue/`, tracked by `install --check` and covered by `--rollback`. Defects fixed: only this user's processes match, a `bwrap` matches only when it wraps webkitgtk, SIGKILL goes only to pids that still match after the 10 s wait, the log directory is created. **Agents:** nothing. **Adopt:** nothing. Setup: on the build host run `private/hostglue/install`, `systemctl --user daemon-reload`, `systemctl --user enable --now test-reaper.timer`; check `install --check` is silent on the three and `systemctl --user list-timers test-reaper.timer` lists it.

### Dashboard look card: freshness bound, no `pacman` on the GTK thread, doc time format (v0.97, 2026-11-01)

`look_ready` now holds a look card whose `ready.checked_at` is older than 15 minutes (`stale`) or more than 1 minute ahead of the clock (`in the future`); `now` is injectable and defaults to the current UTC time. The installed build is read in the answer worker thread, so Send and Retry never block the window on `pacman -Q`. `docs/design/look-ready.md` quotes the time as the code prints it. **Agents:** nothing. **Adopt:** nothing. Setup after install: on the machine that shows the dashboard, install the release package and restart `po-dashboard`; `pacman -Q` shows the release build.

### look-prep removes a refused snapshot (v0.98, 2026-11-01)

The the laptop `look-prep` helper re-checks a snapshot's size once after 1 s when it differs, and if it still differs removes the copy (`rmtree`) and returns the same refusal reason, so no `*-data-snapshot-*` directory is left behind; a stable copy is kept as before. **Agents:** nothing. **Adopt:** nothing. Setup after install: on the laptop, install the host glue (as the v0.81 look-prep step); `grep -c rmtree` on the installed look-prep must be at least 2.

### `po close` closes a no-change item (v0.100, 2026-11-01)

An item whose branch has no commit main lacks, whose worktree is clean and whose newest stamp names that tip clean and passing now closes: no fast-forward, the admin commit is written first and the tag goes on it (annotated: `<tag>: <title> (no change needed)`). The dry run says "no change: the tag goes on the admin commit", and the `on_close` hook's `PO_ITEM_COMMIT` is the admin commit. A branch with no commit but an uncommitted worktree is refused; an item with one commit closes as before. **Agents:** nothing. **Adopt:** nothing.

### `po setup` rule 2 reads the row it numbered (v0.95, 2026-11-01)

The backlog row that names an item's spec files is now read from the same revision its line number came from, so an item branch that shifts lines in the backlog no longer parses another row; a row that does not carry the item's id is skipped, and files that are not item specs (`CHANGELOG.md`, `README.md`, `AGENTS.md`) are skipped, so a row naming `CHANGELOG.md` resolves to its real spec file. **Agents:** nothing. **Adopt:** nothing.

### `po stamp` compares the test leg with its own count (v0.96, 2026-11-01)

With a leg named `test`, the count taken from its output is now checked against that leg's own summaries, not the sum of every leg: a second leg that prints a summary (doc tests, integration) no longer fails with "the gate passed 5 tests but test_count_cmd counted 3". With no `test` leg the comparison stays the sum of all legs; the printed total is unchanged. **Agents:** nothing. **Adopt:** nothing.

### `po serve` answers ETag/304 and `?since=` on `/events.json` (v0.93, 2026-11-01)

`/events.json` of `po serve` now carries an `ETag` (a quoted hash of the whole feed) and answers a matching `If-None-Match` with `304 Not Modified` and no body; that check comes first, so a `?since=` request is 304 too while the feed is unchanged. `?since=<time>` returns only the events at or after that time (and any event with no time), marked `X-Po-Since: partial`; a request without it is marked `X-Po-Since: full`. A 502 error carries no `ETag`. HEAD stays refused (405), so release 22's setup check (`curl -sI`) is replaced by the one below. **Agents:** nothing. **Adopt:** restart `po serve` where it runs. **Setup after install:** 1. the host where `po serve` runs, restart `po-serve`, the session on that host, check `curl -s -D - -o /dev/null <serve-url>/events.json` shows an `ETag` header.

## Release 22 (2026-11-01): faster po, RELEASED status, ready look cards, Setup after install

### Setup after install

| # | Machine | Command | Who | Check |
|---|---|---|---|---|
| 1 | the build host (private host glue; nothing in the public kit) | `install the host glue && systemctl --user daemon-reload && systemctl --user enable --now chan-cache.timer` (v0.89) | the session on that host | `systemctl --user list-timers chan-cache.timer` shows a next run; after it the channel-cache directory holds one file per channel |
| 2 | the machine that shows the dashboard | install the release package (`pacman -Q` shows the release build), then restart `po-dashboard` (v0.74-v0.87 dashboard changes: feeds fetched conditionally, RELEASED filter, look cards held until ready) | the session on that machine | `po-dashboard --check` prints one line per project and the overview shows the release beside each project name |
| 3 | the host where `po serve` runs | restart `po-serve` so `/events.json` answers `ETag`/304 and `?since=` (v0.87) | the session on that host | `curl -sI <serve-url>/events.json` shows an `ETag` header |

**Agents:** `po setup` is new: devs write a `Setup after install` section in every item spec (steps or `None`); a look card needs `--expect` per step, fixtures and a reviewer's check (v0.81); read `AGENTS.md` "Releases and the pre-release review" (v0.80). **Adopt:** `[close] require_setup = true` (v0.84), `[release] source` (v0.83), drop or make a filter of `test_count_cmd` in a manifest with a `test` leg (v0.85). Items: v0.79-v0.89 (the entries below).

### The dashboard's feeds are fetched conditionally, never twice at once (v0.87, 2026-11-01)

Every feed (events, team, decisions, projects) still refreshes every 5 seconds, but a feed whose last fetch is still in flight skips that tick, so a slow server never has two fetches of one feed running. Fetches send `If-None-Match` with the `ETag` of the body last accepted, and a `304 Not Modified` leaves the data as it is (nothing downloaded or parsed). A server that answers `X-Po-Since: full` on the events feed is asked for `?since=<newest event time held>`; its `X-Po-Since: partial` answer holds only the events since, which the window adds; every 60th fetch is whole. A server without these headers is fetched whole each time, as before. New in `dashboard_core`: `Feed`, `feed_url_since`, `merge_since`. `examples/events-demo-server.py` serves `/events.json` with ETag/304 and `?since=`. **Agents:** nothing. **Adopt:** a feed server may send `ETag` (and answer 304) and offer `?since=` with `X-Po-Since`; install the release on the machine that shows the dashboard.

### Backlog load in one process (v0.86, 2026-11-01)

`po_backlog_load` forked one `git show` per spec file, and `po kickoff` read every spec file again for each heading rule and reloaded the backlog at every commit of its founding walk. The backlog and all spec files are now read by one `git cat-file --batch` process, the parsed backlog is memoised per commit within one run, and kickoff reads the spec files once for both rules. In a project with 135 spec files `po status` makes 28 git calls instead of 162 and `po kickoff` 37 instead of 354; the output is byte-identical. **Agents:** nothing. **Adopt:** nothing. **Note:** reading the backlog now needs `python3` on PATH (it did not before; po already used it for `po ready`, `po setup` and the feeds).

### Shared channel-events cache (v0.89, 2026-11-01)

The host's relay readers each fetched every channel's recent messages on every run. A new host script, `chan-cache`, run by a 5-minute timer, now keeps one cache file per channel (one fetch per channel per interval, then only what is newer); the readers use the cache while it is under 10 minutes old and fetch live otherwise, and the readers that post what they just checked always fetch live. Private only, no kit change, nothing exported. **Agents:** none. **Adopt:** nothing. **Setup after install:** on the build host, install the host glue and enable the new `chan-cache.timer` user timer (check: the timer lists a next run and the cache directory fills).

### `po status` probes each worktree once (v0.88, 2026-11-01)

`po status` read each open item's worktree three times (dirty count, dirty section, idle time), each a separate `git status`. One `git status -z` per worktree now feeds the dirty count and the idle time; the output is byte-identical and the git calls fewer. **Agents:** nothing. **Adopt:** nothing.

### Setup after install (v0.84, 2026-11-01)

Every item spec carries a `Setup after install` section: a table `| # | Machine | Command | Who | Check |` with one row per step, or the word `None`. With `[close] require_setup = true`, `po close` refuses (exit 6) an item whose spec lacks it or has it malformed; items founded before the switch was turned on are exempt (judged from the manifest at the item's founding commit). `po close --commit` records the steps as open in the git dir; `po setup list` shows the open ones, `po setup confirm <version> <n> --by <who>` closes one (logged as a `setup` event), `po setup record <version> --commit` writes them again from the item's tag. The manifest reader learns bare `true`/`false` for this switch. Release entries now open with a `### Setup after install` block.

**Agents:** devs write the section in every item spec (steps or `None`); whoever does a setup step confirms it with `po setup confirm`. **Adopt:** `[close] require_setup = true` (optional; absent is off).

### Stamp counts from the test leg's output (v0.85, 2026-11-01)

When `[gate.legs]` has a leg named `test`, `po stamp` takes the test count from that leg's saved output instead of running `test_count_cmd` (the whole suite again, about 43% of po-kit's stamp time). `test_count_cmd` becomes optional and means a filter: the saved output is piped to it on stdin and it never reruns the suite; the count and the cross-check with the gate's own summary are unchanged. With no `test` leg (a single `[gate] command`, or other leg names) `test_count_cmd` is still required and still runs. po-kit's own manifest now uses a sed filter. **Agents:** nothing. **Adopt:** in a manifest with a `test` leg, delete `test_count_cmd`, or make it a filter reading stdin (`cargo test 2>&1` and `uv run pytest -q 2>&1` ignore stdin and keep rerunning the suite).

### RELEASED status and the release number (v0.83, 2026-11-01)

A new optional `[release]` section says what a release is: `source = "tag"` (the newest tag matching `pattern`, default `release-*`, by version order), `"github"` (the tag a feed producer reads from GitHub and passes in; the kit never calls GitHub) or `"none"` (the default). The new read-only `po released [--json] [--release <tag>]` lists the DONE items whose item tag is an ancestor of that release tag (`git merge-base --is-ancestor`). The projects feed gains an optional per-project `release` and per-item `released` (and `setup_open`, reserved for setup steps; absent means none open). The dashboard shows a released item with no open setup step as RELEASED, with its own filter button after DONE (the counts still add up to All); one with steps open stays DONE with a muted `released, setup open`. The latest release sits right-aligned beside the project name on the overview card and the project screen, `no release` in grey. `po-dashboard --check` prints `name | light | todo/doing/done/released | <release>`. **Agents:** nothing. **Adopt:** `[release] source` (and `pattern` for `tag`) in po.toml; a feed producer fills `release` and `released` from `po released --json`.

### Look cards reach the owner only when ready (v0.81, 2026-11-01)

A look card (an action with `requires`) is held, never shown, until three checks pass: a reviewer other than the dev ran every step against the bundle's package (`checked_by`, `check_sha256`; each step has an `expect`, the card lists its `fixtures`), the owner's machine has that exact build installed and checked (`ready`, a `snapshot` of the data before a downgrade, a downgrade refused when the saved data's schema is too new for the build), and every fixture is present. The dashboard shows `Ready: <build> installed, checked <time>`, the snapshot, the fixtures and each step's `expect`; `--check` leaves held cards out. New in `dashboard_core`: `package_nvr`, `step_problems`, `fixture_problems`, `look_ready`, `hold_looks`, `installed_build`. The answer body gains `installed` (the build `pacman -Q` reports on the dashboard's machine); a receiver that refuses a look answer from another build with 409 and `X-Reason: wrong build` shows as `not sent: wrong build`. **Agents:** a look card needs `--expect` for every step, its fixtures (or `--no-fixtures`) and a reviewer's step check before it is posted; a vague or failing step comes back as `FIX?`. **Adopt:** install the release on the machine that shows the dashboard; answer receivers should accept the optional `installed` field.

### Projects tab counts by the status word (v0.82, 2026-11-01)

A status counts by its first word, so `DONE (no change needed: ...)` is DONE and its note stays visible, muted, in the row. Items whose status word is in no filter are named in a muted `n not in a filter: <items>` line on the overview card and the project screen, so a miscount is never silent. **Agents:** nothing. **Adopt:** nothing.

### A pre-release review never holds the release (v0.80, 2026-11-01)

The pre-release review (test review, code review) is read-only and runs alongside release N; release N is cut on schedule. Only the fixes on the reviewer's list ship, as the patch release `release-N.1` (CHANGELOG heading `## Release N.1 (YYYY-MM-DD): <theme>`), then `release-N.2` for a later list; everything else waits for release N+1. `AGENTS.md` has the section "Releases and the pre-release review". **Agents:** nothing new beyond reading that section. **Adopt:** nothing.

## Release 21 (2026-10-31): the dashboard's events scale (choice cards, paging, memory log, archive)

**Agents:** nothing new for agents; `po events` shows the live window only (10 days), and `po events --archived` shows older events. **Adopt:** `[events] live_days` in po.toml (optional, default 10); `--archive-url` (or `PO_DASHBOARD_ARCHIVE_URL`) on the machine that shows the dashboard; install the release where `po serve` runs so `/archive.json` exists. Not covered by tests: the dashboard's widgets (choice card layout, Archive button, Load more) are covered through their pure helpers only.

### Events older than the live window go to an archive (v0.77, 2026-10-31)

The event log keeps the last `[events] live_days` days (default 10); older events move to `po-events-archive.jsonl` beside it, at append time and by `po events --archive-now`, in one atomic rewrite that loses nothing and duplicates nothing. `po events` shows live events only; `po events --archived [--json]` shows the archive. `po serve` adds `/archive.json`. The dashboard takes `--archive-url` (or `PO_DASHBOARD_ARCHIVE_URL`): an Archive button loads the archive once, on demand, below the live events (muted `archived` marker, further pages of 50) and a second press drops it; the Reports 30 d range reads live plus archive, or says `older than the live window; archive not configured`. **Agents:** nothing new. **Adopt:** `[events] live_days` (optional, default 10); `--archive-url` on the machine that shows the dashboard; install the release where `po serve` runs.

### The Events list pages and adds only new cards (v0.76, 2026-10-31)

With Show all on, the dashboard's Events list shows the newest 50 events and a Load more button adds 50 more; the count reads `N of M` in the status line and at the list's foot. A refresh no longer rebuilds the list: it builds cards only for new events, drops the ones that left and reuses the rest, and keeps the scroll position when cards come or go above the view. Events with identical content now show once. **Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard.

### The dashboard bounds its event records and logs its memory (v0.75, 2026-10-31)

The window's `seen` and `born` records are pruned on every fetch, so they can no longer outgrow the feed. Every 60 seconds it also appends one line (time, process RSS in MB, events held, cards on screen, `len(seen)`, `len(born)`) to `$XDG_STATE_HOME/po-dashboard/memory.log` (default `~/.local/state/po-dashboard/memory.log`), capped at 1 MB; `--no-memory-log` turns it off. **Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard.

### A choice card keeps Send in view (v0.74, 2026-10-31)

Fixes the dashboard's choice cards: a long option label widened the page and pushed Send out of view. Options now stack one per line and their labels wrap inside the card; a description sits beside its option when the card is wide and under it when not; the write-in box and Send share one row below the options. Picking and the posted answer are unchanged. **Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard.

## Release 20 (2026-10-30): Copy sets explicit text and says Copied (patch to Release 19)

**Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard.

### Copy sets explicit text and says Copied (v0.73, 2026-10-30)

Fixes the Copy button next to an install command, which copied nothing on a native Wayland desktop. It now offers the text as `text/plain;charset=utf-8` and `text/plain` as well as a string, and the button reads Copied (or Copy failed) for two seconds, so a miss shows. The cause on Wayland was not reproduced on a headless host; if Copy still fails, the label says so. **Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard.

## Release 19 (2026-10-30): an action card answers as an action (patch to Release 18)

**Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard. A receiver may send `X-Reason: <class>` on a refusal.

### An action card answers as an action; the refusal reason shows (v0.72, 2026-10-30)

Fixes release 18 (and v0.69): Send built the answer from the display row, and an action card with no `requires` was read as malformed, so the answer went out as kind `unformatted` and the receiver refused it ("Bad Request"). The body now keeps the card's real kind. A refused answer also shows the receiver's reason class when it sends one in an `X-Reason` header (`not sent: bad request (kind)`; a short lowercase word or two, nothing else is shown). **Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard. A receiver may send `X-Reason: <class>` on a refusal; never content or tokens.

## Release 18 (2026-10-30): an open decision card stays open while the owner types (patch to Release 17)

**Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard.

### An open decision card stays open while the owner types (v0.71, 2026-10-30)

Fixes release 17: typing in a card's answer box closed the card after a few characters. Every 5 s refresh rebuilt every card, the box being typed in lost its focus to the first card's item line, and the next space pressed that line. A refresh that brings the same decisions now rebuilds nothing (only the "asked … ago" text moves on); a changed feed rebuilds and gives the box back its focus and cursor; a draft keeps its spaces as typed (trimmed only when sent). A card closes only on a click of its item line. **Agents:** nothing new. **Adopt:** nothing to turn on; install the release on the machine that shows the dashboard.

## Release 17 (2026-10-30): multi-line answer box, one install block per project

**Agents:** rebuild the cumulative bundle before posting a look card, name the build on the card with `requires` (`ask-mk --requires`), never write an install command on a card; action cards hold only commands that run as written. **Adopt:** on the machine that shows the dashboard, set `--install-dir` or `PO_DASHBOARD_INSTALL_DIR` to the absolute directory holding the built packages; unset, the install block says `set install_dir`. Nothing else to turn on.

### Bundle record, `requires` from the record, cards validated (v0.70, 2026-10-30)

A project keeps one bundle record naming the build and every item waiting for the owner's look; a look card is posted only for an item in the current bundle and names the build with `requires`, and a card that breaks that rule is not shown. **Agents:** rebuild the cumulative bundle before posting a look card, name the build with `requires`, never write an install command on a card.

### Cards name the build, the dashboard writes the install command (v0.69, 2026-10-30)

An action ask may carry `"requires": {"package": "<file name>", "sha256": "<64 hex>"}` (a malformed one makes the ask `unformatted`). `po-dashboard` shows one `Install this build` block per project above its cards: the sha256 check and the `sudo pacman -U` command, each with a Copy button, all paths full, built by `install_commands()` in `dashboard_core` from `--install-dir` / `PO_DASHBOARD_INSTALL_DIR` (absolute, no default; unset, the block says `set install_dir`). Cards on another build than the project's newest are marked `needs <package>: install it first`. **Agents:** name the build with `requires`; never write an install command in an action's steps. **Adopt:** `--install-dir` or `PO_DASHBOARD_INSTALL_DIR` on the viewer's machine.

### Action asks hold runnable commands only (admin, 2026-10-30)

`AGENTS.md` "Asking the owner": an action card may hold only commands that run as written, with no placeholders; if an input is not ready the card is not posted yet. **Agents:** write each command in its own code block and say where to run it. **Adopt:** nothing.

### Dashboard answer box is multi-line, with a counter (v0.68, 2026-10-30)

The write-in, note and free-text fields on a decision card are now growing, scrolling text boxes with an `n / 2000` counter (`ANSWER_MAX_TEXT` in `dashboard_core`); over the limit Send is disabled and nothing is truncated. Ctrl+Enter sends. **Agents:** nothing to do. **Adopt:** nothing.

## Release 16 (2026-10-30): dashboard answer_id fix (patch to Release 15)

Item v0.67. The dashboard's Send on a decision card was refused with 400 because the client sent a 32-hex `answer_id`; it now sends a dashed uuid4.

**Agents, in short:** nothing new to do. Update po-kit; a card that failed with 400 is re-sent from the dashboard.

### Dashboard answer_id is a dashed uuid4 (v0.67, 2026-10-29)

`po-dashboard` answers: `answer_id()` now returns a lowercase dashed uuid4 (`str(uuid.uuid4())`); the 32-hex id it sent before was refused by a receiver checking the README format, with 400 "bad request". The tests use real uuids and check the client's real body against the README format. **Agents:** `answer_id` in dashboard answers is now a dashed uuid4; a 32-hex id was refused by the receiver with 400. **Adopt:** nothing.

## Release 15 (2026-10-30): structured asks, Decisions toggle, answer receiver

Items v0.57 to v0.66 (v0.57, v0.59, v0.60, v0.62, v0.64 and v0.65 change nothing in the kit (test-only or private-only, host-side) and have no entry below. The dashboard's answer POST now waits up to 20 s (v0.64).).

**Agents, in short:** nothing new to do. The Decisions view keeps an unsent answer draft across refreshes, a `Decisions` toggle sits beside `Actions`, and the answer POST waits up to 20 s.

**Adopt, in short:** nothing new. Correction to Release 14's notes: v0.49 (dashboard answering) is listed under Release 13 but shipped in the span of Release 14; its Adopt line is `--answer-url` / `PO_DASHBOARD_ANSWER_URL` with `PO_DASHBOARD_ANSWER_TOKEN` (env only) to point the dashboard at an answer sink; and v0.53 (a read-only test review, no change to the kit) belongs in Release 14's "change nothing" list. The release-14 tag is not moved.

### Two redundant test re-checks dropped (v0.66, 2026-10-29)

Tests only: two checks in `tests/run.sh` that an exact-match just above them already covered are deleted (1266 to 1264 checks). **Agents:** nothing. **Adopt:** nothing.

### Dashboard Decisions toggle (v0.63, 2026-10-28)

`po-dashboard` Decisions view: a `Decisions` toggle beside `Actions` hides the choice entries (unformatted and legacy entries stay under both). The viewer's choice is saved with the Actions one as `{"actions": bool, "decisions": bool}` (a missing key is on, writing one key keeps the other, a broken file means both on); the status line adds `2 decisions hidden`. `--check` still ignores the filters. **Agents:** nothing. **Adopt:** nothing.

### Should-fix batch from the release 14 review (v0.61, 2026-10-28)

Dashboard answers: `post_answer` never forwards the bearer token on a redirect (a redirect is "not sent") and catches a bad status line; one rule decides when Send is allowed (a write-in alone, Pass plus a note, Pass then Failed without a step turns Send off); the payload sends lowercase `result` and `client` `po-dashboard`. `stamp.sh` no longer uses `EPOCHSECONDS` (bash 4.4 works); a non-integer `[stamp] slow_after` is refused (exit 2). `po team` without `[layout] owner_column` exits 2 (`po dispatch` keeps working without it). `po ready` checks `needs_note` as a file on main and refuses `..`, absolute paths and a leading `-`. `po dispatch` always writes the prompt file. **Agents:** run GUI tests on your own `Xvfb :NN`, never a shared display. **Adopt:** nothing.

### Dashboard keeps an unsent answer draft (v0.58, 2026-10-28)

`po-dashboard` Decisions view: an unsent answer (choice pick, write-in text, typed text, Pass/Failed, step, note) now survives the 5 s refresh; it is kept per entry, dropped when the entry leaves the feed and cleared on Send. The Failed step buttons became a toggle group so the picked step shows. **Agents:** nothing. **Adopt:** nothing.

## Release 14 (2026-10-27): gate time, ready list and dispatch, test discipline

Items v0.40 to v0.56 (v0.40, v0.41, v0.43, v0.47, v0.55 and v0.56 change nothing in the kit (private-only or test-only) and have no entry below).

**Agents, in short:** an item that changes or replaces a behaviour updates or deletes the tests that pinned the old one, and the report lists them (AGENTS.md step 2a); tell the PO when a gate passes about 5 minutes (it shows as `slow`); `po dispatch` is the PO's, like `po open` and `po close`.

**Adopt, in short:** optional: `[stamp] slow_after = N`; `[project] name`, `[ready] file`, `[dispatch] order` and `notify` (see `examples/dispatch.po.toml`); the `[[team.agent]]` roster (`examples/team.po.toml`) with `--team-url` pointed at `po serve`'s `/team.json`; `[gate] run_sentinel = "required"` with a runner that prints `RUN-END`/`RUN-ABORTED`.

- v0.54 gate duration in the stamp event: each leg gets `"seconds"` (whole wall-clock seconds, 0 for a leg not reached) and the event a top-level `"seconds"` after `legs`; an older event without them reads as unknown (`-`), never 0. `po events` has a `TOOK` column and shows each leg's time; a run over the new optional `[stamp] slow_after` (default 300) is marked `slow`; the dashboard and `po serve` have a `took` column (warning colour when slow; `po-dashboard` takes the threshold from `PO_SLOW_AFTER`). The trigger for a fast per-item gate is stated in README and AGENTS.md. **Agents:** when a gate passes about 5 minutes (the `slow` mark), tell the PO. **Adopt:** `[stamp] slow_after = N` to move the threshold.
- v0.52 tests do not grow forever, the rule (owner ruling 2026-10-26): an item that changes or replaces a behaviour updates or deletes the tests that pinned the old behaviour in the same commit; a new test is added beside them only for what is new; the report lists the tests changed or deleted (names) or says `none pinned the old behaviour`. In AGENTS.md, Devs gets a new step 2a and the PO's verify step checks that no outdated test was left behind. README.md points to the rule. **Agents:** an item that changes behaviour updates or deletes the tests that pinned it; verify checks none was left. **Adopt:** nothing.
- v0.51 dashboard Reports charts read better: the axis top is the closest round step above the highest value (12, 24, 60, not the next 1/2/5 x 10^n), empty days or hours are not drawn and a muted note under the chart counts them ("5 empty days hidden"), and every bar of gate runs, items closed and failed legs carries its count above and its date or hour below, under a line saying "each bar = one day" (or hour). The text summaries are unchanged. **Agents:** nothing to do. **Adopt:** nothing.
- v0.42 `po ready`: the ready list from backlog status. It reads a candidate file (`[ready] file` in po.toml, JSON lines `{item, title?, agents[], depends[], needs_note?}`, a shared file filtered by `[project] name`), keeps only items whose backlog status is TODO, whose dependencies are DONE and whose `needs_note` file exists, the last line for an item winning; malformed lines are reported with their line number; `--json` and `--explain` show the reasons. **Agents:** nothing to do.
- v0.45 `po dispatch --plan | --commit`: gives each ready item the first free eligible agent of the roster (`po ready` with `po team`), cheapest first in the order of the new `[dispatch] order`, one item per agent per run. `--commit` opens each with `po open --for <agent> --commit` as agent `dispatcher` (`BUZZ_AGENT`), reports a failed open and goes on (exit 6), writes the prompt to `<git dir>/po-dispatch/<item>.md` and runs the optional `[dispatch] notify` command (item, agent, prompt path). `po open --for <agent>` now fills the item's empty `[layout] owner_column` cell in the same admin commit. **Agents:** nothing. **Adopt:** `[dispatch] order = [...]` and `notify = "..."` in po.toml, see `examples/dispatch.po.toml`.
- v0.46 `[project] name` is a manifest key: the reader accepted no `[project]` section, so the filter `po ready` applies to a shared ready file by project name (v0.42) could not be configured. **Agents:** nothing. **Adopt:** `[project] name = "..."` in po.toml when several projects share one `[ready] file`.
- v0.48 the test runner fails when a block dies: multi-check blocks in `tests/run.sh` run through `block <name> <cmd>` (a non-zero exit or a missing `BLOCK-END <name>` line is a FAIL), the run ends `RUN-END <passed> <failed> <blocks>` and an EXIT trap prints `RUN-ABORTED` and exits non-zero on any other end; a self-audit test rejects an unconverted python or shell block; throwaway crashing copies of the runner prove each case. `po stamp` refuses (exit 4) a count command or leg whose output has a `RUN-ABORTED` line, and, with the new `[gate] run_sentinel = "required"`, a count command whose output has no `RUN-END` line. **Agents:** nothing. **Adopt:** `run_sentinel = "required"` and a count command that keeps the runner's exit code, if the project's runner prints `RUN-END`/`RUN-ABORTED`.
- v0.44 `po team [--json]`, the Team-view feed: one entry per `[[team.agent]]` of po.toml (`name`, `model`, `role`) with `state` (`WORKING`, or `idle <time>` from the newest gate event), `now`, `owns` (open items the `owner_column` gives the agent), `free`, and `limit_until` / `usage` merged from the optional `[team] limits_file` and `usage_file`. The manifest reader accepts `[[team.agent]]` and the two `[team]` keys. `po serve` serves the array at `/team.json`. **Adopt:** add the roster (see `examples/team.po.toml`) and point `--team-url` at `/team.json`. Nothing for agents to do.
- v0.50 the host's Projects feed producer (`projects-feed`, a script of the host glue that prints the `--projects-url` feed from `po` for each repo): private only, no kit change, nothing exported. **Agents:** none.

## Release 13 (2026-10-26): decision kinds and the Projects tab

Items v0.36 to v0.39.

**Agents, in short:** an agent asking the owner for a decision now fills in the ask's `kind` (`choice` or `action`) and its fields, as AGENTS.md "Asking the owner" says; an ask without them shows as unformatted.

**Adopt, in short:** optional: a Decisions feed entry may carry `kind`, `id` and the fields of its kind; a `--projects-url` feed (or `PO_DASHBOARD_PROJECTS_URL`) adds the Projects tab; `PO_DASHBOARD_DECISIONS_FILTER` names the Actions filter file.

- v0.36 dashboard Decisions kinds and display, read-only: a decisions entry may carry `kind` (`choice` or `action`) with a required `id`, and the fields of its kind (`question` and `options`; `machine`, `steps` and `done_when`). Each kind has a badge and colour, a malformed one shows as `unformatted`, an entry without `kind` displays as before. Choices first, then Actions, then unformatted and legacy, oldest first in each; an `Actions` toggle (saved in `$XDG_CONFIG_HOME/po-dashboard/decisions.json`) hides Action entries and the status line says `N waiting · M action hidden`; a step's command has a Copy button. Pure helpers in `dashboard_core` (`decision_shape`, `sort_decisions`, `decision_row`, filter load/save, `filter_decisions`); `--check` prints the kind first. `examples/decisions-feed.json` has one of each, the demo server serves it. **Agents:** ask the owner with a kind, see AGENTS.md "Asking the owner". Nothing is sent from the window (answering comes later).
- v0.49 dashboard **Answering decisions**: `--answer-url` / `PO_DASHBOARD_ANSWER_URL` (flag wins over env; http(s) only; none is read-only) sets an answer sink for the Decisions view; `PO_DASHBOARD_ANSWER_TOKEN` (env only) is sent as a bearer token. Each expanded card's kind gets Send controls: Choice (radio row per option + `or write your own` box), Action (Pass/Failed with a step chooser and one-line note that appear for Failed), unformatted (free text). Send posts one JSON object `{answer_id, id, project, item, kind, option, text, result, step, note, answered_at, client}` per answer (`answer_id` = uuid4 per Send, kept with the draft so Retry re-posts the same body). The POST runs in a worker thread (never blocks the UI); state is keyed by `id` in the window state, re-applied on rebuild, pruned when the entry leaves the feed. The card shows `answered · sent` (200/201, muted), `already answered` (409), `no longer waiting` (404), `refused by <host>: <code>` (401/403, +Retry), `not sent: <reason>` (other or no connection, +Retry); no Enter-to-send, no confirmation dialog. Read-only mode says `read-only` once in the status line. Pure helpers in `dashboard_core` (`answer_id`, `answer_body`, `answer_state`, `answer_state_class`, `answer_needs_retry`, extended `resolve_answer_url`, `post_answer`); `examples/events-demo-server.py` serves `POST /answers` (201 first per answer_id, 200 for a repeat, 404 for missing id, 401 without a token). **Agents:** nothing.
- v0.37 dashboard Projects feed: `--projects-url` / `PO_DASHBOARD_PROJECTS_URL`, pure helpers in `dashboard_core` (`parse_projects`, `project_counts`, `project_light`, `filter_items`, `load_projects` keeping the last data on a failed fetch), `--check` lines, `examples/projects-feed.json` served by the demo server. The Projects view follows.
- v0.38 dashboard Projects view, overview: a fourth header button (shown only with `--projects-url`) opens a grid of cards, one per project, with a status light (green active, yellow idle, red inactive; also named in the card's tooltip and accessible label), the name, and TODO, DOING and DONE counts. Cards are focusable (Enter, Space and click are a no-op until the project screen); empty and failed-fetch messages; a refresh keeps scroll and focus; `--view projects` and `--screenshot` work. New palette colour `warn` for the idle light, `project_card` helper in `dashboard_core`. Nothing for agents to do.
- v0.39 dashboard Projects view, project screen: clicking, Enter or Space on a card opens that project in place of the overview: a Back button (and Escape), the name and light, filter buttons All, TODO, DOING, DONE with counts (kept per project while the window is open), and one row per item with id, title, status badge and its agents (TODO eligible, DOING current with the live dot, DONE in order; none is a muted dash). A refresh keeps the open project and filter; a project that leaves the feed returns to the overview. New option `--project <name>` (with `--view projects`) opens straight on a project screen. State helpers and `project_screen` in `dashboard_core`. Nothing for agents to do.

## Release 12 (2026-10-25): dashboard sortable columns, Reports, Decisions fix

Items v0.31 to v0.35.

**Agents, in short:** nothing to do.

**Adopt, in short:** nothing. The dashboard gains sortable column headers (Events, Team), a Reports view with five charts (button under the header), and Decisions entries that stay open across refreshes.

- v0.31: po-dashboard column headers and sortable columns. A muted header line over the Events and Team lists labels each column (same widths as the rows); a click sorts by that column, again reverses, a third returns to the default order; an arrow marks the column. Time sorts by instant. Sorting never rewrites the saved Team order (dragging waits for the default order). Decisions unchanged.
- v0.32: po-dashboard second button row and Reports shell. In the Events view a thinner row under the header holds "Show all" (moved there) and a new "Reports" button; the row is hidden in Team and Decisions. Reports swaps the list for a pane with a 24 h / 7 d / 30 d range choice (7 d default), chart-area placeholders and the empty text "no events in this range"; range and pane survive refreshes. `--view reports` opens it.
- v0.33: po-dashboard Reports, first three charts. A pure aggregation module (`lib/po/dashboard_reports.py`, unit-tested, no GTK) turns the events feed into chart data for the chosen range, and the pane draws it with GTK's snapshot API (no new dependency): gate runs per agent (stacked pass solid / fail hatched per hour for 24 h, per day for 7 d and 30 d), first-try pass rate per agent (first stamp per project, item and agent, with n), and items closed per day stacked by project. Theme colours in light and dark, legend, a text alternative (accessible label and tooltip) per chart. Also fixes the window opening on the Team page (blank without a team feed) instead of Events.
- v0.34: po-dashboard Reports, last two charts. Item cycle time per agent (a box plot: min, quartiles, median, max and n, from an item's open event to its passing close event; unclosed items are left out) and failed legs by kind over time (stacked per hour or day; the six leg names with most failures keep a colour, the rest group as "other"). Both come from `lib/po/dashboard_reports.py` with tests; the README lists the five charts and the feed fields they read; `examples/events-demo-server.py` now emits open and close events too.
- v0.35: po-dashboard Decisions entries stay open across refreshes. An entry expanded in the Decisions view used to collapse again at the next refresh; the window now keeps the expanded entries (by project and item) and re-applies them on every rebuild, and an entry that leaves the feed drops out. Nothing for agents to do.

## Release 11 (2026-10-25): failed-gate evidence, stamp prepare, dashboard polish

Items v0.24 to v0.30.

**Agents, in short:** read the tail or the log of a failed gate before asking why it failed; run the formatter through `[stamp] prepare` or by hand before stamping.

**Adopt, in short:** optional: `[stamp] prepare = ["cargo fmt"]` (or `ruff format .`); feed producers may add `asked_by`.

### Dashboard menu entry (v0.30, 2026-10-25)

`bin/po-dashboard-install` adds a po-dashboard entry and its icons to the user's desktop menu (`--prefix <dir>` for tests, `--uninstall` to remove).

**Agents:** nothing to do.

**Adopt:** nothing.

### The po-kit logo (v0.28, 2026-10-25)

The logo files live in `assets/logo/` (SVG and PNGs 16 to 1024); the dashboard window uses it as its icon and the README shows it at the top.

**Agents:** nothing to do.

**Adopt:** nothing.

### Dashboard: Show all stays put across views (v0.29, 2026-10-25)

The Show all toggle sits left of the view buttons and is hidden by opacity, so switching to Team or Decisions moves nothing.

**Agents:** nothing to do.

**Adopt:** nothing.

### Dashboard: screenshot and check runs never activate a running dashboard (v0.24, 2026-10-24)

`po-dashboard --screenshot` and `--check` now register the GTK application as NON_UNIQUE, so they no longer hand off to the user's open dashboard (no stray windows, the PNG is written).

**Agents:** nothing to do.

**Adopt:** nothing.

### Dashboard: Decisions entries collapse and expand (v0.25, 2026-10-25)

Each Decisions entry shows one line (project, item, short title, when, and the optional `asked_by` muted); clicking it expands the full `waiting_for`, wrapped, line breaks kept; clicking again collapses. The feed row gains an optional `asked_by` string.

**Agents:** nothing to do.

**Adopt:** feed producers may add `asked_by`.

### Failed gates keep their evidence (v0.26, 2026-10-25)

A failed `po stamp` event now carries `tail` on the failing leg (its last 40 lines, redacted) and `log`, the path of the full redacted output kept under `po-logs/` in the git dir. `po events`, `po serve` and po-dashboard show the tail. `po-logs/` is never pruned.

**Agents:** read the tail or the log before asking why a gate failed.

**Adopt:** nothing.

### Stamp prepare step (v0.27, 2026-10-25)

An optional `[stamp] prepare` array in `po.toml` lists commands (a formatter, for example) that `po stamp` runs in the worktree before the gate, so formatting cannot fail it. The evidence block names each line (`prepare ran: <line>`), the event gets a `prepare` leg, and a failing line fails the stamp with its tail kept. `po doctor` offers it.

**Agents:** run the formatter through `prepare` (or by hand) before stamping; the stamp will not fail on formatting alone.

**Adopt:** `[stamp] prepare = ["cargo fmt"]` (or `ruff format .`), by the project's PO.

## Release 10 (2026-10-24): usage limit in the Team view

Item v0.23.

**Agents, in short:** nothing to do.

**Adopt, in short:** optional: add `limit_until` and `usage` to the team feed rows.

### Dashboard: one Status column in the Team view (v0.23, 2026-10-24)

The Team view's separate state and FREE columns become one **Status** column: `LIMIT until <time>` (the viewer's local time, with the date when not today; fail colour; wins over the rest), WORKING (live dot), FREE, or the state as given (`idle 22m`, muted). Rows may carry `limit_until` (ISO time or null; a past, null, absent or unparseable value is no limit) and `usage` (`{five_hour, seven_day}`, each 0-1, shown after the status as muted percentages, only the valid parts). Old feeds work unchanged. `--check` prints the status and usage too.

**Agents:** nothing to do.

**Adopt:** optional: add `limit_until` and `usage` to the team feed rows.

## Release 9 (2026-10-24): manifest-driven briefs and closes, Decisions view

Items v0.20, v0.21, v0.22.

**Agents, in short:** nothing to do; when a project sets `[kickoff] preamble`, it is the first lines of `po kickoff`, and a `[close] checklist` is printed after `po close --commit` (`--run-checklist` runs it).

**Adopt, in short:** optional: `[kickoff] preamble = [...]` and `[close] checklist = [...]` in `po.toml`; `--decisions-url` for the dashboard's Decisions view.

### Dashboard: Decisions view (v0.22, 2026-10-24)

`po-dashboard` gets a third view, **Decisions**, shown in the header toggle only when `--decisions-url` (or `PO_DASHBOARD_DECISIONS_URL`) names a JSON array of `{project, item, title, waiting_for, asked_at, thread_url?}`; there is no default. One line per entry, oldest `asked_at` first (a missing or unreadable one goes last), shown relative with the local time as tooltip; `thread_url` is muted, copyable text, never opened. It refreshes with the events; a failed fetch keeps the last data and says so. Read-only. `--check` prints the entries too; `--view decisions` without a feed exits 1. See `examples/decisions-feed.json`.

**Agents:** nothing to do.

**Adopt:** optional: point `--decisions-url` at a feed of items waiting on a human decision.

### Close: a checklist from the manifest (v0.21, 2026-10-24)

An optional `[close] checklist = ["line", ...]` in `po.toml` (a one-line array of quoted strings, like `[kickoff] preamble`) is printed by `po close --commit` under a `CHECKLIST` heading once the boundary is complete, before any `[hooks] on_close` command. With the new `--run-checklist` flag each non-blank line is also run (`sh -c` in the main worktree, output to stderr; `PO_VERSION`, `PO_TAG`, `PO_TITLE`, `PO_REPO` set); all lines run even if one fails, and a failure is a warning and exit 7 with the boundary standing. The dry run lists the checklist and runs nothing. Without the section, or with `[]`, `po close` is unchanged; `--run-checklist` without one is a usage error. A value that is not an array of quoted strings, or another key under `[close]`, is a manifest error (exit 2). `po doctor` lists the key as available to adopt.

**Agents:** nothing to do unless a project's checklist says so; the PO reads the printed lines after a close.

**Adopt:** optional: add `[close] checklist = [...]` to `po.toml`.

### Kickoff: a preamble from the manifest (v0.20, 2026-10-24)

An optional `[kickoff] preamble = ["line", ...]` in `po.toml` (a one-line array of quoted strings; an empty string is a blank line) is printed by `po kickoff` verbatim at the top of every brief, followed by a blank line, so a project can make its start-of-item steps part of the prompt. Without the section, or with `[]`, the output is byte-identical to before. A value that is not an array of quoted strings, or another key under `[kickoff]`, is a manifest error (exit 2). `po doctor` lists the key as available to adopt.

**Agents:** nothing to do; the preamble, when a project sets one, is the first lines of the brief.

**Adopt:** optional: add `[kickoff] preamble = [...]` to `po.toml`.

## Release 8 (2026-10-24): reorder the Team view

Item v0.19.

**Agents, in short:** nothing to do.

**Adopt, in short:** nothing.

### Dashboard: reorder the Team view (v0.19, 2026-10-24)

In the Team view of `po-dashboard`, drag a line onto another to take its place, or press Alt+Up/Down on a focused line. The order is saved on the viewer's machine in `$XDG_CONFIG_HOME/po-dashboard/team-order.json` (default `~/.config`; `PO_DASHBOARD_TEAM_ORDER` names another file), applied on every refresh and at start, and survives restarts. Agents not in the saved order go last, in the feed's order; a missing or corrupt file means no order. The feed stays read-only. `--check` applies the saved order too.

**Agents:** nothing to do.

**Adopt:** nothing.

## Release 7 (2026-10-24): model in the Team view

Item v0.18.

**Agents, in short:** nothing to do.

**Adopt, in short:** optional: add a `model` string to the team feed rows.

### Dashboard: model in the Team view (v0.18, 2026-10-24)

The team feed's rows gain an optional `model` string (a short label such as "Big Model (API)"). `po-dashboard` shows it on each agent's line, after the name, in the muted text style, and shows nothing when it is absent or not a string. `--check` lines show `name · model`. Feed shape is now `{agent, model?, state, now, owns[], free}`; `examples/team-feed.json` and the README are updated.

**Agents:** nothing to do.

**Adopt:** optional: have the team feed serve `model`.

## Release 6 (2026-10-24): new events fade in

Item v0.17.

**Agents, in short:** nothing to do.

**Adopt, in short:** nothing.

### Dashboard: new events fade in (v0.17, 2026-10-24)

In the Events view of `po-dashboard`, an event that appears while the window is open starts with its card 25% darker (25% lighter in the dark theme) and eases back to the normal card colour over 60 s. Events present at window open or at a view switch start normal. Text keeps WCAG AA contrast at every step. With reduced motion the highlight stays and drops after 60 s without animating. `po serve` pages do the same in CSS. New `--screenshot-delay <s>` option and `examples/events-demo-server.py` (a sample feed with a new event every N s).

**Agents:** nothing to do.

**Adopt:** nothing.

## Release 5 (2026-10-24): dashboard Team view

Item v0.16.

**Agents, in short:** nothing to do.

**Adopt, in short:** optional: point `po-dashboard` at a team feed with `--team-url` or `PO_DASHBOARD_TEAM_URL`.

### Dashboard: Team view (v0.16, 2026-10-24)

- `po-dashboard` gets a second view, toggled from the header (Events | Team),
  when a team feed is set with `--team-url <url-or-file>` or
  `PO_DASHBOARD_TEAM_URL` (no default; without it there is no toggle).
  `--view team` starts in it.
- The feed is a JSON array of `{agent, state, now, owns[], free}`. Each agent
  is one neumorphic line: name, state (a live dot when it starts with WORKING,
  otherwise as given), the item it works on now, the items it owns, and a FREE
  badge. It refreshes with the events; a failed fetch keeps the last data and
  says so. `--check` prints the team lines too. `examples/team-feed.json` is a
  sample.
- **Agents:** nothing. **Adopt:** the option above.

## Release 4 (2026-10-24): one line per event, note icon

Item v0.15.

**Agents, in short:** nothing to do.

**Adopt, in short:** nothing.

### Dashboard and viewer: one line per event (v0.15)

- `po-dashboard` shows each event as one single-line card in fixed columns
  (result, item, project, kind, checks, agent, time, note); long values
  ellipsize with the full text as a tooltip, and the project and checks
  columns widen with the window. An event with a detail shows a note icon
  whose tooltip and accessible label are the detail; the separate detail line
  is gone. `po serve`'s pages use the same one-row layout and note icon.
- **Agents:** none.
- **Adopt:** none.

## Release 3 (2026-10-24): the desktop event viewer

Item v0.14.

**Agents, in short:** nothing to do; `po-dashboard` is a window for the person
who wants to watch the gate events, read-only: run it only when asked.

**Adopt, in short:** `pacman -S gtk4 python-gobject`, only where the window is
wanted.

### `po-dashboard` (v0.14)

- `bin/po-dashboard` is a desktop window (GTK 4, own neumorphic CSS, light
  and dark following the desktop) for the gate events of a `po serve`: the
  last 10 as cards, a "Show all" toggle, a refresh every 5 seconds, an error
  line that keeps the last data. The URL comes from `--url` or
  `PO_DASHBOARD_URL`; there is no default address.
- **Agents:** it is read-only but stays open until closed, so run it only
  when asked.
- **Adopt:** `pacman -S gtk4 python-gobject`, only where the window is wanted.

## Release 2 (2026-10-23): gate events and a viewer

Items v0.12 and v0.13.

**Agents, in short:** nothing to do; `po stamp`, `po open` and `po close` now log
each run, and `po events` reads the log. `po serve` is a read-only viewer that
stays up until stopped: run it only when asked.

**Adopt, in short:** nothing.

### `po events` (v0.12)

- `po stamp` logs every run, passing or failing, and `po open` and
  `po close` log one event each after a complete `--commit`, as one JSON
  object per line in `po-events.jsonl` in the common git dir. A log that
  cannot be written warns and changes nothing else. `po events [--all]
  [--json]` reads it back, newest first (last 10 by default; local time in
  the table, UTC in `--json`).
- **Agents:** none; stamp, open and close log by themselves. `po events`
  is read-only and free to use.
- **Adopt:** none.

### `po serve` (v0.13)

- `po serve [--bind <addr>] [--port <n>]` is a read-only web viewer of the
  gate events: the last 10 at `/`, all at `/all`, JSON at `/events.json`. It
  reads them only through `po events --json`, refreshes every 5 seconds, and
  shows times in the browser's local zone. It binds 127.0.0.1:8765 by default
  and refuses a wildcard address; GET only, every other method is 405.
- **Agents:** `po serve` is read-only but stays up until stopped, so run it
  only when asked.
- **Adopt:** none.

## Release 1 (2026-10-22): reports, idle time, owners, installs, annotated tags

Items v0.8, v0.9, v0.10, v0.11 and v0.4.1, the rest of the backlog after v0.7.

**Agents, in short:** the PO builds reports with `po report` and spots stalls
with `po status --idle <minutes>`; devs still stop at `po stamp`; after this
release run `po doctor` to see what your project could adopt.

**Adopt, in short:** `[layout] owner_column` where the backlog has an owner
column; `[versioning] tag_style = "annotated"` where tags are annotated.

### `po report` (v0.8, 2026-10-22)

- `po report [--note <text>]...` prints the item report as one markdown block:
  files changed, the newest stamp verbatim, numbered notes. Read-only; exit 4
  with empty stdout when the stamp is missing, names another HEAD or dirty
  count, or a changed file is newer than it.
- **Agents:** the PO runs `po report` after `po stamp` to build a report;
  devs still stop at `po stamp`.
- **Adopt:** none.

### idle time in `po status` (v0.9, 2026-10-22)

- Each DOING item shows `idle 3h12m` (`idle -` with no worktree).
  `po status --idle <minutes>` lists items idle longer under `IDLE (n)` and
  exits 8.
- **Agents:** the PO may run `po status --idle <minutes>` to spot stalls.
- **Adopt:** none.

### owners from the backlog (v0.10, 2026-10-22)

- `[layout] owner_column` names a backlog table column. `po open` and
  `po close --next` take the owner from it when `--for` is absent; a `--for`
  that disagrees with the cell exits 3. `po status` and `po kickoff` print the
  owner. Without the key nothing changes.
- **Agents:** none.
- **Adopt:** `[layout] owner_column = "<column>"` where the backlog has an owner column.

### releases and adopters (v0.11, 2026-10-22)

- `bin/po-install [<tag>]` makes a tag the live `po` (detached worktree under
  `~/.local/share/po-kit/<tag>`, symlink switched, old and new tag printed).
  Tags only: it refuses a branch, an unknown tag, a dirty install directory,
  or a tag that breaks an adopter's manifest the old one accepted (exit 6).
- `po version` prints the installed tag. `po doctor` checks every repo in
  `~/.config/po-kit/adopters`: manifest parses, `po status` runs, unset optional
  keys listed as available to adopt. Read-only; exit 2 on a failing adopter.
- **Agents:** run `po doctor` after a po-kit release to see what you could adopt;
  `po version` tells you which release you are on.
- **Adopt:** none (po-kit's own `[hooks] on_close` for `po-install` comes later).

### `[versioning] tag_style` (v0.4.1, 2026-10-22)

- `[versioning] tag_style = "light" | "annotated"` (default light). With
  `annotated`, `po close --commit` writes an annotated tag (`git tag -a`) at the
  item commit, signed as the repo's git config says. Light is unchanged.
- **Agents:** none.
- **Adopt:** `[versioning] tag_style = "annotated"` for a project whose tags are
  annotated.

## Before releases (one entry per item, v0.1–v0.7)

### pytest counting in `po stamp` (v0.7, 2026-10-21)

- `po stamp` counts pytest summaries as well as libtest.
- **Agents:** in Python projects, `po stamp` is the gate evidence too.
- **Adopt:** `[gate] test_format = "pytest"` in Python projects.

### `[hooks] on_close` (v0.6, 2026-10-21)

- `po close --commit` runs a manifest command after a complete boundary, with
  the boundary's facts as `PO_*` variables; exit 7 if it fails.
- **Agents:** none.
- **Adopt:** `[hooks] on_close`.

### `po kickoff` (v0.5, 2026-10-21)

- Prints the item's spec section, the rules pointer and the rulings since the
  last boundary: the mechanical half of a cold prompt.
- **Agents:** the PO starts every cold prompt from `po kickoff <v>`.
- **Adopt:** none.

### `po open` / `po close` (v0.4, 2026-10-19)

- The boundary admin: found or start an item, close it (ff, tag, admin commit,
  next item, prune), dry run by default.
- **Agents:** only the PO runs them with `--commit`.
- **Adopt:** optional `[layout] main`.

### `po fresh` (v0.3, 2026-10-19)

- REBASE REQUIRED (exit 5) when an item branch is behind main.
- **Agents:** re-check before a close; rebase and re-stamp when told.

### `po stamp` (v0.2, 2026-10-19)

- The evidence block, from the gate actually run; `gate-<n>.txt` per run.
- **Agents:** quote the stamp block verbatim; never hand-type results.
- **Adopt:** `[gate.legs]`, `test_count_cmd`; add `gate-*.txt` to .gitignore.

### `po status` / `po prune` (v0.1, 2026-10-19)

- The manifest (`po.toml`), the open-items view, and pruning merged worktrees.
