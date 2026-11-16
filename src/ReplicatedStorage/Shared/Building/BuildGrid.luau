--!strict
--[=[
	BuildGrid
	Cálculo matemático determinista de snap 3D, intersección con el plano de construcción
	y validación de límites en coordenadas locales de BuildZone.
	- Respeta cualquier posición y rotación 3D de BuildZone.
	- Soporta coordenadas positivas y negativas.
	- Evita que las piezas queden enterradas bajo el piso de BuildZone.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildTransformMath = require(ReplicatedStorage.Shared.Building.BuildTransformMath)

export type SnapInput = {
	BuildZoneCFrame: CFrame,
	BuildZoneSize: Vector3,
	WorldHitPosition: Vector3,
	WorldHitNormal: Vector3?,
	PieceSize: Vector3,
	RelativeRotation: CFrame,
	GridSize: number?,
	PositionMode: ("Grid" | "Free")?,
	PrevSnappedLocalPos: Vector3?,
	HysteresisRatio: number?,
	LiftHeightOffset: number?,
}

export type SnapResult = {
	WorldCFrame: CFrame,
	LocalCFrame: CFrame,
	LocalPosition: Vector3,
	RotatedExtents: Vector3,
	SurfaceOriginLocal: Vector3,
	SurfaceNormalLocal: Vector3,
	TangentULocal: Vector3,
	TangentVLocal: Vector3,
}

local EPSILON = 0.01

local BuildGrid = {}

function BuildGrid.SnapValue(value: number, gridSize: number?): number
	local step = gridSize or GameConfig.Building.DefaultGridResolution
	if step <= 0 then
		error("[BuildGrid] GridSize must be > 0")
	end
	return BuildTransformMath.SnapValue(value, step)
end

--[=[
	Interseca un rayo en espacio mundo con el plano inferior (piso) de BuildZone.
	Útil cuando el raycast físico no golpea ninguna pieza o superficie.
]=]
function BuildGrid.IntersectBuildPlane(
	buildZoneCFrame: CFrame,
	buildZoneSize: Vector3,
	rayOrigin: Vector3,
	rayDirection: Vector3
): (Vector3?, Vector3)
	local planeNormal = buildZoneCFrame.UpVector
	local floorPoint = buildZoneCFrame:PointToWorldSpace(Vector3.new(0, -buildZoneSize.Y * 0.5, 0))

	local denom = rayDirection:Dot(planeNormal)
	if math.abs(denom) < 1e-5 then
		return nil, planeNormal
	end

	local t = (floorPoint - rayOrigin):Dot(planeNormal) / denom
	if t < 0 or t > GameConfig.Building.MaxRaycastDistance then
		return nil, planeNormal
	end

	return rayOrigin + rayDirection * t, planeNormal
end

--[=[
	Calcula de manera determinista el CFrame con snap en la cuadrícula local de BuildZone.
	No recorta (clamp) X/Z dentro de BuildZone para que las posiciones fuera de límites
	se muestren visualmente como inválidas en vez de saltar a posiciones inesperadas.
]=]
function BuildGrid.ComputeSnappedCFrame(input: SnapInput): SnapResult
	local res = BuildTransformMath.ComputeSurfacePlacement({
		BuildZoneCFrame = input.BuildZoneCFrame,
		BuildZoneSize = input.BuildZoneSize,
		WorldHitPosition = input.WorldHitPosition,
		WorldHitNormal = input.WorldHitNormal,
		PieceSize = input.PieceSize,
		RelativeRotation = input.RelativeRotation,
		PositionMode = input.PositionMode or GameConfig.Building.PositionModes.Grid,
		GridSize = input.GridSize or GameConfig.Building.DefaultGridResolution,
		PrevSnappedLocalPos = input.PrevSnappedLocalPos,
		HysteresisRatio = input.HysteresisRatio,
		LiftHeightOffset = input.LiftHeightOffset,
	})

	return {
		WorldCFrame = res.WorldCFrame,
		LocalCFrame = res.LocalCFrame,
		LocalPosition = res.LocalPosition,
		RotatedExtents = res.RotatedExtents,
		SurfaceOriginLocal = res.SurfaceOriginLocal,
		SurfaceNormalLocal = res.SurfaceNormalLocal,
		TangentULocal = res.TangentULocal,
		TangentVLocal = res.TangentVLocal,
	}
end

--[=[
	Comprueba si un volumen AABB definido por (`minBound`, `maxBound`) en espacio local de BuildZone,
	desplazado por `assemblyOffset`, permanece dentro del volumen físico real de BuildZone.
]=]
function BuildGrid.ValidateBoundsMinMax(
	buildZoneSize: Vector3,
	minBound: Vector3,
	maxBound: Vector3,
	maxZoneHeight: number?,
	assemblyOffset: { HeightOffset: number?, LateralOffset: number? }?
): (boolean, string?)
	local halfZoneX = buildZoneSize.X * 0.5
	local halfZoneZ = buildZoneSize.Z * 0.5
	local floorY = -buildZoneSize.Y * 0.5
	local effectiveHeight = math.max(buildZoneSize.Y, maxZoneHeight or GameConfig.Building.DefaultZoneHeight)
	local ceilingY = floorY + effectiveHeight

	local offsetX = if assemblyOffset and assemblyOffset.LateralOffset then assemblyOffset.LateralOffset else 0
	local offsetY = if assemblyOffset and assemblyOffset.HeightOffset then assemblyOffset.HeightOffset else 0

	local minX = minBound.X + offsetX
	local maxX = maxBound.X + offsetX
	local minY = minBound.Y + offsetY
	local maxY = maxBound.Y + offsetY
	local minZ = minBound.Z
	local maxZ = maxBound.Z

	if minY < floorY - EPSILON then
		return false, "BelowFloor"
	end
	if maxY > ceilingY + EPSILON then
		return false, "AboveCeiling"
	end
	if minX < -halfZoneX - EPSILON or maxX > halfZoneX + EPSILON then
		return false, "OutOfBoundsX"
	end
	if minZ < -halfZoneZ - EPSILON or maxZ > halfZoneZ + EPSILON then
		return false, "OutOfBoundsZ"
	end

	return true, nil
end

--[=[
	Comprueba si el volumen completo de la pieza (localPosition ± rotatedExtents/2)
	desplazado por `assemblyOffset` permanece dentro del volumen físico real de BuildZone.
]=]
function BuildGrid.ValidateBounds(
	buildZoneSize: Vector3,
	localPosition: Vector3,
	rotatedExtents: Vector3,
	maxZoneHeight: number?,
	assemblyOffset: { HeightOffset: number?, LateralOffset: number? }?
): (boolean, string?)
	local half = rotatedExtents * 0.5
	return BuildGrid.ValidateBoundsMinMax(
		buildZoneSize,
		localPosition - half,
		localPosition + half,
		maxZoneHeight,
		assemblyOffset
	)
end

return BuildGrid

