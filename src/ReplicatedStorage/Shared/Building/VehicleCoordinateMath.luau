--!strict
--[=[
	VehicleCoordinateMath
	Matemática compartida y pura entre cliente y servidor para convertir piezas y dimensiones
	del vehículo entre los cuatro marcos de referencia del sistema:
	1. BlueprintLocal (espacio de BuildZone / LocalCFrame persistente)
	2. VehicleLocal (espacio centrado horizontalmente en X/Z y apoyado en min.Y = 0 respecto a VehicleOrigin)
	3. StandWorld (espacio mundial de DisplayAnchor del VehicleStand aplicando HeightOffset y LateralOffset)
	4. LaunchWorld (espacio mundial del LaunchPoint respetando holgura sobre el piso)
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type VehicleBounds = {
	Valid: boolean,
	PieceCount: number,
	Min: Vector3,
	Max: Vector3,
	Size: Vector3,
	Center: Vector3,
	BaseAnchorCFrame: CFrame, -- Centro X/Z y base min.Y en el espacio local de BuildZone
}

export type PieceSizeResolver = (itemId: string) -> Vector3?

local VehicleCoordinateMath = {}

function VehicleCoordinateMath.ComputePieceLocalBounds(localCFrame: CFrame, pieceSize: Vector3): (Vector3, Vector3)
	local halfExtents = BuildRotation.GetRotatedExtents(pieceSize, localCFrame.Rotation) * 0.5
	local pos = localCFrame.Position
	return pos - halfExtents, pos + halfExtents
end

function VehicleCoordinateMath.ComputeVehicleBounds(
	pieces: { VehicleTypes.BlueprintPiece },
	resolvePieceSize: PieceSizeResolver
): VehicleBounds
	if #pieces == 0 then
		return {
			Valid = false,
			PieceCount = 0,
			Min = Vector3.zero,
			Max = Vector3.zero,
			Size = Vector3.zero,
			Center = Vector3.zero,
			BaseAnchorCFrame = CFrame.identity,
		}
	end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local validCount = 0

	for _, piece in ipairs(pieces) do
		local pieceSize = resolvePieceSize(piece.ItemId)
		if pieceSize then
			local pMin, pMax = VehicleCoordinateMath.ComputePieceLocalBounds(piece.LocalCFrame, pieceSize)
			if pMin.X < minX then
				minX = pMin.X
			end
			if pMin.Y < minY then
				minY = pMin.Y
			end
			if pMin.Z < minZ then
				minZ = pMin.Z
			end
			if pMax.X > maxX then
				maxX = pMax.X
			end
			if pMax.Y > maxY then
				maxY = pMax.Y
			end
			if pMax.Z > maxZ then
				maxZ = pMax.Z
			end
			validCount += 1
		end
	end

	if validCount == 0 then
		return {
			Valid = false,
			PieceCount = 0,
			Min = Vector3.zero,
			Max = Vector3.zero,
			Size = Vector3.zero,
			Center = Vector3.zero,
			BaseAnchorCFrame = CFrame.identity,
		}
	end

	local boundsMin = Vector3.new(minX, minY, minZ)
	local boundsMax = Vector3.new(maxX, maxY, maxZ)
	local size = boundsMax - boundsMin
	local center = (boundsMin + boundsMax) * 0.5
	local baseAnchor = CFrame.new(center.X, boundsMin.Y, center.Z)

	return {
		Valid = true,
		PieceCount = validCount,
		Min = boundsMin,
		Max = boundsMax,
		Size = size,
		Center = center,
		BaseAnchorCFrame = baseAnchor,
	}
end

function VehicleCoordinateMath.ComputeBaseAnchor(
	pieces: { VehicleTypes.BlueprintPiece },
	resolvePieceSize: PieceSizeResolver
): CFrame
	return VehicleCoordinateMath.ComputeVehicleBounds(pieces, resolvePieceSize).BaseAnchorCFrame
end

function VehicleCoordinateMath.BuildZoneToVehicleLocal(vehicleOrigin: CFrame, pieceLocalCFrame: CFrame): CFrame
	return vehicleOrigin:ToObjectSpace(pieceLocalCFrame)
end

function VehicleCoordinateMath.VehicleLocalToTargetWorld(targetAnchorWorldCFrame: CFrame, pieceVehicleLocalCFrame: CFrame): CFrame
	return targetAnchorWorldCFrame:ToWorldSpace(pieceVehicleLocalCFrame)
end

function VehicleCoordinateMath.BlueprintPieceToBuildZoneWorld(
	pieceLocalCFrame: CFrame,
	buildZoneWorldCFrame: CFrame,
	assemblyOffset: VehicleTypes.StandPresentationConfig?
): CFrame
	local effectiveZone = VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(buildZoneWorldCFrame, assemblyOffset)
	return effectiveZone:ToWorldSpace(pieceLocalCFrame)
end

function VehicleCoordinateMath.GetAssemblyOffsetCFrame(
	assemblyOffset: VehicleTypes.StandPresentationConfig?
): CFrame
	local h = if assemblyOffset then (assemblyOffset.HeightOffset or GameConfig.Stand.DefaultHeightOffset) else GameConfig.Stand.DefaultHeightOffset
	local lat = if assemblyOffset then (assemblyOffset.LateralOffset or GameConfig.Stand.DefaultLateralOffset) else GameConfig.Stand.DefaultLateralOffset
	return CFrame.new(lat, h, 0)
end

function VehicleCoordinateMath.GetEffectiveBuildZoneCFrame(
	buildZoneWorldCFrame: CFrame,
	assemblyOffset: VehicleTypes.StandPresentationConfig?
): CFrame
	return buildZoneWorldCFrame * VehicleCoordinateMath.GetAssemblyOffsetCFrame(assemblyOffset)
end

function VehicleCoordinateMath.ComputePhysicalLocalPosition(
	blueprintLocalPosition: Vector3,
	assemblyOffset: VehicleTypes.StandPresentationConfig?
): Vector3
	local h = if assemblyOffset then (assemblyOffset.HeightOffset or GameConfig.Stand.DefaultHeightOffset) else GameConfig.Stand.DefaultHeightOffset
	local lat = if assemblyOffset then (assemblyOffset.LateralOffset or GameConfig.Stand.DefaultLateralOffset) else GameConfig.Stand.DefaultLateralOffset
	return Vector3.new(blueprintLocalPosition.X + lat, blueprintLocalPosition.Y + h, blueprintLocalPosition.Z)
end

function VehicleCoordinateMath.ComputeZoneFloorLocalY(buildZone: BasePart?, platform: BasePart?): number?
	if not buildZone then
		return nil
	end
	local zoneFloorY = -buildZone.Size.Y * 0.5
	if platform and platform:IsA("BasePart") then
		local platTopWorld = platform.CFrame:PointToWorldSpace(Vector3.new(0, platform.Size.Y * 0.5, 0))
		local platTopLocalY = buildZone.CFrame:PointToObjectSpace(platTopWorld).Y
		return math.max(zoneFloorY, platTopLocalY)
	end
	return zoneFloorY
end

function VehicleCoordinateMath.ComputeLiftBoundsFromExtents(
	vehicleMin: Vector3?,
	vehicleMax: Vector3?,
	buildZoneSize: Vector3,
	maxZoneHeight: number?,
	floorLocalYOverride: number?
): VehicleTypes.LiftBounds
	local minH = GameConfig.Stand.MinHeightOffset
	local maxH = GameConfig.Stand.MaxHeightOffset
	local minL = GameConfig.Stand.MinLateralOffset
	local maxL = GameConfig.Stand.MaxLateralOffset

	local halfX = buildZoneSize.X * 0.5
	local zoneFloorY = -buildZoneSize.Y * 0.5
	local effectiveZoneHeight = math.max(buildZoneSize.Y, maxZoneHeight or GameConfig.Building.DefaultZoneHeight)
	local ceilingY = zoneFloorY + effectiveZoneHeight
	local floorY = if floorLocalYOverride ~= nil then math.max(zoneFloorY, floorLocalYOverride) else zoneFloorY

	if vehicleMin and vehicleMax then
		minH = math.max(minH, floorY - vehicleMin.Y)
		maxH = math.min(maxH, ceilingY - vehicleMax.Y)
		minL = math.max(minL, -halfX - vehicleMin.X)
		maxL = math.min(maxL, halfX - vehicleMax.X)
	else
		maxH = math.min(maxH, ceilingY - floorY)
		minL = math.max(minL, -halfX)
		maxL = math.min(maxL, halfX)
	end

	-- Si el vehículo ya llena o supera ligeramente una cota, garantizar rango consistente
	if maxH < minH then
		maxH = minH
	end
	if maxL < minL then
		local midL = (minL + maxL) * 0.5
		minL = midL
		maxL = midL
	end

	local restH = math.clamp(GameConfig.Stand.DefaultHeightOffset, minH, maxH)
	local restL = math.clamp(GameConfig.Stand.DefaultLateralOffset, minL, maxL)

	return {
		MinHeightOffset = minH,
		MaxHeightOffset = maxH,
		MinLateralOffset = minL,
		MaxLateralOffset = maxL,
		DefaultRestHeightOffset = restH,
		DefaultRestLateralOffset = restL,
		VehicleBoundsMin = vehicleMin,
		VehicleBoundsMax = vehicleMax,
	}
end

function VehicleCoordinateMath.ComputeLiftBounds(
	pieces: { VehicleTypes.BlueprintPiece },
	resolvePieceSize: PieceSizeResolver,
	buildZoneSize: Vector3,
	maxZoneHeight: number?,
	floorLocalYOverride: number?
): VehicleTypes.LiftBounds
	if #pieces == 0 then
		return VehicleCoordinateMath.ComputeLiftBoundsFromExtents(nil, nil, buildZoneSize, maxZoneHeight, floorLocalYOverride)
	end
	local bounds = VehicleCoordinateMath.ComputeVehicleBounds(pieces, resolvePieceSize)
	if not bounds.Valid then
		return VehicleCoordinateMath.ComputeLiftBoundsFromExtents(nil, nil, buildZoneSize, maxZoneHeight, floorLocalYOverride)
	end
	return VehicleCoordinateMath.ComputeLiftBoundsFromExtents(bounds.Min, bounds.Max, buildZoneSize, maxZoneHeight, floorLocalYOverride)
end

function VehicleCoordinateMath.IsLiftOffsetWithinBounds(
	heightOffset: number,
	lateralOffset: number,
	liftBounds: VehicleTypes.LiftBounds,
	epsilon: number?
): (boolean, string?)
	local eps = epsilon or GameConfig.Stand.Epsilon
	if heightOffset < liftBounds.MinHeightOffset - eps then
		return false, "BelowMinLiftHeight"
	end
	if heightOffset > liftBounds.MaxHeightOffset + eps then
		return false, "AboveMaxLiftHeight"
	end
	if lateralOffset < liftBounds.MinLateralOffset - eps then
		return false, "BelowMinLateral"
	end
	if lateralOffset > liftBounds.MaxLateralOffset + eps then
		return false, "AboveMaxLateral"
	end
	return true, nil
end

function VehicleCoordinateMath.ComputeStandAnchorWorld(
	displayAnchorWorldCFrame: CFrame,
	presentation: VehicleTypes.StandPresentationConfig?
): CFrame
	local h = if presentation then presentation.HeightOffset else GameConfig.Stand.DefaultHeightOffset
	local lat = if presentation then presentation.LateralOffset else GameConfig.Stand.DefaultLateralOffset
	return displayAnchorWorldCFrame * CFrame.new(lat, h, 0)
end

function VehicleCoordinateMath.BlueprintPieceToStandWorld(
	pieceLocalCFrame: CFrame,
	vehicleOrigin: CFrame,
	displayAnchorWorldCFrame: CFrame,
	presentation: VehicleTypes.StandPresentationConfig?
): CFrame
	local standAnchorWorld = VehicleCoordinateMath.ComputeStandAnchorWorld(displayAnchorWorldCFrame, presentation)
	local pieceRelVehicle = vehicleOrigin:ToObjectSpace(pieceLocalCFrame)
	return standAnchorWorld:ToWorldSpace(pieceRelVehicle)
end

function VehicleCoordinateMath.ComputeLaunchFloorWorld(launchPointPart: BasePart, groundClearance: number?): CFrame
	local clearance = if groundClearance ~= nil then groundClearance else GameConfig.LaunchPrep.GroundClearanceStuds
	-- Base del LaunchPoint coincide con la superficie superior de Platform (-Size.Y * 0.5)
	return launchPointPart.CFrame * CFrame.new(0, -launchPointPart.Size.Y * 0.5 + clearance, 0)
end

function VehicleCoordinateMath.BlueprintPieceToLaunchWorld(
	pieceLocalCFrame: CFrame,
	vehicleOrigin: CFrame,
	launchFloorWorldCFrame: CFrame
): CFrame
	local pieceRelVehicle = vehicleOrigin:ToObjectSpace(pieceLocalCFrame)
	return launchFloorWorldCFrame:ToWorldSpace(pieceRelVehicle)
end

function VehicleCoordinateMath.RebasePieceBetweenBuildZones(
	pieceLocalCFrame: CFrame,
	sourceBuildZoneCFrame: CFrame,
	targetBuildZoneCFrame: CFrame
): CFrame
	local rel = pieceLocalCFrame
	-- El LocalCFrame ya es relativo al BuildZone local: se conserva idéntico en estaciones rotadas o movidas.
	local world = sourceBuildZoneCFrame:ToWorldSpace(rel)
	local worldDelta = sourceBuildZoneCFrame:ToObjectSpace(world)
	return targetBuildZoneCFrame:ToObjectSpace(targetBuildZoneCFrame:ToWorldSpace(worldDelta))
end

return VehicleCoordinateMath

