.pragma library

var ROLLING_MS = 5 * 60 * 60 * 1000
var WEEK_MS = 7 * 24 * 60 * 60 * 1000
var MONTHLY_MS = 30 * 24 * 60 * 60 * 1000

var PROVIDER_LABELS = {
  "opencode": "Zen",
  "opencode-go": "Go",
  "amazon-bedrock": "Bedrock",
  "openrouter": "OpenRouter"
}

function label(id) {
  var key = String(id || "")
  return PROVIDER_LABELS[key] || key || "Unknown"
}

function number(value, fallback) {
  var parsed = Number(value)
  return isFinite(parsed) ? parsed : fallback
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value))
}

function windowMs(kind) {
  if (kind === "rolling") return ROLLING_MS
  if (kind === "monthly") return MONTHLY_MS
  return WEEK_MS
}

function normalizeWindow(window, kind, nowMs) {
  if (!window) return null
  var percent = clamp(number(window.percent, 0) / 100, 0, 1)
  var resetMs = Date.parse(String(window.resetsAt || ""))
  if (!isFinite(resetMs)) resetMs = 0
  return {
    kind: String(kind || "weekly"),
    percent: percent,
    remaining: 1 - percent,
    resetMs: resetMs,
    limitDollars: number(window.limitDollars, 0)
  }
}

function expectedRemaining(window, nowMs) {
  if (!window || window.resetMs <= 0) return 0
  return clamp((window.resetMs - nowMs) / windowMs(window.kind), 0, 1)
}

function behindPace(window, nowMs) {
  if (!window || window.resetMs <= 0) return false
  return window.remaining + 0.0005 < expectedRemaining(window, nowMs)
}

function paceText(window, nowMs) {
  if (!window) return "No limit"
  var points = Math.round(Math.abs(window.remaining - expectedRemaining(window, nowMs)) * 100)
  if (points === 0) return "On pace"
  return points + "% " + (behindPace(window, nowMs) ? "behind pace" : "ahead of pace")
}

function parseCollector(text) {
  try {
    var parsed = JSON.parse(String(text || ""))
    if (!parsed || typeof parsed !== "object" || parsed.status !== "ok" || !Array.isArray(parsed.providers)) {
      return { ok: false, error: "Could not parse OpenCode usage" }
    }
    var go = parsed.go && typeof parsed.go === "object" ? parsed.go : null
    return {
      ok: true,
      data: {
        providers: parsed.providers,
        go: go ? {
          status: String(go.status || ""),
          rolling: go.rolling || null,
          weekly: go.weekly || null,
          monthly: go.monthly || null
        } : null,
        recentDays: Array.isArray(parsed.recentDays) ? parsed.recentDays : [],
        updatedAt: String(parsed.updatedAt || ""),
        error: go && go.status && go.status !== "ok" ? "Go: " + go.status : ""
      }
    }
  } catch (error) {
    return { ok: false, error: "Could not parse OpenCode usage" }
  }
}

function percent(value) {
  return Math.round(clamp(number(value, 0), 0, 1) * 100) + "%"
}

function dollars(value) {
  return "$" + number(value, 0).toFixed(2)
}

function countdown(resetMs, nowMs) {
  if (!resetMs || resetMs <= nowMs) return "now"
  var minutes = Math.max(0, Math.floor((resetMs - nowMs) / 60000))
  var days = Math.floor(minutes / 1440)
  var hours = Math.floor((minutes % 1440) / 60)
  var mins = minutes % 60
  if (days > 0) return days + "d " + hours + "h"
  if (hours > 0) return hours + "h " + mins + "m"
  return mins + "m"
}

function tokenCount(value) {
  var amount = Math.max(0, number(value, 0))
  if (amount >= 1000000) return (amount / 1000000).toFixed(amount >= 100000000 ? 0 : 1).replace(/\.0$/, "") + "M"
  if (amount >= 1000) return (amount / 1000).toFixed(amount >= 100000 ? 0 : 1).replace(/\.0$/, "") + "K"
  return String(Math.round(amount))
}

function dayTokens(day) {
  return Math.max(0, number(day && day.tokens, 0))
}

function dayCost(day) {
  return Math.max(0, number(day && day.cost, 0))
}

function providerTokens(provider, week) {
  return Math.max(0, number(provider && (week ? provider.tokensWeek : provider.tokensMonth), 0))
}

function providerCost(provider, week) {
  return Math.max(0, number(provider && (week ? provider.costWeek : provider.costMonth), 0))
}

function providerWeekShare(provider, providers) {
  var total = weekTotal(providers)
  return total > 0 ? clamp(providerTokens(provider, true) / total, 0, 1) : 0
}

// daily: [{date, tokens, cost}] from collector; dates: ["YYYY-MM-DD", ...]
// Returns token counts aligned to dates (missing days = 0).
function alignedSeries(daily, dates) {
  var map = {}
  var list = (daily && daily.length > 0) ? daily : []
  for (var i = 0; i < list.length; i++) {
    var day = list[i]
    map[String(day && day.date)] = dayTokens(day)
  }
  var out = []
  var keys = (dates && dates.length > 0) ? dates : []
  for (var j = 0; j < keys.length; j++) out.push(map[String(keys[j])] || 0)
  return out
}

function datesOf(days) {
  var list = (days && days.length > 0) ? days : []
  var out = []
  for (var i = 0; i < list.length; i++) out.push(String(list[i] && list[i].date))
  return out
}

function weekTotal(providers) {
  var list = (providers && providers.length > 0) ? providers : []
  var total = 0
  for (var i = 0; i < list.length; i++) total += providerTokens(list[i], true)
  return total
}

function weekCost(providers) {
  var list = (providers && providers.length > 0) ? providers : []
  var total = 0
  for (var i = 0; i < list.length; i++) total += providerCost(list[i], true)
  return total
}

function recentTotal(days) {
  var list = (days && days.length > 0) ? days : []
  var total = 0
  for (var i = 0; i < list.length; i++) total += dayTokens(list[i])
  return total
}

function recentPeak(days) {
  var list = (days && days.length > 0) ? days : []
  var peak = 0
  for (var i = 0; i < list.length; i++) peak = Math.max(peak, dayTokens(list[i]))
  return peak
}

// Tokens on the most recent day (recentDays is chronological, zero-filled).
function todayTokens(days) {
  var list = (days && days.length > 0) ? days : []
  return list.length > 0 ? dayTokens(list[list.length - 1]) : 0
}

function dayLabel(value) {
  var match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(value || ""))
  if (!match) return "—"
  var date = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][date.getDay()]
}

var exportsObject = {
  ROLLING_MS: ROLLING_MS,
  WEEK_MS: WEEK_MS,
  MONTHLY_MS: MONTHLY_MS,
  PROVIDER_LABELS: PROVIDER_LABELS,
  label: label,
  windowMs: windowMs,
  normalizeWindow: normalizeWindow,
  expectedRemaining: expectedRemaining,
  behindPace: behindPace,
  paceText: paceText,
  parseCollector: parseCollector,
  percent: percent,
  dollars: dollars,
  countdown: countdown,
  tokenCount: tokenCount,
  dayTokens: dayTokens,
  dayCost: dayCost,
  providerTokens: providerTokens,
  providerCost: providerCost,
  providerWeekShare: providerWeekShare,
  alignedSeries: alignedSeries,
  datesOf: datesOf,
  weekTotal: weekTotal,
  weekCost: weekCost,
  recentTotal: recentTotal,
  recentPeak: recentPeak,
  todayTokens: todayTokens,
  dayLabel: dayLabel
}

if (typeof module !== "undefined" && module.exports) module.exports = exportsObject
