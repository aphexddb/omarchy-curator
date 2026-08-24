import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

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
  readonly property string promptPath: stateDir + "/curator-prompt.txt"
  readonly property string responsePath: stateDir + "/curator-response.txt"
  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")

  property var prefs: Model.defaultPrefs()
  property var curatorState: Model.defaultState()
  property string skillText: ""
  property string pendingRequest: ""

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

  // ---------------------------------------------------------------- suggest

  function suggest(request) {
    if (curatorState.status === "thinking" || curatorState.status === "applying") return
    pendingRequest = String(request || "")
    setState({ status: "thinking", lastError: "" })
    contextProc.running = true
  }

  function onContextReady(text) {
    var raw
    try {
      raw = JSON.parse(text)
    } catch (e) {
      failWith("could not read desktop context: " + e)
      return
    }
    var context = Model.filterContext(raw, prefs)
    var prompt = Model.buildPrompt(skillText, prefs, context, pendingRequest)

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
      try {
        var previous = JSON.parse(text())
        if (previous && previous.version === 1 && service.curatorState.updatedAt === 0) {
          if (previous.status === "thinking" || previous.status === "applying") previous.status = "idle"
          service.curatorState = previous
        }
      } catch (e) {}
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

  Component.onCompleted: initProc.running = true

  // ---------------------------------------------------------------- ipc

  IpcHandler {
    target: "curator"

    function status(): string {
      return JSON.stringify(service.curatorState)
    }

    function suggest(request: string): string {
      service.suggest(request)
      return "thinking"
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
