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
  run, pass or fail, and every `po open` and `po close --commit`; last 10,
  `--all`, `--json`), `po serve [--bind <addr>] [--port <n>]` (a read-only web
  viewer of those events, loopback by default; run it only when asked, it stays
  up until stopped; `po-dashboard --url <events url>` is the same as a desktop
  window, also only when asked; `--team-url <feed>` or `PO_DASHBOARD_TEAM_URL` adds its Team view, `--decisions-url <feed>` or `PO_DASHBOARD_DECISIONS_URL` its read-only Decisions view; a new event fades in, 60 s), `po version` (the installed tag), `po doctor` (does
  every adopter's manifest still work under the installed po, and which optional
  keys could it adopt).
- **The PO's only:** `po open`, `po close`, `po prune` with `--commit`, and every
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
po never pushes: pushing is the PO's own step after a close.

## When po-kit changes

po-kit ships in releases that bundle several items. Each release's
`CHANGELOG.md` entry has **Agents** lines (what agents must now do) and
**Adopt** lines (optional manifest keys a project may turn on, by its PO's
admin commit).
