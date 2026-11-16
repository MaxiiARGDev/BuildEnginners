--!strict
--[=[
	StandPreviewService
	En Fase 2.4.1 el Stand pasó a funcionar como elevador físico de construcción sobre el
	propio EditableVehicle dentro de BuildZone. Este módulo desactiva la generación de
	modelos duplicados (`StandPreview`) conservando compatibilidad limpia de ciclo de vida
	en Bootstrap y limpieza preventiva de instancias residuales.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local PlotService = require(ServerScriptService.Server.Services.PlotService)

local StandPreviewService = {
	Name = "StandPreviewService",
}

local _unsubPlotReleased: (() -> ())? = nil
local _initialized = false
local _started = false

local function destroyStrayStandPreview(plot: PlotService.PlotRecord?)
	if not plot or not plot.DynamicContainer then
		return
	end
	local stray = plot.DynamicContainer:FindFirstChild(GameConfig.Building.StandPreviewName)
	if stray then
		stray:Destroy()
	end
end

function StandPreviewService.GetStandAnchorCFrame(plot: PlotService.PlotRecord): CFrame
	if plot.StandDisplayAnchor then
		return plot.StandDisplayAnchor.CFrame
	end
	if plot.Zones and plot.Zones.StandZone then
		return plot.Zones.StandZone.CFrame * CFrame.new(0, plot.Zones.StandZone.Size.Y * 0.5, 0)
	end
	return plot.Zones.BuildZone.CFrame
end

function StandPreviewService.RebuildForPlayer(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord,
	_bp: VehicleTypes.VehicleBlueprint?
)
	destroyStrayStandPreview(plot)
	local assignedPlot = PlotService.GetPlotByPlayer(player)
	if assignedPlot and assignedPlot ~= plot then
		destroyStrayStandPreview(assignedPlot)
	end
end

function StandPreviewService.UpdateOffsets(
	player: PlotService.PlayerLike,
	plot: PlotService.PlotRecord?,
	_bp: VehicleTypes.VehicleBlueprint?
)
	destroyStrayStandPreview(plot or PlotService.GetPlotByPlayer(player))
end

function StandPreviewService.Init(_options: { ItemAssetsRoot: Instance? }?)
	if _initialized then
		return
	end
	if not _unsubPlotReleased then
		_unsubPlotReleased = PlotService.OnPlotReleased(function(playerLike, plot)
			destroyStrayStandPreview(plot)
			StandPreviewService.ClearPlayer(playerLike)
		end)
	end
	_initialized = true
end

function StandPreviewService.Start()
	if _started then
		return
	end
	if not _initialized then
		StandPreviewService.Init()
	end
	_started = true
end

function StandPreviewService.GetStandPreviewModel(_player: PlotService.PlayerLike): Model?
	return nil
end

function StandPreviewService.GetTrackedPlayerCount(): number
	return 0
end

function StandPreviewService.ClearPlayer(player: PlotService.PlayerLike)
	local plot = PlotService.GetPlotByPlayer(player)
	destroyStrayStandPreview(plot)
end

function StandPreviewService._ResetForTests()
	if _unsubPlotReleased then
		_unsubPlotReleased()
		_unsubPlotReleased = nil
	end
	_initialized = false
	_started = false
end

return StandPreviewService
