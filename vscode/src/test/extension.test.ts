import * as assert from "assert";
import * as vscode from "vscode";
import { LanguageClient } from "vscode-languageclient/node";

suite("prlsp", () => {
  test("smoke", async () => {
    const ext = vscode.extensions.getExtension("undefined_publisher.prlsp")!;
    assert.ok(ext, "extension not found");
    const api = (await ext.activate()) as {
      client: LanguageClient;
      clientReady: Promise<void>;
    };
    assert.ok(ext.isActive, "extension should be active");

    await api.clientReady;

    const uri = vscode.Uri.parse("prlsp://status");
    const doc = await vscode.workspace.openTextDocument(uri);

    assert.strictEqual(doc.uri.scheme, "prlsp");
    assert.strictEqual(doc.getText(), "hello world");
  }).timeout(30_000);
});
