# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-22

| Thing | State |
|---|---|
| Released | 1.2.1 (`421e4fd`), verified on the marketplace (#11122) |
| `main` | 1.3.0: Power Saving's panel design, live traffic graph, theme accent, repo-docs layout |
| Installed copy | Runs the 1.3.0 `Panel.qml`, copied in for the live check |
| Marketplace | 1.3.0 needs a `[Verify]` issue on the HEAD of `main` once pushed |

## Pending

1. Push `main`, tag `v1.3.0`, open the `[Verify]` issue (`docs/runbooks/release.md`). Waits on Kike.
2. After approval, `omarchy plugin update io.github.selfcrypto.wireguard` so the installed copy is clean again.

## Done

- **2026-10-22.** 1.3.0: live card with traffic graph and exit IP tag, grouped tunnel rows with
  key caps, theme accent, new preview, em dashes removed, repo-docs layout.
