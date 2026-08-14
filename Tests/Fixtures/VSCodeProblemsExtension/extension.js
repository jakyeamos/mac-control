const vscode = require("vscode");

function activate(context) {
  const collection = vscode.languages.createDiagnosticCollection("macctl-fixture");
  context.subscriptions.push(collection);
  const folder = vscode.workspace.workspaceFolders?.[0];
  if (!folder) {
    return;
  }
  const uri = vscode.Uri.joinPath(folder.uri, "problem.ts");
  const diagnostic = new vscode.Diagnostic(
    new vscode.Range(0, 0, 0, 5),
    "Mac Control fixture finding",
    vscode.DiagnosticSeverity.Error,
  );
  diagnostic.source = "macctl-fixture";
  diagnostic.code = "MCCTL001";
  collection.set(uri, [diagnostic]);
}

function deactivate() {}

module.exports = { activate, deactivate };
