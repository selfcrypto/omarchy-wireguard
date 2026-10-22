# omarchy-wireguard: where each thing is

Paths are relative to this file. Every symbol with its line number: `SYMBOLS.md` (generated,
grep it). This file says what each file is for and where to go for a kind of change.

## I want to change…

| What | Where | Also moves |
|---|---|---|
| How tunnels are found | `wg-helper.sh` (`list`), `Panel.qml` (`statusProc`, `refresh`) | README "How it runs things" |
| Connecting, switching, disconnecting | `Panel.qml` (`connectTo`, `disconnectFrom`, `disconnectAll`), `wg-helper.sh` (`up`, `down`) | |
| The default tunnel | `Panel.qml` (`defaultTunnel`, `setDefault`) | README "Configuration" |
| Traffic rates and the graph | `Panel.qml` (`trafficProc`, `rxHistory`, `TrafficGraph`), `wg-helper.sh` (`stats`) | |
| The exit IP check | `Panel.qml` (`checkIp`, `ipProc`, `ipVerified`, `ipMismatch`), `wg-helper.sh` (`ip`) | README "Requirements" |
| Toasts | `Panel.qml` (`notifyOutcome`), `wg-helper.sh` (`notify`, `notify-connect`) | |
| The panel layout, key caps, footer | `Panel.qml` (`KeyCap`, the `column` under `KeyboardPanel`) | `preview.png` |
| A panel key | `Panel.qml` (`keyCatcher` `onTextKey`) | README "Usage", footer |
| An IPC call | `Panel.qml` (`IpcHandler`) | README "IPC" |
| Limits on names, hosts, replies | `Panel.qml` (`max*` properties), `wg-helper.sh` | |
| Marketplace text or version | `manifest.json` | `docs/runbooks/release.md` |

## Files

| File | Role |
|---|---|
| `Panel.qml` | The widget: state from NetworkManager, panel, traffic graph, exit IP, toasts, IPC |
| `wg-helper.sh` | One supervised process per operation; validates and clips everything it prints |
| `manifest.json` | Plugin id, version, settings schema, marketplace descriptions |
| `preview.png` | Marketplace image, 1920×960, from a screenshot of the panel with sample data |
