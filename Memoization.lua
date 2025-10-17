--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Support modules
local HydraTypes = require(ReplicatedStorage.Hydra.Hydra.Types)

-- // Module // --
local Memoization = {}

local function memoize<A, R>(func: (A) -> R): (A) -> R
	local cache: HydraTypes.MemoCache = {}
	setmetatable(cache, {__mode = "k"})
	return function(arg: A): R
		local key: any = arg
		local cached: R? = cache[key]
		if cached ~= nil then return cached end  -- Nil-safe guard
		local result: R = func(arg)
		cache[key] = result
		return result
	end
end

function Memoization.deepClone(t: any, seen: {[any]: boolean}?): any
	if typeof(t) ~= "table" then return t end
	local safeSeen: {[any]: boolean} = if seen ~= nil then seen else {}
	local key: any = t
	if safeSeen[key] then error("Cycle detected in deepClone") end
	safeSeen[key] = true

	return memoize(function(innerT: any): any
		local clone: {[any]: any} = {}
		for k: any, v: any in pairs(innerT) do
			clone[Memoization.deepClone(k, safeSeen)] = Memoization.deepClone(v, safeSeen)
		end
		local mt: any = getmetatable(innerT)
		if mt and typeof(mt) == "table" then
			setmetatable(clone, mt)
		end
		return clone
	end)(t)
end

return Memoization