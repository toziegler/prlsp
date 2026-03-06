import * as assert from "assert";
import * as vscode from "vscode";

suite("prlsp", () => {
  test("extension activates successfully", async () => {
    const ext = vscode.extensions.getExtension("undefined_publisher.prlsp")!;
    assert.ok(ext, "extension not found");
    await ext.activate();
    assert.ok(ext.isActive, "extension should be active");
  }).timeout(30_000);
});
