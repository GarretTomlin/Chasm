import * as path from "path";
import * as fs from "fs";
import { workspace, ExtensionContext, window } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(context: ExtensionContext) {
  const config = workspace.getConfiguration("chasm");
  let serverPath: string = config.get("serverPath") || "";

  if (!serverPath) {
    // Try common locations
    const candidates = [
      path.join(context.extensionPath, "..", "..", "bin", "chasm-lsp"),
      path.join(process.env.HOME || "", ".local", "bin", "chasm-lsp"),
      "/usr/local/bin/chasm-lsp",
    ];
    for (const c of candidates) {
      if (fs.existsSync(c)) {
        serverPath = c;
        break;
      }
    }
  }

  if (!serverPath || !fs.existsSync(serverPath)) {
    window.showWarningMessage(
      "chasm-lsp not found. Install Chasm or set chasm.serverPath in settings."
    );
    return;
  }

  const serverOptions: ServerOptions = {
    command: serverPath,
    transport: TransportKind.stdio,
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "chasm" }],
    synchronize: {
      fileEvents: workspace.createFileSystemWatcher("**/*.chasm"),
    },
  };

  client = new LanguageClient(
    "chasm-lsp",
    "Chasm Language Server",
    serverOptions,
    clientOptions
  );

  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  if (!client) return undefined;
  return client.stop();
}
