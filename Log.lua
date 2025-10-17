--!strict

export type LogLevel = "Debug" | "Info" | "Timing" | "Success" | "Warn" | "None"

local LogLevel: LogLevel = "Debug"

local LogEnabled: ({[string]: boolean} & {All: boolean}) = {
	All = true,  -- Enable all logs by default; toggle to false and specify per-module below
	-- Example: ["ProfileLoader"] = true,  -- Module-specific logging (has to match Log name)
}

local LogLevelsEnabled: {[LogLevel]: boolean} = {
	Debug = true,
	Info = true,
	Timing = true,
	Success = true,
	Warn = true,
	None = false
}

local Log = {}
Log.__index = Log
Log.levels = {
	Debug = 10,
	Info = 20,
	Timing = 24,
	Success = 25,
	Warn = 30,
	None = math.huge
} :: {[string]: number?}

export type Logger = typeof(setmetatable({} :: {
	_moduleName: string,
	_timers: {[string]: number?}
}, Log))

function Log.new(moduleName: string): Logger
	assert(type(moduleName) == "string" and moduleName ~= "", "Bad moduleName")
	return setmetatable({
		_moduleName = moduleName,
		_timers = {}
	}, Log)
end

function Log:_shouldLog(level: LogLevel): boolean
	local moduleEnabled = LogEnabled.All or LogEnabled[self._moduleName] or false
	if not moduleEnabled then return false end
	local levelEnabled = LogLevelsEnabled[level] ~= false  -- Default true if not set
	if not levelEnabled then return false end
	if level == "Warn" then
		return LogLevel ~= "None"
	end
	local ll = Log.levels[LogLevel]
	local lvl = Log.levels[level]
	if lvl and ll and lvl < ll then return false end
	return true
end

function Log:Debug(message: string)
	if not self:_shouldLog("Debug") then return end
	print(string.format("[Debug] [%s]: %s", self._moduleName, message))
end

function Log:Info(message: string)
	if not self:_shouldLog("Info") then return end
	print(string.format("[Info] [%s]: %s", self._moduleName, message))
end

function Log:Timing(message: string)
	if not self:_shouldLog("Timing") then return end
	print(string.format("[Timing] [%s]: %s", self._moduleName, message))
end

function Log:Success(message: string)
	if not self:_shouldLog("Success") then return end
	print(string.format("[Success] [%s]: %s", self._moduleName, message))
end

function Log:Warn(message: string)
	if not self:_shouldLog("Warn") then return end
	warn(string.format("[Warn] [%s]: %s", self._moduleName, message))
end

function Log:TimeStart(key: string)
	self._timers[key] = os.clock()
end

function Log:TimeEnd(key: string, message: string?)
	local start = self._timers[key]
	if not start then return end
	local duration = os.clock() - start
	self._timers[key] = nil
	local logMsg = string.format("%s %.6fs", message or key, duration)
	self:Timing(logMsg)
end

return Log