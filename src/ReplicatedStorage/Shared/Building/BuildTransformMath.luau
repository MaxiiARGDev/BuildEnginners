--!strict
--[=[
	BuildTransformMath
	Matemática pura compartida para posicionamiento sobre superficies (Grid/Libre),
	histéresis anti-parpadeo, intersección rayo-plano y rayo-eje 3D para gizmos,
	desenrollado continuo de ángulos (sin saltos en 0°/360°) y ajustes finos.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)

export type SurfacePlacementInput = {
	BuildZoneCFrame: CFrame,
	BuildZoneSize: Vector3,
	WorldHitPosition: Vector3,
	WorldHitNormal: Vector3?,
	PieceSize: Vector3,
	RelativeRotation: CFrame,
	PositionMode: ("Grid" | "Free")?,
	GridSize: number?,
	PrevSnappedLocalPos: Vector3?,
	HysteresisRatio: number?,
	LiftHeightOffset: number?,
}

export type SurfacePlacementResult = {
	WorldCFrame: CFrame,
	LocalCFrame: CFrame,
	LocalPosition: Vector3,
	RotatedExtents: Vector3,
	SurfaceOriginLocal: Vector3,
	SurfaceNormalLocal: Vector3,
	TangentULocal: Vector3,
	TangentVLocal: Vector3,
}

local BuildTransformMath = {}

function BuildTransformMath.SnapValue(value: number, step: number): number
	if step <= 0 then
		error("[BuildTransformMath] step must be > 0")
	end
	local snapped = math.floor(value / step + 0.5) * step
	if math.abs(snapped) < 1e-6 then
		return 0
	end
	return snapped
end

--[=[
	Snap escalar con pequeña histéresis respecto al valor previo para evitar parpadeo en bordes de celda.
]=]
function BuildTransformMath.SnapValueWithHysteresis(
	value: number,
	step: number,
	prevSnapped: number?,
	hysteresisRatio: number?
): number
	local snapped = BuildTransformMath.SnapValue(value, step)
	if prevSnapped == nil then
		return snapped
	end
	local ratio = hysteresisRatio or 0.08
	if ratio <= 0 then
		return snapped
	end
	-- Mantener celda previa mientras el cursor no supere la frontera ± (0.5 + ratio) * step
	local distFromPrev = math.abs(value - prevSnapped)
	if distFromPrev <= (0.5 + ratio) * step then
		return prevSnapped
	end
	return snapped
end

--[=[
	Calcula una base ortonormal `(tangentU, tangentV, normal)` en espacio local de BuildZone
	para cualquier superficie (piso horizontal, paredes verticales X/Z u otras orientaciones).
]=]
function BuildTransformMath.ComputeSurfaceAxes(surfaceNormalLocal: Vector3): (Vector3, Vector3, Vector3)
	local n = if surfaceNormalLocal.Magnitude > 1e-5 then surfaceNormalLocal.Unit else Vector3.yAxis
	local absX = math.abs(n.X)
	local absY = math.abs(n.Y)
	local absZ = math.abs(n.Z)

	-- En caras ortogonales principales alineamos exactamente con los ejes locales de BuildZone
	if absY >= absX and absY >= absZ and absY > 0.9 then
		return Vector3.xAxis, Vector3.zAxis, Vector3.new(0, if n.Y >= 0 then 1 else -1, 0)
	elseif absX >= absY and absX >= absZ and absX > 0.9 then
		return Vector3.zAxis, Vector3.yAxis, Vector3.new(if n.X >= 0 then 1 else -1, 0, 0)
	elseif absZ >= absX and absZ >= absY and absZ > 0.9 then
		return Vector3.xAxis, Vector3.yAxis, Vector3.new(0, 0, if n.Z >= 0 then 1 else -1)
	end

	local refUp = if math.abs(n:Dot(Vector3.yAxis)) < 0.95 then Vector3.yAxis else Vector3.zAxis
	local u = refUp:Cross(n).Unit
	local v = n:Cross(u).Unit
	return u, v, n
end

--[=[
	Calcula el CFrame sobre una superficie en modo Grid (configurable) o Free (continuo).
	Mantiene contacto exacto a lo largo de la normal de superficie (sin flotar ni enterrar piezas
	de dimensiones pares, impares o fraccionarias) y snappea solo los ejes tangenciales en modo Grid.
]=]
function BuildTransformMath.ComputeSurfacePlacement(input: SurfacePlacementInput): SurfacePlacementResult
	local mode = input.PositionMode or GameConfig.Building.PositionModes.Grid
	local gridSize = input.GridSize or GameConfig.Building.DefaultGridResolution
	if gridSize <= 0 then
		gridSize = GameConfig.Building.DefaultGridResolution
	end

	local rot = if BuildRotation.IsOrthogonal90(input.RelativeRotation, 0.02)
		then BuildRotation.Orthonormalize(input.RelativeRotation)
		else BuildRotation.OrthonormalizeGeneral(input.RelativeRotation)
	local extents = BuildRotation.GetRotatedExtents(input.PieceSize, rot)

	local hitLocal = input.BuildZoneCFrame:PointToObjectSpace(input.WorldHitPosition)
	local rawNormalLocal = if input.WorldHitNormal
		then input.BuildZoneCFrame:VectorToObjectSpace(input.WorldHitNormal)
		else Vector3.yAxis
	local tU, tV, n = BuildTransformMath.ComputeSurfaceAxes(rawNormalLocal)

	local halfAlongN = math.abs(n.X) * (extents.X * 0.5) + math.abs(n.Y) * (extents.Y * 0.5) + math.abs(n.Z) * (extents.Z * 0.5)
	local centerLocal = hitLocal + n * halfAlongN

	local liftH = input.LiftHeightOffset or 0
	local floorY = -input.BuildZoneSize.Y * 0.5 - liftH
	local minCenterY = floorY + extents.Y * 0.5

	if mode == GameConfig.Building.PositionModes.Grid then
		local prev = input.PrevSnappedLocalPos
		local prevU = if prev then prev:Dot(tU) else nil
		local prevV = if prev then prev:Dot(tV) else nil

		local uCoord = BuildTransformMath.SnapValueWithHysteresis(centerLocal:Dot(tU), gridSize, prevU, input.HysteresisRatio)
		local vCoord: number
		-- Cuando una tangente es vertical (superficie vertical), anclar respecto a minCenterY conserva apoyo en el piso
		if math.abs(tV.Y) > 0.9 then
			local rawAboveFloor = centerLocal.Y - minCenterY
			local prevAbove = if prev then (prev.Y - minCenterY) else nil
			local snappedAbove = math.max(0, BuildTransformMath.SnapValueWithHysteresis(rawAboveFloor, gridSize, prevAbove, input.HysteresisRatio))
			vCoord = minCenterY + snappedAbove
		else
			vCoord = BuildTransformMath.SnapValueWithHysteresis(centerLocal:Dot(tV), gridSize, prevV, input.HysteresisRatio)
		end

		local nCoord = centerLocal:Dot(n)
		centerLocal = tU * uCoord + tV * vCoord + n * nCoord
	end

	-- Evitar que cualquier pieza se entierre bajo el piso de BuildZone
	if centerLocal.Y < minCenterY then
		centerLocal = Vector3.new(centerLocal.X, minCenterY, centerLocal.Z)
	end

	local localCFrame = CFrame.new(centerLocal) * rot
	local worldCFrame = input.BuildZoneCFrame:ToWorldSpace(localCFrame)

	return {
		WorldCFrame = worldCFrame,
		LocalCFrame = localCFrame,
		LocalPosition = centerLocal,
		RotatedExtents = extents,
		SurfaceOriginLocal = hitLocal,
		SurfaceNormalLocal = n,
		TangentULocal = tU,
		TangentVLocal = tV,
	}
end

--[=[
	Intersección exacta rayo-plano en espacio 3D (usado por anillos de rotación y plano de suelo).
]=]
function BuildTransformMath.IntersectRayWithPlane(
	rayOrigin: Vector3,
	rayDirection: Vector3,
	planeOrigin: Vector3,
	planeNormal: Vector3
): (boolean, Vector3)
	local dirMag = rayDirection.Magnitude
	local normMag = planeNormal.Magnitude
	if dirMag < 1e-6 or normMag < 1e-6 then
		return false, planeOrigin
	end

	local dirUnit = rayDirection / dirMag
	local normUnit = planeNormal / normMag
	local denom = dirUnit:Dot(normUnit)
	if math.abs(denom) < 1e-4 then
		return false, planeOrigin
	end

	local t = (planeOrigin - rayOrigin):Dot(normUnit) / denom
	if t <= 0 or t > 2000 then
		return false, planeOrigin
	end

	return true, rayOrigin + dirUnit * t
end

--[=[
	Calcula el parámetro `tAxis` del punto más cercano entre un rayo de cámara y una recta de eje 3D
	(punto `axisOrigin + tAxis * axisDir`), independiente de la resolución en píxeles.
]=]
function BuildTransformMath.IntersectRayWithLineAxis(
	rayOrigin: Vector3,
	rayDirection: Vector3,
	axisOrigin: Vector3,
	axisDirection: Vector3
): (boolean, number)
	local rMag = rayDirection.Magnitude
	local aMag = axisDirection.Magnitude
	if rMag < 1e-6 or aMag < 1e-6 then
		return false, 0
	end

	local u = rayDirection / rMag
	local v = axisDirection / aMag
	local w0 = axisOrigin - rayOrigin

	local b = u:Dot(v)
	local denom = 1 - b * b
	if denom < 0.01 then
		-- Rayo casi paralelo al eje -> evitar inestabilidad numérica proyectando contra plano perpendicular a la cámara
		local fallbackOk, hitPoint = BuildTransformMath.IntersectRayWithPlane(rayOrigin, u, axisOrigin, u)
		if not fallbackOk then
			return false, 0
		end
		return true, (hitPoint - axisOrigin):Dot(v)
	end

	local d = u:Dot(w0)
	local e = v:Dot(w0)
	local tAxis = (b * d - e) / denom
	local sRay = d + b * tAxis

	if sRay <= 0 or sRay > 2000 then
		return false, 0
	end

	return true, tAxis
end

--[=[
	Calcula la distancia mínima desde un rayo 3D a un segmento finito `[segA, segB]`,
	y devuelve `(distance, tSeg, rayDist)`. Útil para hit-test preciso de gizmos en perspectiva.
]=]
function BuildTransformMath.RayToSegmentDistance(
	rayOrigin: Vector3,
	rayDirection: Vector3,
	segA: Vector3,
	segB: Vector3
): (number, number, number)
	local u = rayDirection.Unit
	local segVec = segB - segA
	local segLenSq = segVec:Dot(segVec)
	if segLenSq < 1e-8 then
		local ap = segA - rayOrigin
		local s = math.max(0, ap:Dot(u))
		return ((rayOrigin + u * s) - segA).Magnitude, 0, s
	end

	local w0 = rayOrigin - segA
	local a = 1
	local b = u:Dot(segVec)
	local c = segLenSq
	local d = u:Dot(w0)
	local e = segVec:Dot(w0)
	local denom = a * c - b * b

	local sRay: number
	local tSeg: number
	if denom < 1e-6 then
		sRay = 0
		tSeg = math.clamp(e / c, 0, 1)
	else
		sRay = (b * e - c * d) / denom
		tSeg = (a * e - b * d) / denom
		if sRay < 0 then
			sRay = 0
			tSeg = math.clamp(e / c, 0, 1)
		else
			if tSeg < 0 then
				tSeg = 0
				sRay = math.max(0, -d)
			elseif tSeg > 1 then
				tSeg = 1
				sRay = math.max(0, -d + b)
			end
		end
	end

	local closestRay = rayOrigin + u * sRay
	local closestSeg = segA + segVec * tSeg
	return (closestRay - closestSeg).Magnitude, tSeg, sRay
end

--[=[
	Calcula el ángulo con signo (en grados [-180, 180]) de un punto sobre un plano respecto a `refDirUnit`.
]=]
function BuildTransformMath.ComputeSignedAngleOnPlane(
	planeOrigin: Vector3,
	planeNormal: Vector3,
	refDirUnit: Vector3,
	pointOnPlane: Vector3
): number
	local n = planeNormal.Unit
	local ref = (refDirUnit - n * refDirUnit:Dot(n))
	if ref.Magnitude < 1e-5 then
		return 0
	end
	ref = ref.Unit
	local tangent = n:Cross(ref)

	local rel = pointOnPlane - planeOrigin
	local planar = rel - n * rel:Dot(n)
	if planar.Magnitude < 1e-5 then
		return 0
	end

	return math.deg(math.atan2(planar:Dot(tangent), planar:Dot(ref)))
end

--[=[
	Desenrolla un ángulo continuo respecto al previo para eliminar saltos al cruzar ±180° / 0° / 360°.
]=]
function BuildTransformMath.UnwrapAngleDeg(prevUnwrappedDeg: number, rawWrappedDeg: number): number
	local diff = ((rawWrappedDeg - prevUnwrappedDeg + 180) % 360) - 180
	return prevUnwrappedDeg + diff
end

function BuildTransformMath.NudgeLocalCFrame(
	localCFrame: CFrame,
	localAxis: Vector3,
	deltaStuds: number
): CFrame
	local offset = localAxis.Unit * deltaStuds
	return CFrame.new(localCFrame.Position + offset) * localCFrame.Rotation
end

function BuildTransformMath.ClampPositionToBuildZone(
	localPos: Vector3,
	rotatedExtents: Vector3,
	buildZoneSize: Vector3,
	maxZoneHeight: number?
): Vector3
	local halfX = math.max(0, buildZoneSize.X * 0.5 - rotatedExtents.X * 0.5)
	local halfZ = math.max(0, buildZoneSize.Z * 0.5 - rotatedExtents.Z * 0.5)
	local floorY = -buildZoneSize.Y * 0.5
	local effectiveHeight = math.max(buildZoneSize.Y, maxZoneHeight or GameConfig.Building.DefaultZoneHeight)
	local minY = floorY + rotatedExtents.Y * 0.5
	local maxY = math.max(minY, floorY + effectiveHeight - rotatedExtents.Y * 0.5)

	return Vector3.new(
		math.clamp(localPos.X, -halfX, halfX),
		math.clamp(localPos.Y, minY, maxY),
		math.clamp(localPos.Z, -halfZ, halfZ)
	)
end

return BuildTransformMath

