--!strict
--[=[
	BuildMoveGizmo
	Gizmo 3D local de traslación por ejes X (rojo), Y (verde) y Z (azul) en coordenadas de BuildZone.
	- Renderizado mediante pool de CylinderHandleAdornment + ConeHandleAdornment (cero Parts por frame).
	- Matemática proyectiva rayo-eje 3D con resta del punto de agarre inicial (sin salto inicial).
	- Respeta modo Grid (resolución configurada) y modo Libre (continuo hasta 0.01 studs).
	- Cancelable y desacoplado de red.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildTransformMath = require(ReplicatedStorage.Shared.Building.BuildTransformMath)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)

export type AxisName = "X" | "Y" | "Z"

export type MoveDragOptions = {
	PositionMode: ("Grid" | "Free")?,
	GridResolution: number?,
}

type AxisVisual = {
	Shaft: CylinderHandleAdornment,
	Tip: ConeHandleAdornment,
	BaseColor: Color3,
	AxisDir: Vector3,
}

local BuildMoveGizmo = {}

local AXIS_INFO: { { Name: AxisName, Dir: Vector3, Color: Color3 } } = {
	{ Name = "X", Dir = Vector3.xAxis, Color = GameConfig.Building.GizmoAxisXColor },
	{ Name = "Y", Dir = Vector3.yAxis, Color = GameConfig.Building.GizmoAxisYColor },
	{ Name = "Z", Dir = Vector3.zAxis, Color = GameConfig.Building.GizmoAxisZColor },
}

local _containerFolder: Folder? = nil
local _axisVisuals: { [AxisName]: AxisVisual } = {}
local _lastAdornee: BasePart? = nil

local _isDragging = false
local _activeAxis: AxisName? = nil
local _hoverAxis: AxisName? = nil
local _dragStartLocalCFrame: CFrame? = nil
local _grabOffsetAlongAxis = 0
local _prevSnappedCoord: number? = nil
local _currentDeltaStuds = 0
local _isVisible = false

local function getVisualParent(): Instance
	return Workspace.CurrentCamera or Workspace
end

local function ensureVisualsInitialized(buildZone: BasePart)
	local host = getVisualParent()
	if _containerFolder and _containerFolder.Parent ~= host then
		_containerFolder:Destroy()
		_containerFolder = nil
		table.clear(_axisVisuals)
	end

	if not _containerFolder then
		local folder = Instance.new("Folder")
		folder.Name = "BuildMoveGizmoPool"
		folder.Parent = host
		_containerFolder = folder

		for _, info in ipairs(AXIS_INFO) do
			local shaft = Instance.new("CylinderHandleAdornment")
			shaft.Name = `MoveShaft_{info.Name}`
			shaft.Radius = 0.08
			shaft.Height = 2.5
			shaft.Color3 = info.Color
			shaft.Transparency = 0.15
			shaft.AlwaysOnTop = false
			shaft.ZIndex = 6
			shaft.Visible = false
			shaft.Parent = folder

			local tip = Instance.new("ConeHandleAdornment")
			tip.Name = `MoveTip_{info.Name}`
			tip.Radius = 0.22
			tip.Height = 0.55
			tip.Color3 = info.Color
			tip.Transparency = 0.05
			tip.AlwaysOnTop = false
			tip.ZIndex = 7
			tip.Visible = false
			tip.Parent = folder

			_axisVisuals[info.Name] = {
				Shaft = shaft,
				Tip = tip,
				BaseColor = info.Color,
				AxisDir = info.Dir,
			}
		end
	end

	if _lastAdornee ~= buildZone then
		_lastAdornee = buildZone
		for _, visual in pairs(_axisVisuals) do
			visual.Shaft.Adornee = buildZone
			visual.Tip.Adornee = buildZone
		end
	end
end

local function getAxisDir(axis: AxisName): Vector3
	if axis == "X" then
		return Vector3.xAxis
	elseif axis == "Y" then
		return Vector3.yAxis
	else
		return Vector3.zAxis
	end
end

local function getSafeUp(dir: Vector3): Vector3
	return if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
end

function BuildMoveGizmo.ComputeAxisLength(pieceExtents: Vector3): number
	local maxExt = math.max(pieceExtents.X, pieceExtents.Y, pieceExtents.Z)
	return math.clamp(maxExt * 0.65 + 2.1, 2.8, 5.5)
end

function BuildMoveGizmo.HitTestFromRay(
	buildZone: BasePart,
	originLocalPos: Vector3,
	pieceExtents: Vector3,
	rayOriginWorld: Vector3,
	rayDirWorld: Vector3,
	assemblyOffsetCFrame: CFrame?
): AxisName?
	if rayDirWorld.Magnitude < 1e-5 then
		return nil
	end

	local effZoneCF = if assemblyOffsetCFrame then buildZone.CFrame * assemblyOffsetCFrame else buildZone.CFrame
	local localRayOrigin = effZoneCF:PointToObjectSpace(rayOriginWorld)
	local localRayDir = effZoneCF:VectorToObjectSpace(rayDirWorld).Unit
	local axisLen = BuildMoveGizmo.ComputeAxisLength(pieceExtents)
	local camDist = (localRayOrigin - originLocalPos).Magnitude
	local hitThreshold = math.clamp(0.38 + camDist * 0.015, 0.38, 1.05)

	local bestAxis: AxisName? = nil
	local bestDist = hitThreshold

	for _, info in ipairs(AXIS_INFO) do
		local segEnd = originLocalPos + info.Dir * (axisLen + 0.55)
		local dist, tSeg = BuildTransformMath.RayToSegmentDistance(localRayOrigin, localRayDir, originLocalPos + info.Dir * 0.35, segEnd)
		if dist <= bestDist and tSeg >= 0 and tSeg <= 1 then
			bestDist = dist
			bestAxis = info.Name
		end
	end

	_hoverAxis = bestAxis
	return bestAxis
end

function BuildMoveGizmo.BeginDragFromRay(
	axis: AxisName,
	buildZone: BasePart,
	startLocalCFrame: CFrame,
	rayOriginWorld: Vector3,
	rayDirWorld: Vector3,
	assemblyOffsetCFrame: CFrame?
): boolean
	if rayDirWorld.Magnitude < 1e-5 then
		return false
	end

	local effZoneCF = if assemblyOffsetCFrame then buildZone.CFrame * assemblyOffsetCFrame else buildZone.CFrame
	local localRayOrigin = effZoneCF:PointToObjectSpace(rayOriginWorld)
	local localRayDir = effZoneCF:VectorToObjectSpace(rayDirWorld).Unit
	local axisDir = getAxisDir(axis)

	local valid, s0 = BuildTransformMath.IntersectRayWithLineAxis(
		localRayOrigin,
		localRayDir,
		startLocalCFrame.Position,
		axisDir
	)

	_isDragging = true
	_activeAxis = axis
	_dragStartLocalCFrame = startLocalCFrame
	_grabOffsetAlongAxis = if valid then s0 else 0
	_prevSnappedCoord = startLocalCFrame.Position:Dot(axisDir)
	_currentDeltaStuds = 0
	return true
end

function BuildMoveGizmo.UpdateDragFromRay(
	buildZone: BasePart,
	rayOriginWorld: Vector3,
	rayDirWorld: Vector3,
	options: MoveDragOptions?,
	assemblyOffsetCFrame: CFrame?
): (CFrame?, number, string)
	if not _isDragging or not _activeAxis or not _dragStartLocalCFrame then
		return nil, 0, ""
	end
	if rayDirWorld.Magnitude < 1e-5 then
		return _dragStartLocalCFrame, _currentDeltaStuds, `{string.format("%+.2f", _currentDeltaStuds)} st ({_activeAxis})`
	end

	local axis = _activeAxis :: AxisName
	local axisDir = getAxisDir(axis)
	local startCF = _dragStartLocalCFrame :: CFrame
	local effZoneCF = if assemblyOffsetCFrame then buildZone.CFrame * assemblyOffsetCFrame else buildZone.CFrame
	local localRayOrigin = effZoneCF:PointToObjectSpace(rayOriginWorld)
	local localRayDir = effZoneCF:VectorToObjectSpace(rayDirWorld).Unit

	local valid, s = BuildTransformMath.IntersectRayWithLineAxis(
		localRayOrigin,
		localRayDir,
		startCF.Position,
		axisDir
	)
	if not valid then
		return startCF, _currentDeltaStuds, `{string.format("%+.2f", _currentDeltaStuds)} st ({axis})`
	end

	local rawDelta = s - _grabOffsetAlongAxis
	local mode = BuildSnapPolicy.NormalizePositionMode(options and options.PositionMode)
	local startCoord = startCF.Position:Dot(axisDir)
	local targetCoord = startCoord + rawDelta

	local appliedCoord: number
	if mode == GameConfig.Building.PositionModes.Grid then
		local step = BuildSnapPolicy.NormalizeGridResolution(options and options.GridResolution)
		appliedCoord = BuildTransformMath.SnapValueWithHysteresis(targetCoord, step, _prevSnappedCoord, 0.08)
	else
		-- Modo Libre: desplazamiento continuo suave con redondeo mínimo de 0.01 studs
		local fineStep = GameConfig.Building.FreeFineStep
		appliedCoord = BuildTransformMath.SnapValue(targetCoord, fineStep)
	end

	_prevSnappedCoord = appliedCoord
	local finalDelta = appliedCoord - startCoord
	_currentDeltaStuds = finalDelta

	local newPos = startCF.Position + axisDir * finalDelta
	local newLocalCF = CFrame.new(newPos) * startCF.Rotation
	local label = `{string.format("%+.2f", finalDelta)} st ({axis})`
	return newLocalCF, finalDelta, label
end

function BuildMoveGizmo.EndDrag(): (CFrame?, number)
	local startCF = _dragStartLocalCFrame
	local delta = _currentDeltaStuds
	_isDragging = false
	_activeAxis = nil
	_dragStartLocalCFrame = nil
	_grabOffsetAlongAxis = 0
	_prevSnappedCoord = nil
	_currentDeltaStuds = 0
	return startCF, delta
end

function BuildMoveGizmo.CancelDrag(): CFrame?
	local startCF = _dragStartLocalCFrame
	BuildMoveGizmo.EndDrag()
	return startCF
end

function BuildMoveGizmo.IsDragging(): boolean
	return _isDragging
end

function BuildMoveGizmo.GetActiveAxis(): AxisName?
	return _activeAxis
end

function BuildMoveGizmo.GetHoverAxis(): AxisName?
	return _hoverAxis
end

function BuildMoveGizmo.GetCurrentDelta(): number
	return _currentDeltaStuds
end

function BuildMoveGizmo.UpdateVisual(
	buildZone: BasePart,
	originLocalPos: Vector3,
	pieceExtents: Vector3,
	overrideHover: AxisName?,
	overrideActive: AxisName?,
	assemblyOffsetCFrame: CFrame?
)
	if not buildZone or not buildZone.Parent then
		BuildMoveGizmo.Hide()
		return
	end

	ensureVisualsInitialized(buildZone)
	_isVisible = true

	local axisLen = BuildMoveGizmo.ComputeAxisLength(pieceExtents)
	local shaftLen = math.max(1.2, axisLen - 0.3)
	local highlighted = overrideActive or _activeAxis or overrideHover or _hoverAxis

	local adorneeOrigin = if assemblyOffsetCFrame then assemblyOffsetCFrame:PointToWorldSpace(originLocalPos) else originLocalPos

	for _, info in ipairs(AXIS_INFO) do
		local visual = _axisVisuals[info.Name]
		local dir = info.Dir
		local up = getSafeUp(dir)

		local midpoint = adorneeOrigin + dir * (shaftLen * 0.5)
		local shaftCF = CFrame.lookAt(midpoint, midpoint + dir, up)

		local tipBase = adorneeOrigin + dir * shaftLen
		local tipCF = CFrame.lookAt(tipBase, tipBase + dir, up)

		local isHighlighted = (highlighted == info.Name)
		local color = if isHighlighted then GameConfig.Building.GizmoHighlightColor else visual.BaseColor

		visual.Shaft.Adornee = buildZone
		visual.Shaft.Height = shaftLen
		visual.Shaft.Radius = if isHighlighted then 0.11 else 0.08
		visual.Shaft.Color3 = color
		visual.Shaft.Transparency = if isHighlighted then 0.0 else 0.18
		visual.Shaft.CFrame = shaftCF
		visual.Shaft.Visible = true

		visual.Tip.Adornee = buildZone
		visual.Tip.Radius = if isHighlighted then 0.27 else 0.22
		visual.Tip.Height = 0.55
		visual.Tip.Color3 = color
		visual.Tip.Transparency = if isHighlighted then 0.0 else 0.08
		visual.Tip.CFrame = tipCF
		visual.Tip.Visible = true
	end
end

function BuildMoveGizmo.Hide()
	_isVisible = false
	for _, visual in pairs(_axisVisuals) do
		visual.Shaft.Visible = false
		visual.Tip.Visible = false
	end
end

function BuildMoveGizmo.Destroy()
	BuildMoveGizmo.EndDrag()
	_hoverAxis = nil
	_isVisible = false
	_lastAdornee = nil
	if _containerFolder then
		_containerFolder:Destroy()
		_containerFolder = nil
	end
	table.clear(_axisVisuals)
end

function BuildMoveGizmo.GetDebugStats(): { Visible: boolean, IsDragging: boolean, ActiveAxis: AxisName?, HoverAxis: AxisName?, HasContainer: boolean }
	return {
		Visible = _isVisible,
		IsDragging = _isDragging,
		ActiveAxis = _activeAxis,
		HoverAxis = _hoverAxis,
		HasContainer = _containerFolder ~= nil,
	}
end

return BuildMoveGizmo
