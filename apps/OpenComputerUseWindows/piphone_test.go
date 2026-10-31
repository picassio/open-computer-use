package main

// pi-phone fork (PP-270) tests: error codes.

import (
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
	requireCode(t, s.callTool("click", map[string]any{"app": "demo"}), codeInvalidArgument, "safe")
}

// The runtime script carries the fork's guards: coded refusals.
func TestWindowsRuntimeCarriesTheForkGuards(t *testing.T) {
	for _, needle := range []string{
		`function New-OCUError`,
	} {
		if !strings.Contains(windowsRuntimeScript, needle) {
			t.Fatalf("runtime.ps1 lacks %q", needle)
		}
	}
}
