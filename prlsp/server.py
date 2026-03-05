"""LSP server: diagnostics, code actions, commands."""

import logging
from urllib.parse import unquote
from urllib.request import url2pathname

from lsprotocol import types as lsp
from pygls.lsp.server import LanguageServer

from prlsp.git import GitInfo, detect_git_info
from prlsp.github import GitHubAPI, ReviewThread

logger = logging.getLogger(__name__)

SOURCE = "github-review"


def _uri_to_path(uri: str) -> str:
    if uri.startswith("file://"):
        return url2pathname(unquote(uri[7:]))
    return uri


def _thread_message(thread: ReviewThread) -> str:
    lines = []
    for i, c in enumerate(thread.comments):
        prefix = "  └ " if i > 0 else ""
        lines.append(f"{prefix}@{c.author}: {c.body}")
    return "\n".join(lines)


def _make_diagnostic(thread: ReviewThread) -> lsp.Diagnostic:
    line = max(0, thread.line - 1)  # LSP is 0-indexed
    return lsp.Diagnostic(
        range=lsp.Range(
            start=lsp.Position(line=line, character=0),
            end=lsp.Position(line=line, character=1000),
        ),
        message=_thread_message(thread),
        severity=lsp.DiagnosticSeverity.Information,
        source=SOURCE,
        data={
            "thread_id": thread.thread_id,
            "comment_id": thread.comments[0].database_id if thread.comments else 0,
            "path": thread.path,
        },
    )


class PRReviewServer(LanguageServer):
    def __init__(self, github=None, **kwargs):
        super().__init__("prlsp", "0.1.0", **kwargs)
        self.gh = github or GitHubAPI()
        self.git_info: GitInfo | None = None
        self.pr_number: int | None = None
        self.threads: list[ReviewThread] = []


def create_server(github=None) -> PRReviewServer:
    server = PRReviewServer(github=github)

    @server.feature(lsp.INITIALIZED)
    def on_initialized(params: lsp.InitializedParams):
        root = None
        for folder in (server.workspace.folders or {}).values():
            root = _uri_to_path(folder.uri)
            break
        if root is None and server.workspace.root_path:
            root = server.workspace.root_path
        if root is None:
            logger.warning("No workspace root found")
            return

        server.git_info = detect_git_info(root)
        if not server.git_info:
            logger.warning("Not a git repo or no GitHub remote")
            return

        info = server.git_info
        server.pr_number = server.gh.find_pr_number(info.owner, info.repo, info.branch)
        if not server.pr_number:
            logger.info("No open PR for branch %s", info.branch)
            return

        logger.info("Found PR #%d for %s/%s branch %s", server.pr_number, info.owner, info.repo, info.branch)
        _refresh_threads(server)

    @server.feature(lsp.TEXT_DOCUMENT_DID_OPEN)
    def on_did_open(params: lsp.DidOpenTextDocumentParams):
        _publish_file_diagnostics(server, params.text_document.uri)

    @server.feature(lsp.TEXT_DOCUMENT_CODE_ACTION)
    def on_code_action(params: lsp.CodeActionParams) -> list[lsp.CodeAction]:
        actions = []
        uri = params.text_document.uri
        for diag in params.context.diagnostics:
            if diag.source != SOURCE or not diag.data:
                continue
            data = diag.data
            thread_id = data.get("thread_id", "") if isinstance(data, dict) else ""
            comment_id = data.get("comment_id", 0) if isinstance(data, dict) else 0
            if not thread_id:
                continue

            # Resolve action
            actions.append(lsp.CodeAction(
                title="Resolve review thread",
                kind=lsp.CodeActionKind.QuickFix,
                diagnostics=[diag],
                command=lsp.Command(
                    title="Resolve review thread",
                    command="prlsp.resolveThread",
                    arguments=[thread_id, uri],
                ),
            ))

            # Reply action — extract selected text
            doc = server.workspace.get_text_document(uri)
            sel = params.range
            lines = doc.source.splitlines(keepends=True)
            if sel.start.line == sel.end.line:
                selected = lines[sel.start.line][sel.start.character:sel.end.character] if sel.start.line < len(lines) else ""
            else:
                parts = []
                for ln in range(sel.start.line, min(sel.end.line + 1, len(lines))):
                    line_text = lines[ln]
                    if ln == sel.start.line:
                        parts.append(line_text[sel.start.character:])
                    elif ln == sel.end.line:
                        parts.append(line_text[:sel.end.character])
                    else:
                        parts.append(line_text)
                selected = "".join(parts)

            selected = selected.strip()
            if selected:
                actions.append(lsp.CodeAction(
                    title="Reply to review comment",
                    kind=lsp.CodeActionKind.QuickFix,
                    diagnostics=[diag],
                    command=lsp.Command(
                        title="Reply to review comment",
                        command="prlsp.reply",
                        arguments=[comment_id, uri, selected],
                    ),
                ))

        return actions

    @server.command("prlsp.resolveThread")
    def cmd_resolve(thread_id: str, uri: str):
        if not server.git_info:
            return
        ok = server.gh.resolve_thread(thread_id)
        if ok:
            for t in server.threads:
                if t.thread_id == thread_id:
                    t.is_resolved = True
            _publish_file_diagnostics(server, uri)
            server.window_show_message(lsp.ShowMessageParams(
                type=lsp.MessageType.Info, message="Thread resolved"))
        else:
            server.window_show_message(lsp.ShowMessageParams(
                type=lsp.MessageType.Error, message="Failed to resolve thread"))

    @server.command("prlsp.reply")
    def cmd_reply(comment_id: int, uri: str, body: str):
        info = server.git_info
        if not info or not server.pr_number:
            return
        ok = server.gh.reply_to_comment(info.owner, info.repo, server.pr_number, comment_id, body)
        if ok:
            _refresh_threads(server)
            _publish_file_diagnostics(server, uri)
            server.window_show_message(lsp.ShowMessageParams(
                type=lsp.MessageType.Info, message="Reply posted"))
        else:
            server.window_show_message(lsp.ShowMessageParams(
                type=lsp.MessageType.Error, message="Failed to post reply"))

    @server.command("prlsp.refresh")
    def cmd_refresh():
        _refresh_threads(server)
        for uri in server.workspace.text_documents:
            _publish_file_diagnostics(server, uri)
        server.window_show_message(lsp.ShowMessageParams(
            type=lsp.MessageType.Info, message="Refreshed review threads"))

    return server


def _refresh_threads(server: PRReviewServer):
    info = server.git_info
    if not info or not server.pr_number:
        return
    server.threads = server.gh.fetch_review_threads(info.owner, info.repo, server.pr_number)
    logger.info("Fetched %d threads (%d unresolved)",
                len(server.threads),
                sum(1 for t in server.threads if not t.is_resolved))


def _publish_file_diagnostics(server: PRReviewServer, uri: str):
    path = _uri_to_path(uri)
    git_root = server.git_info.root if server.git_info else ""
    if git_root and path.startswith(git_root):
        rel = path[len(git_root):].lstrip("/")
    else:
        rel = path

    diagnostics = [
        _make_diagnostic(t)
        for t in server.threads
        if not t.is_resolved and t.path == rel
    ]
    server.text_document_publish_diagnostics(lsp.PublishDiagnosticsParams(
        uri=uri, diagnostics=diagnostics))
