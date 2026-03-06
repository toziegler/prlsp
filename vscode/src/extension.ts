import * as path from "path";
import * as vscode from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export function activate(context: vscode.ExtensionContext) {
  const goDir = path.resolve(context.extensionPath, "..", "go");

  const serverOptions: ServerOptions = {
    command: "go",
    args: ["run", "."],
    options: { cwd: goDir },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", pattern: "**/*" }],
  };

  client = new LanguageClient("prlsp", "prlsp", serverOptions, clientOptions);
  client.start();

  context.subscriptions.push(
    vscode.commands.registerCommand("prlsp.refresh", () => {
      if (client) {
        return client.sendRequest("workspace/executeCommand", {
          command: "prlsp.refresh",
        });
      }
    })
  );
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
  }
}
