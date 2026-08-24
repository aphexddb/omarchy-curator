// Model.js unit tests. Run with: node test/model-test.js
// No framework — assert() and a pass/fail summary, like omarchy's own
// node-backed shell tests.

const assert = require("node:assert");
const Model = require("../Model.js");
const Learnings = require("../Learnings.js");

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

test("prompt has no habits section without habits", () => {
  const prompt = Model.buildPrompt("SKILL", prefs, { time: "now" }, "", null);
  assert.ok(!prompt.includes("## Learned habits"));
});

test("prompt injects learned habits between context and request", () => {
  const habits = { sampleCount: 42, topAppsByTimeOfDay: [{ timeOfDay: "morning", class: "nvim", share: 0.7 }] };
  const prompt = Model.buildPrompt("SKILL", prefs, { time: "now" }, "hi", habits);
  const habitsAt = prompt.indexOf("## Learned habits");
  assert.ok(habitsAt !== -1);
  assert.ok(prompt.includes('"sampleCount": 42'));
  assert.ok(habitsAt > prompt.indexOf("## Live desktop context"));
  assert.ok(habitsAt < prompt.indexOf("## Request"));
});

// ---------------------------------------------------------------- learnings: sql escaping

test("sqlText doubles single quotes", () => {
  assert.strictEqual(Learnings.sqlText("it's"), "'it''s'");
  assert.strictEqual(Learnings.sqlText(null), "NULL");
});

test("sqlText neutralizes an injection attempt", () => {
  assert.strictEqual(
    Learnings.sqlText("x'); DROP TABLE samples; --"),
    "'x''); DROP TABLE samples; --'");
});

test("sqlInt rejects non-numbers", () => {
  assert.strictEqual(Learnings.sqlInt(85), "85");
  assert.strictEqual(Learnings.sqlInt("12"), "12");
  assert.strictEqual(Learnings.sqlInt("12; DROP"), "NULL");
  assert.strictEqual(Learnings.sqlInt(null), "NULL");
});

// ---------------------------------------------------------------- learnings: samples

// A probe blob like sampleProc produces, Wednesday 2026-01-07 14:30 local.
const sampleNow = new Date(2026, 0, 7, 14, 30).getTime();
const probe = {
  focusedClass: "chromium",
  activeWorkspace: 2,
  workspaces: [{ id: 1, windows: 3 }, { id: 2, windows: 1 }],
  nightlight: false,
  theme: "tokyo-night",
  dnd: "off",
  battery: "85",
  charging: "Discharging"
};

test("makeSample flattens a probe blob", () => {
  const s = Learnings.makeSample(probe, sampleNow);
  assert.strictEqual(s.ts, Math.floor(sampleNow / 1000));
  assert.strictEqual(s.hour, 14);
  assert.strictEqual(s.dow, 3);
  assert.strictEqual(s.focusedClass, "chromium");
  assert.strictEqual(s.activeWorkspace, 2);
  assert.strictEqual(s.windowCount, 4);
  assert.deepStrictEqual(s.workspaceWindows, { "1": 3, "2": 1 });
  assert.strictEqual(s.battery, 85);
  assert.strictEqual(s.charging, 0);
  assert.strictEqual(s.dnd, 0);
  assert.strictEqual(s.nightlight, 0);
});

test("makeSample tolerates a missing battery and unknown charging state", () => {
  const s = Learnings.makeSample({ battery: "", charging: "", dnd: "on", nightlight: true }, sampleNow);
  assert.strictEqual(s.battery, null);
  assert.strictEqual(s.charging, null);
  assert.strictEqual(s.dnd, 1);
  assert.strictEqual(s.nightlight, 1);
  assert.strictEqual(s.focusedClass, "");
  assert.strictEqual(s.activeWorkspace, null);
});

test("makeSample counts Full as charging", () => {
  assert.strictEqual(Learnings.makeSample({ charging: "Full" }, sampleNow).charging, 1);
  assert.strictEqual(Learnings.makeSample({ charging: "Charging" }, sampleNow).charging, 1);
  assert.strictEqual(Learnings.makeSample({ charging: "Not charging" }, sampleNow).charging, 0);
});

test("insertSql batches rows and keeps quotes inert", () => {
  const evil = Learnings.makeSample(
    Object.assign({}, probe, { focusedClass: "it's-a-me'); DROP TABLE samples; --" }), sampleNow);
  const sql = Learnings.insertSql([Learnings.makeSample(probe, sampleNow), evil]);
  assert.ok(sql.startsWith("INSERT INTO samples ("));
  assert.ok(sql.includes("'chromium'"));
  assert.ok(sql.includes("'it''s-a-me''); DROP TABLE samples; --'"));
  assert.ok(!sql.includes("'); DROP") || sql.includes("''); DROP"));
  assert.strictEqual((sql.match(/\n\(/g) || []).length, 2);
});

test("insertSql with no rows is empty", () => {
  assert.strictEqual(Learnings.insertSql([]), "");
  assert.strictEqual(Learnings.insertSql(null), "");
});

// ---------------------------------------------------------------- learnings: aggregation

test("aggregationSql embeds a numeric cutoff only", () => {
  assert.ok(Learnings.aggregationSql(1700000000).includes("ts >= 1700000000"));
  assert.ok(Learnings.aggregationSql("1700000000.9").includes("ts >= 1700000000"));
  assert.ok(Learnings.aggregationSql("1; DROP TABLE samples").includes("ts >= 0"));
});

test("schemaSql versions the database", () => {
  const sql = Learnings.schemaSql();
  assert.ok(sql.includes("PRAGMA user_version = " + Learnings.DB_SCHEMA_VERSION));
  assert.ok(sql.includes("CREATE TABLE IF NOT EXISTS samples"));
});

test("parseHabits accepts the aggregation output and rejects junk", () => {
  const good = Learnings.parseHabits('{"sampleCount": 12, "themeShare": []}\n');
  assert.strictEqual(good.sampleCount, 12);
  assert.strictEqual(Learnings.parseHabits('{"sampleCount": 0}'), null);
  assert.strictEqual(Learnings.parseHabits("Error: no such table"), null);
  assert.strictEqual(Learnings.parseHabits(""), null);
});

// ---------------------------------------------------------------- learnings: listen window

test("listenDay counts 1-based days", () => {
  const start = sampleNow;
  const day = 24 * 60 * 60 * 1000;
  assert.strictEqual(Learnings.listenDay(0, start), 0);
  assert.strictEqual(Learnings.listenDay(start, start), 1);
  assert.strictEqual(Learnings.listenDay(start, start + 6.5 * day), 7);
  assert.strictEqual(Learnings.listenDay(start, start + 7 * day + 1), 8);
});

test("listenActive gates the 7-day window", () => {
  const start = sampleNow;
  const day = 24 * 60 * 60 * 1000;
  const state = { listenStartedAt: start, listenEndedAt: 0 };
  assert.strictEqual(Learnings.listenActive(state, prefs, start + 3 * day), true);
  assert.strictEqual(Learnings.listenActive(state, prefs, start + 7 * day + 1), false);
  assert.strictEqual(Learnings.listenActive({ listenStartedAt: start, listenEndedAt: start + day }, prefs, start + 2 * day), false);
  assert.strictEqual(Learnings.listenActive({ listenStartedAt: 0, listenEndedAt: 0 }, prefs, start), false);
});

test("listenActive honors the learning.enabled pref", () => {
  const off = Model.defaultPrefs();
  off.learning.enabled = false;
  const state = { listenStartedAt: sampleNow, listenEndedAt: 0 };
  assert.strictEqual(Learnings.listenActive(state, off, sampleNow), false);
});

console.log("\n" + passed + " passed, " + failed + " failed");
process.exit(failed === 0 ? 0 : 1);
