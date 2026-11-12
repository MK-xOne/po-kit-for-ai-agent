"""The dashboard's report charts as plain data: no GTK, no drawing.

Turns the events feed (the dicts dashboard_core.parse_events returns) into the
numbers each chart shows, for one of dashboard_core.REPORT_RANGES. Times are
bucketed in UTC unless a tzinfo is given.

    gate_runs(events, seconds, now)   pass/fail stamp runs per agent per bucket
    first_try(events, seconds, now)   per agent, share of first stamps that passed
    closed(events, seconds, now)      items closed per day, by project
    cycle_time(events, seconds, now)  open to close per agent, as a box plot's numbers
    failed_legs(events, seconds, now) failed gate legs per leg name per bucket

Each chart has a *_text() giving its numbers as one sentence, the text
alternative the window attaches to the drawing.

v0.143: the page opens with headline() (four numbers, each beside the previous
period) and charts() gives each chart a title that states its finding, the
previous period, a source line and "as of"; one fail-rate line replaces the
per-agent gate-run rows.
"""
import datetime
import math

import dashboard_core as core

HOUR = 3600
DAY = 86400
HOURLY_UP_TO = DAY  # ranges this short are bucketed by the hour; longer ones by the day
UNKNOWN = "unknown"  # an event with no agent or project
LEG_COLOURS = 3  # failed legs: at most this many leg names keep their own colour (v0.143: was 6)
LEG_FOLD = 0.05  # a leg under this share of all failed legs folds into OTHER too, so no sliver goes unlabelled
OTHER = "other"
MIN_N = 5  # first-try: an agent with fewer items is not ranked: drawn below the ranked ones, marked
SOURCE = "po gate event log"


def _text(value):
    return value.strip() if isinstance(value, str) and value.strip() else UNKNOWN


def bucket_starts(seconds, now=None, tz=None):
    """The start of each bucket of a gate-run chart, oldest first, the last one holding `now`.

    Hourly for a range of a day or less (24 buckets for 24 h), else daily (one per
    day of the range). Daily buckets begin at midnight in `tz`.
    """
    tz = tz or datetime.timezone.utc
    now = (now or datetime.datetime.now(datetime.timezone.utc)).astimezone(tz)
    if seconds <= HOURLY_UP_TO:
        last = now.replace(minute=0, second=0, microsecond=0)
        n, step = max(1, seconds // HOUR), datetime.timedelta(hours=1)
    else:
        last = now.replace(hour=0, minute=0, second=0, microsecond=0)
        n, step = max(1, seconds // DAY), datetime.timedelta(days=1)
    if step.days:  # calendar days: stepping by 24 h would drift across a daylight-saving change
        return [(last - datetime.timedelta(days=i)).replace(tzinfo=tz) for i in range(n - 1, -1, -1)]
    return [last - step * i for i in range(n - 1, -1, -1)]


def day_starts(days, now=None, tz=None):
    """The midnight of each of the last `days` days in `tz`, oldest first, the last holding `now`."""
    tz = tz or datetime.timezone.utc
    now = (now or datetime.datetime.now(datetime.timezone.utc)).astimezone(tz)
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    return [today - datetime.timedelta(days=i) for i in range(days - 1, -1, -1)]


def bucket_labels(starts, daily):
    return [s.strftime("%m-%d") if daily else s.strftime("%H:00") for s in starts]


def _index(starts, hourly, when, tz):
    """The bucket index of `when`, or None when it falls before the first or after the last bucket."""
    when = when.astimezone(tz)
    if when < starts[0]:
        return None
    end = starts[-1] + (datetime.timedelta(hours=1) if hourly else datetime.timedelta(days=1))
    if when >= end:
        return None
    lo, hi = 0, len(starts) - 1
    while lo < hi:  # the last start that is <= when
        mid = (lo + hi + 1) // 2
        if starts[mid] <= when:
            lo = mid
        else:
            hi = mid - 1
    return lo


def gate_runs(events, seconds, now=None, tz=None):
    """Stamp runs per agent per bucket, split pass / fail.

    {"labels": [bucket label], "hourly": bool, "agents": [agent, busiest first],
     "series": {agent: [(pass, fail), ...]}, "total": runs shown}
    Only `stamp` events count; a result other than "pass" counts as a fail.
    """
    tz = tz or datetime.timezone.utc
    now = now or datetime.datetime.now(datetime.timezone.utc)
    hourly = seconds <= HOURLY_UP_TO
    starts = bucket_starts(seconds, now, tz)
    series = {}
    for e in events:
        if e.get("kind") != "stamp":
            continue
        t = core.parse_time(e.get("time"))
        i = _index(starts, hourly, t, tz) if t else None
        if i is None or t > now:
            continue
        cell = series.setdefault(_text(e.get("agent")), [[0, 0] for _ in starts])[i]
        cell[0 if e.get("result") == "pass" else 1] += 1
    agents = sorted(series, key=lambda a: (-sum(p + f for p, f in series[a]), a))
    return {
        "labels": bucket_labels(starts, not hourly), "hourly": hourly, "agents": agents,
        "series": {a: [tuple(c) for c in series[a]] for a in agents},
        "total": sum(p + f for a in agents for p, f in series[a]),
    }


def first_try(events, seconds, now=None, agents=None):
    """Per agent, the share of items whose first stamp passed.

    The first stamp of each (project, item, agent) over the whole feed decides; it
    counts when it falls within the range. {"rows": [{"agent", "n", "passed", "rate"}],
    "n", "passed", "team"}: rows best rate first, then more items, then name; rate is
    0..1; "team" is passed / n over every row (None with no rows). `agents`, the Team
    feed's roster when there is one, keeps only its names (v0.143): the owner's own
    stamps, which carry the user name, are not an agent's.
    """
    now = now or datetime.datetime.now(datetime.timezone.utc)
    lo = now - datetime.timedelta(seconds=seconds)
    first = {}
    for e in events:
        t = core.parse_time(e.get("time"))
        if e.get("kind") != "stamp" or t is None:
            continue
        key = (_text(e.get("project")), _text(e.get("item")), _text(e.get("agent")))
        if key not in first or t < first[key][0]:
            first[key] = (t, e.get("result") == "pass")
    per = {}
    for (_project, _item, agent), (t, ok) in first.items():
        if lo <= t <= now and (agents is None or agent in agents):
            n, passed = per.get(agent, (0, 0))
            per[agent] = (n + 1, passed + ok)
    rows = [{"agent": a, "n": n, "passed": p, "rate": p / n} for a, (n, p) in per.items()]
    rows.sort(key=lambda r: (-r["rate"], -r["n"], r["agent"]))
    n, passed = sum(r["n"] for r in rows), sum(r["passed"] for r in rows)
    return {"rows": rows, "n": n, "passed": passed, "team": passed / n if n else None}


def closed(events, seconds, now=None, tz=None):
    """Items closed per day, stacked by project.

    {"labels": [day], "projects": [project, most closes first],
     "series": {project: [count per day]}, "total": closes shown}
    Only passing `close` events count. One day for 24 h would miss a close made
    before midnight, so a range of a day shows two days; longer ranges show one per day.
    """
    tz = tz or datetime.timezone.utc
    now = now or datetime.datetime.now(datetime.timezone.utc)
    starts = day_starts(max(2, seconds // DAY), now, tz)
    series = {}
    for e in events:
        if e.get("kind") != "close" or e.get("result") != "pass":
            continue
        t = core.parse_time(e.get("time"))
        i = _index(starts, False, t, tz) if t else None
        if i is None or t > now:
            continue
        series.setdefault(_text(e.get("project")), [0] * len(starts))[i] += 1
    projects = sorted(series, key=lambda p: (-sum(series[p]), p))
    return {"labels": bucket_labels(starts, True), "projects": projects,
            "series": {p: series[p] for p in projects}, "total": sum(sum(v) for v in series.values())}


def _quantile(values, q):
    """The q-th quantile (0..1) of sorted `values`, interpolating between neighbours."""
    pos = (len(values) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(values) - 1)
    return values[lo] + (values[hi] - values[lo]) * (pos - lo)


def cycle_time(events, seconds, now=None):
    """Open to close, per agent, as the numbers of a box plot.

    {"rows": [{"agent", "n", "min", "q1", "median", "q3", "max"}], "unit": "minute"|"hour"|"day"}
    An item is a (project, item) with a passing `close` in the range; its cycle is that
    close's time minus its latest `open` at or before it, so an item with no open event,
    or not yet closed, is left out. The item counts for the agent that stamped it most
    (ties: the name that sorts first), else the agent of its close event. Values are
    seconds; rows are ordered by median, longest first, then name.
    """
    now = now or datetime.datetime.now(datetime.timezone.utc)
    lo = now - datetime.timedelta(seconds=seconds)
    opens, stamps, closes = {}, {}, {}
    for e in events:
        t = core.parse_time(e.get("time"))
        if t is None or t > now or e.get("item") in (None, ""):
            continue
        key = (_text(e.get("project")), _text(e.get("item")))
        kind = e.get("kind")
        if kind == "stamp":
            counts = stamps.setdefault(key, {})
            agent = _text(e.get("agent"))
            counts[agent] = counts.get(agent, 0) + 1
        elif kind == "open":
            opens.setdefault(key, []).append(t)
        elif kind == "close" and e.get("result") == "pass" and lo <= t:
            if key not in closes or t > closes[key][0]:
                closes[key] = (t, _text(e.get("agent")))
    per = {}
    for key, (closed_at, closer) in closes.items():
        started = [t for t in opens.get(key, ()) if t <= closed_at]
        if not started:
            continue
        counts = stamps.get(key)
        agent = min(counts, key=lambda a: (-counts[a], a)) if counts else closer
        per.setdefault(agent, []).append((closed_at - max(started)).total_seconds())
    rows = []
    for agent, durations in per.items():
        d = sorted(durations)
        rows.append({"agent": agent, "n": len(d), "min": d[0], "q1": _quantile(d, 0.25),
                     "median": _quantile(d, 0.5), "q3": _quantile(d, 0.75), "max": d[-1]})
    rows.sort(key=lambda r: (-r["median"], r["agent"]))
    every = sorted(d for durations in per.values() for d in durations)
    return {"rows": rows, "unit": cycle_unit(rows), "n": len(every), "median": _quantile(every, 0.5) if every else None}


def cycle_unit(rows):
    """The cycle-time unit, from the medians (v0.141): one long item no longer turns every median into "0.0 d".
    Days when the longest median is a day or more; hours when it is under a day (or when a whisker reaches 2 h);
    minutes only when the whole chart is shorter than that."""
    median = max((r["median"] for r in rows), default=0)
    top = max((r["max"] for r in rows), default=0)
    return "day" if median >= DAY else "hour" if median >= HOUR or top >= 2 * HOUR else "minute"


def failed_legs(events, seconds, now=None, tz=None):
    """Failed gate legs per leg name per bucket, the same buckets as gate_runs.

    {"labels": [bucket label], "hourly": bool, "legs": [name, most failures first, then OTHER],
     "series": {name: [count per bucket]}, "total": failed legs shown}
    Every leg of any event whose result is "fail" counts once. Leg names are free
    text: the LEG_COLOURS busiest in the range (ties by name) that hold at least
    LEG_FOLD of all failed legs keep their own series, the rest are summed under
    OTHER, which comes last.
    """
    tz = tz or datetime.timezone.utc
    now = now or datetime.datetime.now(datetime.timezone.utc)
    hourly = seconds <= HOURLY_UP_TO
    starts = bucket_starts(seconds, now, tz)
    series = {}
    for e in events:
        legs = e.get("legs")
        t = core.parse_time(e.get("time")) if isinstance(legs, list) else None
        i = _index(starts, hourly, t, tz) if t else None
        if i is None or t > now:
            continue
        for leg in legs:
            if isinstance(leg, dict) and leg.get("result") == "fail":
                series.setdefault(_text(leg.get("name")), [0] * len(starts))[i] += 1
    names = sorted(series, key=lambda n: (-sum(series[n]), n))
    total = sum(sum(v) for v in series.values())
    keep = [n for n in names[:LEG_COLOURS] if sum(series[n]) >= LEG_FOLD * total]
    rest = [n for n in names if n not in keep]
    if len(rest) == 1 and len(keep) < LEG_COLOURS:  # one leg alone is named, not called "other"
        keep, rest = keep + rest, []
    out = {n: series[n] for n in keep}
    if rest:
        out[OTHER] = [sum(series[n][i] for n in rest) for i in range(len(starts))]
    return {"labels": bucket_labels(starts, not hourly), "hourly": hourly, "legs": list(out),
            "series": out, "total": sum(sum(v) for v in out.values())}


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def first_try_text(data):
    if not data["rows"]:
        return "First-try pass rate per agent: none in this range."
    parts = ["%s %s of %s%s" % (r["agent"], pct(r["rate"]), plural(r["n"], "item"), "" if r["n"] >= MIN_N else ", too few to rank")
             for r in sorted(data["rows"], key=lambda r: r["n"] < MIN_N)]
    return "First-try pass rate per agent: %s; team average %s." % ("; ".join(parts), pct(data["team"]))


def closed_text(data):
    if not data["total"]:
        return "Items closed per day by project: none in this range."
    parts = ["%s %d" % (p, sum(data["series"][p])) for p in data["projects"]]
    return "Items closed per day by project, %s to %s: %d in all; %s." % (
        data["labels"][0], data["labels"][-1], data["total"], "; ".join(parts))


def duration_text(seconds, unit):
    if unit == "minute":
        return "%.0f min" % (seconds / 60)
    if unit == "hour":
        return "%.1f h" % (seconds / HOUR)
    return "%.1f d" % (seconds / DAY)


def cycle_time_text(data):
    if not data["rows"]:
        return "Item cycle time per agent: none in this range."
    u = data["unit"]
    parts = ["%s %s, median %s, quartiles %s to %s, range %s to %s" % (
        r["agent"], plural(r["n"], "item"), duration_text(r["median"], u), duration_text(r["q1"], u),
        duration_text(r["q3"], u), duration_text(r["min"], u), duration_text(r["max"], u)) for r in data["rows"]]
    return "Item cycle time, open to close, per agent: %s." % "; ".join(parts)


def failed_legs_text(data):
    if not data["total"]:
        return "Failed legs by kind over time: none in this range."
    parts = ["%s %d" % (n, sum(data["series"][n])) for n in data["legs"]]
    return "Failed legs by kind over time, %s to %s: %d in all; %s." % (
        data["labels"][0], data["labels"][-1], data["total"], "; ".join(parts))


def fail_rate(data):
    """The fail-rate line from gate_runs data: per bucket, failed runs over all runs (None for a bucket with no run).

    {"labels", "hourly", "runs": [n], "fails": [n], "rates": [0..1 or None], "total", "failed", "rate"}
    """
    n = len(data["labels"])
    runs = [sum(sum(data["series"][a][i]) for a in data["agents"]) for i in range(n)]
    fails = [sum(data["series"][a][i][1] for a in data["agents"]) for i in range(n)]
    total, failed = sum(runs), sum(fails)
    return {"labels": data["labels"], "hourly": data["hourly"], "runs": runs, "fails": fails,
            "rates": [f / r if r else None for r, f in zip(runs, fails)],
            "total": total, "failed": failed, "rate": failed / total if total else None}


def fail_rate_text(data):
    if not data["total"]:
        return "Fail rate of gate runs: none in this range."
    parts = ["%s %d of %d" % (label, f, r) for label, r, f in zip(data["labels"], data["runs"], data["fails"]) if r]
    return "Fail rate of gate runs, %s to %s: %s of %s failed; per %s: %s." % (
        data["labels"][0], data["labels"][-1], pct(data["rate"]), plural(data["total"], "run"),
        "hour" if data["hourly"] else "day", "; ".join(parts))


def pct(rate):
    """A share as a whole percent with a no-break space: `61 %` (v0.143, one format on every chart)."""
    return "%d\u00a0%%" % round(100 * rate)


def period_name(seconds):
    """`7 d` for a range of core.REPORT_RANGES, else the range in hours or days."""
    for label, secs in core.REPORT_RANGES:
        if secs == seconds:
            return label
    return "%d h" % (seconds // HOUR) if seconds < DAY else "%d d" % (seconds // DAY)


def in_window(events, seconds, now):
    """Whether any event falls in the `seconds` before `now` (the end included)."""
    lo = now - datetime.timedelta(seconds=seconds)
    return any(t is not None and lo < t <= now for t in (core.parse_time(e.get("time")) for e in events))


def closes_in(events, seconds, now, tz=None):
    """Passing close events in the gate-run buckets of the range (bucket_starts), so the headline counts the same
    hours or days as the fail-rate line."""
    lo = bucket_starts(seconds, now, tz)[0]
    return sum(1 for e in events if e.get("kind") == "close" and e.get("result") == "pass"
               and (lambda t: t is not None and lo <= t <= now)(core.parse_time(e.get("time"))))


def _numbers(events, seconds, now, tz, agents):
    g = fail_rate(gate_runs(events, seconds, now, tz))
    f = first_try(events, seconds, now, agents)
    return {"runs": g["total"], "fail": g["rate"], "first": f["team"], "closed": closes_in(events, seconds, now, tz)}


HEADLINE = (("runs", "gate runs", False), ("fail", "fail rate", True), ("first", "first try", True), ("closed", "closed", False))
NO_PREVIOUS = "no previous period"


def change_text(now_value, before, is_rate, period):
    """The previous period beside a number, in words and an arrow (never colour alone):
    `▲ up 24 from 188, previous 7 d`, `▼ down 7 points from 21 %, previous 7 d`, `same as the previous 7 d (12)`."""
    if before is None:
        return NO_PREVIOUS
    show = pct if is_rate else str
    if now_value is None:
        return "was %s, previous %s" % (show(before), period)
    a, b = (round(100 * now_value), round(100 * before)) if is_rate else (now_value, before)
    if a == b:
        return "same as the previous %s (%s)" % (period, show(before))
    unit = " point%s" % ("" if abs(a - b) == 1 else "s") if is_rate else ""
    return "%s %d%s from %s, previous %s" % ("▲ up" if a > b else "▼ down", abs(a - b), unit, show(before), period)


def previous_now(events, seconds, now, covered):
    """The end of the previous period, or None when there is none: the feed does not reach back that far
    (`covered` False) or the previous period holds no event."""
    before = now - datetime.timedelta(seconds=seconds)
    return before if covered and in_window(events, seconds, before) else None


def headline(events, seconds, now=None, tz=None, agents=None, covered=True):
    """The four numbers Reports opens with (v0.143), each beside the previous period of the same length:
    [{"key", "label", "value", "text", "previous", "change"}] for gate runs, fail rate, first try, closed.
    A rate with nothing to divide is None and reads "no runs" or "no items"."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    cur = _numbers(events, seconds, now, tz, agents)
    before = previous_now(events, seconds, now, covered)
    prev = _numbers(events, seconds, before, tz, agents) if before else {}
    out = []
    for key, label, is_rate in HEADLINE:
        value = cur[key]
        text = (pct(value) if value is not None else "no runs" if key == "fail" else "no items") if is_rate else str(value)
        out.append({"key": key, "label": label, "value": value, "text": text, "previous": prev.get(key),
                    "change": change_text(value, prev.get(key), is_rate, period_name(seconds)) if before else NO_PREVIOUS})
    return out


def headline_text(tiles):
    return "; ".join("%s %s (%s)" % (t["label"], t["text"], t["change"]) for t in tiles)


def _trend(name, value, before, show):
    """A title that states the finding: `Fail rate fell to 14 %`, `rose to`, `held at`, or `was` with no previous."""
    if before is None:
        return "%s was %s" % (name, show(value))
    a, b = show(value), show(before)
    if a == b:
        return "%s held at %s" % (name, a)
    return "%s %s to %s" % (name, "rose" if value > before else "fell", a)


def _previous_line(period, text):
    """The chart's context sentence: the previous period's numbers, or that there is none."""
    return ("Previous %s: %s." % (period, text)) if text else "No previous period."


def charts(events, seconds, now=None, tz=None, agents=None, covered=True, as_of=None):
    """The five charts of Reports for a range, each a dict (v0.143):
    {"topic": its REPORT_CHARTS name, "title": the finding, "data", "layout": the layout function,
     "context": the previous period in a sentence, "source": where the numbers come from and as of when,
     "text": the text alternative: title, numbers, previous period and source}.

    The previous period is the same length just before; there is none when `covered` is False (the events do not
    reach back that far) or it holds no event. `agents` (the Team roster) limits first-try to agents. `as_of` is
    when the events last came in (default `now`)."""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    period = period_name(seconds)
    before = previous_now(events, seconds, now, covered)
    as_of_text = core.clock_text(as_of or now, now, tz)
    colours = project_colours(events)

    g = fail_rate(gate_runs(events, seconds, now, tz))
    gp = fail_rate(gate_runs(events, seconds, before, tz)) if before else None
    g["previous"] = gp["rate"] if gp else None
    g["period"] = period
    f = first_try(events, seconds, now, agents)
    fp = first_try(events, seconds, before, agents) if before else None
    f["previous"] = {r["agent"]: r["rate"] for r in fp["rows"]} if fp else {}
    f["team_previous"] = fp["team"] if fp else None
    c = closed(events, seconds, now, tz)
    c["colours"] = colours
    cp = closes_in(events, seconds, before, tz) if before else None
    count = closes_in(events, seconds, now, tz)
    t = cycle_time(events, seconds, now)
    tp = cycle_time(events, seconds, before) if before else None
    lg = failed_legs(events, seconds, now, tz)
    lp = failed_legs(events, seconds, before, tz) if before else None

    out = []

    def add(i, title, data, layout, text, context, what):
        source = "Source: %s, %s · last %s · as of %s." % (SOURCE, what, period, as_of_text)
        out.append({"topic": core.REPORT_CHARTS[i], "title": title, "data": data, "layout": layout,
                    "context": context, "source": source, "text": " ".join((title + ".", text, context, source))})

    add(0, _trend("Fail rate", g["rate"], gp["rate"] if gp else None, pct) if g["rate"] is not None else "No gate runs in this range",
        g, layout_fail_rate, fail_rate_text(g),
        _previous_line(period, gp and ("%s of %s failed" % (pct(gp["rate"]), plural(gp["total"], "run")) if gp["total"] else "no gate runs")),
        "stamp events")
    add(1, _trend("First-try rate", f["team"], f["team_previous"], pct) if f["team"] is not None else "No first stamps in this range",
        f, layout_first_try, first_try_text(f),
        _previous_line(period, fp and ("team %s of %s" % (pct(fp["team"]), plural(fp["n"], "item")) if fp["n"] else "no first stamps")),
        "each item's first stamp per agent" + ("" if agents is None else ", Team agents only"))
    top = c["projects"][0] if c["projects"] else None
    add(2, ("%s closed, most in %s (%d)" % (plural(count, "item"), top, sum(c["series"][top])) if top else "No items closed in this range"),
        c, layout_closed, closed_text(c), _previous_line(period, cp is not None and "%d closed" % cp),
        "passing close events")
    unit = t["unit"]
    add(3, _trend("Median cycle time", t["median"], tp["median"] if tp else None, lambda v: duration_text(v, unit))
        if t["median"] is not None else "No items closed with an open event in this range",
        t, layout_cycle_time, cycle_time_text(t),
        _previous_line(period, tp and ("median %s over %s" % (duration_text(tp["median"], unit), plural(tp["n"], "item")) if tp["n"] else "no items closed")),
        "open to passing close")
    big = lg["legs"][0] if lg["total"] else None
    add(4, ("%s is %s of failed legs (%d of %d)" % (big, pct(sum(lg["series"][big]) / lg["total"]), sum(lg["series"][big]), lg["total"])
            if big else "No failed legs in this range"),
        lg, layout_failed_legs, failed_legs_text(lg),
        _previous_line(period, lp is not None and "%s" % plural(lp["total"], "failed leg") + (
            ", %s %s" % (lp["legs"][0], pct(sum(lp["series"][lp["legs"][0]]) / lp["total"])) if lp["total"] else "")),
        "the failed legs of every event")
    return out


def reports(events, seconds, now=None, tz=None, agents=None, covered=True, as_of=None):
    """The whole Reports page for a range: {"headline": headline(), "charts": charts()}."""
    return {"headline": headline(events, seconds, now, tz, agents, covered),
            "charts": charts(events, seconds, now, tz, agents, covered, as_of)}


def project_colours(events):
    """A fixed colour index per project (v0.143): the projects of the whole feed by name, so a project keeps its
    colour whatever the range and whatever closes it holds; past the palette a colour repeats, hatched."""
    return {p: i for i, p in enumerate(sorted({_text(e.get("project")) for e in events}))}


def nice_max(value):
    """A round axis top just at or above `value`: 1, 1.2, 1.5, 2, 2.4, 3, 4, 5, 6 or 8 times a power of ten.

    Whole numbers only (a count or an hour never gets a fractional tick), at least 1.
    """
    value = max(1, value)
    power = 1
    while True:
        for m in (10, 12, 15, 20, 24, 30, 40, 50, 60, 80):
            top = m * power
            if top % 10 == 0 and top // 10 >= value:
                return top // 10
        power *= 10


# ---- layout: each chart as shapes, for the window to paint ---------------------
# A layout is (height, [shape]). Shapes, in pixels from the chart's top left:
#   ("rect", x, y, w, h, colour, hatched)   hatched = outline and diagonal lines, not a fill
#   ("line", x1, y1, x2, y2, colour)
#   ("text", x, y, string, colour, align)   y is the top of the text; align "start", "middle" or "end"
# A colour is "pass", "fail", "text", "muted" or ("series", n); the window maps it to the theme.

AXIS_W = 40  # room for the y-axis labels
PAD = 8
ROW_H = 64  # plot height of a bar chart
PLOT_H = 120  # plot height of the fail-rate line
TEXT_H = 16
BAR_H = 14
NAME_W = 120
VALUE_W = 170  # "61 %  n=12 · was 70 %"
NARROW = 480  # below this width a row's name and value share one line above a full-width track (390 px phones)
CHAR_W = 7  # the width of one 12 px character, for fitting labels
SERIES_COLOURS = 5  # the project palette's length; further projects reuse a colour, hatched
LEG_SHADES = LEG_COLOURS  # failed legs: one hue in lightness steps, apart from the project colours


def series_colour(i):
    return ("series", i % SERIES_COLOURS), (i // SERIES_COLOURS) % 2 == 1


def _legend(items, x, y, width=None):
    """A row of (colour, hatched, text) swatches that wraps at `width`; returns (shapes, x after, y of the last row)."""
    shapes = []
    for colour, hatched, text in items:
        w = 18 + CHAR_W * len(text) + 14
        if width is not None and x + w > width and x > PAD:
            x, y = PAD, y + TEXT_H + 4
        shapes.append(("rect", x, y + 2, 12, 12, colour, hatched))
        shapes.append(("text", x + 18, y, text, "text", "start"))
        x += w
    return shapes, x, y


def _x_labels(shapes, labels, slots, x0, slot, y):
    """The label of each drawn bucket under its bar; `slots` are the drawn buckets' indices. Labels closer
    than a label's width are thinned to every k-th, so a narrow window does not overprint them."""
    every = max(1, math.ceil((CHAR_W * max((len(labels[i]) for i in slots), default=1) + 6) / max(slot, 1)))
    for k, i in enumerate(slots):
        if k % every == 0:
            shapes.append(("text", x0 + slot * (k + 0.5), y, labels[i], "muted", "middle"))


def _bar_labels(data):
    """Bar labels: a day as its date, an hour as its number (the title line says which)."""
    return [x[:-3] for x in data["labels"]] if data.get("hourly") else data["labels"]


def _hidden_note(shapes, hidden, unit, y):
    """A muted note under the chart saying how many empty buckets were left out; returns the new y."""
    if not hidden:
        return y
    shapes.append(("text", PAD, y + 4, "%s hidden" % plural(hidden, "empty " + unit), "muted", "start"))
    return y + TEXT_H + 4


def axis_ticks(top, unit):
    """(axis end, step) for a duration axis in `unit` from 0 to at least `top` (v0.141): the smallest of the unit's
    TICK_STEPS that needs at most MAX_TICKS steps (hours step by 6, 12 or 24, so days read as days), the end a whole
    number of steps."""
    top = max(1, math.ceil(top))
    step = next((s for s in TICK_STEPS[unit] if top / s <= MAX_TICKS), None)
    if step is None:
        step = nice_max(math.ceil(top / MAX_TICKS))
    return step * math.ceil(top / step), step


TICK_STEPS = {"minute": (1, 2, 5, 10, 15, 30, 60, 120), "hour": (1, 2, 3, 6, 12, 24, 48, 72, 96, 120, 168),
              "day": (1, 2, 5, 7, 10, 14, 30, 60, 90)}
MAX_TICKS = 6
PERCENT_TOPS = (10, 20, 25, 50, 100)


def layout_fail_rate(data, width):
    """One line: the share of gate runs that failed, per hour or day, on a 0-based percent axis (v0.143, replaces
    the per-agent gate-run rows). A bucket with no run is a gap, not a zero; the previous period's rate is a
    dashed line labelled in words; the last point carries its value."""
    shapes = [("path", [(PAD, 9), (PAD + 16, 9)], "fail", 2, False), ("text", PAD + 22, 0, "failed runs ÷ all runs", "text", "start")]
    x = PAD + 22 + CHAR_W * 23 + 14
    prev = data.get("previous")
    if prev is not None:
        label = "previous %s: %s" % (data.get("period", ""), pct(prev))
        if x + 22 + CHAR_W * len(label) > width:
            x, y0 = PAD, TEXT_H + 4
        else:
            y0 = 0
        shapes += [("path", [(x, y0 + 9), (x + 16, y0 + 9)], "muted", 1, True), ("text", x + 22, y0, label, "muted", "start")]
    y = shapes[-1][2] + TEXT_H + 10
    rates = data["rates"]
    if not data["total"]:
        return y, shapes
    top = next(t for t in PERCENT_TOPS if t >= 100 * max([r for r in rates if r is not None] + [prev or 0]))
    x0, n = AXIS_W + PAD, len(rates)
    slot = (width - x0 - PAD) / n
    base = y + PLOT_H
    at = lambda rate: base - PLOT_H * min(1, 100 * rate / top)
    for v in (0, top // 2 if top % 2 == 0 else top / 2, top):
        shapes.append(("text", x0 - 4, at(v / 100) - TEXT_H / 2, "%g\u00a0%%" % v, "muted", "end"))
    shapes.append(("line", x0, base, x0 + slot * n, base, "muted"))
    shapes.append(("line", x0, at(top / 100), x0 + slot * n, at(top / 100), "hairline"))
    if prev is not None:
        shapes.append(("path", [(x0, at(prev)), (x0 + slot * n, at(prev))], "muted", 1, True))
    run, last = [], None
    for i, rate in enumerate(rates):
        if rate is None:  # no run: the line breaks
            if len(run) > 1:
                shapes.append(("path", run, "fail", 2, False))
            run = []
            continue
        point = (x0 + slot * (i + 0.5), at(rate))
        run.append(point)
        shapes.append(("rect", point[0] - 2.5, point[1] - 2.5, 5, 5, "fail", False))
        last = (point, rate)
    if len(run) > 1:
        shapes.append(("path", run, "fail", 2, False))
    if last:
        (px, py), rate = last
        above = py - TEXT_H - 4
        if prev is not None and above - 2 < at(prev) < py + 2:  # clear of the dashed previous line
            above = py + 6
        shapes.append(("text", min(px, width - PAD - 2 * CHAR_W), max(y, above), pct(rate), "text", "middle"))
    _x_labels(shapes, _bar_labels(data), range(n), x0, slot, base + 4)
    unit = "hour" if data["hourly"] else "day"
    shapes.append(("text", PAD, base + TEXT_H + 8, "each point = one %s; %s with no run is a gap" % (unit, "an hour" if data["hourly"] else "a day"), "muted", "start"))
    return base + 2 * TEXT_H + 14, shapes


def _rows_geometry(width):
    """(name x, track x, track width, narrow): wide rows are name | track | value on one line; narrow
    ones put name and value on a line above a full-width track."""
    if width < NARROW:
        return PAD, PAD, max(40, width - 2 * PAD), True
    track_x = PAD + NAME_W
    return PAD, track_x, max(40, width - track_x - VALUE_W - PAD), False


def layout_first_try(data, width):
    """Agents with MIN_N items or more, ranked; then the ones with fewer, under a muted "not ranked" line and
    drawn hatched (v0.143). A dashed team-average line runs through every row; each agent's previous rate is a
    tick on its track and words after its value."""
    shapes, y = [], 0
    name_x, track_x, track_w, narrow = _rows_geometry(width)
    ranked = [r for r in data["rows"] if r["n"] >= MIN_N]
    small = [r for r in data["rows"] if r["n"] < MIN_N]
    prev = data.get("previous", {})
    team = data.get("team")
    if team is not None:
        label = "team average %s" % pct(team) + ("" if data.get("team_previous") is None else ", was %s" % pct(data["team_previous"]))
        tx = track_x + track_w * team
        shapes.append(("text", min(max(tx, track_x + CHAR_W * len(label) / 2), width - PAD - CHAR_W * len(label) / 2), y, label, "text", "middle"))
        y += TEXT_H + 4
    top = y

    def row(r, muted):
        nonlocal y
        value = "%s  n=%d" % (pct(r["rate"]), r["n"]) + (" · was %s" % pct(prev[r["agent"]]) if r["agent"] in prev else "")
        if narrow:
            shapes.append(("text", name_x, y, "%s  %s" % (r["agent"], value), "muted" if muted else "text", "start"))
            y += TEXT_H + 2
        else:
            shapes.append(("text", name_x, y, r["agent"], "muted" if muted else "text", "start"))
            shapes.append(("text", track_x + track_w + 8, y, value, "muted" if muted else "text", "start"))
        shapes.append(("rect", track_x, y, track_w, BAR_H, "hairline", False))
        if r["passed"]:
            shapes.append(("rect", track_x, y, track_w * r["rate"], BAR_H, "muted" if muted else "pass", muted))
        if r["agent"] in prev:
            shapes.append(("rect", track_x + track_w * prev[r["agent"]] - 1, y - 2, 2, BAR_H + 4, "text", False))
        y += BAR_H + 10

    for r in ranked:
        row(r, False)
    if small:
        shapes.append(("text", name_x, y, "fewer than %d items, not ranked" % MIN_N, "muted", "start"))
        y += TEXT_H + 4
        for r in small:
            row(r, True)
    if team is not None:
        tx = track_x + track_w * team
        shapes.append(("path", [(tx, top), (tx, y - 6)], "text", 1, True))
    return max(y, TEXT_H), shapes


def _layout_stacked(names, series, labels, width, colour_of, unit):
    """Stacked bars per bucket with an empty bucket left out, under a wrapping legend that gives each series its
    total and share. Each bar has its total above and its label below; segments are split by a 1 px gap, and a
    bar's biggest segment carries its count inside when it fits (v0.143), so the chart reads without colour."""
    sums = [sum(series[p][i] for p in names) for i in range(len(labels))]
    total = sum(sums)
    items = [(*colour_of(j), "%s %d (%s)" % (name, sum(series[name]), pct(sum(series[name]) / total)) if total else name)
             for j, name in enumerate(names)]
    shapes, _x, y = _legend(items, PAD, 0, width)
    y += TEXT_H + 10
    slots = [i for i, s in enumerate(sums) if s]
    if not slots:
        return y, shapes
    shapes.append(("text", PAD, y - 4, "each bar = one %s" % unit, "muted", "start"))
    y += TEXT_H
    n = len(slots)
    x0, slot = AXIS_W + PAD, (width - AXIS_W - 2 * PAD) / n
    top = nice_max(max(sums))
    base = y + ROW_H + TEXT_H
    shapes.append(("text", x0 - 4, base - ROW_H - 2 - TEXT_H, str(top), "muted", "end"))
    shapes.append(("text", x0 - 4, base - 14, "0", "muted", "end"))
    shapes.append(("line", x0, base, x0 + slot * n, base, "muted"))
    for k, i in enumerate(slots):
        bx, bw, level = x0 + slot * k + slot * 0.15, slot * 0.7, base
        biggest = max(range(len(names)), key=lambda j: (series[names[j]][i], -j))
        for j, p in enumerate(names):
            count = series[p][i]
            if count:
                h = ROW_H * count / top
                level -= h
                colour, hatched = colour_of(j)
                shapes.append(("rect", bx, level + (1 if h > 3 else 0), bw, h - (1 if h > 3 else 0), colour, hatched))
                if j == biggest and h >= TEXT_H + 1 and bw >= CHAR_W * len(str(count)) + 4:
                    shapes.append(("text", bx + bw / 2, level + (h - TEXT_H) / 2, str(count), "text" if hatched else ("ink", colour), "middle"))
        shapes.append(("text", bx + bw / 2, level - TEXT_H, str(sums[i]), "text", "middle"))
    _x_labels(shapes, labels, slots, x0, slot, base + 4)
    y = _hidden_note(shapes, len(labels) - n, unit, base + TEXT_H + 4)
    return y + 4, shapes


def layout_closed(data, width):
    """Closes per day stacked by project, each project in its fixed colour (data["colours"], v0.143)."""
    colours = data.get("colours") or {p: j for j, p in enumerate(data["projects"])}
    return _layout_stacked(data["projects"], data["series"], data["labels"], width,
                           lambda j: series_colour(colours.get(data["projects"][j], j)), "day")


def leg_colour(legs, j):
    """A failed leg's colour: one hue in lightness steps, darkest for the most failures, never a project's
    colour (v0.143); OTHER is hatched muted."""
    return ("muted", True) if legs[j] == OTHER else (("legs", j % LEG_SHADES), j >= LEG_SHADES)


def layout_failed_legs(data, width):
    return _layout_stacked(data["legs"], data["series"], _bar_labels(data), width, lambda j: leg_colour(data["legs"], j),
                           "hour" if data["hourly"] else "day")


def layout_cycle_time(data, width):
    """One row per agent: whisker min to max, box q1 to q3 (neutral, not a project's colour), a bar at the
    median, then the text; on a narrow width the text goes on a line above the track."""
    shapes, y = [], 0
    unit = {"minute": 60, "hour": HOUR, "day": DAY}[data["unit"]]
    top, step = axis_ticks(max((r["max"] for r in data["rows"]), default=1) / unit, data["unit"])
    name_x, track_x, track_w, narrow = _rows_geometry(width)
    at = lambda seconds: track_x + track_w * min(1, seconds / unit / top)
    for r in data["rows"]:
        value = "%s  n=%d" % (duration_text(r["median"], data["unit"]), r["n"])
        if narrow:
            shapes.append(("text", name_x, y, "%s  %s" % (r["agent"], value), "text", "start"))
            y += TEXT_H + 2
        else:
            shapes.append(("text", name_x, y, r["agent"], "text", "start"))
            shapes.append(("text", track_x + track_w + 8, y, value, "text", "start"))
        mid = y + BAR_H / 2
        shapes.append(("line", at(r["min"]), mid, at(r["max"]), mid, "text"))
        for edge in (r["min"], r["max"]):
            shapes.append(("rect", at(edge) - 1, y + 2, 2, BAR_H - 4, "text", False))
        box_x = at(r["q1"])
        shapes.append(("rect", box_x, y, max(3, at(r["q3"]) - box_x), BAR_H, "edge", False))
        shapes.append(("rect", at(r["median"]) - 1.5, y - 2, 3, BAR_H + 4, "text", False))
        y += BAR_H + 10
    shapes.append(("line", track_x, y, track_x + track_w, y, "muted"))
    short = {"minute": "min", "hour": "h", "day": "d"}[data["unit"]]
    for v in range(0, top + 1, step):  # a tick and its label at every step from 0 to the end (v0.141)
        x = track_x + track_w * v / top
        if narrow and v and v != top and (v // step) % 2:  # every other label on a phone, so they do not touch
            shapes.append(("line", x, y, x, y + 4, "muted"))
            continue
        shapes.append(("line", x, y, x, y + 4, "muted"))
        shapes.append(("text", x, y + 6, "%d %s" % (v, short) if v else "0", "muted", "middle"))
    return y + TEXT_H + 10, shapes
