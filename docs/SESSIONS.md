# Sessions

## 2026-10-17: v0.1.0 built

The trigger: the laptop died 3 times in a week (Oct 12, 16, 17). The cause was an orphaned
sustainica `ts-node-dev` stuck in a synchronous startup loop (98% CPU for 20 days; it ignored
SIGTERM) plus 4 orphaned headless Chromes rendering the home-assistant Family Board (~93% CPU
combined), with display sleep set to "never" on battery. Battery health was fine (87%, 345 cycles).

Built Strays: libproc-based scanner, classifier, SwiftUI menu bar panel, CLI (`--list`, `--json`, `--stop`),
install scripts, and 31 unit tests.

Verified on the dev Mac:
- 21 real orphans found, all started by Claude sessions that had ended, from 4 to 226 days old; many listen on 0.0.0.0
- a synthetic busy loop that ignores SIGTERM shows as 100% / ~4 W, flagged hot; `--stop` escalates to SIGKILL after 3 s
- a headless Chrome is detected with its profile dir and DevTools port; the user's own Chrome isn't flagged

Findings worth keeping:
- `getsid()` is 1 for launchd agents and apps. launchd is root-owned and so missing from the table; don't read that as a dead session.
- macOS hides `KERN_PROCARGS2` env for platform binaries and hardened apps. Hence the first-sight Claude ancestry memory.
- `proc_pid_rusage` v6 `ri_energy_nj` is real: a pegged P-core reads ≈3.4 W.
- `open` from a Claude shell passes `CLAUDECODE` into the app's env. LaunchServices apps sit in session 1,
  and that, not the env, is what marks them as intentionally running.
- Self-cost: a scan takes ~12 ms. Most of the app's CPU came from SwiftUI re-laying out the *hidden*
  panel on every refresh. Now only the menu bar badge (Equatable) updates while closed: 0.26 s of CPU
  in 3 min (~0.14%), 60 MB RSS. Panel open/closed is tracked from window occlusion; `onAppear` is
  unreliable for MenuBarExtra (checked with `--visibility-selftest`).

## 2026-10-17: open-panel optimisation

The open panel cost 8% CPU / 0.12 W, mostly from SwiftUI redrawing every row every 2 s, because
every row observed the Store. Changes:
- `PanelModel`: the whole panel as Equatable display strings, published only when it differs.
- Rows are Equatable and take an unobserved Store reference for actions; actions resolve by id against the latest scan.
- Coarse panel formatting (`Fmt.cpuCoarse`, whole-watt battery draw) so idle jitter doesn't redraw rows.
- Open cadence 3 s; docker/DevTools every 10 s; pmset on open, then every 60 s. Listening ports cached for 10 s.

Result: open 2.0% CPU / 0.01 W / 8 idle wakeups per minute (was 8% / 0.12 W / 36). Closed 0.1%, 19 MB, ~1 wakeup per minute.
Test window note: `--visibility-selftest` needs `--float` when other windows cover the test window.
Occlusion correctly reads as "closed".

## 2026-10-17: session-end hook, launch chains, battery history, notifications, clearer UI

Added:
- **Launch chains** (`Launch`, `ProvenanceStore`): the sampler records what launched each new process while
  its parents are alive. Only launches under a shell, runtime or Claude are persisted, to `provenance.json`,
  pruned to live processes.
- **SessionEnd hook** (`strays --session-end`, `SessionEnd`, `SessionLedger`): records the session's
  leftovers to `sessions.jsonl` and posts a distributed notification. The app re-checks at 6 s, 20 s and 60 s,
  and only notifies about survivors once the `claude` process is gone (`/clear` keeps it alive).
  `scripts/claude-hook.py` merges the hook into settings.json; it's bundled into the app for the gear menu.
- **Battery history**: `PowerLog.parse` reads charge readings and "Low Power Sleep" deaths from
  `pmset -g log`. A death's window starts at the last unplug before it. `HistoryStore` adds samples every 5 minutes.
- **Notifications** (UserNotifications, Stop/Ignore actions), plus `activity.log`.
- **Quick wins**: "Stop those" for network-exposed servers, "End N idle" Claude sessions, `strays --port`.
- **Clarity**: a legend (?), one-line section blurbs, plain-English row subtitles, labelled detail grid.

Verified:
- 42 tests.
- An end-to-end session-end test with a stand-in `claude` binary: the hook recorded the server, the app
  notified "left 1 thing running" after the stand-in exited, and the orphan showed "Claude (session ended)".
- The hot-stray notification, with `STRAYS_HOT_AFTER=20`.
- The hook installer on a copy of settings.json: idempotent, minimal diff, and uninstall is byte-identical.

Bugs this pass caught:
- The hook marker didn't match the quoted command (`strays" --session-end`), so a second install duplicated it.
- Nested Claude sessions were swallowed into the outer session's background tasks.
- An inherited `CLAUDE_PID` beat observed ancestry. Observed ancestry now wins.

Corrected the morning's drain figure. The Mac charged from 09:35 to 12:15, then went 100% → 1% in 3h 15m
(about 18 W), not 98% → 1% from 08:49.

Open: notifications showed "not allowed" on this Mac after install, either a dismissed prompt or macOS
refusing the ad-hoc-signed app. Needs a System Settings toggle by Joe; unverified which.

## 2026-10-18/19: session briefing, duplicates, energy by app, sleep summary, post-mortem, auto-cleanup, Docker, --update

- **SessionStart hook** (`strays --session-start`, `SessionStart.swift`): lists what's already running in
  the new session's git project as `additionalContext`. The pipe-test of the real hook command produced
  the expected JSON for games/gradient-descent and nothing for a project with nothing running.
- **Duplicates** (`Classifier.duplicates`): same kind + cwd + title with port numbers removed. Panel offers
  "Keep newest, stop N"; also noted in the session briefing.
- **Energy by app** (`EnergyLedger`): per-process energy-counter deltas grouped by app bundle or by
  hidden / Claude / VM group. Accumulates only on battery, resets on unplug, saved to energy.json every 5 minutes,
  and kept after plugging in ("last time on battery").
- **Sleep summary**: `PowerLog` now tracks sleep → full wake (a `V` in flags like [CDNVA]), counting DarkWakes.
- **Battery post-mortem**: 60 s after launch, and after a wake when the last sample was ≤5%, re-reads the
  power log and notifies about deaths newer than `lastReportedDeath`. That's set to install time, so old deaths
  aren't reported. Tested with `STRAYS_DEATH_LOOKBACK`.
- **Auto-cleanup** (opt-in): `AutoCleanup.eligible` covers ended-Claude-session orphans and browsers that are idle and
  older than N hours. Announced 10 minutes ahead, with Stop now / Keep them. The live flow is untested (nothing old
  enough was running); eligibility is unit-tested.
- **Docker**: quit asks first and lists the containers it will stop. Each container shows `docker stats` CPU and
  memory. Quit uses `docker desktop stop`, then stops leftovers: quitting "Docker" by name only stops the engine
  (com.docker.docker), not the window app (com.electron.dockerdesktop).
- **`strays --update`**: install.sh records the source path. Pulls if there's an upstream (there is:
  J-Glatter/strays), then reinstalls.
- Hook installer now manages both hooks. Tested on a copy: adds only what's missing, idempotent, and uninstall
  restores the pre-hook file byte for byte.
- Snapshots need `--snapshot` to pin the panel open: with the display asleep (displaysleep 5 now) every window
  reads as occluded.
- 49 tests.
