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
"""
import datetime
import math

import dashboard_core as core

HOUR = 3600
DAY = 86400
HOURLY_UP_TO = DAY  # ranges this short are bucketed by the hour; longer ones by the day
UNKNOWN = "unknown"  # an event with no agent or project
LEG_COLOURS = 6  # failed legs: this many leg names keep their own colour, the rest group as OTHER
OTHER = "other"


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


def first_try(events, seconds, now=None):
    """Per agent, the share of items whose first stamp passed.

    The first stamp of each (project, item, agent) over the whole feed decides; it
    counts when it falls within the range. {"rows": [{"agent", "n", "passed", "rate"}]}
    best rate first, then more items, then name; rate is 0..1.
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
        if lo <= t <= now:
            n, passed = per.get(agent, (0, 0))
            per[agent] = (n + 1, passed + ok)
    rows = [{"agent": a, "n": n, "passed": p, "rate": p / n} for a, (n, p) in per.items()]
    rows.sort(key=lambda r: (-r["rate"], -r["n"], r["agent"]))
    return {"rows": rows}


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
    top = max((r["max"] for r in rows), default=0)
    unit = "minute" if top < 2 * HOUR else "hour" if top < 2 * DAY else "day"
    return {"rows": rows, "unit": unit}


def failed_legs(events, seconds, now=None, tz=None):
    """Failed gate legs per leg name per bucket, the same buckets as gate_runs.

    {"labels": [bucket label], "hourly": bool, "legs": [name, most failures first, then OTHER],
     "series": {name: [count per bucket]}, "total": failed legs shown}
    Every leg of any event whose result is "fail" counts once. Leg names are free
    text: the LEG_COLOURS busiest in the range (ties by name) keep their own series,
    the rest are summed under OTHER, which comes last.
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
    keep, rest = names[:LEG_COLOURS], names[LEG_COLOURS:]
    out = {n: series[n] for n in keep}
    if rest:
        out[OTHER] = [sum(series[n][i] for n in rest) for i in range(len(starts))]
    return {"labels": bucket_labels(starts, not hourly), "hourly": hourly, "legs": list(out),
            "series": out, "total": sum(sum(v) for v in out.values())}


def plural(n, word):
    return "%d %s%s" % (n, word, "" if n == 1 else "s")


def gate_runs_text(data):
    if not data["total"]:
        return "Gate runs per agent: none in this range."
    parts = []
    for a in data["agents"]:
        p = sum(x for x, _ in data["series"][a])
        f = sum(x for _, x in data["series"][a])
        parts.append("%s %s, %d passed, %d failed" % (a, plural(p + f, "run"), p, f))
    return "Gate runs per agent, %s to %s: %s." % (data["labels"][0], data["labels"][-1], "; ".join(parts))


def first_try_text(data):
    if not data["rows"]:
        return "First-try pass rate per agent: none in this range."
    parts = ["%s %d%% of %s" % (r["agent"], round(100 * r["rate"]), plural(r["n"], "item")) for r in data["rows"]]
    return "First-try pass rate per agent: %s." % "; ".join(parts)


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


def reports(events, seconds, now=None, tz=None):
    """All five charts for a range: [(title, data, text alternative)] in REPORT_CHARTS order."""
    g = gate_runs(events, seconds, now, tz)
    f = first_try(events, seconds, now)
    c = closed(events, seconds, now, tz)
    t = cycle_time(events, seconds, now)
    l = failed_legs(events, seconds, now, tz)
    return [(core.REPORT_CHARTS[0], g, gate_runs_text(g)),
            (core.REPORT_CHARTS[1], f, first_try_text(f)),
            (core.REPORT_CHARTS[2], c, closed_text(c)),
            (core.REPORT_CHARTS[3], t, cycle_time_text(t)),
            (core.REPORT_CHARTS[4], l, failed_legs_text(l))]


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

AXIS_W = 34  # room for the y-axis labels
PAD = 8
ROW_H = 64  # plot height of one agent's row
ROW_GAP = 26  # a row's title line and the space beneath it
TEXT_H = 16
BAR_H = 14
NAME_W = 120
VALUE_W = 110
SERIES_COLOURS = 6  # the palette's length; further projects reuse a colour, hatched


def series_colour(i):
    return ("series", i % SERIES_COLOURS), (i // SERIES_COLOURS) % 2 == 1


def _legend(items, x, y):
    """A row of (colour, hatched, text) swatches; returns (shapes, width used)."""
    shapes = []
    for colour, hatched, text in items:
        shapes.append(("rect", x, y + 2, 12, 12, colour, hatched))
        shapes.append(("text", x + 18, y, text, "text", "start"))
        x += 18 + 7 * len(text) + 14
    return shapes, x


def _x_labels(shapes, labels, slots, x0, slot, y):
    """The label of each drawn bucket under its bar; `slots` are the drawn buckets' indices."""
    for k, i in enumerate(slots):
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


def layout_gate_runs(data, width):
    unit = "hour" if data["hourly"] else "day"
    shapes, y = _legend([("pass", False, "pass"), ("fail", True, "fail")], PAD, 0)[0], TEXT_H + 6
    labels = _bar_labels(data)
    totals = [sum(data["series"][a][i][0] + data["series"][a][i][1] for a in data["agents"]) for i in range(len(labels))]
    slots = [i for i, t in enumerate(totals) if t]
    if not slots:
        return y, shapes
    shapes.append(("text", PAD, y, "each bar = one %s" % unit, "muted", "start"))
    y += TEXT_H + 4
    n = len(slots)
    x0, slot = AXIS_W + PAD, (width - AXIS_W - 2 * PAD) / n
    top = nice_max(max(totals))
    for agent in data["agents"]:
        runs = data["series"][agent]
        p = sum(x for x, _ in runs)
        f = sum(x for _, x in runs)
        shapes.append(("text", PAD, y, "%s: %s, %d pass, %d fail" % (agent, plural(p + f, "run"), p, f), "text", "start"))
        base = y + TEXT_H + 4 + TEXT_H + ROW_H  # the count above the tallest bar fits between title and plot
        shapes.append(("text", x0 - 4, base - ROW_H - 2, str(top), "muted", "end"))
        shapes.append(("text", x0 - 4, base - 14, "0", "muted", "end"))
        shapes.append(("line", x0, base, x0 + slot * n, base, "muted"))
        for k, i in enumerate(slots):
            pa, fa = runs[i]
            bx, bw = x0 + slot * k + slot * 0.15, slot * 0.7
            hp, hf = ROW_H * pa / top, ROW_H * fa / top
            if pa:
                shapes.append(("rect", bx, base - hp, bw, hp, "pass", False))
            if fa:
                shapes.append(("rect", bx, base - hp - hf, bw, hf, "fail", True))
            if pa + fa:
                shapes.append(("text", bx + bw / 2, base - hp - hf - TEXT_H, str(pa + fa), "text", "middle"))
        _x_labels(shapes, labels, slots, x0, slot, base + 4)
        y = base + TEXT_H + 12
    y = _hidden_note(shapes, len(labels) - n, unit, y)
    return y + TEXT_H, shapes


def layout_first_try(data, width):
    shapes, y = [], 0
    track_x = PAD + NAME_W
    track_w = max(40, width - track_x - VALUE_W - PAD)
    for r in data["rows"]:
        shapes.append(("text", PAD, y, r["agent"], "text", "start"))
        shapes.append(("rect", track_x, y, track_w, BAR_H, "muted", True))
        if r["passed"]:
            shapes.append(("rect", track_x, y, track_w * r["rate"], BAR_H, "pass", False))
        shapes.append(("text", track_x + track_w + 8, y, "%d%%  n=%d" % (round(100 * r["rate"]), r["n"]), "text", "start"))
        y += BAR_H + 10
    return max(y, TEXT_H), shapes


def _layout_stacked(names, series, labels, width, colour_of, unit):
    """Stacked bars per bucket with an empty bucket left out, under a wrapping legend; each bar has its total above and its label below."""
    shapes, y = [], 0
    x = PAD
    for j, name in enumerate(names):  # the legend wraps when the window is narrow
        row, nx = _legend([(*colour_of(j), name)], x, y)
        if nx > width and x > PAD:
            x, y = PAD, y + TEXT_H + 4
            row, nx = _legend([(*colour_of(j), name)], x, y)
        shapes += row
        x = nx
    y += TEXT_H + 10
    sums = [sum(series[p][i] for p in names) for i in range(len(labels))]
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
        for j, p in enumerate(names):
            count = series[p][i]
            if count:
                h = ROW_H * count / top
                level -= h
                shapes.append(("rect", bx, level, bw, h, *colour_of(j)))
        shapes.append(("text", bx + bw / 2, level - TEXT_H, str(sums[i]), "text", "middle"))
    _x_labels(shapes, labels, slots, x0, slot, base + 4)
    y = _hidden_note(shapes, len(labels) - n, unit, base + TEXT_H + 4)
    return y + 4, shapes


def layout_closed(data, width):
    return _layout_stacked(data["projects"], data["series"], data["labels"], width, series_colour, "day")


def layout_failed_legs(data, width):
    def colour_of(j):  # OTHER is always last and hatched muted, apart from the six palette colours
        return (("muted", True) if data["legs"][j] == OTHER else series_colour(j))
    return _layout_stacked(data["legs"], data["series"], _bar_labels(data), width, colour_of,
                           "hour" if data["hourly"] else "day")


def layout_cycle_time(data, width):
    """One row per agent: whisker min to max, box q1 to q3, a bar at the median, then the text."""
    shapes, y = [], 0
    unit = {"minute": 60, "hour": HOUR, "day": DAY}[data["unit"]]
    top = nice_max(math.ceil(max((r["max"] for r in data["rows"]), default=1) / unit))
    track_x = PAD + NAME_W
    track_w = max(40, width - track_x - VALUE_W - PAD)
    at = lambda seconds: track_x + track_w * min(1, seconds / unit / top)
    for r in data["rows"]:
        mid = y + BAR_H / 2
        shapes.append(("text", PAD, y, r["agent"], "text", "start"))
        shapes.append(("line", at(r["min"]), mid, at(r["max"]), mid, "text"))
        for edge in (r["min"], r["max"]):
            shapes.append(("rect", at(edge) - 1, y + 2, 2, BAR_H - 4, "text", False))
        box_x = at(r["q1"])
        shapes.append(("rect", box_x, y, max(3, at(r["q3"]) - box_x), BAR_H, ("series", 0), False))
        shapes.append(("rect", at(r["median"]) - 1.5, y - 2, 3, BAR_H + 4, "text", False))
        shapes.append(("text", track_x + track_w + 8, y, "%s  n=%d" % (duration_text(r["median"], data["unit"]), r["n"]), "text", "start"))
        y += BAR_H + 10
    shapes.append(("line", track_x, y, track_x + track_w, y, "muted"))
    shapes.append(("text", track_x, y + 4, "0", "muted", "middle"))
    shapes.append(("text", track_x + track_w, y + 4, "%d %s" % (top, {"minute": "min", "hour": "h", "day": "d"}[data["unit"]]), "muted", "middle"))
    return y + TEXT_H + 8, shapes
