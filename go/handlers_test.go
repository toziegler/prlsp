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

func TestTextDocumentContent_Status(t *testing.T) {
	s, buf := setupTestServer()

	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://status"})
	id := makeID(1)
	s.handleTextDocumentContent(id, params)

	output := buf.String()
	// Parse the JSON-RPC response from the output (skip Content-Length header)
	idx := strings.Index(output, "{")
	if idx < 0 {
		t.Fatalf("no JSON in output: %q", output)
	}
	body := output[idx:]

	var msg JSONRPCMessage
	if err := json.Unmarshal([]byte(body), &msg); err != nil {
		t.Fatalf("unmarshal response: %v", err)
	}

	var result TextDocumentContentResult
	if err := json.Unmarshal(msg.Result, &result); err != nil {
		t.Fatalf("unmarshal result: %v", err)
	}

	if result.Text != "hello world" {
		t.Errorf("expected %q, got %q", "hello world", result.Text)
	}
}

func TestTextDocumentContent_UnknownHost(t *testing.T) {
	s, buf := setupTestServer()

	params, _ := json.Marshal(TextDocumentContentParams{URI: "prlsp://unknown"})
	id := makeID(1)
	s.handleTextDocumentContent(id, params)

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

	if string(msg.Result) != "null" {
		t.Errorf("expected null result for unknown host, got %s", msg.Result)
	}
}

func TestTextDocumentContent_WrongScheme(t *testing.T) {
	s, buf := setupTestServer()

	params, _ := json.Marshal(TextDocumentContentParams{URI: "file:///foo"})
	id := makeID(1)
	s.handleTextDocumentContent(id, params)

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

	if string(msg.Result) != "null" {
		t.Errorf("expected null result for wrong scheme, got %s", msg.Result)
	}
}
