import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Usage.js" as Usage
import "components"

// Analytics overlay for omarchy.ai-usage (see DETAILING.md).
//
// Shell: global header → horizontal nav + range selector → page content.
// No permanent side rail: the full width belongs to the data. Pages:
// Overview · Models · Agents · Activity · Records · Settings.
//
// Data contract: Models always aggregates by model, Agents always by agent;
// the donut's Agents/Models selector only regroups the donut, never the pages.
Item {
  id: root

  property var shell: null
  property var service: null
  property var manifest: null
  property bool opened: false

  readonly property string pluginId: manifest && manifest.id ? manifest.id : "omarchy.ai-usage"
  readonly property int rev: service ? service.revision : 0

  // --- visualization state (persisted) ----------------------------------
  property string metric: "Cost"        // Cost | Tokens
  property string groupBy: "Provider"   // Provider(=Agents) | Model  — donut only
  property string range: "Month"        // Day | Week | Month | Year | All
  property bool showEstimatedCost: true
  property bool showLocalHistory: true

  property int currentPage: 0
  readonly property var pages: ["Overview", "Models", "Agents", "Activity", "Records", "Settings"]

  // --- typography tokens (DETAILING §Tipografia) ------------------------
  readonly property int pxWindowTitle: Style.font.display                 // ~24
  readonly property int pxPageTitle: Math.round(Style.font.display * 0.83) // ~20
  readonly property int pxKpi: Style.font.displayLarge                    // ~28
  readonly property int pxBody: Style.font.title                          // ~14
  readonly property int pxLabel: Style.font.subtitle                      // ~13
  readonly property int pxCaption: Style.font.bodySmall                   // ~11
  readonly property string monoFamily: Style.font.menuFamily

  // --- derived data -----------------------------------------------------
  readonly property var dataset: service ? service.dataset : null
  readonly property var rangeDays: dataset ? Usage.filterDays(dataset.days, range) : []
  // Independent aggregations: the two rank pages never share a source.
  readonly property var modelAgg: Usage.aggregate(rangeDays, "Model")
  readonly property var agentAgg: Usage.aggregate(rangeDays, "Agent")
  // Donut grouping follows `groupBy` only.
  readonly property var donutData: Usage.buildSegments(rangeDays, metric, groupBy === "Model" ? "Model" : "Agent", 6)
  readonly property var records: Usage.flattenRecords(rangeDays)

  // The shell injects `service`, but that can race the async overlay load at
  // startup; resolve it lazily as a fallback (same pattern as the BarWidget).
  function resolveService() {
    if (root.service || !root.shell) return
    var s = root.shell.serviceFor ? root.shell.serviceFor(root.pluginId) : null
    if (!s && root.shell.ensureService) s = root.shell.ensureService(root.pluginId)
    if (s) root.service = s
  }
  Timer { interval: 300; repeat: true; running: root.opened && root.service === null; onTriggered: root.resolveService() }

  function open(payload) {
    resolveService()
    syncFromSettings()
    root.opened = true
    root.currentPage = 0
    // Rank pages default to Tokens on every open (user preference); the
    // donut/trend keep the global persisted metric.
    modelsPage.rankMetric = "Tokens"
    agentsPage.rankMetric = "Tokens"
    if (root.service) root.service.refresh(false)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Only flip `opened`. shell.hide() invokes this same close(), so calling it
  // back would recurse; the shell clears openPanelIds on its side.
  function close() {
    root.opened = false
  }

  function syncFromSettings() {
    if (!root.service) return
    root.metric = String(root.service.setting("donutMetric", "Cost"))
    root.groupBy = String(root.service.setting("donutGroupBy", "Provider"))
    root.range = String(root.service.setting("defaultRange", "Month"))
    root.showEstimatedCost = root.service.setting("showEstimatedCost", true) !== false
    root.showLocalHistory = root.service.setting("showLocalHistory", true) !== false
  }

  // Persist the full settings object (updateEntryInline replaces the entry).
  function persistSettings(reprobe) {
    if (!root.shell || !root.service || typeof root.shell.updateEntryInline !== "function") return
    var entry = root.service.settingsEntry()
    var next = {}
    for (var k in entry) if (k !== "id") next[k] = entry[k]
    next.donutMetric = root.metric
    next.donutGroupBy = root.groupBy
    next.defaultRange = root.range
    next.showEstimatedCost = root.showEstimatedCost
    next.showLocalHistory = root.showLocalHistory
    next.codexEnabled = root.providerToggle("codex")
    next.kimiEnabled = root.providerToggle("kimi")
    next.grokEnabled = root.providerToggle("grok")
    next.refreshMinutes = root.refreshMinutesValue()
    root.shell.updateEntryInline(root.pluginId, next)
    if (reprobe) root.service.refresh(true)
  }

  // Local mirror of provider toggles so cards are responsive before persist.
  property var toggleState: ({})
  function providerToggle(id) {
    if (root.toggleState[id] !== undefined) return root.toggleState[id]
    return root.service ? root.service.providerEnabled(id) : (id === "codex")
  }
  function setProviderToggle(id, value) {
    var next = root.toggleState
    next[id] = value
    root.toggleState = next
    root.persistSettings(true)
  }
  function refreshMinutesValue() {
    return root.service ? root.service.refreshMinutes : 10
  }

  function formatValue(value) {
    return metric === "Tokens" ? Usage.formatTokens(value) : Usage.formatCost(value)
  }

  function rangeLabel(r) {
    if (r === "Day") return "today"
    if (r === "Week") return "last 7 days"
    if (r === "Month") return "last 30 days"
    if (r === "Year") return "last 12 months"
    return "all time"
  }

  // Row-cursor contract shared by RankPage and RecordsPage (ALIGN §Modelli e
  // Agenti / Records): pages expose cursorIndex + cursorCount; mouse hover and
  // keyboard drive the same index so exactly one highlight is on screen.
  readonly property bool inputFocus: recordsPage.filterField.activeFocus
  function moveCursor(dir) {
    var p = stack.currentItem
    if (!p || !("cursorIndex" in p) || !("cursorCount" in p) || p.cursorCount === 0) return false
    var i = p.cursorIndex
    p.cursorIndex = i < 0 ? (dir > 0 ? 0 : p.cursorCount - 1) : Math.max(0, Math.min(p.cursorCount - 1, i + dir))
    return true
  }

  // --- window -----------------------------------------------------------
  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-ai-usage"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle { anchors.fill: parent; color: Util.alpha(Color.background, 0.55) }

    MouseArea { anchors.fill: parent; onClicked: root.close() }

    BorderSurface {
      id: card
      // Really landscape: prefer 1680×900, cap at 94%/90% of the screen.
      width: Math.min(Style.space(1680), Math.round(panel.width * 0.94))
      height: Math.min(Style.space(900), Math.round(panel.height * 0.90))
      anchors.centerIn: parent
      color: Color.popups.background
      borderSpec: Border.flat(Color.popups.border, Math.max(1, Math.round(Style.space(2))))
      radius: Style.cornerRadius

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true
        Keys.priority: Keys.BeforeItem

        // Global keys (ALIGN §Interazione da tastiera). Escape steps out one
        // level at a time: donut selection → records filter → row cursor →
        // close. j/k/Up/Down drive the current page's row cursor; r refreshes.
        // The donut and trend chart own focus-scoped arrow keys instead.
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.currentPage === 0 && overviewPage.donut.activeIndex >= 0) overviewPage.donut.resetSelection()
            else if (root.currentPage === 4 && recordsPage.filter !== "") { recordsPage.filter = ""; recordsPage.filterField.text = "" }
            else {
              var p = stack.currentItem
              if (p && "cursorIndex" in p && p.cursorIndex >= 0) p.cursorIndex = -1
              else root.close()
            }
            event.accepted = true
          } else if (!root.inputFocus && (event.key === Qt.Key_Down || event.key === Qt.Key_J)) {
            if (root.moveCursor(1)) event.accepted = true
          } else if (!root.inputFocus && (event.key === Qt.Key_Up || event.key === Qt.Key_K)) {
            if (root.moveCursor(-1)) event.accepted = true
          } else if (!root.inputFocus && event.key === Qt.Key_R) {
            if (root.service) root.service.refresh(true)
            event.accepted = true
          }
        }

        ColumnLayout {
          anchors.fill: parent
          anchors.margins: Style.space(24)
          spacing: Style.space(20)

          // --- global header -------------------------------------------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(16)

            ColumnLayout {
              spacing: Style.space(2)
              Text {
                text: "AI Usage"
                color: Color.foreground
                font.family: Style.font.family
                font.pixelSize: root.pxWindowTitle
                font.bold: true
              }
              Text {
                text: "Local usage and official quotas"
                color: Util.alpha(Color.foreground, 0.55)
                font.family: Style.font.family
                font.pixelSize: root.pxLabel
              }
            }

            Item { Layout.fillWidth: true }

            Text {
              text: root.service
                ? (root.service.stale ? "updating…" : "updated " + Usage.timeAgo(root.service.lastRefreshedAtMs))
                : "service unavailable"
              color: root.service && root.service.stale ? Color.urgent : Util.alpha(Color.foreground, 0.55)
              font.family: Style.font.family
              font.pixelSize: root.pxCaption
            }
            Button {
              text: "Refresh"
              iconText: "↻"
              iconSpinning: root.service ? root.service.loading : false
              foreground: Color.foreground
              fontFamily: Style.font.family
              fontSize: root.pxLabel
              horizontalPadding: Style.space(12)
              verticalPadding: Style.space(6)
              onClicked: if (root.service) root.service.refresh(true)
            }
            Button {
              text: "✕"
              tooltipText: "Close (Esc)"
              foreground: Util.alpha(Color.foreground, 0.7)
              fontFamily: Style.font.family
              fontSize: root.pxBody
              horizontalPadding: Style.space(10)
              verticalPadding: Style.space(6)
              onClicked: root.close()
            }
          }

          // --- nav bar: tabs left, range right -------------------------
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(16)

            RowLayout {
              spacing: Style.space(4)
              Repeater {
                model: root.pages
                delegate: NavTab {
                  label: modelData
                  active: index === root.currentPage
                  onPick: { root.currentPage = index; keyCatcher.forceActiveFocus() }
                }
              }
            }

            Item { Layout.fillWidth: true }

            RowLayout {
              id: rangeRow
              Layout.preferredWidth: Style.space(340)
              spacing: Style.space(4)
              Repeater {
                model: ["Day", "Week", "Month", "Year", "All"]
                delegate: NavChip {
                  label: modelData
                  active: root.range === modelData
                  onPick: root.range = modelData
                  cellWidth: (rangeRow.width - rangeRow.spacing * 4) / 5
                }
              }
            }
          }

          PanelSeparator { Layout.fillWidth: true; foreground: Color.foreground; strength: 0.12 }

          // --- pages ----------------------------------------------------
          StackLayout {
            id: stack
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumWidth: Style.space(400)
            currentIndex: root.currentPage

            OverviewPage { id: overviewPage }
            ModelsPage { id: modelsPage }
            AgentsPage { id: agentsPage }
            ActivityPage {}
            RecordsPage { id: recordsPage }
            SettingsPage {}
          }
        }
      }
    }
  }

  // --- shared inline building blocks ------------------------------------

  component NavTab: BorderSurface {
    id: tab
    property string label: ""
    property bool active: false
    signal pick()
    implicitWidth: tabLbl.implicitWidth + Style.space(20)
    implicitHeight: tabLbl.implicitHeight + Style.space(14)
    radius: Style.cornerRadius
    // Omarchy state tokens, not a browser underline (ALIGN §Navigazione):
    // selected fill when active, hover-cursor fill on hover or keyboard
    // focus, shared focus ring on real focus. One visual state for mouse
    // and keyboard.
    color: tab.active ? Style.selectedFillFor(Color.foreground, Color.accent)
      : (tabHover.hovered || tab.activeFocus) ? Style.hoverFillFor(Color.foreground, Color.accent)
      : "transparent"
    borderSpec: tab.activeFocus ? Border.controlSpec("focus", Color.foreground, Color.accent) : Border.none()
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: label

    Text {
      id: tabLbl
      anchors.centerIn: parent
      text: tab.label
      color: tab.active ? Color.foreground : Util.alpha(Color.foreground, 0.55)
      font.family: Style.font.family
      font.pixelSize: root.pxBody
      font.bold: tab.active
    }
    HoverHandler { id: tabHover; cursorShape: Qt.PointingHandCursor }
    MouseArea { anchors.fill: parent; onClicked: { tab.forceActiveFocus(); tab.pick() } }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Space) { tab.pick(); event.accepted = true }
    }
  }

  component NavChip: BorderSurface {
    id: chip
    property string label: ""
    property bool active: false
    // > 0 forces uniform cells — the time selector uses it (ALIGN §Navigazione).
    property real cellWidth: -1
    signal pick()
    implicitWidth: cellWidth > 0 ? cellWidth : chipLbl.implicitWidth + Style.space(14)
    implicitHeight: Math.max(Style.space(30), chipLbl.implicitHeight + Style.space(8))
    radius: Math.max(2, Style.cornerRadius / 2)
    color: chip.active ? Style.selectedFillFor(Color.foreground, Color.accent)
      : (chipHover.hovered || chip.activeFocus) ? Style.hoverFillFor(Color.foreground, Color.accent)
      : "transparent"
    borderSpec: chip.activeFocus ? Border.controlSpec("focus", Color.foreground, Color.accent) : Border.none()
    activeFocusOnTab: true
    Accessible.role: Accessible.Button
    Accessible.name: label

    Text {
      id: chipLbl
      anchors.centerIn: parent
      text: chip.label
      color: chip.active ? Color.foreground : Util.alpha(Color.foreground, 0.6)
      font.family: Style.font.family
      font.pixelSize: root.pxCaption
      font.bold: chip.active
    }
    HoverHandler { id: chipHover; cursorShape: Qt.PointingHandCursor }
    MouseArea { anchors.fill: parent; onClicked: { chip.forceActiveFocus(); chip.pick() } }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Space) { chip.pick(); event.accepted = true }
    }
  }

  // Page header: title + description on the left, optional controls right.
  // Not wrapped in a card; separates window chrome from content.
  component PageHeader: RowLayout {
    property string title: ""
    property string subtitle: ""
    default property alias controls: ctrlBox.data
    Layout.fillWidth: true
    Layout.bottomMargin: Style.space(16)
    spacing: Style.space(16)

    ColumnLayout {
      spacing: Style.space(3)
      Text {
        text: parent.parent.title
        color: Color.foreground
        font.family: Style.font.family
        font.pixelSize: root.pxPageTitle
        font.bold: true
      }
      Text {
        visible: parent.parent.subtitle !== ""
        text: parent.parent.subtitle
        color: Util.alpha(Color.foreground, 0.55)
        font.family: Style.font.family
        font.pixelSize: root.pxLabel
      }
    }
    Item { Layout.fillWidth: true }
    RowLayout { id: ctrlBox; spacing: Style.space(8) }
  }

  // One surface group with a titled header and padded body column.
  component PanelBox: BorderSurface {
    id: pbox
    property string title: ""
    default property alias body: pbody.data
    color: Util.alpha(Color.foreground, 0.03)
    borderSpec: Border.flat(Util.alpha(Color.foreground, 0.08), 1)
    radius: Style.cornerRadius
    padding: Style.space(18)
    implicitHeight: pcol.implicitHeight + contentTopInset + contentBottomInset

    ColumnLayout {
      id: pcol
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: pbox.contentTopInset
      anchors.leftMargin: pbox.contentLeftInset
      anchors.rightMargin: pbox.contentRightInset
      spacing: Style.space(14)

      Text {
        visible: pbox.title !== ""
        Layout.fillWidth: true
        text: pbox.title
        // PanelSectionHeader visual style (ALIGN §PageHeader): caption,
        // bold, dimmed — internal sections never shout like page titles.
        color: Qt.darker(Color.foreground, 1.4)
        font.family: Style.font.family
        font.pixelSize: root.pxCaption
        font.bold: true
      }
      ColumnLayout { id: pbody; Layout.fillWidth: true; spacing: Style.space(12) }
    }
  }

  // KPI: small label over a large value. Lives inside a panel, not a card.
  component KpiStat: ColumnLayout {
    property string label: ""
    property string value: ""
    spacing: Style.space(2)
    Text {
      text: parent.label
      color: Util.alpha(Color.foreground, 0.5)
      font.family: Style.font.family
      font.pixelSize: root.pxCaption
    }
    Text {
      text: parent.value
      color: Color.foreground
      font.family: root.monoFamily
      font.pixelSize: root.pxKpi
      font.bold: true
    }
  }

  // Ranked row with the Omarchy list contract (ALIGN §Models e Agents):
  // full-width CursorSurface, one shared cursor (mouse hover and keyboard
  // both update the page's cursorIndex), tabular numbers, elided label.
  component RankRow: CursorSurface {
    id: rr
    property int rank: 0
    property string label: ""
    property real value: 0
    property real maxValue: 1
    property real tokens: 0
    property real cost: 0
    property real sessions: 0
    property bool isCurrent: false
    signal hoverCursor()
    current: isCurrent
    implicitHeight: col.implicitHeight + Style.space(12)

    HoverHandler { onHoveredChanged: if (hovered) rr.hoverCursor() }

    ColumnLayout {
      id: col
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.topMargin: Style.space(6)
      anchors.bottomMargin: Style.space(6)
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(5)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(10)
        Text {
          Layout.preferredWidth: Style.space(24)
          horizontalAlignment: Text.AlignRight
          text: rr.rank
          color: Util.alpha(Color.foreground, 0.4)
          font.family: root.monoFamily
          font.pixelSize: root.pxLabel
        }
        Text {
          Layout.fillWidth: true
          elide: Text.ElideRight
          text: rr.label
          color: Color.foreground
          font.family: Style.font.family
          font.pixelSize: root.pxBody
          font.bold: true
          ToolTip.text: rr.label
          ToolTip.visible: ma.containsMouse && truncated
          ToolTip.delay: 400
          readonly property bool truncated: contentWidth > width
          MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
        }
        Text {
          visible: root.showLocalHistory
          text: Usage.formatTokens(rr.tokens)
          color: Util.alpha(Color.foreground, 0.6)
          font.family: root.monoFamily
          font.pixelSize: root.pxLabel
        }
        Text {
          visible: root.showEstimatedCost
          Layout.preferredWidth: Style.space(78)
          horizontalAlignment: Text.AlignRight
          text: Usage.formatCost(rr.cost)
          color: Color.foreground
          font.family: root.monoFamily
          font.pixelSize: root.pxLabel
          font.bold: true
        }
      }
      Rectangle {
        Layout.fillWidth: true
        Layout.leftMargin: Style.space(34)
        Layout.preferredHeight: Style.space(7)
        radius: Math.max(1, Style.cornerRadius / 3)
        color: Util.alpha(Color.foreground, 0.10)
        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * (rr.maxValue > 0 ? Math.min(1, rr.value / rr.maxValue) : 0)
          radius: parent.radius
          // Ranked palette hue: rankings share the donut's value ordering, so
          // the same model/agent keeps its hue across both views.
          color: Util.alpha(Color.chartAt(Math.max(0, rr.rank - 1)), 0.8)
          // No width animation: rows re-instantiate on every dataset/revision
          // change and layout resolves parent width after creation, so any
          // Behavior replays the 0→value sweep (stutter when the window opens).
        }
      }
    }
  }

  // ---------------------------------------------------------------- pages

  component OverviewPage: Flickable {
    Layout.fillWidth: true
    Layout.fillHeight: true
    contentWidth: width
    contentHeight: overviewCol.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    // 12-col grid above ~1100px, single column below.
    readonly property int cols: width >= Style.space(1100) ? 12 : 1
    property alias donut: overviewDonut

    ColumnLayout {
      id: overviewCol
      width: parent.width
      spacing: Style.space(20)

      PageHeader {
        title: "Overview"
        subtitle: "Distribution, provider quotas and trend for " + root.rangeLabel(root.range)
      }

      // Top band: distribution (5) | provider quotas (7).
      GridLayout {
        Layout.fillWidth: true
        columns: overviewPage.cols
        columnSpacing: Style.space(20)
        rowSpacing: Style.space(20)

        // --- distribution panel ---
        PanelBox {
          id: distPanel
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.columnSpan: overviewPage.cols === 1 ? 1 : 5
          title: "Usage distribution"

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Text { text: "Group"; color: Util.alpha(Color.foreground, 0.5); font.family: Style.font.family; font.pixelSize: root.pxCaption }
            NavChip { label: "Agents"; active: root.groupBy === "Provider"; onPick: root.groupBy = "Provider" }
            NavChip { label: "Models"; active: root.groupBy === "Model"; onPick: root.groupBy = "Model" }
            Item { Layout.fillWidth: true }
          }

          // Donut + legend side by side (never stacked on wide layouts).
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(20)

            DonutChart {
              id: overviewDonut
              size: Style.space(320)
              segments: root.donutData.segments
              total: root.donutData.total
              metric: root.metric
              centerSubtitle: root.rangeLabel(root.range)
            }
            DonutLegend {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              segments: root.donutData.segments
              total: root.donutData.total
              metric: root.metric
              activeIndex: overviewDonut.activeIndex
              onEnter: function(i) { overviewDonut.hoveredIndex = i }
              onLeave: overviewDonut.hoveredIndex = -1
              onToggle: function(i) { overviewDonut.pinnedIndex = (overviewDonut.pinnedIndex === i) ? -1 : i }
            }
          }

          Text {
            visible: root.donutData.segments.length === 0
            Layout.fillWidth: true
            text: root.dataset && root.dataset.available ? "No usage in this range" : "No local usage data (ccusage)"
            color: Util.alpha(Color.foreground, 0.5)
            font.family: Style.font.family
            font.pixelSize: root.pxLabel
            horizontalAlignment: Text.AlignHCenter
          }

          // Synthetic indicators — one panel, three values, not three cards.
          PanelSeparator { Layout.fillWidth: true; foreground: Color.foreground; strength: 0.10 }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(24)
            KpiStat { label: "TOTAL TOKENS"; value: Usage.formatTokens(root.agentAgg.total.totalTokens || 0) }
            KpiStat { visible: root.showEstimatedCost; label: "EST. COST"; value: Usage.formatCost(root.agentAgg.total.cost || 0) }
            KpiStat { label: "RECORDS"; value: String(root.records.length) }
          }
        }

        // --- provider quotas panel ---
        PanelBox {
          Layout.fillWidth: true
          Layout.fillHeight: true
          Layout.columnSpan: overviewPage.cols === 1 ? 1 : 7
          title: "Quotas & provider status"

          ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(10)
            Repeater {
              model: root.service ? root.service.providers : []
              ProviderCard {
                Layout.fillWidth: true
                provider: modelData
                providerColor: Color.chartFor(modelData.id)
                showEstimatedCost: root.showEstimatedCost
                localBucket: root.agentAgg.groups[modelData.id] || null
                showTopSeparator: index > 0
              }
            }
            Text {
              visible: !root.service || root.service.providers.length === 0
              Layout.fillWidth: true
              text: "No providers monitored. Enable them in Settings."
              color: Util.alpha(Color.foreground, 0.5)
              font.family: Style.font.family
              font.pixelSize: root.pxLabel
            }
            // One contextual note, not repeated per card.
            Text {
              visible: root.service && root.service.providers.length > 0
              Layout.fillWidth: true
              text: "Official quotas where a machine-readable API exists; local numbers are ccusage estimates."
              color: Util.alpha(Color.foreground, 0.4)
              font.family: Style.font.family
              font.pixelSize: root.pxCaption
              wrapMode: Text.WordWrap
            }
          }
        }
      }

      // --- trend chart (full 12 columns) ---
      TrendChart {
        Layout.fillWidth: true
        visible: root.showLocalHistory
        days: root.rangeDays
        metric: root.metric
      }
    }
  }

  // Daily trend: bars + light grid + axis labels + hover tooltip.
  component TrendChart: PanelBox {
    id: trend
    property var days: []
    property string metric: "Cost"
    // Keyboard cursor (ALIGN §Interazione): -1 = follow hover only.
    property int cursor: -1
    title: metric === "Tokens" ? "Trend · tokens" : "Trend · spend"
    onCursorChanged: {
      if (cursor >= 0 && cursor < days.length) {
        var slot = (chartArea.width - Style.space(44)) / Math.max(1, days.length)
        showTip(days[cursor], cursor * slot)
      } else hideTip()
    }
    onDaysChanged: cursor = -1

    readonly property real chartMax: {
      var m = 0
      for (var i = 0; i < days.length; i++) m = Math.max(m, metric === "Tokens" ? days[i].totalTokens : days[i].cost)
      return m
    }

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.space(8)
      Text { text: "Metric"; color: Util.alpha(Color.foreground, 0.5); font.family: Style.font.family; font.pixelSize: root.pxCaption }
      NavChip { label: "Tokens"; active: root.metric === "Tokens"; onPick: root.metric = "Tokens" }
      NavChip { label: "Cost"; active: root.metric === "Cost"; onPick: root.metric = "Cost" }
      Item { Layout.fillWidth: true }
    }

    Item {
      id: chartArea
      Layout.fillWidth: true
      Layout.preferredHeight: Style.space(210)
      // Focus-scoped keyboard: Tab reaches the chart, Left/Right walk days
      // and show the same tooltip hover produces.
      activeFocusOnTab: true
      Accessible.name: "Trend chart"
      Keys.onPressed: function(event) {
        if (trend.days.length === 0) return
        if (event.key === Qt.Key_Left) { trend.cursor = trend.cursor <= 0 ? trend.days.length - 1 : trend.cursor - 1; event.accepted = true }
        else if (event.key === Qt.Key_Right) { trend.cursor = (trend.cursor < 0 || trend.cursor >= trend.days.length - 1) ? 0 : trend.cursor + 1; event.accepted = true }
      }
      onActiveFocusChanged: if (!activeFocus) trend.cursor = -1

      Text {
        anchors.centerIn: parent
        visible: trend.days.length === 0
        text: "No data in this range"
        color: Util.alpha(Color.foreground, 0.5)
        font.family: Style.font.family
        font.pixelSize: root.pxLabel
      }

      // Light horizontal grid + left value labels (discrete scale).
      Repeater {
        model: 4
        Item {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Style.space(44)
          y: (chartArea.height - Style.space(20)) * (index / 3)
          height: 1
          Rectangle { anchors.fill: parent; color: Util.alpha(Color.foreground, 0.07) }
          Text {
            anchors.right: parent.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: trend.chartMax > 0 ? (trend.metric === "Tokens" ? Usage.formatTokens(trend.chartMax * (1 - index / 3)) : Usage.formatCost(trend.chartMax * (1 - index / 3))) : ""
            color: Util.alpha(Color.foreground, 0.4)
            font.family: root.monoFamily
            font.pixelSize: root.pxCaption
          }
        }
      }

      Row {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(44)
        anchors.bottomMargin: Style.space(20)
        spacing: trend.days.length > 40 ? 0 : Style.space(3)
        visible: trend.days.length > 0

        Repeater {
          model: trend.days
          Item {
            width: Math.max(2, (chartArea.width - Style.space(44)) / Math.max(1, trend.days.length) - (trend.days.length > 40 ? 0 : Style.space(3)))
            height: parent.height
            Rectangle {
              anchors.bottom: parent.bottom
              anchors.horizontalCenter: parent.horizontalCenter
              width: Math.max(2, parent.width)
              height: Math.max(Style.space(2), parent.height * (trend.chartMax > 0 ? (trend.metric === "Tokens" ? modelData.totalTokens : modelData.cost) / trend.chartMax : 0))
              radius: 2
              color: Util.alpha(Color.accent, (barMa.containsMouse || index === trend.cursor) ? 0.95 : 0.6)
            }
            MouseArea {
              id: barMa
              anchors.fill: parent
              hoverEnabled: true
              acceptedButtons: Qt.NoButton
              onEntered: trend.showTip(modelData, width * index)
              onExited: trend.hideTip()
            }
          }
        }
      }

      // X axis: first / middle / last date.
      RowLayout {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: Style.space(44)
        visible: trend.days.length > 0
        Text { text: trend.days.length ? trend.days[0].date : ""; color: Util.alpha(Color.foreground, 0.4); font.family: root.monoFamily; font.pixelSize: root.pxCaption }
        Item { Layout.fillWidth: true }
        Text { visible: trend.days.length > 2; text: trend.days.length ? trend.days[Math.floor(trend.days.length / 2)].date : ""; color: Util.alpha(Color.foreground, 0.4); font.family: root.monoFamily; font.pixelSize: root.pxCaption }
        Item { Layout.fillWidth: true }
        Text { text: trend.days.length ? trend.days[trend.days.length - 1].date : ""; color: Util.alpha(Color.foreground, 0.4); font.family: root.monoFamily; font.pixelSize: root.pxCaption }
      }

      // Keyboard focus ring for the plot area.
      Rectangle {
        anchors.fill: parent
        color: "transparent"
        radius: Style.cornerRadius
        border.width: chartArea.activeFocus ? 1 : 0
        border.color: Util.alpha(Color.accent, 0.4)
      }

      // Tooltip.
      Rectangle {
        id: tip
        visible: false
        z: 10
        width: tipCol.implicitWidth + Style.space(16)
        height: tipCol.implicitHeight + Style.space(10)
        radius: Math.max(2, Style.cornerRadius / 2)
        color: Color.tooltip.background
        border.color: Color.tooltip.border
        border.width: 1
        Column {
          id: tipCol
          anchors.centerIn: parent
          spacing: Style.space(2)
          Text { text: tip.tipDate; color: Color.tooltip.text; font.family: Style.font.family; font.pixelSize: root.pxCaption; font.bold: true }
          Text { text: tip.tipValue; color: Color.tooltip.text; font.family: root.monoFamily; font.pixelSize: root.pxCaption }
        }
        property string tipDate: ""
        property string tipValue: ""
      }
    }

    function showTip(day, approxX) {
      tip.tipDate = day.date
      tip.tipValue = (metric === "Tokens" ? Usage.formatTokens(day.totalTokens) : Usage.formatCost(day.cost)) + " · " + (metric === "Tokens" ? "tokens" : "spend")
      tip.x = Math.max(0, Math.min(chartArea.width - tip.width, approxX + Style.space(44)))
      tip.y = Style.space(4)
      tip.visible = true
    }
    function hideTip() { tip.visible = false }
  }

  // Generic ranked page (Models / Agents) with a side summary.
  component RankPage: Flickable {
    id: rankPage
    property var groups: ({})
    property bool byModel: false
    property string sortBy: "value"   // value | tokens | cost | sessions
    // Independent metric for the rank pages: defaults to Tokens and is reset
    // on every open; does not follow the donut/trend metric.
    property string rankMetric: "Tokens"
    // Shared row cursor (ALIGN): hover and keyboard drive the same index.
    property int cursorIndex: -1
    readonly property int cursorCount: rankPage.entryList.length
    onEntryListChanged: if (cursorIndex >= entryList.length) cursorIndex = entryList.length - 1
    readonly property var entryList: rankPage.entries()
    readonly property real entryMax: rankPage.maxOf(entryList)
    Layout.fillWidth: true
    Layout.fillHeight: true
    contentWidth: width
    contentHeight: rankCol.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    function entries() {
      var out = []
      for (var key in groups) {
        var g = groups[key]
        out.push({ key: key, value: rankPage.rankMetric === "Tokens" ? g.totalTokens : g.cost, tokens: g.totalTokens, cost: g.cost, sessions: g.sessions || 0 })
      }
      out.sort(function(a, b) {
        if (sortBy === "tokens") return b.tokens - a.tokens
        if (sortBy === "cost") return b.cost - a.cost
        return b.value - a.value
      })
      return out
    }
    function maxOf(list) {
      var m = 0
      for (var i = 0; i < list.length; i++) m = Math.max(m, list[i].value)
      return m
    }

    ColumnLayout {
      id: rankCol
      width: parent.width
      spacing: Style.space(20)

      PageHeader {
        title: rankPage.byModel ? "Models" : "Agents"
        subtitle: rankPage.byModel
          ? "Always aggregated by model, for " + root.rangeLabel(root.range)
          : "Always aggregated by agent, for " + root.rangeLabel(root.range)
        NavChip { label: "Tokens"; active: rankPage.rankMetric === "Tokens"; onPick: rankPage.rankMetric = "Tokens" }
        NavChip { label: "Cost"; active: rankPage.rankMetric === "Cost"; onPick: rankPage.rankMetric = "Cost" }
      }

      // Full-width ranking — the side summary panel was removed by request.
      PanelBox {
        Layout.fillWidth: true
        title: rankPage.byModel ? "Model ranking" : "Agent ranking"

        // Column headings.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(10)
          Text { Layout.preferredWidth: Style.space(24); horizontalAlignment: Text.AlignRight; text: "#"; color: Util.alpha(Color.foreground, 0.4); font.family: Style.font.family; font.pixelSize: root.pxCaption }
          Text { Layout.fillWidth: true; text: rankPage.byModel ? "Model" : "Agent"; color: Util.alpha(Color.foreground, 0.4); font.family: Style.font.family; font.pixelSize: root.pxCaption }
          Text { visible: root.showLocalHistory; text: "Tokens"; color: Util.alpha(Color.foreground, 0.4); font.family: Style.font.family; font.pixelSize: root.pxCaption }
          Text { visible: root.showEstimatedCost; Layout.preferredWidth: Style.space(78); horizontalAlignment: Text.AlignRight; text: "Cost"; color: Util.alpha(Color.foreground, 0.4); font.family: Style.font.family; font.pixelSize: root.pxCaption }
        }
        PanelSeparator { Layout.fillWidth: true; foreground: Color.foreground; strength: 0.10 }

        Repeater {
          model: rankPage.entryList
          RankRow {
            Layout.fillWidth: true
            rank: index + 1
            label: modelData.key
            value: modelData.value
            maxValue: rankPage.entryMax
            tokens: modelData.tokens
            cost: modelData.cost
            isCurrent: index === rankPage.cursorIndex
            onHoverCursor: rankPage.cursorIndex = index
          }
        }
        Text {
          visible: rankPage.entryList.length === 0
          Layout.fillWidth: true
          text: "No data in this range"
          color: Util.alpha(Color.foreground, 0.5)
          font.family: Style.font.family
          font.pixelSize: root.pxLabel
        }
      }
    }
  }

  component ModelsPage: RankPage { byModel: true; groups: root.modelAgg.groups }
  component AgentsPage: RankPage { byModel: false; groups: root.agentAgg.groups }

  // Activity: calendar heatmap, 7 rows (Mon..Sun) × weeks, time → right.
  // Independent of the global range: always the last N weeks.
  component ActivityPage: Flickable {
    id: actPage
    property int weeks: 12
    Layout.fillWidth: true
    Layout.fillHeight: true
    contentWidth: width
    contentHeight: actCol.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds

    function valueMap() {
      var map = {}
      var days = root.dataset ? root.dataset.days : []
      for (var i = 0; i < days.length; i++) {
        map[days[i].date] = root.metric === "Tokens" ? days[i].totalTokens : days[i].cost
      }
      return map
    }
    readonly property var heat: Usage.heatmapWeeks(valueMap(), weeks, new Date())

    // Two-hue intensity ramp (theme positive -> accent) instead of a flat
    // single-color alpha ramp.
    function heatColor(fraction) {
      var f = Math.max(0, Math.min(1, fraction))
      var from = Color.positive
      var to = Color.accent
      return Qt.rgba(from.r + (to.r - from.r) * f, from.g + (to.g - from.g) * f, from.b + (to.b - from.b) * f, 0.25 + 0.65 * f)
    }

    ColumnLayout {
      id: actCol
      width: parent.width
      spacing: Style.space(20)

      PageHeader {
        title: "Activity"
        subtitle: "Calendar heatmap — last " + actPage.weeks + " weeks (independent of the range above)"
        NavChip { label: "12 weeks"; active: actPage.weeks === 12; onPick: actPage.weeks = 12 }
        NavChip { label: "1 year"; active: actPage.weeks === 52; onPick: actPage.weeks = 52 }
      }

      PanelBox {
        id: heatBox
        Layout.fillWidth: true
        title: "Daily " + (root.metric === "Tokens" ? "tokens" : "spend")

        readonly property real labelW: Style.space(34)
        readonly property real cell: Math.max(8, Math.min(Style.space(20), Math.floor((width - contentLeftInset - contentRightInset - labelW - Style.space(6)) / Math.max(1, actPage.weeks))))

        // Month labels.
        Row {
          Layout.fillWidth: true
          Layout.leftMargin: heatBox.labelW + Style.space(6)
          spacing: 0
          Repeater {
            model: actPage.heat.months
            Text {
              width: heatBox.cell * (actPage.heat.months[index + 1] ? (actPage.heat.months[index + 1].col - modelData.col) : (actPage.weeks - modelData.col))
              text: modelData.label
              color: Util.alpha(Color.foreground, 0.5)
              font.family: Style.font.family
              font.pixelSize: root.pxCaption
            }
          }
        }

        // Day labels + grid.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(6)

          Column {
            spacing: Style.space(3)
            Repeater {
              model: actPage.heat.days
              Text {
                width: heatBox.labelW
                height: heatBox.cell
                verticalAlignment: Text.AlignVCenter
                text: (index % 2 === 0) ? modelData : ""
                color: Util.alpha(Color.foreground, 0.5)
                font.family: Style.font.family
                font.pixelSize: root.pxCaption
              }
            }
          }

          Grid {
            columns: actPage.weeks
            spacing: Style.space(3)
            flow: Grid.TopToBottom
            rows: 7

            Repeater {
              model: {
                // Flatten cells[row][col] column-major so flow:TopToBottom lays
                // each column top→bottom, columns left→right.
                var out = []
                var h = actPage.heat.cells
                for (var c = 0; c < actPage.weeks; c++)
                  for (var r = 0; r < 7; r++)
                    out.push(h[r][c])
                return out
              }
              Rectangle {
                required property var modelData
                width: heatBox.cell
                height: heatBox.cell
                radius: 3
                color: modelData === null ? "transparent"
                  : (modelData.value > 0
                    ? actPage.heatColor(actPage.heat.max > 0 ? modelData.value / actPage.heat.max : 0)
                    : Util.alpha(Color.foreground, 0.06))
                Accessible.description: modelData ? modelData.date + " " + root.formatValue(modelData.value) : ""
                ToolTip.text: modelData ? (modelData.date + " · " + root.formatValue(modelData.value)) : ""
                ToolTip.visible: cellMa.containsMouse && modelData !== null
                ToolTip.delay: 200
                MouseArea { id: cellMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
              }
            }
          }
        }

        // Intensity legend, bottom right.
        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(4)
          Item { Layout.fillWidth: true }
          Text { text: "less"; color: Util.alpha(Color.foreground, 0.5); font.family: Style.font.family; font.pixelSize: root.pxCaption }
          Repeater {
            model: [0.0, 0.25, 0.5, 0.75, 1.0]
            Rectangle {
              width: Style.space(12); height: Style.space(12); radius: 3
              color: modelData === 0 ? Util.alpha(Color.foreground, 0.06) : actPage.heatColor(modelData)
            }
          }
          Text { text: "more"; color: Util.alpha(Color.foreground, 0.5); font.family: Style.font.family; font.pixelSize: root.pxCaption }
        }
      }
    }
  }

  // Records: a real table — persistent header, aligned numeric columns,
  // text filter, sortable, incrementally loaded.
  component RecordsPage: Flickable {
    id: recPage
    property string filter: ""
    property string sortKey: "date"   // date | total | cost
    property bool sortDesc: true
    property int limit: 100
    // Shared row cursor (ALIGN): hover and keyboard drive the same index;
    // the cursor row is kept inside the viewport.
    property int cursorIndex: -1
    readonly property int cursorCount: recPage.visibleRecords.length
    property alias filterField: recFilter
    onCursorIndexChanged: recPage.ensureCursorVisible()
    onVisibleRecordsChanged: if (cursorIndex >= visibleRecords.length) cursorIndex = Math.max(-1, visibleRecords.length - 1)
    function ensureCursorVisible() {
      if (cursorIndex < 0) return
      var rowH = Style.space(42)
      var top = recBox.y + Style.space(52) + cursorIndex * rowH
      if (top < contentY) contentY = Math.max(0, top)
      else if (top + rowH > contentY + height) contentY = top + rowH - height
    }
    Layout.fillWidth: true
    Layout.fillHeight: true
    contentWidth: width
    contentHeight: recCol.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    readonly property var visibleRecords: recPage.computeRows()
    function computeRows() {
      var f = filter.toLowerCase()
      var rows = []
      for (var i = 0; i < root.records.length; i++) {
        var r = root.records[i]
        if (f !== "" && (r.agent + " " + r.model).toLowerCase().indexOf(f) === -1) continue
        rows.push(r)
      }
      rows.sort(function(a, b) {
        var d = 0
        if (sortKey === "total") d = a.totalTokens - b.totalTokens
        else if (sortKey === "cost") d = a.cost - b.cost
        else d = a.date < b.date ? -1 : (a.date > b.date ? 1 : 0)
        return sortDesc ? -d : d
      })
      return rows.slice(0, limit)
    }
    function toggleSort(key) {
      if (sortKey === key) sortDesc = !sortDesc
      else { sortKey = key; sortDesc = true }
    }

    ColumnLayout {
      id: recCol
      width: parent.width
      spacing: Style.space(20)

      PageHeader {
        title: "Records"
        subtitle: root.records.length + " agent×model records for " + root.rangeLabel(root.range)
        TextField {
          id: recFilter
          Layout.preferredWidth: Style.space(220)
          placeholderText: "Filter agent or model…"
          text: recPage.filter
          onTextChanged: recPage.filter = text
        }
      }

      BorderSurface {
        id: recBox
        Layout.fillWidth: true
        color: Util.alpha(Color.foreground, 0.03)
        borderSpec: Border.flat(Util.alpha(Color.foreground, 0.08), 1)
        radius: Style.cornerRadius
        padding: 0
        implicitHeight: recTable.implicitHeight + contentTopInset + contentBottomInset

        ColumnLayout {
          id: recTable
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          anchors.margins: 0
          spacing: 0

          // Persistent header.
          RowLayout {
            id: recHead
            Layout.fillWidth: true
            Layout.leftMargin: Style.space(14)
            Layout.rightMargin: Style.space(14)
            Layout.topMargin: Style.space(10)
            Layout.bottomMargin: Style.space(8)
            spacing: Style.space(12)
            function hdr(key) { return recPage.sortKey === key ? (recPage.sortDesc ? " ▾" : " ▴") : "" }
            Th { Layout.preferredWidth: Style.space(96);  text: "Date" + hdr("date");  align: Text.AlignLeft;  sortable: true; onPick: recPage.toggleSort("date") }
            Th { Layout.preferredWidth: Style.space(110); text: "Agent";               align: Text.AlignLeft }
            Th { Layout.fillWidth: true;                  text: "Model";               align: Text.AlignLeft }
            Th { Layout.preferredWidth: Style.space(70);  text: "Input";               align: Text.AlignRight }
            Th { Layout.preferredWidth: Style.space(70);  text: "Output";              align: Text.AlignRight }
            Th { Layout.preferredWidth: Style.space(70);  text: "Cache";               align: Text.AlignRight }
            Th { Layout.preferredWidth: Style.space(78);  text: "Total" + hdr("total"); align: Text.AlignRight; sortable: true; onPick: recPage.toggleSort("total") }
            Th { Layout.preferredWidth: Style.space(78); visible: root.showEstimatedCost; text: "Cost" + hdr("cost"); align: Text.AlignRight; sortable: true; onPick: recPage.toggleSort("cost") }
          }
          PanelSeparator { Layout.fillWidth: true; foreground: Color.foreground; strength: 0.12 }

          Repeater {
            model: recPage.visibleRecords
            RowLayout {
              required property var modelData
              required property int index
              Layout.fillWidth: true
              Layout.leftMargin: Style.space(14)
              Layout.rightMargin: Style.space(14)
              Layout.preferredHeight: Style.space(42)
              spacing: Style.space(12)
              // Omarchy row contract (ALIGN §Records): one shared cursor —
              // hover and j/k/arrows land on the same selected fill.
              Rectangle {
                anchors.fill: parent
                z: -1
                color: index === recPage.cursorIndex ? Style.selectedFillFor(Color.foreground, Color.accent)
                  : (index % 2 ? Util.alpha(Color.foreground, 0.025) : "transparent")
              }
              HoverHandler { onHoveredChanged: if (hovered) recPage.cursorIndex = index }
              Text { Layout.preferredWidth: Style.space(96);  elide: Text.ElideRight; text: modelData.date; color: Util.alpha(Color.foreground, 0.75); font.family: root.monoFamily; font.pixelSize: root.pxCaption }
              Text { Layout.preferredWidth: Style.space(110); elide: Text.ElideRight; text: modelData.agent; color: Color.foreground; font.family: Style.font.family; font.pixelSize: root.pxLabel }
              Text { Layout.fillWidth: true;                  elide: Text.ElideRight; text: modelData.model; color: Util.alpha(Color.foreground, 0.75); font.family: Style.font.family; font.pixelSize: root.pxLabel; ToolTip.text: modelData.model; ToolTip.visible: false }
              Text { Layout.preferredWidth: Style.space(70);  horizontalAlignment: Text.AlignRight; text: Usage.formatTokens(modelData.inputTokens);  color: Util.alpha(Color.foreground, 0.7); font.family: root.monoFamily; font.pixelSize: root.pxCaption }
              Text { Layout.preferredWidth: Style.space(70);  horizontalAlignment: Text.AlignRight; text: Usage.formatTokens(modelData.outputTokens); color: Util.alpha(Color.foreground, 0.7); font.family: root.monoFamily; font.pixelSize: root.pxCaption }
              Text { Layout.preferredWidth: Style.space(70);  horizontalAlignment: Text.AlignRight; text: Usage.formatTokens(modelData.cacheTokens);  color: Util.alpha(Color.foreground, 0.7); font.family: root.monoFamily; font.pixelSize: root.pxCaption }
              Text { Layout.preferredWidth: Style.space(78);  horizontalAlignment: Text.AlignRight; text: Usage.formatTokens(modelData.totalTokens);  color: Color.foreground; font.family: root.monoFamily; font.pixelSize: root.pxCaption; font.bold: true }
              Text { Layout.preferredWidth: Style.space(78);  horizontalAlignment: Text.AlignRight; visible: root.showEstimatedCost; text: Usage.formatCost(modelData.cost); color: Color.foreground; font.family: root.monoFamily; font.pixelSize: root.pxCaption; font.bold: true }
            }
          }

          Text {
            visible: recPage.visibleRecords.length === 0
            Layout.fillWidth: true
            Layout.margins: Style.space(20)
            horizontalAlignment: Text.AlignHCenter
            text: root.records.length === 0 ? "No records in this range" : "No records match the filter"
            color: Util.alpha(Color.foreground, 0.5)
            font.family: Style.font.family
            font.pixelSize: root.pxLabel
          }

          Button {
            visible: recPage.visibleRecords.length >= recPage.limit && recPage.limit < root.records.length
            Layout.alignment: Qt.AlignHCenter
            Layout.topMargin: Style.space(8)
            Layout.bottomMargin: Style.space(12)
            text: "Load more (" + (root.records.length - recPage.limit) + " remaining)"
            foreground: Color.foreground
            fontFamily: Style.font.family
            fontSize: root.pxLabel
            horizontalPadding: Style.space(14)
            verticalPadding: Style.space(6)
            onClicked: recPage.limit += 100
          }
          Item { Layout.preferredHeight: Style.space(10) }
        }
      }
    }
  }

  // Settings: Connections · Appearance & data · Refresh · Privacy & security.
  component SettingsPage: Flickable {
    id: settingsFlick
    Layout.fillWidth: true
    Layout.fillHeight: true
    contentWidth: width
    contentHeight: setCol.implicitHeight
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

    readonly property int cols: width >= Style.space(1100) ? 12 : 1

    ColumnLayout {
      id: setCol
      width: parent.width
      spacing: Style.space(20)

      PageHeader { title: "Settings"; subtitle: "Connections, appearance, refresh and privacy" }

      // --- Connections ---
      Text { Layout.fillWidth: true; text: "Connections"; color: Qt.darker(Color.foreground, 1.4); font.family: Style.font.family; font.pixelSize: root.pxCaption; font.bold: true }
      GridLayout {
        Layout.fillWidth: true
        // Vertical list: an expanded card must never leave uneven gaps in a
        // second column (ALIGN §Settings attuale).
        columns: 1
        rowSpacing: Style.space(16)

        Repeater {
          model: ["codex", "kimi", "grok"]
          SettingsProviderCard {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignTop
            provider: root.providerForSettings(modelData)
            monitored: root.providerToggle(modelData)
            lastCheckedAtMs: root.service ? root.service.lastRefreshedAtMs : 0
            onToggle: function(enabled) { root.setProviderToggle(modelData, enabled) }
            onRefreshDetection: if (root.service) root.service.refreshProvider(modelData)
          }
        }
      }

      // --- Appearance & data (7) | Refresh (5) ---
      GridLayout {
        Layout.fillWidth: true
        columns: settingsFlick.cols
        columnSpacing: Style.space(20)
        rowSpacing: Style.space(20)

        PanelBox {
          Layout.fillWidth: true
          Layout.columnSpan: settingsFlick.cols === 1 ? 1 : 7
          title: "Appearance & data"

          SettingRow { label: "Initial range" }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            Repeater {
              model: ["Day", "Week", "Month", "Year", "All"]
              NavChip { label: modelData; active: root.range === modelData; onPick: root.range = modelData }
            }
          }
          SettingRow { label: "Donut groups by" }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            NavChip { label: "Agents"; active: root.groupBy === "Provider"; onPick: root.groupBy = "Provider" }
            NavChip { label: "Models"; active: root.groupBy === "Model"; onPick: root.groupBy = "Model" }
          }
          SettingRow { label: "Donut metric" }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)
            NavChip { label: "Cost"; active: root.metric === "Cost"; onPick: root.metric = "Cost" }
            NavChip { label: "Tokens"; active: root.metric === "Tokens"; onPick: root.metric = "Tokens" }
          }
          PanelSeparator { Layout.fillWidth: true; foreground: Color.foreground; strength: 0.10 }
          Toggle {
            Layout.fillWidth: true
            label: "Show estimated cost"
            description: "Local cost is a ccusage estimate, not an official quota"
            checked: root.showEstimatedCost
            foreground: Color.foreground
            accent: Color.accent
            fontFamily: Style.font.family
            onClicked: root.showEstimatedCost = !root.showEstimatedCost
          }
          Toggle {
            Layout.fillWidth: true
            label: "Show local history"
            description: "Token/cost history sourced from ccusage"
            checked: root.showLocalHistory
            foreground: Color.foreground
            accent: Color.accent
            fontFamily: Style.font.family
            onClicked: root.showLocalHistory = !root.showLocalHistory
          }
        }

        PanelBox {
          Layout.fillWidth: true
          Layout.columnSpan: settingsFlick.cols === 1 ? 1 : 5
          title: "Refresh"

          KpiStat { label: "LAST UPDATE"; value: root.service ? Usage.timeAgo(root.service.lastRefreshedAtMs) : "never" }
          KpiStat { label: "AUTO INTERVAL"; value: root.refreshMinutesValue() + " min" }
          NumberField {
            Layout.fillWidth: true
            label: "Interval (minutes)"
            value: root.refreshMinutesValue()
            from: 1
            to: 120
            stepSize: 1
            fieldWidth: Style.space(120)
            foreground: Color.foreground
            accent: Color.accent
            fontFamily: Style.font.family
            onModified: function(v) { root.setRefreshMinutes(v) }
          }
          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)
            Button {
              text: "Refresh now"
              iconText: "↻"
              iconSpinning: root.service ? root.service.loading : false
              foreground: Color.foreground
              fontFamily: Style.font.family
              fontSize: root.pxLabel
              horizontalPadding: Style.space(14)
              verticalPadding: Style.space(6)
              active: true
              onClicked: if (root.service) root.service.refresh(true)
            }
            Text {
              visible: root.service ? root.service.loading : false
              text: "working…"
              color: Util.alpha(Color.foreground, 0.5)
              font.family: Style.font.family
              font.pixelSize: root.pxCaption
            }
          }
          Button {
            text: root.resetArmed ? "Confirm reset?" : "Reset preferences"
            foreground: Color.foreground
            fontFamily: Style.font.family
            fontSize: root.pxLabel
            horizontalPadding: Style.space(14)
            verticalPadding: Style.space(6)
            onClicked: root.armReset()
          }
        }
      }

      // --- Privacy & security (full-width band) ---
      PanelBox {
        Layout.fillWidth: true
        title: "Privacy & security"

        Text {
          Layout.fillWidth: true
          text: "• Reads local usage files via ccusage; never prints tokens, keys or cookies in the UI or logs.\n"
              + "• Runs provider CLIs only for detection/login status; credentials are never stored in the manifest or settings.\n"
              + "• Official quotas use a machine-readable API where one exists (Codex app-server; Kimi /usages and Grok Build billing with the local OAuth tokens, held in memory only, never printed or stored); other providers show local estimates only.\n"
              + "• Network requests happen only for providers you enable. Disable a provider in Connections to stop its polling."
          color: Util.alpha(Color.foreground, 0.6)
          font.family: Style.font.family
          font.pixelSize: root.pxLabel
          wrapMode: Text.WordWrap
          lineHeight: 1.25
        }
      }
    }
  }

  // Sortable header cell: mouse and keyboard equivalent (ALIGN §Records).
  component Th: Text {
    id: th
    property int align: Text.AlignLeft
    property bool sortable: false
    signal pick()
    horizontalAlignment: align
    color: th.activeFocus ? Color.foreground : Util.alpha(Color.foreground, 0.5)
    font.family: Style.font.family
    font.pixelSize: root.pxCaption
    font.bold: true
    activeFocusOnTab: sortable
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: th.pick() }
    Keys.onPressed: function(event) {
      if (event.key === Qt.Key_Return || event.key === Qt.Key_Space) { th.pick(); event.accepted = true }
    }
  }

  // Settings option label row.
  component SettingRow: Text {
    property string label: ""
    Layout.fillWidth: true
    text: label
    color: Color.foreground
    font.family: Style.font.family
    font.pixelSize: root.pxBody
  }

  // Settings helpers.
  property bool resetArmed: false
  function armReset() {
    if (!resetArmed) { resetArmed = true; resetTimer.restart(); return }
    resetArmed = false
    toggleState = ({})
    metric = "Cost"; groupBy = "Provider"; range = "Month"
    showEstimatedCost = true; showLocalHistory = true
    persistSettings(true)
  }
  Timer { id: resetTimer; interval: 3000; onTriggered: root.resetArmed = false }

  function setRefreshMinutes(v) {
    if (!shell || typeof shell.updateEntryInline !== "function" || !service) return
    var entry = service.settingsEntry()
    var next = {}
    for (var k in entry) if (k !== "id") next[k] = entry[k]
    next.refreshMinutes = Math.max(1, Math.min(120, Math.round(Number(v) || 10)))
    shell.updateEntryInline(pluginId, next)
    service.refreshMinutes = next.refreshMinutes
  }

  // Build a provider view for the settings card, even before detection ran.
  function providerForSettings(id) {
    if (service && service.providersById && service.providersById[id]) return service.providersById[id]
    var names = { codex: "Codex", kimi: "Kimi Code", grok: "Grok Build" }
    var notes = {
      codex: "",
      kimi: "Quota available in Kimi /usage",
      grok: "Quota available via /usage in Grok Build"
    }
    var logins = { codex: "codex login", kimi: "kimi login", grok: "grok login --device-auth" }
    return {
      id: id, displayName: names[id] || id, installed: false, authenticated: false,
      enabled: providerToggle(id), status: "not-installed", experimental: id !== "codex",
      capabilities: { localUsage: true, officialQuota: false }, metrics: [],
      quotaNote: notes[id] || "", loginCommand: logins[id] || "", version: "", plan: "", authKind: "",
      docsUrl: "", stale: false
    }
  }
}
