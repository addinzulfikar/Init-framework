# Init Framework

A lightweight Roblox (Luau) framework providing the **Service** (server) and **Controller** (client) patterns with lifecycle hooks.

## Features

- **Lifecycle Hooks**: `InitInit` → `InitStart` → `InitDestroy` for both services and controllers
- **Player Lifecycle Hooks** (server): `OnPlayerAdded` / `OnPlayerRemoving` for handling player connections and unexpected disconnections
- **Dependency Ordering**: Topological sort ensures services/controllers initialize in the correct order
- **Graceful Shutdown**: `InitDestroy` runs on both server and client via `game:BindToClose`
- **Configurable Logging**: Log levels (NONE, ERROR, WARN, INFO, DEBUG) via `SetConfig`
- **Middleware System**: Register middleware functions that run before each lifecycle phase
- **StrictMode**: Configurable error handling for `GetService`/`GetController`

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
    -- Called during client shutdown/disconnection (game:BindToClose)
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

## Handling Unexpected Disconnections

The framework provides built-in support for handling player disconnections:

1. **Server-side**: Define `OnPlayerRemoving(player)` on any service to handle when a player disconnects (whether gracefully or unexpectedly). The framework automatically binds to `Players.PlayerRemoving` and calls this hook on all services that define it, with full error handling via `pcall`.

2. **Client-side**: Define `InitDestroy()` on any controller to handle cleanup when the client shuts down or disconnects. The framework binds to `game:BindToClose` to trigger this cleanup.

3. **Graceful Shutdown**: On server shutdown, the framework first disconnects player lifecycle connections, then runs `InitDestroy` on all services with a 25-second timeout per service.