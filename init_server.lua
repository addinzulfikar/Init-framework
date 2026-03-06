--[=[
	@class InitServer
	Server-side framework module providing the Service pattern with lifecycle hooks
	(`InitInit` → `InitStart` → `InitDestroy`).

	Features:
	- Configurable logging system with log levels
	- Dependency ordering via topological sort
	- Graceful shutdown via `InitDestroy` lifecycle hook
	- Player lifecycle hooks (`OnPlayerAdded` / `OnPlayerRemoving`) for handling unexpected disconnections
	- Middleware system for lifecycle phases
	- StrictMode for GetService error handling
]=]

-- Log level constants
local LOG_LEVEL = {
	NONE = 0,
	ERROR = 1,
	WARN = 2,
	INFO = 3,
	DEBUG = 4,
}

--[=[
	@type ServiceDef { Name: string, Dependencies: {string}?, [any]: any }
	@within InitServer
]=]
type ServiceDef = {
	Name: string,
	Dependencies: { string }?,
	[any]: any,
}

--[=[
	@type Service { Name: string, Dependencies: {string}?, [any]: any }
	@within InitServer
]=]
type Service = {
	Name: string,
	Dependencies: { string }?,
	[any]: any,
}

--[=[
	@type Config { LogLevel: number, InitTimeout: number, OnStartTimeout: number, StrictMode: boolean }
	@within InitServer
]=]
type Config = {
	LogLevel: number,
	InitTimeout: number,
	OnStartTimeout: number,
	StrictMode: boolean,
}

--[=[
	@type MiddlewareFn (item: Service, phase: string) -> ()
	@within InitServer
]=]
type MiddlewareFn = (item: Service, phase: string) -> ()

local InitServer = {}

--[=[
	@prop Util Instance
	@within InitServer
	Reference to the parent of the Init package (for accessing shared utilities like Promise).
]=]
InitServer.Util = (script.Parent :: Instance).Parent

local Players = game:GetService("Players")
local Promise = require(InitServer.Util.Promise)

local services: { [string]: Service } = {}
local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

local middlewares: { MiddlewareFn } = {}

local playerConnections: { RBXScriptConnection } = {}

local config: Config = {
	LogLevel = LOG_LEVEL.WARN,
	InitTimeout = 30,
	OnStartTimeout = 60,
	StrictMode = true,
}

-- Internal logging function
local function log(level: number, message: string)
	if level <= config.LogLevel then
		if level == LOG_LEVEL.ERROR then
			warn(`[Init][ERROR] {message}`)
		elseif level == LOG_LEVEL.WARN then
			warn(`[Init][WARN] {message}`)
		elseif level == LOG_LEVEL.INFO then
			print(`[Init][INFO] {message}`)
		elseif level == LOG_LEVEL.DEBUG then
			print(`[Init][DEBUG] {message}`)
		end
	end
end

-- Run all registered middlewares for an item and phase
local function runMiddlewares(item: Service, phase: string)
	for _, middleware in middlewares do
		local success, err = pcall(middleware, item, phase)
		if not success then
			log(LOG_LEVEL.WARN, `Middleware error during phase "{phase}" for "{item.Name}": {err}`)
		end
	end
end

-- Topological sort for dependency ordering
local function topologicalSort(serviceMap: { [string]: Service }): { Service }
	local sorted: { Service } = {}
	local visited: { [string]: boolean } = {}
	local visiting: { [string]: boolean } = {}

	local function visit(name: string)
		if visited[name] then
			return
		end
		if visiting[name] then
			log(LOG_LEVEL.WARN, `Circular dependency detected involving service "{name}"`)
			return
		end

		visiting[name] = true

		local service = serviceMap[name]
		if service and service.Dependencies then
			for _, depName in service.Dependencies do
				if not serviceMap[depName] then
					log(LOG_LEVEL.WARN, `Service "{name}" depends on "{depName}" which does not exist`)
				else
					visit(depName)
				end
			end
		end

		visiting[name] = nil
		visited[name] = true
		if service then
			table.insert(sorted, service)
		end
	end

	for name in serviceMap do
		visit(name)
	end

	return sorted
end

local function DoesServiceExist(serviceName: string): boolean
	local service: Service? = services[serviceName]
	return service ~= nil
end

--[=[
	@function SetConfig
	@within InitServer
	@param newConfig Config -- Partial config table to merge with defaults
	Sets configuration options. Must be called before `Start()`.
]=]
function InitServer.SetConfig(newConfig: { [string]: any })
	assert(not started, `Config cannot be changed after calling "Init.Start()"`)
	for key, value in newConfig do
		config[key] = value
	end
end

--[=[
	@function AddMiddleware
	@within InitServer
	@param fn MiddlewareFn -- Middleware function `(item, phase) -> ()`
	Registers a middleware function. Must be called before `Start()`.
	Middlewares are called before each lifecycle phase (`InitInit`, `InitStart`, `InitDestroy`, `OnPlayerAdded`, `OnPlayerRemoving`).
]=]
function InitServer.AddMiddleware(fn: MiddlewareFn)
	assert(not started, `Middlewares cannot be added after calling "Init.Start()"`)
	assert(type(fn) == "function", `Middleware must be a function; got {type(fn)}`)
	table.insert(middlewares, fn)
end

--[=[
	@function CreateService
	@within InitServer
	@param serviceDef ServiceDef
	@return Service
	Creates and registers a new service. Must be called before `Start()`.
]=]
function InitServer.CreateService(serviceDef: ServiceDef): Service
	assert(type(serviceDef) == "table", `Service must be a table; got {type(serviceDef)}`)
	assert(type(serviceDef.Name) == "string", `Service.Name must be a string; got {type(serviceDef.Name)}`)
	assert(#serviceDef.Name > 0, "Service.Name must be a non-empty string")
	assert(not DoesServiceExist(serviceDef.Name), `Service "{serviceDef.Name}" already exists`)
	assert(not started, `Services cannot be created after calling "Init.Start()"`)

	local service = serviceDef :: Service
	services[service.Name] = service

	log(LOG_LEVEL.DEBUG, `Created service "{service.Name}"`)

	return service
end

--[=[
	@function AddServices
	@within InitServer
	@param parent Instance -- Parent instance containing ModuleScript children
	@return {Service}
	Requires all ModuleScript children of the given parent. Must be called before `Start()`.
]=]
function InitServer.AddServices(parent: Instance): { Service }
	assert(not started, `Services cannot be added after calling "Init.Start()"`)

	local addedServices = {}
	for _, v in parent:GetChildren() do
		if not v:IsA("ModuleScript") then
			continue
		end

		table.insert(addedServices, require(v))
	end

	return addedServices
end

--[=[
	@function AddServicesDeep
	@within InitServer
	@param parent Instance -- Parent instance to search recursively
	@return {Service}
	Requires all ModuleScript descendants of the given parent. Must be called before `Start()`.
]=]
function InitServer.AddServicesDeep(parent: Instance): { Service }
	assert(not started, `Services cannot be added after calling "Init.Start()"`)

	local addedServices = {}
	for _, v in parent:GetDescendants() do
		if not v:IsA("ModuleScript") then
			continue
		end

		table.insert(addedServices, require(v))
	end

	return addedServices
end

--[=[
	@function GetService
	@within InitServer
	@param serviceName string
	@return Service
	Returns the service with the given name. Must be called after `Start()`.
	In StrictMode (default), throws an error if the service is not found.
	In non-strict mode, warns and returns nil.
]=]
function InitServer.GetService(serviceName: string): Service
	if config.StrictMode then
		assert(started, "Cannot call GetService until Init has been started")
		assert(type(serviceName) == "string", `ServiceName must be a string; got {type(serviceName)}`)
		return assert(services[serviceName], `Could not find service "{serviceName}"`) :: Service
	else
		if not started then
			warn("[Init] Cannot call GetService until Init has been started")
			return nil
		end
		if type(serviceName) ~= "string" then
			warn(`[Init] ServiceName must be a string; got {type(serviceName)}`)
			return nil
		end
		local service = services[serviceName]
		if not service then
			warn(`[Init] Could not find service "{serviceName}". Check to verify a service with this name exists.`)
			return nil
		end
		return service
	end
end

--[=[
	@function GetServices
	@within InitServer
	@return {[string]: Service}
	Returns all registered services. Must be called after `Start()`.
]=]
function InitServer.GetServices(): { [string]: Service }
	assert(started, "Cannot call GetServices until Init has been started")

	return services
end

--[=[
	@function Start
	@within InitServer
	@return Promise
	Starts the framework. Runs `InitInit` on all services in dependency order,
	then spawns `InitStart` for each. Binds graceful shutdown via `game:BindToClose`.
]=]
function InitServer.Start()
	if started then
		return Promise.reject("Init already started")
	end

	started = true

	table.freeze(services)

	log(LOG_LEVEL.INFO, "Starting Init framework (server)...")

	-- Determine initialization order using topological sort
	local sortedServices = topologicalSort(services)

	return Promise.new(function(resolve)
		-- Run InitInit sequentially according to dependency order using promise chaining
		local chain = Promise.resolve()

		for _, service in sortedServices do
			if type(service.InitInit) == "function" then
				chain = chain:andThen(function()
					return Promise.new(function(r, reject)
						debug.setmemorycategory(service.Name)
						log(LOG_LEVEL.INFO, `Initializing "{service.Name}"...`)

						runMiddlewares(service, "InitInit")

						local success, err = pcall(function()
							service:InitInit()
						end)

						if success then
							log(LOG_LEVEL.DEBUG, `"{service.Name}" initialized successfully`)
							r()
						else
							log(LOG_LEVEL.ERROR, `Service "{service.Name}":InitInit() failed: {err}`)
							reject(err)
						end
					end):timeout(config.InitTimeout, `Service "{service.Name}":InitInit() timed out after {config.InitTimeout}s`)
				end)
			end
		end

		resolve(
			chain:catch(function(err)
				log(LOG_LEVEL.ERROR, `A service failed during InitInit: {err}`)
			end)
		)
	end):andThen(function()
		log(LOG_LEVEL.INFO, "All services initialized. Starting services...")

		for _, service in sortedServices do
			if type(service.InitStart) == "function" then
				task.spawn(function()
					debug.setmemorycategory(service.Name)
					log(LOG_LEVEL.INFO, `Starting "{service.Name}"...`)

					runMiddlewares(service, "InitStart")

					local success, err = pcall(function()
						service:InitStart()
					end)
					if not success then
						log(LOG_LEVEL.ERROR, `Service "{service.Name}":InitStart() failed: {err}`)
					end
				end)
			end
		end

		startedComplete = true
		onStartedComplete:Fire()

		task.defer(function()
			onStartedComplete:Destroy()
		end)

		log(LOG_LEVEL.INFO, "Init started successfully")

		-- Bind player lifecycle hooks for handling connections/disconnections
		local function onPlayerAdded(player: Player)
			for _, service in sortedServices do
				if type(service.OnPlayerAdded) == "function" then
					task.spawn(function()
						debug.setmemorycategory(service.Name)
						log(LOG_LEVEL.DEBUG, `Running OnPlayerAdded for "{service.Name}" (player: {player.Name})`)

						runMiddlewares(service, "OnPlayerAdded")

						local success, err = pcall(function()
							service:OnPlayerAdded(player)
						end)
						if not success then
							log(LOG_LEVEL.ERROR, `Service "{service.Name}":OnPlayerAdded() failed for player "{player.Name}": {err}`)
						end
					end)
				end
			end
		end

		local function onPlayerRemoving(player: Player)
			for _, service in sortedServices do
				if type(service.OnPlayerRemoving) == "function" then
					task.spawn(function()
						debug.setmemorycategory(service.Name)
						log(LOG_LEVEL.DEBUG, `Running OnPlayerRemoving for "{service.Name}" (player: {player.Name})`)

						runMiddlewares(service, "OnPlayerRemoving")

						local success, err = pcall(function()
							service:OnPlayerRemoving(player)
						end)
						if not success then
							log(LOG_LEVEL.ERROR, `Service "{service.Name}":OnPlayerRemoving() failed for player "{player.Name}": {err}`)
						end
					end)
				end
			end
		end

		table.insert(playerConnections, Players.PlayerAdded:Connect(onPlayerAdded))
		table.insert(playerConnections, Players.PlayerRemoving:Connect(onPlayerRemoving))

		-- Handle players that joined before the framework started
		for _, player in Players:GetPlayers() do
			onPlayerAdded(player)
		end

		log(LOG_LEVEL.INFO, "Player lifecycle hooks bound")

		-- Bind graceful shutdown
		game:BindToClose(function()
			log(LOG_LEVEL.INFO, "Shutdown initiated. Cleaning up player connections...")

			-- Disconnect player lifecycle connections
			for _, connection in playerConnections do
				connection:Disconnect()
			end
			table.clear(playerConnections)

			log(LOG_LEVEL.INFO, "Running InitDestroy on all services...")

			local destroyPromises = {}

			for _, service in sortedServices do
				if type(service.InitDestroy) == "function" then
					table.insert(
						destroyPromises,
						Promise.new(function(r)
							debug.setmemorycategory(service.Name)
							log(LOG_LEVEL.INFO, `Destroying "{service.Name}"...`)

							runMiddlewares(service, "InitDestroy")

							local success, err = pcall(function()
								service:InitDestroy()
							end)

							if success then
								log(LOG_LEVEL.DEBUG, `"{service.Name}" destroyed successfully`)
							else
								log(LOG_LEVEL.ERROR, `Service "{service.Name}":InitDestroy() failed: {err}`)
							end

							r()
						end):timeout(25, `Service "{service.Name}":InitDestroy() timed out`)
					)
				end
			end

			Promise.allSettled(destroyPromises):await()

			log(LOG_LEVEL.INFO, "Shutdown complete")
		end)
	end)
end

--[=[
	@function OnStart
	@within InitServer
	@return Promise
	Returns a Promise that resolves when `Start()` has completed.
	If `Start()` has already completed, resolves immediately.
]=]
function InitServer.OnStart()
	if startedComplete then
		return Promise.resolve()
	else
		return Promise.fromEvent(onStartedComplete.Event)
			:timeout(config.OnStartTimeout, "Init.Start() was never called or failed to complete")
	end
end

return InitServer
