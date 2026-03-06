package main

import "encoding/json"

// --- JSON-RPC 2.0 ---

type JSONRPCMessage struct {
	JSONRPC string           `json:"jsonrpc"`
	ID      *json.RawMessage `json:"id,omitempty"`
	Method  string           `json:"method,omitempty"`
	Params  json.RawMessage  `json:"params,omitempty"`
	Result  json.RawMessage  `json:"result,omitempty"`
	Error   *JSONRPCError    `json:"error,omitempty"`
}

type JSONRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// --- Initialize ---

type InitializeParams struct {
	RootURI        string          `json:"rootUri,omitempty"`
	RootPath       string          `json:"rootPath,omitempty"`
	WorkspaceFolders []WorkspaceFolder `json:"workspaceFolders,omitempty"`
}

type WorkspaceFolder struct {
	URI  string `json:"uri"`
	Name string `json:"name"`
}

type InitializeResult struct {
	Capabilities ServerCapabilities `json:"capabilities"`
	ServerInfo   ServerInfo         `json:"serverInfo,omitempty"`
}

type ServerInfo struct {
	Name    string `json:"name"`
	Version string `json:"version,omitempty"`
}

type ServerCapabilities struct {
	TextDocumentSync       int                            `json:"textDocumentSync"`
	CodeActionProvider     bool                           `json:"codeActionProvider"`
	ExecuteCommandProvider *ExecuteCommandOptions         `json:"executeCommandProvider,omitempty"`
	Workspace              *ServerCapabilitiesWorkspace   `json:"workspace,omitempty"`
}

type ServerCapabilitiesWorkspace struct {
	TextDocumentContent *TextDocumentContentOptions `json:"textDocumentContent,omitempty"`
}

type TextDocumentContentOptions struct {
	Schemes []string `json:"schemes"`
}

// workspace/textDocumentContent
type TextDocumentContentParams struct {
	URI string `json:"uri"`
}

type TextDocumentContentResult struct {
	Text string `json:"text"`
}

type ExecuteCommandOptions struct {
	Commands []string `json:"commands"`
}

// --- Text Document ---

type DidOpenTextDocumentParams struct {
	TextDocument TextDocumentItem `json:"textDocument"`
}

type TextDocumentItem struct {
	URI        string `json:"uri"`
	LanguageID string `json:"languageId"`
	Version    int    `json:"version"`
	Text       string `json:"text"`
}

type DidChangeTextDocumentParams struct {
	TextDocument   VersionedTextDocumentIdentifier `json:"textDocument"`
	ContentChanges []TextDocumentContentChangeEvent `json:"contentChanges"`
}

type VersionedTextDocumentIdentifier struct {
	URI     string `json:"uri"`
	Version int    `json:"version"`
}

type TextDocumentContentChangeEvent struct {
	Text string `json:"text"`
}

// --- Code Action ---

type CodeActionParams struct {
	TextDocument TextDocumentIdentifier `json:"textDocument"`
	Range        Range                  `json:"range"`
	Context      CodeActionContext       `json:"context"`
}

type TextDocumentIdentifier struct {
	URI string `json:"uri"`
}

type CodeActionContext struct {
	Diagnostics []Diagnostic `json:"diagnostics"`
}

type CodeAction struct {
	Title       string      `json:"title"`
	Kind        string      `json:"kind,omitempty"`
	Diagnostics []Diagnostic `json:"diagnostics,omitempty"`
	Command     *Command    `json:"command,omitempty"`
}

type Command struct {
	Title     string        `json:"title"`
	Command   string        `json:"command"`
	Arguments []interface{} `json:"arguments,omitempty"`
}

// --- Execute Command ---

type ExecuteCommandParams struct {
	Command   string            `json:"command"`
	Arguments []json.RawMessage `json:"arguments,omitempty"`
}

// --- Diagnostics ---

type Diagnostic struct {
	Range    Range            `json:"range"`
	Message  string           `json:"message"`
	Severity int              `json:"severity,omitempty"`
	Source   string           `json:"source,omitempty"`
	Data     *json.RawMessage `json:"data,omitempty"`
}

type Range struct {
	Start Position `json:"start"`
	End   Position `json:"end"`
}

type Position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type PublishDiagnosticsParams struct {
	URI         string       `json:"uri"`
	Diagnostics []Diagnostic `json:"diagnostics"`
}

// --- Window ---

type ShowMessageParams struct {
	Type    int    `json:"type"`
	Message string `json:"message"`
}

type ShowDocumentParams struct {
	URI      string `json:"uri"`
	External bool   `json:"external,omitempty"`
}

type ShowDocumentResult struct {
	Success bool `json:"success"`
}

// MessageType constants
const (
	MessageTypeError   = 1
	MessageTypeWarning = 2
	MessageTypeInfo    = 3
	MessageTypeLog     = 4
)

// DiagnosticSeverity constants
const (
	SeverityError       = 1
	SeverityWarning     = 2
	SeverityInformation = 3
	SeverityHint        = 4
)

// CodeActionKind constants
const (
	CodeActionQuickFix = "quickfix"
	CodeActionEmpty    = ""
)
