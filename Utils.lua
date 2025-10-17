--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Folders
local Shared = ReplicatedStorage:WaitForChild("Shared")

-- Shared modules
local PromiseModule = require(Shared.Promise)
local LogModule = require(Shared.Log)  

-- Utility modules
local PromiseUtils = require(Shared.Utility.PromiseUtils)

-- Support modules
local HydraTypes = require(script.Parent.Types)
local HydraTypeGuards = require(script.Parent.Types.Guards)
local Memoization = require(ReplicatedStorage.Shared.Memoization)

-- Log Instance creation
local Logger = LogModule.new("Utils")  

-- // Module // --
local Utils = {}

function Utils.TopologicalSort(modules: {string}, config: HydraTypes.ConfigTable): {string}?
	local order: {string} = {}
	local indegree: {[string]: number} = {}
	local graph: {[string]: {string}} = {}

	for _, mod: string in ipairs(modules) do
		if not config[mod] then
			Logger:Warn("⚠️ Missing config for " .. mod .. "; skipping in sort")
			continue
		end
		indegree[mod] = 0
		graph[mod] = {}
	end
	for _, mod: string in ipairs(modules) do
		local moduleConfig: HydraTypes.ModuleConfig? = HydraTypeGuards.isModuleConfig(config[mod])
		local deps: {string} = if moduleConfig then moduleConfig.Dependencies else {}
		for _, dep: string in ipairs(deps) do
			if not graph[dep] then
				if config[dep] then
					-- External dep (e.g., from another group); skip warning as it's handled elsewhere
					continue
				end
				local msg = "❌ Missing dep " .. dep .. " for " .. mod
				if config._StrictValidation then
					error(msg)
				else
					Logger:Warn(msg)
					continue
				end
			end
			table.insert(graph[dep], mod)
			indegree[mod] = (indegree[mod] or 0) + 1
		end
	end

	local queue: {string} = {}
	for mod: string, deg: number in pairs(indegree) do
		if deg == 0 then table.insert(queue, mod) end
	end

	local visited: number = 0
	while #queue > 0 do
		local modOpt: string? = table.remove(queue, 1)
		local mod: string = modOpt :: string
		table.insert(order, mod)
		visited += 1
		for _, neighbor: string in ipairs(graph[mod] or {}) do
			indegree[neighbor] -= 1
			if indegree[neighbor] == 0 then
				table.insert(queue, neighbor)
			end
		end
	end

	local processedCount: number = 0
	for _ in pairs(indegree) do
		processedCount += 1
	end
	if visited ~= processedCount then
		local msg = "❌ Cycle detected in dependencies"
		if config._StrictValidation then
			error(msg)
		else
			Logger:Warn(msg)
			return nil
		end
	end

	return order
end

function Utils.getLifecycleMethod(instance: any, method: string): any?
	if typeof(instance) == "table" then
		local func = instance[method]
		if typeof(func) == "function" then return func end
		local mt: any = getmetatable(instance)
		if mt and typeof(mt) == "table" then
			return mt[method]
		end
	end
	return nil
end

function Utils.allSettled(promises: {any}): PromiseModule.Promise<{HydraTypes.SettledResult}>
	if #promises == 0 then
		return PromiseModule.resolved({})
	end
	for _, p: any in ipairs(promises) do
		assert(typeof(p) == "table" and p.Then and type(p.Then) == "function" and p.Catch and type(p.Catch) == "function", "Invalid promise in allSettled")
	end
	return PromiseModule.new(function(resolve: ({HydraTypes.SettledResult}) -> (), _: (any) -> ())
		local results: {HydraTypes.SettledResult} = table.create(#promises)
		local remaining: number = #promises
		local function checkComplete()
			remaining -= 1
			if remaining == 0 then
				resolve(results)
			end
		end
		for i: number, p: any in ipairs(promises) do
			p:Then(function(value: any?)
				results[i] = {status = "fulfilled", value = value}
				checkComplete()
			end):Catch(function(reason: any?)
				results[i] = {status = "rejected", reason = reason}
				checkComplete()
			end)
		end
	end)
end

function Utils.chain<T...>(promises: {PromiseModule.Promise<T...>}): PromiseModule.Promise<T...>
	if #promises == 0 then
		return PromiseModule.resolved()
	end
	local chained: PromiseModule.Promise<T...> = promises[1]
	for i: number = 2, #promises do
		chained = chained:Then(function(...: T...): PromiseModule.Promise<T...>
			return promises[i]
		end)
	end
	return chained
end

function Utils.SafeCall<T...>(func: (T...) -> any, ...: T...): (boolean, any)
	Logger:Warn("Before pcall in SafeCall")  -- Debug: Confirm entry (Remove this after Retry problems are solved)
	local success, result = pcall(func, ...)
	Logger:Warn("After pcall: success=" .. tostring(success) .. ", result=" .. tostring(result))  -- Debug: What pcall returned (Remove this after Retry problems are solved)
	if not success then
		return false, tostring(result)
	end
	return true, result
end

function Utils.deepClone<T>(t: T): T
	-- Wrap with pcall for cycle errors; log via Logger (integrate with Hydra onError if in context)
	local success: boolean, clone: any = pcall(Memoization.deepClone, t)
	if not success then
		Logger:Warn("deepClone failed: " .. tostring(clone))
		error(tostring(clone))  -- Propagate for callers to handle
	end
	return clone :: T
end

function Utils.mergeTables(base: any, override: any): any
	if typeof(base) ~= "table" or typeof(override) ~= "table" then return override end
	local merged: any = Utils.deepClone(base)
	for k, v in pairs(override) do
		if typeof(merged[k]) == "table" and typeof(v) == "table" then
			merged[k] = Utils.mergeTables(merged[k], v)
		else
			merged[k] = v
		end
	end
	return merged
end

function Utils.safeRequire(moduleScript: ModuleScript, registry: {[string]: HydraTypes.Entry}, config: HydraTypes.ConfigTable?): (boolean, any)
	-- Parameters registry and config are unused in this non-sandbox version but kept for compatibility
	local success: boolean, result: any = pcall(require, moduleScript)
	if not success then
		Logger:Warn("Require failed for " .. moduleScript.Name .. ": " .. tostring(result))
		if registry[moduleScript.Name] then  -- Optional: Mark error early if entry exists
			registry[moduleScript.Name].errorInfo = tostring(result)
		end
	end
	return success, result
end

function Utils.normalizePath(fullName: string, paths: HydraTypes.FolderPaths, location: "Server" | "Client" | "Shared", containerPattern: string): string
	local root: string = if location == "Server" then paths.server elseif location == "Client" then paths.client else ""
	local sharedRoot: string = if location == "Shared" then table.concat(paths.shared or {}, ".") else ""
	local stripped: string = fullName:gsub(containerPattern, ""):gsub("^" .. root .. "%.", ""):gsub("^" .. sharedRoot .. "%.", "")
	return stripped:gsub("%.", ".")
end

function Utils.retryLifecycleFallback(options: HydraTypes.RetryOperationOptions, methodName: string, context: "Load" | "Init" | "Start" | "Stop", entry: HydraTypes.Entry?): PromiseModule.Promise<any>
	return PromiseModule.new(function(resolve: (any) -> (), reject: (any) -> ())
		local success: boolean, result: any = Utils.SafeCall(options.operation)
		if not success then
			local errMsg: string = tostring(result)
			Utils.logAndError(options, context, errMsg, entry)
			if options.moduleConfig and options.moduleConfig.critical then
				reject(errMsg)
			else
				resolve(nil)
			end
			return
		end
		local opPromise: PromiseModule.Promise<any> = if PromiseModule.isPromise(result) then result else PromiseModule.resolved(result)
		opPromise:Then(function(finalResult: any)
			if entry then
				entry.state = if context == "Load" then "loaded"
					elseif context == "Init" then "initialized"
					elseif context == "Start" then "started"
					elseif context == "Stop" then "stopped" else entry.state
			end
			Logger:Info(string.format("✅ %s succeeded in %s", context, options.moduleName))
			resolve(finalResult)
		end):Catch(function(err: any)
			local errMsg: string = tostring(err)
			Utils.logAndError(options, context, errMsg, entry)
			if options.moduleConfig and options.moduleConfig.critical then
				reject(errMsg)
			else
				resolve(nil)
			end
		end)
	end)
end

function Utils.retryFallback(options: HydraTypes.RetryOperationOptions, methodName: string, context: "Load" | "Init" | "Start" | "Stop", entry: HydraTypes.Entry?): PromiseModule.Promise<any>
	return PromiseModule.new(function(resolve: (any) -> (), reject: (any) -> ())
		local success: boolean, result: any = Utils.SafeCall(options.operation)
		if not success then
			local errMsg: string = tostring(result)
			Utils.logAndError(options, context, errMsg, entry)
			if options.moduleConfig and options.moduleConfig.critical then
				reject(errMsg)
			else
				resolve(nil)
			end
			return
		end
		local opPromise: PromiseModule.Promise<any> = if PromiseModule.isPromise(result) then result else PromiseModule.resolved(result)
		opPromise:Then(function(finalResult: any)
			if entry then
				entry.state = if context == "Load" then "loaded"
					elseif context == "Init" then "initialized"
					elseif context == "Start" then "started"
					elseif context == "Stop" then "stopped" else entry.state
			end
			Logger:Info(string.format("✅ %s succeeded in %s", context, options.moduleName))
			resolve(finalResult)
		end):Catch(function(err: any)
			local errMsg: string = tostring(err)
			Utils.logAndError(options, context, errMsg, entry)
			if options.moduleConfig and options.moduleConfig.critical then
				reject(errMsg)
			else
				resolve(nil)
			end
		end)
	end)
end

function Utils.logAndError(options: HydraTypes.RetryOperationOptions, context: string, errMsg: string, entry: HydraTypes.Entry?)
	Logger:Warn(string.format("❌ %s failed for %s: %s", context, options.moduleName, errMsg))
	if entry then
		entry.state = "error"
		entry.errorInfo = errMsg
		if entry.instance and Utils.getLifecycleMethod(entry.instance, "OnError") then
			Utils.SafeCall(entry.instance.OnError, entry.instance, errMsg)
		end
	end
	if options.hydra then
		options.hydra:OnError(string.format("Module %s failed for %s: %s", context, options.moduleName, errMsg))
	end
end

function Utils.keys(t: {[any]: any}): {any}
	local k: {any} = {}
	for key in pairs(t) do
		table.insert(k, key)
	end
	return k
end

return Utils