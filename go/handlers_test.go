package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func setupTestServer() (*Server, *bytes.Buffer) {
	var buf bytes.Buffer
	rw := newJSONRPCRW(strings.NewReader(""), &buf)
	s := newServer(&MockGitHub{})
	s.rw = rw
	return s, &buf
}

func makeID(n int) *json.RawMessage {
	raw := json.RawMessage([]byte(`1`))
	return &raw
}

func parseResponse(t *testing.T, buf *bytes.Buffer) JSONRPCMessage {
	t.Helper()
	output := buf.String()
	idx := strings.Index(output, "{")
	if idx < 0 {
		t.Fatalf("no JSON in output: %q", output)
	}
	body := output[idx:]
	var msg JSONRPCMessage
	if err := json.Unmarshal([]byte(body), &msg); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}
	return msg
}

func TestTextDocumentContent_StatusLoading(t *testing.T) {
	s, buf := setupTestServer()

	// Before PR list is loaded, should show "Loading..."
	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://status"})
	s.handleTextDocumentContent(makeID(1), params)

	msg := parseResponse(t, buf)
	var result TextDocumentContentResult
	if err := json.Unmarshal(msg.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if !strings.Contains(result.Text, "Loading...") {
		t.Errorf("expected Loading... in output, got %q", result.Text)
	}
	if !strings.Contains(result.Text, "PR") || !strings.Contains(result.Text, "Author") {
		t.Errorf("expected table header in loading state, got %q", result.Text)
	}
}

func TestTextDocumentContent_StatusWithPRs(t *testing.T) {
	s, buf := setupTestServer()

	// Simulate loaded PR list
	s.prListLoaded = true
	s.prList = []ghPR{
		{
			Number:     42,
			Title:      "Fix bug",
			Author:     ghAuthor{Login: "alice"},
			Assignees:  []ghAssignee{{Login: "bob"}},
			HeadRefOid: "abcdef0123456789",
		},
		{
			Number:     99,
			Title:      "Add feature",
			Author:     ghAuthor{Login: "charlie"},
			HeadRefOid: "1234567890abcdef",
		},
	}

	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://status"})
	s.handleTextDocumentContent(makeID(1), params)

	msg := parseResponse(t, buf)
	var result TextDocumentContentResult
	if err := json.Unmarshal(msg.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if strings.Contains(result.Text, "Loading...") {
		t.Error("should not contain Loading... when loaded")
	}
	if !strings.Contains(result.Text, "#42/abcdef01") {
		t.Errorf("expected #42/abcdef01 in output, got %q", result.Text)
	}
	if !strings.Contains(result.Text, "alice") {
		t.Errorf("expected alice in output, got %q", result.Text)
	}
	if !strings.Contains(result.Text, "alice/bob") {
		t.Errorf("expected alice/bob in output, got %q", result.Text)
	}
	if !strings.Contains(result.Text, "Fix bug") {
		t.Errorf("expected title in output, got %q", result.Text)
	}
	// PR with no assignee should show "charlie/-"
	if !strings.Contains(result.Text, "charlie/-") {
		t.Errorf("expected 'charlie/-' for no assignee on #99, got %q", result.Text)
	}
}

func TestCodeAction_StatusCheckout(t *testing.T) {
	s, buf := setupTestServer()
	s.gitInfo = &GitInfo{Root: "/tmp", Owner: "o", Repo: "r", Branch: "main"}
	s.prListLoaded = true
	s.prList = []ghPR{
		{
			Number:     42,
			Title:      "Fix bug",
			Author:     ghAuthor{Login: "alice"},
			HeadRefOid: "abcdef0123456789abcdef0123456789abcdef01",
		},
		{
			Number:     99,
			Title:      "Add feature",
			Author:     ghAuthor{Login: "charlie"},
			HeadRefOid: "1234567890abcdef1234567890abcdef12345678",
		},
	}

	// Request code actions on line 1 (first PR, since line 0 is header)
	params, _ := json.Marshal(CodeActionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Range: Range{
			Start: Position{Line: 1, Character: 0},
			End:   Position{Line: 1, Character: 0},
		},
		Context: CodeActionContext{},
	})
	s.handleCodeAction(makeID(1), params)

	msg := parseResponse(t, buf)
	var actions []CodeAction
	if err := json.Unmarshal(msg.Result, &actions); err != nil {
		t.Fatalf("unmarshal code actions: %v", err)
	}

	if len(actions) == 0 {
		t.Fatal("expected at least one code action, got none")
	}

	found := false
	for _, a := range actions {
		if strings.Contains(a.Title, "Checkout") && strings.Contains(a.Title, "#42") {
			found = true
			if a.Command == nil {
				t.Error("expected command on checkout action")
			} else if a.Command.Command != "prlsp.checkout" {
				t.Errorf("expected prlsp.checkout command, got %s", a.Command.Command)
			}
		}
	}
	if !found {
		t.Errorf("no checkout action for PR #42 found in %+v", actions)
	}

	// Line 0 (header) should have no actions
	buf.Reset()
	params, _ = json.Marshal(CodeActionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Range: Range{
			Start: Position{Line: 0, Character: 0},
			End:   Position{Line: 0, Character: 0},
		},
		Context: CodeActionContext{},
	})
	s.handleCodeAction(makeID(2), params)

	msg = parseResponse(t, buf)
	if err := json.Unmarshal(msg.Result, &actions); err != nil {
		t.Fatalf("unmarshal code actions: %v", err)
	}
	if len(actions) != 0 {
		t.Errorf("expected no actions on header line, got %+v", actions)
	}

	// Line 2 (second PR) should offer checkout for #99
	buf.Reset()
	params, _ = json.Marshal(CodeActionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Range: Range{
			Start: Position{Line: 2, Character: 0},
			End:   Position{Line: 2, Character: 0},
		},
		Context: CodeActionContext{},
	})
	s.handleCodeAction(makeID(3), params)

	msg = parseResponse(t, buf)
	if err := json.Unmarshal(msg.Result, &actions); err != nil {
		t.Fatalf("unmarshal code actions: %v", err)
	}
	found = false
	for _, a := range actions {
		if strings.Contains(a.Title, "#99") {
			found = true
		}
	}
	if !found {
		t.Errorf("no checkout action for PR #99 on line 2, got %+v", actions)
	}
}

func TestCodeAction_StatusCheckout_NoGitInfo(t *testing.T) {
	s, buf := setupTestServer()
	// No gitInfo set — should return empty actions
	s.prListLoaded = true
	s.prList = []ghPR{
		{
			Number:     42,
			Title:      "Fix bug",
			Author:     ghAuthor{Login: "alice"},
			HeadRefOid: "abcdef0123456789abcdef0123456789abcdef01",
		},
	}

	params, _ := json.Marshal(CodeActionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Range: Range{
			Start: Position{Line: 1, Character: 0},
			End:   Position{Line: 1, Character: 0},
		},
		Context: CodeActionContext{},
	})
	s.handleCodeAction(makeID(1), params)

	msg := parseResponse(t, buf)
	var actions []CodeAction
	if err := json.Unmarshal(msg.Result, &actions); err != nil {
		t.Fatalf("unmarshal code actions: %v", err)
	}
	if len(actions) != 0 {
		t.Errorf("expected no actions without gitInfo, got %+v", actions)
	}
}

func TestCodeAction_StatusCheckout_NotLoaded(t *testing.T) {
	s, buf := setupTestServer()
	s.gitInfo = &GitInfo{Root: "/tmp", Owner: "o", Repo: "r", Branch: "main"}
	s.prListLoaded = false // not loaded yet

	params, _ := json.Marshal(CodeActionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Range: Range{
			Start: Position{Line: 1, Character: 0},
			End:   Position{Line: 1, Character: 0},
		},
		Context: CodeActionContext{},
	})
	s.handleCodeAction(makeID(1), params)

	msg := parseResponse(t, buf)
	var actions []CodeAction
	if err := json.Unmarshal(msg.Result, &actions); err != nil {
		t.Fatalf("unmarshal code actions: %v", err)
	}
	if len(actions) != 0 {
		t.Errorf("expected no actions when not loaded, got %+v", actions)
	}
}

func TestTextDocumentContent_UnknownHost(t *testing.T) {
	s, buf := setupTestServer()

	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://unknown"})
	s.handleTextDocumentContent(makeID(1), params)

	msg := parseResponse(t, buf)
	if string(msg.Result) != "null" {
		t.Errorf("expected null result for unknown host, got %s", msg.Result)
	}
}

func TestDefinition_StatusDocument(t *testing.T) {
	s, buf := setupTestServer()
	s.gitInfo = &GitInfo{Root: "/tmp", Owner: "o", Repo: "r", Branch: "main"}
	s.prListLoaded = true
	s.prList = []ghPR{
		{Number: 42, Title: "Fix bug", Author: ghAuthor{Login: "alice"}, HeadRefOid: "abcdef01"},
		{Number: 99, Title: "Add feature", Author: ghAuthor{Login: "bob"}, HeadRefOid: "12345678"},
	}

	// Line 1 = first PR → prlsp://status/42
	params, _ := json.Marshal(DefinitionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Position:     Position{Line: 1, Character: 5},
	})
	s.handleDefinition(makeID(1), params)

	msg := parseResponse(t, buf)
	var loc Location
	if err := json.Unmarshal(msg.Result, &loc); err != nil {
		t.Fatalf("unmarshal location: %v", err)
	}
	if loc.URI != "prlsp://status/42" {
		t.Errorf("expected prlsp://status/42, got %s", loc.URI)
	}

	// Line 2 = second PR → prlsp://status/99
	buf.Reset()
	params, _ = json.Marshal(DefinitionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Position:     Position{Line: 2, Character: 0},
	})
	s.handleDefinition(makeID(2), params)

	msg = parseResponse(t, buf)
	if err := json.Unmarshal(msg.Result, &loc); err != nil {
		t.Fatalf("unmarshal location: %v", err)
	}
	if loc.URI != "prlsp://status/99" {
		t.Errorf("expected prlsp://status/99, got %s", loc.URI)
	}

	// Line 0 = header → null
	buf.Reset()
	params, _ = json.Marshal(DefinitionParams{
		TextDocument: TextDocumentIdentifier{URI: "prlsp://status"},
		Position:     Position{Line: 0, Character: 0},
	})
	s.handleDefinition(makeID(3), params)

	msg = parseResponse(t, buf)
	if string(msg.Result) != "null" {
		t.Errorf("expected null for header line, got %s", msg.Result)
	}
}

func TestDefinition_NonStatusDocument(t *testing.T) {
	s, buf := setupTestServer()

	params, _ := json.Marshal(DefinitionParams{
		TextDocument: TextDocumentIdentifier{URI: "file:///foo.go"},
		Position:     Position{Line: 0, Character: 0},
	})
	s.handleDefinition(makeID(1), params)

	msg := parseResponse(t, buf)
	if string(msg.Result) != "null" {
		t.Errorf("expected null for non-status doc, got %s", msg.Result)
	}
}

func TestTextDocumentContent_PRComments(t *testing.T) {
	s, buf := setupTestServer()
	s.gitInfo = &GitInfo{Root: "/tmp", Owner: "o", Repo: "r", Branch: "main"}

	// Set up mock with threads
	mock := &MockGitHub{
		threads: []ReviewThread{
			{
				ThreadID:   "t1",
				Path:       "src/main.zig",
				Line:       10,
				IsResolved: false,
				Comments: []ReviewComment{
					{DatabaseID: 1, Body: "is this correct?", Author: "matklad"},
				},
			},
			{
				ThreadID:   "t2",
				Path:       "src/lib.zig",
				Line:       25,
				IsResolved: false,
				Comments: []ReviewComment{
					{DatabaseID: 2, Body: "simplify this?", Author: "matklad"},
					{DatabaseID: 3, Body: "agreed", Author: "alice"},
				},
			},
			{
				ThreadID:   "t3",
				Path:       "src/old.zig",
				Line:       5,
				IsResolved: true,
				Comments: []ReviewComment{
					{DatabaseID: 4, Body: "resolved comment", Author: "bob"},
				},
			},
		},
	}
	s.gh = mock

	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://status/42"})
	s.handleTextDocumentContent(makeID(1), params)

	msg := parseResponse(t, buf)
	var result TextDocumentContentResult
	if err := json.Unmarshal(msg.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	// Should contain unresolved comments
	if !strings.Contains(result.Text, "src/main.zig:10") {
		t.Errorf("expected src/main.zig:10 in output, got %q", result.Text)
	}
	if !strings.Contains(result.Text, "@matklad") || !strings.Contains(result.Text, "is this correct?") {
		t.Errorf("expected @matklad comment, got %q", result.Text)
	}
	if !strings.Contains(result.Text, "src/lib.zig:25") {
		t.Errorf("expected src/lib.zig:25 in output, got %q", result.Text)
	}
	if !strings.Contains(result.Text, "@alice") || !strings.Contains(result.Text, "agreed") {
		t.Errorf("expected @alice reply, got %q", result.Text)
	}
	// Should NOT contain resolved comment
	if strings.Contains(result.Text, "src/old.zig") {
		t.Errorf("should not contain resolved thread, got %q", result.Text)
	}
	if strings.Contains(result.Text, "resolved comment") {
		t.Errorf("should not contain resolved comment, got %q", result.Text)
	}
}

func TestTextDocumentContent_PRComments_NoThreads(t *testing.T) {
	s, buf := setupTestServer()
	s.gitInfo = &GitInfo{Root: "/tmp", Owner: "o", Repo: "r", Branch: "main"}
	s.gh = &MockGitHub{threads: nil}

	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://status/42"})
	s.handleTextDocumentContent(makeID(1), params)

	msg := parseResponse(t, buf)
	var result TextDocumentContentResult
	if err := json.Unmarshal(msg.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}
	if !strings.Contains(result.Text, "No unresolved review comments") {
		t.Errorf("expected empty message, got %q", result.Text)
	}
}

func TestRenderMarkdown_Wrapping(t *testing.T) {
	long := "This is a very long sentence that should definitely be wrapped because it exceeds sixty characters in width."
	out := renderMarkdown(long)
	for _, line := range strings.Split(out, "\n") {
		// Allow some slack for glamour's padding
		if len(strings.TrimRight(line, " ")) > 65 {
			t.Errorf("line too long (%d chars): %q", len(line), line)
		}
	}
}

func TestRenderMarkdown_PreservesCodeBlocks(t *testing.T) {
	md := "Try this:\n```go\nfmt.Println(\"hello\")\n```"
	out := renderMarkdown(md)
	if !strings.Contains(out, "fmt.Println") {
		t.Errorf("expected code block content, got %q", out)
	}
}

func TestTextDocumentContent_PRComments_InvalidNumber(t *testing.T) {
	s, buf := setupTestServer()

	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://status/abc"})
	s.handleTextDocumentContent(makeID(1), params)

	msg := parseResponse(t, buf)
	if string(msg.Result) != "null" {
		t.Errorf("expected null for invalid PR number, got %s", msg.Result)
	}
}

func TestTextDocumentContent_WrongScheme(t *testing.T) {
	s, buf := setupTestServer()

	params, _ := json.Marshal(TextDocumentContentParams{URI: "file:///foo"})
	s.handleTextDocumentContent(makeID(1), params)

	msg := parseResponse(t, buf)
	if string(msg.Result) != "null" {
		t.Errorf("expected null result for wrong scheme, got %s", msg.Result)
	}
}
