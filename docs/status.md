# Status

Current state only. The next session starts here. History: `docs/history/status-journal.md`.
Budget 15 KB.

## Where things stand, 2026-10-22

| Thing | State |
|---|---|
| Released | 1.2.1 (`421e4fd`), verified on the marketplace (#11122) |
| `main` on GitHub | 1.3.0, the commit named in issue #12623 |
| Tag `v1.3.0` | On the commit named in #12623 (moved there on 2026-10-22) |
| Marketplace | #12623 `[Verify]` 1.3.0: compatibility and security baseline passed, waiting for a maintainer |
| Installed copy | Runs the 1.3.0 `Panel.qml`, copied in for the live check |

## Pending

1. #12623 approved. While it is open, a push makes it stale: edit its body to the new HEAD SHA and watch the bot.
2. Push this repo's local docs commits (status only) once #12623 is approved.
3. After approval, `omarchy plugin update io.github.selfcrypto.wireguard` so the installed copy is clean again.

## Done

- **2026-10-22.** 1.3.0: live card with traffic graph and exit IP tag, grouped tunnel rows with
  key caps, theme accent, new preview, em dashes removed, repo-docs layout.
- **2026-10-22.** Marketplace rejected the first push: `AGENTS.md` was a symlink. Now a file.
