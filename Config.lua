--!strict

local Types = require(script.Parent.Types)
local Guards = require(script.Parent.Types.Guards)

-- // Module // --
local Config: Types.ConfigTable = {

	-- Retry Settings (merged nested)
	_RetryOptions = {
		general = {
			initialWaitTime = 1,  -- Default foreground retry delay in seconds
			maxAttempts = 5,      -- Default max foreground attempts
			printWarning = true,  -- Default to warn on foreground retries
			jitter = false,       -- Default no jitter
			backoffStrategy = "exponential"  -- Default exponential backoff
		} :: Types.RetryOptions,
		background = {
			initialWaitTime = 2,  
			maxAttempts = 10,     
			printWarning = true,
			jitter = true,        -- Default jitter for background to prevent thundering herd
			backoffStrategy = "exponential"
		} :: Types.RetryOptions,
		init = {
			initialWaitTime = 1,
			maxAttempts = 5,
			printWarning = true,
			jitter = false,
			backoffStrategy = "exponential"
		} :: Types.RetryOptions,
		start = {
			initialWaitTime = 1,
			maxAttempts = 3,      -- Slightly lower for Start, as it may be less tolerant of delays
			printWarning = true,
			jitter = false,
			backoffStrategy = "fixed"  -- Fixed for quicker recovery in startup
		} :: Types.RetryOptions,
		stop = {
			initialWaitTime = 1,
			maxAttempts = 3,
			printWarning = true,
			jitter = false,
			backoffStrategy = "fixed"
		} :: Types.RetryOptions,
	} :: Types.RetryOptionsTable,

	_CriticalBackgroundRetries = true :: boolean,  -- Default to retry critical modules in background for resilience

	-- Queuing Settings
	_UseRetryQueue = true :: boolean,  -- Default on; enable for centralized retry management
	_MaxConcurrentRetries = 3 :: number,  -- Max simultaneous retries to prevent overload
	_QueueBackoff = 5 :: number,  -- Global delay (seconds) between queue batches
	_MaxRecoveryAttempts = 3 :: number,  -- Max requeues per entry before drop

	-- Validation and Path Settings
	_StrictLocationCheck = true :: boolean,  -- Default to warn (not error) on location mismatches; true to error
	_FolderPaths = {
		server = "Systems",   -- Single string; subfolders handled internally
		client = "Core",      -- Single string
		shared = { "Managers" }  -- Array of strings for shared subfolders
	} :: Types.FolderPaths,

	-- Global Error Handling
	_GlobalErrorHandler = function(moduleName: string, err: string)
		warn("Global Error: " .. moduleName .. " - " .. err)
	end :: (string, string) -> (),

	-- Miscellaneous
	_AllowDuplicates = false :: boolean,  -- Default to skip duplicates with warn; true for dev overrides

	-- Strict Validation
	_StrictValidation = true:: boolean,  -- Default to warn on missing/invalid deps; true to error

}

-- Immediate validation for defaults
if not Guards.isFolderPaths(Config._FolderPaths) then
	error("Invalid default _FolderPaths")
end
local retryOptsTable: Types.RetryOptionsTable? = Guards.isRetryOptionsTable(Config._RetryOptions)
if not retryOptsTable then
	error("Invalid default _RetryOptions table structure")
end
for key: string, opts: Types.RetryOptions in pairs(retryOptsTable) do
	if not Guards.isRetryOptions(opts) then
		error(string.format("Invalid default _RetryOptions.%s", key))
	end
end

return Config