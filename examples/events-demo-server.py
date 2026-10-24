#!/usr/bin/env python3
"""A sample events feed for trying po-dashboard's new-event highlight.

    python3 examples/events-demo-server.py [--port 8798] [--every 15]

Serves /events.json with a few made-up events and adds a new one every --every
seconds, so a po-dashboard (or the page of a po serve pointed at the same data)
open on it shows a card appear and fade. Stop it with Ctrl-C.
"""
import argparse
import datetime
import http.server
import json

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=8798)
ap.add_argument("--every", type=float, default=15, help="seconds between new events")
a = ap.parse_args()

start = datetime.datetime.now(datetime.timezone.utc)
stamp = lambda d: d.strftime("%Y-%m-%dT%H:%M:%SZ")


def event(i, when):
    ok = i % 3 != 2
    return {"time": stamp(when), "kind": "stamp", "item": "1.%d" % i, "project": "demo",
            "result": "pass" if ok else "fail", "agent": "ada",
            "legs": [{"name": "lint", "result": "pass"}, {"name": "test", "result": "pass" if ok else "fail"}],
            "detail": "" if ok else "a sample failure"}


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        n = 5 + int((now - start).total_seconds() // a.every)
        body = json.dumps([event(i, start - datetime.timedelta(minutes=5 - i)) if i < 5 else
                           event(i, start + datetime.timedelta(seconds=(i - 5 + 1) * a.every)) for i in range(n)]).encode()
        self.send_response(200 if self.path.startswith("/events.json") else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


print("serving http://127.0.0.1:%d/events.json (a new event every %gs)" % (a.port, a.every), flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", a.port), H).serve_forever()
