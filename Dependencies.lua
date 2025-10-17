--!strict

-- Support modules
local Types = require(script.Parent.Types)
local Guards = require(script.Parent.Types.Guards)  -- For guards like isFolderPaths

-- // Module // --
local ModuleConfigs: Types.ConfigTable = {

	_FolderPaths = {
		server = "Systems",
		client = "Core",
		shared = {"Managers"}
	} :: Types.FolderPaths,


	------------------------------------
	-------- SERVER --------
	["Data.ProfileLoader"] = {
		Dependencies = {},
		Location = "Server",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = true,  -- Main critical: Blocks on fail, enqueues for recovery
		initMaxAttempts = 10,  -- More retries for Init (data-heavy)
		jitter = true  -- Add jitter for backoff in retries
	} :: Types.ModuleConfig,
	["Data.DataManager"] = {
		Dependencies = {"Data.ProfileLoader"},
		Location = "Server",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = false 
	} :: Types.ModuleConfig,
	["Data.DataLinks"] = {
		Dependencies = {"Data.ProfileLoader"},
		Location = "Server",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = false
	} :: Types.ModuleConfig,
	["Data.LoginTracker"] = {
		Dependencies = {"Data.DataManager"},
		Location = "Server",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = false
	} :: Types.ModuleConfig,
	["Data.TestModule"] = {
		Dependencies = {"Data.DataManager"},
		Location = "Server",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = false
	} :: Types.ModuleConfig,
	-------- CLIENT --------
	["Client.Interface"] = {
		Dependencies = {},
		Location = "Client",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = true,
		startMaxAttempts = 3
	} :: Types.ModuleConfig,
	["Client.UIManager"] = {
		Dependencies = {},
		Location = "Client",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = false
	} :: Types.ModuleConfig,
	-------- SHARED --------
	["Managers.PlayerLC"] = {
		Dependencies = {},
		Location = "Shared",
		maxAttempts = 5,
		backgroundMaxAttempts = 5,
		critical = false
	} :: Types.ModuleConfig,
}

if not Guards.isFolderPaths(ModuleConfigs._FolderPaths) then
	error("Invalid _FolderPaths override in Dependencies module")
end

return ModuleConfigs