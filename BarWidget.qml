import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Curator bar badge: shows the currently inferred or applied mode. Left-click
// toggles the Curator panel, right-click asks for a fresh suggestion without
// opening anything. Renders from the shared state file the service writes.
BarWidget {
  id: root

  property var curatorState: ({ status: "idle", mode: "", recommendation: null })

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/omarchy/curator.json"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool showConfidence: String(setting("showConfidence", "On")) === "On"

  readonly property string status: curatorState ? String(curatorState.status || "idle") : "idle"
  readonly property var recommendation: curatorState ? curatorState.recommendation : null

  function badgeText() {
    if (root.vertical) return "✦"
    if (status === "thinking") return "✦ …"
    if ((status === "ready" || status === "applied") && recommendation && recommendation.mode) {
      var label = "✦ " + recommendation.mode
      if (root.showConfidence && status === "ready")
        label += " · " + Math.round((recommendation.confidence || 0) * 100) + "%"
      return label
    }
    if (status === "error") return "✦ !"
    return "✦"
  }

  implicitWidth: root.vertical ? root.barSize : badge.implicitWidth + Style.space(12)
  implicitHeight: root.vertical ? badge.implicitHeight + Style.space(12) : root.barSize

  FileView {
    path: root.statePath
    watchChanges: true
    printErrors: false
    onLoaded: {
      try { root.curatorState = JSON.parse(text()) } catch (e) {}
    }
    onFileChanged: reload()
  }

  Text {
    id: badge
    anchors.centerIn: parent
    text: root.badgeText()
    color: root.status === "error" ? (bar ? bar.urgent : Color.urgent) : root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.body
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    cursorShape: Qt.PointingHandCursor
    onClicked: function(mouse) {
      if (mouse.button === Qt.RightButton)
        Quickshell.execDetached(["omarchy-shell", "-q", "curator", "suggest", ""])
      else
        Quickshell.execDetached(["omarchy-shell", "-q", "shell", "toggle", "curator.desktop", "{}"])
    }
  }
}
