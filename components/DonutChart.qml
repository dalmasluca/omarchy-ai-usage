import QtQuick
import qs.Commons
import "../Usage.js" as Usage

// Interactive ring chart. Canvas draws the segments with deterministic
// angular hit-testing; hover/pin/keyboard state lives here so the paired
// DonutLegend and the center label stay in sync through `activeIndex`.
Item {
  id: root

  // [{ key, label, value, percent }]
  property var segments: []
  property real total: 0
  property string metric: "Cost"          // "Cost" | "Tokens"
  property int size: Style.space(340)
  property real thickness: 0.30           // ring thickness as fraction of radius
  property color trackColor: Util.alpha(Color.foreground, 0.10)

  property int hoveredIndex: -1
  property int pinnedIndex: -1
  // Optional line under the center total (e.g. the selected period).
  property string centerSubtitle: ""
  readonly property int activeIndex: pinnedIndex >= 0 ? pinnedIndex : hoveredIndex
  readonly property var activeSegment: activeIndex >= 0 && activeIndex < segments.length ? segments[activeIndex] : null

  signal clicked(int index)

  width: size
  height: size

  // Focus-scoped keyboard (ALIGN §Interazione da tastiera): Tab reaches the
  // donut, arrows walk segments, Enter/Space pins. The overlay keyCatcher
  // keeps only Escape so other charts can receive arrows when focused.
  activeFocusOnTab: true
  Keys.onPressed: function(event) {
    if (event.key === Qt.Key_Left || event.key === Qt.Key_Up) { root.moveSelection(-1); event.accepted = true }
    else if (event.key === Qt.Key_Right || event.key === Qt.Key_Down) { root.moveSelection(1); event.accepted = true }
    else if (event.key === Qt.Key_Return || event.key === Qt.Key_Space) { root.togglePin(); event.accepted = true }
  }

  function formatValue(value) {
    return metric === "Tokens" ? Usage.formatTokens(value) : Usage.formatCost(value)
  }

  // One theme chart hue per ranked segment ("Other" stays neutral). Active
  // segment is full strength; the rest dim so the focus reads clearly.
  function segmentColor(index) {
    var isOther = segments[index] && segments[index].key === "__other__"
    var base = isOther ? Color.muted : Color.chartAt(index)
    var alpha = isOther ? 0.35 : 0.88
    if (activeIndex >= 0) alpha = (index === activeIndex) ? 1.0 : alpha * 0.38
    return Util.alpha(base, alpha)
  }

  function moveSelection(delta) {
    if (segments.length === 0) return
    var base = hoveredIndex >= 0 ? hoveredIndex : (pinnedIndex >= 0 ? pinnedIndex : -1)
    var next = base < 0 ? 0 : (base + delta + segments.length) % segments.length
    hoveredIndex = next
  }

  function togglePin() {
    if (segments.length === 0) return
    var target = hoveredIndex >= 0 ? hoveredIndex : pinnedIndex
    if (target < 0) target = 0
    pinnedIndex = (pinnedIndex === target) ? -1 : target
  }

  function resetSelection() {
    hoveredIndex = -1
    pinnedIndex = -1
  }

  // Segment start angles (radians, clockwise from top) for draw + hit-test.
  function segmentAngles() {
    var out = []
    var start = -Math.PI / 2
    for (var i = 0; i < segments.length; i++) {
      var sweep = Math.max(0, Number(segments[i].percent) || 0) * Math.PI * 2
      out.push({ start: start, end: start + sweep })
      start += sweep
    }
    return out
  }

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var cx = width / 2
      var cy = height / 2
      var outerR = Math.min(width, height) / 2 - Style.space(2)
      var innerR = outerR * (1 - root.thickness)
      var angles = root.segmentAngles()
      var gap = root.segments.length > 1 ? 0.02 : 0

      if (root.segments.length === 0 || root.total <= 0) {
        ctx.beginPath()
        ctx.arc(cx, cy, (outerR + innerR) / 2, 0, Math.PI * 2)
        ctx.lineWidth = outerR - innerR
        ctx.strokeStyle = root.trackColor
        ctx.stroke()
        return
      }

      for (var i = 0; i < root.segments.length; i++) {
        var a = angles[i]
        if (a.end - a.start <= 0.0001) continue
        ctx.beginPath()
        ctx.arc(cx, cy, (outerR + innerR) / 2, a.start + gap / 2, a.end - gap / 2)
        ctx.lineWidth = outerR - innerR
        ctx.strokeStyle = root.segmentColor(i)
        ctx.lineCap = "butt"
        ctx.stroke()
      }
    }
  }

  // Focus ring: visible keyboard focus without a decorative border at rest.
  Rectangle {
    anchors.fill: parent
    radius: width / 2
    color: "transparent"
    border.width: root.activeFocus ? 1 : 0
    border.color: Util.alpha(Color.accent, 0.5)
  }

  // Center label: total by default, active segment when hovered/pinned.
  Column {
    anchors.centerIn: parent
    width: parent.width * (1 - root.thickness) - Style.space(12)
    spacing: Style.space(2)

    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      text: root.activeSegment ? root.activeSegment.label : (root.metric === "Tokens" ? "Total Tokens" : "Total Spend")
      color: root.activeSegment ? Color.foreground : Util.alpha(Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.activeSegment ? root.formatValue(root.activeSegment.value) : root.formatValue(root.total)
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.heading
      font.bold: true
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      visible: !!root.activeSegment
      text: root.activeSegment ? Usage.formatPercent(root.activeSegment.percent) : ""
      color: Util.alpha(Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    Text {
      anchors.horizontalCenter: parent.horizontalCenter
      width: parent.width
      horizontalAlignment: Text.AlignHCenter
      elide: Text.ElideRight
      visible: root.centerSubtitle !== "" && !root.activeSegment
      text: root.centerSubtitle
      color: Util.alpha(Color.foreground, 0.5)
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton

    function indexAt(mx, my) {
      var cx = width / 2
      var cy = height / 2
      var dx = mx - cx
      var dy = my - cy
      var dist = Math.sqrt(dx * dx + dy * dy)
      var outerR = Math.min(width, height) / 2 - Style.space(2)
      var innerR = outerR * (1 - root.thickness)
      // Generous inner radius so thin segments stay reachable.
      if (dist > outerR + Style.space(4) || dist < innerR * 0.55) return -1
      var angle = Math.atan2(dy, dx)        // -PI..PI, 0 at +x, clockwise (y down)
      var norm = angle + Math.PI / 2        // shift so top = 0
      while (norm < 0) norm += Math.PI * 2
      while (norm >= Math.PI * 2) norm -= Math.PI * 2
      var frac = norm / (Math.PI * 2)
      var acc = 0
      for (var i = 0; i < root.segments.length; i++) {
        acc += Math.max(0, Number(root.segments[i].percent) || 0)
        if (frac <= acc) return i
      }
      return root.segments.length - 1
    }

    onPositionChanged: function(m) { root.hoveredIndex = indexAt(m.x, m.y) }
    onEntered: root.hoveredIndex = indexAt(mouseX, mouseY)
    onExited: root.hoveredIndex = -1
    onClicked: function(m) {
      var idx = indexAt(m.x, m.y)
      if (idx >= 0) {
        root.hoveredIndex = idx
        root.pinnedIndex = (root.pinnedIndex === idx) ? -1 : idx
        root.clicked(idx)
      }
    }
  }

  Accessible.role: Accessible.Chart
  Accessible.name: "Usage donut"
  Accessible.description: root.activeSegment
    ? root.activeSegment.label + " " + root.formatValue(root.activeSegment.value)
    : "Total " + root.formatValue(root.total)

  onSegmentsChanged: canvas.requestPaint()
  onActiveIndexChanged: canvas.requestPaint()
  onTotalChanged: canvas.requestPaint()
  onSizeChanged: canvas.requestPaint()
}
