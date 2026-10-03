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
// Every action ends in a toast (`notifications`, on by default): a connect is
// announced with the exit IP once it has been fetched — and flagged when an
// IP-literal endpoint does not match it, the same verdict the panel shows —
// a disconnect plainly, a failure as critical.
//
// Everything runs as the user: nmcli for profiles, state and up/down (allowed
// for the active local session by NetworkManager's default policy),
// /sys/class/net for byte counters, one HTTPS request to Cloudflare for the
// exit IP. All of it goes through wg-helper.sh, one supervised process per
// operation: `timeout -k 3 <deadline> sh wg-helper.sh <command> args...`, so
// every call has a wall-clock deadline over its whole process group, fixed
// argv, and output that is validated and bounded before it gets here (profile
// count, name and host length, interface-name syntax, one canonical IPv4).
// The widget re-checks what it parses and treats every string that came from
// NetworkManager or the network as plain text of bounded length.
Panel {
  id: root
  moduleName: "io.github.selfcrypto.wireguard"
  ipcTarget: "io.github.selfcrypto.wireguard"
  manageIpc: false

  // Straight from NetworkManager: [{ name, active, iface, host, since }].
  property var tunnels: []
  property bool discovered: false

  // Limits, mirrored in wg-helper.sh: what is accepted from the helper and
  // what is handed to text sinks and IPC callers.
  readonly property int maxProfiles: 32
  readonly property int maxNameChars: 256
  readonly property int maxLabelChars: 64      // a name as displayed
  readonly property int maxLineChars: 300      // a tooltip, hero line or toast
  readonly property int maxIpcChars: 32768     // an IPC reply

  readonly property string helper: decodeURIComponent(String(Qt.resolvedUrl("wg-helper.sh")).replace(/^file:\/\//, ""))
  // Every external command: deadline over the whole process group, then KILL.
  function supervised(seconds, args) {
    return ["timeout", "-k", "3", String(seconds), "sh", root.helper].concat(args)
  }

  function isIface(s) { return /^[^\/:\s]{1,15}$/.test(String(s)) && s !== "." && s !== ".." }
  function isHost(s) { return /^[\[\]A-Za-z0-9.:-]{1,253}$/.test(String(s)) }
  function isName(s) { return typeof s === "string" && s.length > 0 && s.length <= maxNameChars && !/[\x00-\x1f\x7f]/.test(s) }
  function clip(s, n) { s = String(s); return s.length > n ? s.slice(0, n - 1) + "…" : s }
  function label(name) { return clip(name, maxLabelChars) }
  function labels(names) { return clip(names.map(label).join(", "), maxLineChars) }
  readonly property bool exclusive: root.setting("exclusive", true) !== false
  readonly property bool notifications: root.setting("notifications", true) !== false
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
  // The action in flight, so its toast can report what actually happened.
  property var pendingAction: null

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
  readonly property bool hostIsIp: activeInfo !== null && isIpLiteral(activeInfo.host)
  // Interface that carries internet traffic (see wg-helper.sh route). When it
  // isn't the active tunnel, the tunnel is split and the exit IP is expected
  // to be the normal one. Unknown routing keeps the strict check.
  property string routeIface: ""
  readonly property bool splitTunnel: connected && routeIface !== "" && routeIface !== activeInfo.iface
  // The exit IP must be the gateway's address; anything else is wrong.
  readonly property bool ipMismatch: connected && !splitTunnel && publicIp !== "" && hostIsIp && publicIp !== activeInfo.host
  readonly property bool ipVerified: connected && !splitTunnel && publicIp !== "" && hostIsIp && publicIp === activeInfo.host
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
    if (!connected || trafficProc.running || !isIface(activeInfo.iface)) return
    trafficProc.command = supervised(5, ["stats", activeInfo.iface])
    trafficProc.running = true
  }

  function checkIp() {
    if (!routeProc.running) routeProc.running = true
    if (ipProc.running) return
    ipChecking = true
    ipProc.running = true
  }

  function runAction(argv, action) {
    if (actionProc.running) return
    busy = true
    pendingAction = action || null
    actionProc.command = argv
    actionProc.running = true
  }

  function knownTunnel(name) {
    for (var i = 0; i < tunnels.length; i++) if (tunnels[i].name === name) return true
    return false
  }

  // Canonical IPv4 only: four octets 0-255, no leading zeros.
  function isIpLiteral(s) { return /^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$/.test(String(s)) }

  // The endpoint a connect toast checks the exit IP against; empty when the
  // profile's endpoint is a hostname, which the panel does not verify either.
  function expectedHostFor(name) {
    for (var i = 0; i < tunnels.length; i++)
      if (tunnels[i].name === name && isIpLiteral(tunnels[i].host)) return tunnels[i].host
    return ""
  }

  // Detached (Util.execArgv: argv only, no shell re-tokenising) so a slow exit-IP
  // lookup never holds the panel and back-to-back actions never lose a toast;
  // still under its own `timeout`, so the lookup cannot outlive its deadline.
  function notifyOutcome(action, ok) {
    if (!notifications || !action) return
    if (action.kind === "connect") {
      if (!ok) {
        Util.execArgv(supervised(5, ["notify", "critical", label(action.name) + " failed to come up — left disconnected"]))
        return
      }
      var lead = (action.switched ? "Switched to " : "Connected to ") + label(action.name)
      Util.execArgv(supervised(15, ["notify-connect", lead, expectedHostFor(action.name)]))
      return
    }
    var names = labels(action.names)
    Util.execArgv(supervised(5, ok
      ? ["notify", "normal", "Disconnected from " + names]
      : ["notify", "critical", "Could not bring down " + names]))
  }

  // Names travel as arguments, never inside a script, and only names that
  // came out of the last discovery are ever passed on.
  function connectTo(name) {
    if (!knownTunnel(name) || name === activeTunnel) return
    var others = []
    if (exclusive) for (var i = 0; i < activeNames.length; i++) if (activeNames[i] !== name) others.push(activeNames[i])
    // Others down (10 s each), target up (20 s), a failed target down again
    // (10 s): the deadline covers the worst case of the exclusive switch.
    runAction(supervised(30 + 10 * (others.length + 1), ["up", name].concat(others)),
      { kind: "connect", name: name, switched: others.length > 0 })
  }

  function disconnectFrom(name) {
    if (activeNames.indexOf(name) === -1) return
    runAction(supervised(15, ["down", name]), { kind: "disconnect", names: [name] })
  }

  function disconnectAll() {
    if (!connected) return
    runAction(supervised(5 + 10 * activeNames.length, ["down"].concat(activeNames)),
      { kind: "disconnect", names: activeNames.slice() })
  }

  function togglePower() { connected ? disconnectAll() : connectTo(defaultTunnel) }

  // Persist through the shell's own writer so shell.json stays canonical; the
  // bar then pushes the new `settings` into this widget live, which is what
  // flips `defaultTunnel` — no local state to keep in sync.
  function setDefault(name) {
    if (name === defaultTunnel || defaultProc.running || !knownTunnel(name)) return
    defaultSaving = true
    defaultProc.command = ["timeout", "-k", "3", "15", "omarchy", "bar", "set", root.moduleName, "defaultTunnel", name]
    defaultProc.running = true
  }

  // Bounded by construction (at most maxProfiles entries of capped fields);
  // the hard ceiling is there so no reply can grow past it regardless.
  function tunnelsJson() {
    return clipIpc(JSON.stringify({ exclusive: exclusive, defaultTunnel: defaultTunnel, active: activeNames, tunnels: tunnels }))
  }
  function clipIpc(s) { return s.length > maxIpcChars ? s.slice(0, maxIpcChars) : s }

  // One poll for everything: every WireGuard profile, whether it is active,
  // its interface while it is up (for the byte counters), its peer endpoint
  // (expected exit IP) and its last activation time. The helper validates and
  // clips every field; it is checked again here before it is trusted.
  Process {
    id: statusProc
    command: root.supervised(10, ["list"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text)
        if (raw.length > root.maxIpcChars * 2) { root.busy = false; return }
        var parsed
        try { parsed = JSON.parse(raw) } catch (e) { root.busy = false; return }
        if (!Array.isArray(parsed)) { root.busy = false; return }
        var list = []
        for (var i = 0; i < parsed.length && list.length < root.maxProfiles; i++) {
          var e = parsed[i]
          if (!e || !root.isName(e.name)) continue
          var since = Number(e.since)
          list.push({
            name: e.name,
            active: e.active === true,
            iface: root.isIface(e.iface) ? e.iface : "",
            host: root.isHost(e.host) ? e.host : "",
            since: isFinite(since) && since > 0 ? since : 0
          })
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
        if (!isFinite(rx) || !isFinite(tx) || rx < 0 || tx < 0) return
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

  // The helper prints one canonical IPv4 address or nothing at all.
  Process {
    id: ipProc
    command: root.supervised(10, ["ip"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var ip = String(text).trim()
        root.publicIp = root.isIpLiteral(ip) ? ip : ""
        root.ipChecking = false
      }
    }
    onExited: root.ipChecking = false
  }

  // The helper prints one interface name or nothing at all.
  Process {
    id: routeProc
    command: root.supervised(5, ["route"])
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var dev = String(text).trim()
        root.routeIface = root.isIface(dev) ? dev : ""
      }
    }
  }

  Process {
    id: actionProc
    onExited: (exitCode, exitStatus) => {
      var action = root.pendingAction
      root.pendingAction = null
      root.refresh()
      root.notifyOutcome(action, exitCode === 0 && exitStatus === 0)
    }
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

  // `timeout` already ends every helper at its deadline; this is the belt to
  // its braces, so a poll that somehow never exits cannot stop refreshing.
  Timer {
    interval: 15000
    repeat: true
    running: true
    onTriggered: {
      if (statusProc.running) statusProc.running = false
      if (trafficProc.running) trafficProc.running = false
      if (ipProc.running) ipProc.running = false
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
    function status(): string { return root.connected ? root.clipIpc(root.activeNames.join(",")) : "disconnected" }
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
      ? "WireGuard: " + root.labels(root.activeNames)
      : (root.defaultTunnel !== ""
        ? "WireGuard: disconnected · right-click → " + root.label(root.defaultTunnel)
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
            ? "Connected to " + root.labels(root.activeNames) + root.sinceText
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
                text: root.connected ? "Disconnect" : "Connect to " + root.label(root.defaultTunnel)
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

                  // Names and endpoints come from NetworkManager: plain text,
                  // capped and elided, never auto-detected as rich text.
                  Text {
                    Layout.fillWidth: true
                    text: root.label(row.modelData.name)
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }

                  Text {
                    Layout.fillWidth: true
                    text: row.modelData.host !== "" ? row.modelData.host : "no endpoint"
                    textFormat: Text.PlainText
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
            textFormat: Text.PlainText
            color: root.ipMismatch ? root.urgent : (root.ipVerified ? root.green : root.foreground)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignRight
          }

          Text {
            visible: root.connected && root.publicIp !== "" && !root.ipChecking && root.hostIsIp
            text: root.splitTunnel ? "split tunnel" : (root.ipMismatch ? "unexpected!" : "verified")
            color: root.splitTunnel ? root.dim : (root.ipMismatch ? root.urgent : root.green)
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
