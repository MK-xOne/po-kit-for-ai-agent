// po web view: fetches the feeds through po serve (same origin) and draws them. Feed text only ever goes
// in through textContent. Pure logic is in core.js.
(function () {
  "use strict";
  var C = window.PoCore;
  var POLL_MS = 10000;
  var state = {};      // feed name -> {data, etag, lastOk, failed}
  var expanded = {};   // decision card key -> true
  var configured = [];
  var stallMinutes = 30;
  var timer = null;
  var view = C.viewFromHash(location.hash);
  var eventsFilter = localStorage.getItem("po-web:events-project") || "";
  var answerUrl = null;  // the sink, from /app/config.json; null: Decisions is read-only
  var TOKEN_KEY = "po-web:device-token";  // read only to build a POST and to say whether it is set; never shown
  var DRAFTS_KEY = "po-web:drafts";
  var drafts = loadDrafts();  // card id -> {choice, note, result, step, answer_id, sig}; kept across reloads
  var results = {};          // card id -> {text, sent, sending} of the last Send
  var settingsOpen = false;

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== "") e.textContent = text;
    return e;
  }

  function feedsNow() {
    var f = {};
    C.VIEWS.forEach(function (v) { f[v] = state[v] && state[v].data ? state[v].data : null; });
    if (f.decisions) f.decisions = C.holdLooks(f.decisions, new Date());  // a look card not ready is never shown
    return f;
  }

  function loadDrafts() {
    try {
      var d = JSON.parse(localStorage.getItem(DRAFTS_KEY) || "{}");
      return d && typeof d === "object" && !Array.isArray(d) ? d : {};
    } catch (e) { return {}; }
  }

  function saveDrafts() {
    try { localStorage.setItem(DRAFTS_KEY, JSON.stringify(drafts)); } catch (e) { /* storage full or blocked */ }
  }

  function tokenSet() { return !!localStorage.getItem(TOKEN_KEY); }

  function renderNav() {
    var nav = document.getElementById("views");
    var counts = C.counts(feedsNow(), new Date());
    nav.replaceChildren();
    C.visibleViews(configured).forEach(function (v) {
      var b = el("button", "", C.toggleLabel(v, counts[v]));
      b.type = "button";
      if (v === view) b.setAttribute("aria-current", "page");
      b.addEventListener("click", function () { show(v); });
      nav.appendChild(b);
    });
  }

  function renderBanner() {
    var failed = [], lastOk = null;
    configured.forEach(function (n) {
      var s = state[n];
      if (s && s.failed) {
        failed.push(n);
        if (s.lastOk !== null && (lastOk === null || s.lastOk < lastOk)) lastOk = s.lastOk;
      }
    });
    var b = document.getElementById("banner");
    var text = C.bannerText(failed.length > 0, lastOk, Date.now());
    b.textContent = text;
    b.hidden = !text;
  }

  function renderFilter() {
    var container = document.getElementById("event-filters");
    if (!container) return;
    var show = view === "events";
    container.style.display = show ? "flex" : "none";
    if (!show) return;
    container.replaceChildren();
    var events = state.events && state.events.data ? state.events.data : [];
    var projects = [];
    var seen = {};
    events.forEach(function (e) {
      var p = String(e.project || "");
      if (p && !seen[p]) { seen[p] = true; projects.push(p); }
    });
    projects.sort();
    var all = el("button", "chip" + (eventsFilter === "" ? " on" : ""), "All");
    all.type = "button";
    all.addEventListener("click", function () { setEventsFilter(""); });
    container.appendChild(all);
    projects.forEach(function (p) {
      var b = el("button", "chip" + (eventsFilter === p ? " on" : ""), p);
      b.type = "button";
      b.addEventListener("click", function () { setEventsFilter(p); });
      container.appendChild(b);
    });
  }

  function setEventsFilter(p) {
    eventsFilter = p;
    if (p) localStorage.setItem("po-web:events-project", p);
    else localStorage.removeItem("po-web:events-project");
    render();
  }

  function decisionCard(c) {
    var d = C.decisionCard(c, new Date());
    var kind = C.decisionShape(c);
    var card = el("article", "card");
    var head = el("button", "head");
    head.type = "button";
    head.setAttribute("aria-expanded", expanded[d.key] ? "true" : "false");
    var h = el("h2");
    h.appendChild(el("span", "kind", d.kind));
    h.appendChild(document.createTextNode(d.title));
    head.appendChild(h);
    head.appendChild(el("div", "meta", [d.project && d.item ? d.project + " v" + d.item : d.project, d.waiting, d.asked].filter(Boolean).join(" · ")));
    head.addEventListener("click", function () {
      expanded[d.key] = !expanded[d.key];
      render();
    });
    card.appendChild(head);
    if (expanded[d.key]) {
      var body = el("div", "body");
      if (d.question) body.appendChild(el("p", "", d.question));
      if (d.options.length) {
        var ul = el("ul");
        d.options.forEach(function (o) {
          var li = el("li");
          if (o.recommended) li.appendChild(el("span", "rec", "★ recommended: "));
          li.appendChild(document.createTextNode(o.label));
          if (o.description) li.appendChild(el("div", "meta", o.description));
          ul.appendChild(li);
        });
        if (!(answerUrl && kind === "choice")) body.appendChild(ul);  // with a sink the radios list the options
      }
      if (answerUrl) body.appendChild(answerForm(c, kind));
      card.appendChild(body);
    }
    return card;
  }

  // ---- answering (v0.116): the desktop viewer's controls, stacked for a phone ----

  function canSend(id, kind) {
    var r = results[id];
    return tokenSet() && !(r && (r.sending || r.sent)) && C.answerReady(kind, drafts[id] || {});
  }

  function setDraft(id, kind, key, value, send) {
    var dr = drafts[id] || (drafts[id] = {});
    dr[key] = value;
    saveDrafts();
    send.disabled = !canSend(id, kind);
  }

  function textBox(id, kind, placeholder, send) {
    var wrap = el("div", "writein");
    var box = el("textarea");
    box.rows = 2;
    box.placeholder = placeholder;
    box.setAttribute("aria-label", placeholder);
    box.value = (drafts[id] || {}).note || "";
    var count = el("div", "meta counter");
    function counted() {
      var n = box.value.trim().length;
      count.textContent = n + " / " + C.MAX_TEXT;
      count.classList.toggle("stat-bad", n > C.MAX_TEXT);
    }
    counted();
    box.addEventListener("input", function () { setDraft(id, kind, "note", box.value, send); counted(); });
    wrap.appendChild(box);
    wrap.appendChild(count);
    return wrap;
  }

  function radio(name, checked, label, desc, pick) {
    var lab = el("label", "pick");
    var input = el("input");
    input.type = "radio";
    input.name = name;
    input.checked = checked;
    input.addEventListener("change", function () { if (input.checked) pick(); });
    lab.appendChild(input);
    var words = el("span", "pick-text");
    words.appendChild(document.createTextNode(label));
    if (desc) words.appendChild(el("span", "meta pick-desc", desc));
    lab.appendChild(words);
    return lab;
  }

  function answerForm(c, kind) {
    var id = String(c.id || "");
    var form = el("div", "answer");
    if (kind !== "choice" && kind !== "action") {
      form.appendChild(el("p", "meta", "Answer this one in its thread: it has no answer form."));
      return form;
    }
    var dr = drafts[id] || {};
    var r = results[id];
    var send = el("button", "send", r && r.sending ? "Sending…" : "Send");
    send.type = "button";
    var group = el("fieldset", "picks");
    group.appendChild(el("legend", "meta", kind === "choice" ? "Your answer" : "Result on " + String(c.machine)));
    if (kind === "choice") {
      c.options.forEach(function (o) {
        var label = String(o.label);
        group.appendChild(radio("pick-" + id, dr.choice === label, (o.recommended ? "★ recommended: " : "") + label,
          o.description ? String(o.description) : "", function () { setDraft(id, kind, "choice", label, send); }));
      });
      form.appendChild(group);
      form.appendChild(textBox(id, kind, "or write your own", send));
    } else {
      var steps = el("fieldset", "picks");
      steps.appendChild(el("legend", "meta", "Failed at step"));
      steps.hidden = dr.result !== "Failed";
      ["Pass", "Failed"].forEach(function (res) {
        group.appendChild(radio("result-" + id, dr.result === res, res, "", function () {
          setDraft(id, kind, "result", res, send);
          steps.hidden = res !== "Failed";
        }));
      });
      c.steps.forEach(function (st, i) {
        steps.appendChild(radio("step-" + id, dr.step === i + 1, (i + 1) + ". " + String(st.text), "",
          function () { setDraft(id, kind, "step", i + 1, send); }));
      });
      form.appendChild(group);
      form.appendChild(steps);
      form.appendChild(textBox(id, kind, "note (optional)", send));
    }
    var foot = el("div", "send-row");
    send.disabled = !canSend(id, kind);
    send.addEventListener("click", function () { sendAnswer(c, kind, send); });
    foot.appendChild(send);
    var status = r ? r.text : tokenSet() ? "" : "set the device token to answer";
    if (status) foot.appendChild(el("span", "answer-state" + (r && r.sent ? " sent" : r && !r.sending ? " stat-bad" : " meta"), status));
    form.appendChild(foot);
    return form;
  }

  // One Send posts the desktop viewer's body. The answer_id stays the same while the picks are unchanged, so a
  // Send after a failure is a replay the sink answers 200 without posting twice. Send is disabled until the
  // answer returns (no double post from a double tap).
  function sendAnswer(c, kind, button) {
    var id = String(c.id || "");
    if (!canSend(id, kind)) return;
    var dr = drafts[id];
    var sig = JSON.stringify(C.answerParams(kind, dr));
    if (!dr.answer_id || dr.sig !== sig) {
      dr.answer_id = C.newAnswerId(crypto.getRandomValues(new Uint8Array(16)));
      dr.sig = sig;
      saveDrafts();
    }
    results[id] = { text: "sending…", sending: true };
    button.disabled = true;
    button.textContent = "Sending…";
    var req = C.answerRequest(answerUrl, localStorage.getItem(TOKEN_KEY), C.answerBody(c, dr.answer_id, kind, dr, new Date()));
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, 25000);
    req.init.signal = ctl.signal;
    fetch(req.url, req.init).then(function (resp) {
      return C.answerResult(resp.status, resp.headers.get("X-Reason"), new Date());
    }, function (e) {
      // a browser hides why a request failed: a refused preflight (a revoked device) looks like no sink at all
      return C.answerResult(0, e && e.name === "AbortError" ? "timeout" : "unreachable or refused", new Date());
    }).then(function (res) {
      clearTimeout(timer);
      results[id] = res;
      if (!res.keepDraft) { delete drafts[id]; saveDrafts(); }
      render();
    });
  }

  // The device token: typed or pasted once, kept in localStorage, shown only as "set" or "not set".
  function renderSettings() {
    var box = document.getElementById("settings");
    var btn = document.getElementById("settings-toggle");
    btn.hidden = !answerUrl;
    btn.textContent = tokenSet() ? "Device token set" : "Set device token";
    box.hidden = !(answerUrl && settingsOpen);
    if (box.hidden) return;
    box.replaceChildren();
    box.appendChild(el("p", "meta", tokenSet() ? "device token set" : "no device token: Send stays off"));
    var input = el("input");
    input.type = "password";
    input.autocomplete = "off";
    input.spellcheck = false;
    input.placeholder = "paste the device token";
    input.setAttribute("aria-label", "device token");
    var save = el("button", "", "Save");
    save.type = "button";
    save.addEventListener("click", function () {
      var t = input.value.trim();
      input.value = "";
      if (t) localStorage.setItem(TOKEN_KEY, t);
      settingsOpen = false;
      render();
    });
    var clear = el("button", "", "Remove");
    clear.type = "button";
    clear.addEventListener("click", function () { localStorage.removeItem(TOKEN_KEY); render(); });
    box.appendChild(input);
    var row = el("div", "send-row");
    row.appendChild(save);
    row.appendChild(clear);
    box.appendChild(row);
  }

  function eventGroupCard(g) {
    var key = "evt-" + g.project + "\x00" + g.item;
    var card = el("article", "card");
    var head = el("button", "row event-head");
    head.type = "button";
    head.setAttribute("aria-expanded", expanded[key] ? "true" : "false");
    var label = C.item_label(g, eventsFilter);
    head.appendChild(el("strong", "", label));
    var newest = g.events[0];
    var age = C.relative_time(newest.time, new Date());
    if (age) head.appendChild(document.createTextNode(" · " + age));
    head.addEventListener("click", function () {
      expanded[key] = !expanded[key];
      render();
    });
    card.appendChild(head);
    var lines = el("div", "event-lines");
    g.events.forEach(function (e) {
      var row = el("div", "row event-line");
      row.appendChild(el("span", "", [e.kind, e.result].filter(Boolean).join(" ")));
      var abs = new Date(e.time).toLocaleString();
      row.title = abs;
      row.appendChild(el("span", "meta", e.agent || ""));
      lines.appendChild(row);
    });
    if (expanded[key]) {
      card.setAttribute("data-expanded", "true");
      card.appendChild(lines);
    }
    return card;
  }

  function projectCard(p) {
    var d = C.projectCard(p, new Date(), stallMinutes);
    var card = el("article", "card" + (d.grey ? " grey" : ""));
    var top = el("div", "row");
    top.appendChild(el("strong", "", d.name));
    top.appendChild(el("div", d.releaseMuted ? "meta" : "", d.release));
    card.appendChild(top);
    var body = el("div", "row");
    body.appendChild(el("div", "meta", d.countLine));
    [d.setup, d.error, d.lost].forEach(function (t) { if (t) body.appendChild(el("div", "meta", t)); });
    card.appendChild(body);
    if (d.doing.lines.length) {
      var ul = el("ul", "doing");
      d.doing.lines.forEach(function (l) { ul.appendChild(el("li", l.stalled ? "stalled" : "", l.text)); });
      if (d.doing.more) ul.appendChild(el("li", "meta", "+" + d.doing.more + " more"));
      card.appendChild(ul);
    }
    return card;
  }

  function teamCard(a) {
    var warning = C.team_warning(a);
    var card = el("article", "card" + (warning ? " warn" : ""));
    var row = el("div", "row");
    row.appendChild(el("strong", "", String(a.agent || "?")));
    var stateLine = [a.state, a.now ? "on v" + a.now : ""].filter(Boolean).join(" · ");
    row.appendChild(el("div", C.isWorking(a) ? "meta state-working" : "meta", stateLine));
    var split = C.split_owns(a.owns || [], a.working_on || null);
    if (split.working_on && split.working_on.length) {
      var label = "working on: v" + split.working_on.join(", ");
      if (split.parked && split.parked.length) label += " · parked: v" + split.parked.join(", ");
      row.appendChild(el("div", "meta", label));
    } else if (split.all && split.all.length) {
      row.appendChild(el("div", "meta", "owns v" + split.all.join(", ")));
    }
    var usageText = C.usage_words(a.usage || null, a.limit_until || null, new Date());
    if (usageText) {
      row.appendChild(el("div", "meta", usageText));
    }
    var labelParts = [String(a.agent || "?")];
    if (stateLine) labelParts.push(stateLine);
    if (usageText) labelParts.push(usageText);
    card.setAttribute("aria-label", labelParts.join(", "));
    card.appendChild(row);
    if (warning) {
      var warnRow = el("div", "row warn-text");
      warnRow.appendChild(document.createTextNode("⚠️ " + warning));
      card.appendChild(warnRow);
    }
    return card;
  }

  var DRAW = { decisions: decisionCard, events: eventGroupCard, projects: projectCard, team: teamCard };
  var EMPTY = { decisions: "No decisions waiting.", events: "No events.", projects: "No projects.", team: "No agents." };

  function renderMain() {
    var main = document.getElementById("main");
    var s = state[view];
    main.replaceChildren();
    if (!s || !s.data) {
      main.appendChild(el("p", "empty", s && s.failed ? "Nothing loaded yet." : "Loading…"));
      return;
    }
    if (view === "events") {
      var filtered = C.filter_events(s.data, eventsFilter);
      var sorted = filtered.slice().sort(function (a, b) { return String(b.time).localeCompare(String(a.time)); });
      var groups = C.group_events(sorted).slice(0, 50);
      if (!groups.length) main.appendChild(el("p", "empty", EMPTY[view]));
      groups.forEach(function (g) { main.appendChild(DRAW[view](g)); });
      return;
    }
    var data = s.data;
    if (view === "team") {
      data = C.team_sort(data);
    }
    if (view === "decisions") data = feedsNow().decisions;
    if (!data.length) main.appendChild(el("p", "empty", EMPTY[view]));
    data.forEach(function (x) { main.appendChild(DRAW[view](x)); });
  }

  // typing(): the owner is in an answer box or the token field; a poll then leaves the cards alone (a redraw
  // would drop the focus and the keyboard).
  function typing() {
    var a = document.activeElement;
    return !!a && (a.tagName === "TEXTAREA" || a.tagName === "INPUT") && a.type !== "radio";
  }

  // Drafts and results of cards that left the feed go (a sent card leaves on the next feed).
  function pruneAnswers() {
    var d = state.decisions && state.decisions.data;
    if (!d) return;
    var live = {};
    d.forEach(function (c) { live[String(c.id || "")] = true; });
    var changed = false;
    Object.keys(drafts).forEach(function (k) { if (!live[k]) { delete drafts[k]; changed = true; } });
    Object.keys(results).forEach(function (k) { if (!live[k]) delete results[k]; });
    if (changed) saveDrafts();
  }

  function render(polled) {
    pruneAnswers();
    renderNav();
    renderBanner();
    renderFilter();
    renderSettings();
    if (!(polled === true && typing())) renderMain();
  }

  function show(v) {
    view = v;
    if (location.hash !== "#" + v) history.replaceState(null, "", "#" + v);
    render();
  }

  function fetchFeed(name) {
    var s = state[name] || (state[name] = { data: null, etag: null, lastOk: null, failed: false });
    var headers = {};
    if (s.etag && s.data) headers["If-None-Match"] = s.etag;
    return fetch("/app/feeds/" + name + ".json", { headers: headers, cache: "no-store" }).then(function (r) {
      if (r.status === 304) { s.failed = false; s.lastOk = Date.now(); return; }
      return r.text().then(function (text) {
        var data = C.parseFeed(text);  // a 502 {"error"} body throws here
        if (!r.ok) throw new Error("status " + r.status);
        s.data = data; s.etag = r.headers.get("ETag"); s.failed = false; s.lastOk = Date.now();
      });
    }).catch(function () { s.failed = true; });  // keeps the last data
  }

  function poll() {
    timer = null;
    if (document.hidden) return;  // paused; visibilitychange resumes
    Promise.all(configured.map(fetchFeed)).then(function () {
      render(true);
      if (!document.hidden && timer === null) timer = setTimeout(poll, POLL_MS);
    });
  }

  document.addEventListener("visibilitychange", function () {
    if (document.hidden) { if (timer !== null) { clearTimeout(timer); timer = null; } }
    else if (timer === null) poll();
  });
  window.addEventListener("hashchange", function () { view = C.viewFromHash(location.hash); render(); });
  document.getElementById("settings-toggle").addEventListener("click", function () {
    settingsOpen = !settingsOpen;
    render();
  });

  fetch("/app/config.json", { cache: "no-store" }).then(function (r) { return r.json(); }).then(function (cfg) {
    configured = Array.isArray(cfg.feeds) ? cfg.feeds : [];
    if (typeof cfg.stall_minutes === "number") stallMinutes = cfg.stall_minutes;
    answerUrl = typeof cfg.answer_url === "string" && cfg.answer_url ? cfg.answer_url : null;
    if (C.visibleViews(configured).indexOf(view) < 0) view = C.visibleViews(configured)[0] || "decisions";
    render();
    poll();
  }).catch(function () {
    document.getElementById("banner").textContent = "not updated yet";
    document.getElementById("banner").hidden = false;
  });
})();
