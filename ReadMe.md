# Cooldown

A small, typed Luau cooldown flag for Roblox. Tracks a boolean with automatic timed revert, a change signal, per-instance read/write locks, and optional verbose logging.

- Strict-typed (`--!strict`)
- Timed revert with refresh (re-triggering extends the cooldown)
- Change signal with `(Value, Previous)` payload
- Lock flag writes or reads, optionally on a timer
- Timers are tracked and cancelled, with no stale revert races
- Idempotent `Destroy` that cleans up threads and listeners
- Optional per-instance verbose logging

## Installation

Add to your `wally.toml`:

```toml
[dependencies]
Cooldown = "your-scope/cooldown@0.1.0"
```

Then run:

```
wally install
```

## Quick start

```lua
local Cooldown = require(Packages.Cooldown)

local Dash = Cooldown.new("Dash")

local function TryDash()
	if Dash:GetFlag("now") then
		return
	end
	Dash:SetFlag(true, 1.5)
	-- perform dash
end
```

`true` means the cooldown is active. With `SetFlag(true, 1.5)` the flag reverts to its previous value after 1.5 seconds.

## API

### `Cooldown.new`

```lua
Cooldown.new(
	Identifier: string,
	InitialFlagValue: boolean?,
	FlaggingDisabled: boolean?,
	GetFlagDisabled: boolean?,
	Verbose: boolean?
): Cooldown
```

| Parameter | Default | Description |
|---|---|---|
| `Identifier` | required | Name used in verbose logs. Must be a string. |
| `InitialFlagValue` | `false` | Starting flag value. Also the first revert target. |
| `FlaggingDisabled` | `false` | Start with `SetFlag` blocked. |
| `GetFlagDisabled` | `false` | Start with `GetFlag` blocked. |
| `Verbose` | `false` | Print and warn on every step. |

### Flag

#### `Cooldown:GetFlag(Type, Default?) -> boolean?`

| `Type` | Returns |
|---|---|
| `"now"` | Current value |
| `"prev"` | Value before the last change |

Returns `Default` (`nil` if omitted) when reading is disabled or the object is destroyed. Pass a default to tell "disabled" apart from `false`:

```lua
if Dash:GetFlag("now", true) then
	return
end
```

#### `Cooldown:SetFlag(Value, RevertDelay?) -> boolean`

Sets the flag and returns `true` if it did something.

- A changed value stores the old value as the revert target, updates `"prev"`, and fires the signal.
- With `RevertDelay`, the flag returns to the revert target after that many seconds, and the signal fires again.
- Calling again with the same value and a `RevertDelay` while a revert is pending refreshes the timer and keeps the original revert target. The signal does not fire.
- Returns `false` when flagging is disabled, the object is destroyed, or the value is unchanged with no pending revert to refresh.

```lua
Dash:SetFlag(true, 1.5)
Dash:SetFlag(true, 1.5)
```

The second call extends the cooldown.

### Signal

#### `Cooldown:ListenSignal(Callback) -> Connection?`

Runs `Callback(Value, Previous)` on every flag change, including timed reverts. Returns the connection, or `nil` if destroyed.

```lua
local Connection = Dash:ListenSignal(function(Value, Previous)
	print("Dash cooldown:", Previous, "->", Value)
end)

Connection:Disconnect()
```

#### `Cooldown:ListenSignalOnce(Callback) -> Connection?`

Same as `ListenSignal`, but disconnects after the first fire.

### Locks

| Method | Effect |
|---|---|
| `DisableFlagging(RevertDelay?)` | Blocks `SetFlag`. With a delay, unlocks automatically. |
| `EnableFlagging()` | Unlocks `SetFlag` and cancels any pending timer. |
| `DisableGettingFlag(RevertDelay?)` | Blocks `GetFlag` (returns `Default`). With a delay, unlocks automatically. |
| `EnableGettingFlag()` | Unlocks `GetFlag` and cancels any pending timer. |

All return `boolean` (`true` if state changed). Calling `Disable*` with a delay while a timer is pending refreshes it. Calling `Disable*` while already disabled with no pending timer returns `false`. Call `Enable*` first to switch to a timed lock.

### Lifecycle and debugging

#### `Cooldown:SetVerbose(Value: boolean)`

Toggles logging at runtime. Logs are prefixed `[Cooldown:<Identifier>]`. `print` is used for state changes and harmless no-ops, `warn` for blocked calls.

#### `Cooldown:Destroy()`

Cancels all timers, resets state, and disconnects all listeners. Safe to call more than once. After `Destroy`, every method is a no-op.

## Behavior notes

- State changes complete before the signal fires, so listeners can safely call back into the cooldown.
- Revert timers restore the value from when the cooldown started, not whatever `"prev"` is at fire time.
- Timed reverts are not blocked by `DisableFlagging`. Only manual `SetFlag` calls are.
- The `Signal` field is public, but prefer `ListenSignal` and `ListenSignalOnce`.
- Keep `Verbose` off in production.

## Types

```lua
local Cooldown = require(Packages.Cooldown)

local Dash: Cooldown.Cooldown = Cooldown.new("Dash")
```

## Example: server-authoritative ability

```lua
local Cooldown = require(Packages.Cooldown)

local Cooldowns: { [Player]: Cooldown.Cooldown } = {}

local function Use(Player: Player)
	local Cd = Cooldowns[Player]
	if not Cd then
		Cd = Cooldown.new("Ability_" .. Player.Name)
		Cooldowns[Player] = Cd
	end

	if Cd:GetFlag("now") then
		return false
	end

	Cd:SetFlag(true, 2)
	return true
end

game:GetService("Players").PlayerRemoving:Connect(function(Player)
	local Cd = Cooldowns[Player]
	if Cd then
		Cd:Destroy()
		Cooldowns[Player] = nil
	end
end)
```

## License

MIT