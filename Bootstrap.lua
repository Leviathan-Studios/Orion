--!strict

-- Services
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ServerStorage = if RunService:IsServer() then game:GetService("ServerStorage") else nil
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Hydra requires
local HydraModule = ReplicatedStorage:WaitForChild("Hydra"):WaitForChild("Hydra") :: ModuleScript
local Hydra = require(HydraModule) :: typeof(require(script.Parent.Parent.Hydra))
local HydraUtils = require(ReplicatedStorage.Hydra.Hydra.Utils)
local Types = require(ReplicatedStorage.Hydra.Hydra.Types)
local Guards = require(ReplicatedStorage.Hydra.Hydra.Types.Guards)
local HydraStopper = require(ReplicatedStorage.Hydra.Hydra.Stopper)

-- Shared
local PromiseModule = require(ReplicatedStorage.Shared.Promise)
local LogModule = require(ReplicatedStorage.Shared.Log)

-- Log Instance creation
local Logger = LogModule.new("Bootstrap")

-- // Module // --
local Bootstrap = {}

function Bootstrap.Init(): PromiseModule.Promise<()>
	return PromiseModule.new(function(resolve: () -> (), reject: (string) -> ())
		local success: boolean, err: any = pcall(function()
			local hydra: Types.Hydra = Hydra.GetInstance()

			local function OnError(err: string?)
				Logger:Warn((if RunService:IsServer() then "Server" else "Client") .. " Bootstrap error: " .. tostring(err or "Unknown"))
				hydra:OnError("Bootstrap: " .. tostring(err or "Unknown"))
			end

			-- Get paths with fallback
			local pathsValue: any = hydra.Config._FolderPaths
			local paths: Types.FolderPaths = Guards.isFolderPaths(pathsValue) or {server = "Systems", client = "Core", shared = {"Managers"}}

			-- Context-specific root folder and location
			local rootFolder: Instance? = nil
			local rootName: string = ""
			local location: "Server" | "Client" = if RunService:IsServer() then "Server" else "Client"
			if RunService:IsServer() then
				rootName = paths.server
				rootFolder = ServerStorage:FindFirstChild(rootName)
				if not rootFolder then
					local msg: string = rootName .. " folder missing or invalid"
					Logger:Warn(msg)
					OnError(msg)
					reject(msg)
					return
				end
			elseif RunService:IsClient() then
				rootName = paths.client
				local LocalPlayer: Player = Players.LocalPlayer
				local PlayerScripts: Instance? = LocalPlayer:WaitForChild("PlayerScripts", 5)
				if not PlayerScripts then
					local msg: string = "PlayerScripts not found after timeout"
					Logger:Warn(msg)
					OnError(msg)
					reject(msg)
					return
				else
					rootFolder = PlayerScripts:FindFirstChild(rootName)
				end
			end

			if not rootFolder or not rootFolder:IsA("Folder") then
				local msg: string = rootName .. " folder missing or invalid on " .. location
				Logger:Warn(msg)
				OnError(msg)
				reject(msg)
				return
			end

			local cacheSuccess, cache = HydraUtils.SafeCall(hydra.CacheParent, hydra, rootFolder, location)
			if not cacheSuccess then
				local errMsg: string = tostring(cache)
				Logger:Warn("Failed to cache root folder: " .. errMsg)
				OnError("Failed to cache root folder: " .. errMsg)
				reject(errMsg)
				return
			end

			PromiseModule.resolved(cache):Wait()  -- Block until root cache complete

			local sharedFolders: {string} = paths.shared or {}
			local sharedPromises: {PromiseModule.Promise<()>} = {}
			for _, folderName: string in ipairs(sharedFolders) do
				table.insert(sharedPromises, PromiseModule.new(function(res: () -> (), rej: (string) -> ())
					local sharedFolder: Instance? = ReplicatedStorage:FindFirstChild(folderName)
					if sharedFolder and sharedFolder:IsA("Folder") then
						local sharedSuccess, sharedCache = HydraUtils.SafeCall(hydra.CacheParent, hydra, sharedFolder, "Shared" :: "Shared")
						if not sharedSuccess then
							local errMsg: string = tostring(sharedCache)
							Logger:Warn("Failed to cache shared folder " .. folderName .. ": " .. errMsg)
							OnError("Failed to cache shared folder " .. folderName .. ": " .. errMsg)
							rej(errMsg)
							return
						end
						res()
					else
						local msg: string = "Shared folder missing or invalid: " .. folderName
						Logger:Warn(msg)
						OnError(msg)
						rej(msg)
					end
				end))
			end

			local sharedChain = HydraUtils.allSettled(sharedPromises):Catch(function(err: string)
				Logger:Warn("Shared cache partial failure: " .. err)
				return PromiseModule.resolved()  -- Proceed
			end):Wait()  -- Block until shared complete (partial ok)

			sharedChain:Then(function()
				-- Chain Init (which includes ResolveModules, InitModules, StartModules, and ProcessRecoveryQueue)
				hydra:Init():Wait()  -- Block until init complete
				--	Logger:Success("Framework bootstrap complete")
				resolve()
			end):Catch(function(chainErr: any)
				Logger:Warn("Framework init chain failed: " .. tostring(chainErr))
				OnError("Framework init chain failed: " .. tostring(chainErr))
				reject(tostring(chainErr))
			end)
		end)

		if not success then
			Logger:Warn("Failed to initialize framework: " .. tostring(err))
			reject(tostring(err))
		end
	end)
end

function Bootstrap.Stop(): PromiseModule.Promise<()>
	return PromiseModule.new(function(resolve: () -> (), reject: (any) -> ())
		local hydraOpt: Types.Hydra? = Hydra.GetInstance()
		if hydraOpt == nil then
			Logger:Warn("Hydra instance missing during stop")
			resolve()  -- Graceful no-op
			return
		end
		local hydra: Types.Hydra = hydraOpt

		local stopPromise: PromiseModule.Promise<()> = hydra:Stop()
		stopPromise:Then(function()
			Logger:Success("✅ Framework stop complete")
			resolve()
		end):Catch(function(err: any)
			Logger:Warn("Framework stop chain failed: " .. tostring(err))
			reject(tostring(err))
		end)
	end)
end

return Bootstrap