package main

import (
	"strings"
	"testing"
)

func TestActionPinsObservedWindowAndForwardsKeyboardMethod(t *testing.T) {
	for _, method := range []string{"auto", "global"} {
		t.Run(method, func(t *testing.T) {
			t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "1")
			svc := newService()
			svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, WindowHandle: 1234})
			var request psRequest
			svc.runBridge = func(r psRequest) (*psResponse, error) {
				request = r
				return &psResponse{OK: true, Snapshot: &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, WindowHandle: 1234}}, nil
			}
			result := svc.callTool("press_key", map[string]any{"app": "fixture", "key": "ctrl+a", "key_method": method})
			if result.IsError || request.ExpectedPID != 42 || request.WindowHandle != 1234 || request.KeyMethod != method {
				t.Fatalf("action lost observed identity or explicit method: %#v, %#v", request, result)
			}
		})
	}
}

// pi-phone fork: allow_password_input reaches the bridge only on the call that sets it, only as true.
func TestAllowPasswordInputIsPerCall(t *testing.T) {
	cases := []struct {
		tool string
		args map[string]any
		want bool
	}{
		{"type_text", map[string]any{"text": "x", "allow_password_input": true}, true},
		{"type_text", map[string]any{"text": "x"}, false},
		{"press_key", map[string]any{"key": "a", "allow_password_input": true}, true},
		{"press_key", map[string]any{"key": "a", "allow_password_input": false}, false},
		{"set_value", map[string]any{"element_index": "0", "value": "x", "allow_password_input": true}, true},
		{"set_value", map[string]any{"element_index": "0", "value": "x"}, false},
	}
	for _, c := range cases {
		svc := newService()
		svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, WindowHandle: 1234, Elements: []elementRecord{{Index: 0}}})
		var request psRequest
		svc.runBridge = func(r psRequest) (*psResponse, error) {
			request = r
			return &psResponse{OK: true, Snapshot: &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, WindowHandle: 1234}}, nil
		}
		args := map[string]any{"app": "fixture"}
		for key, value := range c.args {
			args[key] = value
		}
		if result := svc.callTool(c.tool, args); result.IsError {
			t.Fatalf("%s %v: %#v", c.tool, c.args, result)
		}
		if request.AllowPasswordInput != c.want {
			t.Fatalf("%s %v: bridge request %#v", c.tool, c.args, request)
		}
	}
	svc := newService()
	svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}})
	if result := svc.callTool("type_text", map[string]any{"app": "fixture", "text": "x", "allow_password_input": "yes"}); !result.IsError {
		t.Fatalf("a non-boolean allow_password_input was taken: %#v", result)
	}
}

func TestGlobalClickNeedsImageEvenWhenElementIndexExists(t *testing.T) {
	t.Setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "1")
	svc := newService()
	svc.rememberSnapshot("fixture", &appSnapshot{App: appDescriptor{Name: "fixture", PID: 42}, ScreenshotOmitted: true, Elements: []elementRecord{{Index: 0}}})
	svc.runBridge = func(psRequest) (*psResponse, error) {
		t.Fatal("image-less global click reached bridge")
		return nil, nil
	}
	result := svc.callTool("click", map[string]any{"app": "fixture", "element_index": "0", "click_method": "global"})
	if !result.IsError || !strings.Contains(result.Content[0].Text, "screenshot") {
		t.Fatalf("%#v", result)
	}
}
