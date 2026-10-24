"""po-kit: the logic of po-dashboard, with no display and no GTK.

Fetching, parsing, sorting, limiting, formatting and the neumorphic CSS live
here so tests can run them anywhere; bin/po-dashboard only draws the window.
Standard library only.
"""
import datetime
import json
import math
import os
import re
import urllib.error
import urllib.parse
import urllib.request

LAST = 10
INTERVAL_MS = 5000
URL_ENV = "PO_DASHBOARD_URL"
TEAM_URL_ENV = "PO_DASHBOARD_TEAM_URL"
FADE_SECONDS = 60
FADE_STEPS = 60  # one CSS class per step, po-fade-<n>: n steps of highlight left
FADE_AMOUNT = 0.25  # a new card starts 25% darker (lighter in the dark theme)
CUES = {"pass": "✔ pass", "fail": "✘ fail", "skip": "– skip"}  # check, cross, en dash


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
    env = os.environ if env is None else env
    url = (arg or env.get(TEAM_URL_ENV) or "").strip()
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


def legs_text(legs):
    if not isinstance(legs, list):
        return ""
    return " ".join(
        "%s:%s" % (l.get("name", "?"), l.get("result", "?")) if isinstance(l, dict) else str(l) for l in legs
    )


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
        "time": local_time(event.get("time"), tz),
        "legs": legs_text(event.get("legs")),
        "detail": str(event.get("detail") or ""),
    }


def rows(events, show_all, tz=None):
    return [row(e, tz) for e in visible(events, show_all)]


def check_lines(events, show_all=False, tz=None):
    """What the window would show, one ' | ' line per event (po-dashboard --check)."""
    return [" | ".join((r["item"], r["project"], r["kind"], r["result"], r["agent"], r["time"])) for r in rows(events, show_all, tz)]


# ---- the team view ---------------------------------------------------------


def parse_team(text):
    """The team feed: a JSON array of {agent, model?, state, now, owns[], free}. Raises DashboardError."""
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


def team_row(entry):
    """One agent as the strings a team line shows; state is shown as given."""
    state = str(entry.get("state") or "")
    owns = entry.get("owns")
    owns = [str(o) for o in owns] if isinstance(owns, list) else []
    now = entry.get("now")
    model = entry.get("model")
    return {
        "agent": str(entry.get("agent") or "?"),
        "model": model.strip() if isinstance(model, str) else "",
        "state": state or "?",
        "working": state.strip().upper().startswith("WORKING"),
        "now": "" if now in (None, "") else str(now),
        "owns": ", ".join(owns),
        "free": bool(entry.get("free")),
    }


def team_rows(entries):
    return [team_row(e) for e in entries]


def team_check_lines(entries):
    """What the Team view would show, one ' | ' line per agent; a model follows the name after ' · '."""
    return [
        " | ".join((r["agent"] + (" \u00b7 " + r["model"] if r["model"] else ""), r["state"], "now: " + (r["now"] or "-"), "owns: " + (r["owns"] or "-"), "FREE" if r["free"] else ""))
        for r in team_rows(entries)
    ]


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


FADE_TEXT = (("po-text", "text"), ("po-muted", "muted"), ("po-note", "muted"),
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
        "pass": "#13693a", "fail": "#a8201a", "skip": "#5a5f66",
    },
    "dark": {
        "base": "#2b2f36", "light": "#383d46", "dark": "#1e2126",
        "text": "#e8ebf0", "muted": "#aab2bf",
        "pass": "#6fdc9a", "fail": "#ff9a94", "skip": "#aab2bf",
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
.po-note { color: %(muted)s; }
.po-note:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
.po-pass { color: %(pass)s; font-weight: 700; }
.po-fail { color: %(fail)s; font-weight: 700; }
.po-skip { color: %(skip)s; font-weight: 700; }
.po-live { color: %(pass)s; font-weight: 700; }
.po-free { color: %(pass)s; font-weight: 700; border-radius: 10px; padding: 2px 10px;
  box-shadow: inset 3px 3px 6px %(dark)s, inset -3px -3px 6px %(light)s; }
.po-view { background-color: %(base)s; background-image: none; color: %(text)s; border: none; border-radius: 14px;
  padding: 8px 16px; box-shadow: 4px 4px 8px %(dark)s, -4px -4px 8px %(light)s; }
.po-view:checked { box-shadow: inset 4px 4px 8px %(dark)s, inset -4px -4px 8px %(light)s; }
.po-view:focus-visible { outline: 2px solid %(text)s; outline-offset: 2px; }
"""

# (foreground selector, background selector, role): each pair must reach 4.5:1.
CONTRAST_PAIRS = [
    (".po-text", ".po-card", "card text"),
    (".po-muted", ".po-card", "card detail text"),
    (".po-note", ".po-card", "note icon"),
    (".po-pass", ".po-card", "pass status"),
    (".po-fail", ".po-card", "fail status"),
    (".po-skip", ".po-card", "skip status"),
    (".po-live", ".po-card", "working dot"),
    (".po-free", ".po-card", "free badge"),
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
