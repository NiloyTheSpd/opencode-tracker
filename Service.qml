import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

Item {
  id: root
  property var settings: ({})
  property var providers: []
  property var go: null
  property var recentDays: []
  property bool refreshing: false
  property bool collectorTimedOut: false
  property string lastError: ""
  property string output: ""
  property date lastUpdated: new Date(0)
  readonly property string collectorScript: decodeURIComponent(String(Qt.resolvedUrl("collector.sh")).replace(/^file:\/\//, ""))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 60, 3600)
  // Marketplace hardening: absolute interpreter chain (no PATH lookup) and a
  // byte ceiling shared with collector.sh's COLLECTOR_MAX_BYTES.
  readonly property string bashBin: "/usr/bin/bash"
  readonly property string setsidBin: "/usr/bin/setsid"
  readonly property int maxCollectorBytes: 262144

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }
  function refresh() {
    if (refreshing || collector.running) return
    refreshing = true
    collectorTimedOut = false
    collectorKillGrace.stop()
    lastError = ""
    // setsid makes the collector lead its own process group so its
    // TERM trap can stop the whole tree; --noprofile --norc isolates bash.
    collector.command = [root.setsidBin, root.bashBin, "--noprofile", "--norc", root.collectorScript]
    collector.running = true
  }
  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  // Safety net: a hung collector must never wedge the widget in "Refreshing…".
  // Stage 1 (30s): SIGTERM, which the collector traps to stop its whole
  // process group. Stage 2 (+5s): SIGKILL if anything lingers.
  Timer {
    interval: 30000
    repeat: true
    running: root.refreshing
    onTriggered: {
      root.collectorTimedOut = true
      collector.signal(15) // SIGTERM
      collectorKillGrace.restart()
    }
  }
  Timer {
    id: collectorKillGrace
    interval: 5000
    repeat: false
    onTriggered: {
      if (collector.running) collector.signal(9) // SIGKILL, last resort
      if (root.refreshing) {
        root.refreshing = false
        root.lastError = "Collector timed out"
      }
    }
  }
  Process {
    id: collector
    command: []
    // Closed allowlisted environment: HOME (+TZ for sqlite localtime) pass
    // through from the shell; PATH is pinned so shadowed binaries on the
    // user's PATH cannot intercept the collector. OPENCODE_* are the
    // documented test overrides; COLLECTOR_PG_LEADER arms the collector's
    // process-group teardown trap. Everything else (LD_PRELOAD, BASH_ENV…)
    // is stripped. stdin stays closed (stdinEnabled defaults to false).
    clearEnvironment: true
    environment: ({
      HOME: null,
      TZ: null,
      PATH: "/usr/bin:/bin",
      OPENCODE_AUTH_JSON: null,
      OPENCODE_DB: null,
      COLLECTOR_PG_LEADER: "1"
    })
    workingDirectory: "/"
    stdout: StdioCollector {
      id: collectorOutput
      waitForEnd: true
      onStreamFinished: root.output = String(text || "").slice(0, root.maxCollectorBytes)
    }
    stderr: StdioCollector { id: collectorStderr; waitForEnd: true }
    onExited: function(exitCode) {
      collectorKillGrace.stop()
      root.refreshing = false
      if (exitCode !== 0) {
        if (root.collectorTimedOut) {
          root.lastError = "Collector timed out"
        } else {
          var detail = String(collectorStderr.text || "").replace(/\s+/g, " ").trim()
          root.lastError = detail ? detail.slice(0, 180) : ("Collector failed (exit " + exitCode + ")")
        }
        root.collectorTimedOut = false
        return
      }
      root.collectorTimedOut = false
      var rawText = collectorOutput.text || ""
      if (rawText.length > root.maxCollectorBytes) {
        root.lastError = "Collector output too large"
        return
      }
      var parsed = Model.parseCollector(rawText)
      if (!parsed.ok) { root.lastError = parsed.error; return }
      root.providers = parsed.data.providers
      root.go = parsed.data.go
      root.recentDays = parsed.data.recentDays
      root.lastError = parsed.data.error
      root.lastUpdated = new Date()
    }
  }
}
