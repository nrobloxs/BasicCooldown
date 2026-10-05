--!strict

local Signal = require(script.Signal)

local Cooldown = {}
Cooldown.__index = Cooldown

export type Cooldown = typeof(setmetatable(
	{} :: {
		_Identifier: string,
		_Flag: boolean,
		_FlagPrev: boolean,
		_RevertTo: boolean,
		_Destroyed: boolean,
		_RevertThread: thread?,
		_FlaggingThread: thread?,
		_GetFlagThread: thread?,

		Verbose: boolean,
		FlaggingDisabled: boolean,
		GetFlagDisabled: boolean,
		Signal: typeof(Signal.new()),
	},
	Cooldown
))

local function CancelThread(Thread: thread?)
	if Thread then
		task.cancel(Thread)
	end
end

local function Format(Message: string, ...: any): string
	local Args = table.pack(...)
	for Index = 1, Args.n do
		Args[Index] = tostring(Args[Index])
	end
	return string.format(Message, table.unpack(Args, 1, Args.n))
end

local function Log(self: Cooldown, Message: string, ...: any)
	if self.Verbose then
		print(Format("[Cooldown:%s] " .. Message, self._Identifier, ...))
	end
end

local function Warn(self: Cooldown, Message: string, ...: any)
	if self.Verbose then
		warn(Format("[Cooldown:%s] " .. Message, self._Identifier, ...))
	end
end

function Cooldown.new(
	Identifier: string,
	InitialFlagValue: boolean?,
	FlaggingDisabled: boolean?,
	GetFlagDisabled: boolean?,
	Verbose: boolean?
): Cooldown
	assert(type(Identifier) == "string", "Cooldown.new: Identifier must be a string")

	local Initial = InitialFlagValue or false
	local self = setmetatable({
		_Identifier = Identifier,
		_Flag = Initial,
		_FlagPrev = false,
		_RevertTo = Initial,
		_Destroyed = false,
		_RevertThread = nil,
		_FlaggingThread = nil,
		_GetFlagThread = nil,
		Verbose = Verbose or false,
		FlaggingDisabled = FlaggingDisabled or false,
		GetFlagDisabled = GetFlagDisabled or false,
		Signal = Signal.new(),
	}, Cooldown) :: Cooldown

	Log(
		self,
		"Created (flag=%s, flaggingDisabled=%s, getFlagDisabled=%s)",
		self._Flag,
		self.FlaggingDisabled,
		self.GetFlagDisabled
	)
	return self
end

function Cooldown.SetVerbose(self: Cooldown, Value: boolean)
	self.Verbose = Value
	Log(self, "Verbose set to %s", Value)
end

function Cooldown.GetFlag(self: Cooldown, Type: "now" | "prev", Default: boolean?): boolean?
	if self._Destroyed then
		Warn(self, "GetFlag(%s) blocked: destroyed, returning default %s", Type, Default)
		return Default
	end
	if self.GetFlagDisabled then
		Warn(self, "GetFlag(%s) blocked: getting disabled, returning default %s", Type, Default)
		return Default
	end

	local Result: boolean? = nil
	if Type == "now" then
		Result = self._Flag
	elseif Type == "prev" then
		Result = self._FlagPrev
	end

	Log(self, "GetFlag(%s) -> %s", Type, Result)
	return Result
end

function Cooldown.ListenSignal(
	self: Cooldown,
	Callback: (Value: boolean, Previous: boolean) -> ()
): typeof(Signal.new():Connect(function() end))?
	if self._Destroyed then
		Warn(self, "ListenSignal blocked: destroyed")
		return nil
	end
	Log(self, "Listener connected")
	return self.Signal:Connect(Callback)
end

function Cooldown.ListenSignalOnce(
	self: Cooldown,
	Callback: (Value: boolean, Previous: boolean) -> ()
): typeof(Signal.new():Connect(function() end))?
	if self._Destroyed then
		Warn(self, "ListenSignalOnce blocked: destroyed")
		return nil
	end
	Log(self, "One-shot listener connected")

	local Connection: typeof(Signal.new():Connect(function() end))
	Connection = self.Signal:Connect(function(Value: boolean, Previous: boolean)
		Connection:Disconnect()
		Log(self, "One-shot listener fired and disconnected")
		Callback(Value, Previous)
	end)
	return Connection
end

function Cooldown.SetFlag(self: Cooldown, Value: boolean, RevertDelay: number?): boolean
	if self._Destroyed then
		Warn(self, "SetFlag(%s, %s) blocked: destroyed", Value, RevertDelay)
		return false
	end
	if self.FlaggingDisabled then
		Warn(self, "SetFlag(%s, %s) blocked: flagging disabled", Value, RevertDelay)
		return false
	end

	local Refreshing = self._Flag == Value
	if Refreshing and not (RevertDelay and self._RevertThread) then
		Log(
			self,
			"SetFlag(%s, %s) ignored: already %s with no pending revert to refresh",
			Value,
			RevertDelay,
			self._Flag
		)
		return false
	end

	if not Refreshing then
		self._RevertTo = self._Flag
		self._FlagPrev = self._Flag
		self._Flag = Value
		Log(self, "Flag changed %s -> %s", self._FlagPrev, self._Flag)
	else
		Log(self, "Refreshing pending revert, flag stays %s", self._Flag)
	end

	if self._RevertThread then
		Log(self, "Cancelled previous revert timer")
	end
	CancelThread(self._RevertThread)
	self._RevertThread = nil

	if RevertDelay then
		local RevertTo = self._RevertTo
		Log(self, "Revert to %s scheduled in %ss", RevertTo, RevertDelay)
		self._RevertThread = task.delay(RevertDelay, function()
			self._RevertThread = nil
			self._FlagPrev = self._Flag
			self._Flag = RevertTo
			Log(self, "Revert fired %s -> %s", self._FlagPrev, self._Flag)
			self.Signal:Fire(self._Flag, self._FlagPrev)
		end)
	end

	if not Refreshing then
		Log(self, "Firing signal (%s, %s)", self._Flag, self._FlagPrev)
		self.Signal:Fire(self._Flag, self._FlagPrev)
	end

	return true
end

function Cooldown.DisableFlagging(self: Cooldown, RevertDelay: number?): boolean
	if self._Destroyed then
		Warn(self, "DisableFlagging blocked: destroyed")
		return false
	end
	if self.FlaggingDisabled and not (RevertDelay and self._FlaggingThread) then
		Log(self, "DisableFlagging(%s) ignored: already disabled with no pending timer to refresh", RevertDelay)
		return false
	end

	self.FlaggingDisabled = true
	if self._FlaggingThread then
		Log(self, "Cancelled previous flagging timer")
	end
	CancelThread(self._FlaggingThread)
	self._FlaggingThread = nil
	Log(self, "Flagging disabled")

	if RevertDelay then
		Log(self, "Flagging re-enable scheduled in %ss", RevertDelay)
		self._FlaggingThread = task.delay(RevertDelay, function()
			self._FlaggingThread = nil
			self.FlaggingDisabled = false
			Log(self, "Flagging re-enabled by timer")
		end)
	end

	return true
end

function Cooldown.EnableFlagging(self: Cooldown): boolean
	if self._Destroyed then
		Warn(self, "EnableFlagging blocked: destroyed")
		return false
	end
	if not self.FlaggingDisabled then
		Log(self, "EnableFlagging ignored: already enabled")
		return false
	end
	if self._FlaggingThread then
		Log(self, "Cancelled pending flagging timer")
	end
	CancelThread(self._FlaggingThread)
	self._FlaggingThread = nil
	self.FlaggingDisabled = false
	Log(self, "Flagging enabled")
	return true
end

function Cooldown.DisableGettingFlag(self: Cooldown, RevertDelay: number?): boolean
	if self._Destroyed then
		Warn(self, "DisableGettingFlag blocked: destroyed")
		return false
	end
	if self.GetFlagDisabled and not (RevertDelay and self._GetFlagThread) then
		Log(self, "DisableGettingFlag(%s) ignored: already disabled with no pending timer to refresh", RevertDelay)
		return false
	end

	self.GetFlagDisabled = true
	if self._GetFlagThread then
		Log(self, "Cancelled previous get-flag timer")
	end
	CancelThread(self._GetFlagThread)
	self._GetFlagThread = nil
	Log(self, "Getting flag disabled")

	if RevertDelay then
		Log(self, "Getting flag re-enable scheduled in %ss", RevertDelay)
		self._GetFlagThread = task.delay(RevertDelay, function()
			self._GetFlagThread = nil
			self.GetFlagDisabled = false
			Log(self, "Getting flag re-enabled by timer")
		end)
	end

	return true
end

function Cooldown.EnableGettingFlag(self: Cooldown): boolean
	if self._Destroyed then
		Warn(self, "EnableGettingFlag blocked: destroyed")
		return false
	end
	if not self.GetFlagDisabled then
		Log(self, "EnableGettingFlag ignored: already enabled")
		return false
	end
	if self._GetFlagThread then
		Log(self, "Cancelled pending get-flag timer")
	end
	CancelThread(self._GetFlagThread)
	self._GetFlagThread = nil
	self.GetFlagDisabled = false
	Log(self, "Getting flag enabled")
	return true
end

function Cooldown.Destroy(self: Cooldown)
	if self._Destroyed then
		Warn(self, "Destroy ignored: already destroyed")
		return
	end
	self._Destroyed = true
	Log(self, "Destroying")

	CancelThread(self._RevertThread)
	CancelThread(self._FlaggingThread)
	CancelThread(self._GetFlagThread)
	self._RevertThread = nil
	self._FlaggingThread = nil
	self._GetFlagThread = nil
	Log(self, "All timers cancelled")

	self._Flag = false
	self._FlagPrev = false
	self._RevertTo = false

	self.Signal:DisconnectAll()
	Log(self, "Signal listeners disconnected, destroyed")
end

return Cooldown
