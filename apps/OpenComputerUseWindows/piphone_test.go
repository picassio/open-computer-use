package main

// pi-phone fork (PP-270) tests: snapshot ids, stale refs, error codes.

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
		TreeLines:           []string{"\t0 window Pi OCU Demo", "\t\t1 check box Shout Secondary Actions: Toggle"},
		Elements:            []elementRecord{{Index: 0, ControlType: "ControlType.Window"}, {Index: 1, ControlType: "ControlType.CheckBox", Name: "Shout", RuntimeID: []int{7, 42, 3}}},
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
		"\t0 window Pi OCU Demo",
	}
	for i, line := range want {
		if lines[3+i] != line {
			t.Fatalf("line %d = %q, want %q", 3+i, lines[3+i], line)
		}
	}
	id := strings.TrimPrefix(lines[2], "Snapshot: ")
	structured := result.StructuredContent
	if structured["snapshot_id"] != id || structured["window_id"] != "1234" {
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

func TestToolSchemasCarryTheForkArguments(t *testing.T) {
	for _, tool := range toolDefinitions() {
		properties := tool.InputSchema["properties"].(map[string]any)
		_, snapshotID := properties["snapshot_id"]
		_, windowID := properties["window_id"]
		switch tool.Name {
		case "list_apps":
			if snapshotID || windowID {
				t.Fatalf("list_apps: %#v", properties)
			}
		case "get_app_state":
			if !windowID || snapshotID {
				t.Fatalf("get_app_state: %#v", properties)
			}
		default:
			if !snapshotID || !windowID {
				t.Fatalf("%s: %#v", tool.Name, properties)
			}
		}
	}
}

// The runtime script carries the fork's guards: coded refusals and stale elements.
func TestWindowsRuntimeCarriesTheForkGuards(t *testing.T) {
	for _, needle := range []string{
		`function New-OCUError`,
		`throw (New-StaleElementError $record "it changed")`,
		`EnumWindows(delegate (IntPtr hWnd, IntPtr unused)`,
	} {
		if !strings.Contains(windowsRuntimeScript, needle) {
			t.Fatalf("runtime.ps1 lacks %q", needle)
		}
	}
}
