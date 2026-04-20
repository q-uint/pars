import * as vscode from "vscode";
import * as fs from "fs";
import * as path from "path";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
  TransportKind,
} from "vscode-languageclient/node";

let client: LanguageClient | undefined;

export async function activate(context: vscode.ExtensionContext) {
  const serverPath = resolveServerPath(context);
  if (!serverPath) {
    void vscode.window.showErrorMessage(
      "pars: could not find pars-lsp. Set 'pars.serverPath' or put pars-lsp on PATH."
    );
    return;
  }

  const serverOptions: ServerOptions = {
    run: { command: serverPath, transport: TransportKind.stdio },
    debug: { command: serverPath, transport: TransportKind.stdio },
  };

  const clientOptions: LanguageClientOptions = {
    documentSelector: [{ scheme: "file", language: "pars" }],
    synchronize: {
      fileEvents: vscode.workspace.createFileSystemWatcher("**/*.pars"),
    },
  };

  client = new LanguageClient("pars", "pars Language Server", serverOptions, clientOptions);
  context.subscriptions.push({ dispose: () => client?.stop() });
  await client.start();

  context.subscriptions.push(
    vscode.commands.registerCommand("pars.showBytecode", () =>
      BytecodePanel.show(context.extensionPath)
    ),
    vscode.commands.registerCommand("pars.showRailroad", () =>
      RailroadPanel.show(context.extensionPath)
    ),
    vscode.commands.registerCommand(
      "pars.runRule",
      // Optional ruleName preselects the dropdown; called by the
      // server-emitted "Match…" code lens above each rule definition.
      (ruleName?: string) => PlaygroundPanel.show(context.extensionPath, ruleName)
    ),
    // The server emits this command on codeLenses instead of invoking
    // editor.action.showReferences directly, because the native command
    // rejects plain JSON arguments; it needs real Uri/Position/Location
    // instances which only the extension host can construct.
    vscode.commands.registerCommand(
      "pars.showReferences",
      (uri: string, position: { line: number; character: number }, locations: LspLocation[]) => {
        const targetUri = vscode.Uri.parse(uri);
        const targetPos = new vscode.Position(position.line, position.character);
        const targetLocations = locations.map(
          (loc) =>
            new vscode.Location(
              vscode.Uri.parse(loc.uri),
              new vscode.Range(
                new vscode.Position(loc.range.start.line, loc.range.start.character),
                new vscode.Position(loc.range.end.line, loc.range.end.character)
              )
            )
        );
        return vscode.commands.executeCommand(
          "editor.action.showReferences",
          targetUri,
          targetPos,
          targetLocations
        );
      }
    )
  );
}

type LspLocation = {
  uri: string;
  range: {
    start: { line: number; character: number };
    end: { line: number; character: number };
  };
};

export async function deactivate(): Promise<void> {
  if (client) await client.stop();
}

function loadWebviewHtml(extensionPath: string, name: string): string {
  const mediaDir = path.join(extensionPath, "media");
  const outDir = path.join(extensionPath, "out");
  let html = fs.readFileSync(path.join(mediaDir, name), "utf8");

  // Inline webview.css — matches the pattern the other webviews use so
  // a strict CSP doesn't need to whitelist a stylesheet URI.
  const css = fs.readFileSync(path.join(mediaDir, "webview.css"), "utf8");
  html = html.replace(
    '<link rel="stylesheet" href="webview.css">',
    `<style>${css}</style>`
  );

  // Inline any `<script src="…">` or `<link …>` whose target is a
  // sibling file in `out/`. The railroad webview references both the
  // vendored railroad-diagrams library (copied in by `copy-deps`) and
  // its own compiled TS bundle (`railroad.js`); inlining keeps the
  // webview CSP simple (`script-src 'unsafe-inline'`) and avoids
  // wiring webview resource URIs for each asset.
  const inlineScript = (name: string) => {
    const p = path.join(outDir, name);
    const tag = `<script src="${name}"></script>`;
    if (html.includes(tag) && fs.existsSync(p)) {
      html = html.replace(tag, `<script>${fs.readFileSync(p, "utf8")}</script>`);
    }
  };
  const inlineStylesheet = (name: string) => {
    const p = path.join(outDir, name);
    const tag = `<link rel="stylesheet" href="${name}">`;
    if (html.includes(tag) && fs.existsSync(p)) {
      html = html.replace(tag, `<style>${fs.readFileSync(p, "utf8")}</style>`);
    }
  };
  inlineScript("railroad-diagrams.js");
  inlineScript("railroad.js");
  inlineStylesheet("railroad-diagrams.css");

  return html;
}

// Resolve the pars-lsp binary in priority order:
//   1. The `pars.serverPath` user setting (explicit override).
//   2. A binary bundled inside the extension at `bin/pars-lsp`. This
//      is what `editors/vsx/install.sh` produces, so a plain
//      `code --install-extension *.vsix` is all a user needs.
//   3. Bare `pars-lsp`, letting the OS resolve it via PATH.
function resolveServerPath(context: vscode.ExtensionContext): string | undefined {
  const configured = vscode.workspace.getConfiguration("pars").get<string>("serverPath");
  if (configured && configured.trim().length > 0) return configured;

  const bundled = path.join(context.extensionPath, "bin", "pars-lsp");
  if (fs.existsSync(bundled)) return bundled;

  return "pars-lsp";
}

type Instruction = {
  offset: number;
  size: number;
  op: string;
  detail: string;
  span: { start: number; len: number; line: number };
};

type Constant = {
  index: number;
  kind: string;
  display: string;
};

type Disassembly = {
  constants: Constant[];
  instructions: Instruction[];
};

type RuleEntry = {
  index: number;
  name: string;
  disassembly?: Disassembly;
};

type DisassembleResponse =
  | { uri: string; ok: true; main: Disassembly; rules: RuleEntry[] }
  | { uri: string; ok: false; errors: { line: number; column: number; message: string }[] };

// Singleton webview panel that displays the disassembly of the active
// .pars document. The panel follows the active editor: switching to a
// different .pars file updates the view, and edits to the tracked
// document trigger a re-request after a short debounce.
class BytecodePanel {
  static current: BytecodePanel | undefined;

  private readonly panel: vscode.WebviewPanel;
  private readonly disposables: vscode.Disposable[] = [];
  private trackedUri: vscode.Uri | undefined;
  private refreshTimer: NodeJS.Timeout | undefined;
  // Last cursor byte-offset we saw in the tracked editor. Retained so a
  // re-render (triggered by an edit) can immediately re-apply the
  // cursor-driven row highlight without waiting for the next selection
  // change.
  private lastCursorOffset: number | undefined;

  static show(extensionPath: string) {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== "pars") {
      void vscode.window.showInformationMessage("pars: open a .pars file first.");
      return;
    }

    if (BytecodePanel.current) {
      BytecodePanel.current.panel.reveal(vscode.ViewColumn.Beside);
      BytecodePanel.current.track(editor.document.uri);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      "parsBytecode",
      "pars: Bytecode",
      vscode.ViewColumn.Beside,
      { enableScripts: true, retainContextWhenHidden: true }
    );

    BytecodePanel.current = new BytecodePanel(panel, extensionPath);
    BytecodePanel.current.track(editor.document.uri);
  }

  private constructor(panel: vscode.WebviewPanel, extensionPath: string) {
    this.panel = panel;
    this.panel.webview.html = loadWebviewHtml(extensionPath, "bytecode.html");

    this.disposables.push(
      this.panel.onDidDispose(() => this.dispose()),
      this.panel.webview.onDidReceiveMessage((m) => this.onMessage(m)),
      vscode.workspace.onDidChangeTextDocument((e) => {
        if (this.trackedUri && e.document.uri.toString() === this.trackedUri.toString()) {
          this.scheduleRefresh();
        }
      }),
      vscode.window.onDidChangeActiveTextEditor((editor) => {
        if (editor && editor.document.languageId === "pars") {
          this.track(editor.document.uri);
        }
      }),
      vscode.window.onDidChangeTextEditorSelection((e) => {
        if (!this.trackedUri) return;
        if (e.textEditor.document.uri.toString() !== this.trackedUri.toString()) return;
        const offset = e.textEditor.document.offsetAt(e.selections[0].active);
        this.lastCursorOffset = offset;
        this.panel.webview.postMessage({ kind: "cursor", offset });
      })
    );
  }

  private track(uri: vscode.Uri) {
    this.trackedUri = uri;
    this.panel.title = `pars: ${path.basename(uri.fsPath)}`;
    // Seed from whichever editor currently shows this doc so the webview
    // gets an initial cursor highlight without waiting for a keystroke.
    const editor = vscode.window.visibleTextEditors.find(
      (e) => e.document.uri.toString() === uri.toString()
    );
    this.lastCursorOffset = editor
      ? editor.document.offsetAt(editor.selection.active)
      : undefined;
    void this.refresh();
  }

  private scheduleRefresh() {
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => void this.refresh(), 150);
  }

  private async refresh() {
    if (!this.trackedUri || !client) return;
    try {
      const response = (await client.sendRequest("pars/disassemble", {
        textDocument: { uri: this.trackedUri.toString() },
      })) as DisassembleResponse;
      this.panel.webview.postMessage({ kind: "update", response });
      if (this.lastCursorOffset !== undefined) {
        this.panel.webview.postMessage({
          kind: "cursor",
          offset: this.lastCursorOffset,
        });
      }
    } catch (err) {
      this.panel.webview.postMessage({
        kind: "error",
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }

  // Handle row-click events from the webview: reveal the source span
  // that produced the instruction in the original editor. We prefer
  // the byte-offset range when the span has non-zero length (a real
  // source token) and fall back to the line column when the span is a
  // synthetic zero-length marker (e.g. OP_HALT at end-of-input).
  private async onMessage(msg: { kind: string; span?: { start: number; len: number; line: number } }) {
    if (msg.kind !== "reveal" || !msg.span || !this.trackedUri) return;
    const doc = await vscode.workspace.openTextDocument(this.trackedUri);
    const start = doc.positionAt(msg.span.start);
    const end = msg.span.len > 0 ? doc.positionAt(msg.span.start + msg.span.len) : start;
    await vscode.window.showTextDocument(doc, {
      selection: new vscode.Range(start, end),
      viewColumn: vscode.ViewColumn.One,
      preserveFocus: true,
    });
  }

  private dispose() {
    BytecodePanel.current = undefined;
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    for (const d of this.disposables) d.dispose();
    this.panel.dispose();
  }
}

type RunRuleResponse =
  | {
      ok: true;
      kind: "match";
      end: number;
      captures: { slot: number; name?: string; start: number; len: number; text: string }[];
    }
  | { ok: true; kind: "no_match" }
  | { ok: false; kind: "compile_error"; errors: { line: number; column: number; message: string }[] }
  | { ok: false; kind: "no_such_rule"; name: string }
  | { ok: false; kind: "runtime_error" };

// Singleton webview that lets the user pick a rule from the active
// .pars document, paste an input string, and see the match outcome
// (success/failure, end position, and captured slots). Each rule run
// goes through a `pars/runRule` LSP request so the VM is the single
// source of truth — same compile path the rest of the extension uses.
class PlaygroundPanel {
  static current: PlaygroundPanel | undefined;

  private readonly panel: vscode.WebviewPanel;
  private readonly disposables: vscode.Disposable[] = [];
  private trackedUri: vscode.Uri | undefined;
  private selectedRule: string | undefined;
  private input: string = "";

  static show(extensionPath: string, ruleName?: string) {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== "pars") {
      void vscode.window.showInformationMessage("pars: open a .pars file first.");
      return;
    }

    if (PlaygroundPanel.current) {
      PlaygroundPanel.current.panel.reveal(vscode.ViewColumn.Beside);
      void PlaygroundPanel.current.track(editor.document.uri, ruleName);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      "parsPlayground",
      "pars: Playground",
      vscode.ViewColumn.Beside,
      { enableScripts: true, retainContextWhenHidden: true }
    );

    PlaygroundPanel.current = new PlaygroundPanel(panel, extensionPath);
    void PlaygroundPanel.current.track(editor.document.uri, ruleName);
  }

  private constructor(panel: vscode.WebviewPanel, extensionPath: string) {
    this.panel = panel;
    this.panel.webview.html = loadWebviewHtml(extensionPath, "playground.html");

    this.disposables.push(
      this.panel.onDidDispose(() => this.dispose()),
      this.panel.webview.onDidReceiveMessage((m) => void this.onMessage(m)),
      vscode.workspace.onDidChangeTextDocument((e) => {
        if (this.trackedUri && e.document.uri.toString() === this.trackedUri.toString()) {
          // Rule list may have changed; refresh just the dropdown,
          // re-run with the current input.
          void this.refreshRules();
          void this.run();
        }
      }),
      vscode.window.onDidChangeActiveTextEditor((editor) => {
        if (editor && editor.document.languageId === "pars") {
          void this.track(editor.document.uri);
        }
      })
    );
  }

  private async track(uri: vscode.Uri, preselect?: string) {
    this.trackedUri = uri;
    this.panel.title = `pars: ${path.basename(uri.fsPath)}`;
    if (preselect) this.selectedRule = preselect;
    await this.refreshRules();
    await this.run();
  }

  private async refreshRules() {
    if (!this.trackedUri) return;
    let names: string[] = [];
    try {
      const symbols = (await vscode.commands.executeCommand<vscode.DocumentSymbol[]>(
        "vscode.executeDocumentSymbolProvider",
        this.trackedUri
      )) ?? [];
      names = symbols.map((sym) => sym.name);
    } catch {
      // Symbol provider unavailable (compile errors, etc.); leave the
      // dropdown empty rather than failing the whole panel.
    }
    if (this.selectedRule && !names.includes(this.selectedRule)) {
      this.selectedRule = undefined;
    }
    if (!this.selectedRule && names.length > 0) {
      this.selectedRule = names[0];
    }
    this.panel.webview.postMessage({
      kind: "init",
      rules: names,
      selectedRule: this.selectedRule,
      input: this.input,
    });
  }

  private async run() {
    if (!this.trackedUri || !this.selectedRule || !client) return;
    try {
      const response = (await client.sendRequest("pars/runRule", {
        textDocument: { uri: this.trackedUri.toString() },
        ruleName: this.selectedRule,
        input: this.input,
      })) as RunRuleResponse;
      this.panel.webview.postMessage({ kind: "result", response });
    } catch (err) {
      this.panel.webview.postMessage({
        kind: "error",
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }

  private async onMessage(msg: {
    kind: string;
    ruleName?: string;
    input?: string;
  }) {
    if (msg.kind === "select") {
      if (typeof msg.ruleName === "string") this.selectedRule = msg.ruleName;
      await this.run();
    } else if (msg.kind === "input") {
      this.input = msg.input ?? "";
      await this.run();
    }
  }

  private dispose() {
    PlaygroundPanel.current = undefined;
    for (const d of this.disposables) d.dispose();
    this.panel.dispose();
  }
}

type RailroadNode =
  | { kind: "terminal"; text: string }
  | { kind: "non_terminal"; name: string }
  | { kind: "sequence"; items: RailroadNode[] }
  | { kind: "choice"; items: RailroadNode[] }
  | { kind: "optional"; item: RailroadNode }
  | { kind: "zero_or_more"; item: RailroadNode }
  | { kind: "one_or_more"; item: RailroadNode }
  | { kind: "group"; label: string; item: RailroadNode }
  | { kind: "comment"; text: string };

type RailroadResponse =
  | {
      ok: true;
      uri: string;
      rules: Record<string, RailroadNode>;
      // Per-rule where-scope: `where[X][name]` is the body of a
      // sub-rule defined inside X's where-block. The webview prefers
      // this over `rules[name]` when resolving a click inside X.
      where: Record<string, Record<string, RailroadNode>>;
      entry: string | null;
    }
  | { ok: false; uri: string; errors: { line: number; column: number; message: string }[] };

// Singleton webview that renders each rule as an interactive railroad
// diagram. Clicking a non-terminal expands its rule inline; clicking
// again collapses. The rule list comes from the LSP's pars/railroad
// response, refreshed on edits like BytecodePanel does.
class RailroadPanel {
  static current: RailroadPanel | undefined;

  private readonly panel: vscode.WebviewPanel;
  private readonly disposables: vscode.Disposable[] = [];
  private trackedUri: vscode.Uri | undefined;
  private refreshTimer: NodeJS.Timeout | undefined;

  static show(extensionPath: string) {
    const editor = vscode.window.activeTextEditor;
    if (!editor || editor.document.languageId !== "pars") {
      void vscode.window.showInformationMessage("pars: open a .pars file first.");
      return;
    }

    if (RailroadPanel.current) {
      RailroadPanel.current.panel.reveal(vscode.ViewColumn.Beside);
      RailroadPanel.current.track(editor.document.uri);
      return;
    }

    const panel = vscode.window.createWebviewPanel(
      "parsRailroad",
      "pars: Railroad",
      vscode.ViewColumn.Beside,
      { enableScripts: true, retainContextWhenHidden: true }
    );

    RailroadPanel.current = new RailroadPanel(panel, extensionPath);
    RailroadPanel.current.track(editor.document.uri);
  }

  private constructor(panel: vscode.WebviewPanel, extensionPath: string) {
    this.panel = panel;
    this.panel.webview.html = loadWebviewHtml(extensionPath, "railroad.html");

    this.disposables.push(
      this.panel.onDidDispose(() => this.dispose()),
      vscode.workspace.onDidChangeTextDocument((e) => {
        if (this.trackedUri && e.document.uri.toString() === this.trackedUri.toString()) {
          this.scheduleRefresh();
        }
      }),
      vscode.window.onDidChangeActiveTextEditor((editor) => {
        if (editor && editor.document.languageId === "pars") {
          this.track(editor.document.uri);
        }
      })
    );
  }

  private track(uri: vscode.Uri) {
    this.trackedUri = uri;
    this.panel.title = `pars: ${path.basename(uri.fsPath)}`;
    void this.refresh();
  }

  private scheduleRefresh() {
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    this.refreshTimer = setTimeout(() => void this.refresh(), 150);
  }

  private async refresh() {
    if (!this.trackedUri || !client) return;
    try {
      const response = (await client.sendRequest("pars/railroad", {
        textDocument: { uri: this.trackedUri.toString() },
      })) as RailroadResponse;
      if (response.ok) {
        this.panel.webview.postMessage({
          kind: "update",
          rules: response.rules,
          where: response.where,
          entry: response.entry,
        });
      } else {
        this.panel.webview.postMessage({
          kind: "compile_errors",
          errors: response.errors,
        });
      }
    } catch (err) {
      this.panel.webview.postMessage({
        kind: "error",
        message: err instanceof Error ? err.message : String(err),
      });
    }
  }

  private dispose() {
    RailroadPanel.current = undefined;
    if (this.refreshTimer) clearTimeout(this.refreshTimer);
    for (const d of this.disposables) d.dispose();
    this.panel.dispose();
  }
}
