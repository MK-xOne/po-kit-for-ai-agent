"""po-kit: the logic of po-dashboard, with no display and no GTK.

Fetching, parsing, sorting, limiting, formatting and the neumorphic CSS live
here so tests can run them anywhere; bin/po-dashboard only draws the window.
Standard library only.
"""
import datetime
import http.client
import json
import math
import os
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid

LAST = 10
INTERVAL_MS = 5000
# The Reports pane: time ranges (label, seconds), the default one, and the chart areas
# (placeholders until the charts exist) shown when the range holds events.
REPORT_RANGES = (("24 h", 86400), ("7 d", 7 * 86400), ("30 d", 30 * 86400))
REPORT_DEFAULT = 1
REPORT_CHARTS = ("Gate runs per agent", "First-try pass rate per agent", "Items closed per day, by project",
                 "Item cycle time per agent", "Failed legs by kind over time")
REPORT_EMPTY = "no events in this range"
URL_ENV = "PO_DASHBOARD_URL"
TEAM_URL_ENV = "PO_DASHBOARD_TEAM_URL"
DECISIONS_URL_ENV = "PO_DASHBOARD_DECISIONS_URL"
PROJECTS_URL_ENV = "PO_DASHBOARD_PROJECTS_URL"
DECISIONS_FILTER_ENV = "PO_DASHBOARD_DECISIONS_FILTER"  # the saved Actions filter's file, instead of the default under the config dir
ANSWER_URL_ENV = "PO_DASHBOARD_ANSWER_URL"  # where to POST answers (v0.49); none = read-only Decisions
ANSWER_TOKEN_ENV = "PO_DASHBOARD_ANSWER_TOKEN"  # bearer token for the answer POST (v0.49), env only
INSTALL_DIR_ENV = "PO_DASHBOARD_INSTALL_DIR"  # where the builds named by `requires` sit on the viewer's machine (v0.69)
CLIENT = "po-dashboard"
TEAM_ORDER_ENV = "PO_DASHBOARD_TEAM_ORDER"  # the saved order's file, instead of the default under the config dir
FADE_SECONDS = 60
FADE_STEPS = 60  # one CSS class per step, po-fade-<n>: n steps of highlight left
FADE_AMOUNT = 0.25  # a new card starts 25% darker (lighter in the dark theme)
CUES = {"pass": "✔ pass", "fail": "✘ fail", "skip": "– skip"}  # check, cross, en dash
PROJECT_ACTIVE_MINUTES = 30  # the Projects light: active up to this age of the last event
PROJECT_IDLE_HOURS = 24  # idle up to this age, inactive beyond (and for no, unreadable or future time)
PROJECT_SKEW_MINUTES = 1  # a last_event this far ahead of the clock is still taken as now


class DashboardError(Exception):
    """A problem to show the user as one line."""


# ---- the URL and the fetch -------------------------------------------------


def resolve_url(arg, env=None):
    """--url wins over the environment; neither is an error (no default address)."""
    env = os.environ if env is None else env
    url = (arg or env.get(URL_ENV) or "").strip()
    if not url:
        raise DashboardError("no URL: pass --url <url> or set %s (for example the /events.json of a po serve)" % URL_ENV)
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise DashboardError("not an http(s) URL: %s" % url)
    return url


def resolve_team_url(arg, env=None):
    """--team-url wins over the environment; neither is None (no team feed, no default address).

    Besides http(s), a feed may be a file (file:// or a plain path), for a sample or a snapshot.
    """
    return resolve_feed_url(arg, TEAM_URL_ENV, env)


def resolve_decisions_url(arg, env=None):
    """--decisions-url wins over the environment; neither is None (no Decisions view, no default address)."""
    return resolve_feed_url(arg, DECISIONS_URL_ENV, env)


def resolve_projects_url(arg, env=None):
    """--projects-url wins over the environment; neither is None (no Projects feed, no default address)."""
    return resolve_feed_url(arg, PROJECTS_URL_ENV, env)


def resolve_feed_url(arg, env_name, env=None):
    """An optional feed: http(s), file:// or a plain path to a file; none is None."""
    env = os.environ if env is None else env
    url = (arg or env.get(env_name) or "").strip()
    if not url:
        return None
    parts = urllib.parse.urlsplit(url)
    if parts.scheme in ("http", "https") and parts.netloc:
        return url
    if parts.scheme == "file" and parts.path:
        return url
    if not parts.scheme and os.path.isfile(url):
        return "file://" + urllib.parse.quote(os.path.abspath(url))
    raise DashboardError("not an http(s) URL or a file: %s" % url)


def fetch(url, timeout=5):
    """The body of url as text. Raises DashboardError with a one-line reason."""
    try:
        with urllib.request.urlopen(url, timeout=timeout) as r:  # noqa: S310 (scheme checked in resolve_url)
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        raise DashboardError("%s answered %d %s" % (url, e.code, e.reason))
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise DashboardError("cannot reach %s: %s" % (url, getattr(e, "reason", e)))


# ---- answering decisions (v0.49) --------------------------------------------


def resolve_answer_url(arg, env=None):
    """--answer-url wins over the environment; neither is None (read-only mode, no default). http(s) only."""
    env = os.environ if env is None else env
    url = (arg or env.get(ANSWER_URL_ENV) or "").strip()
    if not url:
        return None
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https") or not parts.netloc:
        raise DashboardError("not an http(s) URL: %s" % url)
    return url


def resolve_install_dir(arg, env=None):
    """--install-dir wins over the environment; neither is None (no Install command, no default guess).

    The directory must be an absolute path that a shell reads as written: no `<`, `>`, quote or whitespace.
    """
    env = os.environ if env is None else env
    path = (arg or env.get(INSTALL_DIR_ENV) or "").strip()
    if not path:
        return None
    if not _install_dir_ok(path):
        raise DashboardError("install_dir is not an absolute plain path: %s" % path)
    return path.rstrip("/") or "/"


def answer_id():
    """A lowercase dashed uuid4 (8-4-4-4-12 hex) for a new answer (made once per Send, kept with the draft)."""
    return str(uuid.uuid4())


def answer_body(entry, answer_id, option=None, text=None, result=None, step=None, note=None):
    """The POST body for answering a decision entry.

    One JSON object per answer, flat, null for fields the kind does not use:
    {answer_id, id, project, item, kind, option, text, result, step, note,
     answered_at, client}. answer_id is made once per Send and kept with the
     draft, so Retry re-posts the same body.
    """
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return {
        "answer_id": answer_id,
        "id": str(entry.get("id") or ""),
        "project": str(entry.get("project") or ""),
        "item": str(entry.get("item") or ""),
        "kind": decision_shape(entry),
        "option": option,
        "text": text,
        "result": result,
        "step": step,
        "note": note,
        "answered_at": now,
        "client": CLIENT,
    }


# Mirrors the receiver's MAX_TEXT: characters of the stripped text per answer field.
ANSWER_MAX_TEXT = 2000


def answer_counter(text):
    """The counter under an answer box: ("12 / 2000", over_limit), counting the stripped text."""
    n = len((text or "").strip())
    return ("%d / %d" % (n, ANSWER_MAX_TEXT), n > ANSWER_MAX_TEXT)


def answer_ready(kind, picks):
    """Whether the draft in picks may be sent: the rule Send's sensitivity follows.

    choice: an option, or a write-in alone; action: Pass, or Failed with a step;
    unformatted: non-empty text. Text, note or write-in over ANSWER_MAX_TEXT is never ready
    (the box is not truncated, so nothing typed is lost).
    """
    for field in ("note", "text"):
        if len((picks.get(field) or "").strip()) > ANSWER_MAX_TEXT:
            return False
    if kind == "choice":
        return picks.get("choice") is not None or bool((picks.get("note") or "").strip())
    if kind == "action":
        return picks.get("result") == "Pass" or (picks.get("result") == "Failed" and picks.get("step") is not None)
    return bool((picks.get("text") or "").strip())


def answer_params(kind, picks):
    """The answer_body keyword fields for a draft: lowercase result, step only for failed, text trimmed, empty text null.

    The draft keeps the box's text as typed (spaces and all, so a rebuilt box shows it unchanged);
    the trim happens here, on the way out.
    """
    note = (picks.get("note") or "").strip() or None
    if kind == "choice":
        return {"option": picks.get("choice"), "text": note}
    if kind == "action":
        failed = picks.get("result") == "Failed"
        return {"result": "failed" if failed else "pass", "step": picks.get("step") if failed else None, "note": note}
    return {"text": (picks.get("text") or "").strip()}


def answer_state(status_code, reason="", host=None):
    """The display string for an answer POST response code.

    200/201 -> 'answered \\u00b7 sent' (muted, controls disabled); 409 -> 'already answered'
    (controls disabled); 404 -> 'no longer waiting'; 401/403 -> 'refused by <host>: <code>'
    with a Retry button; anything else or no connection -> 'not sent: <reason>' with Retry.
    """
    if status_code in (200, 201):
        return "answered \u00b7 sent"
    if status_code == 409:
        return "already answered"
    if status_code == 404:
        return "no longer waiting"
    if status_code in (401, 403):
        return "refused by %s: %d" % (host or "?", status_code)
    if reason:
        return "not sent: " + str(reason)
    return "not sent"


def answer_needs_retry(state):
    """Whether an answer display string has a Retry button (refused or not sent)."""
    return state.startswith("refused by") or state.startswith("not sent")


def answer_state_class(state):
    """The CSS class for an answer display string."""
    if state == "answered \u00b7 sent":
        return "po-answered"
    if state == "already answered":
        return "po-already"
    return "po-fail"


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


# The receiver reads the ask back from the relay and posts the ruling before it answers: two
# round trips, so a slow relay needs more than a few seconds (the POST runs in a worker thread).
ANSWER_TIMEOUT = 20


def post_answer(url, body, token=None):
    """POST the answer body as JSON to url. Returns the answer display string."""
    data = json.dumps(body).encode("utf-8")
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    host = urllib.parse.urlsplit(url).netloc
    try:
        # no redirect handler: the bearer token is never forwarded, a redirect is an HTTPError (a failure)
        with urllib.request.build_opener(_NoRedirect).open(req, timeout=ANSWER_TIMEOUT) as r:
            return answer_state(r.status, host=host)
    except urllib.error.HTTPError as e:
        return answer_state(e.code, e.reason, host=host)
    except (urllib.error.URLError, http.client.HTTPException, OSError, ValueError) as e:
        return answer_state(0, str(getattr(e, "reason", e)))


# ---- parse, sort, limit ----------------------------------------------------


def parse_events(text):
    """A JSON array, or one JSON object per line. Raises DashboardError."""
    text = text.strip()
    if not text:
        return []
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            data = [data]
    except ValueError:
        try:
            data = [json.loads(line) for line in text.splitlines() if line.strip()]
        except ValueError as e:
            raise DashboardError("not JSON: %s" % e)
    if not isinstance(data, list):
        raise DashboardError("expected a list of events")
    return [e for e in data if isinstance(e, dict)]


def sort_events(events):
    """Newest first; the sort is stable, so equal times keep the source order."""
    return sorted(events, key=lambda e: str(e.get("time") or ""), reverse=True)


def visible(events, show_all):
    events = sort_events(events)
    return events if show_all else events[:LAST]


def in_range(events, seconds, now=None):
    """The events whose time falls within the last `seconds` before now (default: the present); unreadable times are left out."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    lo = now - datetime.timedelta(seconds=seconds)
    out = []
    for e in events:
        t = parse_time(e.get("time"))
        if t is not None and lo <= t <= now:
            out.append(e)
    return out


# ---- formatting ------------------------------------------------------------


def local_time(iso, tz=None):
    """An ISO UTC time as 'YYYY-MM-DD HH:MM:SS' in tz (default: the local zone); unparseable text is kept."""
    try:
        d = datetime.datetime.fromisoformat(str(iso).replace("Z", "+00:00"))
    except ValueError:
        return str(iso or "")
    if d.tzinfo is None:
        d = d.replace(tzinfo=datetime.timezone.utc)
    return d.astimezone(tz).strftime("%Y-%m-%d %H:%M:%S")


SLOW_ENV = "PO_SLOW_AFTER"  # seconds; a run over it is marked slow (po.toml [stamp] slow_after, default 300)
SLOW_DEFAULT = 300


def slow_after():
    raw = os.environ.get(SLOW_ENV, "")
    return int(raw) if raw.isascii() and raw.isdigit() else SLOW_DEFAULT  # digits only, as the manifest schema


def event_seconds(event):
    """The run's whole seconds, or None when the event has none (an older one: unknown, never 0)."""
    n = event.get("seconds")
    return n if isinstance(n, int) and not isinstance(n, bool) and n >= 0 else None


def took_text(n):
    """57s, 4m12s, 1h02m03s; - when unknown."""
    if n is None:
        return "-"
    if n >= 3600:
        return "%dh%02dm%02ds" % (n // 3600, n % 3600 // 60, n % 60)
    return "%dm%02ds" % (n // 60, n % 60) if n >= 60 else "%ds" % n


def legs_text(legs):
    if not isinstance(legs, list):
        return ""
    return " ".join(
        "%s:%s" % (l.get("name", "?"), l.get("result", "?")) if isinstance(l, dict) else str(l) for l in legs
    )


def note_text(event):
    """The note: the detail, then each failing leg's output tail and the log that holds the run's full output."""
    parts = [str(event.get("detail") or "")]
    legs = event.get("legs")
    for l in legs if isinstance(legs, list) else []:
        if isinstance(l, dict) and l.get("tail"):
            parts.append("leg %s, last lines:\n%s" % (l.get("name", "?"), l["tail"]))
    if event.get("log"):
        parts.append("full output: %s" % event["log"])
    return "\n\n".join(p for p in parts if p)


def result_class(result):
    r = str(result or "").lower()
    return r if r in CUES else "skip"


# The columns of a card, left to right: (row key, title, width in characters,
# widest before ellipsizing, grows with the window). Every card uses the same
# widths, so the fields line up; the note slot follows the last column.
COLUMNS = (
    ("result", "result", 7, 7, False),
    ("item", "item", 6, 6, False),
    ("project", "project", 6, 28, True),
    ("kind", "kind", 5, 5, False),
    ("legs", "checks", 10, 44, True),
    ("agent", "agent", 7, 7, False),
    ("took", "took", 7, 7, False),
    ("time", "time", 17, 17, False),
)
NOTE_ICONS = ("document-edit-symbolic", "text-x-generic-symbolic", "dialog-information-symbolic")
NOTE_FALLBACK = "\u270e"  # pencil, used when the icon theme has none of NOTE_ICONS


def row(event, tz=None):
    """One event as the strings a card shows. The result always carries a symbol and a word."""
    result = str(event.get("result") or "")
    cls = result_class(result)
    item = event.get("item")
    return {
        "item": "-" if item is None else str(item),
        "project": str(event.get("project") or ""),
        "kind": str(event.get("kind") or ""),
        "result": CUES[cls] if result.lower() in CUES else "– %s" % (result or "?"),
        "result_class": cls,
        "agent": str(event.get("agent") or ""),
        "took": took_text(event_seconds(event)),
        "slow": event_seconds(event) is not None and event_seconds(event) > slow_after(),
        "time": local_time(event.get("time"), tz),
        "legs": legs_text(event.get("legs")),
        "detail": note_text(event),
    }


def rows(events, show_all, tz=None, sort=None):
    return [row(e, tz) for e in sorted_events(visible(events, show_all), sort, tz)]


# ---- sortable columns ----------------------------------------------------------
# A sort is None (the default order) or (column key, descending). Clicking a header
# cycles that column ascending, descending, then back to None.


def natural_key(text):
    """Case-insensitive, with digit runs compared as numbers ('1.9' before '1.11')."""
    parts = re.split(r"(\d+)", str(text).lower())
    return tuple((0, int(p), "") if p.isdigit() else (1, 0, p) for p in parts if p != "")


def next_sort(current, key):
    """The sort after a click on column key: ascending, then descending, then none."""
    if current is None or current[0] != key:
        return (key, False)
    return (key, True) if not current[1] else None


def sort_mark(sort, key):
    """The arrow the header of column key shows: up ascending, down descending, '' when not the sorted column."""
    if sort is None or sort[0] != key:
        return ""
    return "\u25bc" if sort[1] else "\u25b2"


def sorted_events(events, sort, tz=None):
    """events ordered by the sort (stable); time by instant, not text; None keeps the order given."""
    if sort is None:
        return list(events)
    key, desc = sort
    if key == "time":
        def value(e):
            t = parse_time(e.get("time"))
            return (1, t.timestamp(), ()) if t else (0, 0.0, natural_key(e.get("time") or ""))
    elif key == "took":
        def value(e):
            n = event_seconds(e)
            return (0, 0) if n is None else (1, n)
    else:
        def value(e):
            return natural_key(row(e, tz)[key])
    return sorted(events, key=value, reverse=desc)


def check_lines(events, show_all=False, tz=None):
    """What the window would show, one ' | ' line per event (po-dashboard --check)."""
    return [" | ".join((r["item"], r["project"], r["kind"], r["result"], r["agent"], r["time"])) for r in rows(events, show_all, tz)]


# ---- the team view ---------------------------------------------------------


def parse_team(text):
    """The team feed: a JSON array of {agent, model?, state, now, owns[], free, limit_until?, usage?}. Raises DashboardError."""
    text = text.strip()
    if not text:
        return []
    try:
        data = json.loads(text)
    except ValueError as e:
        raise DashboardError("not JSON: %s" % e)
    if not isinstance(data, list):
        raise DashboardError("expected a list of agents")
    return [e for e in data if isinstance(e, dict)]


def _usage_part(value):
    """A 0-1 fraction as '37%', or None when it is not a number in that range."""
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 1:
        return None
    return "%d%%" % round(value * 100)


def team_usage(entry):
    """'5h 37% \u00b7 7d 12%' from usage {five_hour, seven_day}; only the parts present, '' when none."""
    usage = entry.get("usage")
    if not isinstance(usage, dict):
        return ""
    parts = [(label, _usage_part(usage.get(key))) for label, key in (("5h", "five_hour"), ("7d", "seven_day"))]
    return " \u00b7 ".join("%s %s" % (label, text) for label, text in parts if text)


def limit_text(entry, now=None, tz=None):
    """'LIMIT until <local time>' while limit_until is a time still ahead; '' otherwise.

    The time is in tz (default: the viewer's zone), with the date when it is not today."""
    until = parse_time(entry.get("limit_until"))
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if until is None or until <= now:
        return ""
    until, today = until.astimezone(tz), now.astimezone(tz).date()
    return "LIMIT until " + until.strftime("%H:%M" if until.date() == today else "%Y-%m-%d %H:%M")


def team_row(entry, now=None, tz=None):
    """One agent as the strings a team line shows.

    status is one of LIMIT until <time> (kind 'limit', wins over the rest), WORKING... (kind 'working'),
    FREE (kind 'free', the free flag), else the state as given (kind 'idle')."""
    state = str(entry.get("state") or "")
    owns = entry.get("owns")
    owns = [str(o) for o in owns] if isinstance(owns, list) else []
    now_item = entry.get("now")
    model = entry.get("model")
    working = state.strip().upper().startswith("WORKING")
    limit = limit_text(entry, now, tz)
    if limit:
        kind, status = "limit", limit
    elif working:
        kind, status = "working", state
    elif entry.get("free"):
        kind, status = "free", "FREE"
    else:
        kind, status = "idle", state or "?"
    return {
        "agent": str(entry.get("agent") or "?"),
        "model": model.strip() if isinstance(model, str) else "",
        "status": status,
        "kind": kind,
        "usage": team_usage(entry),
        "now": "" if now_item in (None, "") else str(now_item),
        "owns": ", ".join(owns),
    }


def team_rows(entries, now=None, tz=None):
    return [team_row(e, now, tz) for e in entries]


TEAM_COLUMNS = ("agent", "model", "status", "now", "owns")


def sorted_team(entries, sort, now=None, tz=None):
    """Team entries ordered by the sort (stable); None keeps the order given (the viewer's saved order)."""
    if sort is None:
        return list(entries)
    key, desc = sort
    return sorted(entries, key=lambda e: natural_key(team_row(e, now, tz)[key]), reverse=desc)


def team_check_lines(entries, now=None, tz=None):
    """What the Team view would show, one ' | ' line per agent; a model follows the name after ' · '."""
    return [
        " | ".join(
            (r["agent"] + (" \u00b7 " + r["model"] if r["model"] else ""), r["status"] + (" (" + r["usage"] + ")" if r["usage"] else ""), "now: " + (r["now"] or "-"), "owns: " + (r["owns"] or "-"))
        )
        for r in team_rows(entries, now, tz)
    ]


# ---- the decisions view ----------------------------------------------------


def parse_decisions(text):
    """The decisions feed: a JSON array of {project, item, title, waiting_for, asked_at, thread_url?, kind?, id?, ...}. Raises DashboardError."""
    text = text.strip()
    if not text:
        return []
    try:
        data = json.loads(text)
    except ValueError as e:
        raise DashboardError("not JSON: %s" % e)
    if not isinstance(data, list):
        raise DashboardError("expected a list of decisions")
    return [e for e in data if isinstance(e, dict)]


_PROJECT_STATUSES_DOING = {"DOING", "PAUSED", "BLOCKED"}


def parse_projects(text):
    """The projects feed: a JSON array of {project, last_event?, items: [{item, title?, status, agents: []}]}. Tolerant."""
    text = (text or "").strip()
    if not text:
        return []
    try:
        data = json.loads(text)
    except ValueError as e:
        raise DashboardError("not JSON: %s" % e)
    if not isinstance(data, list):
        raise DashboardError("expected a list of projects")
    out = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        items = entry.get("items")
        if not isinstance(items, list):
            items = []
        norm_items = []
        for it in items:
            if not isinstance(it, dict):
                continue
            agents = it.get("agents")
            if not isinstance(agents, list):
                agents = []
            agents = [str(a) for a in agents]
            title = it.get("title")
            if title is None:
                title = ""
            norm_items.append({
                "item": str(it.get("item") if it.get("item") is not None else ""),
                "title": str(title),
                "status": str(it.get("status") if it.get("status") is not None else ""),
                "agents": agents,
            })
        le = entry.get("last_event")
        if le is not None and not isinstance(le, str):
            le = str(le)
        out.append({
            "project": str(entry.get("project") if entry.get("project") is not None else ""),
            "last_event": le,
            "items": norm_items,
        })
    return out


def project_counts(items):
    """todo, doing, done counts from a list of project items."""
    todo = doing = done = 0
    for it in items or []:
        status = str((it or {}).get("status") or "").strip().upper()
        if status == "TODO":
            todo += 1
        elif status in _PROJECT_STATUSES_DOING:
            doing += 1
        elif status == "DONE":
            done += 1
    return {"todo": todo, "doing": doing, "done": done}


def project_light(last_event, now=None):
    """active/idle/inactive based on last_event age."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    dt = parse_time(last_event)
    if dt is None:
        return "inactive"
    if dt > now + datetime.timedelta(minutes=PROJECT_SKEW_MINUTES):
        return "inactive"
    age = max(0, (now - dt).total_seconds())
    if age <= PROJECT_ACTIVE_MINUTES * 60:
        return "active"
    if age <= PROJECT_IDLE_HOURS * 3600:
        return "idle"
    return "inactive"


def filter_items(items, f):
    """All/TODO/DOING/DONE filter keeping feed order."""
    items = list(items or [])
    key = str(f).strip().lower() if f is not None else "all"
    if key in ("", "all"):
        return items
    if key == "todo":
        return [it for it in items if str(it.get("status") or "").strip().upper() == "TODO"]
    if key == "doing":
        return [it for it in items if str(it.get("status") or "").strip().upper() in _PROJECT_STATUSES_DOING]
    if key == "done":
        return [it for it in items if str(it.get("status") or "").strip().upper() == "DONE"]
    return items


def project_check_lines(projects, now=None):
    """One line per project for --check: name | light | todo/doing/done."""
    out = []
    for pr in projects:
        c = project_counts(pr["items"])
        out.append("%s | %s | %d/%d/%d" % (pr["project"], project_light(pr["last_event"], now), c["todo"], c["doing"], c["done"]))
    return out


def project_card(pr, now=None):
    """What a Projects card shows: {name, light, counts, text}; text is the tooltip and accessible label, so the
    light is named in words as well as coloured."""
    light = project_light(pr.get("last_event"), now)
    counts = project_counts(pr.get("items"))
    name = str(pr.get("project", ""))
    text = "%s, %s, TODO %d, DOING %d, DONE %d" % (name, light, counts["todo"], counts["doing"], counts["done"])
    return {"name": name, "light": light, "counts": counts, "text": text}


def load_projects(url, last=None):
    """(projects, note) from the feed; a failed fetch keeps `last` and the note says so (note is "" when fine)."""
    try:
        return parse_projects(fetch(url)), ""
    except DashboardError as e:
        return last, "%s (showing the last projects data)" % e if last is not None else str(e)


def parse_time(iso):
    """An ISO time as an aware datetime (no zone = UTC), or None when it is not one."""
    if not isinstance(iso, str) or not iso.strip():
        return None
    try:
        d = datetime.datetime.fromisoformat(iso.strip().replace("Z", "+00:00"))
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=datetime.timezone.utc)


DECISION_KINDS = ("choice", "action")
DECISION_GROUP = {"choice": 0, "action": 1, "unformatted": 2, "legacy": 2}  # the order of the groups in the view
DECISION_BADGE = {"choice": "Choice", "action": "Action", "unformatted": "unformatted", "legacy": ""}


def _text(value):
    return isinstance(value, str) and bool(value.strip())


def _optional_text(value):
    return value is None or isinstance(value, str)


def decision_shape(entry):
    """'choice', 'action', 'unformatted' (a kind that is unknown or an entry missing its id or a field) or 'legacy' (no kind)."""
    if "kind" not in entry:
        return "legacy"
    kind = entry.get("kind")
    if kind not in DECISION_KINDS or not _text(entry.get("id")):
        return "unformatted"
    if kind == "choice":
        options = entry.get("options")
        if not _text(entry.get("question")) or not isinstance(options, list) or len(options) < 2:
            return "unformatted"
        for o in options:
            if not isinstance(o, dict) or not _text(o.get("label")) or not _optional_text(o.get("description")) \
                    or not isinstance(o.get("recommended", False), bool):
                return "unformatted"
        if sum(1 for o in options if o.get("recommended")) > 1:
            return "unformatted"
        return "choice"
    steps = entry.get("steps")
    if not _text(entry.get("machine")) or not _text(entry.get("done_when")) or not isinstance(steps, list) or not steps:
        return "unformatted"
    for st in steps:
        if not isinstance(st, dict) or not _text(st.get("text")) or not _optional_text(st.get("command")):
            return "unformatted"
    if "requires" in entry and requires_of(entry) is None:
        return "unformatted"
    return "action"


def sort_decisions(entries):
    """Choices, then Actions, then unformatted and legacy; inside a group oldest asked first (an entry without a
    readable asked_at last); the sort is stable."""
    far = datetime.datetime.max.replace(tzinfo=datetime.timezone.utc)
    return sorted(entries, key=lambda e: (DECISION_GROUP[decision_shape(e)], parse_time(e.get("asked_at")) or far))


def ago(then, now):
    """How long ago then was, as '5m ago', '3h ago', '2d ago'; under a minute (or ahead) is 'just now'."""
    secs = int((now - then).total_seconds())
    if secs < 60:
        return "just now"
    for size, unit in ((86400, "d"), (3600, "h"), (60, "m")):
        if secs >= size:
            return "%d%s ago" % (secs // size, unit)


def short_title(text, limit=80):
    """A title shortened to at most `limit` characters (default 80)."""
    s = str(text if text is not None else "")
    return s[:limit]


def decision_row(entry, now=None, tz=None):
    """One decision as the strings a line shows; asked is relative to now, asked_local the local time."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    asked = parse_time(entry.get("asked_at"))
    url = entry.get("thread_url")
    item = entry.get("item")
    asked_by = entry.get("asked_by")
    kind = decision_shape(entry)
    row = {
        "kind": kind,
        "id": str(entry.get("id") or "") if kind != "legacy" else "",
        "project": str(entry.get("project") or ""),
        "item": "-" if item in (None, "") else str(item),
        "title": short_title(entry.get("title"), 80),
        "waiting_for": str(entry.get("waiting_for") or "?"),
        "asked": ago(asked, now) if asked else str(entry.get("asked_at") or "?"),
        "asked_local": local_time(entry.get("asked_at"), tz) if asked else "",
        "thread_url": url.strip() if isinstance(url, str) else "",
        "asked_by": asked_by.strip() if isinstance(asked_by, str) else "",
    }
    if kind == "choice":
        row["question"] = entry["question"].strip()
        row["options"] = [{"label": o["label"].strip(), "description": (o.get("description") or "").strip(),
                           "recommended": bool(o.get("recommended"))} for o in entry["options"]]
    elif kind == "action":
        row["machine"] = entry["machine"].strip()
        row["steps"] = [{"n": i + 1, "text": st["text"].strip(), "command": (st.get("command") or "").strip()}
                        for i, st in enumerate(entry["steps"])]
        row["done_when"] = entry["done_when"].strip()
        row["requires"] = requires_of(entry)
    return row


def decision_rows(entries, now=None, tz=None):
    return [decision_row(e, now, tz) for e in sort_decisions(entries)]


# ---- the build an action card needs, and the Install block (v0.69) -----------
# An action card names its build with `requires`; the dashboard, never the agent, writes the
# install command from the viewer's install_dir. One Install block per project.

_PACKAGE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._+:@=,-]*")  # a plain file name a shell reads as written
_SHA256 = re.compile(r"[0-9a-f]{64}")
_INSTALL_DIR = re.compile(r"/[A-Za-z0-9._+:@=,/-]*")
INSTALL_UNSET = "set install_dir"


def _install_dir_ok(path):
    return isinstance(path, str) and _INSTALL_DIR.fullmatch(path) is not None


def requires_of(entry):
    """The entry's `requires` as {package, sha256}, or None when it is absent or malformed: `package` a plain
    file name (no `/`, no `<`, no whitespace or shell character), `sha256` 64 lowercase hex."""
    req = entry.get("requires")
    if not isinstance(req, dict):
        return None
    package, sha = req.get("package"), req.get("sha256")
    if not isinstance(package, str) or _PACKAGE.fullmatch(package) is None:
        return None
    if not isinstance(sha, str) or _SHA256.fullmatch(sha) is None:
        return None
    return {"package": package, "sha256": sha}


def install_commands(install_dir, requires):
    """(sha256 check, install) for a build, every path full and nothing to fill in; None when install_dir is not an
    absolute plain path or requires is malformed. The check feeds `<sha256>  <package>` on stdin with a here-string."""
    req = requires_of({"requires": requires})
    if req is None or not _install_dir_ok(install_dir):
        return None
    d = install_dir.rstrip("/") or "/"
    check = "cd %s && sha256sum -c <<< '%s  %s'" % (d, req["sha256"], req["package"])
    return check, "sudo pacman -U %s/%s" % (d.rstrip("/"), req["package"])


def install_mismatch(requires):
    """The mark on a card whose build is not the one in its project's Install block."""
    return "needs %s: install it first" % requires["package"]


def install_plan(entries, install_dir):
    """{project: block} for the action entries that carry `requires`; block = {package, sha256, commands, note,
    mismatched}. The newest asked card's build is the block; commands are None (note `set install_dir`) when
    install_dir is unset; mismatched maps the decision_key of each card whose build differs to its mark, so one
    project never gets two blocks."""
    far = datetime.datetime.min.replace(tzinfo=datetime.timezone.utc)
    cards = [(e, requires_of(e)) for e in entries if decision_shape(e) == "action" and requires_of(e)]
    newest = {}
    for e, req in cards:
        project, when = str(e.get("project") or ""), parse_time(e.get("asked_at")) or far
        if project not in newest or when >= newest[project][0]:
            newest[project] = (when, req)
    plan = {}
    for project, (_when, req) in newest.items():
        commands = install_commands(install_dir, req) if install_dir else None
        plan[project] = dict(req, commands=commands, note="" if commands else INSTALL_UNSET, mismatched={})
    for e, req in cards:
        block = plan[str(e.get("project") or "")]
        if req != {"package": block["package"], "sha256": block["sha256"]}:
            block["mismatched"][decision_key(e)] = install_mismatch(req)
    return plan


def install_check_lines(entries, install_dir):
    """What the Install blocks would show, for --check: per project the package, then each command or the note,
    then one line per card whose build differs."""
    out = []
    for project, b in install_plan(entries, install_dir).items():
        out.append("install | %s | %s" % (project, b["package"]))
        out.extend("install | %s | %s" % (project, cmd) for cmd in b["commands"] or (b["note"],))
        out.extend("install | %s | %s | %s" % (project, item, mark) for (_p, item), mark in b["mismatched"].items())
    return out


def decision_key(entry):
    """What identifies a decision across refreshes: its project and item."""
    return (str(entry.get("project") or ""), str(entry.get("item") or ""))


def toggle_expanded(expanded, key):
    """The set of expanded decisions with key flipped (a new set; expanded is not changed)."""
    return expanded - {key} if key in expanded else expanded | {key}


def prune_expanded(expanded, entries):
    """The expanded decisions still in the feed; one that left the feed drops out."""
    return expanded & {decision_key(e) for e in entries}


def decisions_same(old, new):
    """Whether a refresh brought the same decisions (key order and spacing aside).

    Then the cards are not rebuilt: an open card keeps its box, its text, its cursor and
    its focus; only the "asked … ago" text moves on with the clock.
    """
    if old is None:
        return False
    return json.dumps(old, sort_keys=True) == json.dumps(new, sort_keys=True)


def answer_focus(focus, entries, answers):
    """The answer box to give the focus back to after the cards are rebuilt, or None.

    focus is (entry id, field, cursor offset) for the box that had the focus before the
    rebuild (field "text" or "note"), or None. It is kept while the entry is still in the
    feed and not answered (an answered card has no box any more).
    """
    if focus is None:
        return None
    aid = focus[0]
    if aid in answers or aid not in {str(e.get("id") or "") for e in entries if e.get("id")}:
        return None
    return focus


def decision_check_lines(entries, now=None, tz=None):
    """What the Decisions view would show, one ' | ' line per entry, the kind first, in the view's order; the Actions filter is ignored."""
    return [
        " | ".join((r["kind"], r["item"], r["project"], r["title"], "waiting for: " + r["waiting_for"],
                    "asked " + r["asked"] + (" (%s)" % r["asked_local"] if r["asked_local"] else ""))
                   + ((r["thread_url"],) if r["thread_url"] else ()))
        for r in decision_rows(entries, now, tz)
    ]


# ---- the Decisions view's Actions filter, saved on the viewer's machine -----


def decisions_filter_path(env=None):
    """$PO_DASHBOARD_DECISIONS_FILTER, else $XDG_CONFIG_HOME (default ~/.config)/po-dashboard/decisions.json."""
    env = os.environ if env is None else env
    path = (env.get(DECISIONS_FILTER_ENV) or "").strip()
    if path:
        return path
    base = (env.get("XDG_CONFIG_HOME") or "").strip()
    if not os.path.isabs(base):  # the XDG spec: a relative value is ignored
        base = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "po-dashboard", "decisions.json")


def _load_filter(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def load_actions_shown(path):
    """Whether Action entries show; on unless the file says {"actions": false} (missing or broken is on)."""
    data = _load_filter(path)
    if data is None:
        return True
    return not (data.get("actions") is False)


def load_decisions_shown(path):
    """Whether Choice entries show; on unless the file says {"decisions": false} (missing or broken is on)."""
    data = _load_filter(path)
    if data is None:
        return True
    return not (data.get("decisions") is False)


def _read_filter(path):
    data = _load_filter(path)
    return data if isinstance(data, dict) else {}


def _write_filter(path, key, shown):
    """Write one key, keeping the other. Raises DashboardError."""
    try:
        data = _read_filter(path)
        data[key] = bool(shown)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=1)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as e:
        raise DashboardError("cannot save the decisions filter: %s" % e)


def save_actions_shown(path, shown):
    """Write the actions filter atomically, keeping the decisions key. Raises DashboardError."""
    _write_filter(path, "actions", shown)


def save_decisions_shown(path, shown):
    """Write the decisions filter atomically, keeping the actions key. Raises DashboardError."""
    _write_filter(path, "decisions", shown)


def filter_decisions(entries, actions_shown, decisions_shown=True):
    """(entries to show, number of Action entries hidden, number of Choice entries hidden)."""
    actions_hidden = 0
    decisions_hidden = 0
    kept = []
    for e in entries:
        shape = decision_shape(e)
        if shape == "action" and not actions_shown:
            actions_hidden += 1
            continue
        if shape == "choice" and not decisions_shown:
            decisions_hidden += 1
            continue
        kept.append(e)
    return kept, actions_hidden, decisions_hidden


def decisions_status(shown, actions_hidden, decisions_hidden=0):
    """The status line: '3 waiting', with '· 1 action hidden' and '· 2 decisions hidden' parts when non-zero."""
    parts = ["%d waiting" % shown]
    if actions_hidden:
        parts.append("%d action hidden" % actions_hidden)
    if decisions_hidden:
        parts.append("%d decisions hidden" % decisions_hidden)
    return " \u00b7 ".join(parts)


# ---- the Team view's order, saved on the viewer's machine -------------------


def team_order_path(env=None):
    """$PO_DASHBOARD_TEAM_ORDER, else $XDG_CONFIG_HOME (default ~/.config)/po-dashboard/team-order.json."""
    env = os.environ if env is None else env
    path = (env.get(TEAM_ORDER_ENV) or "").strip()
    if path:
        return path
    base = (env.get("XDG_CONFIG_HOME") or "").strip()
    if not os.path.isabs(base):  # the XDG spec: a relative value is ignored
        base = os.path.join(os.path.expanduser("~"), ".config")
    return os.path.join(base, "po-dashboard", "team-order.json")


def load_team_order(path):
    """The saved agent names, in order; a missing, unreadable or malformed file is no order."""
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return []
    if isinstance(data, dict):
        data = data.get("order")
    if not isinstance(data, list):
        return []
    out = []
    for n in data:
        if isinstance(n, str) and n not in out:
            out.append(n)
    return out


def save_team_order(path, order):
    """Write the order atomically, creating the directory. Raises DashboardError."""
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        tmp = path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"order": list(order)}, f, indent=1)
            f.write("\n")
        os.replace(tmp, path)
    except OSError as e:
        raise DashboardError("cannot save the team order: %s" % e)


def apply_team_order(entries, order):
    """The feed's entries in the saved order; agents not in it follow, in the feed's order."""
    rank = {n: i for i, n in enumerate(order)}
    last = len(rank)
    keyed = sorted(enumerate(entries), key=lambda p: (rank.get(str(p[1].get("agent") or "?"), last), p[0]))
    return [e for _, e in keyed]


def move_agent(shown, name, index):
    """The shown names with name moved to index (clamped); unchanged when name is not shown."""
    if name not in shown:
        return list(shown)
    out = [n for n in shown if n != name]
    out.insert(max(0, min(index, len(out))), name)
    return out


def merge_team_order(shown, order):
    """The order to save after a move: the shown names, then saved names not shown now (kept for later)."""
    return list(shown) + [n for n in order if n not in shown]


# ---- the new-event highlight -------------------------------------------------


def event_key(event):
    """The identity of an event across fetches: its whole content."""
    return json.dumps(event, sort_keys=True, separators=(",", ":"))


def new_keys(seen, events):
    """The keys of events not in seen (a set, or None before the first fetch, when nothing is new)."""
    keys = [event_key(e) for e in events]
    return [] if seen is None else [k for k in keys if k not in seen]


def fade_step(elapsed, reduced=False):
    """Highlight steps left, FADE_STEPS (just appeared) down to 0 (normal), after elapsed seconds.

    With reduced motion the highlight stays at full strength and drops to 0 at FADE_SECONDS.
    """
    if elapsed >= FADE_SECONDS:
        return 0
    if reduced:
        return FADE_STEPS
    return max(0, min(FADE_STEPS, math.ceil(FADE_STEPS * (1 - max(elapsed, 0) / FADE_SECONDS))))


def mix(c1, c2, t):
    """'#rrggbb' t of the way from c1 to c2."""
    out = [round(int(c1[i:i + 2], 16) * (1 - t) + int(c2[i:i + 2], 16) * t) for i in (1, 3, 5)]
    return "#%02x%02x%02x" % tuple(out)


def fade_target(variant):
    return "#ffffff" if variant == "dark" else "#000000"


def card_color(variant, step):
    """The card colour with step highlight steps left: FADE_AMOUNT toward the target at FADE_STEPS, the base at 0."""
    return mix(PALETTES[variant]["base"], fade_target(variant), FADE_AMOUNT * step / FADE_STEPS)


def readable(fg, bg, variant, need=4.5):
    """fg, moved toward the variant's extreme in small steps until it reaches contrast need on bg."""
    for _ in range(40):
        if contrast(fg, bg) >= need:
            break
        fg = mix(fg, fade_target(variant), 0.1)
    return fg


FADE_TEXT = (("po-text", "text"), ("po-muted", "muted"), ("po-note", "muted"), ("po-warn", "warn"),
             ("po-pass", "pass"), ("po-fail", "fail"), ("po-skip", "skip"))


def fade_css(variant):
    """One rule set per highlight step: the card colour and text colours that stay AA on it."""
    pal, out = PALETTES[variant], []
    for n in range(1, FADE_STEPS + 1):
        bg = card_color(variant, n)
        out.append(".po-card.po-fade-%d { background-color: %s; }" % (n, bg))
        for cls, key in FADE_TEXT:
            out.append(".po-fade-%d .%s { color: %s; }" % (n, cls, readable(pal[key], bg, variant)))
    return "\n".join(out) + "\n"


# ---- the neumorphic style --------------------------------------------------
# One base colour per variant; surfaces are raised (outer light + dark shadow)
# or pressed (inset). Text and status colours are checked against the base by
# the tests, from the generated CSS itself.

PALETTES = {
    "light": {
        "base": "#e0e5ec", "light": "#ffffff", "dark": "#a3b1c6",
        "text": "#2b3440", "muted": "#4f5b6a",
        "pass": "#13693a", "fail": "#a8201a", "skip": "#5a5f66", "warn": "#7a4f00",
        "accent": "#1f5fa8", "series": ["#1f5fa8", "#a14a00", "#7a3d9e", "#00796b", "#8c3b2e", "#5a5f66"],
    },
    "dark": {
        "base": "#2b2f36", "light": "#383d46", "dark": "#1e2126",
        "text": "#e8ebf0", "muted": "#aab2bf",
        "pass": "#6fdc9a", "fail": "#ff9a94", "skip": "#aab2bf", "warn": "#f0c75e",
        "accent": "#7fb2ff", "series": ["#7fb2ff", "#ffb86b", "#c9a0ff", "#5fd6c4", "#e6a08f", "#aab2bf"],
    },
}

CSS_TEMPLATE = """\
window.po-dashboard { background-color: %(base)s; color: %(text)s; }
.po-header { background-color: %(base)s; border-radius: 18px; padding: 12px 18px; margin: 18px 18px 6px 18px;
  box-shadow: 6px 6px 12px %(dark)s, -6px -6px 12px %(light)s; }
.po-title { color: %(text)s; font-weight: 700; font-size: 16px; }
.po-status { color: %(muted)s; font-size: 12px; }
.po-error { color: %(fail)s; font-weight: 600; }
.po-toggle { background-color: %(base)s; background-image: none; color: %(text)s; border: none; border-radius: 14px;
  padding: 8px 16px; box-shadow: 4px 4px 8px %(dark)s, -4px -4px 8px %(light)s; }
.po-toggle:checked { box-shadow: inset 4px 4px 8px %(dark)s, inset -4px -4px 8px %(light)s; }
.po-toggle:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-list { background-color: transparent; padding: 6px 18px 18px 18px; }
.po-card { background-color: %(base)s; border-radius: 14px; padding: 12px 16px; margin: 8px 0;
  box-shadow: 5px 5px 10px %(dark)s, -5px -5px 10px %(light)s; }
.po-text { color: %(text)s; }
.po-muted { color: %(muted)s; font-size: 12px; }
.po-warn { color: %(warn)s; font-size: 12px; font-weight: 700; }
.po-note { color: %(muted)s; }
.po-note:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-pass { color: %(pass)s; font-weight: 700; }
.po-fail { color: %(fail)s; font-weight: 700; }
.po-skip { color: %(skip)s; font-weight: 700; }
.po-live { color: %(pass)s; font-weight: 700; }
.po-free { color: %(pass)s; font-weight: 700; border-radius: 10px; padding: 2px 10px;
  box-shadow: inset 3px 3px 6px %(dark)s, inset -3px -3px 6px %(light)s; }
.po-kind { font-size: 12px; font-weight: 700; }
.po-kind-choice { color: %(accent)s; }
.po-kind-action { color: %(warn)s; }
.po-kind-unformatted { color: %(fail)s; }
.po-answered { color: %(accent)s; font-weight: 700; }
.po-already { color: %(warn)s; font-weight: 700; }
.po-light-active { color: %(pass)s; }
.po-light-idle { color: %(warn)s; }
.po-light-inactive { color: %(fail)s; }
.po-pcard:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-view { background-color: %(base)s; background-image: none; color: %(text)s; border: none; border-radius: 14px;
  padding: 8px 16px; box-shadow: 4px 4px 8px %(dark)s, -4px -4px 8px %(light)s; }
.po-view:checked { box-shadow: inset 4px 4px 8px %(dark)s, inset -4px -4px 8px %(light)s; }
.po-view:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-subrow { margin: 0 18px 0 18px; }
.po-small { background-color: %(base)s; background-image: none; color: %(text)s; border: none; border-radius: 10px;
  padding: 2px 12px; min-height: 0; font-size: 12px; box-shadow: 3px 3px 6px %(dark)s, -3px -3px 6px %(light)s; }
.po-small:checked { box-shadow: inset 3px 3px 6px %(dark)s, inset -3px -3px 6px %(light)s; }
.po-small:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-chart { background-color: %(base)s; border-radius: 14px; padding: 24px 16px; margin: 8px 0;
  box-shadow: inset 4px 4px 8px %(dark)s, inset -4px -4px 8px %(light)s; }
.po-chart-draw:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-colhead { background-color: transparent; background-image: none; border: none; box-shadow: none; padding: 2px 0; min-height: 0; }
.po-colhead:hover { background-color: transparent; }
.po-colhead:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-team:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-team.po-drop { box-shadow: inset 4px 4px 8px %(dark)s, inset -4px -4px 8px %(light)s; }
"""

# (foreground selector, background selector, role): each pair must reach 4.5:1.
CONTRAST_PAIRS = [
    (".po-text", ".po-card", "card text"),
    (".po-muted", ".po-card", "card detail text"),
    (".po-note", ".po-card", "note icon"),
    (".po-warn", ".po-card", "slow run time"),
    (".po-pass", ".po-card", "pass status"),
    (".po-fail", ".po-card", "fail status"),
    (".po-skip", ".po-card", "skip status"),
    (".po-live", ".po-card", "working dot"),
    (".po-free", ".po-card", "free badge"),
    (".po-light-active", ".po-card", "active light"),
    (".po-light-idle", ".po-card", "idle light"),
    (".po-light-inactive", ".po-card", "inactive light"),
    (".po-kind-choice", ".po-card", "choice badge"),
    (".po-kind-action", ".po-card", "action badge"),
    (".po-kind-unformatted", ".po-card", "unformatted badge"),
    (".po-answered", ".po-card", "answered/sent status"),
    (".po-already", ".po-card", "already answered status"),
    (".po-view", ".po-view", "view toggle label"),
    (".po-title", ".po-header", "header title"),
    (".po-status", ".po-header", "header status line"),
    (".po-toggle", ".po-toggle", "toggle label"),
    (".po-error", ".po-header", "error line"),
    ("window.po-dashboard", "window.po-dashboard", "window text"),
]


def css(variant):
    return CSS_TEMPLATE % PALETTES[variant] + fade_css(variant)


def css_properties(text):
    """{selector: {property: value}} for the plain rules of a CSS text (no nesting, no at-rules)."""
    out = {}
    for sel, body in re.findall(r"([^{}]+)\{([^{}]*)\}", re.sub(r"/\*.*?\*/", "", text, flags=re.S)):
        for s in sel.split(","):
            props = out.setdefault(s.strip(), {})
            for decl in body.split(";"):
                if ":" in decl:
                    k, v = decl.split(":", 1)
                    props[k.strip()] = v.strip()
    return out


def luminance(hexcolor):
    chans = [int(hexcolor[i:i + 2], 16) / 255 for i in (1, 3, 5)]
    lin = [c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4 for c in chans]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contrast(a, b):
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


PROJECT_FILTERS = (("All", "all"), ("TODO", "todo"), ("DOING", "doing"), ("DONE", "done"))


def project_view_state(open_project=None, filters=None):
    """The Projects view state: which project is open (None = the overview) and each project's filter."""
    return {"open": open_project, "filters": dict(filters or {})}


def project_state_open(state, name):
    """Open a project's screen; its filter is kept per project while the window is open."""
    return dict(state, open=name)


def project_state_back(state):
    return dict(state, open=None)


def project_state_filter(state, name):
    key = str(state["filters"].get(name, "all")).strip().lower()
    return key if key in dict((k, k) for _l, k in PROJECT_FILTERS) else "all"


def project_state_set_filter(state, name, key):
    return dict(state, filters=dict(state["filters"], **{name: str(key).strip().lower()}))


def project_state_reconcile(state, projects):
    """A refresh: the open project that left the feed returns to the overview; filters of departed projects drop."""
    names = {pr["project"] for pr in projects or []}
    return {"open": state["open"] if state["open"] in names else None,
            "filters": {k: v for k, v in state["filters"].items() if k in names}}


def project_screen(pr, key="all", now=None):
    """What a project screen shows: header (name, light), the filter buttons with their counts, and one row per
    item in the feed's order. Agents are as the feed gives them; none = a muted dash (agents empty, dash true)."""
    items = pr.get("items") or []
    counts = project_counts(items)
    light = project_light(pr.get("last_event"), now)
    filters = [{"label": lab, "key": k, "count": len(items) if k == "all" else counts[k]} for lab, k in PROJECT_FILTERS]
    rows = []
    for it in filter_items(items, key):
        status = str(it.get("status") or "").strip().upper()
        agents = list(it.get("agents") or [])
        rows.append({"item": it.get("item", ""), "title": it.get("title", ""), "status": status, "agents": agents,
                     "live": status == "DOING" and bool(agents),
                     "dash": not agents})
    name = str(pr.get("project", ""))
    return {"name": name, "light": light, "text": "%s, %s" % (name, light), "filters": filters, "rows": rows}
