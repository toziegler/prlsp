import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;
let clientReady: Promise<void> | undefined;

export function activate(context: vscode.ExtensionContext) {
  const goDir = path.resolve(context.extensionPath, "..", "go");

  const serverOptions: ServerOptions = {
    command: "go",
    args: ["run", "."],
    options: { cwd: goDir },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [
      { scheme: "file", pattern: "**/*" },
      { scheme: "prlsp" },
    ],
  };

  client = new LanguageClient("prlsp", "prlsp", serverOptions, clientOptions);
  client.registerProposedFeatures();
  clientReady = client.start();

  context.subscriptions.push(
    vscode.commands.registerCommand("prlsp.showStatus", async () => {
      await clientReady;
      const uri = vscode.Uri.parse("prlsp://status");
      const doc = await vscode.workspace.openTextDocument(uri);
      await vscode.window.showTextDocument(doc, {
        preview: false,
        viewColumn: vscode.ViewColumn.Beside,
      });
    }),
  );

  return { client, clientReady };
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
  }
}
