# Strays

Native macOS menu bar app (Swift 5.10 package, SwiftUI `MenuBarExtra`, macOS 13+) that surfaces
hidden, battery-draining processes, with particular focus on what Claude Code sessions leave behind.
No dependencies.

## Layout

- `Sources/StraysCore`: everything that inspects the machine; no UI.
  - `LibProc.swift`: libproc/sysctl wrappers (pids, bsdinfo, rusage v6 energy, procargs, cwd, listening sockets)
  - `Sampler.swift`: snapshots and CPU/energy rates; records each new process's launch chain (persisted via ProvenanceStore)
  - `Classifier.swift`: snapshot → `Report`. Claims groups in order: browsers → machines → Claude sessions → orphans
  - `CommandNamer.swift`: argv → human name (`ts-node-dev src/index.ts`, `npm run dev`, Claude `eval '…'` wrappers)
  - `Power.swift`: power assertions, battery draw (AppleSmartBattery), pmset/uptime warnings
  - `Integrations.swift`: Shell, Docker, DevTools pages, simctl
  - `Stopper.swift`: TERM → wait → KILL, start-time guarded
  - `Provenance.swift`: launch chains (`Launch`, `ProvenanceStore`), SessionEnd ledger, `StraysPaths`, `ActivityLog`
  - `SessionEnd.swift`: what an ending Claude session leaves behind (hook side), and what survived (app side)
  - `History.swift`: `pmset -g log` parser (charge points, battery deaths, sleep sessions), 5-minute samples, `BatteryStory`
  - `SessionStart.swift`: what's already running in a new session's project (SessionStart hook)
  - `Energy.swift`: `EnergyLedger` (Wh per app since unplugging) and `AutoCleanup` eligibility
- `Sources/Strays`: the app. `main.swift` dispatches CLI vs GUI; `Store` runs the refresh loop, history,
  hot tracking and session-end follow-ups; `PanelModel` turns a scan into display strings; `Notifier` wraps
  UserNotifications; `ClaudeHook` runs the bundled `scripts/claude-hook.py`.
- State lives in `~/Library/Application Support/Strays/`: provenance.json, sessions.jsonl, history.jsonl, energy.json, activity.log.
- `Tests/StraysCoreTests`: classifier and namer tests over synthetic process tables.

## Commands

```sh
swift test                                   # unit tests
swift build && .build/debug/Strays --list    # live scan in the terminal
./scripts/build-app.sh                       # build/Strays.app (ad-hoc signed)
./install.sh                                 # build + install to ~/Applications + login item + ~/.local/bin/strays
build/Strays.app/Contents/MacOS/Strays --window --tall --expand-first --snapshot out.png
                                             # render the panel to PNG (no Screen Recording permission needed)
build/Strays.app/Contents/MacOS/Strays --window --float --visibility-selftest
                                             # check open/closed tracking (--float: other windows would occlude it)
.build/release/Strays --bench                # time 5 steady-state scans
```

## Rules of thumb

- Orphan = user process with ppid 1 whose session leader is dead (or a shell), or with Claude
  env/ancestry. Apps and launchd agents sit in session 1 or lead their own session. Don't flag them.
- Never spawn subprocesses on the background refresh path; `pmset`, `docker` and DevTools run only while the panel is open.
- `Text("\(number)")` localises with thousands separators. Use `Text(verbatim:)` for pids and ports.
- Never edit ~/.claude/settings.json except through `scripts/claude-hook.py`, and test changes to it on a copy
  first (`HOME=<tmp> python3 scripts/claude-hook.py install`).
- `STRAYS_HOT_AFTER=<seconds>` shortens the hot-notification threshold; `STRAYS_DEATH_LOOKBACK=<seconds>`
  widens the battery-death report window. Both are for testing.
- Panel snapshots: always pass `--snapshot` (it pins the panel open). Otherwise a sleeping display or covering
  windows make the window read as closed and nothing renders.
