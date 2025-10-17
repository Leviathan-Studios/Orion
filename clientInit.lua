--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Bootstrap = require(ReplicatedStorage.Hydra.Bootstrap)
local LogModule = require(ReplicatedStorage.Shared.Log)
local Logger = LogModule.new("Client Initialization")

local Players = game:GetService("Players")

Bootstrap.Init():Then(function()
	Logger:Success("🌌 Entering orbit!")
end):Catch(function(err: string)
	Logger:Warn("Client bootstrap failed: " .. err)
end)

-- Shutdown binding
local LocalPlayer = Players.LocalPlayer
LocalPlayer.AncestryChanged:Connect(function(_, parent: Instance?)
	if not parent then
		Bootstrap.Stop():Then(function()
			Logger:Success("👽 Client shutdown complete")
		end):Catch(function(err: string)
			Logger:Warn("Client shutdown failed: " .. err)
		end):Wait()
	end
end)