package main

// pi-phone fork (PP-270): structured errors. See PI-PHONE.md.

import (
	"strings"
)

// Error codes of the machine-readable "Error:" line.
const (
	codeStaleRef        = "stale_ref"
	codeAmbiguousTarget = "ambiguous_target"
	codePolicyDenied    = "policy_denied"
	codeCovered         = "covered"
	codeNotFound        = "not_found"
	codePasswordField   = "password_field"
	codeInvalidArgument = "invalid_argument"
	codeActionFailed    = "action_failed"
	codeFailed          = "failed"
)

var defaultSuggestions = map[string]string{
	codeStaleRef:        "Call get_app_state again and act on its element numbers.",
	codeAmbiguousTarget: "Read the app again.",
	codePolicyDenied:    "Use an element_index action; this physical input is not allowed here.",
	codeCovered:         "Bring the window to the front or move what covers it, then read it again.",
	codeNotFound:        "Check the app, window or element number, then read the app again with get_app_state.",
	codePasswordField:   "Do not type into a password field; ask the person to type it.",
	codeInvalidArgument: "Fix the arguments and call again.",
	codeActionFailed:    "Read the app again before retrying: the action may have taken effect.",
	codeFailed:          "Read the app again, then retry.",
}

// errorResult is a refusal or failure: the human message, then
// "Error: <code> retry=<safe|unsafe> suggestion=<text>", and the same in structuredContent.
// Only action_failed is unsafe to retry: every other code is raised before anything reaches the app.
func errorResult(code, message, suggestion string) toolCallResult {
	if suggestion == "" {
		suggestion = defaultSuggestions[code]
	}
	suggestion = strings.Join(strings.Fields(suggestion), " ")
	retry := "safe"
	if code == codeActionFailed {
		retry = "unsafe"
	}
	text := strings.TrimRight(message, "\n") + "\nError: " + code + " retry=" + retry + " suggestion=" + suggestion
	return toolCallResult{
		Content:           []contentItem{{Type: "text", Text: text}},
		IsError:           true,
		StructuredContent: map[string]any{"error": map[string]any{"code": code, "retry": retry, "suggestion": suggestion}},
	}
}

func invalidArgument(err error) toolCallResult {
	return errorResult(codeInvalidArgument, err.Error(), "")
}

func noAppStateResult(app string) toolCallResult {
	return errorResult(codeStaleRef, "No app state is available for "+app+". Run get_app_state before action tools.", "Call get_app_state for this app first.")
}

// bridgeFailure turns a runtime refusal into its coded result. A runtime error without a code is
// action_failed for an action (it may have happened) and failed for a read.
func bridgeFailure(message, code, suggestion string, action bool) toolCallResult {
	if code == "" {
		code = codeFailed
		if action {
			code = codeActionFailed
		}
	}
	return errorResult(code, message, suggestion)
}
