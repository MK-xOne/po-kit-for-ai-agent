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
import socket
import subprocess
import sys

LAST = 10
COLUMNS = ("item", "project", "kind", "result", "agent", "time")
EXTRA = ("legs", "detail")  # /all only
PO_CMD = ("po", "events", "--all", "--json")


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


def cell(value, col=""):
    if col == "legs" and isinstance(value, list):
        return " ".join(
            "%s:%s" % (l.get("name", "?"), l.get("result", "?")) if isinstance(l, dict) else str(l) for l in value
        )
    if col == "item" and value is None:
        return "-"
    if isinstance(value, (list, dict)):
        value = json.dumps(value, separators=(",", ":"))
    return "" if value is None else str(value)


def rows_html(events, with_legs):
    out = []
    for e in events:
        tds = []
        for col in COLUMNS:
            v = html.escape(cell(e.get(col), col))
            if col == "time":
                v = '<time datetime="%s">%s</time>' % (v, v)
            elif col == "result":
                v = '<span class="r-%s">%s</span>' % (html.escape(cell(e.get(col), col).lower(), quote=True), v)
            tds.append("<td>%s</td>" % v)
        if with_legs:
            for col in EXTRA:
                tds.append("<td>%s</td>" % html.escape(cell(e.get(col), col)))
        out.append('<tr onclick="location=\'/all\'">%s</tr>' % "".join(tds))
    return "\n".join(out)


PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>po events</title>
<style>
body{{font:14px system-ui,sans-serif;margin:1.5rem;color:#222;background:#fff}}
table{{border-collapse:collapse;width:100%}}
th,td{{text-align:left;padding:.35rem .6rem;border-bottom:1px solid #ddd;white-space:nowrap}}
tbody tr{{cursor:pointer}} tbody tr:hover{{background:#f3f3f3}}
.r-pass,.r-ok{{color:#0a7a2f}} .r-fail{{color:#b3261e;font-weight:600}}
#err{{color:#b3261e}} nav a{{margin-right:1rem}}
@media(prefers-color-scheme:dark){{body{{color:#ddd;background:#181818}}
th,td{{border-color:#444}} tbody tr:hover{{background:#262626}}
.r-pass,.r-ok{{color:#5fd38a}} .r-fail,#err{{color:#ff8a80}}}}
</style></head>
<body data-limit="{limit}" data-legs="{legs}">
<h1>{title}</h1>
<nav><a href="/">last {last}</a><a href="/all">all</a><a href="/events.json">json</a></nav>
<p id="err">{err}</p>
<table><thead><tr>{head}</tr></thead>
<tbody id="rows">
{rows}
</tbody></table>
<script>
const body = document.body, limit = +body.dataset.limit, legs = body.dataset.legs === "1";
const cols = {cols}, extra = {extra};
function fmt(c, v) {{
  if (c === "legs" && Array.isArray(v))
    return v.map(l => (l && typeof l === "object") ? (l.name ?? "?") + ":" + (l.result ?? "?") : String(l)).join(" ");
  if (c === "item" && v == null) return "-";
  if (v !== null && typeof v === "object") return JSON.stringify(v);
  return v == null ? "" : String(v);
}}
let last = null;
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
    tr.onclick = () => {{ location = "/all"; }};
    for (const c of cols.concat(legs ? extra : [])) {{
      const td = document.createElement("td");
      const v = fmt(c, e[c]);
      if (c === "time") {{
        const t = document.createElement("time");
        t.setAttribute("datetime", v);
        t.textContent = v;
        td.appendChild(t);
      }} else if (c === "result") {{
        const s = document.createElement("span");
        s.className = "r-" + v.toLowerCase().replace(/[^a-z0-9_-]/g, "");
        s.textContent = v;
        td.appendChild(s);
      }} else td.textContent = v;
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
    if (text !== last) {{ last = text; render(JSON.parse(text)); }}
  }} catch (x) {{ err.textContent = String(x.message || x); }}
}}
local();
setInterval(poll, 5000);
</script></body></html>
"""


def page(events, error, full):
    cols = list(COLUMNS) + (list(EXTRA) if full else [])
    return PAGE.format(
        limit=0 if full else LAST,
        legs=1 if full else 0,
        last=LAST,
        title="All events" if full else "Last %d events" % LAST,
        err=html.escape(error or ""),
        head="".join("<th>%s</th>" % html.escape(c) for c in cols),
        rows=rows_html(events if full else events[:LAST], full),
        cols=json.dumps(list(COLUMNS)),
        extra=json.dumps(list(EXTRA)),
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
