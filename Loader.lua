--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService: RunService = game:GetService("RunService")

-- Folders
local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
if not Shared then warn("⚠️ Shared folder not found in ReplicatedStorage after timeout") end

-- Shared modules
local PromiseModule = require(Shared.Promise)
local LogModule = require(Shared.Log)

-- Utility modules
local PromiseUtils = require(Shared.Utility.PromiseUtils)
local HydraUtils = require(script.Parent.Utils)

-- Support modules
local HydraTypes = require(script.Parent.Types)
local HydraTypeGuards = require(script.Parent.Types.Guards)
local HydraRetry = require(script.Parent.Retry)

-- Log Instance creation
local Logger = LogModule.new("Loader")  

-- // Module // --
local Loader = {}

function Loader.OnError(err: string?)
	if Logger then
		Logger:Warn("Loader error: " .. tostring(err or "Unknown"))
	else
		warn("Loader error: " .. tostring(err or "Unknown"))
	end
end

local Cache: {[string]: any?} = {}
local LoadingSet: {[string]: boolean} = {}

function Loader.LoadModule(moduleName: string, registry: {[string]: HydraTypes.Entry}, config: HydraTypes.ConfigTable?, hydra: HydraTypes.Hydra?): PromiseModule.Promise<any?>
	local entry: HydraTypes.Entry? = registry[moduleName]
	if not entry or not entry.moduleScript then
		Logger:Warn("Entry or ModuleScript missing for " .. moduleName .. "; no retry attempted")
		return PromiseModule.resolved(nil)
	end

	if Cache[moduleName] then
		return PromiseModule.resolved(Cache[moduleName])
	end

	if LoadingSet[moduleName] then
		local errMsg: string = "Circular dependency detected involving: " .. moduleName
		Logger:Warn(errMsg)
		LoadingSet[moduleName] = nil  -- Clear to prevent stale locks
		if hydra then
			hydra:OnError(errMsg)
		end
		return PromiseModule.rejected(errMsg)
	end
	LoadingSet[moduleName] = true

	local isClientRuntime: boolean = RunService:IsClient()
	if entry.moduleScript:GetAttribute("ClientOnly") and not isClientRuntime then
		LoadingSet[moduleName] = nil
		Logger:Info("Skipped client-only module on server: " .. moduleName)
		return PromiseModule.resolved(nil)
	end

	local effectiveConfig: HydraTypes.ConfigTable = config or {}
	local smallConfig: HydraTypes.ConfigTable = {}
	for k: string, v: any in pairs(effectiveConfig) do
		if k:sub(1,1) == "_" then
			smallConfig[k] = v
		end
	end
	local moduleConf: any = effectiveConfig[moduleName]
	if moduleConf then
		smallConfig[moduleName] = moduleConf  -- Add module-specific if present
	end

	local moduleConfig: HydraTypes.ModuleConfig? = HydraTypeGuards.isModuleConfig(moduleConf)

	local operation: () -> any = function()
		return HydraUtils.safeRequire(entry.moduleScript, registry, config)  -- Fix: Add registry and config to match signature (registry for error marking, config optional)
	end

	local retryOpts: HydraTypes.RetryOperationOptions = {
		operation = operation,
		moduleName = moduleName,
		context = "Load",
		hydra = hydra,
		moduleConfig = moduleConfig,
		onRetry = function(attempt: number, err: string)
			Logger:Warn("Load retry " .. attempt .. " for " .. moduleName .. ": " .. err)
		end
	}

	local retryOperation: (HydraTypes.RetryOperationOptions) -> PromiseModule.Promise<any> = HydraRetry.RetryOperation :: (HydraTypes.RetryOperationOptions) -> PromiseModule.Promise<any>  -- Fix: Narrow to non-nil

	return retryOperation(retryOpts):Then(function(result: any?)
		LoadingSet[moduleName] = nil
		if result then
			Cache[moduleName] = result
			if entry then
				entry.instance = result
				entry.state = "loaded"  -- Explicit transition from "registered"
				entry.errorInfo = nil
				if hydra then
					hydra.onModuleLoaded:Fire(moduleName, entry.instance)
				end
			end
		end
		return result
	end):Catch(function(err: any)
		LoadingSet[moduleName] = nil
		local errMsg: string = tostring(err)
		if entry then
			entry.state = "error"
			entry.errorInfo = errMsg
			if entry.instance and HydraUtils.getLifecycleMethod(entry.instance, "OnError") then
				HydraUtils.SafeCall(entry.instance.OnError, entry.instance, errMsg)
			end
		end
		Loader.OnError("Load failed for " .. moduleName .. ": " .. errMsg)
		if hydra then
			hydra:OnError("Load failed for " .. moduleName .. ": " .. errMsg)
		end
		return nil  -- Continue chain
	end)
end

function Loader.LoadDependencies(config: HydraTypes.ConfigTable, registry: {[string]: HydraTypes.Entry}, hydra: HydraTypes.Hydra?): PromiseModule.Promise<{[string]: any}>
	return PromiseModule.new(function(resolve: ({[string]: any}) -> (), reject: (string) -> ())
		local loaded: {[string]: any} = {}

		local moduleList: {string} = {}
		for moduleName: string, _ in pairs(config) do
			if moduleName:sub(1,1) ~= "_" then
				table.insert(moduleList, moduleName)
			end
		end

		local order: {string}? = HydraUtils.TopologicalSort(moduleList, hydra and hydra.Config or config)
		if not order then
			Loader.OnError("Dependency cycle detected in config")
			reject("Dependency cycle")
			return
		end

		local chain: PromiseModule.Promise<()> = PromiseModule.resolved()
		for _, moduleName: string in ipairs(order) do
			chain = chain:Then(function(): PromiseModule.Promise<any?>
				return Loader.LoadModule(moduleName, registry, config, hydra):Then(function(result: any?)
					if result then
						loaded[moduleName] = result
					end
					return result
				end)
			end):Catch(function(err: any)
				Loader.OnError("Load chain failed for " .. moduleName .. ": " .. tostring(err))
			end)
		end

		chain:Then(function()
			local allSuccess: boolean = true
			for _, moduleName: string in ipairs(moduleList) do
				if loaded[moduleName] == nil then allSuccess = false end
			end
			if allSuccess then
				resolve(loaded)
			else
				reject("Some modules failed to load")
			end
		end):Catch(function(err: any)
			Loader.OnError("Overall load dependencies failed: " .. tostring(err))
			reject(tostring(err))
		end)
	end)
end

return Loader