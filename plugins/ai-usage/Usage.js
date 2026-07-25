// Pure data helpers for omarchy.ai-usage. No Qt/QML calls so the same file
// runs under node for the self-check at the bottom.

function num(value) {
  var n = Number(value)
  return isFinite(n) ? n : 0
}

function round2(value) {
  return Math.round(num(value) * 100) / 100
}

// --- formatting ---------------------------------------------------------

function formatNumber(value) {
  var n = num(value)
  var parts = Math.round(Math.abs(n)).toString().split("")
  var out = []
  for (var i = 0; i < parts.length; i++) {
    if (i > 0 && (parts.length - i) % 3 === 0) out.push(",")
    out.push(parts[i])
  }
  return (n < 0 ? "-" : "") + out.join("")
}

function formatTokens(value) {
  var n = num(value)
  var abs = Math.abs(n)
  if (abs >= 1e9) return (n / 1e9).toFixed(1) + "B"
  if (abs >= 1e6) return (n / 1e6).toFixed(1) + "M"
  if (abs >= 1e3) return (n / 1e3).toFixed(1) + "K"
  return String(Math.round(n))
}

function formatCost(value) {
  var n = num(value)
  if (Math.abs(n) >= 1000) return "$" + formatNumber(Math.round(n))
  return "$" + n.toFixed(2)
}

function formatPercent(fraction) {
  var f = num(fraction)
  if (f < 0) return "—"
  return Math.round(f * 100) + "%"
}

function formatResetTime(isoTimestamp) {
  if (!isoTimestamp) return ""
  var reset = new Date(isoTimestamp).getTime()
  if (!isFinite(reset)) return ""
  var diff = reset - Date.now()
  if (diff <= 0) return "now"
  var hours = Math.floor(diff / 3600000)
  var mins = Math.floor((diff % 3600000) / 60000)
  if (hours > 24) return Math.floor(hours / 24) + "d " + (hours % 24) + "h"
  if (hours > 0) return hours + "h " + mins + "m"
  return mins + "m"
}

function timeAgo(ms) {
  var then = num(ms)
  if (then <= 0) return "never"
  var diff = Date.now() - then
  if (diff < 0) diff = 0
  var mins = Math.floor(diff / 60000)
  if (mins < 1) return "just now"
  if (mins < 60) return mins + "m ago"
  var hours = Math.floor(mins / 60)
  if (hours < 24) return hours + "h ago"
  return Math.floor(hours / 24) + "d ago"
}

// --- ccusage parsing ----------------------------------------------------

// Agent prefixes like "[pi] gpt-5.6-sol" fragment the model rankings — strip
// leading [tag] markers and fold known aliases into the canonical name so the
// same model aggregates into one entry everywhere (rankings, donut, records).
var MODEL_ALIASES = { "k3": "kimi-k3" }
function cleanModelName(name) {
  var c = String(name || "").replace(/^\s*(\[[^\]]*\]\s*)+/, "")
  return MODEL_ALIASES[c] || c || "unknown"
}

function emptyBucket() {
  return { inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0, totalTokens: 0, cost: 0 }
}

function addBucket(target, source) {
  var input = num(source.inputTokens)
  var output = num(source.outputTokens)
  var cacheRead = num(source.cacheReadTokens)
  var cacheCreation = num(source.cacheCreationTokens)
  target.inputTokens += input
  target.outputTokens += output
  target.cacheReadTokens += cacheRead
  target.cacheCreationTokens += cacheCreation
  // ccusage emits totalTokens on day/agent rows but NOT on modelBreakdowns —
  // derive it from the four fields when absent, or models read as zero.
  target.totalTokens += source.totalTokens !== undefined ? num(source.totalTokens) : input + output + cacheRead + cacheCreation
  target.cost += num(source.totalCost !== undefined ? source.totalCost : source.cost)
}

// Parse the output of `ccusage daily --json --by-agent` into a normalized
// dataset. Defensive: missing fields never throw.
function parseDaily(parsed) {
  var dataset = {
    fetchedAt: Date.now(),
    available: false,
    error: "",
    days: [],
    totals: emptyBucket(),
    byModel: ({}),
    byAgent: ({}),
    models: [],
    agents: []
  }
  if (!parsed || typeof parsed !== "object") return dataset
  var rows = Array.isArray(parsed.daily) ? parsed.daily : []
  var modelSet = {}
  var agentSet = {}

  for (var i = 0; i < rows.length; i++) {
    var row = rows[i] || {}
    var date = String(row.period || row.date || "")
    if (!date) continue
    var day = {
      date: date,
      inputTokens: num(row.inputTokens),
      outputTokens: num(row.outputTokens),
      cacheReadTokens: num(row.cacheReadTokens),
      cacheCreationTokens: num(row.cacheCreationTokens),
      totalTokens: num(row.totalTokens),
      cost: num(row.totalCost),
      byModel: ({}),
      byAgent: ({}),
      records: []
    }
    var breakdowns = Array.isArray(row.modelBreakdowns) ? row.modelBreakdowns : []
    for (var m = 0; m < breakdowns.length; m++) {
      var bd = breakdowns[m] || {}
      var model = cleanModelName(bd.modelName)
      modelSet[model] = true
      var mb = day.byModel[model] || (day.byModel[model] = emptyBucket())
      addBucket(mb, bd)
      var amb = dataset.byModel[model] || (dataset.byModel[model] = emptyBucket())
      addBucket(amb, bd)
    }
    var agentRows = Array.isArray(row.agents) ? row.agents : []
    for (var a = 0; a < agentRows.length; a++) {
      var ar = agentRows[a] || {}
      var agent = String(ar.agent || "unknown")
      agentSet[agent] = true
      var ab = day.byAgent[agent] || (day.byAgent[agent] = emptyBucket())
      addBucket(ab, ar)
      var aab = dataset.byAgent[agent] || (dataset.byAgent[agent] = emptyBucket())
      addBucket(aab, ar)
      // Joint agent×model records: ccusage nests modelBreakdowns inside each
      // agent row. Keep them so the Records table can show Agent + Model +
      // token breakdown on one row (the flat marginals above lose this join).
      var arModels = Array.isArray(ar.modelBreakdowns) ? ar.modelBreakdowns : []
      for (var am = 0; am < arModels.length; am++) {
        var abd = arModels[am] || {}
        var recModel = cleanModelName(abd.modelName)
        day.records.push({
          agent: agent,
          model: recModel,
          inputTokens: num(abd.inputTokens),
          outputTokens: num(abd.outputTokens),
          cacheReadTokens: num(abd.cacheReadTokens),
          cacheCreationTokens: num(abd.cacheCreationTokens),
          totalTokens: num(abd.inputTokens) + num(abd.outputTokens) + num(abd.cacheReadTokens) + num(abd.cacheCreationTokens),
          cost: num(abd.cost)
        })
      }
      // Agent row with no nested breakdown still yields one record.
      if (arModels.length === 0) {
        day.records.push({
          agent: agent, model: "unknown",
          inputTokens: num(ar.inputTokens), outputTokens: num(ar.outputTokens),
          cacheReadTokens: num(ar.cacheReadTokens), cacheCreationTokens: num(ar.cacheCreationTokens),
          totalTokens: num(ar.totalTokens), cost: num(ar.totalCost !== undefined ? ar.totalCost : ar.cost)
        })
      }
    }
    addBucket(dataset.totals, row)
    dataset.days.push(day)
  }

  dataset.days.sort(function(x, y) { return x.date < y.date ? -1 : (x.date > y.date ? 1 : 0) })
  dataset.models = Object.keys(modelSet).sort()
  dataset.agents = Object.keys(agentSet).sort()
  dataset.available = dataset.days.length > 0
  return dataset
}

// --- ranges -------------------------------------------------------------

function rangeDays(range) {
  var r = String(range || "Month")
  if (r === "Day") return 1
  if (r === "Week") return 7
  if (r === "Month") return 30
  if (r === "Year") return 365
  return 0 // "All"
}

function cutoffDate(range) {
  var span = rangeDays(range)
  if (span <= 0) return ""
  var d = new Date()
  d.setDate(d.getDate() - (span - 1))
  var mm = String(d.getMonth() + 1).padStart(2, "0")
  var dd = String(d.getDate()).padStart(2, "0")
  return d.getFullYear() + "-" + mm + "-" + dd
}

function filterDays(days, range) {
  var cutoff = cutoffDate(range)
  if (!cutoff) return days || []
  var out = []
  for (var i = 0; i < (days || []).length; i++) {
    if ((days[i].date || "") >= cutoff) out.push(days[i])
  }
  return out
}

// Aggregate a set of day rows into one bucket, optionally grouped.
function aggregate(days, groupBy) {
  var groups = {}
  var total = emptyBucket()
  for (var i = 0; i < (days || []).length; i++) {
    var day = days[i]
    addBucket(total, day)
    var source = groupBy === "Model" ? day.byModel : day.byAgent
    for (var key in source) {
      var g = groups[key] || (groups[key] = emptyBucket())
      addBucket(g, source[key])
    }
  }
  return { total: total, groups: groups }
}

// Ranked donut segments with an "Other" tail. metric: "Cost" | "Tokens".
function buildSegments(days, metric, groupBy, maxSegments) {
  var agg = aggregate(days, groupBy)
  var useCost = metric !== "Tokens"
  var entries = []
  for (var key in agg.groups) {
    var value = useCost ? agg.groups[key].cost : agg.groups[key].totalTokens
    if (value > 0) entries.push({ key: key, value: value })
  }
  entries.sort(function(a, b) { return b.value - a.value })
  var total = useCost ? agg.total.cost : agg.total.totalTokens
  var max = Math.max(1, maxSegments || 8)
  var segments = []
  var other = 0
  for (var i = 0; i < entries.length; i++) {
    if (i < max - 1 || entries.length <= max) {
      segments.push({
        key: entries[i].key,
        label: entries[i].key,
        value: entries[i].value,
        percent: total > 0 ? entries[i].value / total : 0
      })
    } else {
      other += entries[i].value
    }
  }
  if (other > 0) {
    segments.push({ key: "__other__", label: "Other", value: other, percent: total > 0 ? other / total : 0 })
  }
  return { total: total, metric: useCost ? "Cost" : "Tokens", groupBy: groupBy, segments: segments }
}

// Per-day series for the daily chart.
function dailySeries(days, metric) {
  var useCost = metric !== "Tokens"
  var out = []
  for (var i = 0; i < (days || []).length; i++) {
    out.push({ date: days[i].date, value: useCost ? days[i].cost : days[i].totalTokens })
  }
  return out
}

// --- records + heatmap --------------------------------------------------

function dateKey(d) {
  return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0")
}

// Flatten per-day agent×model records into table rows, newest first.
function flattenRecords(days) {
  var out = []
  for (var i = (days || []).length - 1; i >= 0; i--) {
    var day = days[i]
    var recs = day.records || []
    for (var r = 0; r < recs.length; r++) {
      var rec = recs[r]
      out.push({
        date: day.date,
        agent: rec.agent,
        model: rec.model,
        inputTokens: rec.inputTokens,
        outputTokens: rec.outputTokens,
        cacheTokens: rec.cacheReadTokens + rec.cacheCreationTokens,
        totalTokens: rec.totalTokens,
        cost: rec.cost
      })
    }
  }
  return out
}

var HEAT_MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
var HEAT_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

// Calendar heatmap grid: 7 rows (Mon..Sun) × `weeks` columns, time increasing
// left→right, last column = current week. Independent of the global range.
// Returns { days, cells:[row][col] = {date,value,future}|null, months:[{col,label}], max }.
function heatmapWeeks(valueByDate, weeks, today) {
  var now = today || new Date()
  var base = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  var dow = (base.getDay() + 6) % 7                 // 0 = Monday
  var thisMonday = new Date(base)
  thisMonday.setDate(base.getDate() - dow)
  var firstMonday = new Date(thisMonday)
  firstMonday.setDate(thisMonday.getDate() - (Math.max(1, weeks) - 1) * 7)

  var map = valueByDate || {}
  var max = 0
  for (var k in map) max = Math.max(max, num(map[k]))

  var cells = []
  var months = []
  var prevMonth = -1
  for (var r = 0; r < 7; r++) cells.push([])
  for (var c = 0; c < weeks; c++) {
    var colMonday = new Date(firstMonday)
    colMonday.setDate(firstMonday.getDate() + c * 7)
    var m = colMonday.getMonth()
    if (m !== prevMonth) { months.push({ col: c, label: HEAT_MONTHS[m] }); prevMonth = m }
    for (var rr = 0; rr < 7; rr++) {
      var d = new Date(colMonday)
      d.setDate(colMonday.getDate() + rr)
      if (d.getTime() > base.getTime()) { cells[rr].push(null); continue }
      var key = dateKey(d)
      cells[rr].push({ date: key, value: num(map[key]), future: false })
    }
  }
  return { days: HEAT_DAYS, cells: cells, months: months, max: max }
}

// --- provider normalization --------------------------------------------

// Merge a detection probe + an optional official quota payload into the
// normalized provider contract the UI consumes. Absent fields stay absent.
function normalizeProvider(probe, quota, enabled) {
  var p = probe || {}
  var metrics = []
  var q = quota || {}

  function pushMetric(kind, label, frac, resetsAt, source) {
    if (frac === undefined || frac === null || frac < 0) return
    metrics.push({
      kind: kind,
      label: label,
      usedPercent: Math.round(num(frac) * 100),
      remainingPercent: Math.round((1 - num(frac)) * 100),
      resetsAt: resetsAt || "",
      source: source
    })
  }

  var capabilities = { localUsage: true, officialQuota: false, resetTimes: false, balance: false, extraUsage: false }
  var status = "unknown"
  if (!p.installed) status = "not-installed"
  else if (p.error) status = "error"
  else if (!p.authenticated) status = "not-authenticated"

  if (q && Array.isArray(q.metrics) && q.metrics.length > 0) {
    // Multi-window quota contract (Kimi Code: weekly + rolling 5h/7d/30d
    // windows), each { label, percent (0..1), resetsAt }.
    capabilities.officialQuota = true
    for (var mi = 0; mi < q.metrics.length; mi++) {
      var m = q.metrics[mi] || {}
      pushMetric("official-" + mi, m.label || "Usage", m.percent, m.resetsAt, "official")
      if (m.resetsAt) capabilities.resetTimes = true
    }
    if (status === "unknown") status = "connected"
  } else if (q && (q.rateLimitPercent >= 0 || q.secondaryRateLimitPercent >= 0)) {
    capabilities.officialQuota = true
    capabilities.resetTimes = !!(q.rateLimitResetAt || q.secondaryRateLimitResetAt)
    pushMetric("primary", q.rateLimitLabel || "Rate limit", q.rateLimitPercent, q.rateLimitResetAt, "official")
    pushMetric("secondary", q.secondaryRateLimitLabel || "Secondary", q.secondaryRateLimitPercent, q.secondaryRateLimitResetAt, "official")
    if (status === "unknown") status = "connected"
  }

  // Authenticated but no (or failed) quota surface: the provider connection
  // itself works — report Connected instead of a misleading Unknown (e.g.
  // Codex during an OpenAI wham/usage outage).
  if (status === "unknown" && p.authenticated) status = "connected"

  return {
    id: p.id || "",
    displayName: p.displayName || p.id || "",
    installed: !!p.installed,
    authenticated: !!p.authenticated,
    enabled: enabled !== false,
    plan: p.plan || (q ? q.plan || q.tierLabel || "" : ""),
    authKind: p.authKind || "",
    version: p.version || "",
    available: !!p.installed,
    loading: false,
    stale: false,
    error: p.error || "",
    experimental: !!p.experimental,
    status: status,
    capabilities: capabilities,
    metrics: metrics,
    quotaNote: p.quotaNote || (q && q.usageStatusText ? String(q.usageStatusText) : ""),
    loginCommand: p.loginCommand || "",
    docsUrl: p.docsUrl || "",
    fetchedAt: Date.now()
  }
}

// --- self-check (node only; never runs under QML) -----------------------

function selfCheck() {
  var sample = {
    daily: [
      { period: "2026-07-01", inputTokens: 100, outputTokens: 50, cacheReadTokens: 0, cacheCreationTokens: 0, totalTokens: 150, totalCost: 1.5,
        modelBreakdowns: [{ modelName: "gpt-5", inputTokens: 100, outputTokens: 50, cost: 1.5 }],
        agents: [{ agent: "codex", inputTokens: 100, outputTokens: 50, totalTokens: 150, totalCost: 1.5,
          modelBreakdowns: [{ modelName: "gpt-5", inputTokens: 100, outputTokens: 50, cost: 1.5 }] }] },
      { period: "2026-07-02", inputTokens: 10, outputTokens: 5, totalTokens: 15, totalCost: 0.5,
        modelBreakdowns: [{ modelName: "kimi-k2", inputTokens: 10, outputTokens: 5, cost: 0.5 }, { modelName: "[pi] gpt-5", inputTokens: 40, outputTokens: 20, cost: 0.7 }, { modelName: "k3", inputTokens: 3, outputTokens: 2, cost: 0.1 }],
        agents: [{ agent: "kimi", inputTokens: 10, outputTokens: 5, totalTokens: 15, totalCost: 0.5,
          modelBreakdowns: [{ modelName: "kimi-k2", inputTokens: 10, outputTokens: 5, cost: 0.5 }] }] }
    ]
  }
  var ds = parseDaily(sample)
  if (!ds.available || ds.days.length !== 2) throw new Error("parseDaily days")
  if (Math.round(ds.totals.cost * 10) / 10 !== 2.0) throw new Error("totals cost")
  if (ds.totals.totalTokens !== 165) throw new Error("totals tokens")
  var seg = buildSegments(ds.days, "Cost", "Agent", 8)
  if (seg.segments[0].key !== "codex") throw new Error("segment ranking")
  // Models vs Agents aggregations must differ (root-cause data fix).
  var byModel = aggregate(ds.days, "Model").groups
  var byAgent = aggregate(ds.days, "Agent").groups
  if (!byModel["gpt-5"] || !byModel["kimi-k2"]) throw new Error("aggregate byModel keys")
  if (!byAgent["codex"] || !byAgent["kimi"]) throw new Error("aggregate byAgent keys")
  if (byModel["codex"] || byAgent["gpt-5"]) throw new Error("model/agent groups must not collide")
  // modelBreakdowns carry no totalTokens in real ccusage output: it must be
  // derived from the four token fields, not read as zero. "[pi] gpt-5" merges
  // into "gpt-5" and the alias "k3" folds into "kimi-k3".
  if (byModel["gpt-5"].totalTokens !== 210) throw new Error("model tokens derived + [tag] merge")
  if (byModel["[pi] gpt-5"]) throw new Error("tagged model must merge")
  if (!byModel["kimi-k3"] || byModel["kimi-k3"].totalTokens !== 5 || byModel["k3"]) throw new Error("model alias fold")
  var tokSeg = buildSegments(ds.days, "Tokens", "Model", 8)
  if (tokSeg.segments[0].key !== "gpt-5") throw new Error("tokens-metric segments")
  // Joint agent×model records survive parsing and flatten newest-first.
  if (ds.days[0].records.length !== 1 || ds.days[0].records[0].agent !== "codex" || ds.days[0].records[0].model !== "gpt-5") throw new Error("day records join")
  var flat = flattenRecords(ds.days)
  if (flat.length !== 2) throw new Error("flattenRecords count")
  if (flat[0].date !== "2026-07-02" || flat[0].agent !== "kimi") throw new Error("flattenRecords order")
  if (flat[1].totalTokens !== 150) throw new Error("flattenRecords tokens")
  // Calendar heatmap: 7 rows, N columns, month labels, no future cells.
  var map = { "2026-07-01": 5 }
  var heat = heatmapWeeks(map, 12, new Date(2026, 6, 24))
  if (heat.cells.length !== 7) throw new Error("heatmap rows")
  if (heat.cells[0].length !== 12) throw new Error("heatmap cols")
  if (heat.max !== 5) throw new Error("heatmap max")
  if (heat.months.length < 1) throw new Error("heatmap month labels")
  if (formatTokens(1500) !== "1.5K") throw new Error("formatTokens")
  if (formatCost(1234.5) !== "$1,235") throw new Error("formatCost")
  if (formatPercent(0.876) !== "88%") throw new Error("formatPercent")
  var prov = normalizeProvider({ id: "codex", displayName: "Codex", installed: true, authenticated: true },
    { rateLimitPercent: 0.4, rateLimitLabel: "Weekly", rateLimitResetAt: "2030-01-01T00:00:00Z", tierLabel: "plus" }, true)
  if (prov.metrics.length !== 1 || prov.metrics[0].usedPercent !== 40) throw new Error("normalize metrics")
  if (prov.status !== "connected") throw new Error("normalize status")
  // Multi-window quota contract (Kimi Code): weekly + rolling windows.
  var kimi = normalizeProvider({ id: "kimi", displayName: "Kimi Code", installed: true, authenticated: true },
    { plan: "Intermediate", metrics: [
      { label: "Weekly limit", percent: 1.0, resetsAt: "2030-01-01T00:00:00Z" },
      { label: "5h limit", percent: 0.25, resetsAt: "" }] }, true)
  if (kimi.metrics.length !== 2 || kimi.metrics[0].usedPercent !== 100 || kimi.metrics[1].usedPercent !== 25) throw new Error("kimi metrics")
  if (!kimi.capabilities.officialQuota || !kimi.capabilities.resetTimes) throw new Error("kimi capabilities")
  if (kimi.plan !== "Intermediate" || kimi.status !== "connected") throw new Error("kimi plan/status")
  // Authenticated with a failed/absent quota surface is still Connected.
  var noQuota = normalizeProvider({ id: "codex", installed: true, authenticated: true },
    { rateLimitPercent: -1, tierLabel: "plus", usageStatusText: "Codex limits unavailable" }, true)
  if (noQuota.status !== "connected") throw new Error("auth without quota must be connected")
  if (noQuota.plan !== "plus" || noQuota.quotaNote !== "Codex limits unavailable") throw new Error("quota fallback note")
  return true
}

if (typeof module !== "undefined" && module.exports) {
  module.exports = { selfCheck: selfCheck, parseDaily: parseDaily, aggregate: aggregate, buildSegments: buildSegments, flattenRecords: flattenRecords, heatmapWeeks: heatmapWeeks, formatTokens: formatTokens, formatCost: formatCost, formatPercent: formatPercent, normalizeProvider: normalizeProvider }
  if (require.main === module) {
    selfCheck()
    console.log("Usage.js self-check passed")
  }
}
