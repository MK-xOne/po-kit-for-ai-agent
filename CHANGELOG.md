# po-kit changelog

Items and releases are different things. Every item close tags its item
(`v0.8`, `v0.9`, ...); that is po's boundary law. A **release** bundles the
items of one backlog scope and is cut once that scope is done, as the
annotated tag `release-N`.

Each item's notes say what changed, what agents must now do (**Agents**), and
which optional manifest keys a project may turn on (**Adopt**, by its PO's
admin commit). At each item close they go under **Unreleased**; at a release,
Unreleased becomes `## Release N (YYYY-MM-DD): <theme>`.

## Unreleased

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
