#!/usr/bin/env python3

import base64
import ctypes
import json
import math
import os
import sys
import time
import traceback
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning)

import gi

gi.require_version("Atspi", "2.0")

try:
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk
except (ImportError, ValueError):
    Gdk = None

from gi.repository import Atspi


MAX_ELEMENTS = 1200
MAX_DEPTH = 64
DEFAULT_TEXT_LIMIT = 500

# pi-phone fork: password fields are marked in the outline, their text is never
# read, and input into them is refused unless the host opts out with
# OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT=1.
PASSWORD_ROLE = "password text"
PASSWORD_MARKER = "[password]"
PASSWORD_REFUSAL = (
    "Refused: the target is a password field. Open Computer Use (pi-phone build) does not type "
    "into password fields; set OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT=1 to allow it."
)

# pi-phone fork: the states an element line may carry ("States: checked, focused"), in this order.
STATE_ORDER = ("checked", "selected", "expanded", "collapsed", "focused", "disabled", "readonly", "secure")
# Roles that hold text a person can edit: without EDITABLE they are read-only.
EDITABLE_ROLES = {"text", "entry", "password text", "spin button", "editbar"}
ATSPI_PATH_PREFIX = "/org/a11y/atspi/accessible/"


class OCUError(RuntimeError):
    """pi-phone fork: a refusal or failure with a machine-readable code.

    Codes: stale_ref, ambiguous_target, policy_denied, covered, not_found, password_field. Each is raised
    before anything reaches the app, so retrying after a fresh read is safe.
    """

    def __init__(self, code, message, suggestion=""):
        super().__init__(message)
        self.code = code
        self.suggestion = suggestion


def frame(x, y, width, height):
    if width is None or height is None or width < 0 or height < 0:
        return None
    return {
        "x": float(x),
        "y": float(y),
        "width": float(width),
        "height": float(height),
    }


def safe(call, default=None):
    try:
        value = call()
        if value is None:
            return default
        return value
    except Exception:
        return default


def supports_interface(node, interface_name):
    interfaces = safe(lambda: node.get_interfaces(), [])
    expected = str(interface_name).casefold()
    return any(str(interface).casefold() == expected for interface in interfaces)


def require_desktop_session():
    missing = []
    if not os.environ.get("XDG_RUNTIME_DIR"):
        missing.append("XDG_RUNTIME_DIR")
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        missing.append("DBUS_SESSION_BUS_ADDRESS")
    if missing:
        raise RuntimeError(
            "Linux runtime requires an active desktop session; missing "
            + ", ".join(missing)
        )


def desktop():
    return Atspi.get_desktop(0)


def child_count(node):
    return int(safe(node.get_child_count, 0) or 0)


def child_at(node, index):
    return safe(lambda: node.get_child_at_index(index))


def node_name(node):
    return str(safe(node.get_name, "") or "")


def limit_text(value, text_limit=DEFAULT_TEXT_LIMIT):
    text = str(value or "")
    if text_limit is None:
        return text
    if len(text) > text_limit:
        return text[:text_limit] + "..."
    return text


def node_role(node):
    return str(safe(node.get_role_name, "") or "")


def is_password(node):
    """AT-SPI ROLE_PASSWORD_TEXT (GTK, Qt, Chromium and Firefox password inputs)."""
    if node is None:
        return False
    try:
        return node_role(node) == PASSWORD_ROLE
    except Exception:
        return False


def password_input_allowed():
    value = os.environ.get("OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT", "")
    return value.strip().lower() in {"1", "true", "yes", "on"}


def focused_node(root):
    """The focused descendant of root, or None when there is none or it cannot be read."""
    try:
        focused_state = Atspi.StateType.FOCUSED
        return find_first(root, lambda node: state_contains(node, focused_state))
    except Exception:
        return None


def refuse_password_input(node, allowed=False):
    """allowed: this call opted out (allow_password_input), a person typing their own password."""
    if is_password(node) and not allowed and not password_input_allowed():
        raise OCUError("password_field", PASSWORD_REFUSAL)


def node_pid(node):
    value = safe(node.get_process_id, 0)
    try:
        return int(value or 0)
    except Exception:
        return 0


def state_contains(node, state):
    state_set = safe(node.get_state_set)
    if state_set is None:
        return False
    return bool(safe(lambda: state_set.contains(state), False))


def extents(node):
    component = safe(node.get_component_iface)
    if component is None:
        return None
    rect = safe(lambda: Atspi.Component.get_extents(component, Atspi.CoordType.SCREEN))
    if (
        rect is None
        or rect.width <= 0
        or rect.height <= 0
        or rect.width > 100000
        or rect.height > 100000
    ):
        return None
    return frame(rect.x, rect.y, rect.width, rect.height)


def relative_frame(node, window_bounds):
    bounds = extents(node)
    if bounds is None:
        return None
    if window_bounds is None:
        return bounds
    return frame(
        bounds["x"] - window_bounds["x"],
        bounds["y"] - window_bounds["y"],
        bounds["width"],
        bounds["height"],
    )


def iter_apps():
    root = desktop()
    apps = []
    for index in range(child_count(root)):
        app = child_at(root, index)
        if app is not None and node_name(app):
            apps.append(app)
    return apps


def app_windows(app):
    windows = []
    for index in range(child_count(app)):
        child = child_at(app, index)
        if child is None:
            continue
        role = node_role(child).lower()
        bounds = extents(child)
        if role in {"frame", "window", "dialog", "alert"} or bounds is not None:
            windows.append((index, child))
    return windows


def main_window(app):
    windows = app_windows(app)
    if not windows:
        raise RuntimeError(
            "No top-level AT-SPI window is available for " + node_name(app)
        )
    for index, window in windows:
        if state_contains(window, Atspi.StateType.ACTIVE):
            return index, window
    for index, window in windows:
        if state_contains(window, Atspi.StateType.SHOWING):
            return index, window
    return windows[0]


def matches_query(app, query):
    normalized = query.strip().lower()
    if not normalized:
        return False
    if normalized.isdigit() and node_pid(app) == int(normalized):
        return True
    app_name = node_name(app).lower()
    if app_name == normalized or normalized in app_name:
        return True
    for _, window in app_windows(app):
        title = node_name(window).lower()
        if title == normalized or normalized in title:
            return True
    return False


def resolve_app(query):
    for app in iter_apps():
        if matches_query(app, query):
            return app
    raise OCUError("not_found", 'appNotFound("{}")'.format(query))


def object_path(node):
    """pi-phone fork: the AT-SPI object path, stable while the object lives; a new object gets a new one."""
    value = safe(lambda: node.path, "")
    return value if isinstance(value, str) else ""


def window_id_of(app, window):
    """pi-phone fork: '<pid>:<object id>', unique on the desktop while the window lives; '' when unknown."""
    path = object_path(window)
    if not path:
        return ""
    if path.startswith(ATSPI_PATH_PREFIX):
        path = path[len(ATSPI_PATH_PREFIX):]
    return "{}:{}".format(node_pid(app), path)


def matching_apps(query):
    """pi-phone fork: every app the query matches, in desktop order (resolve_app takes the first)."""
    return [app for app in iter_apps() if matches_query(app, query)]


def find_window(query, window_id, apps=None):
    """The (app, index, window) with this window id, of an app the query matches; None when it is gone."""
    pid_text = str(window_id).partition(":")[0]
    for app in (iter_apps() if apps is None else apps):
        if str(node_pid(app)) != pid_text or (apps is None and not matches_query(app, query)):
            continue
        for index, window in app_windows(app):
            if window_id_of(app, window) == window_id:
                return app, index, window
    return None


def other_windows(apps, chosen_id, limit=8):
    """pi-phone fork: the other windows of the apps the query matches, to pick one by window_id."""
    others = []
    for app in apps:
        for _, window in app_windows(app):
            window_id = window_id_of(app, window)
            if window_id and window_id != chosen_id and len(others) < limit:
                others.append({"id": window_id, "title": limit_text(node_name(window), 80), "app": node_name(app)})
    return others


def resolve_target(query, window_id=None, stale=False, apps=None):
    """pi-phone fork: the app and window to read or act in (apps: matching_apps(query), if read already).

    With a window id, that window or nothing: not_found for a read (the caller named it), stale_ref for an
    action (the snapshot's window was closed or replaced). Without one, the app's main window, as upstream.
    """
    if window_id:
        found = find_window(query, window_id, apps)
        if found is None:
            if stale:
                raise OCUError(
                    "stale_ref",
                    "The window {} that the snapshot read is gone or was replaced.".format(window_id),
                )
            raise OCUError("not_found", "No window {} of an app matching {!r}.".format(window_id, query))
        return found
    if apps is None:
        app = resolve_app(query)
    elif apps:
        app = apps[0]
    else:
        raise OCUError("not_found", 'appNotFound("{}")'.format(query))
    index, window = main_window(app)
    return app, index, window


def action_names(node):
    names = []
    count = int(safe(node.get_n_actions, 0) or 0)
    for index in range(count):
        name = str(safe(lambda i=index: node.get_action_name(i), "") or "")
        description = str(
            safe(lambda i=index: node.get_action_description(i), "") or ""
        )
        label = name or description
        if label and label not in names:
            names.append(label)
    return names


def accessible_id(node):
    return str(safe(node.get_accessible_id, "") or "")


def text_value(node, text_limit=DEFAULT_TEXT_LIMIT):
    if not supports_interface(node, "Text"):
        return ""
    text_iface = safe(node.get_text_iface)
    if text_iface is None:
        return ""
    count = int(safe(lambda: Atspi.Text.get_character_count(text_iface), 0) or 0)
    if count <= 0:
        return ""
    end_offset = count if text_limit is None else min(count, text_limit + 1)
    value = str(safe(lambda: Atspi.Text.get_text(text_iface, 0, end_offset), "") or "")
    return limit_text(value, text_limit=text_limit)


def numeric_value(node):
    value_iface = safe(node.get_value_iface)
    if value_iface is None:
        return ""
    current = safe(lambda: Atspi.Value.get_current_value(value_iface))
    if current is None:
        return ""
    return str(current)


def element_value(node, text_limit=DEFAULT_TEXT_LIMIT):
    return text_value(node, text_limit=text_limit) or numeric_value(node)


def positive_int(value, fallback):
    if isinstance(value, bool):
        return fallback
    if isinstance(value, float) and not value.is_integer():
        return fallback
    try:
        integer = int(value)
    except (TypeError, ValueError):
        return fallback
    return integer if integer > 0 else fallback


def parse_text_limit(value, fallback=DEFAULT_TEXT_LIMIT):
    if isinstance(value, str) and value.lower() == "max":
        return None
    return positive_int(value, fallback)


def element_states(state_set, role):
    """pi-phone fork: the element's states from its AT-SPI StateSet, as STATE_ORDER names."""
    if state_set is None:
        return []
    nicks = set()
    try:
        for state in state_set.get_states() or []:
            nick = safe(lambda s=state: s.value_nick, "")
            if isinstance(nick, str) and nick:
                nicks.add(nick)
    except Exception:
        return []
    if not nicks:
        # An empty set says nothing (a defunct object): no "disabled" for it.
        return []
    found = set()
    if "checked" in nicks:
        found.add("checked")
    if "selected" in nicks:
        found.add("selected")
    if "expanded" in nicks:
        found.add("expanded")
    elif "expandable" in nicks:
        found.add("collapsed")
    if "focused" in nicks:
        found.add("focused")
    if "enabled" not in nicks and "sensitive" not in nicks:
        found.add("disabled")
    if "read-only" in nicks or (role in EDITABLE_ROLES and "editable" not in nicks):
        found.add("readonly")
    if role == PASSWORD_ROLE:
        found.add("secure")
    return [name for name in STATE_ORDER if name in found]


def record_for(node, index, path, window_bounds, text_limit=DEFAULT_TEXT_LIMIT, lightweight_hidden=False):
    # Only an explicit non-SHOWING state qualifies. Errors/unknown state keep
    # full details; geometry alone cannot prove that a menu/control is hidden.
    # pi-phone fork: one StateSet read serves both the SHOWING check and the element's states.
    state_set = safe(node.get_state_set)
    showing = None
    if lightweight_hidden and state_set is not None:
        showing = safe(lambda: state_set.contains(Atspi.StateType.SHOWING))
    omit_details = showing is not None and not bool(showing)
    bounds = None if omit_details else relative_frame(node, window_bounds)
    role = node_role(node)
    password = role == PASSWORD_ROLE
    value = "" if omit_details or password else element_value(node, text_limit=text_limit)
    states = [] if omit_details else element_states(state_set, role)
    return {
        "index": index,
        "runtimeId": path[:],
        "automationId": "" if omit_details else accessible_id(node),
        "name": limit_text(node_name(node), text_limit=text_limit),
        "controlType": role,
        "localizedControlType": role,
        "className": "" if omit_details else str(safe(node.get_toolkit_name, "") or ""),
        "value": value,
        "nativeWindowHandle": 0,
        "frame": bounds,
        "actions": [] if omit_details else action_names(node),
        **({"objectPath": object_path(node)} if object_path(node) else {}),
        **({"states": states} if states else {}),
        **({"detailsOmitted": True} if omit_details else {}),
        **({"isPassword": True} if password else {}),
    }


def render_tree(root, window_bounds, root_path, text_limit=DEFAULT_TEXT_LIMIT, max_tree_nodes=MAX_ELEMENTS, max_tree_depth=MAX_DEPTH):
    records = []
    lines = []
    lightweight_hidden = os.environ.get("OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN", "").strip().lower() in {"1", "true", "yes", "on"}

    def visit(node, depth, path):
        if len(records) >= max_tree_nodes or depth > max_tree_depth or node is None:
            return
        index = len(records)
        record = record_for(node, index, path, window_bounds, text_limit=text_limit, lightweight_hidden=lightweight_hidden)
        records.append(record)

        role = record["localizedControlType"] or record["controlType"] or "element"
        title = record["name"] or record["automationId"] or ""
        if record.get("detailsOmitted"):
            title += " [hidden details omitted]"
        if record.get("isPassword"):
            title = (title + " " + PASSWORD_MARKER).strip()
        value_segment = ""
        if record["value"] and record["value"] != title:
            safe_value = record["value"].replace("\r", "\\r").replace("\n", "\\n")
            value_segment = " Value: " + safe_value
        actions_segment = ""
        if record["actions"]:
            actions_segment = " Secondary Actions: " + ", ".join(record["actions"])
        if record.get("states"):
            actions_segment += " States: " + ", ".join(record["states"])
        frame_segment = ""
        if record["frame"] is not None:
            f = record["frame"]
            frame_segment = " Frame: {{x: {0}, y: {1}, width: {2}, height: {3}}}".format(
                round(f["x"]),
                round(f["y"]),
                round(f["width"]),
                round(f["height"]),
            )
        lines.append(
            ("\t" * (depth + 1))
            + "{} {} {}{}{}{}".format(
                index, role, title, value_segment, actions_segment, frame_segment
            ).rstrip()
        )

        for child_index in range(child_count(node)):
            child = child_at(node, child_index)
            visit(child, depth + 1, path + [child_index])

    visit(root, 0, root_path)
    return records, lines


# pi-phone fork (PP-271): a window screenshot is a copy of the screen inside the window's rectangle, so
# whatever sits above the window shows in it. The X11 stacking order says what is above: those parts are
# blacked out and reported ("covered"); a minimised or fully covered window gets no picture.


def intersect(a, b):
    """The overlap of two {x, y, width, height} rectangles, or None."""
    left = max(a["x"], b["x"])
    top = max(a["y"], b["y"])
    right = min(a["x"] + a["width"], b["x"] + b["width"])
    bottom = min(a["y"] + a["height"], b["y"] + b["height"])
    if right <= left or bottom <= top:
        return None
    return frame(left, top, right - left, bottom - top)


def union_area(rects):
    """The area the rectangles cover together, counting overlaps once."""
    xs = sorted({value for r in rects for value in (r["x"], r["x"] + r["width"])})
    ys = sorted({value for r in rects for value in (r["y"], r["y"] + r["height"])})
    area = 0.0
    for i in range(len(xs) - 1):
        for j in range(len(ys) - 1):
            cx, cy = (xs[i] + xs[i + 1]) / 2, (ys[j] + ys[j + 1]) / 2
            if any(r["x"] <= cx < r["x"] + r["width"] and r["y"] <= cy < r["y"] + r["height"] for r in rects):
                area += (xs[i + 1] - xs[i]) * (ys[j + 1] - ys[j])
    return area


ALL_DESKTOPS = 0xFFFFFFFF


def compute_cover(stack, target_id, bounds, current_desktop=None):
    """What covers the window's screen rectangle (bounds), from a stacking list ordered bottom to top.

    Each entry: {id, rect, viewable, hidden, input_only, desktop}. Returns {state, covered}, where state is
    clear, partial, full, minimized or unknown, and covered lists the covered parts in window coordinates.
    """
    position = next((i for i, entry in enumerate(stack) if entry["id"] == target_id), None)
    if position is None or bounds is None:
        return {"state": "unknown", "covered": []}
    target = stack[position]
    if not target.get("viewable", True) or target.get("hidden"):
        return {"state": "minimized", "covered": []}
    covered = []
    for entry in stack[position + 1:]:
        if not entry.get("viewable", True) or entry.get("hidden") or entry.get("input_only"):
            continue
        desktop = entry.get("desktop")
        if desktop is not None and desktop != ALL_DESKTOPS and current_desktop is not None and desktop != current_desktop:
            continue
        overlap = intersect(entry["rect"], bounds)
        if overlap is None:
            continue
        local = frame(
            round(overlap["x"] - bounds["x"]),
            round(overlap["y"] - bounds["y"]),
            round(overlap["width"]),
            round(overlap["height"]),
        )
        if local not in covered:
            covered.append(local)
    if not covered:
        return {"state": "clear", "covered": []}
    whole = frame(0, 0, round(bounds["width"]), round(bounds["height"]))
    full = union_area(covered) >= whole["width"] * whole["height"]
    return {"state": "full" if full else "partial", "covered": covered}


def match_client(clients, pid, title, bounds):
    """The one X11 client window that is this AT-SPI window (same process, then title, then rectangle)."""
    candidates = [c for c in clients if c.get("pid") == pid and not c.get("override")]
    named = [c for c in candidates if title and c.get("name") == title]
    if len(named) == 1:
        return named[0]["id"]
    pool = named or candidates
    if bounds is not None:
        def near(rect):
            return rect is not None and all(abs(rect[key] - bounds[key]) <= 2 for key in ("x", "y", "width", "height"))
        placed = [c for c in pool if near(c.get("client")) or near(c.get("rect"))]
        if len(placed) == 1:
            return placed[0]["id"]
    if len(pool) == 1:
        return pool[0]["id"]
    return None


class _XWindowAttributes(ctypes.Structure):
    _fields_ = [
        ("x", ctypes.c_int), ("y", ctypes.c_int), ("width", ctypes.c_int), ("height", ctypes.c_int),
        ("border_width", ctypes.c_int), ("depth", ctypes.c_int), ("visual", ctypes.c_void_p),
        ("root", ctypes.c_ulong), ("window_class", ctypes.c_int), ("bit_gravity", ctypes.c_int),
        ("win_gravity", ctypes.c_int), ("backing_store", ctypes.c_int), ("backing_planes", ctypes.c_ulong),
        ("backing_pixel", ctypes.c_ulong), ("save_under", ctypes.c_int), ("colormap", ctypes.c_ulong),
        ("map_installed", ctypes.c_int), ("map_state", ctypes.c_int), ("all_event_masks", ctypes.c_long),
        ("your_event_mask", ctypes.c_long), ("do_not_propagate_mask", ctypes.c_long),
        ("override_redirect", ctypes.c_int), ("screen", ctypes.c_void_p),
    ]


_X_ERROR_HANDLER = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p)
IS_VIEWABLE = 2
INPUT_ONLY = 2


class X11Display:
    """A small read-only Xlib client (ctypes): window stacking, properties and geometry."""

    def __init__(self):
        lib = ctypes.CDLL("libX11.so.6")
        lib.XOpenDisplay.restype = ctypes.c_void_p
        lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        lib.XDefaultRootWindow.restype = ctypes.c_ulong
        lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        lib.XInternAtom.restype = ctypes.c_ulong
        lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
        lib.XGetWindowProperty.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_long, ctypes.c_long, ctypes.c_int,
            ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int),
            ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_void_p),
        ]
        lib.XGetWindowAttributes.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(_XWindowAttributes)]
        lib.XTranslateCoordinates.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_int, ctypes.c_int,
            ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_int), ctypes.POINTER(ctypes.c_ulong),
        ]
        lib.XQueryTree.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(ctypes.c_uint),
        ]
        lib.XFree.argtypes = [ctypes.c_void_p]
        lib.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        lib.XSetErrorHandler.restype = ctypes.c_void_p
        lib.XSetErrorHandler.argtypes = [ctypes.c_void_p]
        self.lib = lib
        # A window can go away between two requests: Xlib's default handler would end the process.
        self._handler = _X_ERROR_HANDLER(lambda _display, _event: 0)
        self._previous = lib.XSetErrorHandler(ctypes.cast(self._handler, ctypes.c_void_p))
        self.display = lib.XOpenDisplay(None)
        if not self.display:
            lib.XSetErrorHandler(self._previous)
            raise RuntimeError("X11 display unavailable")
        self.root = lib.XDefaultRootWindow(self.display)
        self._atoms = {}

    def close(self):
        if self.display:
            self.lib.XSync(self.display, 0)
            self.lib.XCloseDisplay(self.display)
            self.display = None
        self.lib.XSetErrorHandler(self._previous)

    def atom(self, name):
        if name not in self._atoms:
            self._atoms[name] = self.lib.XInternAtom(self.display, name.encode(), 1)
        return self._atoms[name]

    def prop(self, window, name):
        """(format, values): 32-bit items as ints, 8-bit as bytes; (0, None) when absent."""
        atom = self.atom(name)
        if not atom:
            return 0, None
        actual_type, actual_format = ctypes.c_ulong(), ctypes.c_int()
        count, after, data = ctypes.c_ulong(), ctypes.c_ulong(), ctypes.c_void_p()
        status = self.lib.XGetWindowProperty(
            self.display, window, atom, 0, 4096, 0, 0, ctypes.byref(actual_type), ctypes.byref(actual_format),
            ctypes.byref(count), ctypes.byref(after), ctypes.byref(data),
        )
        if status != 0 or not data.value:
            return 0, None
        try:
            if actual_format.value == 32:
                # Xlib hands 32-bit items to clients as C longs.
                items = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))
                return 32, [items[i] & 0xFFFFFFFF for i in range(count.value)]
            if actual_format.value == 8:
                return 8, ctypes.string_at(data, count.value)
            return actual_format.value, None
        finally:
            self.lib.XFree(data)

    def cardinal(self, window, name):
        _, values = self.prop(window, name)
        return values[0] if isinstance(values, list) and values else None

    def text(self, window):
        _, value = self.prop(window, "_NET_WM_NAME")
        if not value:
            _, value = self.prop(window, "WM_NAME")
        return value.decode("utf-8", "replace") if isinstance(value, bytes) else ""

    def attributes(self, window):
        attrs = _XWindowAttributes()
        if not self.lib.XGetWindowAttributes(self.display, window, ctypes.byref(attrs)):
            return None
        return attrs

    def children(self, window):
        root, parent = ctypes.c_ulong(), ctypes.c_ulong()
        data, count = ctypes.c_void_p(), ctypes.c_uint()
        if not self.lib.XQueryTree(self.display, window, ctypes.byref(root), ctypes.byref(parent),
                                   ctypes.byref(data), ctypes.byref(count)):
            return None, []
        try:
            if not data.value:
                return parent.value, []
            items = ctypes.cast(data, ctypes.POINTER(ctypes.c_ulong))
            return parent.value, [items[i] for i in range(count.value)]
        finally:
            if data.value:
                self.lib.XFree(data)

    def top_level(self, window):
        """The child of the root window that holds this window (its frame, under a reparenting manager)."""
        for _ in range(16):
            parent, _ = self.children(window)
            if parent is None or parent == 0:
                return None
            if parent == self.root:
                return window
            window = parent
        return None

    def entry(self, window):
        """One window as compute_cover and match_client read it, with its frame (decorations) around it."""
        attrs = self.attributes(window)
        if attrs is None:
            return None
        x, y, child = ctypes.c_int(), ctypes.c_int(), ctypes.c_ulong()
        self.lib.XTranslateCoordinates(self.display, window, self.root, 0, 0, ctypes.byref(x), ctypes.byref(y),
                                       ctypes.byref(child))
        client = frame(x.value, y.value, attrs.width, attrs.height)
        _, extents = self.prop(window, "_NET_FRAME_EXTENTS")
        left, right, top, bottom = (extents + [0, 0, 0, 0])[:4] if isinstance(extents, list) else (0, 0, 0, 0)
        border = attrs.border_width
        _, states = self.prop(window, "_NET_WM_STATE")
        hidden_atom = self.atom("_NET_WM_STATE_HIDDEN")
        return {
            "id": window,
            "client": client,
            "rect": frame(
                client["x"] - left - border,
                client["y"] - top - border,
                client["width"] + left + right + 2 * border,
                client["height"] + top + bottom + 2 * border,
            ),
            "viewable": attrs.map_state == IS_VIEWABLE,
            "input_only": attrs.window_class == INPUT_ONLY,
            "override": bool(attrs.override_redirect),
            "hidden": bool(hidden_atom) and isinstance(states, list) and hidden_atom in states,
            "desktop": self.cardinal(window, "_NET_WM_DESKTOP"),
            "pid": self.cardinal(window, "_NET_WM_PID"),
            "name": self.text(window),
        }

    def stack(self):
        """Top-level windows bottom to top: the manager's stacking list plus override-redirect windows."""
        _, root_children = self.children(self.root)
        _, managed = self.prop(self.root, "_NET_CLIENT_LIST_STACKING")
        if not isinstance(managed, list):
            # No window manager: the root's children are the clients, in stacking order.
            return [entry for entry in (self.entry(w) for w in root_children) if entry is not None], root_children
        return [entry for entry in (self.entry(w) for w in managed) if entry is not None], root_children

    def override_entry(self, window):
        """The entry of a mapped override-redirect window (a menu, a tooltip), else None."""
        attrs = self.attributes(window)
        if attrs is None or not attrs.override_redirect or attrs.map_state != IS_VIEWABLE or attrs.window_class == INPUT_ONLY:
            return None
        return self.entry(window)


def read_window_cover(pid, title, bounds):
    """compute_cover for an AT-SPI window, from the live X11 display; unknown when it cannot be read."""
    if bounds is None or not os.environ.get("DISPLAY"):
        return {"state": "unknown", "covered": []}
    try:
        display = X11Display()
    except Exception:
        return {"state": "unknown", "covered": []}
    try:
        stack, root_children = display.stack()
        target = match_client(stack, pid, title, bounds)
        if target is None:
            return {"state": "unknown", "covered": []}
        top = display.top_level(target)
        if top in root_children:
            # Menus, tooltips and other override-redirect windows above the target's frame paint over it
            # too (without a window manager they are in the stack already).
            known = {entry["id"] for entry in stack}
            for window in root_children[root_children.index(top) + 1:]:
                if window not in known:
                    entry = display.override_entry(window)
                    if entry is not None:
                        stack.append(entry)
        return compute_cover(stack, target, bounds, display.cardinal(display.root, "_NET_CURRENT_DESKTOP"))
    except Exception:
        return {"state": "unknown", "covered": []}
    finally:
        display.close()


def black_out(pixbuf, covered):
    """Paint the covered parts of a window picture black (they show other windows)."""
    width, height = pixbuf.get_width(), pixbuf.get_height()
    for rect in covered:
        left, top = max(0, int(rect["x"])), max(0, int(rect["y"]))
        right = min(width, int(rect["x"] + rect["width"]))
        bottom = min(height, int(rect["y"] + rect["height"]))
        if right > left and bottom > top:
            pixbuf.new_subpixbuf(left, top, right - left, bottom - top).fill(0x000000FF)


def capture_window_png(bounds, covered=()):
    if Gdk is None or bounds is None:
        return None
    try:
        screen = Gdk.Screen.get_default()
        if screen is None:
            return None
        root = screen.get_root_window()
        pixbuf = Gdk.pixbuf_get_from_window(
            root,
            int(round(bounds["x"])),
            int(round(bounds["y"])),
            max(1, int(round(bounds["width"]))),
            max(1, int(round(bounds["height"]))),
        )
        if pixbuf is None:
            return None
        if pixbuf_looks_black(pixbuf):
            return None
        black_out(pixbuf, covered)
        ok, data = pixbuf.save_to_bufferv("png", [], [])
        if not ok:
            return None
        return base64.b64encode(bytes(data)).decode("ascii")
    except Exception:
        return None


def pixbuf_looks_black(pixbuf):
    try:
        pixels = pixbuf.get_pixels()
        channels = pixbuf.get_n_channels()
        rowstride = pixbuf.get_rowstride()
        width = pixbuf.get_width()
        height = pixbuf.get_height()
        if width <= 0 or height <= 0 or channels < 3:
            return True
        step_x = max(1, width // 16)
        step_y = max(1, height // 16)
        checked = 0
        for y in range(0, height, step_y):
            row = y * rowstride
            for x in range(0, width, step_x):
                offset = row + (x * channels)
                if (
                    pixels[offset] > 3
                    or pixels[offset + 1] > 3
                    or pixels[offset + 2] > 3
                ):
                    return False
                checked += 1
        return checked > 0
    except Exception:
        return False


def focus_details(window, text_limit=DEFAULT_TEXT_LIMIT, max_nodes=MAX_ELEMENTS, max_depth=MAX_DEPTH):
    """Find focus once, within the same node/depth budget as the snapshot."""
    visited = 0
    truncated = False

    def visit(node, depth):
        nonlocal visited, truncated
        if visited >= max_nodes or depth > max_depth:
            truncated = True
            return None
        visited += 1
        if node is None:
            return None
        if state_contains(node, Atspi.StateType.FOCUSED):
            return node
        children = child_count(node)
        if depth >= max_depth:
            # Do not fetch children that cannot be visited. Otherwise a wide
            # node at the depth boundary can bypass the node budget entirely.
            truncated = truncated or children > 0
            return None
        for index in range(children):
            if visited >= max_nodes:
                truncated = True
                break
            found = visit(child_at(node, index), depth + 1)
            if found is not None:
                return found
        return None

    focused = visit(window, 0)
    if focused is None:
        return None, None, truncated
    summary = (node_role(focused) + " " + limit_text(node_name(focused), text_limit)).strip()
    selection = None
    if is_password(focused):
        # The marker tells the host that typing now would go into a password field;
        # its selection is never read.
        return summary + " " + PASSWORD_MARKER, None, False
    if supports_interface(focused, "Text"):
        text_iface = safe(focused.get_text_iface)
        count = safe(lambda: Atspi.Text.get_n_selections(text_iface), 0)
        selected = safe(lambda: Atspi.Text.get_selection(text_iface, 0)) if count > 0 else None
        if selected is not None:
            end = selected.end_offset
            if text_limit is not None:
                end = min(end, selected.start_offset + text_limit + 1)
            selection = safe(lambda: Atspi.Text.get_text(text_iface, selected.start_offset, end))
            if selection is not None:
                selection = limit_text(selection, text_limit)
    return summary, selection, False


def build_snapshot(query, text_limit=DEFAULT_TEXT_LIMIT, max_tree_nodes=MAX_ELEMENTS, max_tree_depth=MAX_DEPTH, include_ax=True, include_screenshot=True, window_id=None):
    # One pass over the desktop's apps finds the target and the other windows the query matches.
    apps = matching_apps(query)
    app, window_index, window = resolve_target(query, window_id, apps=apps)
    bounds = extents(window)
    chosen_id = window_id_of(app, window)
    cover = {"state": "unknown", "covered": []}
    image = None
    if include_screenshot:
        cover = read_window_cover(node_pid(app), node_name(window), bounds)
        if cover["state"] not in ("full", "minimized"):
            image = capture_window_png(bounds, cover["covered"])
    records, lines = [], []
    focus, selection = None, None
    if include_ax:
        records, lines = render_tree(
            window,
            bounds,
            [window_index],
            text_limit=text_limit,
            max_tree_nodes=max_tree_nodes,
            max_tree_depth=max_tree_depth,
        )
        focus, selection, focus_truncated = focus_details(window, text_limit, max_tree_nodes, max_tree_depth)
        if focus_truncated:
            lines.append("[Focus search incomplete: node/depth budget reached.]")
    pid = node_pid(app)
    return {
        "app": {
            "name": node_name(app),
            "bundleIdentifier": node_name(app),
            "pid": pid,
        },
        "windowTitle": limit_text(node_name(window), text_limit=text_limit),
        "windowBounds": bounds,
        "windowId": chosen_id,
        "otherWindows": other_windows(apps, chosen_id),
        **({"cover": cover["state"], "covered": cover["covered"]} if include_screenshot else {}),
        "screenshotPngBase64": image,
        "treeLines": lines,
        "focusedSummary": focus,
        "selectedText": selection,
        "elements": records,
    }


def list_apps_text():
    lines = []
    for app in sorted(iter_apps(), key=lambda item: (node_name(item).lower(), node_pid(item))):
        windows = app_windows(app)
        if not windows:
            continue
        title = node_name(windows[0][1]) or "untitled"
        name = node_name(app)
        lines.append(
            "{} -- {} [running, pid={}, window={}]".format(
                name, name, node_pid(app), title
            )
        )
    return "\n".join(lines)


def find_first(root, predicate):
    if root is None:
        return None
    if predicate(root):
        return root
    for index in range(child_count(root)):
        found = find_first(child_at(root, index), predicate)
        if found is not None:
            return found
    return None


def iter_all(root):
    items = []

    def visit(node):
        if node is None or len(items) >= MAX_ELEMENTS:
            return
        items.append(node)
        for index in range(child_count(node)):
            visit(child_at(node, index))

    visit(root)
    return items


def resolve_path(app, path):
    if not path:
        return None
    node = app
    for index in path:
        node = child_at(node, int(index))
        if node is None:
            return None
    return node


def names_match(recorded, live):
    """A name as the snapshot recorded it (perhaps cut to text_limit, ending in ...) against the live one."""
    recorded, live = str(recorded or ""), str(live or "")
    if recorded == live:
        return True
    return recorded.endswith("...") and len(live) > len(recorded) - 3 and live.startswith(recorded[:-3])


def element_matches(node, record):
    """pi-phone fork: whether a live element is the one the snapshot saw: role, name, actions, object path."""
    if node is None:
        return False
    if node_role(node) != str(record.get("controlType") or ""):
        return False
    if not names_match(record.get("name"), node_name(node)):
        return False
    recorded_path = str(record.get("objectPath") or "")
    if recorded_path and object_path(node) and object_path(node) != recorded_path:
        return False
    if not record.get("detailsOmitted") and list(record.get("actions") or []) != action_names(node):
        return False
    return True


def stale_element(record, why):
    return OCUError(
        "stale_ref",
        "[{}] is no longer the {} {!r} that the snapshot saw ({}).".format(
            record.get("index"), record.get("controlType") or "element", record.get("name") or "", why
        ),
    )


def find_element(app, record, window=None):
    """pi-phone fork: the live element the snapshot's record names, or a stale_ref refusal.

    Never acts on a re-numbered element: the element at the recorded path must still be the one the snapshot
    saw (role, name, actions, AT-SPI object path); else the object with the recorded path, if it is still
    the same element; else stale_ref. Without an object path only one unambiguous match counts.
    """
    if not record:
        return None
    node = resolve_path(app, record.get("runtimeId") or [])
    if element_matches(node, record):
        return node
    if window is None:
        _, window = main_window(app)
    recorded_path = str(record.get("objectPath") or "")
    if recorded_path:
        moved = find_first(window, lambda candidate: object_path(candidate) == recorded_path)
        if element_matches(moved, record):
            return moved
        raise stale_element(record, "it changed or went away" if moved is None else "it changed")
    if node is not None:
        raise stale_element(record, "another element is there now")
    candidates = [candidate for candidate in iter_all(window) if element_matches(candidate, record)]
    if len(candidates) == 1:
        return candidates[0]
    if candidates:
        raise OCUError(
            "ambiguous_target",
            "[{}] matches {} elements now ({} {!r}).".format(
                record.get("index"), len(candidates), record.get("controlType") or "element", record.get("name") or ""
            ),
        )
    raise stale_element(record, "it went away")


def preferred_action_index(node):
    preferred_exact = {
        "click",
        "press",
        "activate",
        "default.activate",
        "invoke",
        "select",
        "toggle",
        "open",
    }
    count = int(safe(node.get_n_actions, 0) or 0)
    fallback = None
    for index in range(count):
        name = str(safe(lambda i=index: node.get_action_name(i), "") or "")
        description = str(safe(lambda i=index: node.get_action_description(i), "") or "")
        lower = (name or description).lower()
        if lower in preferred_exact:
            return index
        if fallback is None and (
            "activate" in lower or "click" in lower or "press" in lower
        ):
            fallback = index
    return fallback


def do_action_by_index(node, index):
    if index is None:
        return False
    return bool(safe(lambda: node.do_action(int(index)), False))


def screen_point(window_bounds, element=None, x=None, y=None):
    if element is not None:
        f = element.get("frame")
        if f is not None and window_bounds is not None:
            return (
                window_bounds["x"] + f["x"] + f["width"] / 2,
                window_bounds["y"] + f["y"] + f["height"] / 2,
            )
    if x is None or y is None or window_bounds is None:
        raise RuntimeError("coordinate action requires window bounds and x/y")
    return window_bounds["x"] + float(x), window_bounds["y"] + float(y)


def mouse_button_events(button):
    normalized = (button or "left").lower()
    if normalized == "right":
        return "b3p", "b3r"
    if normalized == "middle":
        return "b2p", "b2r"
    return "b1p", "b1r"


def send_mouse_click(x, y, button, count):
    down, up = mouse_button_events(button)
    repeat = max(1, int(count or 1))
    for _ in range(repeat):
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), "abs")
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), down)
        time.sleep(0.035)
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), up)
        time.sleep(0.05)


def send_drag(from_x, from_y, to_x, to_y):
    Atspi.generate_mouse_event(int(round(from_x)), int(round(from_y)), "abs")
    Atspi.generate_mouse_event(int(round(from_x)), int(round(from_y)), "b1p")
    steps = 12
    for step in range(1, steps + 1):
        x = from_x + ((to_x - from_x) * step / steps)
        y = from_y + ((to_y - from_y) * step / steps)
        Atspi.generate_mouse_event(int(round(x)), int(round(y)), "abs")
        time.sleep(0.02)
    Atspi.generate_mouse_event(int(round(to_x)), int(round(to_y)), "b1r")


KEY_ALIASES = {
    "return": "Return",
    "enter": "Return",
    "tab": "Tab",
    "escape": "Escape",
    "esc": "Escape",
    "backspace": "BackSpace",
    "back_space": "BackSpace",
    "delete": "Delete",
    "space": "space",
    "left": "Left",
    "up": "Up",
    "right": "Right",
    "down": "Down",
    "home": "Home",
    "end": "End",
    "page_up": "Page_Up",
    "prior": "Page_Up",
    "page_down": "Page_Down",
    "next": "Page_Down",
}

# X11 modifier bits for LOCKMODIFIERS/UNLOCKMODIFIERS. Super is usually Mod4.
MODIFIER_BITS = {
    "ctrl": "CONTROL",
    "control": "CONTROL",
    "shift": "SHIFT",
    "alt": "ALT",
    "super": "META3",
    "win": "META3",
    "cmd": "META3",
}


# GDK returns VoidSymbol for names it doesn't know.
VOID_SYMBOL = 0xFFFFFF


def keyval(name):
    # Characters have no name lookup in GDK ("/" is "slash"), so map them
    # from Unicode instead.
    if len(name) == 1:
        if Gdk is not None:
            return int(Gdk.unicode_to_keyval(ord(name)))
        return ord(name)
    if Gdk is not None:
        value = int(Gdk.keyval_from_name(name))
        if value and value != VOID_SYMBOL:
            return value
    raise RuntimeError("Unsupported key: " + name)


def send_key(key):
    parts = [part for part in str(key).split("+") if part]
    if not parts:
        raise RuntimeError("Unsupported key: " + str(key))
    main = parts[-1]
    mask = 0
    for modifier in parts[:-1]:
        name = MODIFIER_BITS.get(modifier.lower())
        if name is None:
            raise RuntimeError("Unsupported modifier: " + modifier)
        mask |= 1 << int(getattr(Atspi.ModifierType, name))
    normalized = KEY_ALIASES.get(main.lower(), main)
    if mask:
        Atspi.generate_keyboard_event(mask, None, Atspi.KeySynthType.LOCKMODIFIERS)
    try:
        if len(normalized) == 1 and not mask:
            Atspi.generate_keyboard_event(0, normalized, Atspi.KeySynthType.STRING)
        else:
            # SYM takes a keysym. PRESS, RELEASE, and PRESSRELEASE take a
            # hardware keycode, so passing a keysym there sends another key.
            Atspi.generate_keyboard_event(
                keyval(normalized), None, Atspi.KeySynthType.SYM
            )
    finally:
        if mask:
            Atspi.generate_keyboard_event(
                mask, None, Atspi.KeySynthType.UNLOCKMODIFIERS
            )


def types_character(key):
    """Whether a press_key chord types a character (a, shift+a, space), not a command (ctrl+a, Return)."""
    parts = [part for part in str(key).split("+") if part]
    if not parts:
        return False
    if any(part.lower() not in {"shift"} for part in parts[:-1]):
        return False
    main = parts[-1]
    return len(main) == 1 or main.lower() in {"space"} or main.startswith("KP_") and len(main) == 4


def send_text(text):
    Atspi.generate_keyboard_event(0, str(text), Atspi.KeySynthType.STRING)


def find_editable_text(root):
    def is_editable(node):
        return supports_interface(node, "EditableText") and supports_interface(
            node, "Text"
        )

    return find_first(root, is_editable)


def insert_text(root, text, allow_password=False):
    # pi-phone fork: the focused editable field first (the field the person or the
    # agent clicked), then the first editable field, as before.
    node = focused_node(root)
    if node is None or not (
        supports_interface(node, "EditableText") and supports_interface(node, "Text")
    ):
        node = find_editable_text(root)
    if node is None:
        return False
    refuse_password_input(node, allow_password)
    editable = safe(node.get_editable_text_iface)
    text_iface = safe(node.get_text_iface)
    if editable is None or text_iface is None:
        return False
    offset = int(safe(lambda: Atspi.Text.get_character_count(text_iface), 0) or 0)
    return bool(
        safe(
            lambda: Atspi.EditableText.insert_text(
                editable, offset, str(text), len(str(text))
            ),
            False,
        )
    )


def set_element_value(node, value):
    if node is not None and supports_interface(node, "EditableText"):
        editable = safe(node.get_editable_text_iface)
        if editable is not None:
            return bool(
                safe(
                    lambda: Atspi.EditableText.set_text_contents(editable, str(value)),
                    False,
                )
            )
    value_iface = safe(node.get_value_iface) if node is not None else None
    if value_iface is not None:
        try:
            return bool(Atspi.Value.set_current_value(value_iface, float(value)))
        except Exception:
            pass
    return False


def invoke_secondary_action(node, action):
    if node is None:
        raise RuntimeError("unknown element_index")
    normalized = str(action).lower()
    count = int(safe(node.get_n_actions, 0) or 0)
    for index in range(count):
        name = str(safe(lambda i=index: node.get_action_name(i), "") or "")
        description = str(safe(lambda i=index: node.get_action_description(i), "") or "")
        if normalized in {name.lower(), description.lower()}:
            if do_action_by_index(node, index):
                return
            break
    raise RuntimeError("{} is not a valid secondary action for element".format(action))


def scroll_element(direction, pages):
    key = "Page_Down"
    if direction == "up":
        key = "Page_Up"
    elif direction == "left":
        key = "Left"
    elif direction == "right":
        key = "Right"
    repeat = max(1, int(math.ceil(float(pages or 1))))
    for _ in range(repeat):
        send_key(key)
        time.sleep(0.04)


def perform_operation(operation):
    tool = operation.get("tool")
    if tool == "list_apps":
        return {"ok": True, "text": list_apps_text()}
    if tool == "get_app_state":
        for key in ("include_ax", "include_screenshot"):
            if key in operation and not isinstance(operation[key], bool):
                raise RuntimeError(key + " must be a boolean")
        if not operation.get("include_ax", True) and not operation.get("include_screenshot", True):
            raise RuntimeError("At least one of include_ax or include_screenshot must be true")
        return {
            "ok": True,
            "snapshot": build_snapshot(
                operation.get("app", ""),
                text_limit=parse_text_limit(operation.get("text_limit"), DEFAULT_TEXT_LIMIT),
                max_tree_nodes=positive_int(operation.get("max_tree_nodes"), MAX_ELEMENTS),
                max_tree_depth=positive_int(operation.get("max_tree_depth"), MAX_DEPTH),
                include_ax=operation.get("include_ax", True),
                include_screenshot=operation.get("include_screenshot", True),
                window_id=operation.get("window_id") or None,
            ),
        }

    # pi-phone fork: act in the window the snapshot read (stale_ref when it is gone or replaced), on the
    # element it saw (stale_ref when it changed).
    app, _, window = resolve_target(operation.get("app", ""), operation.get("window_id") or None, stale=True)
    bounds = operation.get("windowBounds") or extents(window)
    element_record = operation.get("element")
    element = find_element(app, element_record, window)
    # pi-phone fork: only this call's own opt-out counts (exactly true), never a default.
    allow_password = operation.get("allow_password_input") is True

    def physical_point(x, y):
        # pi-phone fork: real pointer input lands on whatever is on top at that point.
        refuse_covered_points(app, window, bounds, [(x, y)])
        return x, y

    if tool == "click":
        click_method = (operation.get("click_method") or "auto").lower()
        if click_method == "accessibility":
            if element is None:
                raise RuntimeError("click_method 'accessibility' requires element_index")
            if operation.get("mouse_button", "left") != "left":
                raise RuntimeError(
                    "click_method 'accessibility' only supports mouse_button 'left'"
                )
            if not do_action_by_index(element, preferred_action_index(element)):
                raise RuntimeError(
                    "click_method 'accessibility' could not click the requested element"
                )
        elif click_method == "app_post":
            raise RuntimeError("click_method 'app_post' is not supported on Linux")
        elif click_method == "sky_click":
            raise RuntimeError("click_method 'sky_click' is not supported on Linux")
        elif click_method == "global":
            x, y = physical_point(*screen_point(
                bounds,
                element_record,
                operation.get("x"),
                operation.get("y"),
            ))
            send_mouse_click(
                x, y, operation.get("mouse_button", "left"), operation.get("click_count", 1)
            )
        elif click_method == "auto":
            handled = False
            if element is not None and operation.get("mouse_button", "left") == "left":
                handled = do_action_by_index(element, preferred_action_index(element))
            if not handled:
                x, y = physical_point(*screen_point(
                    bounds,
                    element_record,
                    operation.get("x"),
                    operation.get("y"),
                ))
                send_mouse_click(
                    x,
                    y,
                    operation.get("mouse_button", "left"),
                    operation.get("click_count", 1),
                )
        else:
            raise RuntimeError("Invalid click_method '{}'".format(click_method))
    elif tool == "perform_secondary_action":
        invoke_secondary_action(element, operation.get("action", ""))
    elif tool == "scroll":
        scroll_element(operation.get("direction", "down"), operation.get("pages", 1))
    elif tool == "drag":
        from_x, from_y = screen_point(
            bounds, None, operation.get("from_x"), operation.get("from_y")
        )
        to_x, to_y = screen_point(bounds, None, operation.get("to_x"), operation.get("to_y"))
        refuse_covered_points(app, window, bounds, [(from_x, from_y), (to_x, to_y)])
        send_drag(from_x, from_y, to_x, to_y)
    elif tool == "type_text":
        if not insert_text(window, operation.get("text", ""), allow_password):
            refuse_password_input(focused_node(window), allow_password)
            send_text(operation.get("text", ""))
    elif tool == "press_key":
        if types_character(operation.get("key", "")):
            refuse_password_input(focused_node(window), allow_password)
        send_key(operation.get("key", ""))
    elif tool == "set_value":
        if element is None:
            raise RuntimeError("unknown element_index")
        refuse_password_input(element, allow_password)
        if not set_element_value(element, operation.get("value", "")):
            raise RuntimeError("Cannot set a value for an element that is not settable")
    else:
        raise RuntimeError('unsupportedTool("{}")'.format(tool))

    if operation.get("skip_read_back", False):
        return {"ok": True}

    time.sleep(0.12)
    # The read after an action follows the app's main window, as upstream, unless the call named a window.
    pinned = operation.get("window_id") if operation.get("explicit_window") is True else None
    if pinned:
        return {"ok": True, "snapshot": build_snapshot(operation.get("app", ""), window_id=pinned)}
    return {"ok": True, "snapshot": build_snapshot(operation.get("app", ""))}


def refuse_covered_points(app, window, bounds, points):
    """pi-phone fork: refuse real pointer input at points another window covers now (or a minimised window)."""
    if bounds is None:
        return
    cover = read_window_cover(node_pid(app), node_name(window), bounds)
    if cover["state"] == "minimized":
        raise OCUError("covered", "Refused: the window is minimised; restore it and read it again.")
    for x, y in points:
        local_x, local_y = x - bounds["x"], y - bounds["y"]
        for rect in cover["covered"]:
            if rect["x"] <= local_x < rect["x"] + rect["width"] and rect["y"] <= local_y < rect["y"] + rect["height"]:
                raise OCUError(
                    "covered",
                    "Refused: another window covers ({}, {}) in the window; the input would go there.".format(
                        round(local_x), round(local_y)),
                )


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("runtime.py requires an operation JSON path")
    require_desktop_session()
    Atspi.init()
    with open(sys.argv[1], "r", encoding="utf-8") as file:
        operation = json.load(file)
    try:
        response = perform_operation(operation)
    except OCUError as exc:
        response = {"ok": False, "error": str(exc), "code": exc.code}
        if exc.suggestion:
            response["suggestion"] = exc.suggestion
    except Exception as exc:
        response = {"ok": False, "error": str(exc)}
    print(json.dumps(response, separators=(",", ":")))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print(json.dumps({"ok": False, "error": traceback.format_exc()}))
