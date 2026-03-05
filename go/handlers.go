package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"strings"
)

const source = "github-review"

// --- Server state ---

type Server struct {
	rw       *jsonrpcRW
	docs     map[string]string // uri -> full content
	gitInfo  *GitInfo
	prNumber int
	headSHA  string
	threads  []ReviewThread
	gh       GitHub
	rootURI  string
}

func newServer(gh GitHub) *Server {
	return &Server{
		docs: make(map[string]string),
		gh:   gh,
	}
}

// --- Helpers ---

func uriToPath(uri string) string {
	if strings.HasPrefix(uri, "file://") {
		u, err := url.Parse(uri)
		if err != nil {
			return uri[7:]
		}
		return u.Path
	}
	return uri
}

func (s *Server) uriToRelpath(uri string) string {
	path := uriToPath(uri)
	if s.gitInfo != nil && s.gitInfo.Root != "" && strings.HasPrefix(path, s.gitInfo.Root) {
		return strings.TrimPrefix(path[len(s.gitInfo.Root):], "/")
	}
	return path
}

func makeThreadMessage(t *ReviewThread) string {
	parts := make([]string, 0, len(t.Comments))
	for _, c := range t.Comments {
		parts = append(parts, fmt.Sprintf("@%s: %s", c.Author, c.Body))
	}
	return strings.Join(parts, "\n")
}

func makeDiagnostic(t *ReviewThread) Diagnostic {
	line := t.Line - 1 // LSP is 0-indexed
	if line < 0 {
		line = 0
	}
	dataMap := map[string]interface{}{
		"thread_id":  t.ThreadID,
		"comment_id": 0,
		"path":       t.Path,
	}
	if len(t.Comments) > 0 {
		dataMap["comment_id"] = t.Comments[0].DatabaseID
	}
	rawData, _ := json.Marshal(dataMap)
	raw := json.RawMessage(rawData)
	return Diagnostic{
		Range: Range{
			Start: Position{Line: line, Character: 0},
			End:   Position{Line: line, Character: 1000},
		},
		Message:  makeThreadMessage(t),
		Severity: SeverityError,
		Source:   source,
		Data:     &raw,
	}
}

func (s *Server) publishFileDiagnostics(uri string) {
	rel := s.uriToRelpath(uri)
	var diags []Diagnostic
	for i := range s.threads {
		t := &s.threads[i]
		if !t.IsResolved && t.Path == rel {
			diags = append(diags, makeDiagnostic(t))
		}
	}
	if diags == nil {
		diags = []Diagnostic{}
	}
	s.rw.sendNotification("textDocument/publishDiagnostics", PublishDiagnosticsParams{
		URI:         uri,
		Diagnostics: diags,
	})
}

func (s *Server) refreshThreads() {
	if s.gitInfo == nil || s.prNumber == 0 {
		return
	}
	s.threads = s.gh.FetchReviewThreads(s.gitInfo.Owner, s.gitInfo.Repo, s.prNumber)
	unresolved := 0
	for _, t := range s.threads {
		if !t.IsResolved {
			unresolved++
		}
	}
	log.Printf("Fetched %d threads (%d unresolved)", len(s.threads), unresolved)
}

func (s *Server) showMessage(msgType int, message string) {
	s.rw.sendNotification("window/showMessage", ShowMessageParams{
		Type:    msgType,
		Message: message,
	})
}

func extractSelection(docContent string, r Range) string {
	lines := strings.SplitAfter(docContent, "\n")
	if len(lines) == 0 {
		return ""
	}
	// SplitAfter keeps the newline; handle last empty element
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}

	if r.Start.Line == r.End.Line {
		if r.Start.Line >= len(lines) {
			return ""
		}
		line := lines[r.Start.Line]
		start := r.Start.Character
		end := r.End.Character
		if start > len(line) {
			start = len(line)
		}
		if end > len(line) {
			end = len(line)
		}
		return strings.TrimSpace(line[start:end])
	}

	var parts []string
	for ln := r.Start.Line; ln <= r.End.Line && ln < len(lines); ln++ {
		lineText := lines[ln]
		if ln == r.Start.Line {
			start := r.Start.Character
			if start > len(lineText) {
				start = len(lineText)
			}
			parts = append(parts, lineText[start:])
		} else if ln == r.End.Line {
			end := r.End.Character
			if end > len(lineText) {
				end = len(lineText)
			}
			parts = append(parts, lineText[:end])
		} else {
			parts = append(parts, lineText)
		}
	}
	return strings.TrimSpace(strings.Join(parts, ""))
}

func extractDiagData(data *json.RawMessage) map[string]interface{} {
	if data == nil {
		return nil
	}
	var m map[string]interface{}
	if err := json.Unmarshal(*data, &m); err != nil {
		return nil
	}
	if _, ok := m["thread_id"]; ok {
		return m
	}
	// Neovim wraps: data.data contains the original
	if inner, ok := m["data"]; ok {
		if innerMap, ok := inner.(map[string]interface{}); ok {
			return innerMap
		}
	}
	return m
}

// --- Handlers ---

func (s *Server) handleInitialize(id *json.RawMessage, params json.RawMessage) {
	var p InitializeParams
	json.Unmarshal(params, &p)

	// Save root URI for later
	if len(p.WorkspaceFolders) > 0 {
		s.rootURI = p.WorkspaceFolders[0].URI
	} else if p.RootURI != "" {
		s.rootURI = p.RootURI
	}

	result := InitializeResult{
		Capabilities: ServerCapabilities{
			TextDocumentSync:   1, // Full
			CodeActionProvider: true,
			ExecuteCommandProvider: &ExecuteCommandOptions{
				Commands: []string{
					"prlsp.resolveThread",
					"prlsp.openInBrowser",
					"prlsp.createComment",
					"prlsp.reply",
					"prlsp.refresh",
				},
			},
		},
		ServerInfo: ServerInfo{Name: "prlsp", Version: "0.1.0"},
	}
	s.rw.sendResponse(id, result)
}

func (s *Server) handleInitialized() {
	root := ""
	if s.rootURI != "" {
		root = uriToPath(s.rootURI)
	}
	if root == "" {
		log.Println("No workspace root found")
		return
	}

	s.gitInfo = detectGitInfo(root)
	if s.gitInfo == nil {
		log.Println("Not a git repo or no GitHub remote")
		return
	}

	info := s.gitInfo
	prNumber, headSHA, ok := s.gh.FindPR(info.Owner, info.Repo, info.Branch)
	if !ok {
		log.Printf("No open PR for branch %s", info.Branch)
		return
	}
	s.prNumber = prNumber
	s.headSHA = headSHA
	log.Printf("Found PR #%d for %s/%s branch %s", s.prNumber, info.Owner, info.Repo, info.Branch)

	s.refreshThreads()

	// Publish diagnostics for any already-open documents
	for uri := range s.docs {
		s.publishFileDiagnostics(uri)
	}
}

func (s *Server) handleDidOpen(params json.RawMessage) {
	var p DidOpenTextDocumentParams
	json.Unmarshal(params, &p)
	s.docs[p.TextDocument.URI] = p.TextDocument.Text
	s.publishFileDiagnostics(p.TextDocument.URI)
}

func (s *Server) handleDidChange(params json.RawMessage) {
	var p DidChangeTextDocumentParams
	json.Unmarshal(params, &p)
	if len(p.ContentChanges) > 0 {
		s.docs[p.TextDocument.URI] = p.ContentChanges[len(p.ContentChanges)-1].Text
	}
}

func (s *Server) handleCodeAction(id *json.RawMessage, params json.RawMessage) {
	var p CodeActionParams
	json.Unmarshal(params, &p)

	var actions []CodeAction
	uri := p.TextDocument.URI

	// Diagnostic-tied actions
	for _, diag := range p.Context.Diagnostics {
		if diag.Source != source || diag.Data == nil {
			continue
		}
		data := extractDiagData(diag.Data)
		threadID, _ := data["thread_id"].(string)
		if threadID == "" {
			continue
		}

		label := "Resolve review thread"
		for i := range s.threads {
			t := &s.threads[i]
			if t.ThreadID == threadID && len(t.Comments) > 0 {
				c := t.Comments[0]
				preview := c.Body
				if len(preview) > 40 {
					preview = preview[:40]
				}
				preview = strings.ReplaceAll(preview, "\n", " ")
				label = fmt.Sprintf("Resolve @%s L%d: \"%s...\"", c.Author, t.Line, preview)
				break
			}
		}

		actions = append(actions, CodeAction{
			Title:       label,
			Kind:        CodeActionQuickFix,
			Diagnostics: []Diagnostic{diag},
			Command: &Command{
				Title:     label,
				Command:   "prlsp.resolveThread",
				Arguments: []interface{}{threadID, uri},
			},
		})

		// Open in browser
		commentIDFloat, _ := data["comment_id"].(float64)
		commentID := int(commentIDFloat)
		if commentID != 0 && s.gitInfo != nil && s.prNumber != 0 {
			info := s.gitInfo
			ghURL := fmt.Sprintf("https://github.com/%s/%s/pull/%d#discussion_r%d",
				info.Owner, info.Repo, s.prNumber, commentID)
			actions = append(actions, CodeAction{
				Title:       "Open thread in browser",
				Kind:        CodeActionEmpty,
				Diagnostics: []Diagnostic{diag},
				Command: &Command{
					Title:     "Open thread in browser",
					Command:   "prlsp.openInBrowser",
					Arguments: []interface{}{ghURL},
				},
			})
		}
	}

	// Selection-tied actions
	content := s.docs[uri]
	selected := extractSelection(content, p.Range)
	if selected != "" {
		rel := s.uriToRelpath(uri)

		// Reply to existing threads on this file
		for i := range s.threads {
			t := &s.threads[i]
			if t.IsResolved || t.Path != rel || len(t.Comments) == 0 {
				continue
			}
			first := t.Comments[0]
			preview := first.Body
			if len(preview) > 50 {
				preview = preview[:50]
			}
			preview = strings.ReplaceAll(preview, "\n", " ")
			title := fmt.Sprintf("Reply to @%s L%d: \"%s...\"", first.Author, t.Line, preview)
			actions = append(actions, CodeAction{
				Title: title,
				Kind:  CodeActionQuickFix,
				Command: &Command{
					Title:     title,
					Command:   "prlsp.reply",
					Arguments: []interface{}{first.DatabaseID, uri, selected},
				},
			})
		}

		// Create new review comment
		if s.gitInfo != nil && s.prNumber != 0 && s.headSHA != "" {
			targetLine := p.Range.Start.Line + 1 // 1-indexed for GitHub
			title := fmt.Sprintf("New review comment on L%d", targetLine)
			actions = append(actions, CodeAction{
				Title: title,
				Kind:  CodeActionQuickFix,
				Command: &Command{
					Title:     title,
					Command:   "prlsp.createComment",
					Arguments: []interface{}{uri, targetLine, selected},
				},
			})
		}
	}

	if actions == nil {
		actions = []CodeAction{}
	}
	s.rw.sendResponse(id, actions)
}

func (s *Server) handleExecuteCommand(id *json.RawMessage, params json.RawMessage) {
	var p ExecuteCommandParams
	json.Unmarshal(params, &p)

	switch p.Command {
	case "prlsp.resolveThread":
		s.cmdResolveThread(p.Arguments)
	case "prlsp.openInBrowser":
		s.cmdOpenInBrowser(p.Arguments)
	case "prlsp.createComment":
		s.cmdCreateComment(p.Arguments)
	case "prlsp.reply":
		s.cmdReply(p.Arguments)
	case "prlsp.refresh":
		s.cmdRefresh()
	}

	// Always respond with null result
	s.rw.sendResponse(id, nil)
}

func (s *Server) cmdResolveThread(args []json.RawMessage) {
	if len(args) < 2 || s.gitInfo == nil {
		return
	}
	var threadID, uri string
	json.Unmarshal(args[0], &threadID)
	json.Unmarshal(args[1], &uri)

	ok := s.gh.ResolveThread(threadID)
	if ok {
		for i := range s.threads {
			if s.threads[i].ThreadID == threadID {
				s.threads[i].IsResolved = true
			}
		}
		s.publishFileDiagnostics(uri)
		s.showMessage(MessageTypeInfo, "Thread resolved")
	} else {
		s.showMessage(MessageTypeError, "Failed to resolve thread")
	}
}

func (s *Server) cmdOpenInBrowser(args []json.RawMessage) {
	if len(args) < 1 {
		return
	}
	var ghURL string
	json.Unmarshal(args[0], &ghURL)

	// Send as a request (window/showDocument has a response), but we don't need the result
	s.rw.sendRequest("window/showDocument", ShowDocumentParams{
		URI:      ghURL,
		External: true,
	})
}

func (s *Server) cmdCreateComment(args []json.RawMessage) {
	if len(args) < 3 {
		return
	}
	info := s.gitInfo
	if info == nil || s.prNumber == 0 || s.headSHA == "" {
		return
	}
	var uri string
	var line int
	var body string
	json.Unmarshal(args[0], &uri)
	json.Unmarshal(args[1], &line)
	json.Unmarshal(args[2], &body)

	rel := s.uriToRelpath(uri)
	ok := s.gh.CreateReviewComment(info.Owner, info.Repo, s.prNumber, s.headSHA, rel, line, body)
	if ok {
		s.refreshThreads()
		s.publishFileDiagnostics(uri)
		s.showMessage(MessageTypeInfo, fmt.Sprintf("Review comment posted on L%d", line))
	} else {
		s.showMessage(MessageTypeError, "Failed to post review comment (line may not be in PR diff)")
	}
}

func (s *Server) cmdReply(args []json.RawMessage) {
	if len(args) < 3 {
		return
	}
	info := s.gitInfo
	if info == nil || s.prNumber == 0 {
		return
	}
	var commentID int
	var uri, body string
	json.Unmarshal(args[0], &commentID)
	json.Unmarshal(args[1], &uri)
	json.Unmarshal(args[2], &body)

	ok := s.gh.ReplyToComment(info.Owner, info.Repo, s.prNumber, commentID, body)
	if ok {
		s.refreshThreads()
		s.publishFileDiagnostics(uri)
		s.showMessage(MessageTypeInfo, "Reply posted")
	} else {
		s.showMessage(MessageTypeError, "Failed to post reply")
	}
}

func (s *Server) cmdRefresh() {
	s.refreshThreads()
	for uri := range s.docs {
		s.publishFileDiagnostics(uri)
	}
	s.showMessage(MessageTypeInfo, "Refreshed review threads")
}
