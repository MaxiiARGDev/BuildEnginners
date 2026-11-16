--!strict
--[=[
	BuildRotationGizmo
	Gizmo 3D local de rotación mediante anillos circulares X (rojo), Y (verde) y Z (azul).
	- Renderizado mediante pool de LineHandleAdornment (cero Parts por frame).
	- Matemática proyectiva rayo-plano + desenrollado continuo de ángulo (sin saltos en 0°/360° o ±180°).
	- Respeta incrementos 90°, 45°, 15°, 1° filtrados por la política del objeto en ItemRegistry.
	- Cancelable y sin tráfico de red durante el arrastre.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildTransformMath = require(ReplicatedStorage.Shared.Building.BuildTransformMath)
local BuildSnapPolicy = require(ReplicatedStorage.Shared.Building.BuildSnapPolicy)

export type AxisName = "X" | "Y" | "Z"

export type RotateDragOptions = {
	ItemId: string?,
	AngleIncrementDeg: number?,
}

type RingVisual = {
	Segments: { LineHandleAdornment },
	BaseColor: Color3,
	NormalDir: Vector3,
}

local BuildRotationGizmo = {}

local SEGMENTS_PER_RING = 36

local AXIS_INFO: { { Name: AxisName, Dir: Vector3, Color: Color3 } } = {
	{ Name = "X", Dir = Vector3.xAxis, Color = GameConfig.Building.GizmoAxisXColor },
	{ Name = "Y", Dir = Vector3.yAxis, Color = GameConfig.Building.GizmoAxisYColor },
	{ Name = "Z", Dir = Vector3.zAxis, Color = GameConfig.Building.GizmoAxisZColor },
}

local _containerFolder: Folder? = nil
local _ringVisuals: { [AxisName]: RingVisual } = {}
local _lastAdornee: BasePart? = nil

local _isDragging = false
local _activeAxis: AxisName? = nil
local _hoverAxis: AxisName? = nil
local _dragStartLocalCFrame: CFrame? = nil
local _dragItemId: string? = nil
local _dragRefDir: Vector3 = Vector3.xAxis
local _accumUnwrappedDeg = 0
local _prevSnappedDeltaDeg = 0
local _currentSnappedDeg = 0
local _isVisible = false

local function getVisualParent(): Instance
	return Workspace.CurrentCamera or Workspace
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

local function getPlaneBasis(normalDir: Vector3): (Vector3, Vector3)
	local ref = if math.abs(normalDir.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	local u = (ref - normalDir * ref:Dot(normalDir)).Unit
	local v = normalDir:Cross(u).Unit
	return u, v
end

local function ensureVisualsInitialized(buildZone: BasePart)
	local host = getVisualParent()
	if _containerFolder and _containerFolder.Parent ~= host then
		_containerFolder:Destroy()
		_containerFolder = nil
		table.clear(_ringVisuals)
	end

	if not _containerFolder then
		local folder = Instance.new("Folder")
		folder.Name = "BuildRotationGizmoPool"
		folder.Parent = host
		_containerFolder = folder

		for _, info in ipairs(AXIS_INFO) do
			local segments: { LineHandleAdornment } = table.create(SEGMENTS_PER_RING)
			for s = 1, SEGMENTS_PER_RING do
				local line = Instance.new("LineHandleAdornment")
				line.Name = `RotRing_{info.Name}_{s}`
				line.Color3 = info.Color
				line.Thickness = 3.0
				line.Transparency = 0.10
				line.AlwaysOnTop = false
				line.ZIndex = 6
				line.Visible = false
				line.Length = 1
				line.Parent = folder
				segments[s] = line
			end
			_ringVisuals[info.Name] = {
				Segments = segments,
				BaseColor = info.Color,
				NormalDir = info.Dir,
			}
		end
	end

	if _lastAdornee ~= buildZone then
		_lastAdornee = buildZone
		for _, ring in pairs(_ringVisuals) do
			for _, seg in ipairs(ring.Segments) do
				seg.Adornee = buildZone
			end
		end
	end
end

function BuildRotationGizmo.ComputeRingRadius(pieceExtents: Vector3): number
	local maxExt = math.max(pieceExtents.X, pieceExtents.Y, pieceExtents.Z)
	return math.clamp(maxExt * 0.65 + 1.4, 2.2, 4.6)
end

function BuildRotationGizmo.HitTestFromRay(
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
	local ringRadius = BuildRotationGizmo.ComputeRingRadius(pieceExtents)
	local camDist = (localRayOrigin - originLocalPos).Magnitude
	local hitThreshold = math.clamp(0.42 + camDist * 0.015, 0.42, 1.15)

	local bestAxis: AxisName? = nil
	local bestDist = hitThreshold

	for _, info in ipairs(AXIS_INFO) do
		local hitOk, hitPt = BuildTransformMath.IntersectRayWithPlane(localRayOrigin, localRayDir, originLocalPos, info.Dir)
		local cosIncidence = math.abs(localRayDir:Dot(info.Dir))
		if hitOk and cosIncidence > 0.12 then
			local radialDist = (hitPt - originLocalPos).Magnitude
			local ringDist = math.abs(radialDist - ringRadius)
			local weightedDist = ringDist + (1 - cosIncidence) * 0.03
			if ringDist < hitThreshold and weightedDist < bestDist then
				bestDist = weightedDist
				bestAxis = info.Name
			end
		else
			-- Respaldo cuando el anillo se ve casi de canto respecto a la cámara
			local u, v = getPlaneBasis(info.Dir)
			local prevPt = originLocalPos + u * ringRadius
			for s = 1, 12 do
				local theta = (s / 12) * math.pi * 2
				local nextPt = originLocalPos + (u * math.cos(theta) + v * math.sin(theta)) * ringRadius
				local segDist = BuildTransformMath.RayToSegmentDistance(localRayOrigin, localRayDir, prevPt, nextPt)
				local weightedDist = segDist + 0.06
				if segDist < hitThreshold and weightedDist < bestDist then
					bestDist = weightedDist
					bestAxis = info.Name
				end
				prevPt = nextPt
			end
		end
	end

	_hoverAxis = bestAxis
	return bestAxis
end

function BuildRotationGizmo.BeginDragFromRay(
	axis: AxisName,
	buildZone: BasePart,
	startLocalCFrame: CFrame,
	rayOriginWorld: Vector3,
	rayDirWorld: Vector3,
	itemId: string?,
	assemblyOffsetCFrame: CFrame?
): boolean
	if rayDirWorld.Magnitude < 1e-5 then
		return false
	end

	local axisDir = getAxisDir(axis)
	local effZoneCF = if assemblyOffsetCFrame then buildZone.CFrame * assemblyOffsetCFrame else buildZone.CFrame
	local localRayOrigin = effZoneCF:PointToObjectSpace(rayOriginWorld)
	local localRayDir = effZoneCF:VectorToObjectSpace(rayDirWorld).Unit
	local hitOk, hitPt = BuildTransformMath.IntersectRayWithPlane(localRayOrigin, localRayDir, startLocalCFrame.Position, axisDir)

	local refDir: Vector3
	if hitOk then
		local radial = hitPt - startLocalCFrame.Position
		radial -= axisDir * radial:Dot(axisDir)
		if radial.Magnitude > 0.05 then
			refDir = radial.Unit
		else
			refDir = (getPlaneBasis(axisDir))
		end
	else
		refDir = (getPlaneBasis(axisDir))
	end

	_isDragging = true
	_activeAxis = axis
	_dragStartLocalCFrame = startLocalCFrame
	_dragItemId = itemId
	_dragRefDir = refDir
	_accumUnwrappedDeg = 0
	_prevSnappedDeltaDeg = 0
	_currentSnappedDeg = 0
	return true
end

function BuildRotationGizmo.UpdateDragFromRay(
	buildZone: BasePart,
	rayOriginWorld: Vector3,
	rayDirWorld: Vector3,
	options: RotateDragOptions?,
	assemblyOffsetCFrame: CFrame?
): (CFrame?, number, string)
	if not _isDragging or not _activeAxis or not _dragStartLocalCFrame then
		return nil, 0, ""
	end

	local axis = _activeAxis :: AxisName
	local startCF = _dragStartLocalCFrame :: CFrame
	if rayDirWorld.Magnitude < 1e-5 then
		return startCF, _currentSnappedDeg, `{axis}: {string.format("%+d°", math.round(_currentSnappedDeg))}`
	end

	local axisDir = getAxisDir(axis)
	local effZoneCF = if assemblyOffsetCFrame then buildZone.CFrame * assemblyOffsetCFrame else buildZone.CFrame
	local localRayOrigin = effZoneCF:PointToObjectSpace(rayOriginWorld)
	local localRayDir = effZoneCF:VectorToObjectSpace(rayDirWorld).Unit

	local hitOk, hitPt = BuildTransformMath.IntersectRayWithPlane(localRayOrigin, localRayDir, startCF.Position, axisDir)
	if not hitOk then
		return CFrame.new(startCF.Position) * BuildRotation.RotateAxisDegrees(startCF.Rotation, axis, _currentSnappedDeg),
			_currentSnappedDeg,
			`{axis}: {string.format("%+d°", math.round(_currentSnappedDeg))}`
	end

	local rawWrappedDeg = BuildTransformMath.ComputeSignedAngleOnPlane(startCF.Position, axisDir, _dragRefDir, hitPt)
	_accumUnwrappedDeg = BuildTransformMath.UnwrapAngleDeg(_accumUnwrappedDeg, rawWrappedDeg)

	local effectiveItemId = (options and options.ItemId) or _dragItemId
	local requestedInc = options and options.AngleIncrementDeg
	local effectiveStep = BuildSnapPolicy.GetEffectiveAngleIncrement(effectiveItemId, requestedInc)

	local snappedDeg: number
	if effectiveStep <= 1 then
		snappedDeg = BuildRotation.SnapAngleDegrees(_accumUnwrappedDeg, effectiveStep)
	else
		local hystDeg = math.min(3.5, effectiveStep * 0.08)
		local candidateDeg = BuildRotation.SnapAngleDegrees(_accumUnwrappedDeg, effectiveStep)
		local prevAlignedToStep = math.abs((_prevSnappedDeltaDeg / effectiveStep) - math.round(_prevSnappedDeltaDeg / effectiveStep)) < 1e-4
		if prevAlignedToStep and math.abs(_accumUnwrappedDeg - _prevSnappedDeltaDeg) <= effectiveStep * 0.5 + hystDeg then
			snappedDeg = _prevSnappedDeltaDeg
		else
			snappedDeg = candidateDeg
		end
	end

	_prevSnappedDeltaDeg = snappedDeg
	_currentSnappedDeg = snappedDeg

	local newRot = BuildRotation.RotateAxisDegrees(startCF.Rotation, axis, snappedDeg)
	local newLocalCF = CFrame.new(startCF.Position) * newRot

	local policyTag = ""
	if requestedInc and requestedInc < effectiveStep then
		policyTag = ` (mín {effectiveStep}°)`
	end
	local label = `{axis}: {string.format("%+d°", math.round(snappedDeg))}{policyTag}`
	return newLocalCF, snappedDeg, label
end

function BuildRotationGizmo.EndDrag(): (CFrame?, number)
	local startCF = _dragStartLocalCFrame
	local deg = _currentSnappedDeg
	_isDragging = false
	_activeAxis = nil
	_dragStartLocalCFrame = nil
	_dragItemId = nil
	_accumUnwrappedDeg = 0
	_prevSnappedDeltaDeg = 0
	_currentSnappedDeg = 0
	return startCF, deg
end

function BuildRotationGizmo.CancelDrag(): CFrame?
	local startCF = _dragStartLocalCFrame
	BuildRotationGizmo.EndDrag()
	return startCF
end

function BuildRotationGizmo.IsDragging(): boolean
	return _isDragging
end

function BuildRotationGizmo.GetActiveAxis(): AxisName?
	return _activeAxis
end

function BuildRotationGizmo.GetHoverAxis(): AxisName?
	return _hoverAxis
end

function BuildRotationGizmo.GetCurrentAngleDeg(): number
	return _currentSnappedDeg
end

function BuildRotationGizmo.GetRawUnwrappedDeg(): number
	return _accumUnwrappedDeg
end

function BuildRotationGizmo.UpdateVisual(
	buildZone: BasePart,
	originLocalPos: Vector3,
	pieceExtents: Vector3,
	overrideHover: AxisName?,
	overrideActive: AxisName?,
	assemblyOffsetCFrame: CFrame?
)
	if not buildZone or not buildZone.Parent then
		BuildRotationGizmo.Hide()
		return
	end

	ensureVisualsInitialized(buildZone)
	_isVisible = true

	local ringRadius = BuildRotationGizmo.ComputeRingRadius(pieceExtents)
	local highlighted = overrideActive or _activeAxis or overrideHover or _hoverAxis
	local adorneeOrigin = if assemblyOffsetCFrame then assemblyOffsetCFrame:PointToWorldSpace(originLocalPos) else originLocalPos

	for _, info in ipairs(AXIS_INFO) do
		local ring = _ringVisuals[info.Name]
		local isHighlighted = (highlighted == info.Name)
		local color = if isHighlighted then GameConfig.Building.GizmoHighlightColor else ring.BaseColor
		local thickness = if isHighlighted then 4.0 else 2.5
		local transp = if isHighlighted then 0.0 else 0.16

		local u, v = getPlaneBasis(info.Dir)
		for s = 1, SEGMENTS_PER_RING do
			local theta0 = ((s - 1) / SEGMENTS_PER_RING) * math.pi * 2
			local theta1 = (s / SEGMENTS_PER_RING) * math.pi * 2
			local p0 = adorneeOrigin + (u * math.cos(theta0) + v * math.sin(theta0)) * ringRadius
			local p1 = adorneeOrigin + (u * math.cos(theta1) + v * math.sin(theta1)) * ringRadius
			local chord = p1 - p0
			local len = chord.Magnitude
			local seg = ring.Segments[s]
			local dir = chord / math.max(1e-5, len)
			local safeUp = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis

			seg.Adornee = buildZone
			seg.CFrame = CFrame.lookAt(p0, p1, safeUp)
			seg.Length = len
			seg.Color3 = color
			seg.Thickness = thickness
			seg.Transparency = transp
			seg.Visible = true
		end
	end
end

function BuildRotationGizmo.Hide()
	_isVisible = false
	for _, ring in pairs(_ringVisuals) do
		for _, seg in ipairs(ring.Segments) do
			seg.Visible = false
		end
	end
end

function BuildRotationGizmo.Destroy()
	BuildRotationGizmo.EndDrag()
	_hoverAxis = nil
	_isVisible = false
	_lastAdornee = nil
	if _containerFolder then
		_containerFolder:Destroy()
		_containerFolder = nil
	end
	table.clear(_ringVisuals)
end

function BuildRotationGizmo.GetDebugStats(): { Visible: boolean, IsDragging: boolean, ActiveAxis: AxisName?, HoverAxis: AxisName?, HasContainer: boolean, SegmentsPerRing: number }
	return {
		Visible = _isVisible,
		IsDragging = _isDragging,
		ActiveAxis = _activeAxis,
		HoverAxis = _hoverAxis,
		HasContainer = _containerFolder ~= nil,
		SegmentsPerRing = SEGMENTS_PER_RING,
	}
end

return BuildRotationGizmo
