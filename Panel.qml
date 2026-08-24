import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Learnings.js" as Learnings

// Curator panel: summoned with `omarchy-shell shell toggle curator.desktop "{}"`.
// Shows the current recommendation — rationale, the validated action plan, and
// an optional layout silhouette — with Apply / Undo / Dismiss, plus a free-text
// request box. All mutations go through the `curator` IPC target owned by
// Service.qml; this surface only renders state and sends requests.
Item {
  id: root

  property bool opened: false
  property var curatorState: ({ status: "idle", mode: "", recommendation: null, lastError: "" })
  property var themes: []

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/omarchy/curator.json"

  readonly property color background: Color.menu.background
  readonly property color foreground: Color.menu.text
  readonly property color borderColor: Color.menu.border
  readonly property color scrim: Color.menu.scrim
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: Style.font.family
  property var borderSpec: Border.surfaceSpec("menu", "border", borderColor, Math.max(1, Style.space(2)))

  readonly property var recommendation: curatorState && curatorState.recommendation ? curatorState.recommendation : null
  readonly property string status: curatorState ? String(curatorState.status || "idle") : "idle"
  readonly property bool busy: status === "thinking" || status === "applying"
  readonly property bool listening: curatorState ? curatorState.listening === true : false

  function open(payloadJson) {
    root.opened = true
    if (root.listening) themesProc.running = true
    var payload = null
    try { payload = JSON.parse(payloadJson || "{}") } catch (e) {}
    if (payload && payload.request) {
      requestInput.text = String(payload.request)
      root.sendRequest()
    }
    Qt.callLater(function() { requestInput.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function toggle() {
    if (root.opened) root.close()
    else root.open("{}")
  }

  function curatorCall(args) {
    Quickshell.execDetached(["omarchy-shell", "-q", "curator"].concat(args))
  }

  function sendRequest() {
    if (root.busy || root.listening) return
    curatorCall(["suggest", requestInput.text])
    requestInput.text = ""
  }

  function statusLabel() {
    if (root.listening)
      return "learning · day " + (curatorState.listenDay || 1) + "/" + Learnings.LISTEN_DAYS
    if (status === "thinking") return "thinking…"
    if (status === "applying") return "applying…"
    if (status === "ready" && recommendation)
      return (recommendation.mode || "plan") + " · " + Math.round((recommendation.confidence || 0) * 100) + "%"
    if (status === "applied") return "applied — U to undo"
    if (status === "undone") return "undone"
    if (status === "error") return "error"
    return "idle"
  }

  FileView {
    id: stateWatch
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.curatorState = JSON.parse(text()) } catch (e) {}
    }
    onFileChanged: reload()
  }

  // Read-only theme inventory shown during the listen period. Refreshed on
  // every open so newly installed themes appear.
  Process {
    id: themesProc
    command: ["omarchy-theme-list"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text || "").trim().split("\n")
        var out = []
        for (var i = 0; i < lines.length; i++) {
          var line = lines[i].trim()
          if (line) out.push(line)
        }
        root.themes = out
      }
    }
  }

  component CuratorButton: Rectangle {
    id: button
    property string label: ""
    property bool primary: false
    property bool enabled: true
    signal activated()

    width: buttonText.implicitWidth + Style.spacing.controlPaddingX * 2
    height: Style.spacing.controlHeight
    radius: Style.cornerRadius
    color: buttonArea.containsMouse && button.enabled
      ? Style.selectedFillFor(root.foreground, root.accent)
      : (button.primary ? Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.22) : "transparent")
    border.width: 1
    border.color: Qt.rgba(root.borderColor.r, root.borderColor.g, root.borderColor.b, 0.5)
    opacity: button.enabled ? 1.0 : 0.4

    Text {
      id: buttonText
      anchors.centerIn: parent
      text: button.label
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    MouseArea {
      id: buttonArea
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: button.enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: if (button.enabled) button.activated()
    }
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-curator"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    BorderSurface {
      id: card
      width: Math.min(Style.space(680), panel.width - Style.gapsOut * 2)
      height: Math.min(Style.space(560), panel.height - Style.gapsOut * 2)
      radius: Style.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: Style.spacing.panelPadding

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            root.close()
            event.accepted = true
          } else if (event.key === Qt.Key_U && (event.modifiers & Qt.ControlModifier)) {
            root.curatorCall(["undo"])
            event.accepted = true
          } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                     && (event.modifiers & Qt.ControlModifier)) {
            if (root.status === "ready") root.curatorCall(["apply"])
            event.accepted = true
          }
        }

        Column {
          anchors.fill: parent
          spacing: Style.spacing.panelGap

          // ------------------------------------------------------- header
          Item {
            width: parent.width
            height: Math.max(Style.space(28), Style.font.heading + Style.space(6))

            Text {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "Curator"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.heading
            }

            Text {
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.statusLabel()
              color: root.status === "error" ? root.urgent : root.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ------------------------------------------------------- body
          Flickable {
            width: parent.width
            height: parent.height - Style.space(140)
            contentHeight: bodyColumn.height
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: bodyColumn
              width: parent.width
              spacing: Style.spacing.rowGap

              Text {
                width: parent.width
                visible: root.status === "error" && root.curatorState.lastError
                text: root.curatorState.lastError || ""
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              // Listen-only period: a learning status and a read-only theme
              // inventory instead of the recommendation UI.
              Text {
                width: parent.width
                visible: root.listening
                text: "Learning your desktop — Curator is quietly sampling which apps, workspaces, and themes you use. "
                  + "Suggestions unlock after day " + Learnings.LISTEN_DAYS
                  + ", or right away with `omarchy-shell curator finishListening`."
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                visible: root.listening && root.themes.length > 0
                text: "Installed themes"
                color: root.foreground
                opacity: 0.65
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              Repeater {
                model: root.listening ? root.themes : []

                delegate: Row {
                  required property var modelData
                  width: bodyColumn.width
                  spacing: Style.spacing.controlGap

                  Text {
                    text: "•"
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    width: parent.width - Style.space(20)
                    text: String(modelData)
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                }
              }

              Text {
                width: parent.width
                visible: !root.listening && !root.recommendation && root.status !== "error"
                text: root.busy
                  ? "Reading your desktop and asking the agent…"
                  : "Ask what you should be seeing right now, or describe what you want to set up."
                color: root.foreground
                opacity: 0.6
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                visible: !!root.recommendation && !!root.recommendation.rationale
                text: root.recommendation ? root.recommendation.rationale : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                wrapMode: Text.WordWrap
              }

              Text {
                width: parent.width
                visible: !!root.recommendation && !!root.recommendation.previewDescription
                text: root.recommendation ? root.recommendation.previewDescription : ""
                color: root.foreground
                opacity: 0.65
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }

              // Layout silhouette: proportional window slots in 0..1 coords,
              // when the agent supplied preview.windows.
              Rectangle {
                width: parent.width
                height: Style.space(140)
                visible: !!root.recommendation && !!root.recommendation.preview
                radius: Style.cornerRadius
                color: "transparent"
                border.width: 1
                border.color: Qt.rgba(root.borderColor.r, root.borderColor.g, root.borderColor.b, 0.4)

                Repeater {
                  model: root.recommendation && root.recommendation.preview
                    ? root.recommendation.preview.windows : []

                  delegate: Rectangle {
                    required property var modelData
                    x: Math.max(0, Math.min(1, Number(modelData.x) || 0)) * parent.width + 2
                    y: Math.max(0, Math.min(1, Number(modelData.y) || 0)) * parent.height + 2
                    width: Math.max(0, Math.min(1, Number(modelData.w) || 0)) * parent.width - 4
                    height: Math.max(0, Math.min(1, Number(modelData.h) || 0)) * parent.height - 4
                    radius: Style.cornerRadius / 2
                    color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.16)
                    border.width: 1
                    border.color: Qt.rgba(root.accent.r, root.accent.g, root.accent.b, 0.6)

                    Text {
                      anchors.centerIn: parent
                      text: String(modelData.label || "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      width: Math.max(0, parent.width - 8)
                      horizontalAlignment: Text.AlignHCenter
                    }
                  }
                }
              }

              // Action plan: allowed rows plain, rejected rows dimmed with a
              // reason — the user sees exactly what apply will and won't run.
              Repeater {
                model: root.recommendation ? root.recommendation.actions : []

                delegate: Row {
                  required property var modelData
                  width: bodyColumn.width
                  spacing: Style.spacing.controlGap

                  Text {
                    text: modelData.__allowed ? "•" : "✕"
                    color: modelData.__allowed ? root.accent : root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    width: parent.width - Style.space(20)
                    text: (modelData.__description || modelData.type || "")
                      + (modelData.__allowed ? "" : "  — " + (modelData.__reason || "rejected"))
                    color: root.foreground
                    opacity: modelData.__allowed ? 1.0 : 0.55
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.strikeout: !modelData.__allowed
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }

          // ------------------------------------------------------- input
          Rectangle {
            width: parent.width
            height: Style.spacing.controlHeight + Style.spacing.inputPaddingY
            radius: Style.cornerRadius
            color: "transparent"
            border.width: 1
            border.color: Qt.rgba(root.borderColor.r, root.borderColor.g, root.borderColor.b, 0.5)

            TextInput {
              id: requestInput
              anchors.fill: parent
              anchors.leftMargin: Style.spacing.controlPaddingX
              anchors.rightMargin: Style.spacing.controlPaddingX
              verticalAlignment: TextInput.AlignVCenter
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              clip: true
              enabled: !root.busy && !root.listening
              onAccepted: root.sendRequest()
            }

            Text {
              anchors.fill: requestInput
              verticalAlignment: Text.AlignVCenter
              visible: requestInput.text.length === 0 && !requestInput.activeFocus
              text: root.listening ? "Learning — suggestions unlock after the listen period" : "What should I be seeing right now?"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
            }
          }

          // ------------------------------------------------------- actions
          Row {
            spacing: Style.spacing.controlGap
            anchors.right: parent.right

            CuratorButton {
              label: "Suggest"
              enabled: !root.busy && !root.listening
              onActivated: root.curatorCall(["suggest", requestInput.text])
            }

            CuratorButton {
              label: "Apply"
              primary: true
              enabled: root.status === "ready"
              onActivated: root.curatorCall(["apply"])
            }

            CuratorButton {
              label: "Undo"
              enabled: root.status === "applied"
              onActivated: root.curatorCall(["undo"])
            }

            CuratorButton {
              label: "Dismiss"
              enabled: !!root.recommendation
              onActivated: root.curatorCall(["dismiss"])
            }
          }
        }
      }
    }
  }
}
