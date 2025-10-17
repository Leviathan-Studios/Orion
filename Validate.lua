--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = if RunService:IsServer() then game:GetService("ServerStorage") else nil
local Players = game:GetService("Players")

-- Shared modules
local LogModule = require(ReplicatedStorage.Shared.Log)

-- Utility modules
local HydraUtils = require(script.Parent.Utils)

-- Support modules
local Types = require(script.Parent.Types)
local Guards = require(script.Parent.Types.Guards)

-- Log Instance creation
local Logger = LogModule.new("Validate")

-- // Module // --
local Validate = {}

function Validate.OnError(hydra: Types.Hydra?, err: string?)
	if Logger then
		Logger:Warn("Validate error: " .. tostring(err or "Unknown"))
	else
		warn("Validate error: " .. tostring(err or "Unknown"))
	end
	if hydra then
		hydra:OnError("Validate: " .. tostring(err or "Unknown"))
	end
end

local function FindFirstChildRecursive(parent: Instance, name: string): Instance?
	if parent:FindFirstChild(name) then
		return parent:FindFirstChild(name)
	end
	for _, child: Instance in ipairs(parent:GetChildren()) do
		if child:IsA("Folder") then
			local found: Instance? = FindFirstChildRecursive(child, name)
			if found then return found end
		end
	end
	return nil
end

function Validate.ValidateConfig(config: Types.ConfigTable, hydra: Types.Hydra?): ()
	local isServer: boolean = RunService:IsServer()
	local currentSide: "Client" | "Server" = if isServer then "Server" else "Client"
	local paths: Types.FolderPaths = Guards.getFolderPaths(config, "_FolderPaths", {server = "Systems", client = "Core", shared = {"Managers"}})
	local allErrors: {string} = {}

	-- Explicit typeof for strict boolean
	local strict: boolean = false
	if typeof(config._StrictValidation) == "boolean" then
		strict = config._StrictValidation
	else
		Logger:Warn("Invalid type for _StrictValidation; defaulting to false")
	end

	-- Filter relevant modules by side (explicit guards for comparisons)
	local relevantModules: {string} = {}
	for moduleFullPath: string, moduleConfigValue: any in pairs(config) do
		if moduleFullPath:sub(1,1) == "_" then continue end
		local moduleConfig: Types.ModuleConfig? = Guards.isModuleConfig(moduleConfigValue)
		if not moduleConfig then
			table.insert(allErrors, "Invalid config for " .. moduleFullPath)
			continue
		end

		local loc: "Client" | "Server" | "Shared" = moduleConfig.Location

		local isShared: boolean = loc == "Shared"
		local matchesSide: boolean = loc == currentSide
		local wrongSideServer: boolean = isServer and loc == "Client"  -- Explicit literal
		local wrongSideClient: boolean = not isServer and loc == "Server"

		if (matchesSide or isShared) and not (wrongSideServer or wrongSideClient) then
			table.insert(relevantModules, moduleFullPath)
		end
	end

	-- Single pass: Validate types, existence, deps
	local nums: {string} = {"maxAttempts", "backgroundMaxAttempts", "initialWaitTime", "backgroundInitialWaitTime", "initMaxAttempts", "initInitialWaitTime", "startMaxAttempts", "startInitialWaitTime", "stopMaxAttempts", "stopInitialWaitTime", "loadMaxAttempts", "loadInitialWaitTime", "runtimeMaxAttempts", "runtimeInitialWaitTime", "loadMaxAttempts", "stopMaxAttempts", "_MaxConcurrentRetries", "_QueueBackoff", "_MaxRecoveryAttempts"}
	local bools: {string} = {"critical", "printWarning", "backgroundPrintWarning", "initPrintWarning", "startPrintWarning", "stopPrintWarning", "jitter", "initJitter", "startJitter", "stopJitter", "backgroundJitter", "loadPrintWarning", "loadJitter", "runtimePrintWarning", "runtimeJitter", "_CriticalBackgroundRetries", "_UseRetryQueue", "_StrictLocationCheck", "_AllowDuplicates", "_StrictValidation"}
	local enums: {[string]: {string}} = {
		backoffStrategy = {"exponential", "fixed"},
		initBackoffStrategy = {"exponential", "fixed"},
		startBackoffStrategy = {"exponential", "fixed"},
		stopBackoffStrategy = {"exponential", "fixed"},
		loadBackoffStrategy = {"exponential", "fixed"},
		runtimeBackoffStrategy = {"exponential", "fixed"}
	}

	for _, moduleFullPath: string in ipairs(relevantModules) do
		local moduleConfigValue: any = config[moduleFullPath]
		local moduleConfig: Types.ModuleConfig = moduleConfigValue :: Types.ModuleConfig

		-- Validate optional numbers
		for _, key: string in ipairs(nums) do
			local value: any = moduleConfig[key]
			if value ~= nil and typeof(value) ~= "number" then
				table.insert(allErrors, "Invalid " .. key .. " in " .. moduleFullPath .. ": must be number")
			end
		end

		-- Validate optional booleans
		for _, key: string in ipairs(bools) do
			local value: any = moduleConfig[key]
			if value ~= nil and typeof(value) ~= "boolean" then
				table.insert(allErrors, "Invalid " .. key .. " in " .. moduleFullPath .. ": must be boolean")
			end
		end

		-- Validate optional enums (backoffStrategy etc.)
		for key: string, validEnums: {string} in pairs(enums) do
			local value: any = moduleConfig[key]
			if value ~= nil then
				local isValidEnum: boolean = false
				for _, enum: string in ipairs(validEnums) do
					if value == enum then isValidEnum = true break end
				end
				if not isValidEnum then
					table.insert(allErrors, "Invalid " .. key .. " in " .. moduleFullPath .. ": must be one of " .. table.concat(validEnums, " or "))
				end
			end
		end

		-- Existence check
		local location: "Client" | "Server" | "Shared" = moduleConfig.Location
		local root: Instance? = if location == "Server" then ServerStorage elseif location == "Client" and not isServer then Players.LocalPlayer:FindFirstChild("PlayerScripts") elseif location == "Shared" then ReplicatedStorage else nil
		if root then
			local moduleName: string = moduleFullPath:match("([^.]+)$") or moduleFullPath
			local found: Instance? = FindFirstChildRecursive(root, moduleName)
			if not found or not found:IsA("ModuleScript") then
				local msg: string = "ModuleScript not found for " .. moduleFullPath
				if strict then table.insert(allErrors, msg) else Logger:Warn(msg) end
			end
		end

		-- Dep checks
		for _, dep: string in ipairs(moduleConfig.Dependencies) do
			if typeof(dep) ~= "string" then
				table.insert(allErrors, "❌ Invalid dep in " .. moduleFullPath .. ": must be string")
				continue
			end
			local depConfig: any = config[dep]
			if not depConfig then
				local msg: string = "⚠️ Missing dependency config '" .. dep .. "' for " .. moduleFullPath
				if strict then
					table.insert(allErrors, "❌ " .. msg)
				else
					Logger:Warn(msg)
				end
			elseif not Guards.isModuleConfig(depConfig) then
				local msg: string = "⚠️ Invalid config for dependency '" .. dep .. "' of " .. moduleFullPath .. ": expected ModuleConfig"
				if strict then
					table.insert(allErrors, "❌ " .. msg)
				else
					Logger:Warn(msg)
				end
			else
				local depLocation: string = (depConfig :: Types.ModuleConfig).Location
				if moduleConfig.Location == "Shared" and depLocation ~= "Shared" then
					local msg: string = "⚠️ Side mismatch: Shared module " .. moduleFullPath .. " depends on " .. depLocation .. "-only " .. dep
					if strict then
						table.insert(allErrors, "❌ " .. msg)
					else
						Logger:Warn(msg)
					end
				elseif depLocation ~= "Shared" and moduleConfig.Location ~= "Shared" and depLocation ~= moduleConfig.Location then
					local msg: string = "⚠️ Side mismatch: " .. moduleConfig.Location .. " module " .. moduleFullPath .. " depends on " .. depLocation .. " " .. dep
					if strict then
						table.insert(allErrors, "❌ " .. msg)
					else
						Logger:Warn(msg)
					end
				end
			end
		end
	end

	-- Cycle check on relevant
	local order: {string}? = HydraUtils.TopologicalSort(relevantModules, config)
	if not order then
		table.insert(allErrors, "❌ Cycle detected in dependencies")
	end

	if #allErrors > 0 then
		local aggregated: string = table.concat(allErrors, "; ")
		if strict then
			error("❌ Config validation failed: " .. aggregated)
		else
			Logger:Warn("⚠️ Config validation warnings: " .. aggregated)
			Validate.OnError(hydra, aggregated)
		end
	end
end

return Validate