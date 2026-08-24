import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model
import "Learnings.js" as Learnings

// Curator service: always-loaded orchestrator. Collects desktop context,
// asks the user's default agent (or a local model) for a recommendation,
// validates the returned actions against the allowlist, and executes them
// only on explicit apply. State is shared with the panel and bar widget
// through ~/.local/state/omarchy/curator.json; they talk back through the
// `curator` IPC target.
Item {
  id: service

  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/omarchy/curator"
  readonly property string stateDir: home + "/.local/state/omarchy"
  readonly property string prefsPath: configDir + "/prefs.json"
  readonly property string statePath: stateDir + "/curator.json"
  readonly property string dbPath: stateDir + "/curator.db"
  readonly property string promptPath: stateDir + "/curator-prompt.txt"
  readonly property string responsePath: stateDir + "/curator-response.txt"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  property var prefs: Model.defaultPrefs()
  property var curatorState: Model.defaultState()
  property string skillText: ""
  property string pendingRequest: ""
  property var pendingContext: null
  property bool sqliteAvailable: false
  property var sampleBuffer: []

  readonly property bool learningEnabled: !prefs.learning || prefs.learning.enabled !== false
  readonly property int sampleBaseMs: (prefs.learning && prefs.learning.sampleIntervalSeconds > 0
    ? prefs.learning.sampleIntervalSeconds : 90) * 1000

  // ---------------------------------------------------------------- state

  function setState(patch) {
    var next = {}
    for (var k in curatorState) next[k] = curatorState[k]
    for (var p in patch) next[p] = patch[p]
    next.updatedAt = Date.now()
    curatorState = next
    stateFile.setText(JSON.stringify(next, null, 2) + "\n")
  }

  function failWith(message) {
    console.warn("curator: " + message)
    setState({ status: "error", lastError: message })
  }

  // ---------------------------------------------------------------- listen

  // Keep the derived listening/listenDay fields in the shared state file
  // current, so the panel and bar widget can render them without repeating
  // the window math. Detects natural expiry of the 7-day period.
  function refreshListenState() {
    var now = Date.now()
    var active = Learnings.listenActive(curatorState, prefs, now)
    var day = Math.min(Learnings.listenDay(curatorState.listenStartedAt, now), Learnings.LISTEN_DAYS)
    if (curatorState.listenStartedAt > 0 && curatorState.listenEndedAt === 0
        && !active && learningEnabled) {
      setState({ listening: false, listenEndedAt: now, listenDay: Learnings.LISTEN_DAYS })
      Quickshell.execDetached(["omarchy-notification-send", "Curator",
        "Finished learning your desktop — suggestions are now available"])
      return
    }
    if (curatorState.listening !== active || curatorState.listenDay !== day)
      setState({ listening: active, listenDay: day })
  }

  function finishListening() {
    if (curatorState.listenStartedAt === 0 || curatorState.listenEndedAt > 0) return "not listening"
    setState({ listening: false, listenEndedAt: Date.now() })
    return "ok"
  }

  // ---------------------------------------------------------------- suggest

  function suggest(request) {
    if (curatorState.status === "thinking" || curatorState.status === "applying") return "busy"
    refreshListenState()
    if (curatorState.listening)
      return "listening (day " + curatorState.listenDay + "/" + Learnings.LISTEN_DAYS + ")"
    pendingRequest = String(request || "")
    setState({ status: "thinking", lastError: "" })
    contextProc.running = true
    return "thinking"
  }

  function onContextReady(text) {
    var raw
    try {
      raw = JSON.parse(text)
    } catch (e) {
      failWith("could not read desktop context: " + e)
      return
    }
    pendingContext = Model.filterContext(raw, prefs)
    if (sqliteAvailable) {
      habitsProc.command = ["sqlite3", service.dbPath, Learnings.aggregationSql(Learnings.habitsSince(Date.now()))]
      habitsProc.running = true
    } else {
      runAgent(null)
    }
  }

  function onHabitsReady(text, exitCode) {
    if (exitCode !== 0) console.warn("curator: habits aggregation failed (exit " + exitCode + ")")
    runAgent(exitCode === 0 ? Learnings.parseHabits(text) : null)
  }

  function runAgent(habits) {
    var prompt = Model.buildPrompt(skillText, prefs, pendingContext, pendingRequest, habits)

    // Write the prompt where the user can inspect it, then run the agent on
    // it — one process, so the file is complete before the agent reads it.
    agentProc.command = ["bash", "-c",
      'printf \'%s\' "$1" >"$2" && exec "$3" "$2" "$4"',
      "curator-agent", prompt, service.promptPath,
      service.pluginDir + "/bin/curator-agent", service.prefsPath]
    agentTimeout.restart()
    agentProc.running = true
  }

  function onAgentDone(text, exitCode) {
    agentTimeout.stop()
    responseFile.setText(String(text || ""))
    if (exitCode !== 0) {
      failWith("agent exited with " + exitCode + " — see " + service.responsePath)
      return
    }
    var parsed = Model.parseRecommendation(text)
    if (!parsed.ok) {
      failWith(parsed.error + " — see " + service.responsePath)
      return
    }
    var rec = parsed.recommendation
    rec.actions = Model.validateActions(rec.actions, prefs)
    setState({ status: "ready", mode: rec.mode, recommendation: rec, appliedTypes: [], snapshot: null })

    var modeConf = prefs.modes ? prefs.modes[rec.mode] : null
    if (prefs.autoApplyTrusted === true && modeConf && modeConf.trusted === true) {
      applyRecommendation()
      return
    }
    Quickshell.execDetached(["omarchy-notification-send", "Curator",
      rec.mode ? rec.mode + " (" + Math.round(rec.confidence * 100) + "%) — review in the Curator panel" : "Recommendation ready"])
  }

  // ---------------------------------------------------------------- apply

  function applyRecommendation() {
    if (curatorState.status !== "ready" || !curatorState.recommendation) return "nothing to apply"
    setState({ status: "applying" })
    snapshotProc.running = true
    return "applying"
  }

  function onSnapshotReady(text) {
    var snapshot = null
    try { snapshot = JSON.parse(text) } catch (e) { snapshot = null }

    var rec = curatorState.recommendation
    var argvList = []
    var appliedTypes = []
    for (var i = 0; i < rec.actions.length; i++) {
      var action = rec.actions[i]
      if (action.__allowed && action.__command) {
        argvList.push(action.__command)
        if (appliedTypes.indexOf(action.type) === -1) appliedTypes.push(action.type)
      }
    }
    if (argvList.length === 0) {
      setState({ status: "ready", lastError: "no allowed actions in this plan" })
      return
    }
    setState({ snapshot: snapshot, appliedTypes: appliedTypes })
    applyProc.command = ["bash", "-c", Model.scriptFor(argvList)]
    applyProc.running = true
  }

  function onApplyDone(exitCode) {
    if (exitCode !== 0) setState({ status: "applied", lastError: "some actions failed (exit " + exitCode + ")" })
    else setState({ status: "applied", lastError: "" })
  }

  // ---------------------------------------------------------------- undo

  function undoLast() {
    if (!curatorState.snapshot || !Array.isArray(curatorState.appliedTypes) || curatorState.appliedTypes.length === 0)
      return "nothing to undo"
    var argvList = Model.undoCommands(curatorState.snapshot, curatorState.appliedTypes)
    if (argvList.length === 0) return "nothing to undo"
    undoProc.command = ["bash", "-c", Model.scriptFor(argvList)]
    undoProc.running = true
    setState({ status: "undone", appliedTypes: [], snapshot: null })
    return "undone"
  }

  function dismiss() {
    setState({ status: "idle", mode: "", recommendation: null, appliedTypes: [], snapshot: null, lastError: "" })
  }

  // ---------------------------------------------------------------- sampling

  // One cheap probe result becomes one buffered row; the buffer flushes to
  // sqlite in a single invocation every FLUSH_MAX_SAMPLES rows or when the
  // flush timer fires. Samples never touch the shared state file.
  function onSampleReady(text) {
    var probe
    try {
      probe = JSON.parse(text)
    } catch (e) {
      return
    }
    var buf = sampleBuffer.slice()
    buf.push(Learnings.makeSample(probe, Date.now()))
    sampleBuffer = buf
    if (sampleBuffer.length >= Learnings.FLUSH_MAX_SAMPLES) flushSamples()
  }

  function flushSamples() {
    if (!sqliteAvailable || sampleBuffer.length === 0 || flushProc.running) return
    var sql = Learnings.insertSql(sampleBuffer)
    sampleBuffer = []
    flushProc.command = ["sqlite3", service.dbPath, sql]
    flushProc.running = true
  }

  // ---------------------------------------------------------------- files

  FileView {
    id: prefsFile
    path: service.prefsPath
    watchChanges: true
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        service.prefs = JSON.parse(text())
      } catch (e) {
        console.warn("curator: prefs.json is not valid JSON, using defaults: " + e)
        service.prefs = Model.defaultPrefs()
      }
    }
    onLoadFailed: setText(JSON.stringify(Model.defaultPrefs(), null, 2) + "\n")
    onFileChanged: reload()
  }

  FileView {
    id: stateFile
    path: service.statePath
    atomicWrites: true
    printErrors: false
    onLoaded: {
      // Restore across shell restarts, but never resume a half-finished
      // thinking/applying state whose processes died with the old shell.
      // Merge over the defaults so fields added since the file was written
      // (the listen-period ones) still exist.
      try {
        var previous = JSON.parse(text())
        if (previous && previous.version === 1 && service.curatorState.updatedAt === 0) {
          if (previous.status === "thinking" || previous.status === "applying") previous.status = "idle"
          var merged = Model.defaultState()
          for (var k in previous) merged[k] = previous[k]
          service.curatorState = merged
          service.refreshListenState()
        }
      } catch (e) {}
    }
    onLoadFailed: {
      // First run: no prior state file — enter the listen-only period.
      if (service.curatorState.listenStartedAt === 0 && service.curatorState.listenEndedAt === 0)
        service.setState({ listening: true, listenStartedAt: Date.now(), listenDay: 1 })
    }
  }

  FileView {
    id: skillFile
    path: service.pluginDir + "/prompts/curator-skill.md"
    printErrors: false
    onLoaded: service.skillText = text()
    onLoadFailed: console.warn("curator: missing prompts/curator-skill.md in " + service.pluginDir)
  }

  FileView {
    id: responseFile
    path: service.responsePath
    atomicWrites: true
    printErrors: false
  }

  // ---------------------------------------------------------------- procs

  Process {
    id: initProc
    command: ["bash", "-c", 'mkdir -p "$0" "$1"', service.configDir, service.stateDir]
    onExited: {
      prefsFile.reload()
      stateFile.reload()
      sqliteCheckProc.running = true
    }
  }

  // sqlite3 ships with the default package set, but a missing binary must
  // degrade to "no learning" with a note in the state file — never crash
  // the shell over it.
  Process {
    id: sqliteCheckProc
    command: ["bash", "-c", "command -v sqlite3"]
    onExited: function(exitCode) {
      if (exitCode === 0) {
        dbInitProc.command = ["sqlite3", service.dbPath, Learnings.schemaSql()]
        dbInitProc.running = true
      } else {
        console.warn("curator: sqlite3 not found — habit learning disabled, samples will not be stored")
        service.setState({ sqliteMissing: true })
      }
    }
  }

  Process {
    id: dbInitProc
    onExited: function(exitCode) {
      if (exitCode === 0) {
        service.sqliteAvailable = true
        if (service.curatorState.sqliteMissing) service.setState({ sqliteMissing: false })
      } else {
        console.warn("curator: could not initialize " + service.dbPath + " (exit " + exitCode + ")")
        service.setState({ sqliteMissing: true })
      }
    }
  }

  Process {
    id: contextProc
    command: ["bash", "-c",
      'clients=$(hyprctl -j clients 2>/dev/null); [[ $clients == \\[* ]] || clients="[]"; ' +
      'workspaces=$(hyprctl -j workspaces 2>/dev/null); [[ $workspaces == \\[* ]] || workspaces="[]"; ' +
      'active=$(hyprctl -j activewindow 2>/dev/null); [[ $active == \\{* ]] || active="{}"; ' +
      'aws=$(hyprctl -j activeworkspace 2>/dev/null); [[ $aws == \\{* ]] || aws="{}"; ' +
      'theme=$(omarchy-theme-current 2>/dev/null); ' +
      'dnd=$(omarchy-shell -q notifications isDnd 2>/dev/null); ' +
      'batt=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1); ' +
      'jq -n --argjson clients "$clients" --argjson workspaces "$workspaces" ' +
      '--argjson active "$active" --argjson aws "$aws" ' +
      '--arg time "$(date \'+%A %Y-%m-%d %H:%M\')" --arg theme "$theme" ' +
      '--arg dnd "$dnd" --arg battery "$batt" ' +
      '\'{time:$time, theme:$theme, dnd:$dnd, battery:$battery, clients:$clients, workspaces:$workspaces, activeWindow:$active, activeWorkspaceId:($aws.id // null)}\'']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.onContextReady(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0 && service.curatorState.status === "thinking")
        service.failWith("context probe failed (exit " + exitCode + ")")
    }
  }

  Process {
    id: agentProc
    stdout: StdioCollector {
      id: agentStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      service.onAgentDone(agentStdout.text, exitCode)
    }
  }

  Timer {
    id: agentTimeout
    interval: 240000
    onTriggered: {
      if (agentProc.running) {
        agentProc.running = false
        service.failWith("agent timed out after 240s")
      }
    }
  }

  Process {
    id: snapshotProc
    command: ["bash", "-c",
      'aws=$(hyprctl -j activeworkspace 2>/dev/null); [[ $aws == \\{* ]] || aws="{}"; ' +
      'nl=$(omarchy-shell -q nightlight status 2>/dev/null); [[ $nl == \\{* ]] || nl="{}"; ' +
      'jq -n --argjson aws "$aws" --argjson nl "$nl" ' +
      '--arg theme "$(omarchy-theme-current 2>/dev/null)" ' +
      '--arg dnd "$(omarchy-shell -q notifications isDnd 2>/dev/null)" ' +
      '\'{theme:$theme, workspace:($aws.id // null), dnd:$dnd, nightlight:($nl.enabled // false)}\'']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.onSnapshotReady(text)
    }
  }

  Process {
    id: applyProc
    onExited: function(exitCode) {
      service.onApplyDone(exitCode)
    }
  }

  Process {
    id: undoProc
  }

  // Deliberately cheap sample probe: window classes and counts only — no
  // titles, no screenshots, no AI. Battery comes straight from sysfs.
  Process {
    id: sampleProc
    command: ["bash", "-c",
      'aws=$(hyprctl -j activeworkspace 2>/dev/null); [[ $aws == \\{* ]] || aws="{}"; ' +
      'active=$(hyprctl -j activewindow 2>/dev/null); [[ $active == \\{* ]] || active="{}"; ' +
      'workspaces=$(hyprctl -j workspaces 2>/dev/null); [[ $workspaces == \\[* ]] || workspaces="[]"; ' +
      'nl=$(omarchy-shell -q nightlight status 2>/dev/null); [[ $nl == \\{* ]] || nl="{}"; ' +
      'theme=$(omarchy-theme-current 2>/dev/null); ' +
      'dnd=$(omarchy-shell -q notifications isDnd 2>/dev/null); ' +
      'batt=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -1); ' +
      'chg=$(cat /sys/class/power_supply/BAT*/status 2>/dev/null | head -1); ' +
      'jq -n --argjson aws "$aws" --argjson active "$active" --argjson workspaces "$workspaces" ' +
      '--argjson nl "$nl" --arg theme "$theme" --arg dnd "$dnd" --arg battery "$batt" --arg charging "$chg" ' +
      '\'{focusedClass:($active.class // ""), activeWorkspace:($aws.id // null), ' +
      'workspaces:[$workspaces[] | {id, windows}], nightlight:($nl.enabled // false), ' +
      'theme:$theme, dnd:$dnd, battery:$battery, charging:$charging}\'']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: service.onSampleReady(text)
    }
  }

  Process {
    id: flushProc
    onExited: function(exitCode) {
      if (exitCode !== 0) console.warn("curator: sample flush to " + service.dbPath + " failed (exit " + exitCode + ")")
    }
  }

  Process {
    id: habitsProc
    stdout: StdioCollector {
      id: habitsStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      service.onHabitsReady(habitsStdout.text, exitCode)
    }
  }

  // Sampling cadence: every sampleBaseMs (default 90s) while listening,
  // then 5x slower forever after — habits keep tracking how usage drifts.
  Timer {
    id: sampleTimer
    running: service.sqliteAvailable && service.learningEnabled
    repeat: true
    interval: service.curatorState.listening ? service.sampleBaseMs : service.sampleBaseMs * 5
    onTriggered: {
      service.refreshListenState()
      if (!sampleProc.running) sampleProc.running = true
    }
  }

  Timer {
    id: flushTimer
    running: sampleTimer.running
    repeat: true
    interval: 300000
    onTriggered: service.flushSamples()
  }

  // Keeps the listen-day badge current and catches natural expiry even when
  // sqlite3 is missing and the sample timer never runs.
  Timer {
    id: listenRefreshTimer
    running: service.curatorState.listening === true
    repeat: true
    interval: 3600000
    onTriggered: service.refreshListenState()
  }

  Component.onCompleted: initProc.running = true

  // ---------------------------------------------------------------- ipc

  IpcHandler {
    target: "curator"

    function status(): string {
      return JSON.stringify(service.curatorState)
    }

    function suggest(request: string): string {
      return service.suggest(request)
    }

    function finishListening(): string {
      return service.finishListening()
    }

    function apply(): string {
      return service.applyRecommendation()
    }

    function undo(): string {
      return service.undoLast()
    }

    function dismiss(): string {
      service.dismiss()
      return "ok"
    }

    function reloadPrefs(): string {
      prefsFile.reload()
      return "ok"
    }
  }
}
