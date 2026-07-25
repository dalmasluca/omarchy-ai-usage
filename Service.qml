import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Usage.js" as Usage

// Single shared data source for dalmasluca.ai-usage. No UI here. Loaded by the
// shell's service host; injected with shell/manifest. Combines:
//   - local token/cost history from ccusage (never presented as official quota)
//   - official Codex rate limits via the shared scanner (one app-server poll
//     window, coordinated through ~/.cache/omarchy/codex-quota.json)
//   - official Kimi Code plan quota (weekly + rolling windows) via
//     scripts/kimi_usage.py, the same /usages endpoint the CLI's /usage uses
//   - official Grok Build credit quota (weekly/monthly pool) via
//     scripts/grok_usage.py, the same billing endpoint /usage fetches
//   - opt-in provider detection (kimi/grok) via provider_probe.py
Item {
  id: root
  visible: false

  property var shell: null
  property var manifest: null
  property string omarchyPath: ""

  readonly property string home: Quickshell.env("HOME") || ""
  // The Codex scanner lives in the shell's shared Commons, whose location
  // relative to the plugin depends on the install layout (plugin under
  // quickshell/plugins vs omarchy/plugins). First existing candidate wins.
  readonly property var scannerCandidates: [
    String(Qt.resolvedUrl("../../Commons/scripts/codex_usage_scanner.py")).replace("file://", ""),
    home + "/.config/quickshell/Commons/scripts/codex_usage_scanner.py",
    home + "/.config/omarchy/Commons/scripts/codex_usage_scanner.py"
  ]

  function scannerCommand(force) {
    return ["bash", "-c",
      'c1="$1"; c2="$2"; c3="$3"; shift 3; for p in "$c1" "$c2" "$c3"; do [ -f "$p" ] && exec python3 "$p" "$@"; done; exit 127',
      "codex-quota"
    ].concat(root.scannerCandidates, ["--quota-only"], force ? ["--force"] : [])
  }
  readonly property string probePath: String(Qt.resolvedUrl("scripts/provider_probe.py")).replace("file://", "")
  readonly property string kimiQuotaPath: String(Qt.resolvedUrl("scripts/kimi_usage.py")).replace("file://", "")
  readonly property string grokQuotaPath: String(Qt.resolvedUrl("scripts/grok_usage.py")).replace("file://", "")

  // Normalized state. `revision` bumps on every change so UI bindings that
  // read deep var fields re-evaluate (QML does not notify on deep mutation).
  property var dataset: ({ available: false, days: [], totals: {}, byModel: ({}), byAgent: ({}), models: [], agents: [], error: "" })
  property var providers: []
  property var providersById: ({})
  property int revision: 0
  property bool loading: false
  property bool stale: false
  property string error: ""
  property double lastRefreshedAtMs: 0
  property bool ccusageAvailable: false
  property string ccusageError: ""

  readonly property var optInProviders: ["kimi", "grok"]

  // --- settings (read from the shell.json entry for this widget) ---------

  function manifestDefaults() {
    var m = root.manifest
    if (m && m.barWidget && m.barWidget.defaults) return m.barWidget.defaults
    return {}
  }

  function settingsEntry() {
    var sh = root.shell
    if (!sh || !sh.shellConfig) return {}
    var config = sh.shellConfig
    var key = "dalmasluca.ai-usage"
    if (config.bar && config.bar.layout) {
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length; s++) {
        var arr = config.bar.layout[sections[s]] || []
        for (var i = 0; i < arr.length; i++) {
          if (arr[i] && Util.canonicalWidgetId(arr[i].id) === key) return arr[i]
        }
      }
    }
    if (Array.isArray(config.plugins)) {
      for (var j = 0; j < config.plugins.length; j++) {
        if (config.plugins[j] && Util.canonicalWidgetId(config.plugins[j].id) === key) return config.plugins[j]
      }
    }
    return {}
  }

  function setting(name, fallback) {
    var entry = settingsEntry()
    var value = entry[name]
    if (value === undefined || value === null) {
      var defaults = manifestDefaults()
      value = defaults[name]
    }
    return value === undefined || value === null ? fallback : value
  }

  function providerEnabled(id) {
    return setting(id + "Enabled", id === "codex") === true
  }

  property int refreshMinutes: Math.max(1, Math.min(120, Number(setting("refreshMinutes", 10)) || 10))

  // --- ccusage local history --------------------------------------------

  Process {
    id: ccusageProc
    command: ["ccusage", "daily", "--json", "--by-agent"]
    running: false
    stdout: StdioCollector { id: ccusageOut; waitForEnd: true }
    stderr: StdioCollector { id: ccusageErr; waitForEnd: true }
    onExited: function(code) { root.parseCcusage(code, ccusageOut.text || "", ccusageErr.text || "") }
  }

  function parseCcusage(code, stdoutText, stderrText) {
    var raw = String(stdoutText || "").trim()
    if (code !== 0 || raw === "") {
      root.ccusageAvailable = false
      root.ccusageError = code === 0 ? "ccusage returned no data" : (String(stderrText || "").trim() || "ccusage failed")
      // keep previous dataset visible as stale
      var ds = root.dataset
      ds.available = false
      ds.error = root.ccusageError
      root.dataset = ds
      root.bump()
      root.finishRefresh()
      return
    }
    try {
      var parsed = JSON.parse(raw)
      root.dataset = Usage.parseDaily(parsed)
      root.ccusageAvailable = root.dataset.available
      root.ccusageError = ""
    } catch (e) {
      root.ccusageAvailable = false
      root.ccusageError = "ccusage output unparsable"
      console.warn("ai-usage/ccusage", e)
    }
    root.bump()
    root.finishRefresh()
  }

  // --- Codex official quota (shared scanner) ----------------------------

  Process {
    id: codexProc
    running: false
    stdout: StdioCollector { id: codexOut; waitForEnd: true }
    onExited: function(code) { root.parseCodexQuota(codexOut.text || "") }
  }

  property var codexQuota: ({})

  function parseCodexQuota(stdoutText) {
    var raw = String(stdoutText || "").trim()
    if (raw === "") return
    try {
      root.codexQuota = JSON.parse(raw.split("\n").pop())
    } catch (e) {
      console.warn("ai-usage/codex", e)
    }
    root.rebuildProviders()
  }

  // --- Kimi Code official quota (scripts/kimi_usage.py) -----------------

  Process {
    id: kimiProc
    running: false
    stdout: StdioCollector { id: kimiOut; waitForEnd: true }
    onExited: function(code) { root.parseKimiQuota(kimiOut.text || "") }
  }

  property var kimiQuota: ({})

  function parseKimiQuota(stdoutText) {
    var raw = String(stdoutText || "").trim()
    if (raw === "") return
    try {
      var parsed = JSON.parse(raw.split("\n").pop())
      // Keep the last good quota visible across transient fetch failures.
      if (parsed.available) root.kimiQuota = parsed
    } catch (e) {
      console.warn("ai-usage/kimi", e)
    }
    root.rebuildProviders()
  }

  function runKimiQuota() {
    if (!kimiProc.running) {
      kimiProc.command = ["python3", root.kimiQuotaPath]
      kimiProc.running = true
    }
  }

  // --- Grok Build official quota (scripts/grok_usage.py) ----------------

  Process {
    id: grokProc
    running: false
    stdout: StdioCollector { id: grokOut; waitForEnd: true }
    onExited: function(code) { root.parseGrokQuota(grokOut.text || "") }
  }

  property var grokQuota: ({})

  function parseGrokQuota(stdoutText) {
    var raw = String(stdoutText || "").trim()
    if (raw === "") return
    try {
      var parsed = JSON.parse(raw.split("\n").pop())
      if (parsed.available) root.grokQuota = parsed
    } catch (e) {
      console.warn("ai-usage/grok", e)
    }
    root.rebuildProviders()
  }

  function runGrokQuota() {
    if (!grokProc.running) {
      grokProc.command = ["python3", root.grokQuotaPath]
      grokProc.running = true
    }
  }

  // --- opt-in provider probes (one shared process, queued) --------------

  Process {
    id: probeProc
    running: false
    stdout: StdioCollector { id: probeOut; waitForEnd: true }
    onExited: function(code) { root.finishProbe(probeOut.text || "") }
  }

  property var probeQueue: []
  property var probeResults: ({})
  property var probeLastAt: ({})
  property string currentProbe: ""

  function queueProbes(force) {
    var queue = []
    var now = Date.now()
    for (var i = 0; i < optInProviders.length; i++) {
      var id = optInProviders[i]
      if (!providerEnabled(id)) continue
      var last = probeLastAt[id] || 0
      if (!force && now - last < 5 * 60 * 1000) continue // TTL 5 min
      queue.push(id)
    }
    root.probeQueue = queue
    pumpProbes()
  }

  function pumpProbes() {
    if (probeProc.running) return
    var queue = root.probeQueue
    if (queue.length === 0) {
      root.rebuildProviders()
      return
    }
    var id = queue.shift()
    root.probeQueue = queue
    root.currentProbe = id
    probeProc.command = ["python3", root.probePath, id]
    probeProc.running = true
  }

  function finishProbe(stdoutText) {
    var id = root.currentProbe
    root.currentProbe = ""
    var raw = String(stdoutText || "").trim()
    if (id && raw !== "") {
      try {
        root.probeResults[id] = JSON.parse(raw.split("\n").pop())
        root.probeLastAt[id] = Date.now()
      } catch (e) {
        console.warn("ai-usage/probe", id, e)
      }
    }
    pumpProbes()
  }

  // --- provider assembly -------------------------------------------------

  function rebuildProviders() {
    var list = []
    var byId = {}

    if (providerEnabled("codex")) {
      var codexProbe = {
        id: "codex", displayName: "Codex", installed: true, authenticated: true,
        authKind: "chatgpt-login", experimental: false, version: "",
        loginCommand: "codex login", docsUrl: "https://developers.openai.com/codex",
        quotaNote: ""
      }
      var codex = Usage.normalizeProvider(codexProbe, root.codexQuota, true)
      list.push(codex)
      byId["codex"] = codex
    }

    for (var i = 0; i < optInProviders.length; i++) {
      var id = optInProviders[i]
      if (!providerEnabled(id)) continue
      var probe = root.probeResults[id]
      if (!probe) continue
      var quota = id === "kimi" ? root.kimiQuota : (id === "grok" ? root.grokQuota : null)
      var prov = Usage.normalizeProvider(probe, quota, true)
      list.push(prov)
      byId[id] = prov
    }

    root.providers = list
    root.providersById = byId
    root.bump()
  }

  // --- refresh orchestration --------------------------------------------

  function bump() { root.revision++ }

  function refresh(force) {
    if (root.loading && !force) return
    root.loading = true
    root.stale = root.dataset.available // keep last data visible as stale
    root.error = ""

    // ccusage local history
    if (!ccusageProc.running) ccusageProc.running = true

    // Codex official quota via shared scanner (cache-aware; --force bypasses)
    if (providerEnabled("codex") && !codexProc.running) {
      codexProc.command = root.scannerCommand(force)
      codexProc.running = true
    }

    // Kimi Code official quota (weekly + rolling windows)
    if (providerEnabled("kimi")) runKimiQuota()

    // Grok Build official credit quota (weekly/monthly pool)
    if (providerEnabled("grok")) runGrokQuota()

    queueProbes(force === true)
  }

  function finishRefresh() {
    root.loading = ccusageProc.running || codexProc.running || kimiProc.running || grokProc.running || probeProc.running
    if (!root.loading) {
      root.stale = false
      root.lastRefreshedAtMs = Date.now()
    }
    bump()
  }

  function refreshProvider(id) {
    if (id === "codex") {
      if (!codexProc.running) {
        codexProc.command = root.scannerCommand(true)
        codexProc.running = true
      }
      return
    }
    if (optInProviders.indexOf(id) !== -1) {
      root.probeLastAt[id] = 0
      root.probeQueue = (root.probeQueue.indexOf(id) === -1) ? root.probeQueue.concat([id]) : root.probeQueue
      pumpProbes()
      if (id === "kimi") runKimiQuota()
      if (id === "grok") runGrokQuota()
    }
  }

  // React to settings changes (provider toggles / refresh interval).
  Connections {
    target: root.shell ? root.shell.pluginRegistry : null
    function onPluginsChanged() {
      root.refreshMinutes = Math.max(1, Math.min(120, Number(root.setting("refreshMinutes", 10)) || 10))
      // Stop work for providers that were just disabled.
      for (var i = 0; i < root.optInProviders.length; i++) {
        var id = root.optInProviders[i]
        if (!root.providerEnabled(id)) {
          delete root.probeResults[id]
          var q = root.probeQueue.filter(function(x) { return x !== id })
          root.probeQueue = q
        }
      }
      root.rebuildProviders()
      root.refresh(false)
    }
  }

  Timer {
    interval: Math.max(1, root.refreshMinutes) * 60 * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  // Track in-flight child processes so loading clears when they finish.
  Connections { target: codexProc; function onRunningChanged() { if (!codexProc.running) root.finishRefresh() } }
  Connections { target: kimiProc; function onRunningChanged() { if (!kimiProc.running) root.finishRefresh() } }
  Connections { target: grokProc; function onRunningChanged() { if (!grokProc.running) root.finishRefresh() } }
  Connections { target: probeProc; function onRunningChanged() { if (!probeProc.running) root.finishRefresh() } }
}
