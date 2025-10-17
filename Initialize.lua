--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Folders
local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
if not Shared then warn("⚠️ Shared folder not found in ReplicatedStorage after timeout") end

-- Shared modules
local PromiseModule = require(Shared.Promise)
local LogModule = require(Shared.Log) 

-- Utility modules
local PromiseUtils = require(Shared.Utility.PromiseUtils)
local HydraUtils = require(script.Parent.Utils)
local HydraLoader = require(script.Parent.Loader)
local HydraCache = require(script.Parent.Cache)

-- Support modules
local Types = require(script.Parent.Types) 
local HydraRetry = require(script.Parent.Retry)

-- New: Lifecycle for centralized chains
local HydraLifecycle = require(script.Parent.Lifecycle)

-- Log Instance creation
local Logger = LogModule.new("Initialize") 

-- // Module // --
local Initialize = {}

function Initialize.collectModules(cache: Types.Cache): {string}
	local moduleList: {string} = {}

	-- Reuse Cache's traversal logic (adapted from Build's queue)
	type QueueItem = {subCache: Types.Cache, basePath: string?}
	local queue: {QueueItem} = {{subCache = cache, basePath = nil}}

	while #queue > 0 do
		local item: QueueItem = table.remove(queue, 1) :: QueueItem
		local path: string = if item.basePath then item.basePath .. "." else ""

		for name: string, subItem: any in pairs(item.subCache) do
			if type(subItem) == "table" then
				if (subItem :: any).moduleScript then
					local moduleFullPath: string = path .. name
					table.insert(moduleList, moduleFullPath)
				else
					table.insert(queue, {subCache = subItem :: Types.Cache, basePath = path .. name})
				end
			end
		end
	end

	return moduleList
end

function Initialize.ResolveModules(options: Types.Options, allModules: {string}): PromiseModule.Promise<{[string]: any}>
	local order: {string}? = HydraUtils.TopologicalSort(allModules, options.config)
	if not order then
		local msg = "⚠️ Skipping loading due to dependency cycle"
		if options.config._StrictValidation then
			return PromiseModule.rejected(msg)
		else
			Logger:Warn(msg)
			options.hydra:OnError("Dependency cycle in modules")
			return PromiseModule.resolved({})
		end
	end
	Logger:Debug("Load order: " .. table.concat(order, ", "))

	local loaded: {[string]: any} = {}
	local chain: PromiseModule.Promise<{[string]: any}> = PromiseModule.resolved(loaded)
	for _, moduleName: string in ipairs(order) do
		chain = chain:Then(function(): PromiseModule.Promise<any?>
			return HydraLoader.LoadModule(moduleName, options.registry, options.config, options.hydra):Then(function(result: any?)
				if result then
					loaded[moduleName] = result
					local entry: Types.Entry? = options.registry[moduleName]
					if entry then
						entry.instance = result
						entry.state = "loaded"
						Logger:Info("Loaded module: " .. moduleName)
					end
				end
				return result
			end)
		end):Catch(function(err: any)
			local errMsg: string = tostring(err)
			Logger:Warn("Load chain failed for " .. moduleName .. ": " .. errMsg)
			options.hydra:OnError("Load chain failed: " .. errMsg)
			return nil  -- Continue partial load
		end)
	end

	return chain
end

function Initialize.InitModules(options: Types.Options, order: {string}): PromiseModule.Promise<()>
	local hasInit: (any) -> boolean = function(instance: any): boolean
		return typeof(instance.Init) == "function"
	end
	local successMsg: (string) -> string = function(moduleName: string): string
		return "✅ Initialized module: " .. moduleName
	end
	return HydraLifecycle.processLifecycle(options, order, "Init", hasInit, successMsg, "initialized", "error")
end

function Initialize.StartModules(options: Types.Options, order: {string}): PromiseModule.Promise<()>
	local hasStart: (any) -> boolean = function(instance: any): boolean
		return typeof(instance.Start) == "function"
	end
	local successMsg: (string) -> string = function(moduleName: string): string
		return "✅ Started module: " .. moduleName
	end
	return HydraLifecycle.processLifecycle(options, order, "Start", hasStart, successMsg, "started", "error")
end

return Initialize