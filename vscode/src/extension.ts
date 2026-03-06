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

  // Custom quick fix command that bypasses VS Code's writable precondition
  context.subscriptions.push(
    vscode.commands.registerCommand("prlsp.quickFix", async () => {
      const editor = vscode.window.activeTextEditor;
      if (!editor) {
        return;
      }
      const document = editor.document;
      const range = editor.selection;
      const diagnostics = vscode.languages.getDiagnostics(document.uri)
        .filter(d => range.intersection(d.range));

      const actions = await vscode.commands.executeCommand<vscode.CodeAction[]>(
        "vscode.executeCodeActionProvider",
        document.uri,
        range,
      );

      if (!actions || actions.length === 0) {
        vscode.window.showInformationMessage("No code actions available");
        return;
      }

      const items = actions.map(action => ({
        label: action.title,
        action,
      }));

      const picked = await vscode.window.showQuickPick(items, {
        placeHolder: "Code actions",
      });

      if (!picked) {
        return;
      }

      const action = picked.action;
      if (action.edit) {
        await vscode.workspace.applyEdit(action.edit);
      }
      if (action.command) {
        await vscode.commands.executeCommand(
          action.command.command,
          ...(action.command.arguments ?? []),
        );
      }
    }),
  );

  return { client, clientReady };
}

export async function deactivate(): Promise<void> {
  if (client) {
    await client.stop();
  }
}
