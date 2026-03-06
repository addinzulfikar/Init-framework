--[=[
	@class InitClient
	Client-side framework module providing the Controller pattern with lifecycle hooks
	(`InitInit` → `InitStart` → `InitDestroy`).

	Features:
	- Configurable logging system with log levels
	- Dependency ordering via topological sort
	- Graceful shutdown via `InitDestroy` lifecycle hook for handling disconnections
	- Middleware system for lifecycle phases
	- StrictMode for GetController error handling
	- Error handling parity with server (pcall, timeout, allSettled)
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
	@type ControllerDef { Name: string, Dependencies: {string}?, [any]: any }
	@within InitClient
]=]
type ControllerDef = {
	Name: string,
	Dependencies: { string }?,
	[any]: any,
}

--[=[
	@type Controller { Name: string, Dependencies: {string}?, [any]: any }
	@within InitClient
]=]
type Controller = {
	Name: string,
	Dependencies: { string }?,
	[any]: any,
}

--[=[
	@type Config { LogLevel: number, InitTimeout: number, OnStartTimeout: number, StrictMode: boolean }
	@within InitClient
]=]
type Config = {
	LogLevel: number,
	InitTimeout: number,
	OnStartTimeout: number,
	StrictMode: boolean,
}

--[=[
	@type MiddlewareFn (item: Controller, phase: string) -> ()
	@within InitClient
]=]
type MiddlewareFn = (item: Controller, phase: string) -> ()

local InitClient = {}

--[=[
	@prop Player Player
	@within InitClient
	Reference to the local player.
]=]
InitClient.Player = game:GetService("Players").LocalPlayer

--[=[
	@prop Util Instance
	@within InitClient
	Reference to the parent of the Init package (for accessing shared utilities like Promise).
]=]
InitClient.Util = (script.Parent :: Instance).Parent

local Promise = require(InitClient.Util.Promise)

local controllers: { [string]: Controller } = {}

local started = false
local startedComplete = false
local onStartedComplete = Instance.new("BindableEvent")

local middlewares: { MiddlewareFn } = {}

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
local function runMiddlewares(item: Controller, phase: string)
	for _, middleware in middlewares do
		local success, err = pcall(middleware, item, phase)
		if not success then
			log(LOG_LEVEL.WARN, `Middleware error during phase "{phase}" for "{item.Name}": {err}`)
		end
	end
end

-- Topological sort for dependency ordering
local function topologicalSort(controllerMap: { [string]: Controller }): { Controller }
	local sorted: { Controller } = {}
	local visited: { [string]: boolean } = {}
	local visiting: { [string]: boolean } = {}

	local function visit(name: string)
		if visited[name] then
			return
		end
		if visiting[name] then
			log(LOG_LEVEL.WARN, `Circular dependency detected involving controller "{name}"`)
			return
		end

		visiting[name] = true

		local controller = controllerMap[name]
		if controller and controller.Dependencies then
			for _, depName in controller.Dependencies do
				if not controllerMap[depName] then
					log(LOG_LEVEL.WARN, `Controller "{name}" depends on "{depName}" which does not exist`)
				else
					visit(depName)
				end
			end
		end

		visiting[name] = nil
		visited[name] = true
		if controller then
			table.insert(sorted, controller)
		end
	end

	for name in controllerMap do
		visit(name)
	end

	return sorted
end

local function DoesControllerExist(controllerName: string): boolean
	local controller: Controller? = controllers[controllerName]
	return controller ~= nil
end

--[=[
	@function SetConfig
	@within InitClient
	@param newConfig Config -- Partial config table to merge with defaults
	Sets configuration options. Must be called before `Start()`.
]=]
function InitClient.SetConfig(newConfig: { [string]: any })
	assert(not started, `Config cannot be changed after calling "Init.Start()"`)
	for key, value in newConfig do
		config[key] = value
	end
end

--[=[
	@function AddMiddleware
	@within InitClient
	@param fn MiddlewareFn -- Middleware function `(item, phase) -> ()`
	Registers a middleware function. Must be called before `Start()`.
	Middlewares are called before each lifecycle phase (`InitInit`, `InitStart`, `InitDestroy`).
]=]
function InitClient.AddMiddleware(fn: MiddlewareFn)
	assert(not started, `Middlewares cannot be added after calling "Init.Start()"`)
	assert(type(fn) == "function", `Middleware must be a function; got {type(fn)}`)
	table.insert(middlewares, fn)
end

--[=[
	@function CreateController
	@within InitClient
	@param controllerDef ControllerDef
	@return Controller
	Creates and registers a new controller. Must be called before `Start()`.
]=]
function InitClient.CreateController(controllerDef: ControllerDef): Controller
	assert(type(controllerDef) == "table", `Controller must be a table; got {type(controllerDef)}`)
	assert(type(controllerDef.Name) == "string", `Controller.Name must be a string; got {type(controllerDef.Name)}`)
	assert(#controllerDef.Name > 0, "Controller.Name must be a non-empty string")
	assert(not DoesControllerExist(controllerDef.Name), `Controller "{controllerDef.Name}" already exists`)
	assert(not started, `Controllers cannot be created after calling "Init.Start()"`)

	local controller = controllerDef :: Controller
	controllers[controller.Name] = controller

	log(LOG_LEVEL.DEBUG, `Created controller "{controller.Name}"`)

	return controller
end

--[=[
	@function AddControllers
	@within InitClient
	@param parent Instance -- Parent instance containing ModuleScript children
	@return {Controller}
	Requires all ModuleScript children of the given parent. Must be called before `Start()`.
]=]
function InitClient.AddControllers(parent: Instance): { Controller }
	assert(not started, `Controllers cannot be added after calling "Init.Start()"`)

	local addedControllers = {}
	for _, v in parent:GetChildren() do
		if not v:IsA("ModuleScript") then
			continue
		end

		table.insert(addedControllers, require(v))
	end

	return addedControllers
end

--[=[
	@function AddControllersDeep
	@within InitClient
	@param parent Instance -- Parent instance to search recursively
	@return {Controller}
	Requires all ModuleScript descendants of the given parent. Must be called before `Start()`.
]=]
function InitClient.AddControllersDeep(parent: Instance): { Controller }
	assert(not started, `Controllers cannot be added after calling "Init.Start()"`)

	local addedControllers = {}
	for _, v in parent:GetDescendants() do
		if not v:IsA("ModuleScript") then
			continue
		end

		table.insert(addedControllers, require(v))
	end

	return addedControllers
end

--[=[
	@function GetController
	@within InitClient
	@param controllerName string
	@return Controller
	Returns the controller with the given name. Must be called after `Start()`.
	In StrictMode (default), throws an error if the controller is not found.
	In non-strict mode, warns and returns nil.
]=]
function InitClient.GetController(controllerName: string): Controller
	if config.StrictMode then
		assert(started, "Cannot call GetController until Init has been started")
		assert(type(controllerName) == "string", `ControllerName must be a string; got {type(controllerName)}`)
		return assert(controllers[controllerName], `Could not find controller "{controllerName}"`) :: Controller
	else
		if not started then
			warn("[Init] Cannot call GetController until Init has been started")
			return nil
		end
		if type(controllerName) ~= "string" then
			warn(`[Init] ControllerName must be a string; got {type(controllerName)}`)
			return nil
		end
		local controller = controllers[controllerName]
		if not controller then
			warn(`[Init] Could not find controller "{controllerName}". Check to verify a controller with this name exists.`)
			return nil
		end
		return controller
	end
end

--[=[
	@function GetControllers
	@within InitClient
	@return {[string]: Controller}
	Returns all registered controllers. Must be called after `Start()`.
]=]
function InitClient.GetControllers(): { [string]: Controller }
	assert(started, "Cannot call GetControllers until Init has been started")

	return controllers
end

--[=[
	@function Start
	@within InitClient
	@return Promise
	Starts the framework. Runs `InitInit` on all controllers in dependency order,
	then spawns `InitStart` for each. Binds graceful shutdown via `game:BindToClose`.
]=]
function InitClient.Start()
	if started then
		return Promise.reject("Init already started")
	end

	started = true

	table.freeze(controllers)

	log(LOG_LEVEL.INFO, "Starting Init framework (client)...")

	-- Determine initialization order using topological sort
	local sortedControllers = topologicalSort(controllers)

	return Promise.new(function(resolve)
		-- Run InitInit sequentially according to dependency order using promise chaining
		local chain = Promise.resolve()

		for _, controller in sortedControllers do
			if type(controller.InitInit) == "function" then
				chain = chain:andThen(function()
					return Promise.new(function(r, reject)
						debug.setmemorycategory(controller.Name)
						log(LOG_LEVEL.INFO, `Initializing "{controller.Name}"...`)

						runMiddlewares(controller, "InitInit")

						local success, err = pcall(function()
							controller:InitInit()
						end)

						if success then
							log(LOG_LEVEL.DEBUG, `"{controller.Name}" initialized successfully`)
							r()
						else
							log(LOG_LEVEL.ERROR, `Controller "{controller.Name}":InitInit() failed: {err}`)
							reject(err)
						end
					end):timeout(config.InitTimeout, `Controller "{controller.Name}":InitInit() timed out after {config.InitTimeout}s`)
				end)
			end
		end

		resolve(
			chain:catch(function(err)
				log(LOG_LEVEL.ERROR, `A controller failed during InitInit: {err}`)
			end)
		)
	end):andThen(function()
		log(LOG_LEVEL.INFO, "All controllers initialized. Starting controllers...")

		for _, controller in sortedControllers do
			if type(controller.InitStart) == "function" then
				task.spawn(function()
					debug.setmemorycategory(controller.Name)
					log(LOG_LEVEL.INFO, `Starting "{controller.Name}"...`)

					runMiddlewares(controller, "InitStart")

					local success, err = pcall(function()
						controller:InitStart()
					end)
					if not success then
						log(LOG_LEVEL.ERROR, `Controller "{controller.Name}":InitStart() failed: {err}`)
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

		-- Bind graceful shutdown for handling disconnection/cleanup
		game:BindToClose(function()
			log(LOG_LEVEL.INFO, "Client shutdown initiated. Running InitDestroy on all controllers...")

			local destroyPromises = {}

			for _, controller in sortedControllers do
				if type(controller.InitDestroy) == "function" then
					table.insert(
						destroyPromises,
						Promise.new(function(r)
							debug.setmemorycategory(controller.Name)
							log(LOG_LEVEL.INFO, `Destroying "{controller.Name}"...`)

							runMiddlewares(controller, "InitDestroy")

							local success, err = pcall(function()
								controller:InitDestroy()
							end)

							if success then
								log(LOG_LEVEL.DEBUG, `"{controller.Name}" destroyed successfully`)
							else
								log(LOG_LEVEL.ERROR, `Controller "{controller.Name}":InitDestroy() failed: {err}`)
							end

							r()
						end):timeout(25, `Controller "{controller.Name}":InitDestroy() timed out`)
					)
				end
			end

			Promise.allSettled(destroyPromises):await()

			log(LOG_LEVEL.INFO, "Client shutdown complete")
		end)
	end)
end

--[=[
	@function OnStart
	@within InitClient
	@return Promise
	Returns a Promise that resolves when `Start()` has completed.
	If `Start()` has already completed, resolves immediately.
]=]
function InitClient.OnStart()
	if startedComplete then
		return Promise.resolve()
	else
		return Promise.fromEvent(onStartedComplete.Event)
			:timeout(config.OnStartTimeout, "Init.Start() was never called or failed to complete")
	end
end

return InitClient
