import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "io.github.thespd.opencode-tracker"
  ipcTarget: "io.github.thespd.opencode-tracker"

  property double nowMs: Date.now()
  property string expandedProviderId: ""
  readonly property int dayCount: Math.max(1, service.recentDays.length)
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.35)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property bool alarming: service.go ? Model.behindPace(
    Model.normalizeWindow(service.go.weekly, "weekly", nowMs), nowMs) : false
  readonly property int modelCount: {
    var total = 0
    var list = service.providers || []
    for (var i = 0; i < list.length; i++) {
      var models = list[i] && list[i].modelList
      if (models) total += models.length
    }
    return total
  }
  readonly property var statTiles: [
    { value: Model.tokenCount(Model.weekTotal(service.providers)), label: "TOKENS · 7D" },
    { value: Model.dollars(Model.weekCost(service.providers)), label: "COST · 7D" },
    { value: String(root.modelCount), label: root.modelCount === 1 ? "MODEL" : "MODELS" }
  ]

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function refresh() {
    nowMs = Date.now()
    service.refresh()
  }

  onOpenedChanged: if (opened) {
    nowMs = Date.now()
    if (service.lastUpdated.getTime() === 0 || (Date.now() - service.lastUpdated.getTime()) > service.refreshIntervalSec * 1000) root.refresh()
    Qt.callLater(function() { catcher.forceActiveFocus() })
  }

  Service {
    id: service
    settings: root.settings
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.nowMs = Date.now()
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: " "
    fixedWidth: vertical ? -1 : content.implicitWidth + Style.space(16)
    tooltipText: "OpenCode provider usage · click for details" + (service.lastError ? "\n" + service.lastError : "")
    active: root.alarming
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton || buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: Style.space(6)

      Rectangle {
        id: statusDot
        visible: !(bar ? bar.vertical : false)
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(6)
        height: Style.space(6)
        radius: width / 2
        color: root.alarming ? root.urgent : root.foreground
        opacity: root.alarming ? 1 : 0.55

        SequentialAnimation on opacity {
          id: dotPulse
          loops: Animation.Infinite
          running: service.refreshing
          NumberAnimation { to: 0.25; duration: 450; easing.type: Easing.InOutQuad }
          NumberAnimation { to: 1; duration: 450; easing.type: Easing.InOutQuad }
          onRunningChanged: if (!running) statusDot.opacity = root.alarming ? 1 : 0.55
        }
      }

      Image {
        id: logo
        anchors.verticalCenter: parent.verticalCenter
        source: "opencode.svg"
        width: Style.space(16)
        height: Style.space(16)
        fillMode: Image.PreserveAspectFit
        mipmap: true
        visible: false
      }

      MultiEffect {
        anchors.fill: logo
        source: logo
        colorization: 1.0
        colorizationColor: root.alarming ? root.urgent : root.foreground
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: catcher
    contentWidth: panel.fittedContentWidth(Style.space(520))
    contentHeight: panel.fittedContentHeight(body.implicitHeight, Style.space(650))

    PanelKeyCatcher {
      id: catcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTextKey: function(text) { if (text === "r" || text === "R") root.refresh() }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scroll
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: body.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scroll.contentItem
          property: "interactive"
          value: body.implicitHeight > scroll.height
        }

        Column {
          id: body
          width: scroll.availableWidth
          spacing: Style.space(10)
          opacity: root.opened ? 1 : 0

          Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

          PanelHero {
            width: parent.width
            title: "OpenCode Usage"
            meta: service.providers.length
              ? service.providers.length + " provider" + (service.providers.length === 1 ? "" : "s") + " · " + Model.tokenCount(Model.weekTotal(service.providers)) + " tokens this week"
              : "Waiting for usage data"
            detail: service.refreshing ? "Refreshing…" : ("Updated " + (service.lastUpdated.getTime() === 0 ? "never" : Qt.formatTime(service.lastUpdated, "HH:mm:ss")))
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: service.lastError !== ""
            width: parent.width
            text: service.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            visible: service.refreshing && !service.providers.length
            width: parent.width
            text: "Loading usage…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Column {
            visible: !service.refreshing && service.providers.length === 0
            width: parent.width
            spacing: Style.space(4)

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "No usage in the last 7 days"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: "Run something with OpenCode and it will show up here"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Row {
            id: tilesRow
            visible: service.providers.length > 0
            width: parent.width
            spacing: Style.space(8)

            Repeater {
              model: root.statTiles

              delegate: Rectangle {
                required property var modelData
                width: (tilesRow.width - Style.space(16)) / 3
                implicitHeight: tileCol.implicitHeight + Style.space(16)
                radius: Style.space(10)
                color: Style.normalFill

                Column {
                  id: tileCol
                  width: parent.width - Style.space(16)
                  anchors.horizontalCenter: parent.horizontalCenter
                  y: Style.space(8)
                  spacing: Style.space(2)

                  Text {
                    width: parent.width
                    text: modelData.value
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.heading
                    font.bold: true
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    text: modelData.label
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    elide: Text.ElideRight
                  }
                }
              }
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground; visible: service.providers.length > 0 }

          PanelSectionHeader {
            visible: service.providers.length > 0
            text: "PROVIDERS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: service.providers

            delegate: ProviderCard {
              width: body.width
            }
          }

          PanelSectionHeader {
            visible: service.providers.length > 0
            text: "RECENT USAGE · " + Model.tokenCount(Model.recentTotal(service.recentDays)) + " TOKENS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Canvas {
            id: spark
            visible: service.providers.length > 0
            width: parent.width
            height: Style.space(72)
            antialiasing: true
            property var values: service.recentDays.map(function(day) { return Model.dayTokens(day) })
            property int peak: Model.recentPeak(service.recentDays)
            onValuesChanged: requestPaint()
            onPeakChanged: requestPaint()
            onWidthChanged: requestPaint()
            onHeightChanged: requestPaint()
            onPaint: {
              var ctx = getContext("2d")
              ctx.clearRect(0, 0, width, height)
              var vals = values || []
              var n = vals.length
              if (n === 0) return
              var top = Math.max(1, spark.peak)
              var pad = Style.space(8)
              var base = height - Style.space(4)
              function px(i) { return n === 1 ? width / 2 : pad + i * (width - 2 * pad) / (n - 1) }
              function py(v) { return base - Style.space(4) - (v / top) * (base - 2 * pad) }
              ctx.beginPath()
              ctx.moveTo(px(0), py(vals[0]))
              for (var i = 1; i < n; i++) {
                var mx = (px(i - 1) + px(i)) / 2
                var my = (py(vals[i - 1]) + py(vals[i])) / 2
                ctx.quadraticCurveTo(px(i - 1), py(vals[i - 1]), mx, my)
              }
              ctx.lineTo(px(n - 1), py(vals[n - 1]))
              var fill = ctx.createLinearGradient(0, 0, 0, base)
              var fc = root.foreground
              fill.addColorStop(0, Qt.rgba(fc.r, fc.g, fc.b, 0.30))
              fill.addColorStop(1, Qt.rgba(fc.r, fc.g, fc.b, 0.0))
              ctx.save()
              ctx.lineTo(px(n - 1), base)
              ctx.lineTo(px(0), base)
              ctx.closePath()
              ctx.fillStyle = fill
              ctx.fill()
              ctx.restore()
              ctx.beginPath()
              ctx.moveTo(px(0), py(vals[0]))
              for (var j = 1; j < n; j++) {
                var nx = (px(j - 1) + px(j)) / 2
                var ny = (py(vals[j - 1]) + py(vals[j])) / 2
                ctx.quadraticCurveTo(px(j - 1), py(vals[j - 1]), nx, ny)
              }
              ctx.lineTo(px(n - 1), py(vals[n - 1]))
              ctx.lineWidth = 2
              ctx.strokeStyle = Qt.rgba(fc.r, fc.g, fc.b, 1)
              ctx.stroke()
              var peakIdx = 0
              for (var k = 1; k < n; k++) if (vals[k] > vals[peakIdx]) peakIdx = k
              for (var m = 0; m < n; m++) {
                ctx.beginPath()
                if (m === peakIdx && spark.peak > 0) {
                  ctx.arc(px(m), py(vals[m]), 4, 0, 2 * Math.PI)
                  ctx.fillStyle = root.alarming ? Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 1) : Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 1)
                } else {
                  ctx.arc(px(m), py(vals[m]), 2.5, 0, 2 * Math.PI)
                  ctx.fillStyle = Qt.rgba(fc.r, fc.g, fc.b, 0.85)
                }
                ctx.fill()
              }
            }
          }

          Row {
            visible: service.providers.length > 0
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: service.recentDays

              delegate: Column {
                required property var modelData
                required property int index
                width: (body.width - Style.space(24)) / root.dayCount
                spacing: 0

                Text {
                  width: parent.width
                  text: Model.dayLabel(modelData.date)
                  color: index === service.recentDays.length - 1 ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: index === service.recentDays.length - 1
                  horizontalAlignment: Text.AlignHCenter
                }

                Text {
                  width: parent.width
                  text: Model.dayTokens(modelData) > 0 ? Model.tokenCount(Model.dayTokens(modelData)) : "·"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  horizontalAlignment: Text.AlignHCenter
                  elide: Text.ElideRight
                }
              }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foreground
            visible: !!service.go
          }

          GoSection {
            width: body.width
            visible: !!service.go
          }

          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "R refresh · right-click refresh now · click a provider to expand"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component Pill: Rectangle {
    required property string text
    property color tint: root.foreground
    implicitWidth: pillText.implicitWidth + Style.space(14)
    implicitHeight: pillText.implicitHeight + Style.space(6)
    radius: implicitHeight / 2
    color: Util.alpha(tint, 0.14)

    Text {
      id: pillText
      anchors.centerIn: parent
      text: parent.text
      color: parent.tint
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  component ModelRow: Row {
    required property var modelData
    readonly property var series: Model.alignedSeries(modelData.daily, Model.datesOf(service.recentDays))

    Text {
      width: Math.max(0, breakdownCol.width - Style.space(root.dayCount * 44))
      text: (modelData.modelName || "?") + " · " + Model.tokenCount(modelData.tokensWeek)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Repeater {
      model: series

      Text {
        width: Style.space(44)
        text: numberValue > 0 ? Model.tokenCount(numberValue) : "·"
        color: numberValue > 0 ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        horizontalAlignment: Text.AlignRight
        elide: Text.ElideRight
        readonly property double numberValue: modelData
      }
    }
  }

  component ProviderCard: Rectangle {
    id: providerCard
    required property var modelData
    required property int index
    readonly property var provider: modelData || {}
    readonly property bool expanded: root.expandedProviderId === provider.pid
    readonly property real share: Model.providerWeekShare(provider, service.providers)
    readonly property int topN: 3
    property bool showAllModels: false
    readonly property var sortedModels: {
      var list = ((provider && provider.modelList) || []).slice()
      list.sort(function(a, b) { return ((b && b.tokensWeek) || 0) - ((a && a.tokensWeek) || 0) })
      return list
    }
    readonly property var topModels: sortedModels.slice(0, providerCard.topN)
    readonly property var restModels: sortedModels.slice(providerCard.topN)
    width: body.width
    implicitHeight: cardInner.implicitHeight + Style.space(20)
    radius: Style.space(10)
    color: headerHover.containsMouse || providerCard.expanded ? Style.hoverFill : "transparent"
    opacity: root.opened ? 1 : 0

    Behavior on color { ColorAnimation { duration: 140 } }
    Behavior on opacity {
      SequentialAnimation {
        PauseAnimation { duration: providerCard.index * 70 }
        NumberAnimation { duration: 240; easing.type: Easing.OutCubic }
      }
    }

    Column {
      id: cardInner
      anchors.fill: parent
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      Item {
        width: parent.width
        implicitHeight: headerCol.implicitHeight

        MouseArea {
          id: headerHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: provider.modelList && provider.modelList.length > 0 ? Qt.PointingHandCursor : Qt.ArrowCursor
          onClicked: {
            if (providerCard.expanded) {
              root.expandedProviderId = ""
              providerCard.showAllModels = false
            } else {
              root.expandedProviderId = provider.pid
            }
          }
        }

        Column {
          id: headerCol
          width: parent.width
          spacing: Style.space(6)

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Text {
              text: "▸"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              rotation: providerCard.expanded ? 90 : 0

              Behavior on rotation { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
            }

            Text {
              Layout.fillWidth: true
              text: Model.label(provider.pid)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              elide: Text.ElideRight
            }

            Pill {
              text: Model.dollars(Model.providerCost(provider, true)) + " / 7D"
              tint: root.foreground
            }
          }

          Text {
            width: parent.width
            text: Model.tokenCount(Model.providerTokens(provider, true)) + " tokens · 7d"
              + "   ·   " + Model.tokenCount(Model.providerTokens(provider, false)) + " · 30d"
              + (provider.hasKey ? "" : "   ·   local data")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Rectangle {
            width: parent.width
            height: Style.space(6)
            radius: height / 2
            color: Util.alpha(root.foreground, 0.14)

            Rectangle {
              // Minimum fill so low-volume providers (e.g. 19K vs 479M tokens) stay visible.
              width: parent.width * (providerCard.share > 0 ? Math.max(providerCard.share, 0.025) : 0)
              height: parent.height
              radius: parent.radius
              gradient: Gradient {
                orientation: Gradient.Horizontal
                GradientStop { position: 0; color: Qt.lighter(root.foreground, 1.3) }
                GradientStop { position: 1; color: root.foreground }
              }

              Behavior on width { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
            }
          }
        }
      }

      Item {
        width: parent.width
        height: providerCard.expanded ? breakdownCol.implicitHeight : 0
        clip: true
        opacity: providerCard.expanded ? 1 : 0

        Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        Behavior on opacity { NumberAnimation { duration: 200 } }

        Column {
          id: breakdownCol
          width: parent.width
          spacing: Style.space(5)

          Row {
            width: parent.width
            visible: provider.modelList && provider.modelList.length > 0

            Text {
              width: Math.max(0, parent.width - Style.space(root.dayCount * 44))
              elide: Text.ElideRight
              text: "MODEL"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Repeater {
              model: Model.datesOf(service.recentDays)

              Text {
                width: Style.space(44)
                text: Model.dayLabel(modelData)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                horizontalAlignment: Text.AlignRight
              }
            }
          }

          Repeater {
            model: providerCard.topModels

            delegate: ModelRow {
              width: breakdownCol.width
            }
          }

          Item {
            visible: providerCard.restModels.length > 0
            width: parent.width
            height: providerCard.showAllModels ? restCol.implicitHeight : 0
            clip: true
            opacity: providerCard.showAllModels ? 1 : 0

            Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
            Behavior on opacity { NumberAnimation { duration: 180 } }

            Column {
              id: restCol
              width: parent.width
              spacing: Style.space(5)

              Repeater {
                model: providerCard.restModels

                delegate: ModelRow {
                  width: restCol.width
                }
              }
            }
          }

          Item {
            visible: providerCard.restModels.length > 0
            width: parent.width
            implicitHeight: toggleLabel.implicitHeight + Style.space(4)

            MouseArea {
              id: toggleHover
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: providerCard.showAllModels = !providerCard.showAllModels
            }

            Text {
              id: toggleLabel
              anchors.centerIn: parent
              text: providerCard.showAllModels ? "Show less ▴" : "Show " + providerCard.restModels.length + " more ▾"
              color: toggleHover.containsMouse ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true

              Behavior on color { ColorAnimation { duration: 120 } }
            }
          }

          Text {
            visible: !(provider.modelList && provider.modelList.length > 0)
            width: parent.width
            text: "No usage in the last 7 days"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  component GoSection: Column {
    id: goSection
    spacing: Style.space(8)

    readonly property var windows: [
      { key: "rolling", label: "5H", dollars: 12 },
      { key: "weekly", label: "WEEK", dollars: 30 },
      { key: "monthly", label: "MONTH", dollars: 60 }
    ]

    Text {
      width: parent.width
      text: "OpenCode Go limits"
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.subtitle
      font.bold: true
    }

    Repeater {
      model: goSection.windows

      delegate: Column {
        id: windowRow
        required property var modelData
        width: goSection.width
        spacing: Style.space(4)
        readonly property var w: Model.normalizeWindow(service.go ? service.go[modelData.key] : null, modelData.key, root.nowMs)
        readonly property bool isBehind: modelData.key === "weekly" && Model.behindPace(windowRow.w, root.nowMs)

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Pill {
            text: modelData.label
            tint: windowRow.isBehind ? root.urgent : Color.accent
          }

          Item { Layout.fillWidth: true }

          Text {
            text: windowRow.w
              ? Model.percent(windowRow.w.percent)
              : (service.go && service.go.status && service.go.status !== "ok" ? service.go.status : "—")
            color: windowRow.isBehind ? root.urgent : root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }

          Text {
            text: windowRow.w ? Model.dollars(windowRow.w.limitDollars || modelData.dollars) : ""
            visible: text !== ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          width: parent.width
          height: Style.space(6)
          radius: height / 2
          color: Util.alpha(root.foreground, 0.14)

          Rectangle {
            id: goFill
            width: parent.width * (windowRow.w ? windowRow.w.percent : 0)
            height: parent.height
            radius: parent.radius
            gradient: Gradient {
              orientation: Gradient.Horizontal
              GradientStop { position: 0; color: windowRow.isBehind ? Qt.lighter(root.urgent, 1.2) : Qt.lighter(Color.accent, 1.15) }
              GradientStop { position: 1; color: windowRow.isBehind ? root.urgent : Color.accent }
            }

            Behavior on width { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: root.opened && windowRow.isBehind && !!windowRow.w
              NumberAnimation { to: 0.55; duration: 700; easing.type: Easing.InOutQuad }
              NumberAnimation { to: 1; duration: 700; easing.type: Easing.InOutQuad }
              onRunningChanged: if (!running) goFill.opacity = 1
            }
          }
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            visible: !!windowRow.w
            text: windowRow.w ? "resets " + Model.countdown(windowRow.w.resetMs, root.nowMs) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Item { width: Style.space(1); height: 1 }

          Pill {
            visible: modelData.key === "weekly" && !!windowRow.w
            text: Model.paceText(windowRow.w, root.nowMs)
            tint: windowRow.isBehind ? root.urgent : root.foreground
          }
        }
      }
    }
  }
}
