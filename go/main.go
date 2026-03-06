package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"strconv"
	"strings"
	"sync"
)

// jsonrpcRW handles reading and writing JSON-RPC messages over stdio.
type jsonrpcRW struct {
	reader *bufio.Reader
	mu     sync.Mutex
	writer *bufio.Writer
	nextID int
}

func newJSONRPCRW(r io.Reader, w io.Writer) *jsonrpcRW {
	return &jsonrpcRW{
		reader: bufio.NewReader(r),
		writer: bufio.NewWriter(w),
		nextID: 1,
	}
}

func (rw *jsonrpcRW) readMessage() (*JSONRPCMessage, error) {
	// Read headers until empty line
	contentLength := -1
	for {
		line, err := rw.reader.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if strings.HasPrefix(line, "Content-Length:") {
			val := strings.TrimSpace(line[len("Content-Length:"):])
			n, err := strconv.Atoi(val)
			if err == nil {
				contentLength = n
			}
		}
	}
	if contentLength < 0 {
		return nil, fmt.Errorf("missing Content-Length header")
	}

	body := make([]byte, contentLength)
	if _, err := io.ReadFull(rw.reader, body); err != nil {
		return nil, err
	}

	var msg JSONRPCMessage
	if err := json.Unmarshal(body, &msg); err != nil {
		return nil, fmt.Errorf("invalid JSON: %w", err)
	}
	return &msg, nil
}

func (rw *jsonrpcRW) writeJSON(msg interface{}) {
	body, err := json.Marshal(msg)
	if err != nil {
		log.Printf("marshal error: %v", err)
		return
	}
	rw.mu.Lock()
	defer rw.mu.Unlock()
	fmt.Fprintf(rw.writer, "Content-Length: %d\r\n\r\n", len(body))
	rw.writer.Write(body)
	rw.writer.Flush()
}

func (rw *jsonrpcRW) sendResponse(id *json.RawMessage, result interface{}) {
	var raw json.RawMessage
	if result == nil {
		raw = json.RawMessage("null")
	} else {
		var err error
		raw, err = json.Marshal(result)
		if err != nil {
			log.Printf("marshal result error: %v", err)
			return
		}
	}
	rw.writeJSON(JSONRPCMessage{
		JSONRPC: "2.0",
		ID:      id,
		Result:  raw,
	})
}

func (rw *jsonrpcRW) sendNotification(method string, params interface{}) {
	raw, _ := json.Marshal(params)
	rw.writeJSON(JSONRPCMessage{
		JSONRPC: "2.0",
		Method:  method,
		Params:  raw,
	})
}

func (rw *jsonrpcRW) sendRequest(method string, params interface{}) {
	raw, _ := json.Marshal(params)
	rw.mu.Lock()
	id := rw.nextID
	rw.nextID++
	rw.mu.Unlock()
	idRaw, _ := json.Marshal(id)
	rawID := json.RawMessage(idRaw)
	rw.writeJSON(JSONRPCMessage{
		JSONRPC: "2.0",
		ID:      &rawID,
		Method:  method,
		Params:  raw,
	})
}

func main() {
	mockPath := flag.String("mock", "", "path to mock fixture JSON")
	flag.Parse()

	log.SetOutput(os.Stderr)
	log.SetFlags(log.Ltime | log.Lmicroseconds)

	var gh GitHub
	if *mockPath != "" {
		log.Printf("Mock mode: loading %s", *mockPath)
		mock, err := NewMockGitHub(*mockPath)
		if err != nil {
			log.Fatalf("Failed to load mock: %v", err)
		}
		gh = mock
	} else {
		gh = &GitHubAPI{}
	}

	rw := newJSONRPCRW(os.Stdin, os.Stdout)
	server := newServer(gh)
	server.rw = rw

	for {
		msg, err := rw.readMessage()
		if err != nil {
			if err == io.EOF {
				log.Println("Client disconnected")
				return
			}
			log.Printf("Read error: %v", err)
			return
		}

		log.Printf(">> %s", msg.Method)

		switch msg.Method {
		case "initialize":
			server.handleInitialize(msg.ID, msg.Params)
		case "initialized":
			server.handleInitialized()
		case "textDocument/didOpen":
			server.handleDidOpen(msg.Params)
		case "textDocument/didChange":
			server.handleDidChange(msg.Params)
		case "textDocument/codeAction":
			server.handleCodeAction(msg.ID, msg.Params)
		case "workspace/executeCommand":
			server.handleExecuteCommand(msg.ID, msg.Params)
		case "workspace/textDocumentContent":
			server.handleTextDocumentContent(msg.ID, msg.Params)
		case "shutdown":
			server.rw.sendResponse(msg.ID, nil)
		case "exit":
			return
		default:
			// Ignore unknown methods; respond with null if it has an ID
			if msg.ID != nil {
				rw.sendResponse(msg.ID, nil)
			}
		}
	}
}
