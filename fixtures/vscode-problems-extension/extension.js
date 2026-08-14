const vscode = require("vscode");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const PROVIDER = "vscode.languages.getDiagnostics";
const SCHEMA_VERSION = 1;
const ID_PATTERN = /^[a-z0-9][a-z0-9_-]{0,47}$/;

function fixtureId() {
  const configured = vscode.workspace.getConfiguration("macctl").get("fixtureId");
  const value = process.env.MACCTL_VSCODE_FIXTURE_ID || configured;
  if (typeof value !== "string" || !ID_PATTERN.test(value)) {
    throw new Error("macctl VS Code fixture id is missing or invalid");
  }
  return value;
}

function fixtureRoot() {
  const value = process.env.MACCTL_VSCODE_FIXTURE_ROOT;
  if (typeof value !== "string" || value.length === 0) {
    throw new Error("MACCTL_VSCODE_FIXTURE_ROOT is missing");
  }
  return path.resolve(value);
}

function fixtureDirectory(id) {
  const root = fixtureRoot();
  const directory = path.resolve(root, id);
  if (directory !== root && !directory.startsWith(`${root}${path.sep}`)) {
    throw new Error("macctl VS Code fixture path escaped its root");
  }
  return directory;
}

function workspacePath() {
  const folders = vscode.workspace.workspaceFolders || [];
  if (folders.length !== 1) {
    throw new Error("macctl VS Code fixture requires exactly one workspace folder");
  }
  return path.resolve(folders[0].uri.fsPath);
}

function readMarker(directory, id, workspace) {
  const markerPath = path.join(directory, "fixture-marker.json");
  const marker = JSON.parse(fs.readFileSync(markerPath, "utf8"));
  if (
    marker.schema_version !== SCHEMA_VERSION ||
    marker.fixture_id !== id ||
    path.resolve(marker.workspace_path) !== workspace
  ) {
    throw new Error("macctl VS Code fixture marker identity mismatch");
  }
  return fs.readFileSync(markerPath);
}

function workspaceDigest(directory, id, workspace, markerBytes) {
  return crypto
    .createHash("sha256")
    .update(`${id}|${workspace}|`)
    .update(markerBytes)
    .digest("hex");
}

function severity(diagnostic) {
  switch (diagnostic.severity) {
    case vscode.DiagnosticSeverity.Error:
      return "error";
    case vscode.DiagnosticSeverity.Warning:
      return "warning";
    case vscode.DiagnosticSeverity.Information:
      return "info";
    default:
      return "hint";
  }
}

function boundedString(value) {
  if (value === undefined || value === null) {
    return null;
  }
  const text = typeof value === "object" && "value" in value ? value.value : value;
  return typeof text === "string" ? text.slice(0, 80) : String(text).slice(0, 80);
}

function redactedDiagnostics(workspace) {
  const records = [];
  for (const [uri, diagnostics] of vscode.languages.getDiagnostics()) {
    if (path.resolve(uri.fsPath) !== workspace && !path.resolve(uri.fsPath).startsWith(`${workspace}${path.sep}`)) {
      continue;
    }
    for (const diagnostic of diagnostics) {
      records.push({
        severity: severity(diagnostic),
        source: boundedString(diagnostic.source),
        code: boundedString(diagnostic.code),
        line: diagnostic.range.start.line,
        column: diagnostic.range.start.character,
      });
    }
  }
  return records;
}

function writeSnapshot() {
  const id = fixtureId();
  const directory = fixtureDirectory(id);
  const workspace = workspacePath();
  const markerBytes = readMarker(directory, id, workspace);
  const records = redactedDiagnostics(workspace);
  const payload = {
    schema_version: SCHEMA_VERSION,
    provider: PROVIDER,
    fixture_id: id,
    bundle_id: process.env.MACCTL_VSCODE_BUNDLE_ID || "com.microsoft.VSCode",
    workspace_digest: workspaceDigest(directory, id, workspace, markerBytes),
    generated_at: new Date().toISOString(),
    diagnostics: records,
  };
  const target = path.join(directory, "diagnostics.json");
  const temporary = path.join(directory, `.diagnostics.${process.pid}.${Date.now()}.tmp`);
  fs.writeFileSync(temporary, `${JSON.stringify(payload, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(temporary, target);
}

function ensureFixtureDiagnostics(collection, workspace) {
  const uri = vscode.Uri.file(path.join(workspace, "fixture.ts"));
  const diagnostics = [
    new vscode.Diagnostic(
      new vscode.Range(0, 0, 0, 10),
      "Fixture error is intentionally visible in Problems.",
      vscode.DiagnosticSeverity.Error,
    ),
    new vscode.Diagnostic(
      new vscode.Range(1, 0, 1, 10),
      "Fixture warning is intentionally visible in Problems.",
      vscode.DiagnosticSeverity.Warning,
    ),
    new vscode.Diagnostic(
      new vscode.Range(2, 0, 2, 10),
      "Fixture information is intentionally visible in Problems.",
      vscode.DiagnosticSeverity.Information,
    ),
    new vscode.Diagnostic(
      new vscode.Range(3, 0, 3, 10),
      "Fixture hint is intentionally visible in Problems.",
      vscode.DiagnosticSeverity.Hint,
    ),
  ];
  for (const diagnostic of diagnostics) {
    diagnostic.source = "macctl-fixture";
    diagnostic.code = "MACCTL-FIXTURE";
  }
  collection.set(uri, diagnostics);
}

function activate(context) {
  const id = fixtureId();
  const directory = fixtureDirectory(id);
  const workspace = workspacePath();
  const collection = vscode.languages.createDiagnosticCollection("macctl-fixture");
  ensureFixtureDiagnostics(collection, workspace);
  context.subscriptions.push(collection);
  context.subscriptions.push(vscode.languages.onDidChangeDiagnostics(() => {
    try {
      writeSnapshot();
    } catch (error) {
      console.error(`macctl fixture snapshot failed: ${error.message}`);
    }
  }));
  const document = vscode.Uri.file(path.join(workspace, "fixture.ts"));
  vscode.window.showTextDocument(document, { preview: false, preserveFocus: false }).then(
    () => vscode.commands.executeCommand("workbench.actions.view.problems"),
    (error) => console.error(`macctl fixture editor failed: ${error.message}`),
  );
  setTimeout(() => {
    try {
      writeSnapshot();
      vscode.commands.executeCommand("workbench.actions.view.problems");
    } catch (error) {
      console.error(`macctl fixture startup failed: ${error.message}`);
    }
  }, 250);
}

function deactivate() {}

module.exports = { activate, deactivate };
