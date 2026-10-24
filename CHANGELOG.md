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

Nothing yet.

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
