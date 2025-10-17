--!strict
--testcommit
-- Services
local RunService = game:GetService("RunService")
local ServerStorage: ServerStorage? = if RunService:IsServer() then game:GetService("ServerStorage") else nil
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

-- Folders
local Shared = ReplicatedStorage:WaitForChild("Shared", 5)
if not Shared then warn("⚠️ Shared folder not found in ReplicatedStorage after timeout") return {} end

-- Shared modules
local PromiseModule = require(Shared.Promise)
local MaidModule = require(Shared.Maid)
local SignalModule = require(Shared.Signal)
local LogModule = require(Shared.Log)

-- Utility modules
local PromiseUtils = require(Shared.Utility.PromiseUtils)
local PendingPromiseTracker = require(Shared.Utility.PendingPromiseTracker)

-- Child modules
local HydraCache = require(script.Cache)
local HydraLoader = require(script.Loader)
local HydraInitialize = require(script.Initialize)
local HydraStopper = require(script.Stopper)
local HydraUtils = require(script.Utils)
local HydraValidate = require(script.Validate)
local HydraTypes = require(script.Types)
local HydraTypeGuards = require(script.Types.Guards)
local HydraRetry = require(script.Retry)
local HydraLifecycle = require(script.Lifecycle)

-- Log Instance creation
local Logger = LogModule.new("Hydra")

-- Support modules // Config merge
local GlobalConfig: HydraTypes.ConfigTable = require(script.Config) :: HydraTypes.ConfigTable
local Dependencies: any = require(script.Dependencies)
local ModuleConfigs: HydraTypes.ConfigTable? = if typeof(Dependencies) == "table" then Dependencies :: HydraTypes.ConfigTable else nil

-- // Module // --
local Hydra = {}
local Actions = {}
Hydra.__index = Actions

local singletonInstance: HydraTypes.Hydra?

function Actions.createFullOptions(self: HydraTypes.Hydra): HydraTypes.Options
	return {
		registry = self.registry,
		config = self.Config,
		hydra = self,
		hasInit = function(inst: any): boolean return typeof(inst.Init) == "function" end,
		hasStart = function(inst: any): boolean return typeof(inst.Start) == "function" end,
		hasStop = function(inst: any): boolean return typeof(inst.Stop) == "function" end,
		hasOnError = function(inst: any): boolean return typeof(inst.OnError) == "function" end
	}
end

function Actions.CacheParent(self: HydraTypes.Hydra, parent: Instance, location: "Server" | "Client" | "Shared"): HydraTypes.Cache
	return HydraCache.BuildAndCache({
		parent = parent,
		registry = self.registry,
		cacheTable = self.cacheTable,
		config = self.Config,
		runService = RunService,
		hydra = self,
		location = location
	})
end

function Actions.OnError(self: HydraTypes.Hydra, err: string?)
	local self: HydraTypes.Hydra = self :: HydraTypes.Hydra
	Logger:Warn("Hydra error: " .. tostring(err or "Unknown"))
	self.onGlobalError:Fire("Hydra", tostring(err or "Unknown"), if RunService:IsServer() then "Server" else "Client")
end

function Actions.Init(self: HydraTypes.Hydra): PromiseModule.Promise<()>
	local self: HydraTypes.Hydra = self :: HydraTypes.Hydra
	return PromiseModule.new(function(resolve: () -> (), reject: (any) -> ())
		Logger:TimeStart("Hydra Init")
		local side: "Server" | "Client" = if RunService:IsServer() then "Server" else "Client"  -- Compute early for timings
		local success: boolean, validateErr: any = HydraUtils.SafeCall(HydraValidate.ValidateConfig, self.Config, self)
		if not success then
			local errMsg: string = tostring(validateErr or "Unknown validation error")
			Logger:Warn("Config validation failed: " .. errMsg)
			self:OnError("Config validation failed: " .. errMsg)
			reject(errMsg)
			return
		end

		local allModules: {string} = {}
		local order: {string}? = nil

		-- Cache and collect modules
		local cacheChain: PromiseModule.Promise<()> = PromiseModule.new(function(res: () -> (), rej: (string) -> ())
			local pathsValue: any = self.Config._FolderPaths
			local paths: HydraTypes.FolderPaths = HydraTypeGuards.isFolderPaths(pathsValue) or {server = "Systems", client = "Core", shared = {"Managers"}}
			local rootName: string = if side == "Server" then paths.server else paths.client
			local root: Instance? = nil
			if side == "Server" then
				if ServerStorage then
					root = ServerStorage:FindFirstChild(rootName)
				end
			else
				local playerScripts: Instance? = Players.LocalPlayer:WaitForChild("PlayerScripts", 5)
				if playerScripts then
					root = playerScripts:FindFirstChild(rootName)
				end
			end
			if not root then
				local msg: string = rootName .. " folder missing or invalid on " .. side
				Logger:Warn(msg)
				self:OnError(msg)
				rej(msg)
				return
			end
			local success: boolean, cacheErr: any = HydraUtils.SafeCall(HydraCache.BuildAndCache, {parent = root, registry = self.registry, cacheTable = self.cacheTable, config = self.Config, runService = RunService, hydra = self, location = side})
			if not success then
				local errMsg: string = tostring(cacheErr)
				Logger:Warn("BuildAndCache failed: " .. errMsg)
				self:OnError("BuildAndCache failed: " .. errMsg)
				rej(errMsg)
				return
			end
			local modules: {string} = HydraInitialize.collectModules(self.cacheTable[root] or {})
			for _, mod: string in ipairs(modules) do
				table.insert(allModules, mod)
			end
			res()
		end):Catch(function(err: string)
			Logger:Warn("Cache chain failed: " .. err)
			self:OnError("Cache chain failed: " .. err)
			return PromiseModule.resolved()  -- Continue partial
		end)

		cacheChain:Then(function()
			order = HydraUtils.TopologicalSort(allModules, self.Config)
			if not order then
				Logger:Warn("Dependency cycle detected")
				self:OnError("Dependency cycle in modules")
				resolve()  -- Partial no-op
				return
			end
		end):Then(function()
			local opts: HydraTypes.Options = self:createFullOptions()
			return HydraInitialize.ResolveModules(opts, allModules)
		end):Then(function(_: {[string]: any})
			if order then
				local opts: HydraTypes.Options = self:createFullOptions()
				return HydraInitialize.InitModules(opts, order)
			else
				return PromiseModule.resolved()
			end
		end):Then(function()
			if order then
				local opts: HydraTypes.Options = self:createFullOptions()
				return HydraInitialize.StartModules(opts, order)
			else
				return PromiseModule.resolved()
			end
		end):Then(function()
			self:ProcessRecoveryQueue()
			Logger:Success("✅ Framework init complete")
			resolve()
		end):Catch(function(err: any)
			local errMsg: string = tostring(err)
			Logger:Warn("Init chain failed: " .. errMsg)
			self:OnError("Init chain failed: " .. errMsg)
			reject(errMsg)
		end)
	end)
end

function Actions.Stop(self: HydraTypes.Hydra): PromiseModule.Promise<()>
	local self: HydraTypes.Hydra = self :: HydraTypes.Hydra
	return PromiseModule.new(function(resolve: () -> (), reject: (any) -> ())
		local opts: HydraTypes.Options = self:createFullOptions()
		HydraStopper.StopModules(opts):Then(function()
			Logger:Success("✅ Framework stop complete")
			resolve()
		end):Catch(function(err: any)
			local errMsg: string = tostring(err)
			Logger:Warn("Stop chain failed: " .. errMsg)
			self:OnError("Stop chain failed: " .. errMsg)
			reject(errMsg)
		end)
	end)
end

function Actions.ProcessRecoveryQueue(self: HydraTypes.Hydra): ()
	local self: HydraTypes.Hydra = self :: HydraTypes.Hydra
	if #self.recoveryQueue == 0 then return end
	table.sort(self.recoveryQueue, function(a: HydraTypes.QueueEntry, b: HydraTypes.QueueEntry): boolean
		return a.priority < b.priority
	end)
	for _, entry: HydraTypes.QueueEntry in ipairs(self.recoveryQueue) do
		local success: boolean, result: any = HydraUtils.SafeCall(entry.operation)
		if not success then
			Logger:Warn("Recovery failed for " .. entry.moduleName .. ": " .. tostring(result))
			self:OnError("Recovery failed for " .. entry.moduleName .. ": " .. tostring(result))
		end
	end
	self.recoveryQueue = {}
end

function Hydra.new(): HydraTypes.Hydra
	if singletonInstance then
		return singletonInstance
	end

	local Config: HydraTypes.ConfigTable = HydraUtils.deepClone(GlobalConfig)

	if ModuleConfigs then
		for key: string, value: any in pairs(ModuleConfigs) do
			local existing: any = Config[key]
			if existing then
				if typeof(existing) == "table" and typeof(value) == "table" then
					local base: { [any]: any } = HydraUtils.deepClone(existing)
					for sk: any, sv: any in pairs(value) do
						base[sk] = sv
					end
					Config[key] = base
				else
					if key:sub(1,1) == "_" then
						Logger:Warn("⚠️ Config key conflict during merge: " .. key .. " (overriding with Dependencies value)")
					end
					Config[key] = value
				end
			else
				Config[key] = value
			end
		end
	else
		Logger:Warn("⚠️ Dependencies module missing or invalid; using globals only")
	end

	local tempSelf = {
		registry = {} :: {[string]: HydraTypes.Entry},
		cacheTable = {} :: {[Instance]: HydraTypes.Cache},
		pendingLoadTracker = PendingPromiseTracker.new(),
		onModuleLoaded = SignalModule.new(),
		signalMaid = MaidModule.new(),
		Config = Config,
		recoveryQueue = {} :: {HydraTypes.QueueEntry},
		onGlobalError = SignalModule.new(),
		stopped = false
	}
	local instance = setmetatable(tempSelf, Hydra)
	local self = HydraTypeGuards.isHydra(instance) or error("Hydra type assertion failed")  -- Use guard to narrow

	singletonInstance = self
	self.signalMaid:GiveTask(self.onGlobalError:Connect(function(source: string, err: string, side: string)
		Logger:Warn(string.format("[%s %s] Global error: %s", source, side, err))
	end))

	if RunService:IsServer() then
		self.signalMaid:GiveTask(Players.PlayerRemoving:Connect(function(player: Player)
			if #Players:GetPlayers() == 1 and not self.stopped then  -- Last player
				self.stopped = true  -- Prevent re-entrance
				self:Stop():Then(function()
					Logger:Success("Server fully stopped on last player leave")
				end):Catch(function(err: any)
					self:OnError("Stop failed on last player: " .. tostring(err))
				end):Wait()  -- Block for complete save
			end
		end))
	end

	return self
end

Hydra.GetInstance = function(): HydraTypes.Hydra
	if not singletonInstance then
		return Hydra.new()
	end
	return singletonInstance :: HydraTypes.Hydra
end

return Hydra
