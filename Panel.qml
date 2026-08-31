import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// WireGuard tunnels managed by NetworkManager: a bar icon (green while a
// tunnel is up) with a panel for switching tunnels, live transfer and exit-IP
// verification. Tunnels are discovered, not configured: every WireGuard
// connection profile NetworkManager knows is listed, so importing one with
// `nmcli connection import type wireguard file <name>.conf` is all it takes.
// The expected exit IP is the profile's peer endpoint — the public address a
// full-tunnel gateway gives you — and is only checked when it is an IP literal.
//
// One tunnel at a time by default (`exclusive`): bringing one up takes the
// others down first, because two full-tunnel gateways at once route each
// other's packets into the void. `defaultTunnel` is the one the power switch,
// a right-click on the icon and the IPC `on` call bring up: star a row (or
// press d while connected), or `omarchy bar set <id> defaultTunnel <name>`.
//
// Everything runs as the user: nmcli for profiles, state and up/down (allowed
// for the active local session by NetworkManager's default policy),
// /sys/class/net for byte counters, one HTTPS request to Cloudflare for the
// exit IP.
Panel {
  id: root
  moduleName: "io.github.selfcrypto.wireguard"
  ipcTarget: "io.github.selfcrypto.wireguard"
  manageIpc: false

  // Straight from NetworkManager: [{ name, active, iface, host, since }].
  property var tunnels: []
  property bool discovered: false
  readonly property bool exclusive: root.setting("exclusive", true) !== false
  readonly property var activeNames: {
    var out = []
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].active) out.push(tunnels[i].name)
    return out
  }
  readonly property string activeTunnel: activeNames.length ? activeNames[0] : ""
  readonly property bool connected: activeTunnel !== ""

  // Validated against the discovered profiles so a stale setting can never
  // leave the switch pointing at nothing; empty falls back to the first one.
  readonly property string defaultTunnel: {
    var want = String(root.setting("defaultTunnel", ""))
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].name === want) return want
    return tunnels.length ? tunnels[0].name : ""
  }
  // Default first, the rest in NetworkManager's order: the top row and "1"
  // are always the one that kicks in.
  readonly property var orderedTunnels: {
    var out = []
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].name === defaultTunnel) out.push(tunnels[i])
    for (var j = 0; j < tunnels.length; j++) if (tunnels[j].name !== defaultTunnel) out.push(tunnels[j])
    return out
  }
  property bool defaultSaving: false

  property bool busy: false
  property real rxBytes: -1
  property real txBytes: -1
  property real rxRate: 0
  property real txRate: 0
  property double lastSampleMs: 0
  property string publicIp: ""
  property bool ipChecking: false
  property int nowTick: 0

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color green: "#7dc383"
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property var activeInfo: {
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].name === activeTunnel) return tunnels[i]
    return null
  }
  readonly property double connSince: activeInfo ? activeInfo.since : 0
  readonly property bool hostIsIp: activeInfo !== null && /^\d{1,3}(\.\d{1,3}){3}$/.test(activeInfo.host)
  // The exit IP must be the gateway's address; anything else is wrong.
  readonly property bool ipMismatch: connected && publicIp !== "" && hostIsIp && publicIp !== activeInfo.host
  readonly property bool ipVerified: connected && publicIp !== "" && hostIsIp && publicIp === activeInfo.host
  readonly property string sinceText: {
    var t = nowTick
    if (!connected || !connSince) return ""
    var s = Math.max(0, Math.floor(Date.now() / 1000 - connSince))
    if (s < 90) return " · just now"
    var m = Math.floor(s / 60)
    if (m < 60) return " · " + m + " min"
    return " · " + Math.floor(m / 60) + " h " + (m % 60) + " min"
  }

  function fmtRate(b) {
    if (b < 1024) return Math.round(b) + " B/s"
    if (b < 1048576) return (b / 1024).toFixed(b < 102400 ? 1 : 0) + " KB/s"
    return (b / 1048576).toFixed(1) + " MB/s"
  }

  function fmtBytes(b) {
    if (b < 0) return "—"
    if (b < 1024) return Math.round(b) + " B"
    if (b < 1048576) return (b / 1024).toFixed(1) + " KB"
    if (b < 1073741824) return (b / 1048576).toFixed(1) + " MB"
    return (b / 1073741824).toFixed(2) + " GB"
  }

  function refresh() { if (!statusProc.running) statusProc.running = true }

  function resetLiveStats() {
    rxBytes = -1
    txBytes = -1
    rxRate = 0
    txRate = 0
    publicIp = ""
  }

  function sampleTraffic() {
    if (!connected || trafficProc.running) return
    var base = "/sys/class/net/" + activeInfo.iface + "/statistics/"
    trafficProc.command = ["sh", "-c", "cat \"$1\" \"$2\" 2>/dev/null", "_", base + "rx_bytes", base + "tx_bytes"]
    trafficProc.running = true
  }

  function checkIp() {
    if (ipProc.running) return
    ipChecking = true
    ipProc.running = true
  }

  function runAction(argv) {
    if (actionProc.running) return
    busy = true
    actionProc.command = argv
    actionProc.running = true
  }

  function knownTunnel(name) {
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].name === name) return true
    return false
  }

  // Names travel as arguments, never inside the script, so any profile name
  // NetworkManager accepts is safe here.
  function connectTo(name) {
    if (!knownTunnel(name) || name === activeTunnel) return
    var others = []
    if (exclusive) for (var i = 0; i < activeNames.length; i++) if (activeNames[i] !== name) others.push(activeNames[i])
    runAction(["sh", "-c",
      "target=$1; shift; for x in \"$@\"; do nmcli -w 10 connection down \"$x\" >/dev/null 2>&1; done; " +
      "nmcli -w 20 connection up \"$target\" >/dev/null 2>&1",
      "_", name].concat(others))
  }

  function disconnectFrom(name) {
    if (activeNames.indexOf(name) === -1) return
    runAction(["nmcli", "-w", "10", "connection", "down", name])
  }

  function disconnectAll() {
    if (!connected) return
    runAction(["sh", "-c", "for x in \"$@\"; do nmcli -w 10 connection down \"$x\" >/dev/null 2>&1; done", "_"].concat(activeNames))
  }

  function togglePower() { connected ? disconnectAll() : connectTo(defaultTunnel) }

  // Persist through the shell's own writer so shell.json stays canonical; the
  // bar then pushes the new `settings` into this widget live, which is what
  // flips `defaultTunnel` — no local state to keep in sync.
  function setDefault(name) {
    if (name === defaultTunnel || defaultProc.running || !knownTunnel(name)) return
    defaultSaving = true
    defaultProc.command = ["omarchy", "bar", "set", root.moduleName, "defaultTunnel", name]
    defaultProc.running = true
  }

  function tunnelsJson() {
    return JSON.stringify({ exclusive: exclusive, defaultTunnel: defaultTunnel, active: activeNames, tunnels: tunnels })
  }

  // One poll for everything: every WireGuard profile, whether it is active,
  // its interface (for the byte counters), its peer endpoint (expected exit
  // IP) and its last activation time.
  Process {
    id: statusProc
    command: ["sh", "-c",
      "nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2==\"wireguard\"{print $1}' | while IFS= read -r n; do " +
      "a=0; [ -n \"$(nmcli -t -f GENERAL.STATE connection show \"$n\" 2>/dev/null)\" ] && a=1; " +
      "i=$(nmcli -g connection.interface-name connection show \"$n\" 2>/dev/null); " +
      "e=$(nmcli -g wireguard.peers connection show \"$n\" 2>/dev/null | tr -d '\\\\' | sed -n 's/.*endpoint=\\([^: ]*\\):[0-9]*.*/\\1/p' | head -1); " +
      "t=$(nmcli -g connection.timestamp connection show \"$n\" 2>/dev/null); " +
      "printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"$n\" \"$a\" \"${i:-$n}\" \"$e\" \"${t:-0}\"; done"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).split("\n")
        var list = []
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].trim() === "") continue
          var p = lines[i].split("\t")
          list.push({ name: p[0], active: p[1] === "1", iface: p[2] || p[0], host: p[3] || "", since: Number(p[4] || 0) })
        }
        var previous = root.activeTunnel
        root.tunnels = list
        root.discovered = true
        if (root.activeTunnel !== previous) {
          root.resetLiveStats()
          if (root.opened) {
            root.sampleTraffic()
            root.checkIp()
          }
        }
        root.busy = false
      }
    }
  }

  Process {
    id: trafficProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var lines = String(text).trim().split("\n")
        if (lines.length < 2) return
        var rx = Number(lines[0])
        var tx = Number(lines[1])
        var now = Date.now()
        if (root.rxBytes >= 0 && now > root.lastSampleMs) {
          var dt = (now - root.lastSampleMs) / 1000
          root.rxRate = Math.max(0, (rx - root.rxBytes) / dt)
          root.txRate = Math.max(0, (tx - root.txBytes) / dt)
        }
        root.rxBytes = rx
        root.txBytes = tx
        root.lastSampleMs = now
      }
    }
  }

  Process {
    id: ipProc
    command: ["sh", "-c", "curl -4 -s -m 6 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p'"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.publicIp = String(text).trim()
        root.ipChecking = false
      }
    }
    onExited: root.ipChecking = false
  }

  Process {
    id: actionProc
    onExited: root.refresh()
  }

  Process {
    id: defaultProc
    onExited: root.defaultSaving = false
  }

  Timer {
    interval: Math.max(2, Number(root.setting("refreshIntervalSec", 3))) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.connected
    triggeredOnStart: true
    onTriggered: root.sampleTraffic()
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    onTriggered: root.nowTick++
  }

  // A poll that never exits would silently stop all refreshing; reap it.
  Timer {
    interval: 10000
    repeat: true
    running: true
    onTriggered: {
      if (statusProc.running) statusProc.running = false
      if (trafficProc.running) trafficProc.running = false
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
    function status(): string { return root.connected ? root.activeNames.join(",") : "disconnected" }
    function list(): string { return root.tunnelsJson() }
    function on(): string { if (!root.connected) root.connectTo(root.defaultTunnel); return "ok" }
    function off(): string { root.disconnectAll(); return "ok" }
    function up(name: string): string { if (!root.knownTunnel(name)) return "unknown tunnel: " + name; root.connectTo(name); return "ok" }
    function down(name: string): string { root.disconnectFrom(name); return "ok" }
    function defaultTunnel(): string { return root.defaultTunnel }
    function setDefault(name: string): string { root.setDefault(name); return root.defaultTunnel === name ? "ok" : (root.knownTunnel(name) ? "saving" : "unknown tunnel: " + name) }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    refresh()
    sampleTraffic()
    checkIp()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    active: root.connected
    activeColor: root.green
    tooltipText: root.connected
      ? "WireGuard: " + root.activeNames.join(", ")
      : (root.defaultTunnel !== ""
        ? "WireGuard: disconnected · right-click → " + root.defaultTunnel
        : "WireGuard: no profiles in NetworkManager")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePower()
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(460))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var n = parseInt(t, 10)
        if (t === "t" || t === "T") root.togglePower()
        else if (n >= 1 && n <= root.orderedTunnels.length) root.connectTo(root.orderedTunnels[n - 1].name)
        else if ((t === "d" || t === "D") && root.connected) root.setDefault(root.activeTunnel)
        else if (t === "r" || t === "R") { root.refresh(); root.checkIp() }
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "WireGuard"
          meta: root.connected
            ? "Connected to " + root.activeNames.join(", ") + root.sinceText
            : (root.busy ? "Working…" : "Disconnected")
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.connected ? 1.0 : 0.5
          iconComponent: Component {
            Text {
              text: "󰖂"
              color: root.connected ? root.green : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch
              checked: root.connected
              busy: root.busy
              interactive: root.tunnels.length > 0
              foreground: root.foreground
              onToggled: root.togglePower()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.connected ? "Disconnect" : "Connect to " + root.defaultTunnel
                fontFamily: root.fontFamily
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)

          PanelSectionHeader {
            text: "TUNNELS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.discovered && root.tunnels.length === 0
            text: "No WireGuard profiles in NetworkManager.\nnmcli connection import type wireguard file <name>.conf"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
            topPadding: Style.space(6)
            bottomPadding: Style.space(6)
          }

          Text {
            width: parent.width
            visible: !root.discovered
            text: "Looking for WireGuard profiles…"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            topPadding: Style.space(6)
          }

          Repeater {
            model: root.orderedTunnels
            delegate: Rectangle {
              id: row
              required property var modelData
              readonly property bool isActive: modelData.active
              readonly property bool isDefault: modelData.name === root.defaultTunnel
              // The star sits on top of rowMouse; count its hover too so the
              // highlight does not drop out while crossing it.
              readonly property bool hovered: rowMouse.containsMouse || starMouse.containsMouse
              width: column.width
              height: Style.space(44)
              radius: Style.cornerRadius
              color: row.hovered ? root.hoverFill : "transparent"

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: row.isActive ? root.disconnectFrom(row.modelData.name) : root.connectTo(row.modelData.name)
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Rectangle {
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  color: row.isActive ? root.green : "transparent"
                  border.width: row.isActive ? 0 : 1
                  border.color: root.dim
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0

                  Text {
                    text: row.modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    Layout.fillWidth: true
                    text: row.modelData.host !== "" ? row.modelData.host : "no endpoint"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  text: row.isActive ? "connected" : (row.hovered ? "switch" : "")
                  color: row.isActive ? root.green : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // ★ marks the default; clicking a hollow star makes that row
                // the default without touching the connection.
                Text {
                  id: star
                  text: row.isDefault ? "󰓎" : "󰓒"
                  color: row.isDefault ? root.green : (starMouse.containsMouse ? root.foreground : root.dim)
                  opacity: row.isDefault || starMouse.containsMouse ? 1.0 : 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body

                  MouseArea {
                    id: starMouse
                    anchors.fill: parent
                    anchors.margins: -Style.space(6)
                    hoverEnabled: true
                    cursorShape: row.isDefault ? Qt.ArrowCursor : Qt.PointingHandCursor
                    onClicked: root.setDefault(row.modelData.name)
                  }

                  PanelToolTip {
                    visible: starMouse.containsMouse
                    text: row.isDefault ? "Default tunnel" : (root.defaultSaving ? "Saving…" : "Make default")
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }
        }

        PanelSeparator { width: parent.width }

        ColumnLayout {
          width: parent.width
          spacing: Style.space(4)
          visible: root.connected

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: "↓"
              color: root.green
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              text: root.fmtRate(root.rxRate)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              Layout.fillWidth: true
              text: root.fmtBytes(root.rxBytes) + " total"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }
          }

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(8)

            Text {
              text: "↑"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              text: root.fmtRate(root.txRate)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }

            Text {
              Layout.fillWidth: true
              text: root.fmtBytes(root.txBytes) + " total"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignRight
            }
          }
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Text {
            text: "Exit IP"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            Layout.fillWidth: true
            text: root.ipChecking ? "checking…" : (root.publicIp !== "" ? root.publicIp : "—")
            color: root.ipMismatch ? root.urgent : (root.ipVerified ? root.green : root.foreground)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }

          Text {
            visible: root.connected && root.publicIp !== "" && !root.ipChecking && root.hostIsIp
            text: root.ipMismatch ? "unexpected!" : "verified"
            color: root.ipMismatch ? root.urgent : root.green
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Text {
          width: parent.width
          text: "t toggle · 1-9 tunnel · r refresh\n★ or d marks the default"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
