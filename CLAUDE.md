# omarchy-wireguard · Omarchy bar widget for NetworkManager's WireGuard tunnels

Bar icon and panel for the Omarchy shell (Quickshell, QML): lists every WireGuard profile
NetworkManager knows, switches tunnels, graphs live traffic and checks the exit IP. Published on
the Omarchy plugin marketplace as `io.github.selfcrypto.wireguard` and installed on Kike's
desktop. It shares its panel design with `omarchy-power-saving`.

Where every file and function is: `MAP.md` (by topic) and `SYMBOLS.md` (every symbol, grep it).
Current state: `docs/status.md`. Why things are the way they are: `docs/decisions.md` (grep its
index). Procedures: `docs/runbooks/`. Reader-facing: `README.md`.

## Parts

| Path | Role |
|---|---|
| `Panel.qml` | Bar icon, panel, state, IPC |
| `wg-helper.sh` | Every external command (nmcli, /sys counters, curl, notify-send), supervised and bounded |
| `manifest.json`, `preview.png`, `README.md` | What the marketplace shows |

## Where things run

| Thing | Where |
|---|---|
| Installed copy | `~/.config/omarchy/plugins/io.github.selfcrypto.wireguard`, a clone of this repo |
| Shell | `omarchy-shell` (Quickshell, `/usr/share/omarchy/shell`); log in `journalctl --user` |
| Settings | This widget's entry in `~/.config/omarchy/shell.json` (`omarchy bar set`) |
| Marketplace | GitHub omacom/omarchy-plugin-marketplace, pinned to one commit per release |

## Rules that apply everywhere

- Every external command goes through `wg-helper.sh` under `timeout -k 3`; fixed argv, output validated on both sides.
- Text from NetworkManager or the network is plain text, capped and elided, never rich text.
- Colors and sizes come from `qs.Commons` (`Commons.Color`, `Style`); nothing hard-coded.
- Panel design stays in step with `omarchy-power-saving`: hero, one live card, grouped rows, key-cap footer.
- No em dashes and no filler in code, docs, manifest, commits or issues.
- Nothing is pushed, tagged or filed on the marketplace without asking first.

## Session protocol

1. Read this file and `docs/status.md`. Open `MAP.md` before grepping; grep `SYMBOLS.md` for a name.
2. Work on a branch in this repo, never in the installed copy.
3. Verify: `qmllint` on `Panel.qml`, `sh -n wg-helper.sh`, then the live check in `docs/runbooks/testing.md`.
4. Release as in `docs/runbooks/release.md`: version in `manifest.json`, tag, `[Verify]` issue.

After any change, before the work is called done:

- `docs/status.md`: what is now true and what is pending; move stale Done entries to
  `docs/history/status-journal.md`.
- `docs/decisions.md`: append what a future session would otherwise re-litigate.
- `MAP.md`: a new file gets its role line; a moved responsibility moves its row.
- `repo-docs map && repo-docs check`, clean. Commit the docs with the code.

## Keeping these files small

`CLAUDE.md`, `MAP.md` and `docs/status.md` are read at the start of every session, so every line
costs every session. A rule is one line; its story goes to `docs/decisions.md`. A fact that stops
being current is removed, not annotated. Budgets: this file 15 KB, `MAP.md` 12 KB,
`docs/status.md` 15 KB. `SYMBOLS.md` is generated: never edit it, regenerate it.
