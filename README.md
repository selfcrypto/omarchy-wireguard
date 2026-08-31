# Omarchy WireGuard

WireGuard tunnels for the [Omarchy](https://omarchy.org) bar: a status icon
with a panel that lists every WireGuard profile NetworkManager knows, switches
between them with one click, shows live transfer and verifies the exit IP.

Nothing to configure. Import a profile and it appears:

```bash
nmcli connection import type wireguard file my-gateway.conf
```

## Features

- Every NetworkManager WireGuard profile, discovered automatically.
- One tunnel at a time (default): bringing one up takes the others down
  first, so two full-tunnel gateways never fight over the default route.
- A default tunnel for the power switch, the icon's right-click and the IPC
  `on` call — star any row to choose it.
- Live download/upload rate and totals for the active tunnel.
- Exit-IP check against the profile's peer endpoint: "verified" when the
  public address is the gateway, "unexpected!" when it is not.
- Keyboard-driven panel and full IPC control.

## Installation

```bash
omarchy plugin add https://github.com/selfcrypto/omarchy-wireguard.git --enable
```

Verify:

```bash
omarchy plugin list
omarchy plugin validate ~/.config/omarchy/plugins/io.github.selfcrypto.wireguard
```

Update:

```bash
omarchy plugin update io.github.selfcrypto.wireguard
```

Remove:

```bash
omarchy plugin remove io.github.selfcrypto.wireguard
```

## Usage

- **Left-click** the bar icon: open the panel.
- **Right-click**: connect to the default tunnel, or disconnect.
- **Middle-click**: refresh.
- In the panel: click a row to switch to it (or disconnect it), click the
  star to make it the default. Keys: `t` toggle, `1`–`9` pick a tunnel
  (the default is always `1`), `d` make the connected tunnel the default,
  `r` refresh and re-check the exit IP.

## Configuration

Settings live on the widget's entry in `~/.config/omarchy/shell.json` and are
set with `omarchy bar set`:

```bash
omarchy bar set io.github.selfcrypto.wireguard defaultTunnel my-gateway
omarchy bar set io.github.selfcrypto.wireguard exclusive false --json
omarchy bar set io.github.selfcrypto.wireguard refreshIntervalSec 5
```

| Key | Meaning | Default |
|---|---|---|
| `defaultTunnel` | NetworkManager connection name the switch / right-click / `on` bring up | first profile |
| `exclusive` | bring every other tunnel down before bringing one up | `true` |
| `refreshIntervalSec` | status poll interval, 2–60 s | `3` |

## IPC

```bash
omarchy-shell io.github.selfcrypto.wireguard status          # "gateway" or "disconnected"
omarchy-shell io.github.selfcrypto.wireguard list            # JSON: tunnels, active, default
omarchy-shell io.github.selfcrypto.wireguard on | off        # default tunnel up / everything down
omarchy-shell io.github.selfcrypto.wireguard up <name>
omarchy-shell io.github.selfcrypto.wireguard down <name>
omarchy-shell io.github.selfcrypto.wireguard setDefault <name>
omarchy-shell io.github.selfcrypto.wireguard toggle          # the panel
```

## Requirements and dependencies

- NetworkManager with WireGuard profiles (`nmcli`); `curl` for the exit-IP
  check. Both ship with Omarchy.
- Runs entirely as the user: NetworkManager's default policy lets the active
  local session bring its connections up and down, so no polkit prompt.
- One external request: the exit IP comes from `https://1.1.1.1/cdn-cgi/trace`
  (Cloudflare), only while the panel is open or a tunnel changes.
- The exit-IP verdict is only given when the profile's endpoint is an IP
  literal; a hostname endpoint shows the address without a verdict.

## License

MIT — see [LICENSE](LICENSE).
