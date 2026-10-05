--!strict

local FreeRunnerThread: thread? = nil

type Handler = (...any) -> ()

local function AquireRunnerThread_andCallEventHandler(fn: Handler, ...: any)
	local AquiredFreeRunnerThread = FreeRunnerThread
	FreeRunnerThread = nil
	fn(...)
	FreeRunnerThread = AquiredFreeRunnerThread
end

local function RunEventHandler_InFreeThread(...: any)
	AquireRunnerThread_andCallEventHandler(...)
	while true do
		AquireRunnerThread_andCallEventHandler(coroutine.yield())
	end
end

local Connection = {}
Connection.__index = Connection

export type Connection = typeof(setmetatable(
	{} :: {
		_connected: boolean,
		_fn: Handler,
		_signal: Signal,
	},
	Connection
))

function Connection.new(signal: Signal, fn: Handler): Connection
	return setmetatable({
		_connected = true,
		_fn = fn,
		_signal = signal,
	}, Connection)
end

function Connection.Disconnect(self: Connection)
	self._connected = false
	local connections = self._signal._Connections

	for i, connection in ipairs(connections) do
		if connection == self then
			table.remove(connections, i)
			break
		end
	end
end

local Signal = {}
Signal.__index = Signal

export type Signal = typeof(setmetatable(
	{} :: {
		_Connections: { Connection },
	},
	Signal
))

function Signal.new(): Signal
	local self = setmetatable({
		_Connections = {},
	}, Signal)
	return self
end

function Signal.Fire(self: Signal, ...)
	local _ConnectionsCopy = table.clone(self._Connections)
	for _, connection: Connection in ipairs(_ConnectionsCopy) do
		if connection._connected then
			if not FreeRunnerThread then
				FreeRunnerThread = coroutine.create(RunEventHandler_InFreeThread)
			end
			task.spawn(FreeRunnerThread :: thread, connection._fn, ...)
		end
	end
end

function Signal.Connect(self: Signal, fn: Handler): Connection
	local connection = Connection.new(self, fn)
	table.insert(self._Connections, connection)
	return connection
end

function Signal.Wait(self: Signal)
	local thread = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		Connection.Disconnect(assert(connection, "Signal connection was not initialized"))
		task.spawn(thread, ...)
	end)

	return coroutine.yield()
end

function Signal.DisconnectAll(self: Signal)
	if self._Connections then
		for _, connection in ipairs(self._Connections :: { Connection }) do
			connection._connected = false
		end
		table.clear(self._Connections)
	end
end

function Signal.Destroy(self: Signal)
	self:DisconnectAll()
end

return Signal
