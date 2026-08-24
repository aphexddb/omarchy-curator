// Curator learnings: everything around the local SQLite habit store that can
// be expressed as pure functions — schema SQL, sample-row formatting and
// escaping, the aggregation query, its output parsing, and the 7-day
// listen-window math. No QML types, no IO — the same file loads from
// Service.qml and from `node test/model-test.js`. Service.qml owns the
// sqlite3 processes; this file only builds the SQL they run.

var DB_SCHEMA_VERSION = 1;

// Length of the initial listen-only period, in days.
var LISTEN_DAYS = 7;

// Flush the in-memory sample buffer to sqlite once it holds this many rows
// (a periodic timer in Service.qml also flushes smaller buffers).
var FLUSH_MAX_SAMPLES = 5;

// How far back the suggest-time aggregation looks.
var HABITS_WINDOW_DAYS = 30;

var MS_PER_DAY = 24 * 60 * 60 * 1000;

// ---------------------------------------------------------------- listen window

// 1-based day number of the listen period: 1 on the day sampling started,
// LISTEN_DAYS + 1 once the full period has elapsed. 0 when never started.
function listenDay(startMs, nowMs) {
  if (!startMs || startMs <= 0) return 0;
  var elapsed = Math.max(0, nowMs - startMs);
  return Math.floor(elapsed / MS_PER_DAY) + 1;
}

// Whether the listen-only gate is currently closed (AI suggestions blocked).
function listenActive(state, prefs, nowMs) {
  if (prefs && prefs.learning && prefs.learning.enabled === false) return false;
  if (!state || !state.listenStartedAt) return false;
  if (state.listenEndedAt) return false;
  return listenDay(state.listenStartedAt, nowMs) <= LISTEN_DAYS;
}

// ---------------------------------------------------------------- schema

function schemaSql() {
  return [
    "PRAGMA user_version = " + DB_SCHEMA_VERSION + ";",
    "CREATE TABLE IF NOT EXISTS samples (",
    "  ts INTEGER NOT NULL,",
    "  hour INTEGER NOT NULL,",
    "  dow INTEGER NOT NULL,",
    "  focused_class TEXT NOT NULL DEFAULT '',",
    "  active_workspace INTEGER,",
    "  window_count INTEGER NOT NULL DEFAULT 0,",
    "  workspace_windows TEXT NOT NULL DEFAULT '{}',",
    "  battery INTEGER,",
    "  charging INTEGER,",
    "  theme TEXT NOT NULL DEFAULT '',",
    "  dnd INTEGER NOT NULL DEFAULT 0,",
    "  nightlight INTEGER NOT NULL DEFAULT 0",
    ");",
    "CREATE INDEX IF NOT EXISTS samples_ts ON samples (ts);"
  ].join("\n");
}

// ---------------------------------------------------------------- escaping

// SQL text literal: single quotes doubled, so a window class like
// "it's-a-me'); DROP TABLE samples; --" stays one inert string.
function sqlText(value) {
  if (value === null || value === undefined) return "NULL";
  return "'" + String(value).replace(/'/g, "''") + "'";
}

// SQL integer literal, NULL for anything non-numeric.
function sqlInt(value) {
  if (value === null || value === undefined) return "NULL";
  var n = Number(value);
  if (!Number.isFinite(n)) return "NULL";
  return String(Math.round(n));
}

// ---------------------------------------------------------------- samples

// Reduce one sample-probe JSON blob (see sampleProc in Service.qml) to the
// flat row the samples table stores. Local hour/dow are computed here so the
// database never has to reason about timezones.
function makeSample(probe, nowMs) {
  var d = new Date(nowMs);

  var workspaceWindows = {};
  var windowCount = 0;
  var list = probe && Array.isArray(probe.workspaces) ? probe.workspaces : [];
  for (var i = 0; i < list.length; i++) {
    var ws = list[i];
    if (!ws || ws.id === undefined || ws.id === null) continue;
    var n = Number(ws.windows) || 0;
    workspaceWindows[String(ws.id)] = n;
    windowCount += n;
  }

  var battery = null;
  if (probe && probe.battery !== undefined && String(probe.battery).trim() !== "") {
    var b = parseInt(String(probe.battery), 10);
    if (Number.isInteger(b)) battery = Math.max(0, Math.min(100, b));
  }

  var charging = null;
  var status = probe ? String(probe.charging || "").trim() : "";
  if (status === "Charging" || status === "Full") charging = 1;
  else if (status === "Discharging" || status === "Not charging") charging = 0;

  var dnd = probe ? String(probe.dnd || "").trim() : "";

  return {
    ts: Math.floor(nowMs / 1000),
    hour: d.getHours(),
    dow: d.getDay(),
    focusedClass: probe && probe.focusedClass ? String(probe.focusedClass) : "",
    activeWorkspace: probe && Number.isInteger(probe.activeWorkspace) ? probe.activeWorkspace : null,
    windowCount: windowCount,
    workspaceWindows: workspaceWindows,
    battery: battery,
    charging: charging,
    theme: probe && probe.theme ? String(probe.theme) : "",
    dnd: (dnd === "on" || dnd === "true" || dnd === "1") ? 1 : 0,
    nightlight: probe && probe.nightlight === true ? 1 : 0
  };
}

function sampleValues(s) {
  return "(" + [
    sqlInt(s.ts), sqlInt(s.hour), sqlInt(s.dow),
    sqlText(s.focusedClass),
    sqlInt(s.activeWorkspace),
    sqlInt(s.windowCount),
    sqlText(JSON.stringify(s.workspaceWindows || {})),
    sqlInt(s.battery), sqlInt(s.charging),
    sqlText(s.theme), sqlInt(s.dnd), sqlInt(s.nightlight)
  ].join(", ") + ")";
}

function insertSql(samples) {
  if (!Array.isArray(samples) || samples.length === 0) return "";
  var rows = [];
  for (var i = 0; i < samples.length; i++) rows.push(sampleValues(samples[i]));
  return "INSERT INTO samples (ts, hour, dow, focused_class, active_workspace, "
    + "window_count, workspace_windows, battery, charging, theme, dnd, nightlight) VALUES\n"
    + rows.join(",\n") + ";";
}

// ---------------------------------------------------------------- aggregation

// Epoch-seconds cutoff for the aggregation window.
function habitsSince(nowMs) {
  return Math.floor(nowMs / 1000) - HABITS_WINDOW_DAYS * 24 * 60 * 60;
}

// One query, one output row, one JSON object — the whole "learned habits"
// summary the suggest flow injects into the prompt. Scalar subqueries strip
// SQLite's JSON subtype, hence the json() wrappers.
function aggregationSql(sinceEpochSeconds) {
  var since = Number.isFinite(Number(sinceEpochSeconds)) ? Math.floor(Number(sinceEpochSeconds)) : 0;
  return [
    "WITH recent AS (",
    "  SELECT *,",
    "    CASE",
    "      WHEN hour BETWEEN 5 AND 11 THEN 'morning'",
    "      WHEN hour BETWEEN 12 AND 17 THEN 'afternoon'",
    "      WHEN hour BETWEEN 18 AND 22 THEN 'evening'",
    "      ELSE 'night'",
    "    END AS bucket",
    "  FROM samples WHERE ts >= " + since,
    "),",
    "app_counts AS (",
    "  SELECT bucket, focused_class AS class,",
    "    COUNT(*) * 1.0 / SUM(COUNT(*)) OVER (PARTITION BY bucket) AS share,",
    "    ROW_NUMBER() OVER (PARTITION BY bucket ORDER BY COUNT(*) DESC) AS rank",
    "  FROM recent WHERE focused_class != '' GROUP BY bucket, focused_class",
    "),",
    "theme_counts AS (",
    "  SELECT theme, COUNT(*) * 1.0 / (SELECT COUNT(*) FROM recent) AS share",
    "  FROM recent WHERE theme != '' GROUP BY theme ORDER BY share DESC LIMIT 5",
    "),",
    "battery_buckets AS (",
    "  SELECT bucket, CAST(AVG(battery) AS INTEGER) AS avg_battery,",
    "    ROUND(AVG(charging), 2) AS charging_share",
    "  FROM recent WHERE battery IS NOT NULL GROUP BY bucket",
    ")",
    "SELECT json_object(",
    "  'sampleCount', (SELECT COUNT(*) FROM recent),",
    "  'daysObserved', (SELECT COUNT(DISTINCT date(ts, 'unixepoch', 'localtime')) FROM recent),",
    "  'topAppsByTimeOfDay', json((SELECT json_group_array(json_object(",
    "    'timeOfDay', bucket, 'class', class, 'share', ROUND(share, 2)))",
    "    FROM (SELECT * FROM app_counts WHERE rank <= 3 ORDER BY bucket, rank))),",
    "  'themeShare', json((SELECT json_group_array(json_object(",
    "    'theme', theme, 'share', ROUND(share, 2))) FROM theme_counts)),",
    "  'battery', json((SELECT json_group_array(json_object(",
    "    'timeOfDay', bucket, 'avgPercent', avg_battery, 'chargingShare', charging_share))",
    "    FROM battery_buckets)),",
    "  'dndShare', (SELECT ROUND(AVG(dnd), 2) FROM recent),",
    "  'avgOpenWindows', (SELECT ROUND(AVG(window_count), 1) FROM recent)",
    ");"
  ].join("\n");
}

// Parse the single JSON line the aggregation query prints. Returns null for
// anything unusable (sqlite errors, empty database) so the caller can just
// skip the habits section.
function parseHabits(text) {
  var obj;
  try {
    obj = JSON.parse(String(text || "").trim());
  } catch (e) {
    return null;
  }
  if (!obj || typeof obj !== "object") return null;
  if (typeof obj.sampleCount !== "number" || obj.sampleCount <= 0) return null;
  return obj;
}

// ---------------------------------------------------------------- exports

// QML `import "Learnings.js" as Learnings` sees top-level names directly;
// node needs module.exports. Guard so QML does not trip on `module`.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    DB_SCHEMA_VERSION: DB_SCHEMA_VERSION,
    LISTEN_DAYS: LISTEN_DAYS,
    FLUSH_MAX_SAMPLES: FLUSH_MAX_SAMPLES,
    HABITS_WINDOW_DAYS: HABITS_WINDOW_DAYS,
    listenDay: listenDay,
    listenActive: listenActive,
    schemaSql: schemaSql,
    sqlText: sqlText,
    sqlInt: sqlInt,
    makeSample: makeSample,
    sampleValues: sampleValues,
    insertSql: insertSql,
    habitsSince: habitsSince,
    aggregationSql: aggregationSql,
    parseHabits: parseHabits
  };
}
