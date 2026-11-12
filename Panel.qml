import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Deco Monitor: home-network speed and device count in the bar, read from
// $XDG_RUNTIME_DIR/deco-monitor/status.json, which the deco-monitor user
// service (`deco watch`) rewrites every few seconds. The widget never talks
// to the Deco itself, so it adds no load and never fights the service for
// the Deco's single login session.
//
// All Text pins PlainText: device names come from the network.
Panel {
  id: root
  moduleName: "hell0world.deco-monitor"
  ipcTarget: "hell0world.deco-monitor"

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ---------------------------------------------------------------- settings
  readonly property bool showSpeed: setting("showSpeed", true) !== false
  readonly property bool showCount: setting("showCount", true) !== false

  // ------------------------------------------------------------------ state
  property bool ok: false
  property string error: ""
  property bool haveData: false
  property bool stale: false
  property real down: 0          // kbit/s
  property real up: 0
  property int deviceCount: 0
  property var devices: []
  property var decos: []
  property var history: []       // [[down, up], ...]
  property int decoCpu: -1
  property int decoMem: -1
  property real pollInterval: 3

  readonly property string statusPath: Quickshell.env("XDG_RUNTIME_DIR") + "/deco-monitor/status.json"

  function str(v, max) { return String(v === undefined || v === null ? "" : v).substring(0, max || 64) }
  function num(v) { var n = Number(v); return isFinite(n) && n >= 0 ? n : 0 }

  function apply(txt) {
    var d
    try { d = JSON.parse(txt) } catch (e) { return }
    if (!d || typeof d !== "object") return
    ok = d.ok === true
    error = str(d.error, 200)
    var t = num(d.time)
    pollInterval = Math.max(2, Math.min(60, num(d.interval) || 3))
    stale = t > 0 && (Date.now() / 1000 - t) > Math.max(30, pollInterval * 6)
    if (!ok) return

    down = num(d.down_kbps)
    up = num(d.up_kbps)
    var cl = Array.isArray(d.clients) ? d.clients.slice(0, 200) : []
    deviceCount = cl.filter(function(c) { return c && c.online !== false }).length
    devices = cl.slice(0, 8).map(function(c) {
      return { name: str(c.name, 40), ip: str(c.ip, 40), conn: str(c.connection, 16),
               down: num(c.down_kbps), up: num(c.up_kbps), isNew: c["new"] === true }
    })
    var ns = Array.isArray(d.nodes) ? d.nodes.slice(0, 16) : []
    decos = ns.map(function(n) {
      return { name: str(n.name, 32), model: str(n.model, 24), main: n.role === "master",
               online: n.online !== false, internet: n.internet !== false }
    })
    var h = Array.isArray(d.history) ? d.history.slice(-120) : []
    history = h.map(function(p) { return Array.isArray(p) ? [num(p[0]), num(p[1])] : [0, 0] })
    var p = d.perf || {}
    decoCpu = p.cpu === undefined ? -1 : Math.min(100, num(p.cpu))
    decoMem = p.mem === undefined ? -1 : Math.min(100, num(p.mem))
    haveData = true
  }

  FileView {
    id: statusFile
    path: root.statusPath
    printErrors: false
    blockLoading: false
    onLoaded: root.apply(text())
    onLoadFailed: function(err) { root.ok = false; root.error = ""; root.stale = true }
  }
  // The service replaces the file atomically; a plain reload is the most
  // reliable way to follow that (inotify watches die with the old inode).
  Timer {
    interval: Math.round(root.pollInterval * 1000)
    repeat: true
    running: true
    onTriggered: statusFile.reload()
  }

  function speed(kbps) {
    if (kbps >= 1e6) return strings.t("unit.gbps").arg(I18n.formatNumber(kbps / 1e6, 2))
    if (kbps >= 1000) return strings.t("unit.mbps").arg(I18n.formatNumber(kbps / 1000, kbps >= 1e5 ? 0 : 1))
    return strings.t("unit.kbps").arg(I18n.formatNumber(kbps, 0))
  }
  // compact form for the bar: "12.3M", "850K"
  function short(kbps) {
    if (kbps >= 1e5) return I18n.formatNumber(kbps / 1000, 0) + "M"
    if (kbps >= 1000) return I18n.formatNumber(kbps / 1000, 1) + "M"
    return I18n.formatNumber(kbps, 0) + "K"
  }

  readonly property bool healthy: ok && !stale && haveData

  // ----------------------------------------------------------------- bar
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property string glyph: String.fromCodePoint(healthy ? 0xF06F3 : 0xF0B5F)   // nf-md-router_wireless / router_wireless_off
  readonly property string barText: {
    if (!healthy) return haveData || error ? strings.t("bar.offline") : "…"
    var parts = []
    if (showSpeed) parts.push(strings.t("bar.speed").arg(short(down)).arg(short(up)))
    if (showCount) parts.push(String(deviceCount))
    return parts.join("  ")
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: vertical ? 0 : content.implicitWidth

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: true
    fixedWidth: root.vertical ? -1 : Math.round(content.implicitWidth + Style.bar.iconSlot - Style.bar.iconCanvas)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1
    active: !root.healthy && (root.haveData || root.error !== "")
    tooltipText: root.healthy
      ? strings.t("tooltip").arg(root.speed(root.down)).arg(root.speed(root.up)).arg(strings.tn("bar.devices", root.deviceCount).arg(root.deviceCount))
      : (root.error ? strings.t("tooltip.error").arg(root.error) : strings.t("tooltip.noservice"))
    onPressed: function(b) { root.toggle() }

    Row {
      id: content
      anchors.centerIn: parent
      spacing: root.vertical ? 0 : Style.space(4)

      OpticalGlyph {
        anchors.verticalCenter: parent.verticalCenter
        width: Style.bar.iconCanvas
        height: Style.bar.iconCanvas
        text: root.glyph
        fontFamily: button.fontFamily
        fontSize: Style.bar.iconFont
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }

      Text {
        textFormat: Text.PlainText
        anchors.verticalCenter: parent.verticalCenter
        visible: !root.vertical && text !== ""
        text: root.barText
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: button.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.features: { "tnum": 1 }
        renderType: Text.NativeRendering
      }
    }
  }

  // ----------------------------------------------------------------- panel
  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property color urgent: root.bar ? root.bar.urgent : Color.accent
  readonly property string fontName: root.bar ? root.bar.fontFamily : Style.font.family

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(410))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // Hero: total download, upload + device count, open-app button
        Item {
          width: parent.width
          implicitHeight: Math.max(heroNumber.implicitHeight, heroLabels.implicitHeight)

          Text {
            id: heroNumber
            textFormat: Text.PlainText
            text: root.healthy ? root.speed(root.down) : "—"
            color: root.fg
            font.family: root.fontName
            font.pixelSize: Style.font.display
            font.bold: true
            font.features: { "tnum": 1 }
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroNumber.right
            anchors.leftMargin: Style.space(14)
            anchors.right: appButton.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: strings.t("hero.label")
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fontName
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
            }
            Text {
              textFormat: Text.PlainText
              text: strings.t("hero.sub").arg(root.speed(root.up)).arg(strings.tn("bar.devices", root.deviceCount).arg(root.deviceCount))
              color: root.fg
              opacity: 0.7
              font.family: root.fontName
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
              width: parent.width
            }
          }

          PanelActionButton {
            id: appButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: String.fromCodePoint(0xF0379)   // nf-md-monitor_dashboard
            tooltipText: strings.t("action.app")
            foreground: root.fg
            fontFamily: root.fontName
            onClicked: {
              root.close()
              Quickshell.execDetached(["sh", "-c", "command -v decomon >/dev/null && exec decomon"])
            }
          }
        }

        // Error card
        Column {
          visible: !root.healthy
          width: parent.width
          spacing: Style.space(4)
          Text {
            textFormat: Text.PlainText
            text: strings.t("error.title")
            color: root.urgent
            font.family: root.fontName
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.Wrap
            text: root.error !== "" ? root.error : strings.t("error.service")
            color: root.fg
            opacity: 0.7
            font.family: root.fontName
            font.pixelSize: Style.font.bodySmall
          }
        }

        // Speed graph: download filled, upload as a line
        Rectangle {
          id: graphBox
          visible: root.haveData
          width: parent.width
          height: Style.space(72)
          radius: Style.space(6)
          color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.05)
          border.width: 1
          border.color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
          clip: true

          Canvas {
            id: graph
            anchors.fill: parent
            anchors.margins: 1
            readonly property var points: root.history
            onPointsChanged: if (root.opened) requestPaint()
            onWidthChanged: requestPaint()
            Connections { target: root; function onOpenedChanged() { if (root.opened) graph.requestPaint() } }

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var pts = points, n = pts.length
              if (n < 2) return
              var peak = 1000
              for (var k = 0; k < n; k++) peak = Math.max(peak, pts[k][0], pts[k][1])
              peak *= 1.1
              var step = width / 119
              var x0 = width - (n - 1) * step
              function y(v) { return height - 2 - (height - 4) * v / peak }
              var c = root.fg

              ctx.beginPath()
              ctx.moveTo(x0, height)
              for (var i = 0; i < n; i++) ctx.lineTo(x0 + i * step, y(pts[i][0]))
              ctx.lineTo(width, height)
              ctx.closePath()
              ctx.fillStyle = Qt.rgba(c.r, c.g, c.b, 0.15)
              ctx.fill()

              ctx.beginPath()
              for (var j = 0; j < n; j++) {
                if (j === 0) ctx.moveTo(x0, y(pts[0][0])); else ctx.lineTo(x0 + j * step, y(pts[j][0]))
              }
              ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, 0.85)
              ctx.lineWidth = 1.5
              ctx.stroke()

              ctx.beginPath()
              for (var u = 0; u < n; u++) {
                if (u === 0) ctx.moveTo(x0, y(pts[0][1])); else ctx.lineTo(x0 + u * step, y(pts[u][1]))
              }
              ctx.strokeStyle = Qt.rgba(c.r, c.g, c.b, 0.4)
              ctx.setLineDash([3, 3])
              ctx.lineWidth = 1
              ctx.stroke()
            }
          }

          Text {
            textFormat: Text.PlainText
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(6)
            text: strings.t("graph.window").arg(Math.max(1, Math.round(120 * root.pollInterval / 60)))
            color: root.fg
            opacity: 0.45
            font.family: root.fontName
            font.pixelSize: Style.font.caption
          }
        }

        // Deco units
        PanelSectionHeader {
          visible: root.decos.length > 0
          text: strings.t("section.decos")
          foreground: root.fg
          fontFamily: root.fontName
        }
        Column {
          visible: root.decos.length > 0
          width: parent.width
          spacing: Style.spacing.labelGap

          Repeater {
            model: root.decos
            delegate: Item {
              required property var modelData
              width: parent.width
              implicitHeight: decoName.implicitHeight
              Text {
                id: decoName
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: decoState.left
                anchors.rightMargin: Style.space(8)
                text: modelData.main ? strings.t("deco.main").arg(modelData.name) : modelData.name
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                id: decoState
                textFormat: Text.PlainText
                anchors.right: parent.right
                readonly property bool bad: !modelData.online || !modelData.internet
                text: !modelData.online ? strings.t("deco.offline")
                      : !modelData.internet ? strings.t("deco.nointernet") : strings.t("deco.online")
                color: bad ? root.urgent : root.fg
                opacity: bad ? 1 : 0.6
                font.family: root.fontName
                font.pixelSize: Style.font.bodySmall
                font.bold: bad
              }
            }
          }
          Text {
            visible: root.decoCpu >= 0
            textFormat: Text.PlainText
            text: strings.t("deco.load").arg(root.decoCpu).arg(root.decoMem)
            color: root.fg
            opacity: 0.45
            font.family: root.fontName
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { visible: root.devices.length > 0; width: parent.width; foreground: root.fg }

        PanelSectionHeader {
          visible: root.devices.length > 0
          text: strings.t("section.devices")
          foreground: root.fg
          fontFamily: root.fontName
        }

        Column {
          width: parent.width
          spacing: Style.spacing.labelGap

          Text {
            visible: !root.haveData && root.healthy
            textFormat: Text.PlainText
            text: strings.t("empty")
            color: root.fg
            opacity: 0.5
            font.family: root.fontName
            font.pixelSize: Style.font.bodySmall
          }

          Repeater {
            model: root.devices
            delegate: Item {
              required property var modelData
              width: parent.width
              implicitHeight: devName.implicitHeight

              Text {
                id: devName
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: newTag.visible ? newTag.left : devConn.left
                anchors.rightMargin: Style.space(6)
                text: modelData.name
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideRight
              }
              Text {
                id: newTag
                visible: modelData.isNew
                textFormat: Text.PlainText
                anchors.right: devConn.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: devName.verticalCenter
                text: strings.t("device.new")
                color: root.urgent
                font.family: root.fontName
                font.pixelSize: Style.font.caption
                font.bold: true
              }
              Text {
                id: devConn
                textFormat: Text.PlainText
                anchors.right: devSpeed.left
                anchors.rightMargin: Style.space(10)
                width: Style.space(56)
                horizontalAlignment: Text.AlignRight
                text: modelData.conn
                color: root.fg
                opacity: 0.5
                font.family: root.fontName
                font.pixelSize: Style.font.caption
              }
              Text {
                id: devSpeed
                textFormat: Text.PlainText
                anchors.right: parent.right
                width: Style.space(84)
                horizontalAlignment: Text.AlignRight
                text: "↓" + root.short(modelData.down) + " ↑" + root.short(modelData.up)
                color: root.fg
                font.family: root.fontName
                font.pixelSize: Style.font.bodySmall
                font.bold: modelData.down + modelData.up >= 1000
                font.features: { "tnum": 1 }
              }
            }
          }
        }
      }
    }
  }
}
