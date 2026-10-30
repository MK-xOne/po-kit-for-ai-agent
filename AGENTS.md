# po-kit for agents

How a coding agent (or a person) uses the `po` command in a repository that has
a `po.toml`. Read it, and the newest release in `CHANGELOG.md`, at the start of a
session that touches an item. Full reference: `README.md`. Per-project settings:
the repo's `po.toml`. Installed version: `po version`.

Two roles: the **PO** (product owner) opens, verifies and closes items and owns
every backlog status; **devs** each work one item in its own worktree.

## Everyone

- **Evidence is `po stamp`.** Run it in the item's worktree after the gate
  passes. It runs the gate itself and writes `gate-<n>.txt`. Quote its block
  verbatim; a hand-typed result is never evidence.
- **Read-only, use freely:** `po status` (open items, owners, idle time,
  worktrees, dirt; `--idle <minutes>` flags stalls), `po fresh <v>` (is the
  branch behind main), `po kickoff <v>` (the item's spec section and the rulings
  since the last boundary), `po events` (the gate event log: every `po stamp`
  run, pass or fail, and every `po open` and `po close --commit`; a failed
  stamp shows its failing leg's last 40 lines and names its full log; last 10,
  `--all`, `--json`), `po serve [--bind <addr>] [--port <n>]` (a read-only web
  viewer of those events, loopback by default; run it only when asked, it stays
  up until stopped; `po-dashboard --url <events url>` is the same as a desktop
  window, also only when asked; `--team-url <feed>` or `PO_DASHBOARD_TEAM_URL` adds its Team view, `--decisions-url <feed>` or `PO_DASHBOARD_DECISIONS_URL` its read-only Decisions view; a new event fades in, 60 s), `po dispatch --plan` (who would get which ready item), `po team [--json]` (the Team-view feed from the manifest roster, the events and the backlog owner column), `po version` (the installed tag), `po doctor` (does
  every adopter's manifest still work under the installed po, and which optional
  keys could it adopt).
- **The PO's only:** `po open`, `po close`, `po prune`, `po dispatch` with `--commit`, and every
  backlog status. Without `--commit` they print a plan and change nothing; a dev
  may run them that way to check.
- **Exit codes:** 1 usage, 2 manifest or repo, 3 backlog disagreement, 4 a gate
  leg or count failed (nothing written), 5 REBASE REQUIRED, 6 refused by the
  item law, 7 the close hook failed (the boundary stands), 8 an item is idle
  past `--idle`.
- **A defect or a missing feature in po** is reported to the PO, not patched
  from inside another project's item.

## Devs

1. `cd` into the worktree the prompt names, then `pwd`.
2. Do the item. Gate with the repo's own command (e.g. `./check.sh`).
2a. An item that changes or replaces a behaviour updates or deletes the tests that pinned the old behaviour, in the same commit. A new test is added beside them only for what is new. Report lists the tests changed or deleted (names) or says `none pinned the old behaviour`.
3. `po stamp` in the worktree; on exit 4, fix and run it again.
4. Report: `po report [--note <text>]...` prints the report block (files changed,
   the newest stamp verbatim, numbered notes) from a fresh stamp; exit 4 if it
   is stale.
5. Stop without committing until the PO says to commit; then commit and
   `po stamp` again at dirty 0.

## PO

`po open` → the dev's brief (`po kickoff` is its mechanical half) → verify with
`po stamp` → rulings → commit → `po close` → `po prune`. Before `po close`,
`po fresh` must pass; when main moved, rebase the item branch and re-stamp.
po never pushes: pushing is the PO's own step after a close. Verify also checks
that no outdated test was left behind: for a changed behaviour, search the tests
for the old name, flag, output or exit code, and send back any that still pins it
(or passes only because it no longer checks anything).

**Slow gate trigger.** Every stamp event records the seconds it took, and `po events` and the dashboard mark a run over `[stamp] slow_after` (default 300) as `slow`. When a gate goes over about 5 minutes, the PO specs a fast per-item gate and runs the full suite nightly and before each release; those tiers are not built until then.

## Asking the owner

An agent that asks the owner for a decision gives the ask a kind, so the Decisions view
can show it as a card. The ask carries an `id` (the ask's own message id) and its
`waiting_for` line.

- **Choice:** one clear question and two or more options, each with a label and a one-line
  description; the recommended option first and marked `recommended`. The two-way
  approve or deny becomes a two-option choice, e.g. `Approve the import screen?` with
  `Approve (recommended): ships as specified` and `Deny: back to spec`.
- **Action:** the machine, numbered steps with one thing per step and every command in its
  own `command` field, and `done_when`: what the person answering should see if it worked, e.g.
  `On the build host: 1. restart the viewer ... done when the page shows the new tag`.

An action holds only commands that run as written: no placeholders such as `<package>`.
If an input is not ready (a file not yet delivered, a package not yet built), do not post
the card yet. Each command sits in its own copy-paste code block and names where to run it.

**A look card is posted only when its item is in the current bundle:** rebuild the cumulative
bundle first. The card names the build with `requires` and carries no install command. A card
with a placeholder, a bare install-file name, an install step beside `requires`, or a `requires`
that is not the current bundle is not shown, and its asker gets one `FIX?` with the reason.

An ask without these fields shows as `unformatted` and may wait longer.

## When po-kit changes

po-kit ships in releases that bundle several items. Each release's
`CHANGELOG.md` entry has **Agents** lines (what agents must now do) and
**Adopt** lines (optional manifest keys a project may turn on, by its PO's
admin commit).
