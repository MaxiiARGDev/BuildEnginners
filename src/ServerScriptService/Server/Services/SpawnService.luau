--!strict
--[=[
	SpawnService
	Posiciona a cada jugador en el `PlayerSpawn` de su estación asignada por PlotService.
	- Sin coordenadas globales hardcodeadas ni dependencia de Workspace.Baseplate.
	- Evita conexiones duplicadas de CharacterAdded y limpia al desconectar.
	- Maneja condiciones de carrera entre CharacterAdded y PlotService.Assign sin esperas infinitas.
	- Mantiene la misma estación al reaparecer y expone hooks para limpieza futura de VehicleRuntime.
]=]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local PlotService = require(ServerScriptService.Server.Services.PlotService)

export type BeforeRespawnHook = (player: PlotService.PlayerLike, plot: PlotService.PlotRecord) -> ()

local HUMANOID_ROOT_TIMEOUT_SECONDS = 5

local SpawnService = {
	Name = "SpawnService",
}

local _characterConnections: { [number]: RBXScriptConnection } = {}
local _serviceConnections: { RBXScriptConnection } = {}
local _unsubPlotAssigned: (() -> ())? = nil
local _beforeRespawnHooks: { BeforeRespawnHook } = {}
local _initialized = false
local _started = false

local function getHumanoidRootPart(character: Model): BasePart?
	local existing = character:FindFirstChild("HumanoidRootPart")
	if existing and existing:IsA("BasePart") then
		return existing
	end
	local waited = character:WaitForChild("HumanoidRootPart", HUMANOID_ROOT_TIMEOUT_SECONDS)
	if waited and waited:IsA("BasePart") then
		return waited
	end
	return nil
end

local function runBeforeRespawnHooks(player: PlotService.PlayerLike, plot: PlotService.PlotRecord)
	for _, hook in ipairs(_beforeRespawnHooks) do
		local ok, err = pcall(hook, player, plot)
		if not ok then
			warn(`[SpawnService] BeforeRespawnHook error for '{player.Name}': {tostring(err)}`)
		end
	end
end

--[=[
	Posiciona de forma síncrona un Character sobre el PlayerSpawn indicado usando Character:PivotTo(),
	anulando velocidades residuales para evitar caídas o penetración en Platform.
]=]
function SpawnService.PositionCharacter(character: Model, playerSpawn: BasePart): boolean
	if not character.Parent or not playerSpawn.Parent then
		return false
	end

	local rootPart = getHumanoidRootPart(character)
	if not rootPart then
		return false
	end

	rootPart.AssemblyLinearVelocity = Vector3.zero
	rootPart.AssemblyAngularVelocity = Vector3.zero
	character:PivotTo(playerSpawn.CFrame)
	return true
end

function SpawnService.SpawnAtAssignedPlot(player: PlotService.PlayerLike, character: Model, plotOverride: PlotService.PlotRecord?): boolean
	local plot = plotOverride or PlotService.GetPlotByPlayer(player)
	if not plot then
		return false
	end

	runBeforeRespawnHooks(player, plot)
	return SpawnService.PositionCharacter(character, plot.PlayerSpawn)
end

local function handleCharacterAdded(player: Player, character: Model)
	-- Esperar al siguiente ciclo diferido para sobrescribir cualquier colocación por defecto de Roblox
	task.defer(function()
		if not player.Parent or not character.Parent or player.Character ~= character then
			return
		end
		SpawnService.SpawnAtAssignedPlot(player, character, nil)
	end)
end

local function bindPlayer(player: Player)
	if _characterConnections[player.UserId] ~= nil then
		return
	end

	_characterConnections[player.UserId] = player.CharacterAdded:Connect(function(character)
		handleCharacterAdded(player, character)
	end)

	if player.Character then
		handleCharacterAdded(player, player.Character)
	end
end

local function unbindPlayer(player: Player)
	local conn = _characterConnections[player.UserId]
	if conn then
		conn:Disconnect()
		_characterConnections[player.UserId] = nil
	end
end

function SpawnService.RegisterBeforeRespawnHook(hook: BeforeRespawnHook): () -> ()
	table.insert(_beforeRespawnHooks, hook)
	return function()
		local idx = table.find(_beforeRespawnHooks, hook)
		if idx then
			table.remove(_beforeRespawnHooks, idx)
		end
	end
end

function SpawnService.GetTrackedConnectionCount(): number
	local count = 0
	for _ in pairs(_characterConnections) do
		count += 1
	end
	return count
end

function SpawnService.HasCharacterConnection(userId: number): boolean
	return _characterConnections[userId] ~= nil
end

function SpawnService.Init()
	if _initialized then
		return
	end
	_initialized = true
end

function SpawnService.Start()
	if _started then
		return
	end
	if not _initialized then
		SpawnService.Init()
	end

	-- Si CharacterAdded ocurrió antes de que PlotService.Assign terminara, posicionar apenas se asigne
	_unsubPlotAssigned = PlotService.OnPlotAssigned(function(playerLike, plotRecord)
		if typeof(playerLike) == "Instance" and (playerLike :: Instance):IsA("Player") then
			local player = playerLike :: Player
			local character = player.Character
			if character and character.Parent then
				SpawnService.SpawnAtAssignedPlot(player, character, plotRecord)
			end
		end
	end)

	for _, player in ipairs(Players:GetPlayers()) do
		bindPlayer(player)
	end

	table.insert(
		_serviceConnections,
		Players.PlayerAdded:Connect(function(player)
			bindPlayer(player)
		end)
	)

	table.insert(
		_serviceConnections,
		Players.PlayerRemoving:Connect(function(player)
			unbindPlayer(player)
		end)
	)

	_started = true
end

function SpawnService._ResetForTests()
	for _, conn in ipairs(_serviceConnections) do
		conn:Disconnect()
	end
	table.clear(_serviceConnections)

	for userId, conn in pairs(_characterConnections) do
		conn:Disconnect()
		_characterConnections[userId] = nil
	end

	if _unsubPlotAssigned then
		_unsubPlotAssigned()
		_unsubPlotAssigned = nil
	end

	table.clear(_beforeRespawnHooks)
	_initialized = false
	_started = false
end

return SpawnService

