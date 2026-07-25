import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../Usage.js" as Usage

// Thin meter row: label, bar, "% left" and reset time. `metric` follows the
// normalized contract { label, usedPercent, remainingPercent, resetsAt, source }.
ColumnLayout {
  id: root

  property var metric: ({})
  property int barHeight: Style.space(6)
  // Per-provider hue from the theme chart palette; urgent overrides near
  // exhaustion regardless.
  property color fillColor: Color.accent

  spacing: Style.space(4)

  readonly property real used: Math.max(0, Math.min(1, Number(metric.usedPercent || 0) / 100))
  // Urgent threshold (ALIGN §Quote e barre): at >= 90% consumed the meter and
  // percentage paint urgent. Ordinary mid-range consumption never goes red;
  // urgent is reserved for near-exhaustion (or real errors, handled upstream).
  readonly property bool hot: used >= 0.9

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.space(8)

    Text {
      Layout.fillWidth: true
      elide: Text.ElideRight
      text: root.metric.label || "Usage"
      color: Util.alpha(Color.foreground, 0.7)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      text: Math.round(root.used * 100) + "%"
      color: root.hot ? Color.urgent : Color.foreground
      font.family: Style.font.menuFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
    Text {
      visible: root.metric.resetsAt ? true : false
      text: root.metric.resetsAt ? "reset " + Usage.formatResetTime(root.metric.resetsAt) : ""
      color: Util.alpha(Color.foreground, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  Rectangle {
    Layout.fillWidth: true
    Layout.preferredHeight: root.barHeight
    radius: Math.max(1, Style.cornerRadius / 3)
    color: Util.alpha(Color.foreground, 0.14)

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.used
      radius: parent.radius
      color: root.hot ? Util.alpha(Color.urgent, 0.8) : Util.alpha(root.fillColor, 0.8)
      // Deliberately no width animation: provider rebuilds and layout passes
      // re-evaluate this width constantly (each data source finishing bumps
      // revision and replaces the providers array; the overlay show resolves
      // parent width after creation), so any Behavior replays the 0→used
      // sweep and the bars visibly stutter/repeat when the window opens.
    }
  }
}
