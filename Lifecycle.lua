--!strict

-- Services
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared modules
local PromiseModule = require(ReplicatedStorage.Shared.Promise)
local LogModule = require(ReplicatedStorage.Shared.Log)

-- Hydra modules
local HydraUtils = require(script.Parent.Utils)
local HydraRetry = require(script.Parent.Retry)
local Types = require(script.Parent.Types)
local Guards = require(script.Parent.Types.Guards)

-- Log Instance
local Logger = LogModule.new("Lifecycle")

-- // Module // --
local Module = {}

type MethodName = "Init" | "Start" | "Stop"
type SuccessState = "initialized" | "started" | "stopped"
type FailState = "error"
type SuccessMsgFn = (string) -> string

function Module.processLifecycle(options: Types.Options, order: {string}, methodName: MethodName, hasMethod: (any) -> boolean, successMsg: SuccessMsgFn, successState: SuccessState, failState: FailState): PromiseModule.Promise<()>
	return PromiseModule.new(function(resolve: () -> (), reject: (any) -> ())
		local chain: PromiseModule.Promise<()> = PromiseModule.resolved()
		for _, moduleName: string in ipairs(order) do
			chain = chain:Then(function(): PromiseModule.Promise<()>
				return PromiseModule.new(function(res: () -> (), rej: (any) -> ())
					local entry: Types.Entry? = options.registry[moduleName]
					if not entry or not entry.instance then
						Logger:Debug("⏭️ Skipping " .. methodName .. " for " .. moduleName .. " (no entry or instance)")
						res()
						return
					end
					local safeEntry: Types.Entry = entry :: Types.Entry

					local shouldSkip: boolean = false
					if methodName == "Init" then
						if safeEntry.state ~= "loaded" then shouldSkip = true end
					elseif methodName == "Start" then
						if safeEntry.state ~= "initialized" then shouldSkip = true end
					elseif methodName == "Stop" then
						if safeEntry.state ~= "started" then shouldSkip = true end
					end
					if shouldSkip then
						Logger:Debug("⏭️ Skipping " .. methodName .. " for " .. moduleName .. " (invalid state: " .. tostring(safeEntry.state) .. ")")
						res()
						return
					end

					if typeof(safeEntry.instance) ~= "table" then
						Logger:Warn("Invalid instance type for " .. moduleName .. ": expected table, got " .. typeof(safeEntry.instance))
						res()
						return
					end
					local instance: {[any]: any} = safeEntry.instance :: {[any]: any}

					if not hasMethod(instance) then
						Logger:Debug("⏭️ No " .. methodName .. " method for " .. moduleName)
						res()
						return
					end

					local moduleConfig: Types.ModuleConfig? = Guards.isModuleConfig(options.config[moduleName])
					local operation: () -> any = function()
						local success: boolean, result: any = HydraUtils.SafeCall(instance[methodName], instance)
						if not success then
							error(tostring(result))  -- Propagate for Retry to catch
						end
						return result
					end

					local retryOpts: Types.RetryOperationOptions = {
						operation = operation,
						moduleName = moduleName,
						context = methodName,
						hydra = options.hydra,
						moduleConfig = moduleConfig,
						onRetry = function(attempt: number, err: string)
							Logger:Warn(methodName .. " retry " .. attempt .. " for " .. moduleName .. ": " .. err)
						end
					}

					local retryOperation: (Types.RetryOperationOptions) -> PromiseModule.Promise<any> = HydraRetry.RetryOperation :: (Types.RetryOperationOptions) -> PromiseModule.Promise<any>

					retryOperation(retryOpts):Then(function(_: any)
						Logger:Info(successMsg(moduleName))
						safeEntry.state = successState
						res()
					end):Catch(function(err: any)
						local errMsg: string = tostring(err)
						Logger:Warn("❌ " .. methodName .. " failed for " .. moduleName .. ": " .. errMsg)
						safeEntry.state = failState
						safeEntry.errorInfo = errMsg
						local onError: any? = HydraUtils.getLifecycleMethod(instance, "OnError")
						if onError ~= nil and typeof(onError) == "function" then
							HydraUtils.SafeCall(onError, instance, errMsg)
						end
						if options.hydra then
							options.hydra:OnError("Module " .. methodName .. " failed for " .. moduleName .. ": " .. errMsg)
						end
						local isCritical = if moduleConfig then moduleConfig.critical else false
						if isCritical then
							rej(errMsg)  -- Propagate for critical (Task 2)
						else
							res()  -- Continue partial for non-critical
						end
					end)
				end)
			end):Catch(function(err: any)
				local errMsg: string = tostring(err)
				Logger:Warn(methodName .. " chain catch: " .. errMsg .. " (continuing partial)")
				if options.hydra then
					options.hydra:OnError(methodName .. " chain failed: " .. errMsg)
				end
				return PromiseModule.resolved()  -- Allow chain to proceed
			end)
		end
		chain:Then(resolve):Catch(reject)
	end)
end

return Module