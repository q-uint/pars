/// <reference lib="dom" />
//
// Webview script for the Railroad panel. Built separately from the
// extension bundle (browser target) and inlined into railroad.html at
// load time by `loadWebviewHtml` in extension.ts. Runs in the webview
// global context; `acquireVsCodeApi` and the railroad-diagrams library
// are provided by the host / injected script tag.

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

type HostMessage =
  | {
      kind: "update";
      rules: Record<string, RailroadNode>;
      where: Record<string, Record<string, RailroadNode>>;
      entry: string | null;
    }
  | { kind: "error"; message: string }
  | {
      kind: "compile_errors";
      errors: { line: number; column: number; message: string }[];
    };

// railroad-diagrams v1.0.0 exposes these as globals on the webview
// window; we interact with them structurally and don't care about
// their internal shape beyond `Diagram.addTo(Element)`.
declare const Diagram: (...items: unknown[]) => { addTo(el: Element): void };
declare const Terminal: (text: string) => unknown;
declare const NonTerminal: (name: string) => unknown;
declare const Sequence: (...items: unknown[]) => unknown;
declare const Choice: (def: number, ...items: unknown[]) => unknown;
declare const Optional: (item: unknown) => unknown;
declare const ZeroOrMore: (item: unknown) => unknown;
declare const OneOrMore: (item: unknown) => unknown;
declare function acquireVsCodeApi(): unknown;

// railroad-diagrams' `Comment` global collides with the DOM's
// `Comment` constructor under `lib=dom`; alias it through
// `globalThis` so the reference goes to the library, not the node
// type.
const RRComment = (globalThis as unknown as { Comment: (text: string) => unknown }).Comment;

interface WalkState {
  pendingClicks: { path: string; name: string; cycle: boolean; canExpand: boolean }[];
  // Indices into the Terminal document-order that correspond to
  // operator labels (lookaheads, captures, longest, bounded
  // quantifiers). We bump `termCount` on every Terminal we emit
  // during the walk, so `labelTerms` lists the positions whose
  // rendered `g.terminal` element should be restyled.
  labelTerms: Set<number>;
  // Map of Terminal index → path for "▼ name" expand headers.
  // Clicking one of these collapses the expansion.
  collapseTerms: Map<number, { path: string; depth: number }>;
  termCount: number;
}

// Retained for parity with the original inline script — held to keep
// the acquire-once contract even though we don't post back today.
acquireVsCodeApi();

const ruleSelect = document.getElementById("rule") as HTMLSelectElement;
const diagramEl = document.getElementById("diagram") as HTMLElement;
const fitBtn = document.getElementById("fit-toggle") as HTMLButtonElement;

let fitMode = false;
fitBtn.addEventListener("click", () => {
  fitMode = !fitMode;
  document.body.classList.toggle("fit", fitMode);
  fitBtn.textContent = fitMode ? "Scale: fit" : "Scale: scroll";
});

// Persistent state. `rules` is a map of rule name → IR node, pushed
// by the host on every compile. `whereScopes[r][name]` is the body of
// a sub-rule defined in rule `r`'s where-block; looked up before the
// global `rules` map so a click on a where-bound name expands to the
// local definition. `expanded` tracks which non-terminal paths the
// user has opened; cleared on every new payload because paths are
// only valid against one specific IR tree.
let rules: Record<string, RailroadNode> = {};
let whereScopes: Record<string, Record<string, RailroadNode>> = {};
let rootName: string | null = null;
const expanded = new Set<string>();

window.addEventListener("message", (ev: MessageEvent<HostMessage>) => {
  const msg = ev.data;
  if (msg.kind === "update") {
    rules = msg.rules || {};
    whereScopes = msg.where || {};
    const entry = msg.entry || null;
    const names = Object.keys(rules);
    // Keep the current selection if the rule is still there;
    // otherwise fall back to the entry, otherwise the first rule.
    if (!rootName || !rules[rootName]) {
      rootName = entry && rules[entry] ? entry : names[0] || null;
    }
    expanded.clear();
    renderSelect(names);
    renderDiagram();
  } else if (msg.kind === "error") {
    renderError(msg.message);
  } else if (msg.kind === "compile_errors") {
    renderErrors(msg.errors);
  }
});

ruleSelect.addEventListener("change", () => {
  rootName = ruleSelect.value;
  expanded.clear();
  renderDiagram();
});

function renderSelect(names: string[]) {
  ruleSelect.innerHTML = "";
  if (!names || names.length === 0) {
    const opt = document.createElement("option");
    opt.textContent = "(no rules defined)";
    opt.disabled = true;
    ruleSelect.appendChild(opt);
    ruleSelect.disabled = true;
    return;
  }
  ruleSelect.disabled = false;
  for (const n of names) {
    const opt = document.createElement("option");
    opt.value = n;
    opt.textContent = n;
    if (n === rootName) opt.selected = true;
    ruleSelect.appendChild(opt);
  }
}

function renderError(message: string) {
  diagramEl.innerHTML = "";
  const p = document.createElement("p");
  p.className = "errors";
  p.textContent = message;
  diagramEl.appendChild(p);
}

function renderErrors(errs: { line: number; column: number; message: string }[]) {
  diagramEl.innerHTML = "";
  const ul = document.createElement("ul");
  ul.className = "errors";
  for (const e of errs) {
    const li = document.createElement("li");
    li.textContent = `line ${e.line + 1}, col ${e.column + 1}: ${e.message}`;
    ul.appendChild(li);
  }
  diagramEl.appendChild(ul);
}

// Walk the IR for the chosen rule, produce a tabatkins/railroad tree,
// attach it to the DOM, then wire click handlers onto each
// non-terminal in document-order.
//
// Document-order is the same as IR-walk order because we build the
// tree depth-first and the library renders depth-first; we record
// each non-terminal's path as we go and zip against the rendered
// `.non-terminal` nodes afterwards.
function renderDiagram() {
  diagramEl.innerHTML = "";
  if (!rootName) {
    const p = document.createElement("p");
    p.className = "empty";
    p.textContent = "No rule selected.";
    diagramEl.appendChild(p);
    return;
  }
  const body = rules[rootName];
  if (!body) return;

  const walk: WalkState = {
    pendingClicks: [],
    labelTerms: new Set(),
    collapseTerms: new Map(),
    termCount: 0,
  };
  // Ancestors track the stack of currently-expanded rule names along
  // the walk, so we can mark cycles without infinite-looping.
  const ancestors = [rootName];
  const scope = whereScopes[rootName] || {};
  const tree = buildLibTree(body, "", walk, ancestors, scope);
  ancestors.pop();

  const diagram = Diagram(tree);
  diagram.addTo(diagramEl);

  // Library v1.0.0 doesn't annotate the emitted `<g>` elements with
  // `terminal` / `non-terminal` classes, so the only distinguishing
  // trait is the shape of their direct `<rect>`: Terminal uses
  // `rx="10"` (rounded); NonTerminal has no rx (sharp corners). Tag
  // them here so the rest of this function can find them via
  // `.non-terminal` / `.terminal`, and so the panel's CSS can target
  // each kind.
  const allGs = diagramEl.querySelectorAll("svg.railroad-diagram g");
  allGs.forEach((g) => {
    const rect = g.querySelector(":scope > rect");
    if (!rect) return;
    if (rect.getAttribute("rx")) g.classList.add("terminal");
    else g.classList.add("non-terminal");
  });

  const ntEls = diagramEl.querySelectorAll("g.non-terminal");
  ntEls.forEach((el, i) => {
    const info = walk.pendingClicks[i];
    if (!info) return;
    if (info.cycle) {
      el.classList.add("cycle");
      return;
    }
    if (!info.canExpand) return; // unknown rule — don't offer expand
    if (expanded.has(info.path)) el.classList.add("expanded");
    el.addEventListener("click", () => {
      if (expanded.has(info.path)) expanded.delete(info.path);
      else expanded.add(info.path);
      renderDiagram();
    });
  });

  const termEls = diagramEl.querySelectorAll("g.terminal");
  termEls.forEach((el, i) => {
    if (walk.labelTerms.has(i)) el.classList.add("operator-label");
    const collapseInfo = walk.collapseTerms.get(i);
    if (collapseInfo !== undefined) {
      el.classList.add("collapse-header");
      // Depth is 1-based for the first expansion so the CSS
      // `calc(depth * 55)` hue starts at a visible color instead of
      // red-at-zero which some themes render nearly invisible.
      (el as HTMLElement).style.setProperty("--depth", String(collapseInfo.depth));
      el.addEventListener("click", () => {
        expanded.delete(collapseInfo.path);
        renderDiagram();
      });
    }
  });
}

// Resolve a rule name against the current where-scope first, then the
// global rules map. A where-bound sub-rule shadows a same-named
// top-level rule inside its parent rule's body — the same lookup
// order the compiler uses.
function resolveRule(
  name: string,
  scope: Record<string, RailroadNode>,
): RailroadNode | null {
  if (scope && Object.prototype.hasOwnProperty.call(scope, name)) return scope[name];
  if (Object.prototype.hasOwnProperty.call(rules, name)) return rules[name];
  return null;
}

function buildLibTree(
  node: RailroadNode,
  path: string,
  walk: WalkState,
  ancestors: string[],
  scope: Record<string, RailroadNode>,
): unknown {
  switch (node.kind) {
    case "terminal":
      walk.termCount += 1;
      return Terminal(node.text);
    case "non_terminal": {
      const isCycle = ancestors.indexOf(node.name) !== -1;
      const body = isCycle ? null : resolveRule(node.name, scope);
      const canExpand = body !== null;
      if (expanded.has(path) && canExpand) {
        // Bracket the expanded body with a "▼ name" opening and a
        // "▲ name" closing Terminal. Both are recorded as collapse
        // points (click either to unwind) and carry the current
        // nesting depth so CSS can paint them in a depth-keyed
        // color — this is what makes nested expansions visually
        // distinguishable without a real Group primitive.
        const depth = ancestors.length;
        walk.collapseTerms.set(walk.termCount, { path, depth });
        walk.termCount += 1;
        const opener = Terminal("\u25bc " + node.name);
        ancestors.push(node.name);
        const inner = buildLibTree(body!, path + "/" + node.name, walk, ancestors, scope);
        ancestors.pop();
        walk.collapseTerms.set(walk.termCount, { path, depth });
        walk.termCount += 1;
        const closer = Terminal("\u25b2 " + node.name);
        return Sequence(opener, inner, closer);
      }
      walk.pendingClicks.push({ path, name: node.name, cycle: isCycle, canExpand });
      return NonTerminal(node.name);
    }
    case "sequence":
      return Sequence(
        ...node.items.map((c, i) => buildLibTree(c, path + "." + i, walk, ancestors, scope)),
      );
    case "choice":
      return Choice(
        0,
        ...node.items.map((c, i) => buildLibTree(c, path + "." + i, walk, ancestors, scope)),
      );
    case "optional":
      return Optional(buildLibTree(node.item, path + ".0", walk, ancestors, scope));
    case "zero_or_more":
      return ZeroOrMore(buildLibTree(node.item, path + ".0", walk, ancestors, scope));
    case "one_or_more":
      return OneOrMore(buildLibTree(node.item, path + ".0", walk, ancestors, scope));
    case "group": {
      // v1.0.0 lacks a Group primitive. Render as
      // `Sequence(Terminal(label), child)` so the label gets a box,
      // then tag that terminal's index for post-render restyling
      // with `.operator-label`.
      walk.labelTerms.add(walk.termCount);
      walk.termCount += 1;
      const labelEl = Terminal(node.label);
      return Sequence(labelEl, buildLibTree(node.item, path + ".0", walk, ancestors, scope));
    }
    case "comment":
      return RRComment(node.text);
  }
}
