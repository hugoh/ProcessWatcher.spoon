-- vim: set ft=lua:

--- === ProcessWatcher ===
---
--- A Hammerspoon Spoon that watches for processes that have gotten out of
--- hand (sustained high CPU or memory usage), warns via an actionable macOS
--- notification, and shows current status in the menu bar.
---
--- Download: https://github.com/hugoh/ProcessWatcher.spoon/releases/latest

local obj = {}
obj.__index = obj

obj.name = "ProcessWatcher"
obj.version = "dev"
obj.author = "Hugo Haas"
obj.license = "MIT"
obj.homepage = "https://github.com/hugoh/ProcessWatcher.spoon"

--- ProcessWatcher.configPath
--- Variable
--- Path to the JSON config file (default: ~/.config/ProcessWatcher/config.json).
obj.configPath = os.getenv("HOME") .. "/.config/ProcessWatcher/config.json"

obj._menu = nil
obj._timer = nil
obj._running = false
obj._config = nil
obj.log = hs.logger.new("ProcessWatcher", "info")

-- Leaky-bucket sustain counters, keyed by metric ("cpu"/"mem") then process name.
obj._counters = { cpu = {}, mem = {} }
-- Currently-flagged names -> { since=, cpu=bool, cpu_value=, mem=bool, mem_value=, pids={} }.
obj._flagged = {}
-- Process name -> epoch seconds until which alerts are snoozed (from the notification's Ignore action).
obj._snooze = {}
-- Most recent aggregated-by-name sample: name -> { cpu=, mem=, pids={} }.
obj._lastSample = {}
-- "name:metric" -> the hs.notify object for a still-outstanding (not acted on) alert, so it
-- can be withdrawn if the flag clears before the user acts on it.
obj._pendingNotifications = {}

local DEFAULT_CONFIG = {
	interval = 30, -- seconds between samples
	cpuThreshold = 90, -- percent CPU (can exceed 100 for multi-threaded processes)
	memThreshold = 25, -- percent of physical RAM
	sustainSeconds = 600, -- how long a process must stay over threshold before alerting
	snoozeHours = 2, -- how long the notification's "Ignore" action suppresses alerts
	terminateGraceSeconds = 20, -- wait after SIGTERM before escalating to SIGKILL
	topCount = 5, -- how many processes to show in the "Top CPU"/"Top Memory" menu sections
	notify = true,
	allowlist = {}, -- process names that are never flagged
	-- Per-process overrides: list of { pattern=<Lua pattern>, cpuThreshold=, memThreshold=, sustainSeconds= }.
	-- Matched against process names with name:find(pattern); first match in list order wins.
	-- Fields left unset on a matching entry fall back to the global values above.
	overrides = {},
}

-- hs.fnutils.copy errors on a nil argument, so callers pass `t or {}`.

-- Validates the global (not per-override) config. In particular, interval >= sustainSeconds
-- silently collapses the leaky-bucket sustain logic to a single sample (ticks == 1): a process
-- flags on the very first over-threshold sample and unflags on the very next under-threshold one,
-- with none of the dip-tolerance the leaky bucket is meant to provide. Per-override sustainSeconds
-- is intentionally NOT validated this way: a near-instant override for a specific process is a
-- legitimate, deliberate choice, unlike an accidental global misconfiguration.
local function validateConfig(cfg)
	if type(cfg.interval) ~= "number" or cfg.interval <= 0 then return false, "interval must be a positive number" end
	if type(cfg.sustainSeconds) ~= "number" or cfg.sustainSeconds <= 0 then
		return false, "sustainSeconds must be a positive number"
	end
	if cfg.interval >= cfg.sustainSeconds then
		return false,
			string.format(
				"interval (%s) must be less than sustainSeconds (%s) -- otherwise sustained-usage "
					.. "tolerance collapses to a single sample",
				tostring(cfg.interval),
				tostring(cfg.sustainSeconds)
			)
	end
	return true
end

--- ProcessWatcher:loadConfig()
--- Method
--- Loads config from `configPath`, filling in defaults for missing keys. Errors (via `error()`)
--- if the resulting config is invalid (e.g. interval >= sustainSeconds) without touching any
--- previously-loaded config -- so a broken on-disk file can never disrupt already-running
--- monitoring via reloadConfig(), only prevent a first-ever start().
function obj:loadConfig()
	local config = hs.json.read(self.configPath)
	-- hs.json.read returns nil both when the file is missing and when it exists
	-- but fails to parse (malformed JSON). Distinguish the two via hs.fs.attributes
	-- so a corrupt file is surfaced instead of being silently discarded and
	-- immediately overwritten with an empty default config.
	local parseFailed = config == nil and hs.fs.attributes(self.configPath) ~= nil
	config = config or {}
	local candidate = {}
	for k, v in pairs(DEFAULT_CONFIG) do
		if config[k] ~= nil then
			candidate[k] = config[k]
		else
			candidate[k] = v
		end
	end
	candidate.allowlist = hs.fnutils.copy(config.allowlist or {})
	candidate.overrides = hs.fnutils.copy(config.overrides or {})

	local ok, err = validateConfig(candidate)
	if not ok then error("ProcessWatcher: invalid config at " .. self.configPath .. ": " .. err, 2) end
	self._config = candidate

	if parseFailed then
		self.log.w(
			"Config file at "
				.. self.configPath
				.. " could not be parsed as JSON; leaving it on disk untouched "
				.. "and using defaults in memory for this session"
		)
	else
		self:saveConfig()
	end
	self.log.i("Config loaded from " .. self.configPath)
	return self
end

--- ProcessWatcher:saveConfig()
--- Method
--- Writes the current in-memory config to `configPath`.
function obj:saveConfig()
	local dir = string.match(self.configPath, "^(.*)/[^/]+$")
	if dir then hs.fs.mkdir(dir) end
	local ok = hs.json.write(self._config, self.configPath, true, true)
	if ok then
		self.log.i("Config saved to " .. self.configPath)
	else
		self.log.e("Failed to save config to " .. self.configPath)
	end
	return self
end

--- ProcessWatcher:configure(cfg)
--- Method
--- Merges `cfg` into the current config, persists it, and restarts monitoring if running. Errors
--- (via `error()`) if the resulting config is invalid (e.g. interval >= sustainSeconds) without
--- applying or persisting any of it -- currently-running monitoring, if any, is left untouched.
function obj:configure(cfg)
	if not self._config then self:loadConfig() end
	local candidate = hs.fnutils.copy(self._config)
	for k, v in pairs(cfg or {}) do
		if DEFAULT_CONFIG[k] ~= nil then candidate[k] = v end
	end

	local ok, err = validateConfig(candidate)
	if not ok then error("ProcessWatcher: invalid config: " .. err, 2) end
	self._config = candidate

	self:saveConfig()
	if self._running then
		self:stop()
		self:start()
	end
	return self
end

--- ProcessWatcher:reloadConfig()
--- Method
--- Re-reads `configPath` from disk (e.g. after hand-editing it) and restarts monitoring if running.
function obj:reloadConfig()
	local wasRunning = self._running
	self:loadConfig()
	if wasRunning then
		self:stop()
		self:start()
	end
	return self
end

--- ProcessWatcher:openConfig()
--- Method
--- Opens the config file in the user's default editor for JSON files.
function obj:openConfig() hs.open(self.configPath) end

function obj:_sustainTicks(sustainSeconds)
	sustainSeconds = sustainSeconds or self._config.sustainSeconds
	return math.max(1, math.floor(sustainSeconds / self._config.interval))
end

-- Returns the effective { cpuThreshold, memThreshold, sustainSeconds } for a process
-- name: the first entry in config.overrides whose pattern matches `name` (via
-- name:find(pattern)), with any fields it leaves unset falling back to the global
-- config, or the global config outright if no override matches.
function obj:_thresholdsFor(name)
	local cfg = self._config
	for _, o in ipairs(cfg.overrides or {}) do
		if o.pattern then
			local ok, matchStart = pcall(string.find, name, o.pattern)
			if not ok then
				self.log.wf("Invalid override pattern %q: %s", tostring(o.pattern), tostring(matchStart))
			elseif matchStart then
				return {
					cpuThreshold = o.cpuThreshold or cfg.cpuThreshold,
					memThreshold = o.memThreshold or cfg.memThreshold,
					sustainSeconds = o.sustainSeconds or cfg.sustainSeconds,
				}
			end
		end
	end
	return { cpuThreshold = cfg.cpuThreshold, memThreshold = cfg.memThreshold, sustainSeconds = cfg.sustainSeconds }
end

function obj:_isExcluded(name)
	if hs.fnutils.contains(self._config.allowlist, name) then return true end
	local expiry = self._snooze[name]
	if expiry then
		if expiry > os.time() then return true end
		self._snooze[name] = nil
	end
	return false
end

-- Parses `ps -A -c -o pid=,pcpu=,pmem=,comm=` output into pid -> {pid, cpu, mem, name}.
-- Uses `-c` so `comm` is the bare executable name (no args/path), which keeps the
-- trailing `(.+)$` capture safe for names containing spaces (e.g. "Google Chrome Helper").
-- Lines that don't match the expected shape are logged and skipped rather than silently
-- dropped, since silent drops are how the prior implementation masked missing processes.
local function parsePs(self, output)
	local byPid = {}
	for line in output:gmatch("[^\r\n]+") do
		local pid, cpu, mem, name = line:match("^%s*(%d+)%s+([%d%.]+)%s+([%d%.]+)%s+(.+)$")
		if pid and cpu and mem and name then
			byPid[pid] = { pid = pid, cpu = tonumber(cpu), mem = tonumber(mem), name = name }
		else
			self.log.wf("Skipping unparsable ps line: %s", line)
		end
	end
	return byPid
end

local function aggregateByName(byPid)
	local byName = {}
	for _, p in pairs(byPid) do
		local entry = byName[p.name]
		if not entry then
			entry = { name = p.name, cpu = 0, mem = 0, pids = {} }
			byName[p.name] = entry
		end
		entry.cpu = entry.cpu + p.cpu
		entry.mem = entry.mem + p.mem
		table.insert(entry.pids, p.pid)
	end
	-- pairs(byPid) iterates in unspecified order, so sort each name's PID list
	-- (numerically) for stable, readable output in status()/the menu bar.
	for _, entry in pairs(byName) do
		table.sort(entry.pids, function(a, b) return tonumber(a) < tonumber(b) end)
	end
	return byName
end

-- Withdraws a still-outstanding (not clicked) notification for name/metric, if any.
-- Safe to call even if there's nothing pending, or if the notification was already
-- dismissed by the user/OS (hs.notify:withdraw() on those is a harmless no-op).
function obj:_withdrawNotification(name, metric)
	local key = name .. ":" .. metric
	local note = self._pendingNotifications[key]
	if note then
		pcall(function() note:withdraw() end)
		self._pendingNotifications[key] = nil
	end
end

function obj:_unflag(name, metric)
	self:_withdrawNotification(name, metric)
	if not self._flagged[name] then return end
	self._flagged[name][metric] = nil
	if not self._flagged[name].cpu and not self._flagged[name].mem then self._flagged[name] = nil end
end

-- Clears both metrics' flags/notifications for name in one call, used when a process is
-- resolved through a channel other than waiting for the leaky bucket to decay (killed,
-- ignored, or newly allowlisted mid-flight).
function obj:_clearFlag(name)
	self._flagged[name] = nil
	self:_withdrawNotification(name, "cpu")
	self:_withdrawNotification(name, "mem")
end

function obj:_flag(name, metric, value, sustainSeconds, pids)
	self._flagged[name] = self._flagged[name] or { since = os.time() }
	local wasFlagged = self._flagged[name][metric]
	self._flagged[name][metric] = true
	self._flagged[name][metric .. "_value"] = value
	self._flagged[name].pids = pids
	if not wasFlagged then
		self.log.i(string.format("Flagged %s: %s=%.1f", name, metric, value))
		if self._config.notify then self:_notify(name, metric, value, sustainSeconds) end
	end
end

-- Leaky bucket: a sample over threshold increments the counter (capped at `ticks`),
-- a sample under threshold decrements it (floored at 0) rather than resetting to 0.
-- This tolerates the brief dips a genuinely runaway process still has, instead of
-- wiping all accumulated progress on a single low sample.
function obj:_evaluateMetric(name, metric, value, threshold, ticks, sustainSeconds, pids)
	local counters = self._counters[metric]
	local count = counters[name] or 0
	if value >= threshold then
		count = math.min(ticks, count + 1)
	else
		count = math.max(0, count - 1)
	end
	counters[name] = count

	if count >= ticks then
		self:_flag(name, metric, value, sustainSeconds, pids)
	elseif count == 0 then
		self:_unflag(name, metric)
	end
end

function obj:_evaluate(byName)
	for _, metric in ipairs({ "cpu", "mem" }) do
		for name in pairs(self._counters[metric]) do
			if not byName[name] then
				self._counters[metric][name] = nil
				self:_unflag(name, metric)
			end
		end
	end

	for name, data in pairs(byName) do
		if self:_isExcluded(name) then
			self._counters.cpu[name] = nil
			self._counters.mem[name] = nil
			self:_clearFlag(name)
		else
			local t = self:_thresholdsFor(name)
			local ticks = self:_sustainTicks(t.sustainSeconds)
			self:_evaluateMetric(name, "cpu", data.cpu, t.cpuThreshold, ticks, t.sustainSeconds, data.pids)
			self:_evaluateMetric(name, "mem", data.mem, t.memThreshold, ticks, t.sustainSeconds, data.pids)
		end
	end
end

function obj:_notify(name, metric, value, sustainSeconds)
	local label = metric == "cpu" and "CPU" or "Memory"
	local note = hs.notify.new(function(notification)
		local activation = notification:activationType()
		if activation == hs.notify.activationTypes.actionButtonClicked then
			self:kill(name)
		elseif activation == hs.notify.activationTypes.additionalActionClicked then
			self:ignore(name)
		end
	end, {
		title = "ProcessWatcher: high " .. label .. " usage",
		-- %.0f (not %d) since sustainSeconds can be a non-integer (e.g. from JSON config).
		informativeText = string.format("%s has used %.0f%% %s for %.0fs+", name, value, label, sustainSeconds),
		hasActionButton = true,
		actionButtonTitle = "Terminate",
		otherButtonTitle = "Ignore",
		withdrawAfter = 0,
	})
	self._pendingNotifications[name .. ":" .. metric] = note
	note:send()
	return note
end

--- ProcessWatcher:ignore(name)
--- Method
--- Snoozes alerts for `name` for `config.snoozeHours` and clears any current flag on it.
function obj:ignore(name)
	self._snooze[name] = os.time() + (self._config.snoozeHours * 3600)
	self._counters.cpu[name] = nil
	self._counters.mem[name] = nil
	self:_clearFlag(name)
	self.log.i(string.format("Snoozing alerts for %s for %.0fh", name, self._config.snoozeHours))
	self:_updateMenu()
end

function obj:_terminatePid(pid)
	self.log.i("Terminating pid " .. pid .. " (SIGTERM)")
	hs.execute("/bin/kill -TERM " .. pid)
	hs.timer.doAfter(self._config.terminateGraceSeconds, function()
		-- kill -0 exits 0 iff the pid is still alive; hs.execute's 4th return value
		-- is the exit code (its 2nd return reflects task-launch success, not exit status).
		local _, _, _, rc = hs.execute("/bin/kill -0 " .. pid .. " 2>/dev/null")
		if rc == 0 then
			self.log.w("pid " .. pid .. " still alive after grace period, sending SIGKILL")
			hs.execute("/bin/kill -KILL " .. pid)
		end
	end)
end

--- ProcessWatcher:kill(nameOrPid)
--- Method
--- Terminates a process by name (all PIDs currently aggregated under that name in the
--- last sample) or by PID (numeric string/number). Returns true if any PID was targeted.
function obj:kill(nameOrPid)
	local key = tostring(nameOrPid)
	local pids = {}
	if key:match("^%d+$") then
		table.insert(pids, key)
	else
		local entry = self._lastSample[key]
		if entry then pids = hs.fnutils.copy(entry.pids) end
	end
	if #pids == 0 then
		self.log.w("No matching process found for " .. key)
		return false
	end
	for _, pid in ipairs(pids) do
		self:_terminatePid(pid)
	end
	self:_clearFlag(key)
	self._counters.cpu[key] = nil
	self._counters.mem[key] = nil
	self:_updateMenu()
	return true
end

function obj:_topProcesses()
	local list = {}
	for name, data in pairs(self._lastSample) do
		table.insert(list, { name = name, cpu = data.cpu, mem = data.mem, pids = data.pids })
	end
	local byCpu = hs.fnutils.copy(list)
	table.sort(byCpu, function(a, b) return a.cpu > b.cpu end)
	local byMem = hs.fnutils.copy(list)
	table.sort(byMem, function(a, b) return a.mem > b.mem end)
	local function trim(t)
		local out = {}
		for i = 1, math.min(self._config.topCount, #t) do
			out[i] = t[i]
		end
		return out
	end
	return trim(byCpu), trim(byMem)
end

function obj:_updateMenu()
	if not self._menu then return end

	local flaggedNames = {}
	for name in pairs(self._flagged) do
		table.insert(flaggedNames, name)
	end
	table.sort(flaggedNames)

	local menu = {}
	if #flaggedNames > 0 then
		table.insert(menu, { title = "Flagged", disabled = true })
		for _, name in ipairs(flaggedNames) do
			local f = self._flagged[name]
			local parts = {}
			if f.cpu then table.insert(parts, string.format("CPU %.0f%%", f.cpu_value or 0)) end
			if f.mem then table.insert(parts, string.format("Mem %.0f%%", f.mem_value or 0)) end
			table.insert(menu, {
				title = string.format("  %s (%s)", name, table.concat(parts, ", ")),
				menu = {
					{ title = "Terminate", fn = function() self:kill(name) end },
					{
						title = string.format("Ignore for %.0fh", self._config.snoozeHours),
						fn = function() self:ignore(name) end,
					},
				},
			})
		end
		table.insert(menu, { title = "-" })
	end

	local topCpu, topMem = self:_topProcesses()
	table.insert(menu, { title = "Top CPU", disabled = true })
	for _, e in ipairs(topCpu) do
		table.insert(menu, { title = string.format("  %s — %.0f%%", e.name, e.cpu) })
	end
	table.insert(menu, { title = "Top Memory", disabled = true })
	for _, e in ipairs(topMem) do
		table.insert(menu, { title = string.format("  %s — %.0f%%", e.name, e.mem) })
	end

	table.insert(menu, { title = "-" })
	table.insert(menu, { title = "Edit Config…", fn = function() self:openConfig() end })

	self._menu:setMenu(menu)
	self._menu:setTitle(#flaggedNames > 0 and "🌡️!" or "🌡️")
end

function obj:_sample()
	local out = hs.execute("/bin/ps -A -c -o pid=,pcpu=,pmem=,comm=")
	if not out or out == "" then
		self.log.w("ps returned no output")
		return
	end
	local byPid = parsePs(self, out)
	local byName = aggregateByName(byPid)
	self._lastSample = byName
	self:_evaluate(byName)
	self:_updateMenu()
end

--- ProcessWatcher:status()
--- Method
--- Returns a human-readable summary of currently-flagged processes, processes still
--- accumulating sustain ticks toward a flag, and the current top CPU/memory processes
--- (used by the CLI).
local function pidStr(pids) return (pids and #pids > 0) and table.concat(pids, ",") or "?" end

-- Builds "Tracking (not yet flagged)" lines: names with a nonzero leaky-bucket counter
-- on either metric that aren't already flagged (those are covered by the Flagged:
-- section and their counters are typically pinned at the cap). Sorted by proximity to
-- flagging -- highest ticks/ticksRequired ratio first -- so what's about to trip next
-- shows up on top, tie-broken by name for stable ordering.
function obj:_trackingLines()
	local entries = {}
	local seen = {}
	for _, metric in ipairs({ "cpu", "mem" }) do
		for name, count in pairs(self._counters[metric]) do
			if count > 0 and not self._flagged[name] and not seen[name] then
				seen[name] = true
				local ticksRequired = self:_sustainTicks(self:_thresholdsFor(name).sustainSeconds)
				local sample = self._lastSample[name]
				local parts = {}
				local maxRatio = 0
				for _, m in ipairs({ "cpu", "mem" }) do
					local c = self._counters[m][name] or 0
					if c > 0 then
						local value = sample and sample[m] or 0
						local label = m == "cpu" and "CPU" or "Mem"
						table.insert(parts, string.format("%s %d/%d ticks (%.0f%%)", label, c, ticksRequired, value))
						maxRatio = math.max(maxRatio, c / ticksRequired)
					end
				end
				table.insert(entries, { name = name, text = table.concat(parts, ", "), ratio = maxRatio })
			end
		end
	end
	table.sort(entries, function(a, b)
		if a.ratio ~= b.ratio then return a.ratio > b.ratio end
		return a.name < b.name
	end)
	local lines = {}
	for _, e in ipairs(entries) do
		table.insert(lines, string.format("  %s: %s", e.name, e.text))
	end
	return lines
end

function obj:status()
	local names = {}
	for name in pairs(self._flagged) do
		table.insert(names, name)
	end
	table.sort(names)

	local lines = {}
	if #names == 0 then
		table.insert(lines, "No flagged processes.")
	else
		table.insert(lines, "Flagged:")
		for _, name in ipairs(names) do
			local f = self._flagged[name]
			local elapsed = os.time() - f.since
			local parts = {}
			if f.cpu then table.insert(parts, string.format("CPU %.0f%%", f.cpu_value or 0)) end
			if f.mem then table.insert(parts, string.format("Mem %.0f%%", f.mem_value or 0)) end
			table.insert(
				lines,
				string.format(
					"  %s: %s (flagged %ds ago, pid=%s)",
					name,
					table.concat(parts, ", "),
					elapsed,
					pidStr(f.pids)
				)
			)
		end
	end

	local trackingLines = self:_trackingLines()
	if #trackingLines > 0 then
		table.insert(lines, "Tracking (not yet flagged):")
		for _, l in ipairs(trackingLines) do
			table.insert(lines, l)
		end
	end

	if next(self._lastSample) ~= nil then
		local topCpu, topMem = self:_topProcesses()
		table.insert(lines, "Top CPU:")
		for _, e in ipairs(topCpu) do
			table.insert(lines, string.format("  %s (pid=%s) — %.0f%%", e.name, pidStr(e.pids), e.cpu))
		end
		table.insert(lines, "Top Memory:")
		for _, e in ipairs(topMem) do
			table.insert(lines, string.format("  %s (pid=%s) — %.0f%%", e.name, pidStr(e.pids), e.mem))
		end
	end

	return table.concat(lines, "\n")
end

--- ProcessWatcher:configSummary()
--- Method
--- Returns a one-line summary of the current thresholds/sustain/interval/allowlist/overrides config (used by the CLI).
function obj:configSummary()
	local c = self._config
	local overrideParts = {}
	for _, o in ipairs(c.overrides or {}) do
		table.insert(
			overrideParts,
			string.format(
				"%s(cpu=%s,mem=%s,sustain=%s)",
				o.pattern,
				o.cpuThreshold and (o.cpuThreshold .. "%") or "-",
				o.memThreshold and (o.memThreshold .. "%") or "-",
				o.sustainSeconds and (o.sustainSeconds .. "s") or "-"
			)
		)
	end
	return string.format(
		"interval=%.0fs cpuThreshold=%.0f%% memThreshold=%.0f%% sustainSeconds=%.0fs snoozeHours=%.0f "
			.. "allowlist=[%s] overrides=[%s]",
		c.interval,
		c.cpuThreshold,
		c.memThreshold,
		c.sustainSeconds,
		c.snoozeHours,
		table.concat(c.allowlist, ","),
		table.concat(overrideParts, ";")
	)
end

--- ProcessWatcher:start()
--- Method
--- Begins periodic sampling and shows the menu bar icon.
function obj:start()
	if not self._config then self:loadConfig() end
	if self._timer then self:stop() end
	self._menu = hs.menubar.new()
	if not hs.ipc then
		self.log.w(
			"hs.ipc is not loaded, so bin/processwatcher (the CLI) will not be able to "
				.. 'reach this Spoon. Add require("hs.ipc") to your Hammerspoon init.lua to enable it.'
		)
	end
	self.log.f(
		"Starting %s v%s (interval=%.0fs, cpu>=%.0f%%, mem>=%.0f%%, sustain=%.0fs)",
		self.name,
		self.version,
		self._config.interval,
		self._config.cpuThreshold,
		self._config.memThreshold,
		self._config.sustainSeconds
	)
	self:_sample()
	self._timer = hs.timer.doEvery(self._config.interval, function() self:_sample() end)
	self._running = true
	return self
end

--- ProcessWatcher:stop()
--- Method
--- Stops sampling and removes the menu bar icon.
function obj:stop()
	if self._timer then
		self._timer:stop()
		self._timer = nil
	end
	if self._menu then
		self._menu:delete()
		self._menu = nil
	end
	self._running = false
	self.log.f("Stopped %s v%s", self.name, self.version)
	return self
end

return obj
