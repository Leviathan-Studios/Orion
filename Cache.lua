--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Folders
local Shared = ReplicatedStorage:WaitForChild("Shared", 5) 
if not Shared then warn("⚠️ Shared folder not found in ReplicatedStorage after timeout - Falling back to basic print for Cache logs") end

-- Shared modules
local LogModule = require(Shared.Log)

-- Utility modules
local HydraUtils = require(script.Parent.Utils)

-- Support modules
local Types = require(script.Parent.Types)
local Guards = require(script.Parent.Types.Guards)

-- Log Instance creation
local Logger = LogModule.new("Cache") 

-- // Module // --
local Cache = {}

function Cache.OnError(hydra: Types.Hydra?, err: string?)
	if Logger then
		Logger:Warn("Cache error: " .. tostring(err or "Unknown"))
	else
		print("[Hydra Cache Error]: " .. tostring(err or "Unknown"))
	end
	if hydra then
		hydra:OnError("Cache: " .. tostring(err or "Unknown"))
	end
end

function Cache.Build(options: {parent: Instance, registry: {[string]: Types.Entry}, config: any, runService: any, hydra: Types.Hydra?, location: "Server" | "Client" | "Shared"}): Types.Cache
	local function logWarn(msg: string)
		if Logger then
			Logger:Warn(msg)
		else
			print("[Hydra Cache Warn]: " .. msg)
		end
	end

	local parent: Instance = options.parent
	local registry: {[string]: Types.Entry} = options.registry
	local ComponentsConfig = options.config
	local RunService = options.runService
	local hydra: Types.Hydra? = options.hydra
	local location: "Server" | "Client" | "Shared" = options.location

	assert(typeof(parent) == "Instance", "Parent must be an Instance")
	assert(location == "Server" or location == "Client" or location == "Shared", "Invalid location")
	if not parent:IsA("Folder") then
		logWarn("❌ Parent is not a Folder (ClassName: " .. parent.ClassName .. ") - Skipping build, returning empty cache")
		Cache.OnError(hydra, "Invalid parent type: " .. parent.ClassName)
		return {}
	end

	local cache: Types.Cache = {}
	local traversalCache: Types.Cache = cache
	if location == "Shared" then
		traversalCache = {}
		cache[parent.Name] = traversalCache
	end

	local seenModules: {[string]: boolean} = {}

	local pathsValue: any = ComponentsConfig._FolderPaths
	local paths: Types.FolderPaths = Guards.isFolderPaths(pathsValue) or {server = "Systems", client = "Core", shared = {"Managers"}}
	local containerPattern: string = if location == "Server" then "^ServerStorage%." else if location == "Client" then "^PlayerScripts%." else "^ReplicatedStorage%."

	local function validateModuleEntry(child: ModuleScript, currentPath: string, depth: number): Types.Entry?
		if child.Name == "Hydra" or child.Name == "Config" or child.Name == "Dependencies" or child.Name == "Bootstrap" or child.Name == "Types" or child.Name == "Guards" or child.Name == "Utils" or child.Name == "Cache" or child.Name == "Loader" or child.Name == "Initialize" or child.Name == "Stopper" or child.Name == "Retry" or child.Name == "Validate" or child.Name == "Lifecycle" or child.Name == "Log" or child.Name == "Memoization" then
			return nil  -- Skip framework modules
		end

		local fullName: string = child:GetFullName()
		local moduleFullPath: string = HydraUtils.normalizePath(fullName, paths, location, containerPattern)
		if seenModules[moduleFullPath] then
			logWarn("⚠️ Duplicate module detected: " .. moduleFullPath .. "; skipping")
			return nil
		end
		seenModules[moduleFullPath] = true

		if child:GetAttribute("Disabled") then
			logWarn("⚠️ Disabled module skipped: " .. moduleFullPath)
			return nil
		end

		if child:GetAttribute("ClientOnly") and RunService:IsServer() then
			logWarn("⚠️ Client-only module skipped on server: " .. moduleFullPath)
			return nil
		end

		return {
			moduleScript = child,
			instance = nil,
			state = "registered",
			errorInfo = nil
		}
	end

	type QueueItem = {current: Instance, currentCache: Types.Cache, currentPath: string, depth: number}
	local queue: {QueueItem} = {{current = parent, currentCache = traversalCache, currentPath = "", depth = 0}}
	local tail: number = 1

	while tail > 0 do
		local item: QueueItem = table.remove(queue, 1) :: QueueItem
		tail -= 1
		local current: Instance = item.current
		local currentCache: Types.Cache = item.currentCache
		local currentPath: string = item.currentPath
		local depth: number = item.depth

		for _, child: Instance in ipairs(current:GetChildren()) do
			if child:IsA("ModuleScript") then
				local entry: Types.Entry? = validateModuleEntry(child :: ModuleScript, currentPath, depth)
				if entry then
					local moduleName: string = child.Name
					currentCache[moduleName] = entry
					local moduleFullPath: string = currentPath .. moduleName
					registry[moduleFullPath] = entry
				end
			elseif child:IsA("Folder") then
				local subCache: Types.Cache = {}
				currentCache[child.Name] = subCache
				table.insert(queue, {current = child :: Instance, currentCache = subCache, currentPath = currentPath .. child.Name .. ".", depth = depth + 1})
				tail += 1
			else
				logWarn("⚠️ Unexpected child in traversal: " .. child.Name .. " (ClassName: " .. child.ClassName .. "); ignoring")
			end
		end
	end

	return cache
end

function Cache.BuildAndCache(options: {parent: Instance, registry: {[string]: Types.Entry}, cacheTable: {[Instance]: Types.Cache}, config: any, runService: any, hydra: Types.Hydra?, location: "Server" | "Client" | "Shared"}): Types.Cache
	local parent: Instance = options.parent
	local registry: {[string]: Types.Entry} = options.registry
	local cacheTable: {[Instance]: Types.Cache} = options.cacheTable
	local config = options.config
	local runService = options.runService
	local hydra: Types.Hydra? = options.hydra
	local location: "Server" | "Client" | "Shared" = options.location

	if cacheTable[parent] then
		return cacheTable[parent]
	end

	local success, cacheOrErr = HydraUtils.SafeCall(Cache.Build, {
		parent = parent,
		registry = registry,
		config = config,
		runService = runService,
		hydra = hydra,
		location = location
	})

	if not success then
		Cache.OnError(hydra, cacheOrErr :: string)
		return {}
	end

	local cache: Types.Cache = cacheOrErr :: Types.Cache
	cacheTable[parent] = cache
	return cache
end

function Cache.Invalidate(options: {parent: Instance, cacheTable: {[Instance]: Types.Cache}, registry: {[string]: Types.Entry}}): ()
	local parent: Instance = options.parent
	local cacheTable: {[Instance]: Types.Cache} = options.cacheTable
	local registry: {[string]: Types.Entry} = options.registry

	if not cacheTable[parent] then return end

	for key: string, entry: Types.Entry in pairs(registry) do
		if entry.moduleScript:IsDescendantOf(parent) then
			registry[key] = nil
		end
	end
	cacheTable[parent] = nil
end

function Cache.Find(cache: Types.Cache, moduleFullPath: string): Types.Entry?
	local parts: {string} = moduleFullPath:split(".")
	local current: any = cache
	for i: number = 1, #parts - 1 do
		current = current[parts[i]]
		if not current or type(current) ~= "table" then
			return nil
		end
	end
	local entry: any = current[parts[#parts]]
	if type(entry) == "table" and entry.moduleScript then
		return entry :: Types.Entry
	else
		return nil
	end
end

return Cache