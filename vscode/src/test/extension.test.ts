import * as assert from "assert";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";

suite("prlsp", () => {
  let api: { client: LanguageClient; clientReady: Promise<void> };

  suiteSetup(async () => {
    const ext = vscode.extensions.getExtension("undefined_publisher.prlsp")!;
    assert.ok(ext, "extension not found");
    api = (await ext.activate()) as typeof api;
    await api.clientReady;
  });

  test("status document opens", async () => {
    const uri = vscode.Uri.parse("prlsp://status");
    const doc = await vscode.workspace.openTextDocument(uri);
    assert.strictEqual(doc.uri.scheme, "prlsp");
    const text = doc.getText();
    assert.ok(
      text.includes("Author/Reviewer"),
      `expected table header in: ${text}`,
    );
  }).timeout(30_000);

  test("code actions on status document (zero-width cursor)", async () => {
    const uri = vscode.Uri.parse("prlsp://status");
    const doc = await vscode.workspace.openTextDocument(uri);

    // Wait for PR list to load (poll until "Loading..." disappears or timeout)
    let text = doc.getText();
    for (let i = 0; i < 50 && text.includes("Loading..."); i++) {
      await new Promise((r) => setTimeout(r, 500));
      // Re-read — content provider may have refreshed
      text = (await vscode.workspace.openTextDocument(uri)).getText();
    }

    // If still loading, the test still checks code actions work (they should return empty)
    const lines = text.split("\n");
    // Find first non-header, non-empty line (should be a PR line)
    let prLine = -1;
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].includes("#")) {
        prLine = i;
        break;
      }
    }

    if (prLine === -1) {
      // No PRs loaded — just verify code actions on header return empty
      const actions = await vscode.commands.executeCommand<vscode.CodeAction[]>(
        "vscode.executeCodeActionProvider",
        uri,
        new vscode.Range(0, 0, 0, 0),
      );
      assert.ok(
        !actions || actions.length === 0,
        "expected no actions on header line",
      );
      return;
    }

    // Request code actions on the PR line
    const actions = await vscode.commands.executeCommand<vscode.CodeAction[]>(
      "vscode.executeCodeActionProvider",
      uri,
      new vscode.Range(prLine, 0, prLine, 0),
    );

    assert.ok(actions, "expected code actions response");
    assert.ok(actions.length > 0, `expected code actions on PR line ${prLine}, got none. Document text:\n${text}`);

    const checkout = actions.find((a) => a.title.includes("Checkout"));
    assert.ok(checkout, `expected Checkout action, got: ${actions.map((a) => a.title).join(", ")}`);
  }).timeout(60_000);

  test("code actions on status document (block cursor / 1-char selection)", async () => {
    const uri = vscode.Uri.parse("prlsp://status");
    const doc = await vscode.workspace.openTextDocument(uri);

    let text = doc.getText();
    for (let i = 0; i < 50 && text.includes("Loading..."); i++) {
      await new Promise((r) => setTimeout(r, 500));
      text = (await vscode.workspace.openTextDocument(uri)).getText();
    }

    const lines = text.split("\n");
    let prLine = -1;
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].includes("#")) {
        prLine = i;
        break;
      }
    }

    if (prLine === -1) {
      return; // no PRs to test
    }

    // Simulate block cursor: 1-character wide selection
    const actions = await vscode.commands.executeCommand<vscode.CodeAction[]>(
      "vscode.executeCodeActionProvider",
      uri,
      new vscode.Range(prLine, 0, prLine, 1),
    );

    assert.ok(actions, "expected code actions response");
    assert.ok(actions.length > 0, `expected code actions with block cursor on PR line ${prLine}, got none. Document text:\n${text}`);

    const checkout = actions.find((a) => a.title.includes("Checkout"));
    assert.ok(checkout, `expected Checkout action with block cursor`);
  }).timeout(60_000);

  test("code actions with only:quickfix filter", async () => {
    const uri = vscode.Uri.parse("prlsp://status");
    const doc = await vscode.workspace.openTextDocument(uri);

    let text = doc.getText();
    for (let i = 0; i < 50 && text.includes("Loading..."); i++) {
      await new Promise((r) => setTimeout(r, 500));
      text = (await vscode.workspace.openTextDocument(uri)).getText();
    }

    const lines = text.split("\n");
    let prLine = -1;
    for (let i = 1; i < lines.length; i++) {
      if (lines[i].includes("#")) {
        prLine = i;
        break;
      }
    }

    if (prLine === -1) {
      return;
    }

    // This is what editor.action.quickFix does — filters to only quickfix kind
    const actions = await vscode.commands.executeCommand<vscode.CodeAction[]>(
      "vscode.executeCodeActionProvider",
      uri,
      new vscode.Range(prLine, 0, prLine, 1),
      vscode.CodeActionKind.QuickFix.value,
    );

    assert.ok(actions, "expected code actions response with quickfix filter");
    assert.ok(
      actions.length > 0,
      `expected quickfix actions on PR line ${prLine}, got none. Document text:\n${text}`,
    );
  }).timeout(60_000);
});
