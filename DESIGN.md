# Native Mac operating surface

The user's brief pins the visual direction: a macOS utility, with familiar native controls. The primary job is scanning routes and safely changing their running state.

- Three regions: 200 pt source sidebar, flexible rules table, 310 pt inspector. Window minimum 1060 × 660; default 1220 × 760.
- SF system type: 13 pt controls, 12 pt secondary labels, 22 pt page title. Monospaced text only for addresses, ports and transfer measurements.
- System window, control and grouped backgrounds; system accent blue; semantic green/orange/red for ready, starting and error. Never communicate state only by color.
- Toolbar: add rule, start/stop filtered rules, import/export, inspector toggle. Firewall is a dedicated sidebar destination.
- Editor lives in the inspector. Start only saved, valid rules. Running rules must be stopped before editing.
- Empty states explain the next action. First launch never fabricates active traffic.
- Native keyboard focus, accessibility labels, resizable table columns, search, context menus, and destructive deletion confirmation.
- Motion only for view/state changes; obey system reduced-motion preference by using native controls.

## Final interaction decisions

- A single `Window` scene named `main` owns the main UI; every entry activates that scene instead of creating another WindowGroup instance.
- A unified compact toolbar spans the full window; the content-only HSplitView avoids an independently inset sidebar toolbar separator.
- The menu-bar extra uses a 360 pt window panel with a native blue switch on every saved rule, including stopped rules. The list has explicit height, capped at 400 pt with scrolling.
- Application icon: pearl ceramic rounded tile, silver recessed routing channels, dimensional blue glass bidirectional arrows. Source and generation provenance are in Resources.
- Validation feedback is pinned immediately above the editor footer. Switching to another draft requires an explicit discard decision.
