--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Folders
local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
if not Shared then warn("⚠️ Shared folder not found in ReplicatedStorage after timeout") return {} end

-- Shared modules
local PromiseModule = require(Shared.Promise)
local LogModule = require(Shared.Log)

-- Utility modules
local HydraUtils = require(script.Parent.Utils)
local Types = require(script.Parent.Types)
local Guards = require(script.Parent.Types.Guards)

-- Log Instance creation
local Logger = LogModule.new("Retry")

-- // Module // --
local Retry = {}

local defaultRetryOptions: Types.RetryOptions = {
	initialWaitTime = 1,
	maxAttempts = 5,
	printWarning = true,
	jitter = false,
	backoffStrategy = "exponential"
}

function Retry.getEffectiveRetryOptions(options: Types.RetryOperationOptions, isForeground: boolean): Types.RetryOptions
	local globalConfig: Types.ConfigTable = if options.hydra then options.hydra.Config else require(script.Parent.Config)
	local modConfig: Types.ModuleConfig? = options.moduleConfig
	local context: string = options.context:lower()

	-- Narrow _RetryOptions to RetryOptionsTable with guard
	local retryOptsTable: Types.RetryOptionsTable = Guards.getRetryOptionsTable(globalConfig, "_RetryOptions", {general = defaultRetryOptions})

	-- Select base based on isForeground
	local baseKey: string = if isForeground then "general" else "background"
	local baseAny: any = retryOptsTable[baseKey] or retryOptsTable.general
	local base: Types.RetryOptions = if Guards.isRetryOptions(baseAny) then HydraUtils.deepClone(baseAny) else defaultRetryOptions

	-- Merge context-specific (e.g., "init" overrides general/background)
	local specificKey: string = context
	local specificAny: any = retryOptsTable[specificKey]
	if Guards.isRetryOptions(specificAny) then
		for k: string, v: any in pairs(specificAny :: Types.RetryOptions) do
			base[k] = v
		end
	end

	-- Apply module overrides (context-specific first, then general)
	if modConfig then
		local contextPrefix: string = context
		base.initialWaitTime = modConfig[contextPrefix .. "InitialWaitTime"] or modConfig.initialWaitTime or base.initialWaitTime  -- e.g., "loadInitialWaitTime" if context = "load"
		base.maxAttempts = modConfig[contextPrefix .. "MaxAttempts"] or modConfig.maxAttempts or base.maxAttempts  -- e.g., "initMaxAttempts" if context = "init"
		base.printWarning = modConfig[contextPrefix .. "PrintWarning"] or modConfig.printWarning or base.printWarning  -- e.g., "startPrintWarning" if context = "start"
		base.jitter = modConfig[contextPrefix .. "Jitter"] or modConfig.jitter or base.jitter  -- e.g., "stopJitter" if context = "stop"
		base.backoffStrategy = modConfig[contextPrefix .. "BackoffStrategy"] or modConfig.backoffStrategy or base.backoffStrategy  -- e.g., "runtimeBackoffStrategy" if context = "runtime"
	end

	return base
end

function Retry.calculateWaitTime(retryConfig: Types.RetryOptions, attempt: number): number
	local baseWait = retryConfig.initialWaitTime or 1
	local waitTime: number = if retryConfig.backoffStrategy == "fixed" then baseWait else baseWait * math.pow(2, attempt - 1)
	if retryConfig.jitter then
		waitTime = waitTime * (0.9 + math.random() * 0.2)  -- ±10% jitter
	end
	return math.max(waitTime, 0.1)
end

function Retry.RetryOperation(options: Types.RetryOperationOptions): PromiseModule.Promise<any>
	return PromiseModule.new(function(resolve: (any) -> (), reject: (any) -> ())
		local retryConfig: Types.RetryOptions = Retry.getEffectiveRetryOptions(options, true)
		local maxAttempts: number = retryConfig.maxAttempts or 5
		local attempts: number = 0
		local isForeground: boolean = true
		local moduleConfig: Types.ModuleConfig? = options.moduleConfig
		local isCritical: boolean = moduleConfig and moduleConfig.critical or false
		local criticalBackground: boolean = Guards.getBooleanOption(options.hydra and options.hydra.Config or {}, "_CriticalBackgroundRetries", true)

		local function handleFinalFailure(errMsg: string)
			local entry: Types.Entry? = if options.hydra then options.hydra.registry[options.moduleName] else nil
			if entry then
				entry.state = "error"
				entry.errorInfo = errMsg
				if entry.instance and HydraUtils.getLifecycleMethod(entry.instance, "OnError") then
					HydraUtils.SafeCall(entry.instance.OnError, entry.instance, errMsg)
				end
			end
			if options.hydra then
				options.hydra:OnError(options.context .. " failed for " .. options.moduleName .. ": " .. errMsg)
			end
			if isCritical then
				reject(errMsg)
			else
				resolve(nil)
			end
		end

		local function scheduleNextAttempt(attempt: () -> ())
			local waitTime: number = Retry.calculateWaitTime(retryConfig, attempts)
			local useQueue: boolean = Guards.getBooleanOption(options.hydra and options.hydra.Config or {}, "_UseRetryQueue", false)
			if not isForeground and useQueue and options.hydra then
				local queueEntry: Types.QueueEntry = {
					priority = if isCritical then 1 else 5,
					moduleName = options.moduleName,
					context = options.context,
					operation = options.operation,
					dependents = {},  -- Populate if needed from registry
					retryCount = attempts,
					config = retryConfig
				}
				table.insert(options.hydra.recoveryQueue, queueEntry)
				resolve("queued")  -- Resolve current as pending
				return  -- Skip direct schedule
			end
			-- Direct schedule
			if isForeground then
				task.wait(waitTime)
				attempt()
			else
				task.delay(waitTime, attempt)
			end
		end

		local function attempt()
			attempts += 1
			if attempts > 1 then
				Logger:Info(string.format("Retry attempt %d/%d for %s in %s", attempts, maxAttempts, options.context, options.moduleName))
			end

			local success: boolean, result: any = HydraUtils.SafeCall(options.operation)
			if success then
				if PromiseModule.isPromise(result) then
					result:Then(resolve):Catch(function(err: any)
						local errMsg: string = tostring(err)
						if options.onRetry then options.onRetry(attempts, errMsg) end
						if retryConfig.printWarning then
							Logger:Warn(string.format("Attempt %d/%d failed (async) for %s in %s: %s", attempts, maxAttempts, options.context, options.moduleName, errMsg))
						end
						if attempts >= maxAttempts then
							handleFinalFailure(errMsg)
							return
						end
						if attempts == 1 and (not isCritical or criticalBackground) then
							isForeground = false
							retryConfig = Retry.getEffectiveRetryOptions(options, false)
						end
						scheduleNextAttempt(attempt)
					end)
				else
					resolve(result)
				end
				return
			end

			local errMsg: string = tostring(result)
			if options.onRetry then options.onRetry(attempts, errMsg) end
			if retryConfig.printWarning then
				local failMsg: string = if attempts == 1 then string.format("Initial %s failed for %s: %s; starting retries", options.context, options.moduleName, errMsg)
					else string.format("Attempt %d/%d failed for %s in %s: %s", attempts, maxAttempts, options.context, options.moduleName, errMsg)
				Logger:Warn(failMsg)
			end

			if attempts >= maxAttempts then
				handleFinalFailure(errMsg)
				return
			end

			if attempts == 1 and (not isCritical or criticalBackground) then
				isForeground = false
				retryConfig = Retry.getEffectiveRetryOptions(options, false)
			end
			scheduleNextAttempt(attempt)
		end

		attempt()
	end)
end

function Retry.RuntimeRetry(options: Types.RetryOperationOptions): PromiseModule.Promise<any>
	-- Reuse RetryOperation for consistency (context="Runtime" ; for failing functions)
	return Retry.RetryOperation(options)
end

return Retry