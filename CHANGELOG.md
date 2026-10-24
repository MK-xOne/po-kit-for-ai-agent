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
