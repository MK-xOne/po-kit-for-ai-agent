// The web view in a real headless browser (v0.116): a draft survives a reload, Send posts once to the sink and
// the card shows `sent <time>`, an unreachable sink keeps the draft and shows `not sent: <class>`, and 390 px
// screenshots of a long-label card; v0.139: the Projects card's switch posts once and the badge follows it; v0.140: the Release dialog posts once. Not part of tests/run.sh (it needs a Chromium); run it by hand:
//   PO_WEB_CHROME=<chrome or chrome-headless-shell> node tests/web-browser.test.js <out dir>
// It starts, on loopback only, a stub feed server, a stub answer sink (it answers the page's preflight and
// records every POST), `po serve` with both configured, and the browser with a remote-debugging pipe-free
// port; everything is stopped at the end. Prints ok/FAIL lines and BLOCK-END web-browser like web-core.
"use strict";
const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");

const ROOT = path.join(__dirname, "..");
const CHROME = process.env.PO_WEB_CHROME;
const OUT = process.argv[2];
if (!CHROME || !OUT) { console.error("usage: PO_WEB_CHROME=<chrome> node tests/web-browser.test.js <out dir>"); process.exit(1); }
fs.mkdirSync(OUT, { recursive: true });
const TOKEN = "test-token-0123456789abcdefghijkl";

function check(name, cond, detail) {
  console.log((cond ? "ok" : "FAIL") + "\t" + name + "\t" + String(detail === undefined ? "" : detail).replace(/\n/g, " | "));
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const procs = [];

// A child that prints "PORT <n>" (or po serve's "listening on http://127.0.0.1:<n>/") once it listens.
function start(cmd, args, re) {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
    procs.push(p);
    let buf = "";
    const seen = (d) => { buf += d; const m = buf.match(re); if (m) resolve({ p, port: Number(m[1]), log: () => buf }); };
    p.stdout.on("data", seen);
    p.stderr.on("data", seen);
    p.on("exit", (c) => reject(new Error(cmd + " exited " + c + ": " + buf)));
  });
}

// Feed stub: /decisions.json is examples/decisions-feed.json with the asked times moved to now; /projects.json is
// examples/projects-feed.json with `active` set on the first three projects (v0.139) and a fourth without it.
const FEED_PY = String.raw`
import http.server, json, sys, datetime
d = json.load(open(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for c in d:
    if isinstance(c, dict): c["asked_at"] = now
body = json.dumps(d).encode()
p = json.load(open(sys.argv[2]))
for e, a in zip(p, (True, False, True)): e["active"] = a
p.append(dict(p[0], project="grove")); p[-1].pop("active")
pbody = json.dumps(p).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        proj = self.path.startswith("/projects.json")
        self.send_response(200 if self.path.startswith("/decisions.json") or proj else 404)
        self.send_header("Content-Type", "application/json"); self.send_header("ETag", '"2"' if proj else '"1"'); self.end_headers()
        self.wfile.write(pbody if proj else body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); print("PORT", s.server_address[1], flush=True); s.serve_forever()
`;
// Sink stub: the CORS answers of the design (2.5), every POST appended as one JSON line to argv[1].
const SINK_PY = String.raw`
import http.server, json, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def cors(self):
        o = self.headers.get("Origin")
        if o: self.send_header("Access-Control-Allow-Origin", o); self.send_header("Vary", "Origin")
    def do_OPTIONS(self):
        self.send_response(204); self.cors()
        self.send_header("Access-Control-Allow-Methods", "POST")
        self.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type"); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0"))
        rec = {"auth": self.headers.get("Authorization"), "type": self.headers.get("Content-Type"),
               "body": json.loads(self.rfile.read(n))}
        with open(sys.argv[1], "a") as f: f.write(json.dumps(rec) + "\n")
        refuse = rec["body"].get("project") == "meadow"
        if rec["body"].get("project") == "orchard": time.sleep(4)  # v0.139: holds the switch in its switching state
        self.send_response(404 if refuse else 201); self.cors(); self.send_header("Access-Control-Expose-Headers", "X-Reason")
        if refuse: self.send_header("X-Reason", "unknown project")
        self.send_header("Content-Length", "0"); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); print("PORT", s.server_address[1], flush=True); s.serve_forever()
`;

// A minimal CDP client over the browser's page websocket (node's global WebSocket).
async function cdp(port) {
  let targets;
  for (let i = 0; i < 50 && !targets; i++) {
    try { targets = await (await fetch("http://127.0.0.1:" + port + "/json/list")).json(); } catch (e) { await sleep(100); }
  }
  const page = targets.find((t) => t.type === "page");
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r) => ws.addEventListener("open", r));
  let id = 0;
  const wait = {};
  const events = [];
  ws.addEventListener("message", (m) => {
    const d = JSON.parse(m.data);
    if (d.id && wait[d.id]) { wait[d.id](d); delete wait[d.id]; } else if (d.method) events.push(d);
  });
  const send = (method, params) => new Promise((r) => { const n = ++id; wait[n] = r; ws.send(JSON.stringify({ id: n, method, params: params || {} })); });
  const evaluate = async (expr) => {
    const r = await send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });
    if (r.result.exceptionDetails) throw new Error(expr + ": " + JSON.stringify(r.result.exceptionDetails));
    return r.result.result.value;
  };
  const until = async (expr, ms) => {
    for (let t = 0; t < (ms || 8000); t += 100) { if (await evaluate(expr)) return true; await sleep(100); }
    return false;
  };
  const shot = async (file, width) => {
    const w = width || 390;
    if (w !== 390) { await send("Emulation.setDeviceMetricsOverride", { width: w, height: 844, deviceScaleFactor: 1, mobile: false }); await sleep(300); }
    const h = await evaluate("Math.ceil(document.documentElement.scrollHeight)");
    await send("Emulation.setDeviceMetricsOverride", { width: w, height: h, deviceScaleFactor: 1, mobile: w === 390 });
    const r = await send("Page.captureScreenshot", { format: "png" });
    fs.writeFileSync(file, Buffer.from(r.result.data, "base64"));
    await send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  };
  return { send, evaluate, until, shot, events, close: () => ws.close() };
}

// Expand the card whose title starts with `title` (a tap on its header) and return nothing.
const expand = (title) => `(() => { const b = [...document.querySelectorAll("article.card button.head")]
  .find((x) => x.textContent.includes(${JSON.stringify(title)})); b.click(); return true; })()`;
const cardOf = (title) => `[...document.querySelectorAll("article.card")].find((x) => x.querySelector("button.head").textContent.includes(${JSON.stringify(title)}))`;

(async () => {
  const posts = path.join(OUT, "sink-posts.jsonl");
  fs.rmSync(posts, { force: true });
  const feed = await start("python3", ["-I", "-c", FEED_PY, path.join(ROOT, "examples", "decisions-feed.json"),
    path.join(ROOT, "examples", "projects-feed.json")], /PORT (\d+)/);
  const sink = await start("python3", ["-I", "-c", SINK_PY, posts], /PORT (\d+)/);
  const serve = await start("python3", ["-B", path.join(ROOT, "lib", "po", "serve.py"), "--repo", ROOT, "--port", "0",
    "--decisions-url", "http://127.0.0.1:" + feed.port + "/decisions.json",
    "--projects-url", "http://127.0.0.1:" + feed.port + "/projects.json",
    "--answer-url", "http://127.0.0.1:" + sink.port + "/answers"], /listening on http:\/\/127\.0\.0\.1:(\d+)\//);
  const profile = fs.mkdtempSync(path.join(OUT, "profile-"));
  const chrome = await start(CHROME, ["--headless", "--no-sandbox", "--disable-gpu", "--no-first-run", "--remote-debugging-port=0",
    "--user-data-dir=" + profile, "--window-size=390,844", "about:blank"], /DevTools listening on ws:\/\/127\.0\.0\.1:(\d+)\//);
  const b = await cdp(chrome.port);
  const APP = "http://127.0.0.1:" + serve.port + "/app/";
  try {
    await b.send("Page.enable");
    await b.send("Emulation.setDeviceMetricsOverride", { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
    await b.send("Page.navigate", { url: APP });
    await b.until("document.querySelectorAll('article.card').length > 0");
    check("web-browser: no device token: Send is off and the card says why",
      await b.evaluate(`(${expand("Accept the new import screen")}, (() => { const c = ${cardOf("Accept the new import screen")};
        return c.querySelector("button.send").disabled && c.textContent.includes("set the device token to answer"); })())`));
    await b.evaluate(`localStorage.setItem("po-web:device-token", ${JSON.stringify(TOKEN)}); true`);
    await b.send("Page.reload");
    await b.until("document.querySelectorAll('article.card').length > 0");
    check("web-browser: the header says the token is set and never shows it",
      await b.evaluate(`document.getElementById("settings-toggle").textContent === "device token set \u00b7 change" && !document.body.innerText.includes(${JSON.stringify(TOKEN)})`));
    // v0.142 (18): once set it is a small settings link (smaller text than the view tabs, no button frame), still 44 px tall
    const link = await b.evaluate(`(() => { const t = document.getElementById("settings-toggle"), v = document.querySelector("#views button");
      const s = getComputedStyle(t); return [t.classList.contains("link"), parseFloat(s.fontSize) < parseFloat(getComputedStyle(v).fontSize),
      s.borderTopWidth, t.getBoundingClientRect().height]; })()`);
    check("web-browser: v0.142 a set token is a small settings link, not a full-size button", link[0] && link[1] && link[2] === "0px" && link[3] >= 44, JSON.stringify(link));

    // a draft: pick a radio and type a note, then reload
    await b.evaluate(expand("Accept the new import screen"));
    await b.evaluate(`(() => { const c = ${cardOf("Accept the new import screen")}; const r = c.querySelectorAll("input[type=radio]");
      r[1].click(); const t = c.querySelector("textarea"); t.value = "after the demo"; t.dispatchEvent(new Event("input")); return true; })()`);
    const before = await b.evaluate(`(() => { const c = ${cardOf("Accept the new import screen")};
      return [[...c.querySelectorAll("input[type=radio]")].findIndex((x) => x.checked), c.querySelector("textarea").value, c.querySelector("button.send").disabled]; })()`);
    check("web-browser: a pick enables Send", before[0] === 1 && before[2] === false, JSON.stringify(before));
    await b.send("Page.reload");
    await b.until("document.querySelectorAll('article.card').length > 0");
    await b.evaluate(expand("Accept the new import screen"));
    const after = await b.evaluate(`(() => { const c = ${cardOf("Accept the new import screen")};
      return [[...c.querySelectorAll("input[type=radio]")].findIndex((x) => x.checked), c.querySelector("textarea").value, c.querySelector("button.send").disabled]; })()`);
    check("web-browser: the draft (pick and note) survives a reload", JSON.stringify(after) === JSON.stringify(before), JSON.stringify([before, after]));
    // a poll redraw (10 s) keeps it too
    await sleep(11000);
    const polled = await b.evaluate(`(() => { const c = ${cardOf("Accept the new import screen")};
      return c ? [[...c.querySelectorAll("input[type=radio]")].findIndex((x) => x.checked), c.querySelector("textarea").value] : null; })()`);
    check("web-browser: the draft survives a feed refresh", JSON.stringify(polled) === JSON.stringify(before.slice(0, 2)), JSON.stringify(polled));

    // the long-label card, stacked at 390 px, Send in view
    await b.evaluate(expand("Pick the rollout plan"));
    const layout = await b.evaluate(`(() => { const c = ${cardOf("Pick the rollout plan")}; const s = c.querySelector("button.send").getBoundingClientRect();
      return { scrollW: document.documentElement.scrollWidth, sendRight: s.right, sendH: s.height,
               picks: [...c.querySelectorAll("label.pick")].map((l) => Math.round(l.getBoundingClientRect().height)) }; })()`);
    check("web-browser: at 390 px a long-label card has no sideways scroll, labels wrap, Send is 44 px tall and inside the screen",
      layout.scrollW <= 390 && layout.sendRight <= 390 && layout.sendH >= 44 && Math.max(...layout.picks) > 60 && Math.min(...layout.picks) >= 44, JSON.stringify(layout));
    await b.shot(path.join(OUT, "answer-390.png"));

    // Send: one POST with the bearer token, then `sent <time>`; a second tap cannot post again
    const sendExpr = `(() => { const c = ${cardOf("Accept the new import screen")}; const s = c.querySelector("button.send"); s.click(); s.click();
      return s.disabled; })()`;
    check("web-browser: Send disables on the tap", await b.evaluate(sendExpr));
    const sent = await b.until(`(() => { const c = ${cardOf("Accept the new import screen")}; return /^sent \\d{1,2}:\\d{2} [AP]M$/.test((c.querySelector(".answer-state") || {}).textContent); })()`);
    const lines = fs.existsSync(posts) ? fs.readFileSync(posts, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse) : [];
    check("web-browser: Send posts once to the sink with the bearer token and JSON, and the card shows `sent <time>`",
      sent && lines.length === 1 && lines[0].auth === "Bearer " + TOKEN && /^application\/json/.test(lines[0].type), JSON.stringify(lines));
    check("web-browser: the posted body is the card's, with the picked option and the note",
      lines.length === 1 && lines[0].body.id === "ask-0707" && lines[0].body.client === "po-dashboard" && lines[0].body.text === "after the demo"
      && typeof lines[0].body.option === "string" && /^[0-9a-f-]{36}$/.test(lines[0].body.answer_id), JSON.stringify(lines[0] && lines[0].body));
    check("web-browser: after a sent answer the draft is gone from storage",
      await b.evaluate(`!("ask-0707" in JSON.parse(localStorage.getItem("po-web:drafts") || "{}"))`));
    await b.shot(path.join(OUT, "sent-390.png"));

    // v0.139: the Projects card's switch
    const projCard = (name) => `[...document.querySelectorAll("article.card")].find((x) => x.querySelector("strong") && x.querySelector("strong").textContent === ${JSON.stringify(name)})`;
    await b.evaluate(`location.hash = "#projects"; true`);
    await b.until(`!!(${projCard("harbor")})`);
    const pv = await b.evaluate(`(() => {
      const card = (n) => [...document.querySelectorAll("article.card")].find((x) => x.querySelector("strong") && x.querySelector("strong").textContent === n);
      const sw = (n) => card(n).querySelector("button.switch");
      const badge = (n) => (card(n).querySelector(".badge") || {}).textContent || "";
      return { harborBadge: badge("harbor"), orchardBadge: badge("orchard"), groveSwitch: !!sw("grove"), groveBadge: badge("grove"),
               harborChecked: sw("harbor").getAttribute("aria-checked"), harborRole: sw("harbor").getAttribute("role"),
               harborWords: sw("harbor").textContent, harborH: Math.round(sw("harbor").getBoundingClientRect().height),
               scrollW: document.documentElement.scrollWidth }; })()`);
    check("web-browser: v0.139 an inactive project's card shows the `inactive` badge as text, an active one none",
      pv.harborBadge === "inactive" && pv.orchardBadge === "", JSON.stringify(pv));
    check("web-browser: v0.139 the switch is a role=switch button, aria-checked false and `off` in words for an inactive project, 44 px tall",
      pv.harborRole === "switch" && pv.harborChecked === "false" && pv.harborWords === "off" && pv.harborH >= 44, JSON.stringify(pv));
    check("web-browser: v0.139 a feed entry without `active` renders with neither switch nor badge", pv.groveSwitch === false && pv.groveBadge === "", JSON.stringify(pv));
    check("web-browser: v0.139 no sideways scroll at 390 px on the Projects view", pv.scrollW <= 390, pv.scrollW);
    await b.shot(path.join(OUT, "projects-light-390.png"));
    await b.shot(path.join(OUT, "projects-light-1280.png"), 1280);
    const nPosts = fs.readFileSync(posts, "utf8").trim().split("\n").length;
    await b.evaluate(`${projCard("harbor")}.querySelector("button.switch").click(), true`);
    const switched = await b.until(`(() => { const c = ${projCard("harbor")}; const s = c.querySelector("button.switch");
      return s.getAttribute("aria-checked") === "true" && !s.disabled && !c.querySelector(".badge") && s.textContent === "active"; })()`);
    const swPosts = fs.readFileSync(posts, "utf8").trim().split("\n").map(JSON.parse).slice(nPosts);
    check("web-browser: v0.139 a tap posts one project-active body with the device token; the switch shows on and the badge goes",
      switched && swPosts.length === 1 && swPosts[0].auth === "Bearer " + TOKEN && swPosts[0].body.kind === "project-active"
      && swPosts[0].body.project === "harbor" && swPosts[0].body.active === true && /^[0-9a-f-]{36}$/.test(swPosts[0].body.answer_id), JSON.stringify(swPosts));
    await sleep(11000);  // a poll: the feed still says false, the switch keeps the new position
    check("web-browser: v0.139 the switched card keeps its new position across a feed refresh that does not show it yet",
      await b.evaluate(`${projCard("harbor")}.querySelector("button.switch").getAttribute("aria-checked") === "true"`));
    await b.evaluate(`${projCard("meadow")}.querySelector("button.switch").click(), true`);
    const refused = await b.until(`(() => { const c = ${projCard("meadow")}; return c.textContent.includes("not switched: unknown project")
      && c.querySelector("button.switch").getAttribute("aria-checked") === "true"; })()`);
    check("web-browser: v0.139 a refused switch says `not switched: unknown project` and shows the feed's position again", refused);
    await b.shot(path.join(OUT, "projects-switched-light-390.png"));
    await b.evaluate(`${projCard("orchard")}.querySelector("button.switch").click(), true`);
    const switching = await b.until(`(() => { const c = ${projCard("orchard")}; const s = c.querySelector("button.switch");
      return s.disabled && s.getAttribute("aria-checked") === "false" && c.textContent.includes("switching\u2026"); })()`, 3000);
    check("web-browser: v0.139 while its POST is out the switch shows the new position, is off and says switching…", switching);
    await b.shot(path.join(OUT, "projects-switching-light-390.png"));
    await b.until(`!${projCard("orchard")}.querySelector("button.switch").disabled`, 8000);
    await b.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
    await sleep(300);
    await b.shot(path.join(OUT, "projects-dark-390.png"));
    await b.shot(path.join(OUT, "projects-dark-1280.png"), 1280);
    await b.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }] });
    // v0.140: the Release button and its confirm dialog
    const rv = await b.evaluate(`(() => {
      const card = (n) => [...document.querySelectorAll("article.card")].find((x) => x.querySelector("strong") && x.querySelector("strong").textContent === n);
      const rb = (n) => card(n).querySelector("button.release");
      return { orchardOn: !rb("orchard").disabled, harborOff: rb("harbor").disabled,
               harborWhy: card("harbor").querySelector(".release-row").textContent,
               h: Math.round(rb("orchard").getBoundingClientRect().height), scrollW: document.documentElement.scrollWidth }; })()`);
    check("web-browser: v0.140 every card has a 44 px Release button, off at N = 0 saying why",
      rv.orchardOn && rv.harborOff && rv.harborWhy.includes("nothing to release: no DONE item since the start (no release yet)") && rv.h >= 44 && rv.scrollW <= 390, JSON.stringify(rv));
    const nPosts140 = fs.readFileSync(posts, "utf8").trim().split("\n").length;
    await b.evaluate(`${projCard("orchard")}.querySelector("button.release").click(), true`);
    const dlgOpen = await b.until(`(() => { const d = document.getElementById("release-dialog"); return !!d && d.open
      && d.querySelector(".release-title").textContent === "Release orchard: 1 DONE item since release-3"; })()`, 3000);
    check("web-browser: v0.140 Release opens a modal dialog titled with N and the last release", dlgOpen);
    await b.evaluate(`(() => { const t = document.querySelector("#release-dialog textarea"); t.value = "line one\\n  line two"; t.dispatchEvent(new Event("input")); return true; })()`);
    await b.shot(path.join(OUT, "release-dialog-light-390.png"));
    await b.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "dark" }] });
    await sleep(300);
    await b.shot(path.join(OUT, "release-dialog-dark-390.png"));
    await b.shot(path.join(OUT, "release-dialog-dark-1280.png"), 1280);
    await b.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-color-scheme", value: "light" }] });
    await b.evaluate(`[...document.querySelectorAll("#release-dialog button")].find((x) => x.textContent === "Release").click(), true`);
    const asked = await b.until(`(() => !document.getElementById("release-dialog") && ${projCard("orchard")}.textContent.includes("release asked · sent"))()`, 8000);
    const rlPosts = fs.readFileSync(posts, "utf8").trim().split("\n").map(JSON.parse).slice(nPosts140);
    check("web-browser: v0.140 the dialog's Release posts one release-request with the note as typed and the device token; the card says release asked",
      asked && rlPosts.length === 1 && rlPosts[0].auth === "Bearer " + TOKEN && rlPosts[0].body.kind === "release-request"
      && rlPosts[0].body.project === "orchard" && rlPosts[0].body.note === "line one\n  line two", JSON.stringify(rlPosts));
    await b.shot(path.join(OUT, "release-asked-light-390.png"));
    await b.evaluate(`${projCard("orchard")}.querySelector("button.release").click(), true`);
    await b.until(`!!document.getElementById("release-dialog")`, 3000);
    await b.evaluate(`[...document.querySelectorAll("#release-dialog button")].find((x) => x.textContent === "Cancel").click(), true`);
    check("web-browser: v0.140 Cancel closes the dialog and posts nothing",
      await b.until(`!document.getElementById("release-dialog")`, 3000) && fs.readFileSync(posts, "utf8").trim().split("\n").length === nPosts140 + 1);
    await b.evaluate(`${projCard("orchard")}.querySelector("button.release").click(), true`);
    await b.until(`!!document.getElementById("release-dialog")`, 3000);
    await b.evaluate(`(() => { const t = document.querySelector("#release-dialog textarea"); t.value = "by keyboard"; t.dispatchEvent(new Event("input"));
      t.dispatchEvent(new KeyboardEvent("keydown", { key: "Enter", ctrlKey: true, bubbles: true, cancelable: true })); return true; })()`);
    const keyed = await b.until(`!document.getElementById("release-dialog")`, 8000);
    const kPosts = fs.readFileSync(posts, "utf8").trim().split("\n").map(JSON.parse).slice(nPosts140);
    check("web-browser: v0.140 Ctrl+Enter in the note posts the release-request like Release and closes the dialog",
      keyed && kPosts.length === 2 && kPosts[1].auth === "Bearer " + TOKEN && kPosts[1].body.kind === "release-request"
      && kPosts[1].body.project === "orchard" && kPosts[1].body.note === "by keyboard", JSON.stringify(kPosts));
    await b.evaluate(`localStorage.removeItem("po-web:device-token"); location.hash = "#projects"; true`);
    await b.send("Page.reload");
    await b.until(`!!(${projCard("orchard")})`);
    check("web-browser: v0.139 without a device token the switch is off and the card says why",
      await b.evaluate(`(() => { const c = ${projCard("orchard")}; return c.querySelector("button.switch").disabled && c.textContent.includes("set the device token to switch"); })()`));
    await b.shot(path.join(OUT, "projects-disabled-light-390.png"));
    await b.evaluate(`localStorage.setItem("po-web:device-token", ${JSON.stringify(TOKEN)}); location.hash = "#decisions"; true`);
    await b.send("Page.reload");
    await b.until("document.querySelectorAll('article.card button.head').length > 0");

    // the sink goes away: the draft stays and the card says `not sent: <class>`
    sink.p.kill();
    await sleep(300);
    await b.evaluate(expand("Choose the cache policy"));
    await b.evaluate(`(() => { const c = ${cardOf("Choose the cache policy")}; c.querySelectorAll("input[type=radio]")[0].click(); return true; })()`);
    await b.evaluate(`${cardOf("Choose the cache policy")}.querySelector("button.send").click(), true`);
    const notSent = await b.until(`(() => { const c = ${cardOf("Choose the cache policy")}; return (c.querySelector(".answer-state") || {}).textContent === "not sent: unreachable or refused"; })()`);
    const kept = await b.evaluate(`(() => { const c = ${cardOf("Choose the cache policy")}; return [c.querySelectorAll("input[type=radio]")[0].checked, !c.querySelector("button.send").disabled,
      "ask-0206" in JSON.parse(localStorage.getItem("po-web:drafts") || "{}")]; })()`);
    check("web-browser: an unreachable sink shows `not sent: unreachable or refused`, keeps the draft and Send comes back",
      notSent && kept.every(Boolean), JSON.stringify(kept));
    await b.shot(path.join(OUT, "not-sent-390.png"));
    check("web-browser: the token is never in the page's text or address",
      await b.evaluate(`!document.body.innerText.includes(${JSON.stringify(TOKEN)}) && !location.href.includes(${JSON.stringify(TOKEN)}) && !document.title.includes(${JSON.stringify(TOKEN)})`));
  } catch (e) {
    check("web-browser: the run finished", false, e.stack);
  } finally {
    b.close();
    procs.forEach((p) => { try { p.kill(); } catch (e) { /* gone */ } });
    await sleep(300);
    fs.rmSync(profile, { recursive: true, force: true });
    console.log("BLOCK-END web-browser");
    process.exit(0);
  }
})();
