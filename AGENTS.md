# AGENTS

## Project Structure

- `go/` — LSP server (Go)
- `vscode/` — VS Code client extension (TypeScript)
- `emacs/` — Emacs client
- `lsp-spec/` — LSP 3.18 specification (gitignored)

## Architecture

All logic belongs in the LSP server (`go/`). Clients (`vscode/`, `emacs/`) should be thin
wrappers that only handle editor integration (starting the server, forwarding LSP messages,
registering providers required by the editor). Clients must not parse document content,
implement business logic, or duplicate server-side functionality.

## LSP Specification

The `lsp-spec/` directory contains the LSP 3.18 specification (pre-release),
sourced from https://github.com/microsoft/language-server-protocol/tree/gh-pages/_specifications/lsp/3.18.

This is the specification we target for this project.
