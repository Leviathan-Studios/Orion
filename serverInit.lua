--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Bootstrap = require(ReplicatedStorage.Hydra.Bootstrap)
local LogModule = require(ReplicatedStorage.Shared.Log)
local Logger = LogModule.new("Server Initialization")

Bootstrap.Init():Then(function()
	Logger:Success("🚀 Hydra core stabilized!")
end):Catch(function(err: string)
	Logger:Warn("Server bootstrap failed: " .. err)
end)

-- Shutdown binding
game:BindToClose(function()
	Bootstrap.Stop():Then(function()
		Logger:Success("👽 Server shutdown complete")
	end):Catch(function(err: string)
		Logger:Warn("Server shutdown failed: " .. err)
	end):Wait()
end)