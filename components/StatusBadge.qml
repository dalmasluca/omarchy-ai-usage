import QtQuick
import qs.Commons

// Small status chip. `status` is one of the normalized provider states; the
// badge maps it to a label + tone using only theme tokens.
Rectangle {
  id: root

  property string status: "unknown"
  property bool experimental: false
  property bool stale: false

  implicitWidth: label.implicitWidth + Style.space(14)
  implicitHeight: label.implicitHeight + Style.space(6)
  radius: Math.max(2, Style.cornerRadius / 2)
  color: Util.alpha(tone, 0.16)

  readonly property color tone: {
    if (status === "not-installed") return Util.alpha(Color.foreground, 0.6)
    if (status === "not-authenticated") return Color.urgent
    if (status === "error") return Color.urgent
    if (status === "limited" || stale) return Color.urgent
    if (experimental) return Util.alpha(Color.foreground, 0.8)
    return Color.positive
  }

  readonly property string label_: {
    if (status === "not-installed") return "Not installed"
    if (status === "not-authenticated") return "Login required"
    if (status === "error") return "Error"
    if (stale) return "Stale"
    if (status === "limited") return "Limited"
    if (experimental) return "Experimental"
    if (status === "connected") return "Connected"
    return "Unknown"
  }

  Text {
    id: label
    anchors.centerIn: parent
    text: root.label_
    color: root.tone
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
    font.bold: true
  }
}
