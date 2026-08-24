// Curator model logic: preferences, prompt construction, response parsing,
// and the action allowlist. Pure functions only — no QML types, no IO — so
// the same file loads from Service.qml and from `node test/model-test.js`.

var SCHEMA_VERSION = 1;

// Hyprland dispatchers the AI may drive. Everything else is rejected before
// it reaches a shell. Deliberately excludes exec, keyword, plugin, dpms,
// exit, and anything else that changes config or leaves the window-management
// domain.
var DISPATCH_ALLOW = [
  "workspace", "movetoworkspace", "movetoworkspacesilent", "focuswindow",
  "focusmonitor", "movefocus", "movewindow", "swapwindow", "resizeactive",
  "splitratio", "togglefloating", "pseudo", "pin", "fullscreen",
  "fakefullscreen", "centerwindow", "cyclenext", "togglegroup", "togglesplit"
];

// Characters with no legitimate use in a dispatch argument. Injection is
// already impossible — every argv element is single-quoted by scriptFor —
// so this only rejects the obviously hostile. Regex selector characters
// ($, ^, parens, backslash) stay allowed: class:^(chromium)$ is normal.
var UNSAFE_ARG = /[;&|`<>\n\r]/;

function defaultPrefs() {
  return {
    version: SCHEMA_VERSION,
    modes: {
      "deep-work": {
        description: "Focused coding or writing. Terminal and editor only, notifications silenced.",
        preferredApps: ["alacritty", "nvim", "obsidian"],
        theme: "",
        dnd: true,
        trusted: false
      },
      "meeting": {
        description: "Video call. Browser or meeting app focused, notifications silenced.",
        preferredApps: ["chromium"],
        theme: "",
        dnd: true,
        trusted: false
      },
      "evening": {
        description: "Winding down. Warm colors, night light on, notifications allowed.",
        preferredApps: [],
        theme: "",
        nightlight: true,
        dnd: false,
        trusted: false
      }
    },
    timeRules: [
      { from: "09:00", to: "12:00", prefer: "deep-work" },
      { from: "18:00", to: "22:00", prefer: "evening" }
    ],
    allowedApps: ["alacritty", "nautilus", "chromium", "obsidian", "spotify"],
    autoApplyTrusted: false,
    privacy: {
      preferLocalLLM: false,
      ollamaModel: "",
      sendWindowTitles: true
    }
  };
}

function defaultState() {
  return {
    version: SCHEMA_VERSION,
    status: "idle",          // idle | thinking | ready | applying | applied | undone | error
    mode: "",
    recommendation: null,
    snapshot: null,
    appliedTypes: [],
    lastError: "",
    updatedAt: 0
  };
}

// ---------------------------------------------------------------- context

// Reduce raw hyprctl output to the minimum the model needs, honoring the
// privacy settings. Never forward pids, addresses, or monitor serials.
function filterContext(raw, prefs) {
  var sendTitles = !!(prefs && prefs.privacy && prefs.privacy.sendWindowTitles);
  var out = {
    time: raw.time || "",
    battery: raw.battery || "",
    theme: raw.theme || "",
    dnd: raw.dnd || "",
    activeWorkspace: null,
    clients: [],
    workspaces: []
  };

  var active = raw.activeWindow && raw.activeWindow.class ? raw.activeWindow : null;
  if (Array.isArray(raw.workspaces)) {
    for (var w = 0; w < raw.workspaces.length; w++) {
      var ws = raw.workspaces[w];
      out.workspaces.push({ id: ws.id, windows: ws.windows });
    }
  }
  if (raw.activeWorkspaceId !== undefined && raw.activeWorkspaceId !== null)
    out.activeWorkspace = raw.activeWorkspaceId;

  if (Array.isArray(raw.clients)) {
    for (var i = 0; i < raw.clients.length; i++) {
      var c = raw.clients[i];
      if (!c || !c.class) continue;
      var row = {
        class: c.class,
        workspace: c.workspace ? c.workspace.id : null,
        floating: !!c.floating,
        focused: !!(active && active.address && c.address === active.address)
      };
      if (sendTitles) row.title = String(c.title || "");
      out.clients.push(row);
    }
  }
  return out;
}

// ---------------------------------------------------------------- prompt

function buildPrompt(skillText, prefs, context, request) {
  var prefsForModel = {
    modes: prefs.modes,
    timeRules: prefs.timeRules,
    allowedApps: prefs.allowedApps
  };
  return skillText
    + "\n\n## User preferences\n```json\n" + JSON.stringify(prefsForModel, null, 2)
    + "\n```\n\n## Live desktop context\n```json\n" + JSON.stringify(context, null, 2)
    + "\n```\n\n## Request\n" + (request && request.trim() ? request.trim() : "What should I be seeing right now?")
    + "\n\nReply with the single JSON object described in the output contract. No prose before or after it.\n";
}

// ---------------------------------------------------------------- parsing

// Agents wrap JSON in prose or fences no matter how firmly asked not to.
// Find the first balanced top-level object and parse that.
function extractJson(text) {
  var s = String(text || "");
  var start = s.indexOf("{");
  while (start !== -1) {
    var depth = 0, inString = false, escaped = false;
    for (var i = start; i < s.length; i++) {
      var ch = s[i];
      if (inString) {
        if (escaped) escaped = false;
        else if (ch === "\\") escaped = true;
        else if (ch === '"') inString = false;
      } else if (ch === '"') inString = true;
      else if (ch === "{") depth++;
      else if (ch === "}") {
        depth--;
        if (depth === 0) {
          try { return JSON.parse(s.slice(start, i + 1)); } catch (e) { break; }
        }
      }
    }
    start = s.indexOf("{", start + 1);
  }
  return null;
}

function parseRecommendation(text) {
  var obj = extractJson(text);
  if (!obj) return { ok: false, error: "no JSON object found in agent output" };
  if (!Array.isArray(obj.actions)) return { ok: false, error: "agent output has no actions array" };
  return {
    ok: true,
    recommendation: {
      mode: String(obj.mode || ""),
      confidence: typeof obj.confidence === "number" ? Math.max(0, Math.min(1, obj.confidence)) : 0,
      rationale: String(obj.rationale || ""),
      previewDescription: String(obj.previewDescription || ""),
      preview: obj.preview && Array.isArray(obj.preview.windows) ? obj.preview : null,
      actions: obj.actions
    }
  };
}

// ---------------------------------------------------------------- actions

function appAllowlist(prefs) {
  var seen = {};
  var list = Array.isArray(prefs.allowedApps) ? prefs.allowedApps.slice() : [];
  if (prefs.modes) {
    for (var mode in prefs.modes) {
      var apps = prefs.modes[mode] && prefs.modes[mode].preferredApps;
      if (Array.isArray(apps)) list = list.concat(apps);
    }
  }
  var out = [];
  for (var i = 0; i < list.length; i++) {
    var app = String(list[i]);
    if (!seen[app]) { seen[app] = true; out.push(app); }
  }
  return out;
}

// Validate one action and, when valid, produce the argv to run it. Returns
// { allowed, reason, command, description }.
function checkAction(action, prefs) {
  if (!action || typeof action !== "object" || typeof action.type !== "string")
    return { allowed: false, reason: "malformed action", command: null, description: "malformed action" };

  switch (action.type) {
    case "theme": {
      var name = String(action.name || "");
      if (!/^[a-z0-9][a-z0-9-]*$/.test(name))
        return { allowed: false, reason: "invalid theme name", command: null, description: "theme: " + name };
      return { allowed: true, reason: "", command: ["omarchy-theme-set", name], description: "Switch theme to " + name };
    }
    case "background": {
      return { allowed: true, reason: "", command: ["omarchy-theme-bg-next"], description: "Cycle to the next background" };
    }
    case "workspace": {
      var id = Number(action.id);
      if (!Number.isInteger(id) || id < 1 || id > 10)
        return { allowed: false, reason: "workspace id must be 1-10", command: null, description: "workspace: " + action.id };
      return { allowed: true, reason: "", command: ["hyprctl", "dispatch", "workspace", String(id)], description: "Go to workspace " + id };
    }
    case "hyprctl": {
      var tokens = String(action.cmd || "").trim().split(/\s+/);
      if (tokens[0] !== "dispatch" || tokens.length < 2)
        return { allowed: false, reason: "only 'dispatch' is allowed", command: null, description: "hyprctl: " + action.cmd };
      var verb = tokens[1];
      if (DISPATCH_ALLOW.indexOf(verb) === -1)
        return { allowed: false, reason: "dispatcher '" + verb + "' is not on the allowlist", command: null, description: "hyprctl: " + action.cmd };
      var arg = tokens.slice(2).join(" ");
      if (UNSAFE_ARG.test(arg))
        return { allowed: false, reason: "unsafe characters in dispatch argument", command: null, description: "hyprctl: " + action.cmd };
      var argv = ["hyprctl", "dispatch", verb];
      if (arg) argv.push(arg);
      return { allowed: true, reason: "", command: argv, description: "hyprctl dispatch " + verb + (arg ? " " + arg : "") };
    }
    case "exec": {
      var app = String(action.app || action.cmd || "");
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(app))
        return { allowed: false, reason: "exec takes a bare command name, no arguments", command: null, description: "launch: " + app };
      if (appAllowlist(prefs).indexOf(app) === -1)
        return { allowed: false, reason: "'" + app + "' is not in your allowed apps", command: null, description: "launch: " + app };
      return { allowed: true, reason: "", command: ["omarchy-launch-or-focus", app], description: "Launch or focus " + app };
    }
    case "dnd": {
      var on = action.enable === true;
      return { allowed: true, reason: "", command: ["omarchy-shell", "-q", "notifications", "setDnd", on ? "on" : "off"],
               description: (on ? "Silence" : "Allow") + " notifications" };
    }
    case "nightlight": {
      var enable = action.enable === true;
      return { allowed: true, reason: "", command: ["omarchy-shell", "-q", "nightlight", enable ? "enable" : "disable"],
               description: (enable ? "Enable" : "Disable") + " night light" };
    }
    default:
      return { allowed: false, reason: "unknown action type '" + action.type + "'", command: null, description: String(action.type) };
  }
}

// Annotate every action in a recommendation in place-safe copies.
function validateActions(actions, prefs) {
  var out = [];
  for (var i = 0; i < (actions || []).length; i++) {
    var verdict = checkAction(actions[i], prefs);
    var row = {};
    for (var k in actions[i]) row[k] = actions[i][k];
    row.__allowed = verdict.allowed;
    row.__reason = verdict.reason;
    row.__description = verdict.description;
    row.__command = verdict.command;
    out.push(row);
  }
  return out;
}

// ---------------------------------------------------------------- shell

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function scriptFor(argvList) {
  var lines = [];
  for (var i = 0; i < argvList.length; i++) {
    var argv = argvList[i];
    if (!argv) continue;
    var quoted = [];
    for (var j = 0; j < argv.length; j++) quoted.push(shellQuote(argv[j]));
    lines.push(quoted.join(" "));
  }
  return lines.join("\n");
}

// Undo only touches the aspects the applied plan changed. `snapshot` comes
// from the pre-apply probe; `appliedTypes` is the list of action types that
// actually ran.
function undoCommands(snapshot, appliedTypes) {
  var argvList = [];
  function touched(t) { return appliedTypes.indexOf(t) !== -1; }
  if (!snapshot) return argvList;
  if (touched("theme") && snapshot.theme)
    argvList.push(["omarchy-theme-set", String(snapshot.theme)]);
  if ((touched("workspace") || touched("hyprctl")) && Number.isInteger(snapshot.workspace))
    argvList.push(["hyprctl", "dispatch", "workspace", String(snapshot.workspace)]);
  if (touched("dnd"))
    argvList.push(["omarchy-shell", "-q", "notifications", "setDnd", snapshot.dnd === "on" ? "on" : "off"]);
  if (touched("nightlight"))
    argvList.push(["omarchy-shell", "-q", "nightlight", snapshot.nightlight === true ? "enable" : "disable"]);
  return argvList;
}

// ---------------------------------------------------------------- exports

// QML `import "Model.js" as Model` sees top-level functions directly; node
// needs module.exports. Guard so QML does not trip on `module`.
if (typeof module !== "undefined" && module.exports) {
  module.exports = {
    defaultPrefs: defaultPrefs,
    defaultState: defaultState,
    filterContext: filterContext,
    buildPrompt: buildPrompt,
    extractJson: extractJson,
    parseRecommendation: parseRecommendation,
    appAllowlist: appAllowlist,
    checkAction: checkAction,
    validateActions: validateActions,
    shellQuote: shellQuote,
    scriptFor: scriptFor,
    undoCommands: undoCommands,
    DISPATCH_ALLOW: DISPATCH_ALLOW
  };
}
