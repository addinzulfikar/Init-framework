--[=[
	@class Init
	Framework entry point. Automatically returns InitServer or InitClient
	based on the runtime context.
]=]
local RunService = game:GetService("RunService")

if RunService:IsServer() then
	return require(script.InitServer)
else
	local InitServer = script:FindFirstChild("InitServer")
	if InitServer and RunService:IsRunning() then
		InitServer:Destroy()
	end

	return require(script.InitClient)
end
