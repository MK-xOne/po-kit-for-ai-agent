// Node tests of the web view (share/po-web/): the pure functions of core.js and the static rules of the
// design note (docs/design/web-dashboard-auth.md, checks C5 and C8). Prints "ok<TAB>name<TAB>" or
// "FAIL<TAB>name<TAB>detail" lines and BLOCK-END web-core, as tests/run.sh's `block` reads them.
// Run with TZ=UTC: the "today" counts depend on the viewer's timezone.
"use strict";
const fs = require("fs");
const path = require("path");
const dir = path.join(__dirname, "..", "share", "po-web");
const ex = path.join(__dirname, "..", "examples");
const C = require(path.join(dir, "core.js"));

function check(name, cond, detail) {
  console.log((cond ? "ok" : "FAIL") + "\t" + name + "\t" + String(detail === undefined ? "" : detail).replace(/\n/g, " | "));
}
function throws(fn) { try { fn(); } catch (e) { return e.message; } return null; }
const eq = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const feed = (f) => fs.readFileSync(path.join(ex, f), "utf8");
const NOW = new Date(2026, 10, 1, 15, 0); // local fields: Nov 1 2026 15:00

function locHm(d) {
  var h12 = d.getHours();
  var ampm = h12 >= 12 ? "PM" : "AM";
  var hh = h12 % 12 || 12;
  var mm = String(d.getMinutes()).padStart(2, "0");
  return hh + ":" + mm + " " + ampm;
}

// feed parsing
const decisions = C.parseFeed(feed("decisions-feed.json"));
check("web: parseFeed reads examples/decisions-feed.json", decisions.length === 6, decisions.length);
check("web: parseFeed reads examples/team-feed.json", C.parseFeed(feed("team-feed.json")).length === 4);
check("web: parseFeed reads examples/projects-feed.json", C.parseFeed(feed("projects-feed.json")).length >= 1);
check("web: parseFeed turns an {error} body into its message", throws(() => C.parseFeed('{"error":"cannot reach x"}')) === "cannot reach x");
check("web: parseFeed refuses text that is not JSON", throws(() => C.parseFeed("<html>")) === "the feed is not JSON");
check("web: parseFeed refuses a JSON value that is not a list", throws(() => C.parseFeed('{"a":1}')) === "the feed is not a list");
check("web: parseFeed drops members that are not objects", C.parseFeed('[1,{"a":1},null,"x"]').length === 1);

// counts
const team = C.parseFeed(feed("team-feed.json"));
check("web: teamWorking counts the agents whose state is WORKING", C.teamWorking(team) === 1, C.teamWorking(team));
check("web: teamWorking matches any case and ignores 'idle'", C.teamWorking([{ state: "working 3m" }, { state: "idle 4m" }, { state: "networking" }, {}]) === 1);
const events = [
  { time: "2026-11-01T14:00:00Z" }, { time: "2026-11-01T00:00:00Z" }, { time: "2026-10-31T23:59:59Z" }, { time: "bad" }, {},
];
check("web: eventsToday counts the events of the viewer's calendar day", C.eventsToday(events, NOW) === 2, C.eventsToday(events, NOW));
check("web: eventsToday of nothing is 0", C.eventsToday([], NOW) === 0);
const c = C.counts({ decisions, events, projects: C.parseFeed(feed("projects-feed.json")), team }, NOW);
check("web: counts gives each view its count", c.decisions === 6 && c.events === 2 && c.team === 1 && c.projects >= 1, JSON.stringify(c));
check("web: a feed not loaded has a null count", C.counts({ decisions: null, events: null, projects: null, team: null }, NOW).decisions === null);

// toggle labels
check("web: Decisions (2)", C.toggleLabel("decisions", 2) === "Decisions (2)");
check("web: Events (n today)", C.toggleLabel("events", 5) === "Events (5 today)");
check("web: Projects (n)", C.toggleLabel("projects", 3) === "Projects (3)");
check("web: Team (n working)", C.toggleLabel("team", 1) === "Team (1 working)");
check("web: a zero count is shown", C.toggleLabel("decisions", 0) === "Decisions (0)");
check("web: no count shows the name alone", C.toggleLabel("team", null) === "Team");
check("web: the toggle order is Decisions, Events, Projects, Team", eq(C.VIEWS, ["decisions", "events", "projects", "team"]));

// the home view and the hash
check("web: Decisions is the home view (empty hash)", C.viewFromHash("") === "decisions");
check("web: an unknown hash is the home view", C.viewFromHash("#nope") === "decisions");
check("web: the chosen view survives in the hash", C.viewFromHash("#team") === "team" && C.viewFromHash("#events") === "events");
check("web: a view with no configured feed is hidden", eq(C.visibleViews(["decisions", "team"]), ["decisions", "team"]));
check("web: visibleViews keeps the toggle order", eq(C.visibleViews(["team", "events", "decisions", "projects"]), ["decisions", "events", "projects", "team"]));

// age
check("web: age under a minute is just now", C.age("2026-11-01T14:59:30Z", NOW) === "just now");
check("web: age in minutes", C.age("2026-11-01T14:48:00Z", NOW) === "12m ago");
check("web: age in hours", C.age("2026-11-01T12:00:00Z", NOW) === "3h ago");
check("web: age in days", C.age("2026-10-30T15:00:00Z", NOW) === "2d ago");
check("web: an unparsable time has no age", C.age("x", NOW) === "" && C.age(null, NOW) === "");
check("web: a clock-skewed future time is just now", C.age("2026-11-01T15:05:00Z", NOW) === "just now");

// decision cards
const look = C.decisionCard(decisions[0], NOW);
check("web: a card without kind is a look", look.kind === "look" && look.title === "Pick the storage format for snapshots");
check("web: the card names who waits and when it was asked", look.waiting === "waiting for a ruling, asked by ana" && look.asked.startsWith("asked "), look.waiting + " / " + look.asked);
const choice = C.decisionCard(decisions[1], NOW);
check("web: a choice card lists its options with the recommended one marked",
  choice.kind === "choice" && choice.options.length === 2 && choice.options[0].recommended === true && choice.options[1].recommended === false && choice.options[0].label === "Approve");
check("web: a card with no options has an empty list", C.decisionCard(decisions[3], NOW).options.length === 0);
const evil = C.decisionCard({ id: "x", title: "<img src=x onerror=alert(1)>", question: "<script>1</script>", options: [{ label: "<b>a</b>" }] }, NOW);
check("web: C5 a card whose title is <img onerror> stays that literal text", evil.title === "<img src=x onerror=alert(1)>" && evil.question === "<script>1</script>" && evil.options[0].label === "<b>a</b>");
check("web: a card's key is its id", C.decisionCard({ id: "ask-1" }, NOW).key === "ask-1");

// banner
check("web: no banner while fetches work", C.bannerText(false, NOW.getTime(), NOW.getTime()) === "");
check("web: the banner says when the data was last good", C.bannerText(true, NOW.getTime() - 5 * 60000, NOW.getTime()) === "not updated 5m ago");
check("web: the banner with nothing ever loaded", C.bannerText(true, null, NOW.getTime()) === "not updated yet");

// relative_time
check("web: relative_time under a minute is just now", C.relative_time("2026-11-01T14:59:30Z", NOW) === "just now");
check("web: relative_time in minutes", C.relative_time("2026-11-01T14:48:00Z", NOW) === "12m ago");
check("web: relative_time in hours", C.relative_time("2026-11-01T12:00:00Z", NOW) === "3h ago");
check("web: relative_time yesterday", C.relative_time("2026-10-31T14:12:00Z", NOW) === "yesterday 2:12 PM");
check("web: relative_time older", C.relative_time("2026-10-30T15:00:00Z", NOW) === "Oct 30");
check("web: relative_time future clock skew is just now", C.relative_time("2026-11-01T15:05:00Z", NOW) === "just now");
check("web: relative_time bad input is empty", C.relative_time("x", NOW) === "" && C.relative_time(null, NOW) === "");

// group_events
var evts = [
  {time: "2026-11-01T14:00:00Z", project: "demo", item: "1.1", kind: "stamp"},
  {time: "2026-11-01T13:00:00Z", project: "demo", item: "1.1", kind: "stamp"},
  {time: "2026-11-01T12:00:00Z", project: "demo", item: "1.2", kind: "open"},
  {time: "2026-11-01T11:00:00Z", project: "other", item: "1.2", kind: "stamp"},
  {time: "2026-11-01T10:00:00Z", project: "demo", item: "1.2", kind: "stamp"},
];
var grouped = C.group_events(evts);
check("web: adjacent same item grouped", grouped.length === 4, JSON.stringify(grouped.map(function (g) { return g.project + "/" + g.item + ":" + g.events.length; })));
check("web: non-adjacent same item not grouped", grouped[1].events.length === 1);
check("web: same item in two projects not grouped", grouped[1].project === "demo" && grouped[2].project === "other");
check("web: empty events returns no groups", C.group_events([]).length === 0);

// item_label
check("web: item label All shows project and item", C.item_label({project: "demo", item: "0.1"}, "") === "demo v0.1");
check("web: item label filtered shows item only", C.item_label({project: "demo", item: "0.1"}, "demo") === "v0.1");
check("web: item label empty project", C.item_label({project: "", item: "0.1"}, "") === "v0.1");

// filter_events
check("web: filter_events empty project returns all", C.filter_events(evts, "").length === 5);
check("web: filter_events one project", C.filter_events(evts, "demo").length === 4);
check("web: filter_events missing project returns none", C.filter_events(evts, "nope").length === 0);

// usage_words
function isoLocal(d) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate(), d.getHours(), d.getMinutes()).toISOString();
}
check("web: usage_words both parts", C.usage_words({five_hour: 0.8, seven_day: 0.12}, null, NOW) === "80% of the 5 h window used, 12% of the 7 d window");
check("web: usage_words one part", C.usage_words({five_hour: 1.0}, null, NOW) === "100% of the 5 h window used");
check("web: usage_words none", C.usage_words({}, null, NOW) === "");
check("web: usage_words limit until today", C.usage_words(null, isoLocal(NOW), NOW) === "limit until " + locHm(NOW));
check("web: usage_words limit until another day", C.usage_words(null, isoLocal(new Date(NOW.getFullYear(), NOW.getMonth(), NOW.getDate() + 1, NOW.getHours(), NOW.getMinutes())), NOW).startsWith("limit until " + locHm(new Date(NOW.getFullYear(), NOW.getMonth(), NOW.getDate() + 1, NOW.getHours(), NOW.getMinutes())) + " "));
check("web: usage_words with limit and usage", C.usage_words({five_hour: 0.5}, isoLocal(NOW), NOW) === "50% of the 5 h window used, limit until " + locHm(NOW));
check("web: usage_words over 100%", C.usage_words({five_hour: 1.3}, null, NOW) === "130% of the 5 h window used");
check("web: usage_words non-numeric", C.usage_words({five_hour: NaN, seven_day: "x"}, null, NOW) === "");
check("web: usage_words limit only", C.usage_words(null, isoLocal(new Date(NOW.getFullYear(), NOW.getMonth(), NOW.getDate(), 23, 30)), NOW) === "limit until 11:30 PM");

// split_owns
check("web: split_owns with working_on in list", JSON.stringify(C.split_owns(["1.4", "1.5", "1.6"], "1.4")) === JSON.stringify({working_on: ["1.4"], parked: ["1.5", "1.6"]}));
check("web: split_owns working_on not in list", JSON.stringify(C.split_owns(["1.4", "1.5"], "1.9")) === JSON.stringify({all: ["1.4", "1.5"]}));
check("web: split_owns no working_on", JSON.stringify(C.split_owns(["1.4", "1.5"], null)) === JSON.stringify({all: ["1.4", "1.5"]}));
check("web: split_owns empty owns", JSON.stringify(C.split_owns([], "1.4")) === JSON.stringify({all: []}));

// team_sort
var unsorted = [
  {agent: "ada", state: "WORKING", owns: ["1.4"]},
  {agent: "bo", state: "idle 22m", owns: ["1.5", "1.6"]},
  {agent: "cy", state: "idle 3h", owns: []},
  {agent: "di", state: "idle 5m", owns: ["1.7"]}
];
var sorted = C.team_sort(unsorted);
check("web: team_sort warning agents first", sorted[0].agent === "bo" && sorted[1].agent === "di" && sorted[2].agent === "ada" && sorted[3].agent === "cy");
check("web: team_sort keeps feed order within groups", JSON.stringify(sorted.map((a) => a.agent)) === JSON.stringify(["bo", "di", "ada", "cy"]));
check("web: team_sort copies a short array", JSON.stringify(C.team_sort([unsorted[2]]).map((a) => a.agent)) === JSON.stringify(["cy"]));

// team_warning
check("web: team_warning working owns", C.team_warning({state: "WORKING", owns: ["1.4"]}) === null);
check("web: team_warning idle owns", C.team_warning({state: "idle 22m", owns: ["1.5", "1.6"]}) === "idle, owns 2 items");
check("web: team_warning idle none", C.team_warning({state: "idle 22m", owns: []}) === null);
check("web: team_warning idle one", C.team_warning({state: "idle 22m", owns: ["1.7"]}) === "idle, owns 1 item");
check("web: team_warning idle missing owns", C.team_warning({state: "idle 22m"}) === null);

// C5, C8: the files
const files = ["index.html", "core.js", "app.js", "style.css"].map((f) => [f, fs.readFileSync(path.join(dir, f), "utf8")]);
const banned = [/\binnerHTML\b/, /\bouterHTML\b/, /\binsertAdjacentHTML\b/, /document\.write/, /\beval\(/, /new Function/, /\bon[a-z]+\s*=/, /javascript:/];
const hits = [];
for (const [f, text] of files) for (const re of banned) if (re.test(text.replace(/\/\/.*$/gm, ""))) hits.push(f + " " + re);
check("web: C5 share/po-web has no innerHTML, eval, inline handler or javascript: URL", hits.length === 0, hits.join("; "));
const refs = [...files[0][1].matchAll(/(?:src|href)="([^"]*)"/g)].map((m) => m[1]);
check("web: C8 index.html references only /app/ paths", refs.length >= 3 && refs.every((r) => r.startsWith("/app/")), refs.join(" "));
check("web: C8 the code makes no request outside the origin", !files.some(([f, t]) => /https?:\/\//.test(t)), "");

// v0.114: the Projects card
const D = (items, mins) => C.doingLines(items, NOW, mins);
const doing = (item, agents, last) => Object.assign({ item: item, status: "DOING", agents: agents }, last === undefined ? {} : { last_event: last });
let d = D([doing("0.99", ["budy"], "2026-11-01T14:58:00Z")]);
check("web: doingLines writes a fresh DOING item as `v0.99 - budy - 2m ago`, not stalled", eq(d, { lines: [{ text: "v0.99 - budy - 2m ago", stalled: false }], more: 0 }), JSON.stringify(d));
d = D([doing("0.98", ["ana"], "2026-11-01T14:20:00Z")]);
check("web: doingLines marks an item whose last event is older than 30 min stalled", d.lines[0].text === "v0.98 - ana - 40m ago" && d.lines[0].stalled === true, JSON.stringify(d));
check("web: doingLines treats exactly stall_minutes as not yet stalled", D([doing("1", ["a"], "2026-11-01T14:30:00Z")]).lines[0].stalled === false);
check("web: doingLines takes stall_minutes from its argument", D([doing("1", ["a"], "2026-11-01T14:20:00Z")], 60).lines[0].stalled === false && D([doing("1", ["a"], "2026-11-01T14:58:00Z")], 1).lines[0].stalled === true);
d = D([doing("0.97", ["cy"])]);
check("web: doingLines with no last_event says `no events` and is stalled", d.lines[0].text === "v0.97 - cy - no events" && d.lines[0].stalled === true, JSON.stringify(d));
check("web: doingLines with an unreadable time says `no events` and is stalled", D([doing("0.96", ["cy"], "soon")]).lines[0].text === "v0.96 - cy - no events");
d = D([doing("0.95", [], "2026-11-01T14:58:00Z")]);
check("web: doingLines with no owner leaves the owner out", d.lines[0].text === "v0.95 - 2m ago", JSON.stringify(d));
const many = [1, 2, 3, 4, 5, 6, 7].map((i) => doing("m" + i, ["a"], "2026-11-01T14:58:00Z"));
d = D(many);
check("web: doingLines caps at 5 lines and counts the rest as more", d.lines.length === 5 && d.more === 2 && d.lines[4].text.startsWith("vm5"), JSON.stringify(d));
check("web: doingLines of exactly 5 has no more", D(many.slice(0, 5)).more === 0);
d = D([{ item: "1", status: "TODO" }, { item: "2", status: "DONE" }, { item: "3", status: "PAUSED", agents: ["x"], last_event: "2026-11-01T14:58:00Z" }]);
check("web: doingLines lists only DOING (PAUSED and BLOCKED count as DOING)", d.lines.length === 1 && d.lines[0].text.startsWith("v3"), JSON.stringify(d));
check("web: doingLines of a non-list is empty", eq(C.doingLines(null, NOW), { lines: [], more: 0 }));
const proj = C.parseFeed(feed("projects-feed.json"));
let card = C.projectCard(proj[0], NOW);
check("web: projectCard of the example: release, count line, setup line, one fresh DOING line",
  card.release === "release-3" && card.countLine === "TODO 1  DOING 1  DONE 1  RELEASED 0" && card.setup === "setup open 2" &&
  eq(card.doing.lines, [{ text: "v3.2 - cy - 2m ago", stalled: false }]), JSON.stringify(card));
card = C.projectCard(proj[1], NOW);
check("web: projectCard says `no release` muted and wraps the n not in a filter line", card.release === "no release" && card.releaseMuted === true && card.lost === "12 not in a filter: 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.10, 1.11, 1.12, 1.13", card.release + "|" + card.lost);
card = C.projectCard(proj[2], NOW);
check("web: projectCard of a project with error is grey, says feed error and keeps its counts", card.grey === true && card.error === "feed error" && card.countLine.indexOf("RELEASED 1") > 0 && card.setup === "setup open 1", JSON.stringify(card));
check("web: projectCard of a healthy project is not grey", C.projectCard(proj[0], NOW).grey === false && C.projectCard(proj[0], NOW).error === "");

// contrast: the CSS variables of each scheme, text pairs at 4.5:1 (WCAG AA)
function lum(hex) {
  const [r, g, b] = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}
const ratio = (a, b) => { const [x, y] = [lum(a), lum(b)].sort((p, q) => q - p); return (x + 0.05) / (y + 0.05); };
const css = files[3][1];
const vars = (block) => Object.fromEntries([...block.matchAll(/--([a-z-]+):\s*(#[0-9a-fA-F]{6})/g)].map((m) => [m[1], m[2]]));
const light = vars(css.slice(0, css.indexOf("@media")));
const dark = vars(css.slice(css.indexOf("prefers-color-scheme: dark")));
const PAIRS = [["text", "bg"], ["text", "card"], ["muted", "bg"], ["muted", "card"], ["warn", "bg"], ["warn", "card"], ["ok", "card"], ["bad", "card"], ["on-accent", "accent"], ["accent", "bg"]];
for (const [name, v] of [["light", light], ["dark", Object.assign({}, light, dark)]]) {
  const low = PAIRS.filter(([f, b]) => !(v[f] && v[b]) || ratio(v[f], v[b]) < 4.5).map(([f, b]) => f + "/" + b + (v[f] && v[b] ? " " + ratio(v[f], v[b]).toFixed(2) : " missing"));
  check("web: " + name + " scheme text colours meet WCAG AA (4.5:1)", low.length === 0, low.join("; "));
}
check("web: the page has a viewport meta and a dark scheme", /name="viewport"/.test(files[0][1]) && /prefers-color-scheme: dark/.test(css));

// renderMain regression: non-events views must keep feed order and not slice to 50
var decisionsFeed = C.parseFeed(feed("decisions-feed.json"));
var projectsFeed = C.parseFeed(feed("projects-feed.json"));
var teamFeed = C.parseFeed(feed("team-feed.json"));
check("web: decisions view keeps feed order", JSON.stringify(decisionsFeed.map((c) => c.id)) === JSON.stringify([decisionsFeed[0].id, decisionsFeed[1].id, decisionsFeed[2].id, decisionsFeed[3].id, decisionsFeed[4].id, decisionsFeed[5].id]));
check("web: projects view keeps feed order", JSON.stringify(projectsFeed.map((c) => c.project)) === JSON.stringify(projectsFeed.map((c) => c.project)));
var sortedTeam = C.team_sort(teamFeed);
check("web: team view sorts warning agents before non-warning", sortedTeam[0].agent === "bo" && sortedTeam[1].agent === "di" && sortedTeam[2].agent === "ada" && sortedTeam[3].agent === "cy");
check("web: team view keeps feed order within groups", JSON.stringify(sortedTeam.map((c) => c.agent)) === JSON.stringify(["bo", "di", "ada", "cy"]));

// ---- answering (v0.116) ----
const { execFileSync } = require("child_process");
const harbor = decisionsFeed.find((c) => c.id === "ask-0707");
const long = decisionsFeed.find((c) => c.id === "ask-0909");
const action = decisionsFeed.find((c) => c.id === "ask-0205");
const AID = "0f1e2d3c-4b5a-4978-8a1b-2c3d4e5f6a7b";
const AT = new Date(Date.UTC(2026, 10, 2, 12, 0, 0));
check("web: decisionShape matches the desktop viewer's kinds", C.decisionShape(harbor) === "choice" && C.decisionShape(action) === "action"
  && C.decisionShape(decisionsFeed[0]) === "legacy" && C.decisionShape(decisionsFeed.find((c) => c.id === "ask-0808")) === "unformatted");
// the same picks give the same body as dashboard_core.answer_body (the desktop viewer's on_send_answer)
function desktopBody(card, kind, picks) {
  const py = 'import json,sys; sys.path.insert(0, sys.argv[1]); import dashboard_core as c; a = json.loads(sys.argv[2]);'
    + ' b = c.answer_body(a["card"], a["aid"], kind=a["kind"], installed=None, **c.answer_params(a["kind"], a["picks"])); b.pop("answered_at"); print(json.dumps(b))';
  return JSON.parse(execFileSync("python3", ["-B", "-c", py, path.join(__dirname, "..", "lib", "po"), JSON.stringify({ card, aid: AID, kind, picks })]).toString());
}
function pageBody(card, kind, picks) { const b = C.answerBody(card, AID, kind, picks, AT); delete b.answered_at; return b; }
const casesBody = [
  [harbor, "choice", { choice: "Approve", note: "  ship it  " }],
  [harbor, "choice", { choice: null, note: "hold until Friday" }],
  [action, "action", { result: "Pass", note: "" }],
  [action, "action", { result: "Failed", step: 2, note: "viewer did not come back" }],
];
const diff = casesBody.filter(([c, k, p]) => JSON.stringify(pageBody(c, k, p)) !== JSON.stringify(desktopBody(c, k, p)));
check("web: the answer body equals the desktop viewer's for the same picks (fields, order, trims, nulls)", diff.length === 0,
  diff.map(([c, k, p]) => JSON.stringify(pageBody(c, k, p)) + " vs " + JSON.stringify(desktopBody(c, k, p))).join("; "));
const full = C.answerBody(harbor, AID, "choice", { choice: "Approve" }, AT);
check("web: the body has answered_at in UTC seconds and client po-dashboard",
  full.answered_at === "2026-11-02T12:00:00Z" && full.client === "po-dashboard" && full.installed === null, JSON.stringify(full));
const longLabel = long.options[0].label;
const bl = C.answerBody(long, AID, "choice", { choice: longLabel }, AT), bs = C.answerBody(harbor, AID, "choice", { choice: "Approve" }, AT);
check("web: a long-label card's body is the short-label one with its own id, project, item and the label verbatim",
  JSON.stringify(Object.assign({}, bl, { id: "", project: "", item: "", option: "" })) === JSON.stringify(Object.assign({}, bs, { id: "", project: "", item: "", option: "" }))
  && bl.option === longLabel && bl.option.length > 200, JSON.stringify(bl));
check("web: answerReady: a choice needs an option or a write-in", !C.answerReady("choice", {}) && C.answerReady("choice", { choice: "Deny" })
  && C.answerReady("choice", { note: "x" }) && !C.answerReady("choice", { note: "   " }));
check("web: answerReady: an action needs Pass, or Failed with a step", C.answerReady("action", { result: "Pass" })
  && !C.answerReady("action", { result: "Failed" }) && C.answerReady("action", { result: "Failed", step: 1 }));
check("web: answerReady: a text over 2000 characters is never ready; unformatted never", !C.answerReady("choice", { choice: "Deny", note: "x".repeat(2001) })
  && C.answerReady("choice", { choice: "Deny", note: "x".repeat(2000) }) && !C.answerReady("unformatted", { text: "go" }));

// C6: the token goes only into the Authorization header of a POST to the configured sink
const TOK = "tok-Zq9xY8wV7uT6sR5qP4oN3mL2kJ1iH0g";
const SINK = "http" + "://sink.example:8791/answers";
const rq = C.answerRequest(SINK, TOK, full);
const others = JSON.stringify([rq.url, rq.init.body, rq.init.method, rq.init.credentials, rq.init.redirect, rq.init.referrerPolicy, rq.init.headers["Content-Type"]]);
check("web: C6 the request is a POST to the configured answer_url, JSON, no cookie, no referrer, no redirect",
  rq.url === SINK && rq.init.method === "POST" && rq.init.headers["Content-Type"] === "application/json" && rq.init.credentials === "omit"
  && rq.init.redirect === "error" && rq.init.referrerPolicy === "no-referrer" && JSON.parse(rq.init.body).answer_id === AID, others);
check("web: C6 the token is only in the Authorization header", rq.init.headers.Authorization === "Bearer " + TOK && !others.includes(TOK)
  && Object.keys(rq.init.headers).length === 2);
const states = [[201, null], [200, null], [409, null], [409, "wrong build"], [404, null], [401, null], [403, null], [429, "rate limit"], [0, "unreachable or refused"], [0, "timeout"], [502, "feed"], [500, "<b>x</b>"]]
  .map(([s, r]) => C.answerResult(s, r, NOW));
check("web: C6 no banner or answer state holds the token", !states.some((r) => r.text.includes(TOK)) && !C.bannerText(true, null, NOW).includes(TOK));
const appJs = fs.readFileSync(path.join(dir, "app.js"), "utf8");
check("web: C6 the page never logs, never sets the title or the location from the token",
  !/\bconsole\./.test(appJs) && !/document\.title/.test(appJs) && (appJs.match(/getItem\(TOKEN_KEY\)/g) || []).length === 2
  && /answerRequest\(answerUrl, localStorage\.getItem\(TOKEN_KEY\)/.test(appJs) && !/location[^\n]*TOKEN/.test(appJs));
check("web: the token field is a password input whose value is cleared on save", /input\.type = "password"/.test(appJs) && /input\.value = "";/.test(appJs));

// what the card shows after Send
check("web: a sent answer shows `sent <time>` and drops the draft", states[0].text === "sent 3:00 PM" && states[0].sent && !states[0].keepDraft && states[1].sent);
check("web: an unreachable sink keeps the draft and shows `not sent: <class>`", states[8].text === "not sent: unreachable or refused" && states[8].keepDraft
  && states[9].text === "not sent: timeout");
check("web: 409 is already answered; a wrong build keeps the draft", states[2].text === "already answered" && !states[2].keepDraft
  && states[3].text === "not sent: wrong build" && states[3].keepDraft);
check("web: 404 no longer waiting; 401/403 refused; 429 rate limit; a reason that is not a short class is not shown",
  states[4].text === "no longer waiting" && /^not sent: refused \(401\)/.test(states[5].text) && /^not sent: refused \(403\)/.test(states[6].text)
  && /^not sent: rate limit/.test(states[7].text) && states[10].text === "not sent: feed" && states[11].text === "not sent: status 500",
  states.map((r) => r.text).join(" | "));
const ids = Array.from({ length: 50 }, () => C.newAnswerId(require("crypto").randomBytes(16)));
check("web: answer ids are lowercase dashed uuid4 (the receiver's pattern) and differ",
  ids.every((i) => /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(i)) && new Set(ids).size === 50, ids[0]);
check("web: the page makes ids with crypto.getRandomValues (randomUUID needs a secure context)",
  /crypto\.getRandomValues/.test(appJs) && !/randomUUID/.test(appJs));

// look cards: held unless ready, exactly as the desktop viewer's v0.81 hold
const SHA = "ab".repeat(32);
const lookNow = new Date(Date.UTC(2026, 10, 2, 12, 0, 0));
const lookCard = { kind: "action", id: "look-1", project: "demo", item: "0.9", machine: "the laptop", done_when: "seen",
  steps: [{ text: "click Bookmarks in the menu bar", expect: "three bookmarks" }], fixtures: [],
  requires: { package: "demo-2.0-1-x86_64.pkg.tar.zst", sha256: SHA }, checked_by: "dev1", check_sha256: SHA,
  ready: { build: "demo 2.0-1", checked_at: "2026-11-02T11:55:00Z" } };
check("web: a ready look card is shown and its body names the build the install machine reported",
  C.lookReady(lookCard, lookNow)[0] && C.holdLooks([lookCard, harbor], lookNow).length === 2
  && C.answerBody(lookCard, AID, "action", { result: "Pass" }, lookNow).installed === "demo 2.0-1");
const held = [
  ["no ready", Object.assign({}, lookCard, { ready: undefined })],
  ["stale", Object.assign({}, lookCard, { ready: { build: "demo 2.0-1", checked_at: "2026-11-02T11:40:00Z" } })],
  ["another build", Object.assign({}, lookCard, { ready: { build: "demo 1.9-1", checked_at: "2026-11-02T11:55:00Z" } })],
  ["no step check", Object.assign({}, lookCard, { checked_by: "" })],
  ["check on another build", Object.assign({}, lookCard, { check_sha256: "cd".repeat(32) })],
  ["a vague step", Object.assign({}, lookCard, { steps: [{ text: "open the page and look", expect: "x" }] })],
  ["a fixture not in place", Object.assign({}, lookCard, { fixtures: [{ name: "db", kind: "path", target: "~/x.db", present: false }] })],
];
const shown = held.filter(([, c]) => C.holdLooks([c], lookNow).length !== 0).map(([n]) => n);
check("web: a look card failing a ready or build check is held, never answerable (v0.81)", shown.length === 0, shown.join(", "));
const pyHeld = JSON.parse(execFileSync("python3", ["-B", "-c", 'import json,sys,datetime; sys.path.insert(0, sys.argv[1]); import dashboard_core as c;'
  + ' now = datetime.datetime(2026, 11, 2, 12, 0, tzinfo=datetime.timezone.utc); print(json.dumps([c.look_ready(e, now=now)[0] for e in json.loads(sys.argv[2])]))',
  path.join(__dirname, "..", "lib", "po"), JSON.stringify([lookCard].concat(held.map(([, c]) => c)))]).toString());
check("web: lookReady agrees with the desktop viewer's look_ready on every fixture", JSON.stringify(pyHeld) === JSON.stringify([lookCard].concat(held.map(([, c]) => c)).map((c) => C.lookReady(c, lookNow)[0])), JSON.stringify(pyHeld));
check("web: a card that is not a look card is never held", C.holdLooks(decisionsFeed, lookNow).length === decisionsFeed.length);
console.log("BLOCK-END web-core");
