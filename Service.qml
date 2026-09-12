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
  property string lastError: ""
  property string output: ""
  property date lastUpdated: new Date(0)
  readonly property string collectorScript: decodeURIComponent(String(Qt.resolvedUrl("collector.sh")).replace(/^file:\/\//, ""))
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 300, 60, 3600)

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
    lastError = ""
    collector.command = ["bash", root.collectorScript]
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
  Timer {
    interval: 30000
    repeat: true
    running: root.refreshing
    onTriggered: {
      collector.running = false
      root.refreshing = false
      root.lastError = "Collector timed out"
    }
  }
  Process {
    id: collector
    command: []
    stdout: StdioCollector {
      id: collectorOutput
      waitForEnd: true
      onStreamFinished: root.output = text
    }
    stderr: StdioCollector { id: collectorStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      if (exitCode !== 0) {
        var detail = String(collectorStderr.text || "").replace(/\s+/g, " ").trim()
        root.lastError = detail ? detail.slice(0, 180) : ("Collector failed (exit " + exitCode + ")")
        return
      }
      var parsed = Model.parseCollector(collectorOutput.text || "")
      if (!parsed.ok) { root.lastError = parsed.error; return }
      root.providers = parsed.data.providers
      root.go = parsed.data.go
      root.recentDays = parsed.data.recentDays
      root.lastError = parsed.data.error
      root.lastUpdated = new Date()
    }
  }
}
