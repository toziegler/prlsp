import * as assert from "assert";
import * as vscode from "vscode";

suite("prlsp", () => {
  test("refresh command executes without error", async () => {
    // Wait for our extension to activate
    const ext = vscode.extensions.getExtension("undefined_publisher.prlsp")!;
    assert.ok(ext, "extension not found");
    await ext.activate();

    // Give the LSP client a moment to start (go run compile)
    await new Promise((r) => setTimeout(r, 10_000));

    // Should not throw — server responds with null and sends a showMessage notification
    await vscode.commands.executeCommand("prlsp.refresh");
  }).timeout(30_000);
});
