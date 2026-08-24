// Model.js unit tests. Run with: node test/model-test.js
// No framework — assert() and a pass/fail summary, like omarchy's own
// node-backed shell tests.

const assert = require("node:assert");
const Model = require("../Model.js");

let passed = 0;
let failed = 0;

function test(name, fn) {
  try {
    fn();
    passed++;
    console.log("ok   " + name);
  } catch (e) {
    failed++;
    console.error("FAIL " + name + "\n     " + e.message);
  }
}

const prefs = Model.defaultPrefs();

// ---------------------------------------------------------------- parsing

test("extractJson finds a bare object", () => {
  assert.deepStrictEqual(Model.extractJson('{"a": 1}'), { a: 1 });
});

test("extractJson survives markdown fences and prose", () => {
  const out = Model.extractJson('Sure! Here is the plan:\n```json\n{"mode": "deep-work", "actions": []}\n```\nDone.');
  assert.strictEqual(out.mode, "deep-work");
});

test("extractJson handles braces inside strings", () => {
  const out = Model.extractJson('{"rationale": "use {curly} braces", "actions": []}');
  assert.strictEqual(out.rationale, "use {curly} braces");
});

test("extractJson skips a broken object and finds the next", () => {
  const out = Model.extractJson('{oops not json} {"actions": []}');
  assert.deepStrictEqual(out.actions, []);
});

test("parseRecommendation requires an actions array", () => {
  assert.strictEqual(Model.parseRecommendation('{"mode": "x"}').ok, false);
  assert.strictEqual(Model.parseRecommendation('{"actions": []}').ok, true);
});

test("parseRecommendation clamps confidence", () => {
  const r = Model.parseRecommendation('{"confidence": 3.5, "actions": []}');
  assert.strictEqual(r.recommendation.confidence, 1);
});

// ---------------------------------------------------------------- actions

test("theme action builds omarchy-theme-set", () => {
  const v = Model.checkAction({ type: "theme", name: "tokyo-night" }, prefs);
  assert.strictEqual(v.allowed, true);
  assert.deepStrictEqual(v.command, ["omarchy-theme-set", "tokyo-night"]);
});

test("theme action rejects shell metacharacters", () => {
  const v = Model.checkAction({ type: "theme", name: "x; rm -rf ~" }, prefs);
  assert.strictEqual(v.allowed, false);
});

test("workspace action bounds ids to 1..10", () => {
  assert.strictEqual(Model.checkAction({ type: "workspace", id: 3 }, prefs).allowed, true);
  assert.strictEqual(Model.checkAction({ type: "workspace", id: 0 }, prefs).allowed, false);
  assert.strictEqual(Model.checkAction({ type: "workspace", id: "2; ls" }, prefs).allowed, false);
});

test("hyprctl action allows listed dispatchers only", () => {
  const ok = Model.checkAction({ type: "hyprctl", cmd: "dispatch movetoworkspacesilent 2,class:^(chromium)$" }, prefs);
  assert.strictEqual(ok.allowed, true);
  assert.deepStrictEqual(ok.command, ["hyprctl", "dispatch", "movetoworkspacesilent", "2,class:^(chromium)$"]);

  assert.strictEqual(Model.checkAction({ type: "hyprctl", cmd: "dispatch exec kitty" }, prefs).allowed, false);
  assert.strictEqual(Model.checkAction({ type: "hyprctl", cmd: "keyword general:gaps_in 0" }, prefs).allowed, false);
  assert.strictEqual(Model.checkAction({ type: "hyprctl", cmd: "dispatch workspace 1; reboot" }, prefs).allowed, false);
});

test("exec action honors the app allowlist", () => {
  assert.strictEqual(Model.checkAction({ type: "exec", app: "obsidian" }, prefs).allowed, true);
  assert.strictEqual(Model.checkAction({ type: "exec", app: "not-a-listed-app" }, prefs).allowed, false);
  assert.strictEqual(Model.checkAction({ type: "exec", app: "obsidian --evil-flag" }, prefs).allowed, false);
});

test("dnd and nightlight map to omarchy-shell IPC", () => {
  assert.deepStrictEqual(Model.checkAction({ type: "dnd", enable: true }, prefs).command,
    ["omarchy-shell", "-q", "notifications", "setDnd", "on"]);
  assert.deepStrictEqual(Model.checkAction({ type: "nightlight", enable: false }, prefs).command,
    ["omarchy-shell", "-q", "nightlight", "disable"]);
});

test("unknown action types are rejected", () => {
  assert.strictEqual(Model.checkAction({ type: "shell", cmd: "rm -rf /" }, prefs).allowed, false);
  assert.strictEqual(Model.checkAction(null, prefs).allowed, false);
});

test("validateActions annotates without dropping rows", () => {
  const rows = Model.validateActions([
    { type: "theme", name: "rose-pine" },
    { type: "exec", app: "definitely-not-allowed" }
  ], prefs);
  assert.strictEqual(rows.length, 2);
  assert.strictEqual(rows[0].__allowed, true);
  assert.strictEqual(rows[1].__allowed, false);
  assert.ok(rows[1].__reason.length > 0);
});

// ---------------------------------------------------------------- shell

test("shellQuote survives single quotes", () => {
  assert.strictEqual(Model.shellQuote("it's"), "'it'\\''s'");
});

test("scriptFor quotes every argv element", () => {
  const script = Model.scriptFor([["omarchy-theme-set", "tokyo-night"], ["hyprctl", "dispatch", "workspace", "2"]]);
  assert.strictEqual(script, "'omarchy-theme-set' 'tokyo-night'\n'hyprctl' 'dispatch' 'workspace' '2'");
});

// ---------------------------------------------------------------- undo

test("undo only reverts touched aspects", () => {
  const snapshot = { theme: "catppuccin", workspace: 4, dnd: "off", nightlight: false };
  const cmds = Model.undoCommands(snapshot, ["theme", "dnd"]);
  assert.deepStrictEqual(cmds, [
    ["omarchy-theme-set", "catppuccin"],
    ["omarchy-shell", "-q", "notifications", "setDnd", "off"]
  ]);
});

test("undo with no snapshot is a no-op", () => {
  assert.deepStrictEqual(Model.undoCommands(null, ["theme"]), []);
});

test("undo skips a null workspace instead of dispatching 'null'", () => {
  const cmds = Model.undoCommands({ theme: "", workspace: null, dnd: "off" }, ["workspace"]);
  assert.deepStrictEqual(cmds, []);
});

// ---------------------------------------------------------------- context

test("filterContext strips titles when sendWindowTitles is off", () => {
  const raw = {
    time: "Monday 10:15", theme: "tokyo-night", dnd: "off",
    clients: [{ class: "chromium", title: "my secret tab", workspace: { id: 2 }, address: "0x1" }],
    activeWindow: { class: "chromium", address: "0x1" },
    workspaces: [{ id: 2, windows: 1 }],
    activeWorkspaceId: 2
  };
  const strictPrefs = Model.defaultPrefs();
  strictPrefs.privacy.sendWindowTitles = false;
  const ctx = Model.filterContext(raw, strictPrefs);
  assert.strictEqual(ctx.clients[0].title, undefined);
  assert.strictEqual(ctx.clients[0].class, "chromium");
  assert.strictEqual(ctx.clients[0].focused, true);
  assert.strictEqual(ctx.activeWorkspace, 2);
});

test("prompt contains prefs, context, and the request", () => {
  const prompt = Model.buildPrompt("SKILL", prefs, { time: "now" }, "set up for deep work");
  assert.ok(prompt.startsWith("SKILL"));
  assert.ok(prompt.includes('"time": "now"'));
  assert.ok(prompt.includes("set up for deep work"));
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
