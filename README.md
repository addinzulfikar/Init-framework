# Init Framework

A lightweight Roblox (Luau) framework providing the **Service** (server) and **Controller** (client) patterns with lifecycle hooks.

## Features

- **Lifecycle Hooks**: `InitInit` → `InitStart` → `InitDestroy` for both services and controllers
- **Player Lifecycle Hooks** (server): `OnPlayerAdded` / `OnPlayerRemoving` for handling player connections and unexpected disconnections
- **Dependency Ordering**: Topological sort ensures services/controllers initialize in the correct order
- **Graceful Shutdown**: `InitDestroy` runs on server via `game:BindToClose` and on client via `Players.PlayerRemoving`
- **Configurable Logging**: Log levels (NONE, ERROR, WARN, INFO, DEBUG) via `SetConfig`
- **Middleware System**: Register middleware functions that run before each lifecycle phase
- **StrictMode**: Configurable error handling for `GetService`/`GetController`
- **ByteNet Integration**: Built-in support for [ByteNet / ByteNetMax](https://github.com/) networking — access via `Init.ByteNet` or convenience wrappers

## Usage

### Server (Service Pattern)

```lua
local Init = require(path.to.Init)

local MyService = Init.CreateService({
    Name = "MyService",
    Dependencies = { "DataService" },
})

function MyService:InitInit()
    -- Called first, in dependency order
end

function MyService:InitStart()
    -- Called after all services have initialized
end

function MyService:OnPlayerAdded(player)
    -- Called when a player joins the game
    print(player.Name .. " joined!")
end

function MyService:OnPlayerRemoving(player)
    -- Called when a player leaves (including unexpected disconnections)
    -- Use this to save player data, clean up resources, etc.
    print(player.Name .. " left!")
end

function MyService:InitDestroy()
    -- Called during graceful shutdown (game:BindToClose)
end

Init.Start()
```

### Client (Controller Pattern)

```lua
local Init = require(path.to.Init)

local MyController = Init.CreateController({
    Name = "MyController",
})

function MyController:InitInit()
    -- Called first, in dependency order
end

function MyController:InitStart()
    -- Called after all controllers have initialized
end

function MyController:InitDestroy()
    -- Called during client shutdown/disconnection (Players.PlayerRemoving)
    -- Use this to clean up resources on disconnection
end

Init.Start()
```

### Configuration

```lua
Init.SetConfig({
    LogLevel = 4,        -- DEBUG level (0=NONE, 1=ERROR, 2=WARN, 3=INFO, 4=DEBUG)
    InitTimeout = 30,    -- Timeout for InitInit in seconds
    OnStartTimeout = 60, -- Timeout for OnStart promise
    StrictMode = true,   -- Error on missing service/controller (vs warn+nil)
})
```

### Middleware

```lua
Init.AddMiddleware(function(item, phase)
    print(item.Name .. " is entering phase: " .. phase)
end)
```

Middleware phases: `InitInit`, `InitStart`, `InitDestroy`, `OnPlayerAdded`, `OnPlayerRemoving`

### ByteNet Integration

Init includes built-in support for [ByteNet / ByteNetMax](https://github.com/) networking. Place a `ByteNet` or `ByteNetMax` ModuleScript in your **Packages** folder (the same folder that contains `Promise`), and Init will automatically detect and expose it.

#### Accessing ByteNet through Init

```lua
local Init = require(path.to.Init)
local ByteNet = Init.ByteNet -- full ByteNet module reference (nil if not installed)
```

#### Convenience Wrappers

Init exposes wrapper methods so you can define namespaces, packets, and queries directly through Init:

```lua
local Init = require(path.to.Init)

-- These are equivalent to ByteNet.defineNamespace / definePacket / defineQuery
local MyNamespace = Init.DefineNamespace("MyNamespace", function()
    return {
        packets = {
            MyPacket = Init.DefinePacket({
                value = Init.ByteNet.struct({
                    message = Init.ByteNet.string,
                })
            }),
        },
        queries = {
            GetData = Init.DefineQuery({
                request = Init.ByteNet.struct({}),
                response = Init.ByteNet.struct({
                    coins = Init.ByteNet.uint32,
                })
            }),
        },
    }
end)
```

#### Full Example (ByteNetPackets module)

You can create a shared `ByteNetPackets` ModuleScript that defines all your networking:

```lua
-- ReplicatedStorage/Packages/ByteNetPackets.lua
local Init = require(path.to.Init)
local ByteNet = Init.ByteNet

local module = {}

module.DailyLogin = Init.DefineNamespace("DailyLogin", function()
    return {
        packets = {},
        queries = {
            GetDailyLoginData = ByteNet.defineQuery({
                request = ByteNet.struct({}),
                response = ByteNet.struct({
                    CurrentDay = ByteNet.uint8,
                    ConsecutiveDays = ByteNet.uint8,
                    ClaimedToday = ByteNet.bool,
                    CanClaim = ByteNet.bool,
                    RewardsJSON = ByteNet.string,
                })
            }),
        }
    }
end)

module.Combat = Init.DefineNamespace("Combat", function()
    return {
        packets = {
            RequestAttack = ByteNet.definePacket({
                value = ByteNet.struct({
                    IsNPC = ByteNet.bool,
                    TargetUserId = ByteNet.uint32,
                    TargetName = ByteNet.string,
                    ClientRange = ByteNet.int32,
                })
            }),
        },
        queries = {
            GetCombatStats = ByteNet.defineQuery({
                request = ByteNet.struct({}),
                response = ByteNet.struct({
                    Damage = ByteNet.uint16,
                    CritChance = ByteNet.uint8,
                    CritMultiplier = ByteNet.uint8,
                    AttackSpeed = ByteNet.uint8,
                })
            }),
        }
    }
end)

return module
```

#### Server-side usage (listening for queries)

```lua
local ByteNetPackets = require(path.to.ByteNetPackets)

ByteNetPackets.DailyLogin.queries.GetDailyLoginData.listen(function(data, player)
    return {
        CurrentDay = 1,
        ConsecutiveDays = 5,
        ClaimedToday = false,
        CanClaim = true,
        RewardsJSON = "{}",
    }
end)
```

#### Client-side usage (invoking queries)

```lua
local ByteNetPackets = require(path.to.ByteNetPackets)

local loginData = ByteNetPackets.DailyLogin.queries.GetDailyLoginData.invoke({})
print(loginData.CurrentDay)
```

> **Note:** ByteNet is optional. If no `ByteNet` or `ByteNetMax` module is found in the Packages folder, `Init.ByteNet` will be `nil` and the convenience wrappers (`DefineNamespace`, `DefinePacket`, `DefineQuery`) will error when called.

## Handling Unexpected Disconnections

The framework provides built-in support for handling player disconnections:

1. **Server-side**: Define `OnPlayerRemoving(player)` on any service to handle when a player disconnects (whether gracefully or unexpectedly). The framework automatically binds to `Players.PlayerRemoving` and calls this hook on all services that define it, with full error handling via `pcall`.

2. **Client-side**: Define `InitDestroy()` on any controller to handle cleanup when the client shuts down or disconnects. The framework listens for `Players.PlayerRemoving` to trigger this cleanup when the local player leaves.

3. **Graceful Shutdown**: On server shutdown, the framework first disconnects player lifecycle connections, then runs `InitDestroy` on all services with a 25-second timeout per service.