# Decisions

Append-only. One entry per decision a future session would otherwise re-litigate or silently
contradict. Newest last. Navigate by grepping titles or the index; never read this file in full.

Format:

```
## YYYY-MM-DD · short title
**Decision.** What was decided.
**Why.** The reason, briefly. Who asked, if someone did.
**Alternative rejected.** What was not chosen, and what it would have cost.
```

Titles are never changed once cited from another file.

## Index

- `Every external command through wg-helper.sh` · `CLAUDE.md`
- `Panel design shared with Power Saving` · `CLAUDE.md`

## 2026-08-31 · Tunnels are discovered, not configured
**Decision.** Every WireGuard profile NetworkManager knows is listed; the plugin stores only the default tunnel's name.
**Why.** Importing a profile with `nmcli` is all a user should have to do.
**Alternative rejected.** A tunnel list in the plugin's settings: a second source of truth.

## 2026-08-31 · One tunnel at a time by default
**Decision.** `exclusive` (on by default) brings the other tunnels down before one comes up.
**Why.** Two full-tunnel gateways at once route each other's packets into nothing.
**Alternative rejected.** Leaving others up: broken routing with no visible cause.

## 2026-09-05 · Every external command through wg-helper.sh
**Decision.** One helper process per operation, `timeout -k 3` over its process group, fixed argv, output validated and clipped on both sides.
**Why.** Hardening for the marketplace: no hung process, no shell re-tokenising, no unbounded input from NetworkManager or the network.
**Alternative rejected.** Inline `sh -c` strings in QML: quoting bugs and no deadline.

## 2026-10-22 · Panel design shared with Power Saving
**Decision.** Same language as `omarchy-power-saving` 1.5.0: hero with the switch, one live card (tunnel, endpoint, a minute of traffic as a graph, rates, exit IP with a verified, unexpected or not checked tag), tunnels in one grouped list with icon tiles and number key caps, key-cap footer.
**Why.** Kike found both panels plain next to the top marketplace plugins and asked for the same treatment.
**Alternative rejected.** A separate design per plugin: two looks for one author's plugins.

## 2026-10-22 · Theme accent instead of green
**Decision.** A live tunnel is shown in `Commons.Color.accent`; the hard-coded `#7dc383` is gone.
**Why.** Colors must follow the active Omarchy theme; the theme exposes no green to plugins.
**Alternative rejected.** Keeping the green: clashes with themes whose accent is not green.

## 2026-10-22 · Preview with sample data
**Decision.** `preview.png` is a screenshot of the real panel fed sample tunnels and documentation IP ranges (203.0.113.0/24, 198.51.100.0/24), composed at 1920×960 like Power Saving's.
**Why.** A connected panel shows the graph; real tunnel names and addresses must not be published.
**Alternative rejected.** Kike's own tunnels: private addresses in a public image.
