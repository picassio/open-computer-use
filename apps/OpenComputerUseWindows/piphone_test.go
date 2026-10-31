package main

// pi-phone fork (PP-270) tests: snapshot ids, stale refs, covered regions, headed input, error codes.

import (
	"regexp"
	"strings"
	"testing"
)

func firstLine(result toolCallResult) string {
	return strings.SplitN(result.Content[0].Text, "\n", 2)[0]
}

func errorLine(t *testing.T, result toolCallResult) string {
	t.Helper()
	if !result.IsError {
		t.Fatalf("expected an error, got %#v", result)
	}
	for _, line := range strings.Split(result.Content[0].Text, "\n") {
		if strings.HasPrefix(line, "Error: ") {
			return line
		}
	}
	t.Fatalf("no Error: line in %q", result.Content[0].Text)
	return ""
}

func requireCode(t *testing.T, result toolCallResult, code, retry string) {
	t.Helper()
	line := errorLine(t, result)
	if !strings.HasPrefix(line, "Error: "+code+" retry="+retry+" suggestion=") || len(line) <= len("Error: "+code+" retry="+retry+" suggestion=") {
		t.Fatalf("error line = %q, want code %s retry %s", line, code, retry)
	}
	structured, _ := result.StructuredContent["error"].(map[string]any)
	if structured["code"] != code || structured["retry"] != retry || structured["suggestion"] == "" {
		t.Fatalf("structured error = %#v", result.StructuredContent)
	}
}

// fakeBridge answers each runtime request with the next response and records the requests.
type fakeBridge struct {
	requests  []psRequest
	responses []*psResponse
}

func (f *fakeBridge) run(request psRequest) (*psResponse, error) {
	f.requests = append(f.requests, request)
	response := f.responses[0]
	if len(f.responses) > 1 {
		f.responses = f.responses[1:]
	}
	copy := *response
	if response.Snapshot != nil {
		snapshot := *response.Snapshot
		copy.Snapshot = &snapshot
	}
	return &copy, nil
}

func demoSnapshot(t *testing.T) *appSnapshot {
	return &appSnapshot{
		App:                 appDescriptor{Name: "demo", PID: 42},
		WindowTitle:         "Pi OCU Demo",
		WindowHandle:        1234,
		WindowBounds:        &frame{X: 100, Y: 100, Width: 400, Height: 300},
		ScreenshotPNGBase64: pngBase64(t, 400, 300),
		TreeLines:           []string{"\t0 window Pi OCU Demo", "\t\t1 check box Shout Secondary Actions: Toggle States: checked"},
		Elements:            []elementRecord{{Index: 0, ControlType: "ControlType.Window"}, {Index: 1, ControlType: "ControlType.CheckBox", Name: "Shout", RuntimeID: []int{7, 42, 3}}},
		Cover:               "clear",
	}
}

func serviceWith(responses ...*psResponse) (*service, *fakeBridge) {
	bridge := &fakeBridge{responses: responses}
	s := newService()
	s.runBridge = bridge.run
	return s, bridge
}

func TestSnapshotLinesAndStructuredResult(t *testing.T) {
	read := demoSnapshot(t)
	read.OtherWindows = []windowRef{{ID: "5678", Title: "Other", App: "demo"}}
	read.Cover = "partial"
	read.Covered = []frame{{X: 300, Y: 0, Width: 100, Height: 150}}
	s, _ := serviceWith(&psResponse{OK: true, Snapshot: read})
	result := s.callTool("get_app_state", map[string]any{"app": "demo"})
	if result.IsError || len(result.Content) != 2 {
		t.Fatalf("%#v", result)
	}
	lines := strings.Split(result.Content[0].Text, "\n")
	if lines[0] != "App=demo (pid 42)" || !strings.HasPrefix(lines[1], "Window: \"Pi OCU Demo\"") {
		t.Fatalf("the first two lines changed: %q", lines[:2])
	}
	if !regexp.MustCompile(`^Snapshot: [0-9a-f]{8}$`).MatchString(lines[2]) {
		t.Fatalf("snapshot line = %q", lines[2])
	}
	want := []string{
		"Window id: 1234",
		`Other windows: 5678 "Other" (demo)`,
		"Covered: [{x: 300, y: 0, width: 100, height: 150}] (other windows; blacked out in the screenshot)",
		"\t0 window Pi OCU Demo",
	}
	for i, line := range want {
		if lines[3+i] != line {
			t.Fatalf("line %d = %q, want %q", 3+i, lines[3+i], line)
		}
	}
	id := strings.TrimPrefix(lines[2], "Snapshot: ")
	structured := result.StructuredContent
	covered, _ := structured["covered"].([]frame)
	if structured["snapshot_id"] != id || structured["window_id"] != "1234" || len(covered) != 1 || covered[0].X != 300 || structured["cover"] != "partial" {
		t.Fatalf("structured = %#v", structured)
	}
}

func TestEveryReadGetsANewSnapshotID(t *testing.T) {
	s, _ := serviceWith(&psResponse{OK: true, Snapshot: demoSnapshot(t)})
	first := s.callTool("get_app_state", map[string]any{"app": "demo"}).StructuredContent["snapshot_id"]
	second := s.callTool("get_app_state", map[string]any{"app": "demo"}).StructuredContent["snapshot_id"]
	if first == "" || first == second {
		t.Fatalf("snapshot ids %v, %v", first, second)
	}
}

func TestAnOldSnapshotIDIsStale(t *testing.T) {
	s, bridge := serviceWith(&psResponse{OK: true, Snapshot: demoSnapshot(t)})
	old := s.callTool("get_app_state", map[string]any{"app": "demo"}).StructuredContent["snapshot_id"].(string)
	latest := s.callTool("get_app_state", map[string]any{"app": "demo"}).StructuredContent["snapshot_id"].(string)
	sent := len(bridge.requests)

	stale := s.callTool("click", map[string]any{"app": "demo", "element_index": "1", "snapshot_id": old})
	requireCode(t, stale, codeStaleRef, "safe")
	if !strings.Contains(stale.Content[0].Text, "replaced by "+latest) {
		t.Fatalf("message = %q", stale.Content[0].Text)
	}
	unknown := s.callTool("set_value", map[string]any{"app": "demo", "element_index": "1", "value": "x", "snapshot_id": "deadbeef"})
	requireCode(t, unknown, codeStaleRef, "safe")
	if !strings.Contains(unknown.Content[0].Text, "unknown") {
		t.Fatalf("message = %q", unknown.Content[0].Text)
	}
	for _, tool := range []string{"perform_secondary_action", "scroll", "type_text", "press_key"} {
		args := map[string]any{"app": "demo", "element_index": "1", "action": "toggle", "direction": "down", "text": "x", "key": "Return", "snapshot_id": old}
		requireCode(t, s.callTool(tool, args), codeStaleRef, "safe")
	}
	if len(bridge.requests) != sent {
		t.Fatal("a stale call reached the runtime")
	}

	if result := s.callTool("click", map[string]any{"app": "demo", "element_index": "1", "snapshot_id": latest}); result.IsError {
		t.Fatalf("the latest snapshot was refused: %#v", result)
	}
	request := bridge.requests[len(bridge.requests)-1]
	if request.Element == nil || len(request.Element.RuntimeID) != 3 || request.Element.ControlType != "ControlType.CheckBox" || request.Element.Name != "Shout" {
		t.Fatalf("the runtime did not get what the snapshot saw: %#v", request.Element)
	}
}

func TestActionsAreBoundToTheSnapshotWindow(t *testing.T) {
	s, bridge := serviceWith(&psResponse{OK: true, Snapshot: demoSnapshot(t)})
	s.callTool("get_app_state", map[string]any{"app": "demo"})

	requireCode(t, s.callTool("press_key", map[string]any{"app": "demo", "key": "Return", "window_id": "9999"}), codeStaleRef, "safe")

	s.callTool("press_key", map[string]any{"app": "demo", "key": "Return"})
	request := bridge.requests[len(bridge.requests)-1]
	if request.WindowHandle != 1234 || request.ExpectedPID != 42 || request.ExplicitWindow {
		t.Fatalf("an action must carry the snapshot's window: %#v", request)
	}
	s.callTool("press_key", map[string]any{"app": "demo", "key": "Return", "window_id": "1234"})
	if request := bridge.requests[len(bridge.requests)-1]; request.WindowHandle != 1234 || !request.ExplicitWindow {
		t.Fatalf("an explicit window_id must pin the read back: %#v", request)
	}

	s.callTool("get_app_state", map[string]any{"app": "demo", "window_id": "5678"})
	if request := bridge.requests[len(bridge.requests)-1]; request.WindowHandle != 5678 || !request.ExplicitWindow {
		t.Fatalf("get_app_state window_id not sent: %#v", request)
	}
	requireCode(t, s.callTool("get_app_state", map[string]any{"app": "demo", "window_id": "notepad"}), codeInvalidArgument, "safe")
}

func TestRuntimeRefusalsKeepTheirCode(t *testing.T) {
	s, _ := serviceWith(&psResponse{OK: true, Snapshot: demoSnapshot(t)})
	s.callTool("get_app_state", map[string]any{"app": "demo"})
	for _, c := range []struct {
		response *psResponse
		code     string
		retry    string
	}{
		{&psResponse{Error: "[1] is no longer the check box", Code: codeStaleRef}, codeStaleRef, "safe"},
		{&psResponse{Error: "Refused: the target is a password field.", Code: codePasswordField}, codePasswordField, "safe"},
		{&psResponse{Error: "[1] matches 2 elements now", Code: codeAmbiguousTarget}, codeAmbiguousTarget, "safe"},
		{&psResponse{Error: "input failed"}, codeActionFailed, "unsafe"},
	} {
		s.runBridge = (&fakeBridge{responses: []*psResponse{c.response}}).run
		result := s.callTool("set_value", map[string]any{"app": "demo", "element_index": "1", "value": "x"})
		requireCode(t, result, c.code, c.retry)
		if !strings.HasPrefix(result.Content[0].Text, c.response.Error+"\n") {
			t.Fatalf("the human message is gone: %q", result.Content[0].Text)
		}
	}
	s.runBridge = (&fakeBridge{responses: []*psResponse{{Error: `appNotFound("demo")`, Code: codeNotFound}}}).run
	requireCode(t, s.callTool("get_app_state", map[string]any{"app": "demo"}), codeNotFound, "safe")
	s.runBridge = (&fakeBridge{responses: []*psResponse{{Error: "UI Automation broke"}}}).run
	requireCode(t, s.callTool("get_app_state", map[string]any{"app": "demo"}), codeFailed, "safe")
	requireCode(t, newService().callTool("press_key", map[string]any{"app": "nothing", "key": "a"}), codeStaleRef, "safe")
	requireCode(t, s.callTool("click", map[string]any{"app": "demo", "element_index": "99"}), codeNotFound, "safe")
	requireCode(t, s.callTool("click", map[string]any{"app": "demo", "element_index": "1", "snapshot_id": 7}), codeInvalidArgument, "safe")
}

func TestPhysicalInputNeedsHeaded(t *testing.T) {
	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "1")
	s, bridge := serviceWith(&psResponse{OK: true, Snapshot: demoSnapshot(t)})
	s.callTool("get_app_state", map[string]any{"app": "demo"})
	sent := len(bridge.requests)
	for _, args := range []map[string]any{
		{"tool": "drag", "from_x": 10, "from_y": 10, "to_x": 50, "to_y": 50},
		{"tool": "click", "x": 10, "y": 10},
		{"tool": "click", "x": 10, "y": 10, "headed": false},
		{"tool": "click", "x": 10, "y": 10, "click_method": "app_post"},
		{"tool": "click", "element_index": "1", "click_method": "global"},
		{"tool": "press_key", "key": "ctrl+a", "key_method": "global"},
	} {
		tool := args["tool"].(string)
		delete(args, "tool")
		args["app"] = "demo"
		requireCode(t, s.callTool(tool, args), codePolicyDenied, "safe")
	}
	if len(bridge.requests) != sent {
		t.Fatal("physical input without headed reached the runtime")
	}
	requireCode(t, s.callTool("drag", map[string]any{"app": "demo", "from_x": 1, "from_y": 1, "to_x": 2, "to_y": 2, "headed": "yes"}), codeInvalidArgument, "safe")

	for _, c := range []struct {
		tool string
		args map[string]any
	}{
		{"click", map[string]any{"element_index": "1"}},
		{"click", map[string]any{"element_index": "1", "click_method": "app_post"}},
		{"press_key", map[string]any{"key": "Return"}},
	} {
		c.args["app"] = "demo"
		if result := s.callTool(c.tool, c.args); result.IsError {
			t.Fatalf("%s %v needs no headed: %#v", c.tool, c.args, result)
		}
		if bridge.requests[len(bridge.requests)-1].Headed {
			t.Fatal("headed sent without the flag")
		}
	}
	for _, c := range []struct {
		tool string
		args map[string]any
	}{
		{"drag", map[string]any{"from_x": 10, "from_y": 10, "to_x": 50, "to_y": 50}},
		{"click", map[string]any{"x": 10, "y": 10}},
		{"press_key", map[string]any{"key": "ctrl+a", "key_method": "global"}},
	} {
		c.args["app"] = "demo"
		c.args["headed"] = true
		if result := s.callTool(c.tool, c.args); result.IsError {
			t.Fatalf("%s with headed: %#v", c.tool, result)
		}
		if request := bridge.requests[len(bridge.requests)-1]; !request.Headed || request.Tool != c.tool {
			t.Fatalf("headed did not reach the runtime: %#v", request)
		}
	}
	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "")
	requireCode(t, s.callTool("click", map[string]any{"app": "demo", "element_index": "1", "click_method": "global", "headed": true}), codePolicyDenied, "safe")
	requireCode(t, s.callTool("press_key", map[string]any{"app": "demo", "key": "a", "key_method": "global", "headed": true}), codePolicyDenied, "safe")
}

func TestCoordinatesInACoveredPartAreRefused(t *testing.T) {
	read := demoSnapshot(t)
	read.Cover = "partial"
	read.Covered = []frame{{X: 300, Y: 0, Width: 100, Height: 150}}
	s, bridge := serviceWith(&psResponse{OK: true, Snapshot: read})
	s.callTool("get_app_state", map[string]any{"app": "demo"})
	sent := len(bridge.requests)
	requireCode(t, s.callTool("click", map[string]any{"app": "demo", "x": 350, "y": 20, "headed": true}), codeCovered, "safe")
	requireCode(t, s.callTool("drag", map[string]any{"app": "demo", "from_x": 10, "from_y": 10, "to_x": 399, "to_y": 149, "headed": true}), codeCovered, "safe")
	if len(bridge.requests) != sent {
		t.Fatal("a covered point reached the runtime")
	}
	if result := s.callTool("click", map[string]any{"app": "demo", "x": 299, "y": 20, "headed": true}); result.IsError {
		t.Fatalf("an uncovered point was refused: %#v", result)
	}
}

func TestFullyCoveredOrMinimisedWindowsSayWhyThereIsNoScreenshot(t *testing.T) {
	for cover, want := range map[string]string{
		"full":      "Screenshot omitted: other windows cover the whole window.",
		"minimized": "Screenshot omitted: the window is minimised.",
	} {
		read := demoSnapshot(t)
		read.Cover = cover
		read.ScreenshotPNGBase64 = ""
		if cover == "full" {
			read.Covered = []frame{{Width: 400, Height: 300}}
		} else {
			read.WindowBounds = nil
		}
		s, _ := serviceWith(&psResponse{OK: true, Snapshot: read})
		result := s.callTool("get_app_state", map[string]any{"app": "demo"})
		if len(result.Content) != 1 || !strings.Contains(result.Content[0].Text, want) || strings.Contains(result.Content[0].Text, "Screenshot unavailable") {
			t.Fatalf("%s: %#v", cover, result)
		}
		requireCode(t, s.callTool("click", map[string]any{"app": "demo", "x": 5, "y": 5, "headed": true}), codeCovered, "safe")
	}
}

func TestRefuseIfCovered(t *testing.T) {
	read := demoSnapshot(t)
	read.Cover = "partial"
	read.Covered = []frame{{X: 300, Y: 0, Width: 100, Height: 150}}
	s, _ := serviceWith(&psResponse{OK: true, Snapshot: read})
	refused := s.callTool("get_app_state", map[string]any{"app": "demo", "refuse_if_covered": true})
	requireCode(t, refused, codeCovered, "safe")
	if len(refused.Content) != 1 || s.currentSnapshot("demo") != nil {
		t.Fatalf("a refused read returned a picture or became the latest snapshot: %#v", refused)
	}
	for _, cover := range []string{"unknown", "minimized", ""} {
		read.Cover = cover
		requireCode(t, s.callTool("get_app_state", map[string]any{"app": "demo", "refuse_if_covered": true}), codeCovered, "safe")
	}
	read.Cover, read.Covered = "clear", nil
	if result := s.callTool("get_app_state", map[string]any{"app": "demo", "refuse_if_covered": true}); result.IsError {
		t.Fatalf("an uncovered window was refused: %#v", result)
	}
	requireCode(t, s.callTool("get_app_state", map[string]any{"app": "demo", "refuse_if_covered": true, "include_screenshot": false}), codeInvalidArgument, "safe")
}

func TestToolSchemasCarryTheForkArguments(t *testing.T) {
	for _, tool := range toolDefinitions() {
		properties := tool.InputSchema["properties"].(map[string]any)
		_, snapshotID := properties["snapshot_id"]
		_, windowID := properties["window_id"]
		_, headed := properties["headed"]
		_, refuse := properties["refuse_if_covered"]
		switch tool.Name {
		case "list_apps":
			if snapshotID || windowID {
				t.Fatalf("list_apps: %#v", properties)
			}
		case "get_app_state":
			if !windowID || !refuse || snapshotID {
				t.Fatalf("get_app_state: %#v", properties)
			}
		default:
			if !snapshotID || !windowID || headed != (tool.Name == "click" || tool.Name == "drag" || tool.Name == "press_key") {
				t.Fatalf("%s: %#v", tool.Name, properties)
			}
		}
	}
}

// The runtime script carries the fork's guards: coded refusals, the headed gate on SendInput, and the
// z-order cover check before a screenshot.
func TestWindowsRuntimeCarriesTheForkGuards(t *testing.T) {
	for _, needle := range []string{
		`function New-OCUError`,
		`return ((Test-EnvFlagEnabled "OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS") -and $script:HeadedThisCall)`,
		`$script:HeadedThisCall = ($operation.headed -is [bool]) -and $operation.headed`,
		`$cover = Get-WindowCover $handle $bounds`,
		`throw (New-StaleElementError $record "it changed")`,
		`EnumWindows(delegate (IntPtr hWnd, IntPtr unused)`,
	} {
		if !strings.Contains(windowsRuntimeScript, needle) {
			t.Fatalf("runtime.ps1 lacks %q", needle)
		}
	}
}
