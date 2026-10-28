#!/usr/bin/env python3
"""A sample events feed for trying po-dashboard's new-event highlight.

    python3 examples/events-demo-server.py [--port 8798] [--every 15]

Serves /events.json with some made-up events (open, stamp and close events over
the past days, enough for every Reports chart) and adds a new one every --every
seconds, so a po-dashboard (or the page of a po serve pointed at the same data)
open on it shows a card appear and fade. It also serves /decisions.json, the
sample examples/decisions-feed.json, and /projects.json, the sample
examples/projects-feed.json with each last_event moved to now (active, idle and
inactive lights), for --decisions-url and --projects-url. POST /answers prints
the body to stdout, answers 201 the first time it sees an answer_id, 200 for a
repeat of the same answer_id, 404 for a missing id, 401 without a bearer token,
for --answer-url. Stop with Ctrl-C.
"""
import argparse
import datetime
import http.server
import json
import os

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
            "legs": [{"name": "lint", "result": "pass", "seconds": 2}, {"name": "test", "result": "pass" if ok else "fail", "seconds": 40 + 90 * i}],
            "seconds": 42 + 90 * i, "detail": "" if ok else "a sample failure"}


def history():
    """Open, stamp and close events over the past days, so every report chart has something to show."""
    out = []
    for n, (agent, project, hours) in enumerate([("ada", "demo", 3), ("ada", "demo", 7), ("ada", "demo", 26), ("bob", "demo", 5),
                                                  ("bob", "other", 40), ("bob", "other", 9), ("cy", "other", 14)]):
        closed_at = start - datetime.timedelta(hours=2 + 11 * n)
        item = "0.%d" % n
        out.append({"time": stamp(closed_at - datetime.timedelta(hours=hours)), "kind": "open", "item": item, "project": project,
                    "result": "pass", "agent": "pat", "legs": [], "detail": ""})
        for k, leg in enumerate(["lint", "test", "docs", "build", "types", "audit", "smoke"][: 1 + n % 4]):
            out.append({"time": stamp(closed_at - datetime.timedelta(minutes=30 + 20 * k)), "kind": "stamp", "item": item, "project": project,
                        "result": "fail", "agent": agent, "legs": [{"name": leg, "result": "fail", "seconds": 31}], "seconds": 31, "detail": "a sample failure"})
        out.append({"time": stamp(closed_at - datetime.timedelta(minutes=10)), "kind": "stamp", "item": item, "project": project,
                    "result": "pass", "agent": agent, "legs": [{"name": "lint", "result": "pass", "seconds": 3}, {"name": "test", "result": "pass", "seconds": 330}], "seconds": 333, "detail": ""})
        out.append({"time": stamp(closed_at), "kind": "close", "item": item, "project": project,
                    "result": "pass", "agent": "pat", "legs": [], "detail": ""})
    return out


def projects():
    """examples/projects-feed.json with the last_event of each project moved to now minus 5 minutes, 3 hours, 3 days."""
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "projects-feed.json")) as f:
        feed = json.load(f)
    for pr, age in zip(feed, (datetime.timedelta(minutes=5), datetime.timedelta(hours=3), datetime.timedelta(days=3))):
        pr["last_event"] = stamp(datetime.datetime.now(datetime.timezone.utc) - age)
    return feed


class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/decisions.json"):
            with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "decisions-feed.json"), "rb") as f:
                body = f.read()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.startswith("/projects.json"):
            body = json.dumps(projects()).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        now = datetime.datetime.now(datetime.timezone.utc)
        n = 5 + int((now - start).total_seconds() // a.every)
        body = json.dumps(history() + [event(i, start - datetime.timedelta(minutes=5 - i)) if i < 5 else
                           event(i, start + datetime.timedelta(seconds=(i - 5 + 1) * a.every)) for i in range(n)]).encode()
        self.send_response(200 if self.path.startswith("/events.json") else 404)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        """POST /answers: print the body, answer 201 the first time per answer_id,
        200 for a repeat of the same answer_id, 404 for a missing id, 401 without
        a bearer token."""
        if self.path.startswith("/answers"):
            length = int(self.headers.get("Content-Length", 0))
            raw = self.rfile.read(length) if length else b"{}"
            if not self.headers.get("Authorization"):
                self.send_response(401)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            try:
                data = json.loads(raw)
            except ValueError:
                print("answer: %s" % raw.decode("utf-8", "replace"), flush=True)
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            print("answer:", json.dumps(data), flush=True)
            if not data.get("id"):
                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            ans_id = data.get("answer_id")
            if ans_id in self.server.answers:
                self.send_response(200)
            else:
                self.server.answers.add(ans_id)
                self.send_response(201)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(404)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), H)
srv.answers = set()
print("serving http://127.0.0.1:%d/events.json (a new event every %gs), /decisions.json, /projects.json and POST /answers" % (srv.server_address[1], a.every), flush=True)
srv.serve_forever()
