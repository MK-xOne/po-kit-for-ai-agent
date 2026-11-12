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
  var switches = {};         // project -> {active, at, note, sending}: the last switch flipped here (v0.139)
  var agentSwitches = {};    // agent -> {active, at, note, sending}: the last agent switch flipped here (v0.173)
  var releases = {};         // project -> the last Release request's result here (v0.140)

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

  // sinkRequest(body): the one place the token is read for a POST (an answer, or a project switch since v0.139).
  function sinkRequest(body) { return C.answerRequest(answerUrl, localStorage.getItem(TOKEN_KEY), body); }

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
    if (d.kind) h.appendChild(el("span", "kind", d.kind));
    h.appendChild(document.createTextNode(d.title));
    head.appendChild(h);
    head.appendChild(el("div", "meta", [d.project && d.item ? d.project + " " + C.itemRef(d.item) : d.project, d.waiting, d.asked].filter(Boolean).join(" · ")));
    head.addEventListener("click", function () {
      expanded[d.key] = !expanded[d.key];
      render();
    });
    card.appendChild(head);
    var thread = threadRow(d, kind === "choice" || kind === "action");  // last on the card, open or closed
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
    card.appendChild(thread);
    return card;
  }

  // threadRow (v0.141): every card's "Open thread" link, outside the head button so it is a link of its own; a card
  // with no answer form says to answer there.
  function threadRow(d, hasForm) {
    var row = el("div", "row thread-row");
    if (d.thread) {
      var a = el("a", "thread-link", "Open thread");
      a.href = d.thread;
      a.target = "_blank";
      a.rel = "noopener noreferrer";
      row.appendChild(a);
    } else {
      row.appendChild(el("span", "meta", "no thread link in the feed"));
    }
    if (!hasForm) row.appendChild(el("span", "meta", "no answer form: answer it in its thread"));
    return row;
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
    if (kind !== "choice" && kind !== "action") return form;  // threadRow says to answer in the thread
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
    var req = sinkRequest(C.answerBody(c, dr.answer_id, kind, dr, new Date()));
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
    // v0.142: once set, a small settings link beside the views; a full-size button only while a token is missing
    btn.textContent = tokenSet() ? "device token set \u00b7 change" : "Set device token";
    btn.classList.toggle("link", tokenSet());
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
    var newest = g.events[0];
    var cue = C.eventHead(newest);  // v0.141: the newest event's result (mark and word) and kind on the head
    var what = el("span", "event-what");
    what.appendChild(el("strong", "", label));
    if (cue.word) what.appendChild(el("span", "result" + (cue.cls ? " " + cue.cls : ""), [cue.mark, cue.word].filter(Boolean).join(" ")));
    if (cue.kind) what.appendChild(el("span", "meta", cue.kind));
    head.appendChild(what);
    var age = C.relative_time(newest.time, new Date());
    if (age) head.appendChild(el("span", "meta", age));
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

  // The project switch (v0.139): a button with role switch; it posts on the answer path and keeps the new position
  // while the (cached) feed catches up. Off without a sink or a token, and while its POST is out.
  function switchRow(d) {
    var nowMs = Date.now();
    var sw = switches[d.name];
    // done: a refusal's note stays for the hold, a switch that went through until the feed shows it
    if (sw && !sw.sending && (sw.note ? nowMs - sw.at >= C.SWITCH_HOLD_MS : C.switchSettled(d.active, sw, nowMs))) {
      delete switches[d.name];
      sw = null;
    }
    var shown = C.switchShown(d.active, sw && !sw.note ? sw : null, nowMs);
    var row = el("div", "row switch-row");
    row.setAttribute("data-shown", shown ? "true" : "false");
    var b = el("button", "switch");
    b.type = "button";
    b.setAttribute("role", "switch");
    b.setAttribute("aria-checked", shown ? "true" : "false");
    b.setAttribute("aria-label", d.name + " active");
    b.appendChild(el("span", "knob"));
    b.appendChild(el("span", "", shown ? "active" : "off"));
    b.disabled = !answerUrl || !tokenSet() || !!(sw && sw.sending);
    b.addEventListener("click", function () { flipProject(d.name, !shown); });
    row.appendChild(b);
    var why = !answerUrl ? "read-only: no answer URL" : !tokenSet() ? "set the device token to switch" : sw && sw.sending ? "switching\u2026" : sw && sw.note ? sw.note : "";
    if (why) row.appendChild(el("span", sw && sw.note && !sw.sending ? "stat-bad" : "meta", why));
    return row;
  }

  function flipProject(name, active) {
    var sw = switches[name] = { active: active, at: Date.now(), note: "", sending: true };
    render();
    var body = C.projectActiveBody(name, active, C.newAnswerId(crypto.getRandomValues(new Uint8Array(16))), new Date());
    var req = sinkRequest(body);
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, 25000);
    req.init.signal = ctl.signal;
    fetch(req.url, req.init).then(function (resp) {
      return C.switchResult(resp.status, resp.headers.get("X-Reason"));
    }, function (e) {
      return C.switchResult(0, e && e.name === "AbortError" ? "timeout" : "unreachable or refused");
    }).then(function (note) {
      clearTimeout(timer);
      sw.sending = false;
      sw.note = note;
      sw.at = Date.now();
      render();
    });
  }

  // The Release button (v0.140): it opens the confirm dialog; off, saying why, at N = 0, without a sink or a token.
  function releaseRow(p) {
    var rv = C.releaseView(p, !!answerUrl);
    var name = String(p.project || "");
    var row = el("div", "row release-row");
    var b = el("button", "release", "Release");
    b.type = "button";
    b.setAttribute("aria-label", "Release " + name);
    var why = rv.why || (!tokenSet() ? "set the device token to release" : "");
    b.disabled = !!why;
    b.addEventListener("click", function () { openRelease(p); });
    row.appendChild(b);
    var said = why || releases[name] || "";
    if (said) row.appendChild(el("span", said.indexOf("not sent") === 0 ? "stat-bad" : "meta", said));
    return row;
  }

  // One dialog for every card, outside <main> so a re-render never closes it. Its answer_id is made when it opens and
  // kept for a Retry with the same note (the sink answers a replay 200 and never posts twice).
  function openRelease(p) {
    var rv = C.releaseView(p, !!answerUrl);
    if (!rv.enabled || !tokenSet()) return;
    var name = String(p.project || "");
    var dlg = document.getElementById("release-dialog");
    if (dlg) dlg.remove();
    dlg = el("dialog", "release-dialog");
    dlg.id = "release-dialog";
    dlg.setAttribute("aria-labelledby", "release-title");
    var title = el("p", "release-title", rv.title);
    title.id = "release-title";
    dlg.appendChild(title);
    dlg.appendChild(el("p", "meta", "This asks the PO to cut the release now; nothing is tagged or pushed from here."));
    var box = el("textarea", "");
    box.rows = 4;
    box.placeholder = "Note for the release (optional)";
    box.setAttribute("aria-label", "Note for the release");
    dlg.appendChild(box);
    var counter = el("div", "counter meta", "");
    dlg.appendChild(counter);
    var state = el("div", "release-state meta", "");
    state.setAttribute("role", "status");
    dlg.appendChild(state);
    var foot = el("div", "row send-row");
    var cancel = el("button", "cancel", "Cancel");
    cancel.type = "button";
    var go = el("button", "", "Release");
    go.type = "button";
    foot.appendChild(cancel);
    foot.appendChild(go);
    dlg.appendChild(foot);
    var sent = { aid: C.newAnswerId(crypto.getRandomValues(new Uint8Array(16))), note: null, sending: false };
    function ready() {
      var n = box.value.trim().length;
      counter.textContent = n + " / " + C.RELEASE_NOTE_MAX;
      counter.className = "counter " + (n > C.RELEASE_NOTE_MAX ? "stat-bad" : "meta");
      go.disabled = sent.sending || !C.releaseReady(box.value);
    }
    box.addEventListener("input", ready);
    box.addEventListener("keydown", function (e) {
      if (!C.releaseKeySends(e)) return;
      e.preventDefault();
      go.click();  // a disabled or sending Release ignores it, as a click would
    });
    cancel.addEventListener("click", function () { dlg.close(); });
    dlg.addEventListener("close", function () { dlg.remove(); });
    go.addEventListener("click", function () {
      if (sent.sending || !C.releaseReady(box.value)) return;
      if (sent.note !== null && sent.note !== box.value) sent.aid = C.newAnswerId(crypto.getRandomValues(new Uint8Array(16)));
      sent.note = box.value;
      sent.sending = true;
      go.textContent = "Releasing\u2026";
      state.textContent = "sending\u2026";
      state.className = "release-state meta";
      ready();
      var req = sinkRequest(C.releaseBody(name, box.value, sent.aid, new Date()));
      var ctl = new AbortController();
      var timer = setTimeout(function () { ctl.abort(); }, 25000);
      req.init.signal = ctl.signal;
      fetch(req.url, req.init).then(function (resp) {
        return C.releaseResult(resp.status, resp.headers.get("X-Reason"));
      }, function (e) {
        return C.releaseResult(0, e && e.name === "AbortError" ? "timeout" : "unreachable or refused");
      }).then(function (res) {
        clearTimeout(timer);
        sent.sending = false;
        releases[name] = res;
        if (res === C.RELEASE_SENT) {
          dlg.close();
        } else {
          state.textContent = res;
          state.className = "release-state stat-bad";
          go.textContent = "Retry";
          ready();
        }
        render();
      });
    });
    ready();
    document.body.appendChild(dlg);
    if (typeof dlg.showModal === "function") dlg.showModal(); else dlg.setAttribute("open", "");
    box.focus();
  }

  function projectCard(p) {
    var d = C.projectCard(p, new Date(), stallMinutes);
    var card = el("article", "card" + (d.grey ? " grey" : ""));
    var top = el("div", "row");
    top.appendChild(el("strong", "", d.name));
    var row = d.active !== null ? switchRow(d) : null;
    // the badge follows the switch, so a switch still on its way shows at once
    var badge = row ? (row.getAttribute("data-shown") === "false" ? "inactive" : "") : d.badge;
    if (badge) top.appendChild(el("span", "badge", badge));
    top.appendChild(el("div", d.releaseMuted ? "meta" : "", d.release));
    card.appendChild(top);
    if (row) card.appendChild(row);
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
    card.appendChild(releaseRow(p));
    return card;
  }

  // An agent's switch (v0.173): the project switch's button, one per Team card, only with a sink. The OFF badge
  // follows it, so a switch still on its way shows at once.
  function agentSwitchRow(name, feedActive) {
    var nowMs = Date.now();
    var sw = agentSwitches[name];
    if (sw && !sw.sending && (sw.note ? nowMs - sw.at >= C.SWITCH_HOLD_MS : C.switchSettled(feedActive, sw, nowMs))) {
      delete agentSwitches[name];
      sw = null;
    }
    var shown = C.switchShown(feedActive, sw && !sw.note ? sw : null, nowMs);
    var row = el("div", "row switch-row");
    row.setAttribute("data-shown", shown ? "true" : "false");
    var b = el("button", "switch");
    b.type = "button";
    b.setAttribute("role", "switch");
    b.setAttribute("aria-checked", shown ? "true" : "false");
    b.setAttribute("aria-label", name + " active");
    b.appendChild(el("span", "knob"));
    b.appendChild(el("span", "", shown ? "on" : "off"));
    b.disabled = !tokenSet() || !!(sw && sw.sending);
    b.addEventListener("click", function () { flipAgent(name, !shown); });
    row.appendChild(b);
    var why = !tokenSet() ? "set the device token to switch" : sw && sw.sending ? "switching\u2026" : sw && sw.note ? sw.note : "";
    if (why) row.appendChild(el("span", sw && sw.note && !sw.sending ? "stat-bad" : "meta", why));
    return row;
  }

  function flipAgent(name, active) {
    var sw = agentSwitches[name] = { active: active, at: Date.now(), note: "", sending: true };
    render();
    var body = C.agentActiveBody(name, active, C.newAnswerId(crypto.getRandomValues(new Uint8Array(16))), new Date());
    var req = sinkRequest(body);
    var ctl = new AbortController();
    var timer = setTimeout(function () { ctl.abort(); }, 25000);
    req.init.signal = ctl.signal;
    fetch(req.url, req.init).then(function (resp) {
      return C.switchResult(resp.status, resp.headers.get("X-Reason"));
    }, function (e) {
      return C.switchResult(0, e && e.name === "AbortError" ? "timeout" : "unreachable or refused");
    }).then(function (note) {
      clearTimeout(timer);
      sw.sending = false;
      sw.note = note;
      sw.at = Date.now();
      render();
    });
  }

  function teamCard(a, shared) {
    var now = new Date();
    var name = String(a.agent || "?");
    var switchRow = answerUrl ? agentSwitchRow(name, !C.teamOff(a)) : null;
    var off = switchRow ? switchRow.getAttribute("data-shown") === "false" : C.teamOff(a);
    var warning = off ? null : C.team_warning(a, now);
    var card = el("article", "card" + (warning ? " warn" : "") + (off ? " off" : ""));
    var row = el("div", "row");
    row.appendChild(el("strong", "", name));
    // a live limit replaces the feed's own state text: one line, the dashboard's one time format (v0.142);
    // switched off (v0.173), an OFF badge takes the state's place, a live limit still said after it
    var stateLine = [off ? C.limitText(a, now) : C.limitText(a, now) || a.state, a.now ? "on " + C.itemRef(a.now) : ""].filter(Boolean).join(" · ");
    if (off) {
      var st = el("div", "meta");
      st.appendChild(el("span", "badge off", "OFF"));
      if (stateLine) st.appendChild(document.createTextNode(" " + stateLine));
      row.appendChild(st);
      stateLine = "OFF" + (stateLine ? " · " + stateLine : "");
    } else {
      row.appendChild(el("div", C.isWorking(a) ? "meta state-working" : "meta", stateLine));
    }
    var split = C.split_owns(a.owns || [], a.working_on || null);
    if (split.working_on && split.working_on.length) {
      var label = "working on: " + split.working_on.map(C.itemRef).join(", ");
      if (split.parked && split.parked.length) label += " · parked: " + split.parked.map(C.itemRef).join(", ");
      row.appendChild(el("div", "meta", label));
    } else if (split.all && split.all.length) {
      row.appendChild(el("div", "meta", "owns " + split.all.map(C.itemRef).join(", ")));
    }
    var usageText = C.usage_words(a.usage || null);
    if (usageText && usageText !== shared) {  // a shared subscription's usage is said once, above the cards
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
    if (switchRow) card.appendChild(switchRow);
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
      data = C.team_sort(data, new Date());
      var shared = C.teamUsage(data);
      if (shared) main.appendChild(el("p", "meta team-head", "Subscription: " + shared));
      if (!data.length) main.appendChild(el("p", "empty", EMPTY[view]));
      data.forEach(function (x) { main.appendChild(teamCard(x, shared)); });
      return;
    }
    if (view === "decisions") data = C.sortDecisions(feedsNow().decisions);  // the desktop viewer's order (v0.141)
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
