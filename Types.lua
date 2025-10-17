--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared modules
local PromiseModule = require(ReplicatedStorage.Shared.Promise)
local SignalModule = require(ReplicatedStorage.Shared.Signal)
local MaidModule = require(ReplicatedStorage.Shared.Maid)

-- Utility modules
local PromiseUtils = require(ReplicatedStorage.Shared.Utility.PromiseUtils)
local PendingPromiseTracker = require(ReplicatedStorage.Shared.Utility.PendingPromiseTracker)
local SignalUtils = require(ReplicatedStorage.Shared.Utility.SignalUtils)

-- // Module // --
local Types = {}

-- Defines retry configuration options for operations like Load, Init, Start, Stop for backoff strategies.
export type RetryOptions = {
	initialWaitTime: number?,      -- Optional: Initial delay in seconds before first retry.
	maxAttempts: number?,          -- Optional: Maximum number of retry attempts.
	printWarning: boolean?,        -- Optional: Flag to log warnings on each retry.
	jitter: boolean?,              -- Optional: Add random jitter to backoff delays to prevent thundering herd.
	backoffStrategy: "exponential" | "fixed"?  -- Optional: Strategy for delay growth between retries.
}

export type RetryOptionsTable = { [string]: RetryOptions }

export type RetryOperationOptions = {
	operation: () -> any,          -- The function to retry
	moduleName: string,            -- For logging/context
	context: "Load" | "Init" | "Start" | "Runtime" | "Stop", 
	hydra: Hydra?,     -- Optional Hydra instance for queuing/onError
	moduleConfig: ModuleConfig?,  -- Per-module config (from registry)
	onRetry: (attempt: number, err: string) -> ()?  -- Optional callback on each retry
}

-- Configuration for individual modules in Hydra's dependency system; defines dependencies, location, and retry overrides per lifecycle.
export type ModuleConfig = {
	Dependencies: {string},        -- Required: Array of module names this module depends on.
	Location: "Client" | "Server" | "Shared",  -- Required: Runtime side for the module (enforces loading restrictions).
	initialWaitTime: number?,      -- Optional: General foreground retry delay for all operations.
	maxAttempts: number?,          -- Optional: General foreground max retries.
	printWarning: boolean?,        -- Optional: General foreground warning flag on retries.
	backgroundInitialWaitTime: number?,  -- Optional: Background retry delay for non-critical failures.
	backgroundMaxAttempts: number?,      -- Optional: Background max retries.
	backgroundPrintWarning: boolean?,    -- Optional: Background warning flag.
	critical: boolean?,            -- Optional: If true, failures block chain or queue for recovery (default false).
	allowDuplicates: boolean?,     -- Optional: Allow duplicate module names with warn (default false).
	jitter: boolean?,              -- Optional: General jitter flag.
	backoffStrategy: "exponential" | "fixed"?,  -- Optional: General backoff strategy.
	loadInitialWaitTime: number?,  -- Optional: Per-lifecycle overrides (Load)
	loadMaxAttempts: number?,
	loadPrintWarning: boolean?,
	loadJitter: boolean?,
	loadBackoffStrategy: "exponential" | "fixed"?,
	initInitialWaitTime: number?,  -- Init
	initMaxAttempts: number?,
	initPrintWarning: boolean?,
	initJitter: boolean?,
	initBackoffStrategy: "exponential" | "fixed"?,
	startInitialWaitTime: number?,  -- Start
	startMaxAttempts: number?,
	startPrintWarning: boolean?,
	startJitter: boolean?,
	startBackoffStrategy: "exponential" | "fixed"?,
	stopInitialWaitTime: number?,  -- Stop
	stopMaxAttempts: number?,
	stopPrintWarning: boolean?,
	stopJitter: boolean?,
	stopBackoffStrategy: "exponential" | "fixed"?,
	runtimeInitialWaitTime: number?,  -- Runtime
	runtimeMaxAttempts: number?,
	runtimePrintWarning: boolean?,
	runtimeJitter: boolean?,
	runtimeBackoffStrategy: "exponential" | "fixed"?,
}

export type SettledResult = {
	status: "fulfilled" | "rejected",
	value: any?,  -- Present if fulfilled
	reason: any?  -- Present if rejected
}

export type ConfigValue = ModuleConfig | RetryOptionsTable | boolean | number | FolderPaths | (string, string) -> ()

export type ConfigTable = { [string]: ConfigValue }

export type Entry = {
	moduleScript: ModuleScript,
	instance: any?,  -- Loaded instance (table)
	state: "registered" | "loaded" | "initialized" | "started" | "stopped" | "error" | "recovered",
	errorInfo: string?
}

export type Cache = { [string]: Cache | Entry }

export type MemoCache = { [any]: any }

export type HydraData = {
	registry: {[string]: Entry},
	cacheTable: {[Instance]: Cache},
	pendingLoadTracker: any,
	onModuleLoaded: any,
	signalMaid: any,
	Config: ConfigTable,
	recoveryQueue: {QueueEntry},
	onGlobalError: any,
	stopped: boolean,
}

export type HydraActions = {
	createFullOptions: (self: Hydra) -> Options,
	OnError: (self: Hydra, err: string?) -> (),
	Init: (self: Hydra) -> any,
	Stop: (self: Hydra) -> any,
	ProcessRecoveryQueue: (self: Hydra) -> (),
	CacheParent: (self: Hydra, parent: Instance, location: "Server" | "Client" | "Shared") -> Cache,  -- Add for typing
}

export type HydraMetatable = {
	__index: HydraActions
}

export type Hydra = typeof(setmetatable({} :: HydraData, {} :: HydraMetatable))

export type Options = {
	registry: {[string]: Entry},
	config: ConfigTable,
	hydra: Hydra,
	hasInit: (any) -> boolean,
	hasStart: (any) -> boolean,
	hasStop: (any) -> boolean,
	hasOnError: (any) -> boolean
}

export type QueueEntry = {
	priority: number,              -- For sorting recovery queue (lower = higher priority)
	moduleName: string,
	context: "Load" | "Init" | "Start" | "Stop" | "Runtime",
	operation: () -> any,
	dependents: {string},          -- Dependent modules to notify/retry after recovery
	retryCount: number,
	config: RetryOptions
}

export type FolderPaths = {
	server: string,
	client: string,
	shared: {string}?
}

return Types