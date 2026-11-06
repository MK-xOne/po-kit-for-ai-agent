// po web view: the pure functions (feed parsing, counts, words). No DOM here, so node tests them:
// the page loads this file as a plain script (global PoCore); node loads it with require().
(function (root) {
  "use strict";

  var VIEWS = ["decisions", "events", "projects", "team"];
  var FEEDS = { decisions: "decisions", events: "events", projects: "projects", team: "team" };

  function isObj(v) { return v !== null && typeof v === "object" && !Array.isArray(v); }

  // parseFeed(text): the feed's array. A body {"error": ...} (the 502 convention) or anything that is not a
  // JSON array throws an Error with a message the banner can show; array members that are not objects drop.
  function parseFeed(text) {
    var data;
    try { data = JSON.parse(text); } catch (e) { throw new Error("the feed is not JSON"); }
    if (isObj(data) && typeof data.error === "string") throw new Error(data.error);
    if (!Array.isArray(data)) throw new Error("the feed is not a list");
    return data.filter(isObj);
  }

  function sameLocalDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  }

  // eventsToday(events, now): events whose time falls on now's calendar day in the viewer's timezone.
  function eventsToday(events, now) {
    var n = 0;
    for (var i = 0; i < events.length; i++) {
      var t = typeof events[i].time === "string" ? new Date(events[i].time) : null;
      if (t && !isNaN(t) && sameLocalDay(t, now)) n++;
    }
    return n;
  }

  // An agent is working when its state starts with WORKING, any case ("WORKING", "working 4m").
  function isWorking(agent) {
    return typeof agent.state === "string" && /^working\b/i.test(agent.state.trim());
  }

  function teamWorking(team) {
    var n = 0;
    for (var i = 0; i < team.length; i++) if (isWorking(team[i])) n++;
    return n;
  }

  // counts(feeds, now): feeds is {decisions, events, projects, team}, each an array or null (not loaded).
  // A null feed has a null count: the toggle then shows its name alone.
  function counts(feeds, now) {
    return {
      decisions: feeds.decisions ? feeds.decisions.length : null,
      events: feeds.events ? eventsToday(feeds.events, now) : null,
      projects: feeds.projects ? feeds.projects.length : null,
      team: feeds.team ? teamWorking(feeds.team) : null
    };
  }

  // toggleLabel(view, count): "Decisions (2)", "Events (3 today)", "Projects (4)", "Team (1 working)".
  function toggleLabel(view, count) {
    var name = view.charAt(0).toUpperCase() + view.slice(1);
    if (count === null || count === undefined) return name;
    var suffix = view === "events" ? " today" : view === "team" ? " working" : "";
    return name + " (" + count + suffix + ")";
  }

  // The view in a location.hash ("#team"); the home view, decisions, for anything else.
  function viewFromHash(hash) {
    var v = String(hash || "").replace(/^#/, "");
    return VIEWS.indexOf(v) >= 0 ? v : "decisions";
  }

  // visibleViews(configured): the toggle order, minus a view whose feed is not configured. Decisions first.
  function visibleViews(configured) {
    return VIEWS.filter(function (v) { return configured.indexOf(FEEDS[v]) >= 0; });
  }

  function age(iso, now) {
    var t = typeof iso === "string" ? new Date(iso) : null;
    if (!t || isNaN(t)) return "";
    var s = Math.floor((now - t) / 1000);
    if (s < 60) return "just now";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m ago";
    var h = Math.floor(m / 60);
    if (h < 24) return h + "h ago";
    return Math.floor(h / 24) + "d ago";
  }

  // item_label(group, filter): "v0.99" or "demo v0.99" when All is chosen. An event with no item ("" or "-") names
  // the project alone (v0.146: never "demo v-"); the "v" comes from itemRef, so a value already starting "v" keeps it.
  function item_label(group, filter) {
    var item = str(group.item).trim();
    var label = item === "-" ? "" : itemRef(item);
    if (!filter && group.project) label = label ? group.project + " " + label : group.project;
    return label;
  }

  // itemRef(v) (v0.141): an item as the Team view names it. A bare version ("0.141", from po team) gets its "v"; a value
  // that already says "project vX" (the team-status feed) is kept as it is, so it never reads "on vproject v1.2".
  function itemRef(v) {
    var s = str(v).trim();
    return /^[0-9]/.test(s) ? "v" + s : s;
  }

  // eventHead(e) (v0.141): what an Events card head says about its newest event: the result as a mark and a word
  // (so it is never colour alone) and the kind. mark and word are "" for an event with no result.
  var RESULT_CUES = { pass: ["✔", "pass"], fail: ["✘", "fail"], skip: ["–", "skip"] };
  function eventHead(e) {
    var cue = RESULT_CUES[str(e && e.result)] || ["", str(e && e.result)];
    return { mark: cue[0], word: cue[1], kind: str(e && e.kind), cls: cue[1] === "pass" ? "ok" : cue[1] === "fail" ? "bad" : "" };
  }

  // filter_events(events, project): the events of one project, or all when project is falsy.
  function filter_events(events, project) {
    if (!project) return events;
    return events.filter(function (e) { return String(e.project || "") === project; });
  }

  // relative_time(iso, now): viewer-local, never shows today's date. Absolute time
  // belongs in the tooltip. Future clock skew shows "just now".
  function relative_time(iso, now) {
    var t = typeof iso === "string" ? new Date(iso) : null;
    if (!t || isNaN(t)) return "";
    var s = Math.floor((now - t) / 1000);
    if (s < 60) return "just now";
    var m = Math.floor(s / 60);
    if (m < 60) return m + "m ago";
    var h = Math.floor(m / 60);
    if (h < 24) return h + "h ago";
    var d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    var y = new Date(t.getFullYear(), t.getMonth(), t.getDate());
    var diffDays = Math.floor((d - y) / 86400000);
    if (diffDays === 1) {
      var h12 = t.getHours();
      var ampm = h12 >= 12 ? "PM" : "AM";
      var hh = h12 % 12 || 12;
      var mm = String(t.getMinutes()).padStart(2, "0");
      return "yesterday " + hh + ":" + mm + " " + ampm;
    }
    var months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    return months[t.getMonth()] + " " + t.getDate();
  }

  // group_events(events): consecutive events of the same project+item (adjacent after
  // sorting newest-first) are grouped. Returns [{project, item, events}].
  function group_events(events) {
    if (!Array.isArray(events) || events.length === 0) return [];
    var sorted = events.slice().sort(function (a, b) { return String(b.time).localeCompare(String(a.time)); });
    var groups = [];
    var cur = null;
    for (var i = 0; i < sorted.length; i++) {
      var e = sorted[i];
      var key = String(e.project || "") + "\x00" + String(e.item || "");
      if (!cur || cur.key !== key) {
        cur = { key: key, project: String(e.project || ""), item: String(e.item || ""), events: [e] };
        groups.push(cur);
      } else {
        cur.events.push(e);
      }
    }
    return groups;
  }

  function str(v) {
    if (v === null || v === undefined) return "";
    return typeof v === "object" ? JSON.stringify(v) : String(v);
  }

  // decisionCard(card, now): what the Decisions view shows for one card. Every field is plain text for
  // textContent; options are the choice card's, the recommended one marked.
  function decisionCard(card, now) {
    var kind = str(card.kind) || "look";
    var options = Array.isArray(card.options) ? card.options.filter(isObj).map(function (o) {
      return { label: str(o.label), description: str(o.description), recommended: o.recommended === true };
    }) : [];
    var asked = age(card.asked_at, now);
    return {
      key: str(card.id) || str(card.project) + "/" + str(card.item) + "/" + str(card.title),
      kind: kind,
      title: str(card.title),
      project: str(card.project),
      item: str(card.item),
      waiting: [str(card.waiting_for) && "waiting for " + str(card.waiting_for), str(card.asked_by) && "asked by " + str(card.asked_by)]
        .filter(Boolean).join(", "),
      asked: asked ? "asked " + asked : "",
      question: str(card.question),
      options: options,
      thread: threadUrl(card.thread_url)
    };
  }

  // threadUrl(v) (v0.141): the card's thread link, as dashboard_core.thread_link decides: http(s) with a host, or a chat
  // app's own deep link (`<scheme>://...`, letters only) whose scheme is not one that runs code or shows local data.
  var LINK_BLOCKED_SCHEMES = ["javascript", "vbscript", "data", "file", "blob", "about", "filesystem", "view-source", "chrome",
    "resource", "jar"];
  function threadUrl(v) {
    var s = typeof v === "string" ? v.trim() : "";
    var m = /^([A-Za-z][A-Za-z0-9+.-]*):\/\/(.)/.exec(s);
    var scheme = m ? m[1].toLowerCase() : "";
    if (scheme === "http" || scheme === "https") {
      try { return new URL(s).host ? s : ""; } catch (e) { return ""; }
    }
    return /^[a-z]+$/.test(scheme) && LINK_BLOCKED_SCHEMES.indexOf(scheme) < 0 && !/\s/.test(s) ? s : "";
  }

  // sortDecisions(cards) (v0.141): the desktop viewer's order (dashboard_core.sort_decisions): Choices, then Actions,
  // then unformatted and legacy; inside a group the oldest asked first, a card without a readable asked_at last;
  // stable.
  var DECISION_GROUP = { choice: 0, action: 1, unformatted: 2, legacy: 2 };
  function sortDecisions(cards) {
    return cards.map(function (c, i) {
      var t = typeof c.asked_at === "string" ? Date.parse(c.asked_at) : NaN;
      return { c: c, i: i, g: DECISION_GROUP[decisionShape(c)], t: isNaN(t) ? Infinity : t };
    }).sort(function (a, b) {
      return a.g - b.g || (a.t === b.t ? 0 : a.t < b.t ? -1 : 1) || a.i - b.i;
    }).map(function (x) { return x.c; });
  }

  // bannerText(lastOk, now): "" when the last fetch worked or nothing was ever fetched, else the banner words.
  // lastOk is the ms time of the last good fetch, or null.
  function bannerText(failed, lastOk, now) {
    if (!failed) return "";
    if (lastOk === null || lastOk === undefined) return "not updated yet";
    var a = age(new Date(lastOk).toISOString(), now);
    return "not updated " + (a === "just now" ? "just now" : a);
  }

  var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

  // clockText(t, now): the one time format of the dashboard (v0.142, the same as the desktop's clock_text):
  // "7:00 PM EST", then " Nov 30" when t is not today (and " 2027" when not this year); the viewer's zone, named.
  function clockText(t, now) {
    var h = t.getHours(), mm = String(t.getMinutes()).padStart(2, "0");
    var zone = (t.toLocaleTimeString("en-US", { timeZoneName: "short" }).match(/\s([A-Za-z][\w+:-]*)$/) || ["", ""])[1];
    var text = (h % 12 || 12) + ":" + mm + " " + (h >= 12 ? "PM" : "AM") + (zone ? " " + zone : "");
    var sameDay = t.getFullYear() === now.getFullYear() && t.getMonth() === now.getMonth() && t.getDate() === now.getDate();
    if (sameDay) return text;
    return text + " " + MONTHS[t.getMonth()] + " " + t.getDate() + (t.getFullYear() === now.getFullYear() ? "" : " " + t.getFullYear());
  }

  // usage_words(usage): human-readable usage string from the feed's usage {five_hour, seven_day} (parts present
  // only), e.g. "80% of the 5 h window used, 12% of the 7 d window". The limit is the agent's state (limitText).
  function usage_words(usage) {
    var parts = [];
    if (usage && Number.isFinite(usage.five_hour)) parts.push(Math.round(usage.five_hour * 100) + "% of the 5 h window used");
    if (usage && Number.isFinite(usage.seven_day)) parts.push(Math.round(usage.seven_day * 100) + "% of the 7 d window");
    return parts.join(", ");
  }

  // limitText(agent, now): "LIMIT until 7:00 PM EST Nov 30" while limit_until is still ahead, "" otherwise (v0.142:
  // one line, one format, instead of the feed's state and a second "limit until" line).
  function limitText(agent, now) {
    var t = agent && typeof agent.limit_until === "string" ? new Date(agent.limit_until) : null;
    if (!t || isNaN(t) || t <= now) return "";
    return "LIMIT until " + clockText(t, now);
  }

  // teamUsage(agents): the usage every agent with one shows (one subscription), said once above the Team cards;
  // "" when none has usage or they differ (each card then keeps its own).
  function teamUsage(agents) {
    var seen = {};
    (Array.isArray(agents) ? agents : []).forEach(function (a) { var u = usage_words(a && a.usage); if (u) seen[u] = true; });
    var keys = Object.keys(seen);
    return keys.length === 1 ? keys[0] : "";
  }

  // split_owns(owns, working_on): splits an agent's owns list into working-on items
  // and parked items when the feed gives a working_on field. Returns {working_on:[], parked:[]}
  // or {all:[]} when working_on is absent or not in owns.
  function split_owns(owns, working_on) {
    if (!Array.isArray(owns) || owns.length === 0) return {all: []};
    if (!working_on) return {all: owns.slice()};
    var idx = owns.indexOf(working_on);
    if (idx >= 0) {
      var parked = owns.slice();
      parked.splice(idx, 1);
      return {working_on: [working_on], parked: parked};
    }
    return {all: owns.slice()};
  }

  // team_warning(agent, now): the warning for an idle agent that still owns items, naming the cause (v0.142), or
  // null. None while it works or owns nothing, and none at its usage limit (its LIMIT line is the cause). The FREE
  // flag says its items wait on someone else; otherwise it owns them and is on none.
  function team_warning(agent, now) {
    if (typeof agent.state === "string" && /^working\b/i.test(agent.state.trim())) return null;
    var owns = Array.isArray(agent.owns) ? agent.owns : [];
    if (owns.length === 0) return null;
    if (limitText(agent, now || new Date())) return null;
    var n = owns.length + " item" + (owns.length === 1 ? "" : "s");
    if (agent.free === true) return "idle: its " + n + (owns.length === 1 ? " waits" : " wait") + " on someone else";
    return "idle, owns " + n + " and works on none";
  }

  // team_sort(agents): warning agents first, stable otherwise.
  function team_sort(agents, now) {
    if (!Array.isArray(agents) || agents.length < 2) return agents.slice();
    return agents.slice().sort(function (a, b) {
      var wa = team_warning(a, now) ? 0 : 1;
      var wb = team_warning(b, now) ? 0 : 1;
      return wa - wb;
    });
  }

  var DOING_WORDS = ["DOING", "PAUSED", "BLOCKED"];  // the words the GTK Projects card counts as DOING
  var DEFAULT_STALL_MINUTES = 30;
  var MAX_DOING_LINES = 5;
  var STALLED = ", stalled";  // v0.142: a stalled line says so in words, not by its colour alone

  // statusWord(status): the first word, upper-cased, trailing punctuation stripped ("DONE (no change)" is DONE).
  function statusWord(status) {
    var w = String(status === null || status === undefined ? "" : status).trim().split(/\s+/)[0] || "";
    return w.replace(/[!-\/:-@\[-`{-~]+$/, "").toUpperCase();
  }

  function setupOpen(item) {
    var n = item && item.setup_open;
    return typeof n === "number" && n > 0 && Math.floor(n) === n ? n : 0;
  }

  // itemWord(item): RELEASED for a DONE item the release contains with no setup step open, else its status word.
  function itemWord(item) {
    var w = statusWord(item && item.status);
    return w === "DONE" && item.released === true && setupOpen(item) === 0 ? "RELEASED" : w;
  }

  // doingLines(items, now, stallMinutes): the DOING items of one project as lines `v0.99 - budy - 2m ago`
  // (item, its first agent, the age of its own last event; the owner is left out when there is none). A line
  // is stalled when that event is older than stallMinutes, and its text then ends in `, stalled`; an item with no
  // readable event time says `no events` and is stalled. At most 5 lines; the rest is `more`, shown as `+n more`.
  function doingLines(items, now, stallMinutes) {
    var limit = (typeof stallMinutes === "number" && stallMinutes >= 0 ? stallMinutes : DEFAULT_STALL_MINUTES) * 60000;
    var lines = [];
    (Array.isArray(items) ? items : []).forEach(function (it) {
      if (!isObj(it) || DOING_WORDS.indexOf(itemWord(it)) < 0) return;
      var owner = Array.isArray(it.agents) && it.agents.length ? str(it.agents[0]) : "";
      var t = typeof it.last_event === "string" ? new Date(it.last_event) : null;
      var known = t !== null && !isNaN(t);
      var h = it.idle_hours;
      if (typeof h === "number" && isFinite(h) && h >= 0) {  // v0.130: the producer's idle time wins over the last event's age
        h = Math.floor(h);
        lines.push({
          text: ["v" + str(it.item), owner, h < 1 ? "active" : "idle " + h + "h"].filter(Boolean).join(" - ") + (h >= 2 ? STALLED : ""),
          stalled: h >= 2
        });
        return;
      }
      var stalled = known ? now - t > limit : true;
      lines.push({
        text: ["v" + str(it.item), owner, known ? relative_time(it.last_event, now) : "no events"].filter(Boolean).join(" - ") + (stalled ? STALLED : ""),
        stalled: stalled
      });
    });
    return { lines: lines.slice(0, MAX_DOING_LINES), more: Math.max(0, lines.length - MAX_DOING_LINES) };
  }

  // projectCard(p, now, stallMinutes): what the Projects view shows for one project, matching the GTK card:
  // the release label (muted `no release`), the count line, the muted `setup open N` and `n not in a filter: ...`
  // lines, GREY_REASON for a project with an error (greyed, and saying why), and its DOING lines. active (v0.139) is the feed's
  // true/false, null when the feed has no `active` key (then no switch and no badge); badge is `inactive` when false.
  var GREY_REASON = "greyed: this project's feed failed, so its counts may be out of date";  // v0.141: why, in words
  function projectCard(p, now, stallMinutes) {
    var items = Array.isArray(p.items) ? p.items.filter(isObj) : [];
    var c = { TODO: 0, DOING: 0, DONE: 0, RELEASED: 0 };
    var lost = [], setup = 0;
    items.forEach(function (it) {
      var w = itemWord(it);
      if (DOING_WORDS.indexOf(w) >= 0) c.DOING++;
      else if (c.hasOwnProperty(w)) c[w]++;
      else lost.push(str(it.item) || "?");
      setup += setupOpen(it);
    });
    var rel = typeof p.release === "string" && p.release.trim() ? p.release.trim() : "";
    var error = typeof p.error === "string" && p.error.trim() ? p.error.trim().split(/\s+/).join(" ") : "";
    return {
      name: str(p.project) || "?",
      release: rel || "no release", releaseMuted: !rel,
      countLine: ["TODO", "DOING", "DONE", "RELEASED"].map(function (k) { return k + " " + c[k]; }).join("  "),
      setup: setup ? "setup open " + setup : "",
      lost: lost.length ? lost.length + " not in a filter: " + lost.join(", ") : "",
      error: error ? GREY_REASON : "", grey: !!error,
      active: typeof p.active === "boolean" ? p.active : null,
      badge: p.active === false ? "inactive" : "",
      doing: doingLines(items, now, stallMinutes)
    };
  }

  // ---- the project switch (v0.139): posted on the answer path, the same sink and token --------------------

  var PROJECT_ACTIVE = "project-active";
  var SWITCH_HOLD_MS = 180000;  // a switched card shows the new state this long while the (cached) feed catches up

  // projectActiveBody(project, active, answerId, now): the body that switches a project on or off.
  function projectActiveBody(project, active, answerId, now) {
    return {
      answer_id: answerId,
      kind: PROJECT_ACTIVE,
      project: str(project),
      active: active === true,
      answered_at: now.toISOString().replace(/\.\d{3}Z$/, "Z"),
      client: CLIENT
    };
  }

  // switchShown(feedActive, pending, nowMs): the position the switch shows: the pending {active, at} while the feed
  // does not show it yet (until SWITCH_HOLD_MS after it was sent), else the feed's.
  function switchShown(feedActive, pending, nowMs) {
    if (pending && nowMs - pending.at < SWITCH_HOLD_MS && pending.active !== feedActive) return pending.active;
    return feedActive;
  }

  // switchSettled(feedActive, pending, nowMs): may the pending switch be dropped (the feed agrees, or the hold ran out).
  function switchSettled(feedActive, pending, nowMs) {
    return !pending || pending.active === feedActive || nowMs - pending.at >= SWITCH_HOLD_MS;
  }

  // switchResult(status, reason): "" when the switch went through (200/201), else what the card says.
  function switchResult(status, reason) {
    var why = typeof reason === "string" && REASON_RE.test(reason.trim()) ? reason.trim() : "";
    if (status === 200 || status === 201) return "";
    if (status === 401 || status === 403) return "not switched: refused (" + status + "), check the device token";
    if (status === 429) return "not switched: rate limit, try again in a moment";
    if (status === 0) return "not switched: " + (why || "unreachable");
    return "not switched: " + (why || "status " + status);
  }


  // ---- the release button (v0.140): it ASKS, on the answer path, the same sink and token ------------------

  var RELEASE_REQUEST = "release-request";
  var RELEASE_NOTE_MAX = 2000;  // characters of the trimmed note; the receiver refuses more (400 `note too long`)
  var RELEASE_SENT = "release asked \u00b7 sent";

  // unreleasedDone(items): the DONE items (any DONE status word) the feed does not mark released.
  function unreleasedDone(items) {
    return (Array.isArray(items) ? items : []).filter(function (it) {
      return isObj(it) && statusWord(it.status) === "DONE" && it.released !== true;
    }).length;
  }

  // releaseView(p, sink): {n, title, enabled, why} of a card's Release button, as the desktop viewer's release_view:
  // title `Release <project>: N DONE items since <last release>`; off, saying why, at N = 0 or without a sink.
  function releaseView(p, sink) {
    var name = str(p && p.project);
    var n = unreleasedDone(p && p.items);
    var rel = p && typeof p.release === "string" && p.release.trim() ? p.release.trim() : "the start (no release yet)";
    var why = !sink ? "read-only: no answer URL" : n === 0 ? "nothing to release: no DONE item since " + rel : "";
    return { n: n, title: "Release " + name + ": " + n + " DONE item" + (n === 1 ? "" : "s") + " since " + rel,
      enabled: !why, why: why };
  }

  // releaseBody(project, note, answerId, now): the body that asks for a release; the note goes as typed.
  function releaseBody(project, note, answerId, now) {
    return {
      answer_id: answerId,
      kind: RELEASE_REQUEST,
      project: str(project),
      note: typeof note === "string" ? note : "",
      answered_at: now.toISOString().replace(/\.\d{3}Z$/, "Z"),
      client: CLIENT
    };
  }

  // releaseReady(note): may Release be pressed (the trimmed note within RELEASE_NOTE_MAX).
  function releaseReady(note) { return String(note || "").trim().length <= RELEASE_NOTE_MAX; }

  // releaseKeySends(ev): does this keydown in the note send it (Ctrl+Enter, or Cmd+Enter on a Mac), as the
  // desktop viewer's answer box; never while an input method is composing.
  function releaseKeySends(ev) {
    return !!ev && ev.key === "Enter" && (!!ev.ctrlKey || !!ev.metaKey) && !ev.isComposing;
  }

  // releaseResult(status, reason): RELEASE_SENT when it went through (200/201), else `not sent: <why>`.
  function releaseResult(status, reason) {
    var why = typeof reason === "string" && REASON_RE.test(reason.trim()) ? reason.trim() : "";
    if (status === 200 || status === 201) return RELEASE_SENT;
    if (status === 401 || status === 403) return "not sent: refused (" + status + "), check the device token";
    if (status === 429) return "not sent: rate limit, try again in a moment";
    if (status === 0) return "not sent: " + (why || "unreachable");
    return "not sent: " + (why || "status " + status);
  }

  // ---- answering (v0.116): the same body the desktop viewer's on_send_answer posts ----------------------

  var CLIENT = "po-dashboard";
  var MAX_TEXT = 2000;  // the receiver's limit on a text field, counted on the trimmed text
  var PACKAGE_RE = /^[A-Za-z0-9][A-Za-z0-9._+:@=,-]*$/;
  var SHA256_RE = /^[0-9a-f]{64}$/;
  var PKG_NVR_RE = /^(.+)-([^-]+)-([^-]+)-([^-]+)\.pkg\.tar\.[a-z0-9]+$/;

  function text(v) { return typeof v === "string" && v.trim() !== ""; }
  function optionalText(v) { return v === null || v === undefined || typeof v === "string"; }

  function requiresOf(card) {
    var r = card.requires;
    if (!isObj(r) || typeof r.package !== "string" || !PACKAGE_RE.test(r.package)) return null;
    if (typeof r.sha256 !== "string" || !SHA256_RE.test(r.sha256)) return null;
    return { package: r.package, sha256: r.sha256 };
  }

  // decisionShape(card): "choice", "action", "unformatted" or "legacy" (no kind), as the desktop viewer decides.
  function decisionShape(card) {
    if (!("kind" in card)) return "legacy";
    if ((card.kind !== "choice" && card.kind !== "action") || !text(card.id)) return "unformatted";
    if (card.kind === "choice") {
      var o = card.options;
      if (!text(card.question) || !Array.isArray(o) || o.length < 2) return "unformatted";
      for (var i = 0; i < o.length; i++) {
        if (!isObj(o[i]) || !text(o[i].label) || !optionalText(o[i].description)) return "unformatted";
        if (o[i].recommended !== undefined && typeof o[i].recommended !== "boolean") return "unformatted";
      }
      if (o.filter(function (x) { return x.recommended === true; }).length > 1) return "unformatted";
      return "choice";
    }
    var st = card.steps;
    if (!text(card.machine) || !text(card.done_when) || !Array.isArray(st) || !st.length) return "unformatted";
    for (var j = 0; j < st.length; j++) {
      if (!isObj(st[j]) || !text(st[j].text) || !optionalText(st[j].command)) return "unformatted";
    }
    if ("requires" in card && requiresOf(card) === null) return "unformatted";
    return "action";
  }

  function isLook(card) { return decisionShape(card) === "action" && requiresOf(card) !== null; }

  // The look-card checks of v0.81 (dashboard_core.look_ready): a look card that fails one is never shown.
  var VAGUE = ["the page", "somewhere", "as usual", "etc", "and so on", "if needed", "try", "some", "whatever",
    "check that it works"];
  var VAGUE_RE = new RegExp("(?<![\\w/.-])(" + VAGUE.map(function (v) { return v.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"); })
    .join("|") + ")(?![\\w/-])", "i");
  var QUOTED_RE = /(?<!\w)'[^']+'(?!\w)|"[^"]+"|`[^`]+`/;
  var STEP_MIN = 12, FIXTURES_MAX = 20, FIXTURE_NAME_MAX = 60;
  var LOOK_FRESH_MS = 15 * 60 * 1000, LOOK_FUTURE_MS = 60 * 1000;

  function stepProblems(steps) {
    if (!Array.isArray(steps) || !steps.length) return ["no steps"];
    var out = [];
    steps.forEach(function (st, i) {
      var n = i + 1;
      if (!isObj(st)) { out.push("step " + n + " is not an object"); return; }
      var t = typeof st.text === "string" ? st.text : "";
      if (!text(st.expect)) out.push("step " + n + " has no expect (what the owner should see)");
      if (t.trim().length < STEP_MIN) out.push("step " + n + " is too short to follow");
      var hit = VAGUE_RE.exec(t);
      if (hit && !QUOTED_RE.test(t)) out.push("step " + n + " is vague");
    });
    return out;
  }

  function fixtureProblems(fixtures) {
    if (!Array.isArray(fixtures)) return ["fixtures missing: list them, or write [] for none"];
    if (fixtures.length > FIXTURES_MAX) return ["more than " + FIXTURES_MAX + " fixtures"];
    var names = fixtures.map(function (f) { return isObj(f) ? f.name : undefined; });
    var out = [];
    fixtures.forEach(function (f, i) {
      var n = i + 1;
      if (isObj(f) && typeof f.name === "string" && f.name.length > FIXTURE_NAME_MAX) { out.push("fixture " + n + ": name too long"); return; }
      if (isObj(f) && names.filter(function (x) { return x === f.name; }).length > 1) { out.push("fixture " + n + ": name used twice"); return; }
      if (!isObj(f) || !text(f.name) || (f.kind !== "path" && f.kind !== "url") || !text(f.target)) {
        out.push("fixture " + n + " needs name, kind (path or url) and target"); return;
      }
      var t = f.target;
      if (f.kind === "path" && (t.indexOf("~/") !== 0 || t.split("/").indexOf("..") >= 0 || /\s/.test(t))) out.push("fixture " + f.name + ": a path starts ~/ with no ..");
      if (f.kind === "url" && (!/^https:\/\//.test(t) || /\s/.test(t))) out.push("fixture " + f.name + ": a url is https");
    });
    return out;
  }

  // lookReady(card, now): [true, ""] for a card that is not a look card or passed every check, else [false, why].
  function lookReady(card, now) {
    if (!isLook(card)) return [true, ""];
    var req = requiresOf(card);
    var m = PKG_NVR_RE.exec(req.package);
    if (!m) return [false, "the package name has no version"];
    if (!text(card.checked_by)) return [false, "no step check"];
    if (card.check_sha256 !== req.sha256) return [false, "the step check ran on another build"];
    var probs = stepProblems(card.steps).concat(fixtureProblems(card.fixtures));
    if (probs.length) return [false, probs[0]];
    var missing = card.fixtures.filter(function (f) { return f.present !== true; });
    if (missing.length) return [false, "fixture not in place"];
    var ready = card.ready;
    var at = isObj(ready) && typeof ready.checked_at === "string" ? new Date(ready.checked_at) : null;
    if (!isObj(ready) || !text(ready.build) || !at || isNaN(at)) return [false, "not checked on the install machine"];
    if (now - at > LOOK_FRESH_MS) return [false, "stale"];
    if (at - now > LOOK_FUTURE_MS) return [false, "in the future"];
    var build = m[1] + " " + m[2] + "-" + m[3];
    if (ready.build.trim() !== build) return [false, "installed is " + ready.build.trim() + ", the card needs " + build];
    return [true, "Ready: " + build + " installed"];
  }

  // holdLooks(cards, now): the cards to show; a look card that is not ready is held (never shown), as in v0.81.
  function holdLooks(cards, now) {
    return cards.filter(function (c) { return lookReady(c, now)[0]; });
  }

  // installedFor(card): the build a look card's answer names, the one the install machine reported ready
  // (the phone has no packages of its own); null for every other card, as the desktop viewer sends.
  function installedFor(card) {
    return isLook(card) && isObj(card.ready) && text(card.ready.build) ? card.ready.build.trim() : null;
  }

  // newAnswerId(bytes): a lowercase dashed uuid4 from 16 random bytes (crypto.getRandomValues: crypto.randomUUID
  // needs a secure context, and the page is served over plain HTTP inside the tailnet).
  function newAnswerId(bytes) {
    var b = Array.prototype.slice.call(bytes, 0, 16);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    var h = b.map(function (x) { return (x + 0x100).toString(16).slice(1); }).join("");
    return h.slice(0, 8) + "-" + h.slice(8, 12) + "-" + h.slice(12, 16) + "-" + h.slice(16, 20) + "-" + h.slice(20);
  }

  function tooLong(v) { return typeof v === "string" && v.trim().length > MAX_TEXT; }

  // answerReady(kind, picks): may the draft be sent. choice: an option or a write-in; action: Pass, or Failed
  // with a step. A text over the limit is never ready (the box keeps it, nothing typed is lost).
  function answerReady(kind, picks) {
    if (tooLong(picks.note) || tooLong(picks.text)) return false;
    if (kind === "choice") return (picks.choice !== null && picks.choice !== undefined) || text(picks.note);
    if (kind === "action") return picks.result === "Pass" || (picks.result === "Failed" && Number.isInteger(picks.step));
    return false;
  }

  // answerParams(kind, picks): the body fields of a draft (dashboard_core.answer_params): text trimmed, empty null.
  function answerParams(kind, picks) {
    var note = typeof picks.note === "string" && picks.note.trim() ? picks.note.trim() : null;
    if (kind === "choice") return { option: picks.choice === undefined ? null : picks.choice, text: note };
    var failed = picks.result === "Failed";
    return { result: failed ? "failed" : "pass", step: failed ? picks.step : null, note: note };
  }

  // answerBody(card, answerId, kind, picks, now): the flat JSON object the desktop viewer posts, every field
  // present, null where the kind does not use it.
  function answerBody(card, answerId, kind, picks, now) {
    var p = answerParams(kind, picks);
    return {
      answer_id: answerId,
      id: str(card.id),
      project: str(card.project),
      item: str(card.item),
      kind: kind,
      option: p.option === undefined ? null : p.option,
      text: p.text === undefined ? null : p.text,
      result: p.result === undefined ? null : p.result,
      step: p.step === undefined ? null : p.step,
      note: p.note === undefined ? null : p.note,
      answered_at: now.toISOString().replace(/\.\d{3}Z$/, "Z"),
      client: CLIENT,
      installed: installedFor(card)
    };
  }

  // answerRequest(answerUrl, token, body): the fetch() arguments for one answer. The token goes only into the
  // Authorization header of a POST to the configured sink; no cookie, no referrer, no redirect is followed.
  function answerRequest(answerUrl, token, body) {
    return {
      url: answerUrl,
      init: {
        method: "POST",
        mode: "cors",
        credentials: "omit",
        cache: "no-store",
        redirect: "error",
        referrerPolicy: "no-referrer",
        headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
        body: JSON.stringify(body)
      }
    };
  }

  function clock(d) {
    var h = d.getHours();
    return (h % 12 || 12) + ":" + String(d.getMinutes()).padStart(2, "0") + " " + (h >= 12 ? "PM" : "AM");
  }

  var REASON_RE = /^[a-z0-9][a-z0-9/ _-]{0,39}$/;

  // answerResult(status, reason, now): what the card shows after a POST. status 0 is no answer at all
  // (reason then names the class: "unreachable", "timeout"). sent: the answer went through; keepDraft: the
  // controls stay and Send may be pressed again (same answer_id while the picks are unchanged).
  function answerResult(status, reason, now) {
    var why = typeof reason === "string" && REASON_RE.test(reason.trim()) ? reason.trim() : "";
    if (status === 200 || status === 201) return { text: "sent " + clock(now), sent: true, keepDraft: false };
    if (status === 409 && why === "wrong build") return { text: "not sent: wrong build", sent: false, keepDraft: true };
    if (status === 409) return { text: "already answered", sent: false, keepDraft: false };
    if (status === 404) return { text: "no longer waiting", sent: false, keepDraft: false };
    if (status === 401 || status === 403) return { text: "not sent: refused (" + status + "), check the device token", sent: false, keepDraft: true };
    if (status === 429) return { text: "not sent: rate limit, try again in a moment", sent: false, keepDraft: true };
    if (status === 0) return { text: "not sent: " + (why || "unreachable"), sent: false, keepDraft: true };
    return { text: "not sent: " + (why || "status " + status), sent: false, keepDraft: true };
  }

  var api = {
    doingLines: doingLines, projectCard: projectCard, statusWord: statusWord, itemWord: itemWord,
    VIEWS: VIEWS, parseFeed: parseFeed, eventsToday: eventsToday, isWorking: isWorking, teamWorking: teamWorking,
    counts: counts, toggleLabel: toggleLabel, viewFromHash: viewFromHash, visibleViews: visibleViews, age: age,
    relative_time: relative_time, group_events: group_events, item_label: item_label, filter_events: filter_events,
    itemRef: itemRef, eventHead: eventHead, threadUrl: threadUrl, sortDecisions: sortDecisions, GREY_REASON: GREY_REASON,
    decisionCard: decisionCard, bannerText: bannerText, usage_words: usage_words, split_owns: split_owns,
    clockText: clockText, limitText: limitText, teamUsage: teamUsage,
    team_warning: team_warning, team_sort: team_sort,
    MAX_TEXT: MAX_TEXT, decisionShape: decisionShape, isLook: isLook, lookReady: lookReady, holdLooks: holdLooks,
    installedFor: installedFor, newAnswerId: newAnswerId, answerReady: answerReady, answerParams: answerParams,
    answerBody: answerBody, answerRequest: answerRequest, answerResult: answerResult,
    projectActiveBody: projectActiveBody, switchShown: switchShown, switchSettled: switchSettled, switchResult: switchResult,
    SWITCH_HOLD_MS: SWITCH_HOLD_MS,
    unreleasedDone: unreleasedDone, releaseView: releaseView, releaseBody: releaseBody, releaseReady: releaseReady,
    releaseResult: releaseResult, releaseKeySends: releaseKeySends, RELEASE_NOTE_MAX: RELEASE_NOTE_MAX, RELEASE_SENT: RELEASE_SENT
  };
  if (typeof module === "object" && module.exports) module.exports = api;
  else root.PoCore = api;
})(typeof self !== "undefined" ? self : this);
