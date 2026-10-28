#!/usr/bin/env python3
"""po-kit: po serve — a small read-only HTTP viewer of the gate events.

Events come only from `po events --json` (one JSON object per event, or one
JSON array); the log file is never read here. GET only, standard library only.
Run through lib/po/serve.sh, which has already worked out the repository.
"""
import argparse
import html
import http.server
import ipaddress
import json
import os
import socket
import subprocess
import sys

LAST = 10
COLUMNS = ("result", "item", "project", "kind", "checks", "agent", "took", "time", "note")
SLOW_ENV = "PO_SLOW_AFTER"  # seconds; po serve sets it from po.toml [stamp] slow_after (default 300)
SLOW_DEFAULT = 300
CUES = {"pass": "\u2714 pass", "fail": "\u2718 fail", "skip": "\u2013 skip"}
WIDTHS = {"result": 9, "item": 8, "kind": 7, "agent": 10, "took": 10, "time": 20, "note": 4}  # ch; project and checks share the rest
FADE_SECONDS = 60  # a row that appears while the page is open starts 25% darker (lighter in dark) and eases back
# Text colours inside a highlighted row: darker (lighter in dark) than the normal ones, so they stay AA
# (4.5:1) on the strongest highlight; the tests check them against it.
NEW_TEXT = {"light": {"text": "#222222", "muted": "#333333", "pass": "#06471a", "fail": "#7a1610"},
            "dark": {"text": "#f2f2f2", "muted": "#e6e6e6", "pass": "#8ff0b0", "fail": "#ffc2bd"}}
PO_CMD = ("po", "events", "--all", "--json")
TEAM_CMD = ("po", "team", "--json")


def die(msg, code=1):
    sys.stderr.write("po serve: %s\n" % msg)
    sys.exit(code)


def unspecified(addr):
    """True when addr is a wildcard bind (0.0.0.0, ::, 0, empty, or a name that resolves to one)."""
    a = addr.strip("[]")
    if a in ("", "0"):
        return True
    try:
        return ipaddress.ip_address(a).is_unspecified
    except ValueError:
        pass
    try:
        infos = socket.getaddrinfo(a, None)
    except OSError:
        return False
    return any(ipaddress.ip_address(i[4][0].split("%")[0]).is_unspecified for i in infos)


def parse_events(text):
    text = text.strip()
    if not text:
        return []
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            data = [data]
    except ValueError:
        data = [json.loads(line) for line in text.splitlines() if line.strip()]
    return [e for e in data if isinstance(e, dict)]


def load_events(repo):
    """All events, newest first. Raises RuntimeError with a message the page can show."""
    try:
        p = subprocess.run(PO_CMD, cwd=repo, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError("cannot run po events: %s" % e)
    if p.returncode != 0:
        raise RuntimeError("po events exited %d: %s" % (p.returncode, p.stderr.strip()))
    try:
        events = parse_events(p.stdout)
    except ValueError as e:
        raise RuntimeError("po events --json is not JSON: %s" % e)
    # ISO UTC strings sort as text; the sort is stable, so equal times keep po's order.
    events.sort(key=lambda e: str(e.get("time", "")), reverse=True)
    return events


def load_team(repo):
    """The Team-view feed as po team --json prints it. Raises RuntimeError with a message for the client."""
    try:
        p = subprocess.run(TEAM_CMD, cwd=repo, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError("cannot run po team: %s" % e)
    if p.returncode != 0:
        raise RuntimeError("po team exited %d: %s" % (p.returncode, p.stderr.strip()))
    try:
        data = json.loads(p.stdout)
    except ValueError as e:
        raise RuntimeError("po team --json is not JSON: %s" % e)
    if not isinstance(data, list):
        raise RuntimeError("po team --json is not a JSON array")
    return data


def legs_text(legs):
    if not isinstance(legs, list):
        return ""
    return " ".join("%s:%s" % (l.get("name", "?"), l.get("result", "?")) if isinstance(l, dict) else str(l) for l in legs)


def note_text(event):
    """The note: the detail, then each failing leg's output tail and the log that holds the run's full output."""
    parts = [text(event.get("detail"))]
    legs = event.get("legs")
    for l in legs if isinstance(legs, list) else []:
        if isinstance(l, dict) and l.get("tail"):
            parts.append("leg %s, last lines:\n%s" % (l.get("name", "?"), text(l["tail"])))
    if event.get("log"):
        parts.append("full output: %s" % text(event["log"]))
    return "\n\n".join(p for p in parts if p)


def text(value):
    if isinstance(value, (list, dict)):
        value = json.dumps(value, separators=(",", ":"))
    return "" if value is None else str(value)


def slow_after():
    try:
        return int(os.environ.get(SLOW_ENV, SLOW_DEFAULT))
    except ValueError:
        return SLOW_DEFAULT


def seconds(e):
    """The run's whole seconds, or None (an older event: unknown, never 0)."""
    n = e.get("seconds")
    return n if isinstance(n, int) and not isinstance(n, bool) and n >= 0 else None


def took_text(n):
    """57s, 4m12s, 1h02m03s; - when unknown."""
    if n is None:
        return "-"
    if n >= 3600:
        return "%dh%02dm%02ds" % (n // 3600, n % 3600 // 60, n % 60)
    return "%dm%02ds" % (n // 60, n % 60) if n >= 60 else "%ds" % n


def field(e, col):
    """The text of one column of event e."""
    if col == "took":
        return took_text(seconds(e))
    if col == "result":
        r = text(e.get("result"))
        return CUES.get(r.lower(), "\u2013 %s" % (r or "?"))
    if col == "checks":
        return legs_text(e.get("legs"))
    if col == "note":
        return note_text(e)
    if col == "item" and e.get("item") is None:
        return "-"
    return text(e.get(col))


def rows_html(events):
    out = []
    for e in events:
        tds = []
        for col in COLUMNS:
            raw = field(e, col)
            v = html.escape(raw)
            t = html.escape(raw, quote=True)
            if col == "note":
                inner = (
                    '<span class="note" role="img" tabindex="0" title="%s" aria-label="%s">\u270e</span>' % (t, t) if raw else ""
                )
                tds.append('<td class="c-note">%s</td>' % inner)
                continue
            if col == "time":
                inner = '<time datetime="%s">%s</time>' % (t, v)
            elif col == "result":
                cls = text(e.get("result")).lower()
                cls = cls if cls in CUES else "skip"
                inner = '<span class="r-%s">%s</span>' % (cls, v)
            else:
                inner = v
            slow = " slow" if col == "took" and (seconds(e) or 0) > slow_after() else ""
            tds.append('<td class="c-%s%s" title="%s">%s</td>' % (col, slow, t, inner))
        out.append('<tr onclick="location=\'/all\'">%s</tr>' % "".join(tds))
    return "\n".join(out)


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>po events</title>
<style>
body{{font:14px system-ui,sans-serif;margin:1.5rem;color:#222;background:#fff}}
table{{border-collapse:collapse;width:100%;table-layout:fixed;min-width:44rem}}
th,td{{text-align:left;padding:.35rem .6rem;border-bottom:1px solid #ddd;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}}
tbody tr{{cursor:pointer}} tbody tr:hover{{background:#f3f3f3}}
.r-pass,.r-ok{{color:#0a7a2f;font-weight:600}} .r-fail{{color:#b3261e;font-weight:600}} .r-skip{{color:#555;font-weight:600}}
.c-kind,.c-checks,.c-agent,.c-took,.c-time{{color:#555}} .c-took.slow{{color:#8a5a00;font-weight:600}} .note{{color:#555;cursor:help}}
.note:focus-visible{{outline:2px solid currentColor;outline-offset:2px}}
tbody tr.new td{{background-color:rgba(0,0,0,.25);animation:fade {fade}s linear forwards;color:{lt[muted]}}}
tbody tr.new .c-item,tbody tr.new .c-project,tbody tr.new .c-note,tbody tr.new .note{{color:{lt[text]}}}
tbody tr.new .r-pass,tbody tr.new .r-ok{{color:{lt[pass]}}} tbody tr.new .r-fail{{color:{lt[fail]}}} tbody tr.new .r-skip{{color:{lt[muted]}}}
@keyframes fade{{from{{background-color:rgba(0,0,0,.25)}}to{{background-color:rgba(0,0,0,0)}}}}
@keyframes fade-dark{{from{{background-color:rgba(255,255,255,.25)}}to{{background-color:rgba(255,255,255,0)}}}}
@media(prefers-reduced-motion:reduce){{tbody tr.new td{{animation:none}}}}
.sr{{position:absolute;left:-9999px}}
#err{{color:#b3261e}} nav a{{margin-right:1rem}}
@media(prefers-color-scheme:dark){{body{{color:#ddd;background:#181818}}
th,td{{border-color:#444}} tbody tr:hover{{background:#262626}}
.r-pass,.r-ok{{color:#5fd38a}} .r-fail,#err{{color:#ff8a80}} .r-skip,.c-kind,.c-checks,.c-agent,.c-took,.c-time,.note{{color:#aaa}} .c-took.slow{{color:#f0c75e}}
tbody tr.new td{{background-color:rgba(255,255,255,.25);animation-name:fade-dark;color:{dk[muted]}}}
tbody tr.new .c-item,tbody tr.new .c-project,tbody tr.new .c-note,tbody tr.new .note{{color:{dk[text]}}}
tbody tr.new .r-pass,tbody tr.new .r-ok{{color:{dk[pass]}}} tbody tr.new .r-fail{{color:{dk[fail]}}} tbody tr.new .r-skip{{color:{dk[muted]}}}
@media(prefers-reduced-motion:reduce){{tbody tr.new td{{animation:none}}}}}}
</style></head>
<body data-limit="{limit}" data-slow="{slow}">
<h1>{title}</h1>
<nav><a href="/">last {last}</a><a href="/all">all</a><a href="/events.json">json</a></nav>
<p id="err">{err}</p>
<table><colgroup>{colgroup}</colgroup><thead><tr>{head}</tr></thead>
<tbody id="rows">
{rows}
</tbody></table>
<script>
const limit = +document.body.dataset.limit, slow = +document.body.dataset.slow;
const cols = {cols}, cues = {cues};
function legs(v) {{
  return Array.isArray(v) ? v.map(l => (l && typeof l === "object") ? (l.name ?? "?") + ":" + (l.result ?? "?") : String(l)).join(" ") : "";
}}
function str(v) {{
  if (v !== null && typeof v === "object") return JSON.stringify(v);
  return v == null ? "" : String(v);
}}
function took(e) {{
  const n = e.seconds;
  if (!Number.isInteger(n) || n < 0) return "-";
  const p = x => String(x).padStart(2, "0");
  return n >= 3600 ? Math.floor(n / 3600) + "h" + p(Math.floor(n % 3600 / 60)) + "m" + p(n % 60) + "s"
    : n >= 60 ? Math.floor(n / 60) + "m" + p(n % 60) + "s" : n + "s";
}}
function field(c, e) {{
  if (c === "took") return took(e);
  if (c === "result") {{ const r = str(e.result); return cues[r.toLowerCase()] || "\u2013 " + (r || "?"); }}
  if (c === "checks") return legs(e.legs);
  if (c === "note") {{
    const parts = [str(e.detail)];
    for (const l of Array.isArray(e.legs) ? e.legs : []) if (l && typeof l === "object" && l.tail) parts.push("leg " + (l.name ?? "?") + ", last lines:\\n" + str(l.tail));
    if (e.log) parts.push("full output: " + str(e.log));
    return parts.filter(p => p).join("\\n\\n");
  }}
  if (c === "item" && e.item == null) return "-";
  return str(e[c]);
}}
const fadeMs = {fade} * 1000;
let last = null, seen = null;
const born = new Map();  // event JSON -> Date.now() when it appeared while the page was open
function local() {{
  for (const t of document.querySelectorAll("time")) {{
    const d = new Date(t.getAttribute("datetime"));
    if (!isNaN(d)) t.textContent = d.toLocaleString();
  }}
}}
function render(events) {{
  const tb = document.getElementById("rows");
  tb.replaceChildren();
  for (const e of (limit ? events.slice(0, limit) : events)) {{
    const tr = document.createElement("tr");
    const age = Date.now() - (born.get(JSON.stringify(e)) ?? -Infinity);
    if (age < fadeMs) {{
      tr.className = "new";
      tr.style.animationDelay = "-" + age / 1000 + "s";
      setTimeout(() => tr.classList.remove("new"), fadeMs - age);
    }}
    tr.onclick = () => {{ location = "/all"; }};
    for (const c of cols) {{
      const td = document.createElement("td");
      const v = field(c, e);
      td.className = "c-" + c + (c === "took" && Number.isInteger(e.seconds) && e.seconds > slow ? " slow" : "");
      if (c === "note") {{
        if (v) {{
          const n = document.createElement("span");
          n.className = "note";
          n.setAttribute("role", "img");
          n.tabIndex = 0;
          n.title = v;
          n.setAttribute("aria-label", v);
          n.textContent = "\u270e";
          td.appendChild(n);
        }}
      }} else {{
        td.title = v;
        if (c === "time") {{
          const t = document.createElement("time");
          t.setAttribute("datetime", v);
          t.textContent = v;
          td.appendChild(t);
        }} else if (c === "result") {{
          const s = document.createElement("span");
          const r = str(e.result).toLowerCase();
          s.className = "r-" + (cues[r] ? r : "skip");
          s.textContent = v;
          td.appendChild(s);
        }} else td.textContent = v;
      }}
      tr.appendChild(td);
    }}
    tb.appendChild(tr);
  }}
  local();
}}
async function poll() {{
  const err = document.getElementById("err");
  try {{
    const r = await fetch("/events.json", {{cache: "no-store"}});
    const text = await r.text();
    if (!r.ok) throw new Error(text);
    err.textContent = "";
    if (text !== last) {{
      last = text;
      const events = JSON.parse(text), keys = events.map(e => JSON.stringify(e));
      if (seen) for (const k of keys) if (!seen.has(k)) born.set(k, Date.now());
      seen = new Set([...(seen || []), ...keys]);
      render(events);
    }}
  }} catch (x) {{ err.textContent = String(x.message || x); }}
}}
local();
setInterval(poll, 5000);
</script></body></html>
"""


def page(events, error, full):
    return PAGE.format(
        limit=0 if full else LAST,
        slow=slow_after(),
        last=LAST,
        title="All events" if full else "Last %d events" % LAST,
        err=html.escape(error or ""),
        colgroup="".join('<col style="width:%dch">' % WIDTHS[c] if c in WIDTHS else "<col>" for c in COLUMNS),
        head="".join(
            '<th class="c-%s">%s</th>' % (c, '<span class="sr">note</span>' if c == "note" else html.escape(c)) for c in COLUMNS
        ),
        rows=rows_html(events if full else events[:LAST]),
        cols=json.dumps(list(COLUMNS)),
        cues=json.dumps(CUES),
        fade=FADE_SECONDS,
        lt=NEW_TEXT["light"],
        dk=NEW_TEXT["dark"],
    )


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "po-serve"
    sys_version = ""

    def send(self, code, ctype, data, extra=()):
        body = data.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?", 1)[0].split("#", 1)[0]
        if path == "/team.json":
            try:
                return self.send(200, "application/json", json.dumps(load_team(self.server.repo)))
            except RuntimeError as e:
                return self.send(502, "application/json", json.dumps({"error": str(e)}))
        if path not in ("/", "/all", "/events.json"):
            return self.send(404, "text/plain; charset=utf-8", "not found\n")
        try:
            events, error = load_events(self.server.repo), None
        except RuntimeError as e:
            events, error = [], str(e)
        if path == "/events.json":
            if error:
                return self.send(502, "application/json", json.dumps({"error": error}))
            return self.send(200, "application/json", json.dumps(events))
        self.send(200, "text/html; charset=utf-8", page(events, error, path == "/all"))

    def refuse(self):
        self.send(405, "text/plain; charset=utf-8", "read-only: GET only\n", [("Allow", "GET")])

    do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = refuse

    def log_message(self, fmt, *args):
        sys.stderr.write("po serve: %s %s\n" % (self.address_string(), fmt % args))


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, repo):
        self.address_family = socket.AF_INET6 if ":" in addr[0] else socket.AF_INET
        self.repo = repo
        super().__init__(addr, Handler)


def main():
    ap = argparse.ArgumentParser(prog="po serve", add_help=False)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--repo", required=True)
    try:
        a = ap.parse_args()
    except SystemExit:
        die("usage: po serve [--bind <addr>] [--port <n>]")
    if unspecified(a.bind):
        die("refusing to bind %r: a wildcard address would expose the events on every interface; "
            "name one address (default 127.0.0.1)" % a.bind)
    if not 0 <= a.port <= 65535:
        die("--port must be 0..65535")
    try:
        srv = Server((a.bind.strip("[]"), a.port), a.repo)
    except OSError as e:
        die("cannot listen on %s:%d: %s" % (a.bind, a.port, e), 2)
    host, port = srv.server_address[:2]
    print("po serve: listening on http://%s/" % (("[%s]:%d" if ":" in host else "%s:%d") % (host, port)), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
