-- luacheck: std +busted
-- luacheck: globals hs
-- luacheck: globals assert (are (equal same) is_true is_nil)
-- Busted tests for ProcessWatcher Spoon using a mock hs environment.

local mock_hs
local ProcessWatcher

local function makeLogger()
	local l = { _infos = {}, _warnings = {}, _errors = {} }
	l.i = function(msg) table.insert(l._infos, msg) end
	l.f = function(fmt, ...) table.insert(l._infos, string.format(fmt, ...)) end
	l.w = function(msg) table.insert(l._warnings, msg) end
	l.wf = function(fmt, ...) table.insert(l._warnings, string.format(fmt, ...)) end
	l.e = function(msg) table.insert(l._errors, msg) end
	l.d = function() end
	l.df = function() end
	return l
end

before_each(function()
	local config_store = {}
	local exec_handler = function(_cmd) return "", true, "exit", 0 end
	local timers = {}

	mock_hs = {
		logger = { new = function() return makeLogger() end },
		json = {
			read = function(path) return config_store[path] end,
			write = function(data, path, _pretty, _ensureAscii)
				config_store[path] = data
				return true
			end,
		},
		fs = {
			mkdir = function(_p) return true end,
			attributes = function(p) return config_store[p] and {} or nil end,
		},
		fnutils = {
			copy = function(t)
				local out = {}
				for k, v in pairs(t) do
					out[k] = v
				end
				return out
			end,
			contains = function(t, val)
				for _, v in ipairs(t) do
					if v == val then return true end
				end
				return false
			end,
		},
		notify = {
			_sent = {},
			activationTypes = {
				closed = 0,
				contentsClicked = 1,
				actionButtonClicked = 2,
				replied = 3,
				additionalActionClicked = 4,
			},
		},
		timer = { _all = timers },
		menubar = {
			new = function()
				local m = {}
				function m:setTitle(t) self._title = t end
				function m:setMenu(items) self._menuItems = items end
				function m:delete() self._deleted = true end
				return m
			end,
		},
	}

	mock_hs._opened = {}
	mock_hs.open = function(p) table.insert(mock_hs._opened, p) end

	mock_hs.execute = function(cmd) return exec_handler(cmd) end
	mock_hs._setExecHandler = function(fn) exec_handler = fn end

	mock_hs.timer.doAfter = function(_delay, fn)
		local t = { _fn = fn, _stopped = false, _recurring = false }
		function t:stop() self._stopped = true end
		table.insert(timers, t)
		return t
	end
	mock_hs.timer.doEvery = function(_interval, fn)
		local t = { _fn = fn, _stopped = false, _recurring = true }
		function t:stop() self._stopped = true end
		table.insert(timers, t)
		return t
	end
	mock_hs._fireTimers = function()
		-- Fire (and clear) all pending one-shot doAfter timers; recurring
		-- doEvery timers are left alone (call their _fn directly instead).
		local pending = {}
		for _, t in ipairs(timers) do
			if not t._recurring and not t._stopped then table.insert(pending, t) end
		end
		timers = {}
		for i, t in ipairs(mock_hs.timer._all) do
			if t._recurring then table.insert(timers, t) end
			mock_hs.timer._all[i] = nil
		end
		for _, t in ipairs(timers) do
			table.insert(mock_hs.timer._all, t)
		end
		for _, t in ipairs(pending) do
			t._fn()
		end
	end

	mock_hs.notify._withdrawn = {}
	mock_hs.notify.new = function(fn, attrs)
		local n = { _fn = fn, _attrs = attrs, _withdrawn = false }
		function n:send() table.insert(mock_hs.notify._sent, { attrs = self._attrs, fn = self._fn, note = self }) end
		function n:withdraw()
			self._withdrawn = true
			table.insert(mock_hs.notify._withdrawn, self._attrs)
		end
		return n
	end

	mock_hs._setConfig = function(path, cfg) config_store[path] = cfg end

	package.loaded.hs = nil
	_G.hs = mock_hs

	ProcessWatcher = dofile("init.lua")
end)

-- Simulates the user clicking a notification action button.
local function fireNotification(entry, activationType)
	entry.fn({ activationType = function() return activationType end })
end

describe("ProcessWatcher", function()
	describe("module structure", function()
		it("returns a table", function() assert.is.table(ProcessWatcher) end)

		it("has name", function() assert.are.equal("ProcessWatcher", ProcessWatcher.name) end)

		it("has configPath ending in config.json", function()
			assert.is.string(ProcessWatcher.configPath)
			assert.truthy(ProcessWatcher.configPath:find("config.json$"))
		end)

		it("has required methods", function()
			for _, m in ipairs({
				"loadConfig",
				"saveConfig",
				"configure",
				"reloadConfig",
				"openConfig",
				"status",
				"configSummary",
				"kill",
				"ignore",
				"start",
				"stop",
			}) do
				assert.are.equal("function", type(ProcessWatcher[m]))
			end
		end)

		it("initializes with nil menu and config", function()
			assert.is_nil(ProcessWatcher._menu)
			assert.is_nil(ProcessWatcher._config)
		end)
	end)

	describe("loadConfig", function()
		it("fills in defaults when file missing", function()
			ProcessWatcher:loadConfig()
			assert.are.equal(30, ProcessWatcher._config.interval)
			assert.are.equal(90, ProcessWatcher._config.cpuThreshold)
			assert.are.equal(25, ProcessWatcher._config.memThreshold)
			assert.are.equal(0, #ProcessWatcher._config.allowlist)
		end)

		it("reads existing overrides from disk", function()
			mock_hs._setConfig(ProcessWatcher.configPath, { cpuThreshold = 50, allowlist = { "Xcode" } })
			ProcessWatcher:loadConfig()
			assert.are.equal(50, ProcessWatcher._config.cpuThreshold)
			assert.are.equal(25, ProcessWatcher._config.memThreshold) -- untouched default
			assert.are.equal(1, #ProcessWatcher._config.allowlist)
			assert.are.equal("Xcode", ProcessWatcher._config.allowlist[1])
		end)

		it("keeps a malformed file untouched instead of overwriting it", function()
			-- Simulate: file exists on disk (hs.fs.attributes truthy) but hs.json.read
			-- returned nil because it failed to parse.
			mock_hs.fs.attributes = function(_p) return {} end
			mock_hs.json.read = function(_p) return nil end
			local writeCalled = false
			mock_hs.json.write = function()
				writeCalled = true
				return true
			end
			ProcessWatcher:loadConfig()
			assert.is_false(writeCalled)
			assert.are.equal(1, #ProcessWatcher.log._warnings)
		end)
	end)

	describe("reloadConfig", function()
		it("picks up changes written to disk since the last load", function()
			ProcessWatcher:loadConfig()
			assert.are.equal(90, ProcessWatcher._config.cpuThreshold)
			mock_hs._setConfig(ProcessWatcher.configPath, { cpuThreshold = 42 })
			ProcessWatcher:reloadConfig()
			assert.are.equal(42, ProcessWatcher._config.cpuThreshold)
		end)

		it("does not start monitoring if it wasn't already running", function()
			ProcessWatcher:loadConfig()
			ProcessWatcher:reloadConfig()
			assert.is_false(ProcessWatcher._running)
			assert.is_nil(ProcessWatcher._menu)
		end)

		it("restarts monitoring with the reloaded config if it was running", function()
			mock_hs._setExecHandler(function(_cmd) return "111  10.0  1.0 Finder\n", true, "exit", 0 end)
			ProcessWatcher:start()
			mock_hs._setConfig(ProcessWatcher.configPath, { cpuThreshold = 42 })
			ProcessWatcher:reloadConfig()
			assert.is_true(ProcessWatcher._running)
			assert.are.equal(42, ProcessWatcher._config.cpuThreshold)
		end)
	end)

	describe("sample parsing and name aggregation", function()
		before_each(function() ProcessWatcher:loadConfig() end)

		it("aggregates CPU/memory across PIDs sharing a name", function()
			mock_hs._setExecHandler(function(_cmd)
				local out = "111  50.0  2.0 Google Chrome Helper\n"
					.. "222  60.0  3.0 Google Chrome Helper\n"
					.. "333  10.0  1.0 Finder\n"
				return out, true, "exit", 0
			end)
			ProcessWatcher:_sample()
			local chrome = ProcessWatcher._lastSample["Google Chrome Helper"]
			assert.is.table(chrome)
			assert.are.equal(110.0, chrome.cpu)
			assert.are.equal(5.0, chrome.mem)
			assert.are.equal(2, #chrome.pids)
			assert.are.equal(10.0, ProcessWatcher._lastSample["Finder"].cpu)
		end)

		it("skips unparsable lines without failing the whole sample", function()
			mock_hs._setExecHandler(
				function(_cmd) return "not a valid ps line\n111  50.0  2.0 Finder\n", true, "exit", 0 end
			)
			ProcessWatcher:_sample()
			assert.is.table(ProcessWatcher._lastSample["Finder"])
			assert.truthy(#ProcessWatcher.log._warnings > 0)
		end)

		it("handles empty ps output without erroring", function()
			mock_hs._setExecHandler(function(_cmd) return "", true, "exit", 0 end)
			assert.has_no.errors(function() ProcessWatcher:_sample() end)
		end)
	end)

	describe("leaky-bucket sustain logic", function()
		before_each(function()
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 1, sustainSeconds = 3, cpuThreshold = 90 })
		end)

		local function sample(cpu)
			ProcessWatcher:_evaluate({ Hog = { name = "Hog", cpu = cpu, mem = 0, pids = { "1" } } })
		end

		it("does not flag before sustainSeconds worth of over-threshold samples", function()
			sample(95)
			sample(95)
			assert.is_nil(ProcessWatcher._flagged["Hog"])
			assert.are.equal(0, #mock_hs.notify._sent)
		end)

		it("flags once the tick count reaches the sustain threshold", function()
			sample(95)
			sample(95)
			sample(95)
			assert.is.table(ProcessWatcher._flagged["Hog"])
			assert.is_true(ProcessWatcher._flagged["Hog"].cpu)
			assert.are.equal(1, #mock_hs.notify._sent)
		end)

		it("tolerates a single dip below threshold instead of resetting progress", function()
			-- This is the exact bug the prior implementation had: one low sample
			-- should decrement, not zero, the sustain counter.
			sample(95) -- count 1
			sample(95) -- count 2
			sample(50) -- dip: count 1 (not 0)
			sample(95) -- count 2
			sample(95) -- count 3 -> flags
			assert.is.table(ProcessWatcher._flagged["Hog"])
		end)

		it("unflags once the counter fully decays back to 0", function()
			sample(95)
			sample(95)
			sample(95) -- flagged
			assert.is.table(ProcessWatcher._flagged["Hog"])
			sample(0)
			sample(0)
			sample(0) -- counter: 2,1,0
			assert.is_nil(ProcessWatcher._flagged["Hog"])
		end)

		it("withdraws the unacted notification once the process recovers on its own", function()
			sample(95)
			sample(95)
			sample(95) -- flagged, notification sent
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.are.equal(0, #mock_hs.notify._withdrawn)
			sample(0)
			sample(0)
			sample(0) -- decays back to 0, unflagged
			assert.are.equal(1, #mock_hs.notify._withdrawn)
		end)

		it("clears counters/flags for a process that disappears entirely", function()
			sample(95)
			sample(95)
			sample(95) -- flagged
			ProcessWatcher:_evaluate({}) -- Hog no longer present in this sample
			assert.is_nil(ProcessWatcher._flagged["Hog"])
			assert.is_nil(ProcessWatcher._counters.cpu["Hog"])
		end)
	end)

	describe("interval vs. sustainSeconds validation", function()
		local function sample(cpu)
			ProcessWatcher:_evaluate({ Hog = { name = "Hog", cpu = cpu, mem = 0, pids = { "1" } } })
		end

		it("_sustainTicks floors at 1 for a valid config where sustainSeconds barely exceeds interval", function()
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 600, sustainSeconds = 601 })
			assert.are.equal(1, ProcessWatcher:_sustainTicks())
		end)

		it("configure() rejects interval == sustainSeconds", function()
			ProcessWatcher:loadConfig()
			assert.has_error(function() ProcessWatcher:configure({ interval = 600, sustainSeconds = 600 }) end)
		end)

		it("configure() rejects interval > sustainSeconds", function()
			ProcessWatcher:loadConfig()
			assert.has_error(function() ProcessWatcher:configure({ interval = 600, sustainSeconds = 60 }) end)
		end)

		it("configure() rejects a non-positive interval or sustainSeconds", function()
			ProcessWatcher:loadConfig()
			assert.has_error(function() ProcessWatcher:configure({ interval = 0, sustainSeconds = 60 }) end)
			assert.has_error(function() ProcessWatcher:configure({ interval = 30, sustainSeconds = 0 }) end)
		end)

		it("an invalid configure() call leaves the previous config and running state untouched", function()
			mock_hs._setExecHandler(function(_cmd) return "111  10.0  1.0 Finder\n", true, "exit", 0 end)
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 60, sustainSeconds = 600 })
			ProcessWatcher:start()
			assert.has_error(function() ProcessWatcher:configure({ interval = 600, sustainSeconds = 600 }) end)
			assert.are.equal(60, ProcessWatcher._config.interval) -- unchanged
			assert.is_true(ProcessWatcher._running) -- still running on the old config
		end)

		it("loadConfig() rejects an invalid on-disk config without touching a previously-loaded one", function()
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 60, sustainSeconds = 600 })
			mock_hs._setConfig(ProcessWatcher.configPath, { interval = 600, sustainSeconds = 600 })
			assert.has_error(function() ProcessWatcher:loadConfig() end)
			assert.are.equal(60, ProcessWatcher._config.interval) -- old in-memory config survives
		end)

		it("reloadConfig() with a broken on-disk file leaves already-running monitoring untouched", function()
			mock_hs._setExecHandler(function(_cmd) return "111  10.0  1.0 Finder\n", true, "exit", 0 end)
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 60, sustainSeconds = 600 })
			ProcessWatcher:start()
			local timerBefore = ProcessWatcher._timer
			mock_hs._setConfig(ProcessWatcher.configPath, { interval = 600, sustainSeconds = 600 })
			assert.has_error(function() ProcessWatcher:reloadConfig() end)
			assert.is_true(ProcessWatcher._running)
			assert.are.equal(timerBefore, ProcessWatcher._timer) -- never stopped/restarted
			assert.are.equal(60, ProcessWatcher._config.interval)
		end)

		it(
			"collapsed dip-tolerance would otherwise be a real misconfiguration trap "
				.. "(ticks == 1, demonstrated directly against _evaluate without going through configure())",
			function()
				-- validateConfig() is only wired into configure()/loadConfig(); this shows *why*
				-- it exists by driving the leaky bucket directly at ticks == 1.
				ProcessWatcher:loadConfig()
				ProcessWatcher._config.interval = 600
				ProcessWatcher._config.sustainSeconds = 600
				sample(95)
				assert.is.table(ProcessWatcher._flagged["Hog"]) -- flagged on the very first sample
				sample(0)
				assert.is_nil(ProcessWatcher._flagged["Hog"]) -- and cleared on the very next one
			end
		)

		it("real dip-tolerance requires interval meaningfully smaller than sustainSeconds", function()
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 60, sustainSeconds = 600, cpuThreshold = 90 })
			assert.are.equal(10, ProcessWatcher:_sustainTicks())
			for _ = 1, 10 do
				sample(95)
			end
			assert.is.table(ProcessWatcher._flagged["Hog"])
			sample(0) -- one dip: counter goes from 10 to 9, still flagged
			assert.is.table(ProcessWatcher._flagged["Hog"])
		end)
	end)

	describe("per-process overrides", function()
		before_each(function()
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 1, sustainSeconds = 3, cpuThreshold = 90 })
		end)

		it("raises the effective threshold for names matching a pattern", function()
			ProcessWatcher:configure({ overrides = { { pattern = "Teams", cpuThreshold = 200 } } })
			for _ = 1, 5 do
				ProcessWatcher:_evaluate({
					["Teams Helper (GPU)"] = { name = "Teams Helper (GPU)", cpu = 150, mem = 0, pids = { "1" } },
				})
			end
			assert.is_nil(ProcessWatcher._flagged["Teams Helper (GPU)"])
		end)

		it("still flags a matched process once it exceeds the overridden threshold", function()
			ProcessWatcher:configure({ overrides = { { pattern = "Teams", cpuThreshold = 200 } } })
			for _ = 1, 5 do
				ProcessWatcher:_evaluate({ Teams = { name = "Teams", cpu = 250, mem = 0, pids = { "1" } } })
			end
			assert.is.table(ProcessWatcher._flagged["Teams"])
		end)

		it("overrides sustainSeconds independently of the global default", function()
			-- Global sustain is 3 ticks; override drops it to 1 so a single high
			-- sample flags immediately.
			ProcessWatcher:configure({ overrides = { { pattern = "Teams", sustainSeconds = 1 } } })
			ProcessWatcher:_evaluate({ Teams = { name = "Teams", cpu = 99, mem = 0, pids = { "1" } } })
			assert.is.table(ProcessWatcher._flagged["Teams"])
		end)

		it("leaves fields unset on the override falling back to global config", function()
			-- Only cpuThreshold is overridden; memThreshold should still use the global 25%.
			ProcessWatcher:configure({ overrides = { { pattern = "Teams", cpuThreshold = 200 } }, memThreshold = 25 })
			for _ = 1, 5 do
				ProcessWatcher:_evaluate({ Teams = { name = "Teams", cpu = 0, mem = 30, pids = { "1" } } })
			end
			assert.is_true(ProcessWatcher._flagged["Teams"].mem)
		end)

		it("uses the first matching override when multiple patterns match", function()
			ProcessWatcher:configure({
				overrides = {
					{ pattern = "Teams", cpuThreshold = 200 },
					{ pattern = "Helper", cpuThreshold = 10 },
				},
			})
			for _ = 1, 5 do
				ProcessWatcher:_evaluate({
					["Teams Helper"] = { name = "Teams Helper", cpu = 150, mem = 0, pids = { "1" } },
				})
			end
			assert.is_nil(ProcessWatcher._flagged["Teams Helper"]) -- matched by the 200% rule, not the 10% one
		end)

		it("supports anchored exact-match patterns", function()
			ProcessWatcher:configure({ overrides = { { pattern = "^Teams$", cpuThreshold = 200 } } })
			for _ = 1, 5 do
				ProcessWatcher:_evaluate({
					["Teams Helper"] = { name = "Teams Helper", cpu = 95, mem = 0, pids = { "1" } },
				})
			end
			-- "Teams Helper" isn't an exact match for "^Teams$", so the global 90% threshold applies.
			assert.is.table(ProcessWatcher._flagged["Teams Helper"])
		end)

		it("logs a warning and falls back to global thresholds for an invalid pattern", function()
			ProcessWatcher:configure({ overrides = { { pattern = "[", cpuThreshold = 200 } } })
			for _ = 1, 5 do
				ProcessWatcher:_evaluate({ Teams = { name = "Teams", cpu = 95, mem = 0, pids = { "1" } } })
			end
			assert.is.table(ProcessWatcher._flagged["Teams"]) -- fell back to the global 90% threshold
			assert.truthy(#ProcessWatcher.log._warnings > 0)
		end)

		it("reflects the overridden sustainSeconds in the notification text", function()
			-- Global sustainSeconds is 3 (from the outer before_each); override to a
			-- distinct value (2) so the assertion proves the override was used, not
			-- just that the global default happens to match.
			ProcessWatcher:configure({ overrides = { { pattern = "Teams", sustainSeconds = 2 } } })
			for _ = 1, 2 do
				ProcessWatcher:_evaluate({ Teams = { name = "Teams", cpu = 99, mem = 0, pids = { "1" } } })
			end
			assert.are.equal(1, #mock_hs.notify._sent)
			assert.truthy(mock_hs.notify._sent[1].attrs.informativeText:find("2s%+"))
		end)
	end)

	describe("allowlist and snooze exclusion", function()
		before_each(function()
			ProcessWatcher:loadConfig()
			ProcessWatcher:configure({ interval = 1, sustainSeconds = 2, cpuThreshold = 90 })
		end)

		it("never flags a process on the allowlist", function()
			ProcessWatcher:configure({ allowlist = { "Xcode" } })
			for _ = 1, 5 do
				ProcessWatcher:_evaluate({ Xcode = { name = "Xcode", cpu = 99, mem = 0, pids = { "1" } } })
			end
			assert.is_nil(ProcessWatcher._flagged["Xcode"])
			assert.are.equal(0, #mock_hs.notify._sent)
		end)

		it("suppresses re-alerting while a name is snoozed via ignore()", function()
			local function sample()
				ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			end
			sample()
			sample() -- flags, 1 notification
			assert.are.equal(1, #mock_hs.notify._sent)

			ProcessWatcher:ignore("Bad")
			assert.is_nil(ProcessWatcher._flagged["Bad"])

			sample()
			sample() -- would flag again if not snoozed
			assert.is_nil(ProcessWatcher._flagged["Bad"])
			assert.are.equal(1, #mock_hs.notify._sent)
		end)

		it("resumes flagging once the snooze window expires", function()
			local function sample()
				ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			end
			ProcessWatcher:ignore("Bad")
			ProcessWatcher._snooze["Bad"] = os.time() - 1 -- force expiry
			sample()
			sample()
			assert.is.table(ProcessWatcher._flagged["Bad"])
		end)
	end)

	describe("notifications", function()
		before_each(function()
			ProcessWatcher:loadConfig()
			-- sustainSeconds must exceed interval (validated), but floor(3/2) still floors to a
			-- single tick, so one _evaluate() call is enough to flag -- these tests are about
			-- notification/kill/ignore behavior, not sustain-tick math.
			ProcessWatcher:configure({ interval = 2, sustainSeconds = 3, cpuThreshold = 90 })
		end)

		it("sends an actionable notification with Terminate/Ignore", function()
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			assert.are.equal(1, #mock_hs.notify._sent)
			local attrs = mock_hs.notify._sent[1].attrs
			assert.is_true(attrs.hasActionButton)
			assert.are.equal("Terminate", attrs.actionButtonTitle)
			assert.are.equal("Ignore", attrs.otherButtonTitle)
			assert.truthy(attrs.informativeText:find("Bad"))
		end)

		it("does not crash when sustainSeconds is fractional (valid JSON number, not just integers)", function()
			ProcessWatcher:configure({ interval = 2, sustainSeconds = 2.5, cpuThreshold = 90 })
			assert.has_no.errors(
				function() ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } }) end
			)
			assert.are.equal(1, #mock_hs.notify._sent)
		end)

		it("Terminate action kills the process", function()
			ProcessWatcher._lastSample["Bad"] = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } }
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			local killed = {}
			mock_hs._setExecHandler(function(cmd)
				table.insert(killed, cmd)
				return "", true, "exit", 0
			end)
			fireNotification(mock_hs.notify._sent[1], mock_hs.notify.activationTypes.actionButtonClicked)
			assert.truthy(killed[1]:find("kill %-TERM 1"))
		end)

		it("Ignore action snoozes the process", function()
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			fireNotification(mock_hs.notify._sent[1], mock_hs.notify.activationTypes.additionalActionClicked)
			assert.is_not_nil(ProcessWatcher._snooze["Bad"])
			assert.is_nil(ProcessWatcher._flagged["Bad"])
		end)

		it(
			"withdraws the notification when the process is killed via the menu/CLI, not the notification itself",
			function()
				ProcessWatcher._lastSample["Bad"] = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } }
				ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
				assert.are.equal(1, #mock_hs.notify._sent)
				ProcessWatcher:kill("Bad") -- simulates acting via the menu bar/CLI, not the notification's own button
				assert.are.equal(1, #mock_hs.notify._withdrawn)
			end
		)

		it("withdraws the notification when the process is ignored via the menu/CLI", function()
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			assert.are.equal(1, #mock_hs.notify._sent)
			ProcessWatcher:ignore("Bad")
			assert.are.equal(1, #mock_hs.notify._withdrawn)
		end)

		it("withdraws the notification when the process is added to the allowlist mid-flight", function()
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			assert.are.equal(1, #mock_hs.notify._sent)
			ProcessWatcher:configure({ allowlist = { "Bad" } })
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 0, pids = { "1" } } })
			assert.are.equal(1, #mock_hs.notify._withdrawn)
			assert.is_nil(ProcessWatcher._flagged["Bad"])
		end)

		it("tracks CPU and memory notifications independently", function()
			ProcessWatcher:configure({ memThreshold = 20 })
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 99, mem = 50, pids = { "1" } } })
			assert.are.equal(2, #mock_hs.notify._sent) -- one for cpu, one for mem
			ProcessWatcher:_evaluate({ Bad = { name = "Bad", cpu = 0, mem = 50, pids = { "1" } } }) -- cpu recovers
			assert.are.equal(1, #mock_hs.notify._withdrawn) -- only the cpu notification
			assert.is.table(ProcessWatcher._flagged["Bad"]) -- still flagged on mem
		end)
	end)

	describe("kill", function()
		before_each(function() ProcessWatcher:loadConfig() end)

		it("sends SIGTERM to every pid aggregated under a name", function()
			ProcessWatcher._lastSample["Foo"] = { name = "Foo", cpu = 10, mem = 10, pids = { "111", "222" } }
			local cmds = {}
			mock_hs._setExecHandler(function(cmd)
				table.insert(cmds, cmd)
				return "", true, "exit", 0
			end)
			local ok = ProcessWatcher:kill("Foo")
			assert.is_true(ok)
			assert.truthy(cmds[1]:find("kill %-TERM 111"))
			assert.truthy(cmds[2]:find("kill %-TERM 222"))
		end)

		it("kills directly by numeric PID", function()
			local cmds = {}
			mock_hs._setExecHandler(function(cmd)
				table.insert(cmds, cmd)
				return "", true, "exit", 0
			end)
			local ok = ProcessWatcher:kill("999")
			assert.is_true(ok)
			assert.truthy(cmds[1]:find("kill %-TERM 999"))
		end)

		it("returns false for an unknown name", function()
			mock_hs._setExecHandler(function(_cmd) return "", true, "exit", 0 end)
			assert.is_false(ProcessWatcher:kill("NoSuchProcess"))
		end)

		it("escalates to SIGKILL if the process survives the grace period", function()
			ProcessWatcher._lastSample["Foo"] = { name = "Foo", cpu = 10, mem = 10, pids = { "111" } }
			local cmds = {}
			mock_hs._setExecHandler(function(cmd)
				table.insert(cmds, cmd)
				if cmd:find("kill %-0") then return "", true, "exit", 0 end -- still alive
				return "", true, "exit", 0
			end)
			ProcessWatcher:kill("Foo")
			mock_hs._fireTimers()
			local sawKill9 = false
			for _, c in ipairs(cmds) do
				if c:find("KILL") then sawKill9 = true end
			end
			assert.is_true(sawKill9)
		end)

		it("does not escalate if the process is already gone", function()
			ProcessWatcher._lastSample["Foo"] = { name = "Foo", cpu = 10, mem = 10, pids = { "111" } }
			local cmds = {}
			mock_hs._setExecHandler(function(cmd)
				table.insert(cmds, cmd)
				if cmd:find("kill %-0") then return "", true, "exit", 1 end -- gone
				return "", true, "exit", 0
			end)
			ProcessWatcher:kill("Foo")
			mock_hs._fireTimers()
			for _, c in ipairs(cmds) do
				assert.falsy(c:find("KILL " .. "111"))
			end
		end)
	end)

	describe("menu bar", function()
		before_each(function()
			ProcessWatcher:loadConfig()
			ProcessWatcher._menu = mock_hs.menubar.new()
		end)

		it("shows the plain icon with no flagged processes", function()
			ProcessWatcher:_updateMenu()
			assert.are.equal("🌡️", ProcessWatcher._menu._title)
		end)

		it("shows the alert icon and a Flagged section when something is flagged", function()
			ProcessWatcher._flagged["Bad"] = { since = os.time(), cpu = true, cpu_value = 99, pids = { "1" } }
			ProcessWatcher:_updateMenu()
			assert.are.equal("🌡️!", ProcessWatcher._menu._title)
			local found = false
			for _, item in ipairs(ProcessWatcher._menu._menuItems) do
				if item.title and item.title:find("Bad") then found = true end
			end
			assert.is_true(found)
		end)

		it("Edit Config item calls hs.open with configPath", function()
			ProcessWatcher:_updateMenu()
			local editItem
			for _, item in ipairs(ProcessWatcher._menu._menuItems) do
				if item.title and item.title:find("Edit Config") then editItem = item end
			end
			assert.is.table(editItem)
			editItem.fn()
			assert.are.equal(ProcessWatcher.configPath, mock_hs._opened[1])
		end)
	end)

	describe("status and configSummary", function()
		before_each(function() ProcessWatcher:loadConfig() end)

		it(
			"reports no flagged processes initially",
			function() assert.are.equal("No flagged processes.", ProcessWatcher:status()) end
		)

		it("includes flagged process details after a flag", function()
			ProcessWatcher._flagged["Bad"] = { since = os.time(), cpu = true, cpu_value = 99, pids = { "1" } }
			assert.truthy(ProcessWatcher:status():find("Bad"))
			assert.truthy(ProcessWatcher:status():find("99"))
		end)

		it("includes the PID(s) of a flagged process", function()
			ProcessWatcher._flagged["Bad"] = { since = os.time(), cpu = true, cpu_value = 99, pids = { "111", "222" } }
			assert.truthy(ProcessWatcher:status():find("pid=111,222"))
		end)

		it("shows top CPU/memory processes once a sample has been taken", function()
			mock_hs._setExecHandler(
				function(_cmd) return "111  80.0  10.0 Chrome\n222  20.0  5.0 Finder\n", true, "exit", 0 end
			)
			ProcessWatcher:_sample()
			local s = ProcessWatcher:status()
			assert.truthy(s:find("Top CPU:"))
			assert.truthy(s:find("Chrome %(pid=111%)"))
			assert.truthy(s:find("Top Memory:"))
		end)

		it(
			"omits top-process sections before any sample has been taken",
			function() assert.is_nil(ProcessWatcher:status():find("Top CPU:")) end
		)

		it("lists every PID for a name aggregated across multiple processes", function()
			mock_hs._setExecHandler(
				function(_cmd) return "111  50.0  2.0 Chrome\n222  30.0  1.0 Chrome\n", true, "exit", 0 end
			)
			ProcessWatcher:_sample()
			assert.truthy(ProcessWatcher:status():find("Chrome %(pid=111,222%)"))
		end)

		it("shows a Tracking entry for a process accumulating toward a flag", function()
			ProcessWatcher:configure({ interval = 1, sustainSeconds = 5, cpuThreshold = 50 })
			mock_hs._setExecHandler(function(_cmd) return "111  80.0  10.0 Chrome\n", true, "exit", 0 end)
			ProcessWatcher:_sample() -- one over-threshold sample: counter 1/5, not yet flagged
			local s = ProcessWatcher:status()
			assert.truthy(s:find("Tracking %(not yet flagged%):"))
			assert.truthy(s:find("Chrome: CPU 1/5 ticks %(80%%%)"))
			assert.is_nil(ProcessWatcher._flagged["Chrome"])
		end)

		it("excludes already-flagged names from the Tracking section", function()
			-- interval=2, sustainSeconds=3 floors to 1 tick, so a single sample flags immediately.
			ProcessWatcher:configure({ interval = 2, sustainSeconds = 3, cpuThreshold = 50 })
			mock_hs._setExecHandler(function(_cmd) return "111  80.0  10.0 Chrome\n", true, "exit", 0 end)
			ProcessWatcher:_sample()
			assert.is.table(ProcessWatcher._flagged["Chrome"])
			assert.is_nil(ProcessWatcher:status():find("Tracking"))
		end)

		it("excludes names that are below threshold (zero ticks)", function()
			ProcessWatcher:configure({ interval = 1, sustainSeconds = 5, cpuThreshold = 90 })
			mock_hs._setExecHandler(function(_cmd) return "111  10.0  1.0 Finder\n", true, "exit", 0 end)
			ProcessWatcher:_sample()
			assert.is_nil(ProcessWatcher:status():find("Tracking"))
		end)

		it("combines CPU and Mem tracking progress on one line for the same name", function()
			ProcessWatcher:configure({ interval = 1, sustainSeconds = 5, cpuThreshold = 50, memThreshold = 50 })
			mock_hs._setExecHandler(function(_cmd) return "111  80.0  80.0 Chrome\n", true, "exit", 0 end)
			ProcessWatcher:_sample()
			local s = ProcessWatcher:status()
			assert.truthy(s:find("Chrome: CPU 1/5 ticks %(80%%%), Mem 1/5 ticks %(80%%%)"))
		end)

		it("sorts Tracking entries by proximity to flagging, closest first", function()
			ProcessWatcher:configure({ interval = 1, sustainSeconds = 5, cpuThreshold = 50 })
			ProcessWatcher._lastSample = {
				CloseOne = { cpu = 80, mem = 0, pids = { "1" } },
				FarOne = { cpu = 60, mem = 0, pids = { "2" } },
			}
			ProcessWatcher._counters.cpu["CloseOne"] = 4
			ProcessWatcher._counters.cpu["FarOne"] = 1
			local s = ProcessWatcher:status()
			local closeIdx = s:find("CloseOne")
			local farIdx = s:find("FarOne")
			assert.is_not_nil(closeIdx)
			assert.is_not_nil(farIdx)
			assert.is_true(closeIdx < farIdx)
		end)

		it("configSummary includes thresholds", function()
			local s = ProcessWatcher:configSummary()
			assert.truthy(s:find("cpuThreshold=90"))
			assert.truthy(s:find("memThreshold=25"))
		end)

		it("configSummary does not crash with fractional config values", function()
			ProcessWatcher:configure({ interval = 2, sustainSeconds = 2.5, cpuThreshold = 87.5, snoozeHours = 1.5 })
			assert.has_no.errors(function() ProcessWatcher:configSummary() end)
		end)

		it("configSummary includes per-process overrides", function()
			ProcessWatcher:configure({ overrides = { { pattern = "Teams", cpuThreshold = 200 } } })
			local s = ProcessWatcher:configSummary()
			assert.truthy(s:find("Teams"))
			assert.truthy(s:find("cpu=200%%"))
		end)
	end)

	describe("start/stop lifecycle", function()
		it("creates a menu bar item and a recurring timer on start", function()
			mock_hs._setExecHandler(function(_cmd) return "", true, "exit", 0 end)
			ProcessWatcher:start()
			assert.is.table(ProcessWatcher._menu)
			assert.is.table(ProcessWatcher._timer)
			assert.is_true(ProcessWatcher._running)
		end)

		it("tears down menu and timer on stop", function()
			mock_hs._setExecHandler(function(_cmd) return "", true, "exit", 0 end)
			ProcessWatcher:start()
			ProcessWatcher:stop()
			assert.is_nil(ProcessWatcher._menu)
			assert.is_nil(ProcessWatcher._timer)
			assert.is_false(ProcessWatcher._running)
		end)

		it("warns on start if hs.ipc is not loaded (CLI would silently fail)", function()
			mock_hs._setExecHandler(function(_cmd) return "", true, "exit", 0 end)
			mock_hs.ipc = nil
			ProcessWatcher:start()
			assert.truthy(#ProcessWatcher.log._warnings > 0)
		end)

		it("does not warn on start if hs.ipc is loaded", function()
			mock_hs._setExecHandler(function(_cmd) return "111  10.0  1.0 Finder\n", true, "exit", 0 end)
			mock_hs.ipc = {}
			ProcessWatcher:start()
			assert.are.equal(0, #ProcessWatcher.log._warnings)
		end)
	end)
end)
