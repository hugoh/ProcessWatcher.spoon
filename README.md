# ProcessWatcher Spoon

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon Spoon](https://img.shields.io/badge/Hammerspoon-Spoon-FFA500.svg)](https://www.hammerspoon.org/docs/index.html)

A Hammerspoon Spoon that watches for processes that have gotten out of hand — sustained high CPU or memory usage — warns you with an actionable notification, and shows current status in the menu bar.

**Repository**: [https://github.com/hugoh/ProcessWatcher.spoon](https://github.com/hugoh/ProcessWatcher.spoon)

## Features

- Samples all processes on an interval and aggregates CPU%/memory% **by process name**, so an app that stays heavy via a rotating cast of short-lived child processes (browser/Electron helpers, etc.) is still caught, not just a single long-lived runaway PID
- Leaky-bucket sustain tracking: a process must stay over threshold for a configurable duration before it's flagged, and a brief dip below threshold doesn't wipe out all accumulated progress
- Actionable notification when a process trips a threshold, with **Terminate** and **Ignore** buttons right on the alert — auto-withdrawn if you never act on it and the process resolves on its own (recovers, gets killed/ignored via the menu or CLI, or gets added to the allowlist mid-flight)
- Menu bar 🌡️ icon showing currently-flagged processes (with a Kill/Ignore submenu per entry) and top-CPU/top-memory processes at a glance
- Configurable allowlist for processes that should never be flagged (compilers, encoders, backups, etc.), plus a temporary snooze via the notification's Ignore action
- Per-process threshold/sustain overrides, matched by Lua pattern (e.g. give Teams' helper processes more headroom before alerting)
- CLI (`bin/processwatcher`), built on Hammerspoon's `hs` IPC tool, for querying status, killing a process, and inspecting config from the terminal
- Config file is human-editable JSON, with a menu item to open it directly

## Installation

Ensure you have [Hammerspoon](https://www.hammerspoon.org) installed, then choose a method:

### Release zip (recommended)

1. Download `ProcessWatcher.spoon.zip` from the [latest release](https://github.com/hugoh/ProcessWatcher.spoon/releases/latest)
2. Unzip — this produces a `ProcessWatcher.spoon` folder
3. Move it to `~/.hammerspoon/Spoons/`
4. Reload Hammerspoon (menu bar icon → Reload Config, or run `hs.reload()` in the console)

### SpoonInstall (if you already use it)

```lua
spoon.SpoonInstall:installSpoonFromZip(
  "https://github.com/hugoh/ProcessWatcher.spoon/releases/latest/download/ProcessWatcher.spoon.zip"
)
```

### Clone from git (for development or latest changes)

```bash
cd ~/.hammerspoon/Spoons
git clone https://github.com/hugoh/ProcessWatcher.spoon.git
```

## Configuration

Add the following to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("ProcessWatcher"):start()
```

Config lives at `~/.config/ProcessWatcher/config.json` (created with defaults on first run). You can also set it from Lua before starting:

```lua
hs.loadSpoon("ProcessWatcher"):configure({
  interval = 30,               -- seconds between samples
  cpuThreshold = 90,           -- percent CPU (can exceed 100 for multi-threaded processes)
  memThreshold = 25,           -- percent of physical RAM
  sustainSeconds = 600,        -- how long a process must stay over threshold before alerting
  snoozeHours = 2,             -- how long the notification's "Ignore" action suppresses alerts
  terminateGraceSeconds = 2,   -- wait after SIGTERM before escalating to SIGKILL
  topCount = 5,                -- how many processes to show in the "Top CPU"/"Top Memory" sections
  notify = true,               -- whether to send a notification when a process is flagged
  allowlist = { "Xcode", "ffmpeg" },
  overrides = {                       -- per-process threshold/sustain overrides
    { pattern = "Teams", cpuThreshold = 200, sustainSeconds = 600 },
  },
}):start()
```

`interval` must be strictly less than `sustainSeconds` (and both must be positive) — `configure()`/`loadConfig()` raise a Lua `error()` otherwise, rather than silently accepting a config where the leaky-bucket sustain logic collapses to a single sample (`interval >= sustainSeconds` means a process flags on the very first over-threshold sample and unflags on the very next low one, with none of the intended dip-tolerance). This validation never mutates state before it passes: an invalid `configure()` call leaves the current config and any running monitoring completely untouched, and an invalid on-disk `config.json` only prevents a first-ever `start()` — it can't disrupt already-running monitoring via `reloadConfig()`, since `reloadConfig()` reads and validates the new config _before_ stopping the old one.

### Per-process overrides

`overrides` is an ordered list of `{ pattern, cpuThreshold, memThreshold, sustainSeconds }`. `pattern` is a [Lua pattern](https://www.lua.org/manual/5.4/manual.html#6.4.1) (not full regex — similar spirit, different syntax: no alternation `|`, quantifiers are `*`/`+`/`-`/`?`) matched against the process name with `name:find(pattern)`. The **first** entry in the list whose pattern matches wins; any of `cpuThreshold`/`memThreshold`/`sustainSeconds` left unset on that entry fall back to the global config.

- Plain patterns match as a substring: `"Teams"` matches `"Teams"`, `"Teams Helper (Renderer)"`, `"Teams Helper (GPU)"`, etc. — handy for covering every helper process an Electron app spawns with one rule.
- Anchor with `^`/`$` for an exact match: `"^Teams$"` matches only a process literally named `Teams`.
- Magic characters (`( ) . % + - * ? [ ] ^ $`) in a literal name need escaping with `%`, e.g. `"^Teams Helper %(Renderer%)$"`.
- A malformed pattern is logged as a warning and skipped (falls through to the next rule / global config) rather than crashing evaluation.

## Menu Bar

Click the 🌡️ icon (shown as 🌡️! while something is flagged) to see:

1. **Flagged** — currently-flagged processes with live CPU%/Mem%, each with a submenu to **Terminate** or **Ignore for &lt;N&gt;h**. Omitted entirely when nothing is flagged.
2. **Top CPU** / **Top Memory** — the top `topCount` processes by each metric, shown even when nothing is flagged, for at-a-glance status.
3. **Edit Config…** — opens the raw JSON config file in your default editor.

Note: on a crowded menu bar (many status items, or a notched MacBook Pro display), macOS can silently squeeze status items off-screen entirely. If the icon disappears, ProcessWatcher is still running and monitoring in the background — the [CLI](#cli) works regardless of whether the icon is visible.

## Methods

- `configure(cfg)` - Merge settings into the config, persist them, and restart monitoring if already running
- `loadConfig()` / `saveConfig()` - Load/save the JSON config file directly
- `reloadConfig()` - Re-read `config.json` from disk (e.g. after hand-editing it) and restart monitoring if running
- `openConfig()` - Open the config file in your default JSON editor
- `start()` - Begin periodic sampling and show the menu bar icon
- `stop()` - Stop sampling and remove the menu bar icon
- `kill(nameOrPid)` - Terminate a process by name (all PIDs currently aggregated under that name) or PID; sends SIGTERM, escalates to SIGKILL if it's still alive after `terminateGraceSeconds`
- `ignore(name)` - Snooze alerts for a process name for `snoozeHours`
- `status()` - Human-readable summary of currently-flagged processes (name, CPU/mem%, time flagged, PIDs), processes still accumulating sustain ticks toward a flag (closest-to-flagging first), and the current top CPU/memory processes
- `configSummary()` - Human-readable summary of current thresholds/sustain/interval/allowlist/overrides

## CLI

`bin/processwatcher` wraps Hammerspoon's `hs` IPC CLI. Install it once from the Hammerspoon console:

```lua
hs.ipc.cliInstall()
```

Then, with `ProcessWatcher` loaded and running:

```bash
processwatcher status              # flagged processes, processes trending toward a flag, and top CPU/memory processes
processwatcher kill <name|pid>     # terminate a process
processwatcher config              # print current thresholds/sustain/interval/allowlist/overrides
processwatcher reload              # re-read config.json from disk and restart monitoring if running
```

## Security & Permissions

ProcessWatcher samples processes by shelling out to `/bin/ps` and terminates them via `/bin/kill`, both running as your user — it can only see and kill processes you already have permission to (not other users' or root-owned processes, without `sudo`, which ProcessWatcher never uses). Notifications go through macOS's standard notification system, so the first alert may prompt you to allow notifications for Hammerspoon if you haven't already.

## API documentation

Full API reference is available at **<https://hugoh.github.io/ProcessWatcher.spoon/>**.
