import contextlib
import importlib.util
import pathlib
import sys
import types
import unittest
from unittest import mock


class FakeText:
    @staticmethod
    def get_character_count(_interface):
        return 5

    @staticmethod
    def get_text(_interface, _start, _end):
        return "hello"


class FakeEditableText:
    @staticmethod
    def insert_text(_interface, _offset, _text, _length):
        return True

    @staticmethod
    def set_text_contents(_interface, _text):
        return True


def load_runtime():
    gi = types.ModuleType("gi")
    gi.require_version = lambda *_args: None
    repository = types.ModuleType("gi.repository")
    repository.Atspi = types.SimpleNamespace(
        Text=FakeText,
        EditableText=FakeEditableText,
    )
    repository.Gdk = types.SimpleNamespace()
    gi.repository = repository

    runtime_path = pathlib.Path(__file__).with_name("runtime.py")
    spec = importlib.util.spec_from_file_location("open_computer_use_linux_runtime", runtime_path)
    module = importlib.util.module_from_spec(spec)
    with mock.patch.dict(
        sys.modules,
        {"gi": gi, "gi.repository": repository},
    ):
        spec.loader.exec_module(module)
    return module


class InterfaceOnlyAccessible:
    def __init__(self, interfaces):
        self.interfaces = interfaces

    def get_interfaces(self):
        return self.interfaces

    def get_text_iface(self):
        return self

    def get_editable_text_iface(self):
        return self

    def get_child_count(self):
        return 0


class RuntimeInterfaceDetectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = load_runtime()

    def test_text_value_uses_accessible_interfaces(self):
        node = InterfaceOnlyAccessible(["Accessible", "Text"])

        self.assertEqual(self.runtime.text_value(node), "hello")

    def test_insert_text_uses_accessible_interfaces(self):
        node = InterfaceOnlyAccessible(["Accessible", "Text", "EditableText"])

        self.assertTrue(self.runtime.insert_text(node, "hello"))

    def test_set_value_uses_accessible_interfaces(self):
        node = InterfaceOnlyAccessible(["Accessible", "Text", "EditableText"])

        self.assertTrue(self.runtime.set_element_value(node, "hello"))


class FakeKeySynthType:
    PRESS = "PRESS"
    RELEASE = "RELEASE"
    PRESSRELEASE = "PRESSRELEASE"
    SYM = "SYM"
    STRING = "STRING"
    LOCKMODIFIERS = "LOCKMODIFIERS"
    UNLOCKMODIFIERS = "UNLOCKMODIFIERS"


class FakeModifierType:
    SHIFT = 0
    CONTROL = 2
    ALT = 3
    META3 = 6


KEYSYMS = {"Return": 0xFF0D, "Tab": 0xFF09, "Down": 0xFF54}


class RuntimeKeyTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.events = []
        self.runtime.Atspi = types.SimpleNamespace(
            KeySynthType=FakeKeySynthType,
            ModifierType=FakeModifierType,
            generate_keyboard_event=lambda value, text, synth: self.events.append(
                (value, text, synth)
            ),
        )
        self.runtime.Gdk = types.SimpleNamespace(
            # Like GDK, unknown names map to VoidSymbol rather than 0.
            keyval_from_name=lambda name: KEYSYMS.get(name, 0xFFFFFF),
            unicode_to_keyval=lambda codepoint: codepoint,
        )

    def test_named_key_is_sent_as_keysym(self):
        self.runtime.send_key("Enter")

        self.assertEqual(self.events, [(0xFF0D, None, "SYM")])

    def test_modifiers_are_held_around_the_key(self):
        self.runtime.send_key("ctrl+shift+Tab")

        mask = (1 << FakeModifierType.CONTROL) | (1 << FakeModifierType.SHIFT)
        self.assertEqual(
            self.events,
            [
                (mask, None, "LOCKMODIFIERS"),
                (0xFF09, None, "SYM"),
                (mask, None, "UNLOCKMODIFIERS"),
            ],
        )

    def test_modified_character_is_sent_as_keysym(self):
        self.runtime.send_key("ctrl+a")

        mask = 1 << FakeModifierType.CONTROL
        self.assertEqual(self.events[1], (ord("a"), None, "SYM"))
        self.assertEqual(self.events[0], (mask, None, "LOCKMODIFIERS"))

    def test_modified_punctuation_is_sent_as_keysym(self):
        self.runtime.send_key("ctrl+/")

        self.assertEqual(self.events[1], (ord("/"), None, "SYM"))

    def test_unknown_key_name_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.runtime.send_key("NoSuchKey")

        self.assertEqual(self.events, [])

    def test_plain_character_is_typed(self):
        self.runtime.send_key("a")

        self.assertEqual(self.events, [(0, "a", "STRING")])

    def test_unknown_modifier_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.runtime.send_key("hyper+a")

        self.assertEqual(self.events, [])


class RuntimeSelectiveObservationTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.app = object()
        self.window = object()
        self.patches = []
        for name, value in {
            "resolve_app": self.app,
            "matching_apps": [self.app],
            "main_window": (0, self.window),
            "extents": {"x": 1, "y": 2, "width": 300, "height": 200},
            "node_pid": 42,
            "node_name": "Editor",
            "render_tree": ([{"index": 7}], ["tree"]),
            "focus_details": ("focus", "selection", False),
            "capture_window_png": "png",
            "window_id_of": "42:6",
            "other_windows": [],
            "read_window_cover": {"state": "clear", "covered": []},
        }.items():
            patch = mock.patch.object(self.runtime, name, return_value=value)
            self.patches.append(patch)
            patch.start()
            self.addCleanup(patch.stop)

    def test_defaults_still_collect_full_state(self):
        state = self.runtime.build_snapshot("Editor")
        self.assertEqual(state["elements"], [{"index": 7}])
        self.assertEqual(state["screenshotPngBase64"], "png")
        self.runtime.focus_details.assert_called_once()

    def test_screenshot_only_skips_tree_focus_and_selection(self):
        state = self.runtime.build_snapshot("Editor", include_ax=False)
        self.assertEqual(state["screenshotPngBase64"], "png")
        self.assertEqual(state["elements"], [])
        self.assertEqual(state["treeLines"], [])
        self.assertIsNone(state["focusedSummary"])
        self.assertIsNone(state["selectedText"])
        for name in ("render_tree", "focus_details"):
            getattr(self.runtime, name).assert_not_called()

    def test_ax_only_skips_capture(self):
        state = self.runtime.build_snapshot("Editor", include_screenshot=False)
        self.assertEqual(state["treeLines"], ["tree"])
        self.assertIsNone(state["screenshotPngBase64"])
        self.runtime.capture_window_png.assert_not_called()

    def test_ax_only_preserves_bounded_focus_reporting(self):
        self.runtime.focus_details.return_value = (None, None, True)
        state = self.runtime.build_snapshot("Editor", text_limit=20, max_tree_nodes=2,
                                            max_tree_depth=1, include_screenshot=False)
        self.runtime.focus_details.assert_called_once_with(self.window, 20, 2, 1)
        self.assertIn("[Focus search incomplete: node/depth budget reached.]", state["treeLines"])
        self.runtime.capture_window_png.assert_not_called()

    def test_tool_forwards_explicit_observation_flags(self):
        state = self.runtime.perform_operation({"tool": "get_app_state", "app": "Editor", "include_ax": False})
        self.assertTrue(state["ok"])
        self.runtime.render_tree.assert_not_called()

    def test_invalid_or_empty_observations_are_rejected(self):
        for flags in ({"include_ax": "false"}, {"include_screenshot": None},
                      {"include_ax": 0}, {"include_ax": False, "include_screenshot": False}):
            with self.subTest(flags=flags):
                with self.assertRaises(RuntimeError):
                    self.runtime.perform_operation({"tool": "get_app_state", "app": "Editor", **flags})
        self.runtime.resolve_app.assert_not_called()


class HiddenDetailsTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.runtime.Atspi.StateType = types.SimpleNamespace(SHOWING="showing")

    def node(self, showing):
        node = mock.Mock()
        node.get_name.return_value = "Menu"
        node.get_role_name.return_value = "menu"
        node.get_child_count.return_value = 0
        node.get_state_set.return_value.contains.return_value = showing
        return node

    def test_hidden_record_retains_identity_and_skips_expensive_properties(self):
        node = self.node(False)
        with mock.patch.object(self.runtime, "relative_frame") as geometry, \
             mock.patch.object(self.runtime, "element_value") as value, \
             mock.patch.object(self.runtime, "action_names") as actions:
            record = self.runtime.record_for(node, 7, [0, 3], None, lightweight_hidden=True)
        self.assertEqual((record["index"], record["runtimeId"], record["name"]), (7, [0, 3], "Menu"))
        self.assertTrue(record["detailsOmitted"])
        for query in (geometry, value, actions):
            query.assert_not_called()
        node.get_toolkit_name.assert_not_called()
        node.get_accessible_id.assert_not_called()

    def test_default_and_unknown_or_showing_state_keep_full_details(self):
        for enabled, showing in ((False, False), (True, True), (True, None)):
            with self.subTest(enabled=enabled, showing=showing):
                node = self.node(showing)
                with mock.patch.object(self.runtime, "relative_frame", return_value=None), \
                     mock.patch.object(self.runtime, "accessible_id", return_value="id"), \
                     mock.patch.object(self.runtime, "element_value", return_value="value"), \
                     mock.patch.object(self.runtime, "action_names", return_value=["open"]):
                    record = self.runtime.record_for(node, 0, [0], None, lightweight_hidden=enabled)
                self.assertNotIn("detailsOmitted", record)
                self.assertEqual((record["value"], record["actions"]), ("value", ["open"]))
                # pi-phone fork: one StateSet read for the element's states (and SHOWING when enabled).
                node.get_state_set.assert_called_once()
                if not enabled:
                    node.get_state_set.return_value.contains.assert_not_called()

    def test_hidden_parent_does_not_prune_visible_menu_children_or_renumber(self):
        parent = self.node(False)
        child = self.node(True)
        parent.get_child_count.return_value = 1
        parent.get_child_at_index.return_value = child
        with mock.patch.dict(self.runtime.os.environ, {"OPEN_COMPUTER_USE_LINUX_LIGHTWEIGHT_HIDDEN": "1"}), \
             mock.patch.object(self.runtime, "relative_frame", return_value=None), \
             mock.patch.object(self.runtime, "accessible_id", return_value="id"), \
             mock.patch.object(self.runtime, "element_value", return_value="value"), \
             mock.patch.object(self.runtime, "action_names", return_value=[]):
            records, lines = self.runtime.render_tree(parent, None, [0])
        self.assertEqual([r["index"] for r in records], [0, 1])
        self.assertTrue(records[0]["detailsOmitted"])
        self.assertNotIn("detailsOmitted", records[1])
        self.assertIn("hidden details omitted", lines[0])
        self.assertEqual(records[1]["runtimeId"], [0, 0])

    def test_failed_state_reads_keep_full_details(self):
        for failure in ("state-set", "missing-state-set", "contains"):
            with self.subTest(failure=failure):
                node = self.node(False)
                if failure == "state-set":
                    node.get_state_set.side_effect = RuntimeError("state unavailable")
                elif failure == "missing-state-set":
                    node.get_state_set.return_value = None
                else:
                    node.get_state_set.return_value.contains.side_effect = RuntimeError("state unavailable")
                with mock.patch.object(self.runtime, "relative_frame", return_value=None), \
                     mock.patch.object(self.runtime, "element_value", return_value="retained"), \
                     mock.patch.object(self.runtime, "action_names", return_value=["click"]):
                    record = self.runtime.record_for(node, 0, [0], None, lightweight_hidden=True)
                self.assertNotIn("detailsOmitted", record)
                self.assertEqual((record["value"], record["actions"]), ("retained", ["click"]))

    def test_showing_node_with_negative_geometry_keeps_details(self):
        node = self.node(True)
        bounds = {"x": -100, "y": -200, "width": 30, "height": 40}
        with mock.patch.object(self.runtime, "relative_frame", return_value=bounds), \
             mock.patch.object(self.runtime, "element_value", return_value="visible"), \
             mock.patch.object(self.runtime, "action_names", return_value=["click"]):
            record = self.runtime.record_for(node, 0, [0], None, lightweight_hidden=True)
        self.assertNotIn("detailsOmitted", record)
        self.assertEqual((record["frame"], record["value"], record["actions"]), (bounds, "visible", ["click"]))


class FocusDetailsTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.runtime.Atspi.StateType = types.SimpleNamespace(FOCUSED="focused")

    def node(self, children=(), focused=False):
        node = mock.Mock()
        node.get_child_count.return_value = len(children)
        node.get_child_at_index.side_effect = lambda i: children[i]
        node.get_state_set.return_value.contains.side_effect = lambda s: focused
        node.get_name.return_value = "Editor"
        node.get_role_name.return_value = "text"
        node.get_interfaces.return_value = ["Text"]
        return node

    def test_summary_and_selection_share_one_focus_lookup(self):
        focused = self.node(focused=True)
        root = self.node([focused])
        self.runtime.Atspi.Text = types.SimpleNamespace(
            get_n_selections=lambda _: 1,
            get_selection=lambda _iface, index: types.SimpleNamespace(start_offset=1, end_offset=8),
            get_text=lambda _iface, start, end: "hello"[start:end],
        )
        summary, selected, truncated = self.runtime.focus_details(root)
        self.assertEqual((summary, selected, truncated), ("text Editor", "ello", False))
        root.get_child_at_index.assert_called_once_with(0)
        focused.get_state_set.assert_called_once()

    def test_node_budget_reports_incomplete_instead_of_absent(self):
        children = [self.node() for _ in range(100)]
        root = self.node(children)
        self.assertEqual(self.runtime.focus_details(root, max_nodes=3), (None, None, True))
        self.assertEqual(root.get_child_at_index.call_count, 2)

    def test_depth_budget_and_complete_absence(self):
        root = self.node([self.node([self.node(focused=True)])])
        self.assertEqual(self.runtime.focus_details(root, max_depth=1), (None, None, True))
        self.assertEqual(self.runtime.focus_details(self.node()), (None, None, False))

    def test_depth_boundary_does_not_fetch_out_of_budget_children(self):
        boundary = self.node()
        boundary.get_child_count.return_value = 100
        boundary.get_child_at_index.side_effect = None
        boundary.get_child_at_index.return_value = None
        root = self.node([boundary])
        self.assertEqual(self.runtime.focus_details(root, max_nodes=3, max_depth=1), (None, None, True))
        boundary.get_child_at_index.assert_not_called()

    def test_depth_boundary_leaf_is_complete(self):
        root = self.node([self.node()])
        self.assertEqual(self.runtime.focus_details(root, max_depth=1), (None, None, False))

    def test_focus_after_a_pruned_branch_is_still_reported(self):
        pruned = self.node([self.node()])
        focused = self.node(focused=True)
        root = self.node([pruned, focused])
        self.assertEqual(self.runtime.focus_details(root, max_depth=1), ("text Editor", None, False))
        pruned.get_child_at_index.assert_not_called()

    def test_selection_uses_standard_atspi_api_and_character_offsets(self):
        focused = self.node(focused=True)
        self.runtime.Atspi.Text = types.SimpleNamespace(
            get_n_selections=lambda _: 1,
            get_selection=lambda _iface, index: types.SimpleNamespace(start_offset=1, end_offset=4),
            get_text=lambda _iface, start, end: "a中文🙂z"[start:end],
        )
        self.assertEqual(self.runtime.focus_details(focused), ("text Editor", "中文🙂", False))
        self.assertEqual(self.runtime.focus_details(focused, text_limit=2), ("text Ed...", "中文...", False))

    def test_no_selection_does_not_fetch_a_range(self):
        selection = mock.Mock()
        self.runtime.Atspi.Text = types.SimpleNamespace(get_n_selections=lambda _: 0, get_selection=selection)
        self.assertEqual(self.runtime.focus_details(self.node(focused=True)), ("text Editor", None, False))
        selection.assert_not_called()

    def test_selection_read_failure_keeps_the_focus_summary(self):
        self.runtime.Atspi.Text = types.SimpleNamespace(
            get_n_selections=lambda _: 1,
            get_selection=mock.Mock(side_effect=RuntimeError("element became unavailable")),
        )
        self.assertEqual(self.runtime.focus_details(self.node(focused=True)), ("text Editor", None, False))

    def test_snapshot_reports_focus_budget_exhaustion(self):
        with mock.patch.object(self.runtime, "matching_apps", return_value=[object()]), \
             mock.patch.object(self.runtime, "main_window", return_value=(0, self.node())), \
             mock.patch.object(self.runtime, "extents"), \
             mock.patch.object(self.runtime, "render_tree", return_value=([], [])), \
             mock.patch.object(self.runtime, "focus_details", return_value=(None, None, True)) as focus, \
             mock.patch.object(self.runtime, "node_pid", return_value=42), \
             mock.patch.object(self.runtime, "node_name", return_value="Editor"), \
             mock.patch.object(self.runtime, "other_windows", return_value=[]), \
             mock.patch.object(self.runtime, "read_window_cover", return_value={"state": "clear", "covered": []}), \
             mock.patch.object(self.runtime, "capture_window_png"):
            state = self.runtime.build_snapshot("Editor", max_tree_nodes=5, max_tree_depth=2)
        self.assertIn("incomplete", state["treeLines"][0])
        self.assertEqual(focus.call_args.args[2:], (5, 2))


class RuntimeActionReadBackTests(unittest.TestCase):
    def setUp(self):
        self.runtime = load_runtime()
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.object(self.runtime, "resolve_app"))
        self.stack.enter_context(mock.patch.object(self.runtime, "main_window", return_value=(0, object())))
        for name in ("extents", "find_element", "send_key", "send_drag", "send_mouse_click",
                     "invoke_secondary_action", "scroll_element", "insert_text", "set_element_value",
                     "refuse_covered_points"):
            self.stack.enter_context(mock.patch.object(self.runtime, name))
        self.snapshot = self.stack.enter_context(mock.patch.object(self.runtime, "build_snapshot", return_value={"elements": []}))
        self.sleep = self.stack.enter_context(mock.patch.object(self.runtime.time, "sleep"))

    def test_all_actions_skip_snapshot_and_settle_when_requested(self):
        for tool, arguments in (
            ("click", {"x": 1, "y": 2}),
            ("drag", {"from_x": 1, "from_y": 2, "to_x": 3, "to_y": 4}),
            ("press_key", {"key": "Return"}),
            ("type_text", {"text": "hello"}),
            ("set_value", {"value": "hello"}),
            ("perform_secondary_action", {"action": "activate"}),
            ("scroll", {"direction": "down", "pages": 1}),
        ):
            with self.subTest(tool=tool):
                with mock.patch.object(self.runtime, "screen_point", side_effect=[(1, 2), (3, 4)]):
                    result = self.runtime.perform_operation({"tool": tool, "app": "Editor", "skip_read_back": True, **arguments})
                self.assertEqual(result, {"ok": True})
                self.snapshot.assert_not_called()
                self.sleep.assert_not_called()
        self.runtime.send_key.assert_called_once_with("Return")
        self.runtime.send_drag.assert_called_once_with(1, 2, 3, 4)
        self.runtime.insert_text.assert_called_once()

    def test_default_action_still_waits_and_returns_snapshot(self):
        result = self.runtime.perform_operation({"tool": "press_key", "app": "Editor", "key": "Return"})
        self.assertEqual(result, {"ok": True, "snapshot": {"elements": []}})
        self.sleep.assert_called_once_with(0.12)
        self.snapshot.assert_called_once_with("Editor")

    def test_explicit_observation_is_not_suppressed(self):
        result = self.runtime.perform_operation({"tool": "get_app_state", "app": "Editor", "skip_read_back": True})
        self.assertIn("snapshot", result)
        self.snapshot.assert_called_once()

    def test_action_errors_are_not_suppressed(self):
        self.runtime.send_key.side_effect = RuntimeError("input failed")
        with self.assertRaisesRegex(RuntimeError, "input failed"):
            self.runtime.perform_operation({"tool": "press_key", "app": "Editor", "key": "Return", "skip_read_back": True})
        self.snapshot.assert_not_called()


class PasswordFieldTests(unittest.TestCase):
    """pi-phone fork: password fields are marked, never read, and not typed into."""

    def setUp(self):
        self.runtime = load_runtime()
        self.runtime.Atspi.StateType = types.SimpleNamespace(SHOWING="showing", FOCUSED="focused")
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(mock.patch.dict(self.runtime.os.environ, {}, clear=False))
        self.runtime.os.environ.pop("OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT", None)

    def node(self, role, name="", focused=False, children=()):
        node = mock.Mock()
        node.get_name.return_value = name
        node.get_role_name.return_value = role
        node.get_child_count.return_value = len(children)
        node.get_child_at_index.side_effect = lambda index: children[index]
        node.get_state_set.return_value.contains.side_effect = lambda state: focused and state == "focused"
        return node

    def test_password_line_is_marked_and_its_text_is_never_read(self):
        secret = self.node("password text", "Password")
        window = self.node("frame", "Sign in", children=(secret,))
        with mock.patch.object(self.runtime, "relative_frame", return_value=None), \
             mock.patch.object(self.runtime, "accessible_id", return_value=""), \
             mock.patch.object(self.runtime, "element_value",
                               side_effect=lambda node, **_: "hunter2" if node is secret else "") as value, \
             mock.patch.object(self.runtime, "action_names", return_value=[]):
            records, lines = self.runtime.render_tree(window, None, [0])
        self.assertTrue(records[1]["isPassword"])
        self.assertEqual(records[1]["value"], "")
        self.assertNotIn("isPassword", records[0])
        self.assertIn("1 password text Password [password]", lines[1])
        self.assertNotIn("hunter2", "\n".join(lines))
        self.assertEqual(value.call_count, 1)  # only the window's own value was read

    def test_focused_password_summary_is_marked_without_selection(self):
        secret = self.node("password text", "Password", focused=True)
        window = self.node("frame", "Sign in", children=(secret,))
        summary, selection, truncated = self.runtime.focus_details(window)
        self.assertEqual(summary, "password text Password [password]")
        self.assertIsNone(selection)
        self.assertFalse(truncated)

    def test_set_value_into_a_password_field_is_refused(self):
        secret = self.node("password text", "Password")
        with mock.patch.object(self.runtime, "resolve_app"), \
             mock.patch.object(self.runtime, "main_window", return_value=(0, self.node("frame"))), \
             mock.patch.object(self.runtime, "extents"), \
             mock.patch.object(self.runtime, "find_element", return_value=secret), \
             mock.patch.object(self.runtime, "set_element_value") as write:
            with self.assertRaisesRegex(RuntimeError, "password field"):
                self.runtime.perform_operation({"tool": "set_value", "app": "Editor", "element": {"index": 1}, "value": "x"})
        write.assert_not_called()

    def test_typing_into_a_focused_password_field_is_refused(self):
        secret = self.node("password text", "Password", focused=True)
        secret.get_interfaces.return_value = ["Accessible", "Text", "EditableText"]
        window = self.node("frame", "Sign in", children=(secret,))
        with mock.patch.object(self.runtime, "resolve_app"), \
             mock.patch.object(self.runtime, "main_window", return_value=(0, window)), \
             mock.patch.object(self.runtime, "extents"), \
             mock.patch.object(self.runtime, "find_element", return_value=None), \
             mock.patch.object(self.runtime, "send_text") as typed, \
             mock.patch.object(self.runtime, "send_key") as pressed:
            for operation in ({"tool": "type_text", "text": "hunter2"}, {"tool": "press_key", "key": "h"},
                              {"tool": "press_key", "key": "shift+h"}):
                with self.subTest(operation=operation):
                    with self.assertRaisesRegex(RuntimeError, "password field"):
                        self.runtime.perform_operation({"app": "Editor", "skip_read_back": True, **operation})
            # Commands are still allowed: submitting or leaving the field.
            for key in ("Return", "Tab", "ctrl+a"):
                self.runtime.perform_operation({"app": "Editor", "skip_read_back": True, "tool": "press_key", "key": key})
        typed.assert_not_called()
        self.assertEqual([call.args[0] for call in pressed.call_args_list], ["Return", "Tab", "ctrl+a"])

    def test_a_call_that_allows_password_input_types_there(self):
        secret = self.node("password text", "Password", focused=True)
        # Not editable through AT-SPI: type_text falls back to keystrokes into the focused field.
        secret.get_interfaces.return_value = ["Accessible", "Text"]
        window = self.node("frame", "Sign in", children=(secret,))
        window.get_interfaces.return_value = ["Accessible"]
        with mock.patch.object(self.runtime, "resolve_app"), \
             mock.patch.object(self.runtime, "main_window", return_value=(0, window)), \
             mock.patch.object(self.runtime, "extents"), \
             mock.patch.object(self.runtime, "find_element", return_value=secret), \
             mock.patch.object(self.runtime, "set_element_value", return_value=True) as write, \
             mock.patch.object(self.runtime, "send_text") as typed, \
             mock.patch.object(self.runtime, "send_key") as pressed:
            for operation in ({"tool": "type_text", "text": "hunter2"}, {"tool": "press_key", "key": "h"},
                              {"tool": "set_value", "element": {"index": 1}, "value": "hunter2"}):
                with self.subTest(operation=operation):
                    self.runtime.perform_operation({"app": "Editor", "skip_read_back": True,
                                                    "allow_password_input": True, **operation})
            # Only exactly true opts out: anything else keeps the guard.
            for allow in (False, "true", 1, None):
                with self.subTest(allow=allow):
                    with self.assertRaisesRegex(RuntimeError, "password field"):
                        self.runtime.perform_operation({"app": "Editor", "skip_read_back": True, "tool": "type_text",
                                                        "text": "x", "allow_password_input": allow})
        typed.assert_called_once_with("hunter2")
        pressed.assert_called_once_with("h")
        write.assert_called_once_with(secret, "hunter2")

    def test_opt_out_allows_password_input(self):
        secret = self.node("password text", "Password")
        self.runtime.os.environ["OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT"] = "1"
        self.addCleanup(self.runtime.os.environ.pop, "OPEN_COMPUTER_USE_ALLOW_PASSWORD_INPUT", None)
        self.runtime.refuse_password_input(secret)

    def test_types_character(self):
        for key, expected in (("a", True), ("shift+a", True), ("space", True), ("KP_0", True),
                              ("Return", False), ("ctrl+a", False), ("alt+F4", False), ("BackSpace", False)):
            with self.subTest(key=key):
                self.assertEqual(self.runtime.types_character(key), expected)


def rect(x, y, width, height):
    return {"x": float(x), "y": float(y), "width": float(width), "height": float(height)}


class CoveredWindowTests(unittest.TestCase):
    """pi-phone fork (PP-271): what covers a window, from the X11 stacking order."""

    def setUp(self):
        self.runtime = load_runtime()
        self.bounds = rect(100, 100, 400, 300)

    def entry(self, window_id, r, **flags):
        return {"id": window_id, "rect": r, "viewable": True, **flags}

    def test_window_above_is_reported_in_window_coordinates(self):
        stack = [self.entry(1, rect(0, 0, 1280, 800)), self.entry(2, self.bounds), self.entry(3, rect(400, 50, 300, 200))]
        cover = self.runtime.compute_cover(stack, 2, self.bounds)
        self.assertEqual(cover, {"state": "partial", "covered": [rect(300, 0, 100, 150)]})

    def test_windows_below_hidden_unmapped_input_only_or_elsewhere_do_not_cover(self):
        stack = [
            self.entry(1, rect(0, 0, 1280, 800)),
            self.entry(2, self.bounds),
            self.entry(3, rect(100, 100, 50, 50), viewable=False),
            self.entry(4, rect(100, 100, 50, 50), hidden=True),
            self.entry(5, rect(100, 100, 50, 50), input_only=True),
            self.entry(6, rect(100, 100, 50, 50), desktop=1),
            self.entry(7, rect(900, 600, 50, 50)),
        ]
        self.assertEqual(self.runtime.compute_cover(stack, 2, self.bounds, current_desktop=0), {"state": "clear", "covered": []})
        sticky = stack + [self.entry(8, rect(100, 100, 10, 10), desktop=0xFFFFFFFF)]
        self.assertEqual(self.runtime.compute_cover(sticky, 2, self.bounds, current_desktop=0)["covered"], [rect(0, 0, 10, 10)])

    def test_full_cover_by_several_windows_and_minimised_and_unknown(self):
        stack = [self.entry(2, self.bounds), self.entry(3, rect(0, 0, 300, 800)), self.entry(4, rect(250, 0, 800, 800))]
        self.assertEqual(self.runtime.compute_cover(stack, 2, self.bounds)["state"], "full")
        minimised = [self.entry(2, self.bounds, viewable=False), self.entry(3, rect(0, 0, 10, 10))]
        self.assertEqual(self.runtime.compute_cover(minimised, 2, self.bounds), {"state": "minimized", "covered": []})
        self.assertEqual(self.runtime.compute_cover(stack, 99, self.bounds)["state"], "unknown")

    def test_union_area_counts_overlaps_once(self):
        self.assertEqual(self.runtime.union_area([rect(0, 0, 10, 10), rect(5, 5, 10, 10)]), 175)
        self.assertEqual(self.runtime.union_area([]), 0)

    def test_match_client_by_process_title_then_rectangle(self):
        clients = [
            {"id": 1, "pid": 42, "name": "Pi OCU Demo", "rect": rect(0, 0, 10, 10)},
            {"id": 2, "pid": 42, "name": "Other", "rect": rect(100, 100, 400, 300)},
            {"id": 3, "pid": 7, "name": "Pi OCU Demo", "rect": self.bounds},
            {"id": 4, "pid": 42, "name": "Pi OCU Demo", "override": True},
        ]
        self.assertEqual(self.runtime.match_client(clients, 42, "Pi OCU Demo", self.bounds), 1)
        self.assertEqual(self.runtime.match_client(clients, 42, "Untitled", self.bounds), 2)
        twins = [dict(clients[0], rect=self.bounds), dict(clients[0], id=5, rect=rect(0, 0, 9, 9))]
        self.assertEqual(self.runtime.match_client(twins, 42, "Pi OCU Demo", self.bounds), 1)
        self.assertIsNone(self.runtime.match_client(twins, 42, "Pi OCU Demo", rect(500, 500, 1, 1)))

    def test_black_out_fills_each_covered_part_clipped_to_the_picture(self):
        pixbuf = mock.Mock()
        pixbuf.get_width.return_value = 400
        pixbuf.get_height.return_value = 300
        self.runtime.black_out(pixbuf, [rect(300, 0, 150, 150), rect(-10, 250, 20, 100), rect(500, 500, 5, 5)])
        self.assertEqual(pixbuf.new_subpixbuf.call_args_list, [mock.call(300, 0, 100, 150), mock.call(0, 250, 10, 50)])
        pixbuf.new_subpixbuf.return_value.fill.assert_called_with(0x000000FF)

    def snapshot(self, cover):
        with mock.patch.object(self.runtime, "matching_apps", return_value=[]), \
             mock.patch.object(self.runtime, "resolve_target", return_value=(object(), 0, object())), \
             mock.patch.object(self.runtime, "extents", return_value=self.bounds), \
             mock.patch.object(self.runtime, "node_pid", return_value=42), \
             mock.patch.object(self.runtime, "node_name", return_value="Pi OCU Demo"), \
             mock.patch.object(self.runtime, "window_id_of", return_value="42:6"), \
             mock.patch.object(self.runtime, "other_windows", return_value=[{"id": "43:9", "title": "Other", "app": "x"}]), \
             mock.patch.object(self.runtime, "read_window_cover", return_value=cover), \
             mock.patch.object(self.runtime, "capture_window_png", return_value="png") as capture:
            state = self.runtime.build_snapshot("demo", include_ax=False)
        return state, capture

    def test_snapshot_blacks_out_a_partly_covered_window_and_reports_it(self):
        state, capture = self.snapshot({"state": "partial", "covered": [rect(300, 0, 100, 150)]})
        capture.assert_called_once_with(self.bounds, [rect(300, 0, 100, 150)])
        self.assertEqual((state["cover"], state["covered"], state["screenshotPngBase64"]), ("partial", [rect(300, 0, 100, 150)], "png"))
        self.assertEqual((state["windowId"], state["otherWindows"][0]["id"]), ("42:6", "43:9"))

    def test_snapshot_of_a_fully_covered_or_minimised_window_has_no_picture(self):
        for cover in ({"state": "full", "covered": [rect(0, 0, 400, 300)]}, {"state": "minimized", "covered": []}):
            with self.subTest(cover=cover["state"]):
                state, capture = self.snapshot(cover)
                capture.assert_not_called()
                self.assertIsNone(state["screenshotPngBase64"])
                self.assertEqual(state["cover"], cover["state"])

    def test_physical_input_at_a_covered_point_is_refused(self):
        with mock.patch.object(self.runtime, "read_window_cover", return_value={"state": "partial", "covered": [rect(300, 0, 100, 150)]}), \
             mock.patch.object(self.runtime, "node_pid", return_value=42), \
             mock.patch.object(self.runtime, "node_name", return_value="Pi OCU Demo"):
            self.runtime.refuse_covered_points(object(), object(), self.bounds, [(150, 150)])
            with self.assertRaises(self.runtime.OCUError) as refused:
                self.runtime.refuse_covered_points(object(), object(), self.bounds, [(150, 150), (450, 120)])
        self.assertEqual(refused.exception.code, "covered")


class FakeState:
    def __init__(self, nick):
        self.value_nick = nick


class ElementStateTests(unittest.TestCase):
    """pi-phone fork: element states from the AT-SPI StateSet."""

    def setUp(self):
        self.runtime = load_runtime()

    def states(self, role, *nicks):
        state_set = mock.Mock()
        state_set.get_states.return_value = [FakeState(nick) for nick in nicks]
        return self.runtime.element_states(state_set, role)

    def test_states_map_to_the_outline_names_in_order(self):
        self.assertEqual(self.states("check box", "enabled", "sensitive", "focusable", "checked", "focused"), ["checked", "focused"])
        self.assertEqual(self.states("check box", "enabled", "sensitive"), [])
        self.assertEqual(self.states("tree item", "enabled", "expandable", "selected"), ["selected", "collapsed"])
        self.assertEqual(self.states("tree item", "enabled", "expandable", "expanded"), ["expanded"])
        self.assertEqual(self.states("push button", "focusable", "visible"), ["disabled"])
        self.assertEqual(self.states("text", "enabled", "sensitive"), ["readonly"])
        self.assertEqual(self.states("text", "enabled", "editable"), [])
        self.assertEqual(self.states("label", "enabled", "read-only"), ["readonly"])
        self.assertEqual(self.states("password text", "enabled", "editable"), ["secure"])
        self.assertEqual(self.states("push button"), [])
        self.assertEqual(self.runtime.element_states(None, "check box"), [])

    def test_outline_line_carries_states_and_record_carries_object_path(self):
        node = mock.Mock()
        node.get_name.return_value = "Shout"
        node.get_role_name.return_value = "check box"
        node.get_child_count.return_value = 0
        node.path = "/org/a11y/atspi/accessible/3"
        node.get_state_set.return_value.get_states.return_value = [FakeState(n) for n in ("enabled", "checked")]
        with mock.patch.object(self.runtime, "relative_frame", return_value=rect(12, 96, 396, 22)), \
             mock.patch.object(self.runtime, "accessible_id", return_value=""), \
             mock.patch.object(self.runtime, "element_value", return_value=""), \
             mock.patch.object(self.runtime, "action_names", return_value=["click"]):
            records, lines = self.runtime.render_tree(node, None, [0])
        self.assertEqual(lines[0], "\t0 check box Shout Secondary Actions: click States: checked Frame: {x: 12, y: 96, width: 396, height: 22}")
        self.assertEqual((records[0]["states"], records[0]["objectPath"]), (["checked"], "/org/a11y/atspi/accessible/3"))


class StaleRefTests(unittest.TestCase):
    """pi-phone fork: never act on a re-numbered element or in a replaced window."""

    def setUp(self):
        self.runtime = load_runtime()
        self.nodes = {}

    def node(self, role, name, path, actions=("click",), children=()):
        node = mock.Mock()
        node.get_role_name.return_value = role
        node.get_name.return_value = name
        node.path = path
        node.get_child_count.return_value = len(children)
        node.get_child_at_index.side_effect = lambda index: children[index]
        node.get_n_actions.return_value = len(actions)
        node.get_action_name.side_effect = lambda index: actions[index]
        node.get_action_description.return_value = ""
        return node

    def record(self, index, role, name, runtime_id, path="", actions=("click",)):
        return {"index": index, "controlType": role, "name": name, "runtimeId": runtime_id,
                "actions": list(actions), **({"objectPath": path} if path else {})}

    def list_window(self, names):
        items = [self.node("list item", name, "/org/a11y/atspi/accessible/" + str(10 + int(name[-1]))) for name in names]
        listing = self.node("list", "", "/org/a11y/atspi/accessible/9", actions=(), children=items)
        window = self.node("frame", "Demo", "/org/a11y/atspi/accessible/6", actions=(), children=[listing])
        app = self.node("application", "demo", "/org/a11y/atspi/accessible/root", actions=(), children=[window])
        return app, window, items

    def test_the_element_at_the_recorded_path_is_used_when_it_is_the_same(self):
        app, window, items = self.list_window(["Item 1", "Item 2", "Item 3"])
        record = self.record(3, "list item", "Item 3", [0, 0, 2], "/org/a11y/atspi/accessible/13")
        self.assertIs(self.runtime.find_element(app, record, window), items[2])

    def test_a_reversed_list_finds_the_same_object_or_refuses(self):
        app, window, items = self.list_window(["Item 6", "Item 5", "Item 4", "Item 3", "Item 2", "Item 1"])
        # The snapshot saw Item 3 at [0, 0, 2]; now Item 4 is there. The object (path …/13) moved to [0, 0, 3].
        record = self.record(3, "list item", "Item 3", [0, 0, 2], "/org/a11y/atspi/accessible/13")
        self.assertIs(self.runtime.find_element(app, record, window), items[3])
        # A new object with the same name (a rebuilt list) is not the element the snapshot saw.
        rebuilt = dict(record, objectPath="/org/a11y/atspi/accessible/99")
        with self.assertRaises(self.runtime.OCUError) as refused:
            self.runtime.find_element(app, rebuilt, window)
        self.assertEqual(refused.exception.code, "stale_ref")
        self.assertIn("Item 3", str(refused.exception))

    def test_without_object_paths_a_changed_element_is_refused_and_twins_are_ambiguous(self):
        app, window, items = self.list_window(["Item 6", "Item 5", "Item 4"])
        for item in items:
            item.path = None
        with self.assertRaises(self.runtime.OCUError) as refused:
            self.runtime.find_element(app, self.record(3, "list item", "Item 3", [0, 0, 2]), window)
        self.assertEqual(refused.exception.code, "stale_ref")
        items[1].get_name.return_value = "Item 4"
        with self.assertRaises(self.runtime.OCUError) as refused:
            self.runtime.find_element(app, self.record(3, "list item", "Item 4", [0, 5, 0]), window)
        self.assertEqual(refused.exception.code, "ambiguous_target")

    def test_changed_actions_or_role_are_stale_and_cut_names_still_match(self):
        app, window, items = self.list_window(["Item 1", "Item 2"])
        with self.assertRaises(self.runtime.OCUError):
            self.runtime.find_element(app, self.record(2, "list item", "Item 2", [0, 0, 1], actions=("activate",)), window)
        with self.assertRaises(self.runtime.OCUError):
            self.runtime.find_element(app, self.record(2, "push button", "Item 2", [0, 0, 1]), window)
        self.assertIs(self.runtime.find_element(app, self.record(2, "list item", "It...", [0, 0, 1]), window), items[1])

    def test_an_action_in_a_replaced_window_is_stale_and_a_read_of_a_missing_one_not_found(self):
        with mock.patch.object(self.runtime, "find_window", return_value=None), \
             mock.patch.object(self.runtime, "matching_apps", return_value=[]), \
             mock.patch.object(self.runtime, "send_key") as pressed:
            with self.assertRaises(self.runtime.OCUError) as refused:
                self.runtime.perform_operation({"tool": "press_key", "app": "demo", "key": "Return", "window_id": "42:6"})
            self.assertEqual(refused.exception.code, "stale_ref")
            with self.assertRaises(self.runtime.OCUError) as missing:
                self.runtime.perform_operation({"tool": "get_app_state", "app": "demo", "window_id": "42:6"})
            self.assertEqual(missing.exception.code, "not_found")
        pressed.assert_not_called()

    def test_window_ids_name_the_process_and_object(self):
        app = self.node("application", "demo", "/org/a11y/atspi/accessible/root")
        app.get_process_id.return_value = 42
        window = self.node("frame", "Demo", "/org/a11y/atspi/accessible/6")
        self.assertEqual(self.runtime.window_id_of(app, window), "42:6")
        window.path = None
        self.assertEqual(self.runtime.window_id_of(app, window), "")


class ErrorCodeTests(unittest.TestCase):
    """pi-phone fork: refusals reach the Go side with their code."""

    def test_main_reports_the_code_of_a_refusal(self):
        import io
        import tempfile
        runtime = load_runtime()
        runtime.Atspi.init = lambda: None
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as handle:
            handle.write('{"tool": "set_value"}')
        self.addCleanup(pathlib.Path(handle.name).unlink)
        output = io.StringIO()
        with mock.patch.object(runtime, "require_desktop_session"), \
             mock.patch.object(runtime, "perform_operation", side_effect=runtime.OCUError("password_field", runtime.PASSWORD_REFUSAL)), \
             mock.patch.object(runtime.sys, "argv", ["runtime.py", handle.name]), \
             contextlib.redirect_stdout(output):
            runtime.main()
        response = __import__("json").loads(output.getvalue())
        self.assertEqual((response["ok"], response["code"]), (False, "password_field"))
        self.assertIn("password field", response["error"])


if __name__ == "__main__":
    unittest.main()
