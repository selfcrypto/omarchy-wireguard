# Testing

Static checks (the lint warnings about unqualified access and `QObject` members are the baseline):

```bash
sh -n wg-helper.sh
/usr/lib/qt6/bin/qmllint -I ~/.local/share/qml-imports -I /usr/lib/qt6/qml Panel.qml
```

Live check in the shell. Copy the panel into the installed clone, restart the shell, open it:

```bash
P=~/.config/omarchy/plugins/io.github.selfcrypto.wireguard
cp Panel.qml wg-helper.sh "$P"/
omarchy restart shell
omarchy-shell io.github.selfcrypto.wireguard open
omarchy-shell io.github.selfcrypto.wireguard list
journalctl --user --since "-2 min" | grep -i wireguard
```

Connecting a tunnel changes the machine's routing: ask first. For screenshots of the connected
state, feed sample data instead (a temporary `Timer` in the installed copy that sets `tunnels`,
`publicIp` and the rate histories, as done for `preview.png` on 2026-10-22), then copy the real
`Panel.qml` back.

Put the installed copy back to the released version:

```bash
git -C "$P" checkout -- . && git -C "$P" clean -fd && omarchy restart shell
```
