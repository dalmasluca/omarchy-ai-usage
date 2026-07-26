import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Usage.js" as Usage
import "components"

BarWidget {
  id: root
  moduleName: "dalmasluca.ai-usage"

  property var service: null
  property bool popupOpen: false
  property bool buttonHovered: false
  readonly property bool popupHovered: popup.containsMouse

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Util.alpha(foreground, 0.6)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string displayMode: String(setting("display", "icon"))
  readonly property string range: String(setting("defaultRange", "Day"))
  readonly property int rev: service ? service.revision : 0

  // Range-filtered local dataset for bar + popover.
  readonly property var rangeDays: service && service.dataset ? Usage.filterDays(service.dataset.days, range) : []
  readonly property var rangeAgg: Usage.aggregate(rangeDays, "Agent")
  readonly property var donutData: Usage.buildSegments(rangeDays, "Cost", "Agent", 6)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // --- service resolution (first-party service loads at startup) --------
  function resolveService() {
    if (root.service || !root.bar || !root.bar.shell) return
    var sh = root.bar.shell
    var s = sh.serviceFor ? sh.serviceFor("dalmasluca.ai-usage") : null
    if (!s && sh.ensureService) s = sh.ensureService("dalmasluca.ai-usage")
    if (s) root.service = s
  }
  Component.onCompleted: resolveService()
  Timer { interval: 300; repeat: true; running: root.service === null; onTriggered: root.resolveService() }
  Connections { target: root.bar; function onShellChanged() { root.resolveService() } }

  // --- hover open/close with delayed hide (button -> popup safe) --------
  function showPopup() { hideTimer.stop(); root.popupOpen = true }
  function scheduleHide() { hideTimer.restart() }
  onButtonHoveredChanged: buttonHovered ? showPopup() : scheduleHide()
  onPopupHoveredChanged: popupHovered ? hideTimer.stop() : scheduleHide()
  Timer {
    id: hideTimer
    interval: 220
    onTriggered: if (!root.buttonHovered && !root.popupHovered) root.popupOpen = false
  }

  function summonOverlay() {
    root.popupOpen = false
    if (root.bar && root.bar.shell && root.bar.shell.summon) root.bar.shell.summon("dalmasluca.ai-usage", "{}")
  }

  function forceRefresh() {
    if (root.service) root.service.refresh(true)
  }

  function barLabel() {
    if (displayMode === "cost") return Usage.formatCost(rangeAgg.total.cost)
    if (displayMode === "tokens") return Usage.formatTokens(rangeAgg.total.totalTokens)
    // Monochrome Nerd Font glyph, never a text string (ALIGN §Widget).
    return "󰚩"
  }

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: root.vertical ? root.barSize : label.implicitWidth + Style.space(12)
    implicitHeight: root.vertical ? root.barSize : root.barSize

    Text {
      id: label
      anchors.centerIn: parent
      text: root.barLabel()
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: root.displayMode === "icon" ? Style.font.title : Style.font.bodySmall
      font.bold: root.displayMode === "icon"
    }

    HoverHandler {
      target: button
      onHoveredChanged: root.buttonHovered = hovered
    }

    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      cursorShape: Qt.PointingHandCursor
      onClicked: function(mouse) {
        if (mouse.button === Qt.MiddleButton) { root.forceRefresh(); return }
        root.summonOverlay()
      }
    }
  }

  // --- hover popover (OpenUsage-inspired: narrow, vertical) -------------
  PopupCard {
    id: popup
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.popupOpen
    triggerMode: "hover"
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(popColumn.implicitHeight, Style.space(520))

    ColumnLayout {
      id: popColumn
      anchors.fill: parent
      spacing: Style.space(10)

      // Bare header.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)
        Text {
          Layout.fillWidth: true
          text: "AI Usage"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          font.bold: true
        }
        Text {
          text: root.range
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      // Compact Total Spend donut.
      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)
        visible: root.donutData.segments.length > 0

        DonutChart {
          id: popDonut
          size: Style.space(110)
          thickness: 0.32
          segments: root.donutData.segments
          total: root.donutData.total
          metric: "Cost"
        }
        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(2)
          Text { text: "Total Spend"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
          Text { text: Usage.formatCost(root.rangeAgg.total.cost); color: root.foreground; font.family: root.fontFamily; font.pixelSize: Style.font.heading; font.bold: true }
          Text { text: Usage.formatTokens(root.rangeAgg.total.totalTokens) + " tokens"; color: root.dim; font.family: root.fontFamily; font.pixelSize: Style.font.caption }
        }
      }

      // Provider header + single inner block of thin meters.
      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(8)

        Repeater {
          model: root.service ? root.service.providers : []

          ColumnLayout {
            id: provBlock
            required property var modelData
            Layout.fillWidth: true
            spacing: Style.space(6)
            visible: modelData.metrics && modelData.metrics.length > 0

            Text {
              Layout.fillWidth: true
              text: modelData.displayName
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
            Repeater {
              // Grok: pool row only (Weekly credits) in the hover popup; the
              // per-product breakdown of the same window lives behind the
              // analytics card toggle. metrics[0] is the pool by contract
              // (grok_usage.py emits it first, pinned by its self-check).
              model: provBlock.modelData.id === "grok" ? (provBlock.modelData.metrics || []).slice(0, 1) : provBlock.modelData.metrics
              QuotaMeter { Layout.fillWidth: true; metric: modelData; barHeight: Style.space(5); fillColor: Color.chartFor(provBlock.modelData.id) }
            }
          }
        }

        Text {
          visible: !root.service || root.service.providers.length === 0
          Layout.fillWidth: true
          text: "No providers monitored. Open analytics → Settings."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // Mini trend (last 14 days of the range).
      Row {
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(26)
        spacing: Style.space(2)
        visible: root.rangeDays.length > 1

        Repeater {
          model: root.rangeDays.slice(-14)
          Rectangle {
            required property var modelData
            width: Math.max(2, (popup.contentWidth - popup.padding * 2 - Style.space(2) * 13) / 14)
            height: Style.space(26)
            color: "transparent"
            Rectangle {
              anchors.bottom: parent.bottom
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              height: Math.max(Style.space(2), parent.height * root.trendFraction(modelData.cost))
              radius: 1
              color: Util.alpha(root.foreground, 0.55)
            }
          }
        }
      }

      // Minimal footer.
      Text {
        Layout.fillWidth: true
        text: root.service && root.service.stale ? "Refreshing… · click for analytics" : "Click for analytics · middle-click refresh"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignHCenter
      }
    }
  }

  function trendMax() {
    var max = 0
    for (var i = 0; i < rangeDays.length; i++) max = Math.max(max, rangeDays[i].cost)
    return max
  }
  function trendFraction(value) {
    var max = trendMax()
    return max > 0 ? Math.max(0, Math.min(1, value / max)) : 0
  }
}
