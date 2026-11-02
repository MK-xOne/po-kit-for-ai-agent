// The web view in a real headless browser (v0.116): a draft survives a reload, Send posts once to the sink and
// the card shows `sent <time>`, an unreachable sink keeps the draft and shows `not sent: <class>`, and 390 px
// screenshots of a long-label card. Not part of tests/run.sh (it needs a Chromium); run it by hand:
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

// Feed stub: /decisions.json is examples/decisions-feed.json with the asked times moved to now.
const FEED_PY = String.raw`
import http.server, json, sys, datetime
d = json.load(open(sys.argv[1]))
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
for c in d:
    if isinstance(c, dict): c["asked_at"] = now
body = json.dumps(d).encode()
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path.startswith("/decisions.json") else 404)
        self.send_header("Content-Type", "application/json"); self.send_header("ETag", '"1"'); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H); print("PORT", s.server_address[1], flush=True); s.serve_forever()
`;
// Sink stub: the CORS answers of the design (2.5), every POST appended as one JSON line to argv[1].
const SINK_PY = String.raw`
import http.server, json, sys
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
        self.send_response(201); self.cors(); self.send_header("Access-Control-Expose-Headers", "X-Reason")
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
  const shot = async (file) => {
    const h = await evaluate("Math.ceil(document.documentElement.scrollHeight)");
    await send("Emulation.setDeviceMetricsOverride", { width: 390, height: h, deviceScaleFactor: 1, mobile: true });
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
  const feed = await start("python3", ["-I", "-c", FEED_PY, path.join(ROOT, "examples", "decisions-feed.json")], /PORT (\d+)/);
  const sink = await start("python3", ["-I", "-c", SINK_PY, posts], /PORT (\d+)/);
  const serve = await start("python3", ["-B", path.join(ROOT, "lib", "po", "serve.py"), "--repo", ROOT, "--port", "0",
    "--decisions-url", "http://127.0.0.1:" + feed.port + "/decisions.json",
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
      await b.evaluate(`document.getElementById("settings-toggle").textContent === "Device token set" && !document.body.innerText.includes(${JSON.stringify(TOKEN)})`));

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
