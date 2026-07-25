import QtQuick
import QtQuick.Layouts
import Quickshell.Io
import qs.Commons
import qs.Ui
import "../Usage.js" as Usage

// Settings connection card (DETAILING §Connections).
//
// Closed: a compact, uniform-height header — icon/name, status badge,
// optional secondary "Experimental" chip, monitor toggle on the same row,
// a CLI/auth subtitle and capability chips, plus a "Manage ›" affordance.
// A disabled card reveals nothing until opened. Manage expands the detail
// section in place (CLI/auth/plan, capabilities, login command + copy,
// refresh detection, docs). Expansion grows the card, never overlaps.
BorderSurface {
  id: root

  property var provider: ({})
  property bool monitored: false
  property double lastCheckedAtMs: 0
  property bool expanded: false

  signal toggle(bool enabled)
  signal refreshDetection()

  color: Util.alpha(Color.foreground, 0.04)
  borderSpec: Border.flat(Util.alpha(Color.foreground, 0.08), 1)
  radius: Style.cornerRadius
  padding: Style.space(14)
  // Uniform closed height so the two-column grid stays aligned.
  implicitHeight: body.implicitHeight + contentTopInset + contentBottomInset

  readonly property var caps: provider.capabilities || ({})
  readonly property bool needsLogin: provider.installed && !provider.authenticated

  ColumnLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: root.contentTopInset
    anchors.leftMargin: root.contentLeftInset
    anchors.rightMargin: root.contentRightInset
    spacing: Style.space(8)

    // --- header row: name + status + experimental + toggle ---
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)

      Text {
        Layout.fillWidth: true
        elide: Text.ElideRight
        text: root.provider.displayName || root.provider.id || "Provider"
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: Style.font.title
        font.bold: true
      }
      StatusBadge {
        // Real status only; experimental is a separate secondary chip.
        status: root.provider.status || "unknown"
        experimental: false
        stale: !!root.provider.stale
      }
      Rectangle {
        visible: !!root.provider.experimental
        implicitWidth: expLbl.implicitWidth + Style.space(10)
        implicitHeight: expLbl.implicitHeight + Style.space(4)
        radius: Math.max(2, Style.cornerRadius / 2)
        color: Util.alpha(Color.foreground, 0.10)
        Text {
          id: expLbl
          anchors.centerIn: parent
          text: "Experimental"
          color: Util.alpha(Color.foreground, 0.7)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }

    // --- subtitle: CLI · account ---
    Text {
      Layout.fillWidth: true
      elide: Text.ElideRight
      text: {
        var p = root.provider
        if (!p.installed) return "CLI not installed"
        var v = String(p.version || "")
        var left = p.id + (v ? " " + v : "")
        var right = p.authenticated ? (p.plan ? "account · " + p.plan : "account detected") : "not logged in"
        return left + " · " + right
      }
      color: Util.alpha(Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // --- capability chips + monitor toggle + manage ---
    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(6)

      Repeater {
        model: {
          var c = root.caps
          var out = []
          if (c.localUsage) out.push("Local usage")
          if (c.officialQuota) out.push("Official limits")
          if (out.length === 0) out.push("No official quota")
          return out
        }
        Rectangle {
          required property string modelData
          implicitWidth: capLbl.implicitWidth + Style.space(10)
          implicitHeight: capLbl.implicitHeight + Style.space(4)
          radius: Math.max(2, Style.cornerRadius / 2)
          color: Util.alpha(Color.foreground, 0.08)
          Text {
            id: capLbl
            anchors.centerIn: parent
            text: modelData
            color: Util.alpha(Color.foreground, 0.75)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }
      }

      Item { Layout.fillWidth: true }

      Toggle {
        label: ""
        checked: root.monitored
        foreground: Color.foreground
        accent: Color.accent
        fontFamily: Style.font.family
        onClicked: root.toggle(!root.monitored)
      }
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      Text {
        visible: root.monitored
        text: "Checked " + Usage.timeAgo(root.lastCheckedAtMs)
        color: Util.alpha(Color.foreground, 0.45)
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }
      Item { Layout.fillWidth: true }
      Button {
        text: root.expanded ? "Close ▴" : "Manage ›"
        foreground: Util.alpha(Color.accent, 0.9)
        fontFamily: Style.font.family
        fontSize: Style.font.caption
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: root.expanded = !root.expanded
      }
    }

    // --- expanded detail (only when opened) ---
    ColumnLayout {
      visible: root.expanded
      Layout.fillWidth: true
      spacing: Style.space(10)

      PanelSeparator { Layout.fillWidth: true; foreground: Color.foreground; strength: 0.12 }

      GridLayout {
        Layout.fillWidth: true
        columns: 2
        columnSpacing: Style.space(12)
        rowSpacing: Style.space(4)

        Text { text: "CLI"; color: Util.alpha(Color.foreground, 0.55); font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text {
          Layout.fillWidth: true; elide: Text.ElideRight
          text: root.provider.installed ? (root.provider.id + (root.provider.version ? " · " + root.provider.version : "")) : "not installed"
          color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption
        }
        Text { text: "Auth"; color: Util.alpha(Color.foreground, 0.55); font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text {
          Layout.fillWidth: true; elide: Text.ElideRight
          text: root.provider.authKind || (root.provider.installed ? "unknown" : "—")
          color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption
        }
        Text { text: "Capabilities"; color: Util.alpha(Color.foreground, 0.55); font.family: Style.font.family; font.pixelSize: Style.font.caption }
        Text {
          Layout.fillWidth: true; elide: Text.ElideRight
          text: {
            var c = root.caps; var out = []
            if (c.localUsage) out.push("local usage")
            if (c.officialQuota) out.push("official quota")
            if (c.resetTimes) out.push("reset times")
            return out.length ? out.join(", ") : "none"
          }
          color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.caption
        }
      }

      // Login command — only when a login is actually needed.
      Rectangle {
        id: loginBox
        visible: root.needsLogin && String(root.provider.loginCommand || "") !== ""
        Layout.fillWidth: true
        implicitHeight: loginLabel.implicitHeight + Style.space(8)
        radius: Math.max(2, Style.cornerRadius / 3)
        color: Util.alpha(Color.foreground, loginBox.justCopied ? 0.14 : 0.06)
        property bool justCopied: false

        Text {
          id: loginLabel
          anchors.left: parent.left
          anchors.right: copyBtn.left
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(6)
          text: (loginBox.justCopied ? "Copied! " : "$ ") + (root.provider.loginCommand || "")
          color: Color.foreground
          font.family: Style.font.menuFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }
        Button {
          id: copyBtn
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.rightMargin: Style.space(4)
          text: "Copy"
          foreground: Color.foreground
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(3)
          onClicked: {
            copyProc.command = ["wl-copy", String(root.provider.loginCommand || "")]
            copyProc.running = true
            loginBox.justCopied = true
            copiedTimer.restart()
          }
        }
        Timer { id: copiedTimer; interval: 1500; onTriggered: loginBox.justCopied = false }
        Process { id: copyProc; running: false }
      }

      Text {
        Layout.fillWidth: true
        visible: String(root.provider.quotaNote || "") !== ""
        text: root.provider.quotaNote
        color: Util.alpha(Color.foreground, 0.55)
        font.family: Style.font.family
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)
        Button {
          text: "Refresh detection"
          foreground: Color.foreground
          fontFamily: Style.font.family
          fontSize: Style.font.caption
          horizontalPadding: Style.space(10)
          verticalPadding: Style.space(4)
          onClicked: root.refreshDetection()
        }
        Item { Layout.fillWidth: true }
        Text {
          visible: String(root.provider.docsUrl || "") !== ""
          text: "Docs ↗"
          color: Util.alpha(Color.accent, 0.85)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          font.underline: true
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: if (root.provider.docsUrl) Qt.openUrlExternally(root.provider.docsUrl)
          }
        }
      }
    }
  }
}
