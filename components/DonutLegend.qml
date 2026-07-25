import QtQuick
import QtQuick.Layouts
import qs.Commons
import "../Usage.js" as Usage

// Ranked legend paired with DonutChart. Hovering a row highlights the matching
// segment; clicking pins it. Reads the same metric formatting as the donut.
ColumnLayout {
  id: root

  property var segments: []
  property int activeIndex: -1
  property string metric: "Cost"
  property real total: 0

  signal enter(int index)
  signal leave()
  signal toggle(int index)

  spacing: Style.space(6)

  function formatValue(value) {
    return metric === "Tokens" ? Usage.formatTokens(value) : Usage.formatCost(value)
  }

  Repeater {
    model: root.segments

    delegate: Item {
      id: rowItem
      required property var modelData
      required property int index
      Layout.fillWidth: true
      implicitHeight: row.implicitHeight
      readonly property bool active: index === root.activeIndex

      RowLayout {
        id: row
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(8)

        Rectangle {
          Layout.preferredWidth: Style.space(10)
          Layout.preferredHeight: Style.space(10)
          radius: Style.space(2)
          // Same palette as DonutChart.segmentColor so swatches match hues.
          color: {
            var isOther = modelData && modelData.key === "__other__"
            var base = isOther ? Color.muted : Color.chartAt(index)
            return Util.alpha(base, rowItem.active ? 1.0 : 0.85)
          }
        }

        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: modelData.label
          color: rowItem.active ? Color.foreground : Util.alpha(Color.foreground, 0.78)
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: rowItem.active
        }

        Text {
          text: root.formatValue(modelData.value)
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          Layout.preferredWidth: Style.space(40)
          horizontalAlignment: Text.AlignRight
          text: Usage.formatPercent(modelData.percent)
          color: Util.alpha(Color.foreground, 0.55)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }

      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        acceptedButtons: Qt.LeftButton
        onEntered: root.enter(index)
        onExited: root.leave()
        onClicked: root.toggle(index)
      }
    }
  }
}
