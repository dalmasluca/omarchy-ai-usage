import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../Usage.js" as Usage

// Overview provider card: header + official quota meters + local spend/token
// rows. Official quota and local history are kept visually distinct; local
// numbers are never labelled as quota.
BorderSurface {
  id: root

  property var provider: ({})
  // Stable per-provider hue (Color.chartFor(provider.id)) for the meters.
  property color providerColor: Color.accent
  // { totalTokens, cost } from dataset.byAgent[provider.id], optional.
  property var localBucket: null
  property bool showEstimatedCost: true
  // Row inside the Overview panel, not a SaaS card (ALIGN §Overview): the
  // containing PanelBox owns the only border; instances separate via divider.
  property bool showTopSeparator: false

  color: "transparent"
  borderSpec: Border.none()
  radius: Style.cornerRadius
  padding: Style.space(10)
  implicitHeight: body.implicitHeight + contentTopInset + contentBottomInset

  readonly property bool hasQuota: provider.metrics && provider.metrics.length > 0
  // Grok: metrics[0] is the pool row (Weekly credits); the rest are
  // per-product slices of the same window, collapsed behind a toggle.
  readonly property bool hasBreakdown: provider.id === "grok" && hasQuota && provider.metrics.length > 1
  property bool expanded: false

  ColumnLayout {
    id: body
    anchors.left: parent.left
    anchors.right: parent.right
    anchors.top: parent.top
    anchors.topMargin: root.contentTopInset
    anchors.leftMargin: root.contentLeftInset
    anchors.rightMargin: root.contentRightInset
    spacing: Style.space(10)

    PanelSeparator {
      Layout.fillWidth: true
      visible: root.showTopSeparator
      foreground: Color.foreground
      strength: 0.10
    }

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
        status: root.provider.status || "unknown"
        experimental: !!root.provider.experimental
        stale: !!root.provider.stale
      }
    }

    Text {
      visible: String(root.provider.plan || "") !== ""
      Layout.fillWidth: true
      text: root.provider.plan
      color: Util.alpha(Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }

    // Official quota meters.
    Repeater {
      model: root.hasQuota ? (root.hasBreakdown && !root.expanded ? root.provider.metrics.slice(0, 1) : root.provider.metrics) : []
      QuotaMeter { Layout.fillWidth: true; metric: modelData; fillColor: root.providerColor }
    }

    Button {
      visible: root.hasBreakdown
      text: root.expanded ? "Hide breakdown ▴" : "Show breakdown ▾"
      foreground: Util.alpha(Color.accent, 0.9)
      fontFamily: Style.font.family
      fontSize: Style.font.caption
      horizontalPadding: Style.space(8)
      verticalPadding: Style.space(4)
      onClicked: root.expanded = !root.expanded
    }

    // Fallback when no machine-readable quota exists.
    Text {
      visible: !root.hasQuota && String(root.provider.quotaNote || "") !== ""
      Layout.fillWidth: true
      text: root.provider.quotaNote
      color: Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WordWrap
    }

    // Local history rows (estimated, not quota).
    ColumnLayout {
      visible: root.localBucket != null
      Layout.fillWidth: true
      spacing: Style.space(3)

      PanelSeparator { Layout.fillWidth: true; foreground: Color.foreground; strength: 0.12 }

      RowLayout {
        Layout.fillWidth: true
        Text { text: "Tokens (local)"; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        Item { Layout.fillWidth: true }
        Text { text: root.localBucket ? Usage.formatTokens(root.localBucket.totalTokens) : "0"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true }
      }
      RowLayout {
        visible: root.showEstimatedCost
        Layout.fillWidth: true
        Text { text: "Est. cost (local)"; color: Util.alpha(Color.foreground, 0.6); font.family: Style.font.family; font.pixelSize: Style.font.bodySmall }
        Item { Layout.fillWidth: true }
        Text { text: root.localBucket ? Usage.formatCost(root.localBucket.cost) : "$0.00"; color: Color.foreground; font.family: Style.font.family; font.pixelSize: Style.font.bodySmall; font.bold: true }
      }
    }
  }
}
