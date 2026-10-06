--!strict

local Signal = require(script.Signal)

local Flag = {}
Flag.__index = Flag

export type Flag = typeof(setmetatable(
	{} :: {
		_Identifier: string,
		_Flag: boolean,
		_FlagPrev: boolean,
		_RevertTo: boolean,
		_Destroyed: boolean,
		_RevertThread: thread?,
		_FlaggingThread: thread?,
		_GetFlagThread: thread?,
		_RevertAt: number?,
		_FlaggingAt: number?,
		_GetFlagAt: number?,

		Verbose: boolean?,
		Compounding: boolean?,
		FlaggingDisabled: boolean,
		GetFlagDisabled: boolean,
		Signal: typeof(Signal.new()),
	},
	Flag
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

local function Log(self: Flag, Message: string, ...: any)
	if self.Verbose then
		print(Format("[Flag:%s] " .. Message, self._Identifier, ...))
	end
end

local function Warn(self: Flag, Message: string, ...: any)
	if self.Verbose then
		warn(Format("[Flag:%s] " .. Message, self._Identifier, ...))
	end
end

function Flag.new(
	Identifier: string,
	InitialFlagValue: boolean?,
	FlaggingDisabled: boolean?,
	GetFlagDisabled: boolean?,
	Verbose: boolean?,
	Compounding: boolean?
): Flag
	assert(type(Identifier) == "string", "Flag.new: Identifier must be a string")

	local Initial = InitialFlagValue or false
	local self = setmetatable({
		_Identifier = Identifier,
		_Flag = Initial,
		_FlagPrev = Initial,
		_RevertTo = Initial,
		_Destroyed = false,
		_RevertThread = nil,
		_FlaggingThread = nil,
		_GetFlagThread = nil,
		_RevertAt = nil,
		_FlaggingAt = nil,
		_GetFlagAt = nil,
		Verbose = Verbose or false,
		Compounding = Compounding or false,
		FlaggingDisabled = FlaggingDisabled or false,
		GetFlagDisabled = GetFlagDisabled or false,
		Signal = Signal.new(),
	}, Flag) :: Flag

	Log(
		self,
		"Created (flag=%s, flaggingDisabled=%s, getFlagDisabled=%s)",
		self._Flag,
		self.FlaggingDisabled,
		self.GetFlagDisabled
	)
	return self
end

function Flag.SetVerbose(self: Flag, Value: boolean)
	self.Verbose = Value
	Log(self, "Verbose set to %s", Value)
end

function Flag.Get(self: Flag, Type: "now" | "prev", Default: boolean?): boolean?
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

function Flag.GetRemaining(self: Flag): number
	return self._RevertAt and math.max(0, self._RevertAt - os.clock()) or 0
end

function Flag.ListenSignal(
	self: Flag,
	Callback: (Value: boolean, Previous: boolean) -> ()
): typeof(Signal.new():Connect(function() end))?
	if self._Destroyed then
		Warn(self, "ListenSignal blocked: destroyed")
		return nil
	end
	Log(self, "Listener connected")
	return self.Signal:Connect(Callback)
end

function Flag.ListenSignalOnce(
	self: Flag,
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

function Flag.Set(self: Flag, Value: boolean, RevertDelay: number?, MaxDelay: number?): boolean
	assert(RevertDelay == nil or (RevertDelay == RevertDelay and RevertDelay >= 0), "bad RevertDelay")
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

	local Deadline = RevertDelay and (os.clock() + RevertDelay)
	if self.Compounding and Refreshing and RevertDelay and self._RevertAt then
		Deadline = self._RevertAt + RevertDelay
		if MaxDelay then
			Deadline = math.max(self._RevertAt, math.min(Deadline, os.clock() + MaxDelay))
		end
		RevertDelay = math.max(0, Deadline - os.clock())
	end
	if Refreshing and Deadline and self._RevertAt and Deadline < self._RevertAt then
		return false
	end

	if not Refreshing then
		if not self._RevertThread then
			self._RevertTo = self._Flag
		end

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
	self._RevertAt = nil

	if RevertDelay then
		local RevertTo = self._RevertTo
		self._RevertAt = Deadline
		Log(self, "Revert to %s scheduled in %ss", RevertTo, RevertDelay)
		self._RevertThread = task.delay(RevertDelay, function()
			self._RevertThread = nil
			self._RevertAt = nil
			if self._Flag == RevertTo then
				Log(self, "Revert skipped, already %s", RevertTo)
				return
			end
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

function Flag.DisableFlagging(self: Flag, RevertDelay: number?, MaxDelay: number?): boolean
	if self._Destroyed then
		Warn(self, "DisableFlagging blocked: destroyed")
		return false
	end
	if self.FlaggingDisabled and not self._FlaggingThread then
		Log(self, "DisableFlagging ignored: already permanently disabled")
		return false
	end

	local Deadline = RevertDelay and (os.clock() + RevertDelay)
	local Pending = self._FlaggingAt
	if RevertDelay and Pending then
		if self.Compounding then
			Deadline = Pending + RevertDelay
			if MaxDelay then
				Deadline = math.max(Pending, math.min(Deadline, os.clock() + MaxDelay))
			end
			RevertDelay = math.max(0, Deadline - os.clock())
		elseif Deadline and Deadline < Pending then
			return false
		end
	end
	self.FlaggingDisabled = true
	if self._FlaggingThread then
		Log(self, "Cancelled previous flagging timer")
	end
	CancelThread(self._FlaggingThread)
	self._FlaggingThread = nil
	self._FlaggingAt = nil
	Log(self, "Flagging disabled")

	if RevertDelay then
		self._FlaggingAt = Deadline
		Log(self, "Flagging re-enable scheduled in %ss", RevertDelay)
		self._FlaggingThread = task.delay(RevertDelay, function()
			self._FlaggingThread = nil
			self._FlaggingAt = nil
			self.FlaggingDisabled = false
			Log(self, "Flagging re-enabled by timer")
		end)
	end

	return true
end

function Flag.EnableFlagging(self: Flag): boolean
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
	self._FlaggingAt = nil
	self.FlaggingDisabled = false
	Log(self, "Flagging enabled")
	return true
end

function Flag.DisableGettingFlag(self: Flag, RevertDelay: number?, MaxDelay: number?): boolean
	if self._Destroyed then
		Warn(self, "DisableGettingFlag blocked: destroyed")
		return false
	end
	if self.GetFlagDisabled and not self._GetFlagThread then
		Log(self, "DisableGettingFlag ignored: already permanently disabled")
		return false
	end

	local Deadline = RevertDelay and (os.clock() + RevertDelay)
	local Pending = self._GetFlagAt
	if RevertDelay and Pending then
		if self.Compounding then
			Deadline = Pending + RevertDelay
			if MaxDelay then
				Deadline = math.max(Pending, math.min(Deadline, os.clock() + MaxDelay))
			end
			RevertDelay = math.max(0, Deadline - os.clock())
		elseif Deadline and Deadline < Pending then
			return false
		end
	end

	self.GetFlagDisabled = true
	if self._GetFlagThread then
		Log(self, "Cancelled previous get-flag timer")
	end
	CancelThread(self._GetFlagThread)
	self._GetFlagThread = nil
	self._GetFlagAt = nil
	Log(self, "Getting flag disabled")

	if RevertDelay then
		self._GetFlagAt = Deadline
		Log(self, "Getting flag re-enable scheduled in %ss", RevertDelay)
		self._GetFlagThread = task.delay(RevertDelay, function()
			self._GetFlagThread = nil
			self._GetFlagAt = nil
			self.GetFlagDisabled = false
			Log(self, "Getting flag re-enabled by timer")
		end)
	end

	return true
end

function Flag.EnableGettingFlag(self: Flag): boolean
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
	self._GetFlagAt = nil
	self.GetFlagDisabled = false
	Log(self, "Getting flag enabled")
	return true
end

function Flag.Destroy(self: Flag)
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
	self._RevertAt = nil
	self._FlaggingAt = nil
	self._GetFlagAt = nil
	Log(self, "All timers cancelled")

	self._Flag = false
	self._FlagPrev = false
	self._RevertTo = false

	self.Signal:DisconnectAll()
	Log(self, "Signal listeners disconnected, destroyed")
end

return Flag
