package main

// pi-phone fork (PP-270): structured errors, snapshot-scoped refs and covered window regions.
// See PI-PHONE.md.

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"strings"
	"time"
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
	codeStaleRef:        "Call get_app_state again and act on its element numbers and snapshot id.",
	codeAmbiguousTarget: "Read the app again, with a window_id from the outline if several windows match.",
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

func newSnapshotID() string {
	var bytes [4]byte
	if _, err := rand.Read(bytes[:]); err != nil {
		return fmt.Sprintf("%08x", uint32(time.Now().UnixNano()))
	}
	return hex.EncodeToString(bytes[:])
}

// windowRef is another window the app query matches, which get_app_state can read by window_id.
type windowRef struct {
	ID    string `json:"id"`
	Title string `json:"title,omitempty"`
	App   string `json:"app,omitempty"`
}

// snapshotMark is what is kept of an earlier snapshot (in memory only): enough to say it was replaced.
type snapshotMark struct {
	app      string
	replaced string
}

const keptSnapshotMarks = 64

func renderFrames(frames []frame) string {
	parts := make([]string, 0, len(frames))
	for _, f := range frames {
		parts = append(parts, fmt.Sprintf("{x: %.0f, y: %.0f, width: %.0f, height: %.0f}", f.X, f.Y, f.Width, f.Height))
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// piPhoneLines are the outline lines after "Window:": the snapshot id, the window id, the other
// windows the app matches, and what covers the window.
func (s *appSnapshot) piPhoneLines() []string {
	lines := []string{"Snapshot: " + s.ID}
	if s.WindowID != "" {
		lines = append(lines, "Window id: "+s.WindowID)
	}
	if len(s.OtherWindows) > 0 {
		parts := make([]string, 0, len(s.OtherWindows))
		for _, other := range s.OtherWindows {
			parts = append(parts, fmt.Sprintf("%s %q (%s)", other.ID, other.Title, other.App))
		}
		lines = append(lines, "Other windows: "+strings.Join(parts, ", "))
	}
	switch s.Cover {
	case "partial":
		lines = append(lines, "Covered: "+renderFrames(s.Covered)+" (other windows; blacked out in the screenshot)")
	case "full":
		lines = append(lines, "Covered: "+renderFrames(s.Covered)+" (the whole window)")
	case "unknown":
		lines = append(lines, "Covered: unknown (the window stacking could not be read)")
	}
	return lines
}

// coverOmission says why a minimised or fully covered window has no screenshot.
func (s *appSnapshot) coverOmission() string {
	switch s.Cover {
	case "full":
		return "Screenshot omitted: other windows cover the whole window. Bring it to the front, then read it again."
	case "minimized":
		return "Screenshot omitted: the window is minimised. Restore it, then read it again."
	}
	return ""
}

func (s *appSnapshot) structured() map[string]any {
	covered := s.Covered
	if covered == nil {
		covered = []frame{}
	}
	result := map[string]any{"snapshot_id": s.ID, "window_id": s.WindowID, "covered": covered}
	if s.Cover != "" {
		result["cover"] = s.Cover
	}
	if len(s.OtherWindows) > 0 {
		result["other_windows"] = s.OtherWindows
	}
	return result
}

// coveredAt reports whether a screenshot point (window coordinates) is covered, or the window is.
func (s *appSnapshot) coveredAt(x, y float64) bool {
	if s.Cover == "full" || s.Cover == "minimized" {
		return true
	}
	for _, f := range s.Covered {
		if x >= f.X && x < f.X+f.Width && y >= f.Y && y < f.Y+f.Height {
			return true
		}
	}
	return false
}

func coveredPointResult(x, y float64) toolCallResult {
	return errorResult(codeCovered, fmt.Sprintf("Refused: (%.0f, %.0f) is covered by another window in the last read; the input would land there.", x, y), "")
}

// refArguments are the optional snapshot_id and window_id of an action.
type refArguments struct {
	snapshotID string
	windowID   string
}

func refArgumentsFrom(args map[string]any) (refArguments, error) {
	var refs refArguments
	for key, target := range map[string]*string{"snapshot_id": &refs.snapshotID, "window_id": &refs.windowID} {
		value, exists := args[key]
		if !exists || value == nil {
			continue
		}
		text, ok := value.(string)
		if !ok {
			return refs, fmt.Errorf("%s must be a string", key)
		}
		*target = strings.TrimSpace(text)
	}
	return refs, nil
}

// actionSnapshot is the app's latest snapshot, if the call's snapshot_id and window_id still name it.
func (s *service) actionSnapshot(app string, refs refArguments) (*appSnapshot, *toolCallResult) {
	snapshot := s.currentSnapshot(app)
	if snapshot == nil {
		result := noAppStateResult(app)
		return nil, &result
	}
	if refs.snapshotID != "" && refs.snapshotID != snapshot.ID {
		message := fmt.Sprintf("Snapshot %s is not the latest read of %s (the latest is %s).", refs.snapshotID, app, snapshot.ID)
		if mark, ok := s.marks[refs.snapshotID]; !ok {
			message = fmt.Sprintf("Snapshot %s is unknown here (snapshots last only while this ocu runs); the latest read of %s is %s.", refs.snapshotID, app, snapshot.ID)
		} else if mark.replaced != "" {
			message = fmt.Sprintf("Snapshot %s of %s was replaced by %s.", refs.snapshotID, mark.app, mark.replaced)
			if mark.replaced != snapshot.ID {
				message += fmt.Sprintf(" The latest read of %s is %s.", app, snapshot.ID)
			}
		}
		result := errorResult(codeStaleRef, message, "")
		return nil, &result
	}
	if refs.windowID != "" && refs.windowID != snapshot.WindowID {
		result := errorResult(codeStaleRef, fmt.Sprintf("The latest read of %s is of window %s, not %s.", app, snapshot.WindowID, refs.windowID), "Call get_app_state with this window_id, then act.")
		return nil, &result
	}
	return snapshot, nil
}

var (
	snapshotIDProperty = map[string]any{
		"type":        "string",
		"description": "pi-phone build: the Snapshot id of the get_app_state the element number comes from. Refused with stale_ref when it is not the app's latest read.",
	}
	windowIDProperty = map[string]any{
		"type":        "string",
		"description": "pi-phone build: a Window id from the outline. get_app_state reads that window; an action is refused with stale_ref unless the latest read is of it.",
	}
	refuseIfCoveredProperty = map[string]any{
		"type":        "boolean",
		"default":     false,
		"description": "pi-phone build: refuse (covered) instead of returning a screenshot with covered parts blacked out.",
	}
)

// withPiPhoneProperties adds the fork's arguments to the tool schemas.
func withPiPhoneProperties(tools []toolDefinition) []toolDefinition {
	for _, tool := range tools {
		properties, _ := tool.InputSchema["properties"].(map[string]any)
		if properties == nil || tool.Name == "list_apps" {
			continue
		}
		properties["window_id"] = windowIDProperty
		if tool.Name == "get_app_state" {
			properties["refuse_if_covered"] = refuseIfCoveredProperty
			continue
		}
		properties["snapshot_id"] = snapshotIDProperty
	}
	return tools
}

// remember keeps a mark of each snapshot, so a later call with an old id hears what replaced it.
func (s *service) mark(previous, next *appSnapshot) {
	if previous != nil && previous != next && previous.ID != "" {
		if mark, ok := s.marks[previous.ID]; ok {
			mark.replaced = next.ID
			s.marks[previous.ID] = mark
		}
	}
	if _, ok := s.marks[next.ID]; !ok {
		s.marks[next.ID] = snapshotMark{app: next.App.Name}
		s.markOrder = append(s.markOrder, next.ID)
		for len(s.markOrder) > keptSnapshotMarks {
			delete(s.marks, s.markOrder[0])
			s.markOrder = s.markOrder[1:]
		}
	}
}
