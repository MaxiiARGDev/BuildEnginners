--!strict
--[=[
	FaceSnapMath
	Matemática compartida y pura para ajuste automático cara con cara (`FaceSnap`, Fase 2.4.2).
	Opera directamente sobre cajas orientadas (OBB) y geometrías compuestas (`PartBoxes`)
	sin depender exclusivamente de Attachments `Conn_*`:
	- Evalúa las 6 caras locales (+X, -X, +Y, -Y, +Z, -Z) de cada sub-caja en cualquier rotación.
	- Alinea caras compatibles opuestas (`candNormal · targetNormal <= -0.985`) a contacto exacto (gap = 0)
	  conservando la rotación elegida por el jugador.
	- Verifica colisiones OBB reales (`ConnectionMath.AnyOverlap`) y límites reales de `BuildZone` / piso.
	- Mantiene estado de histéresis (`FaceLockState`) para evitar saltos o parpadeos al mover el cursor.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildGrid = require(ReplicatedStorage.Shared.Building.BuildGrid)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type FaceId = "+X" | "-X" | "+Y" | "-Y" | "+Z" | "-Z"

export type BoxFace = {
	FaceId: FaceId,
	BoxIndex: number,
	Center: Vector3,
	Normal: Vector3,
	TangentU: Vector3,
	TangentV: Vector3,
	HalfU: number,
	HalfV: number,
}

export type FaceSnapVisualTarget = {
	TargetPieceId: string,
	TargetFaceId: FaceId,
	TargetBoxIndex: number,
	CandidateFaceId: FaceId,
	CandidateBoxIndex: number,
	TargetFaceCenter: Vector3,
	TargetFaceNormal: Vector3,
	TargetTangentU: Vector3,
	TargetTangentV: Vector3,
	TargetHalfU: number,
	TargetHalfV: number,
	ContactPoint: Vector3,
	IsValid: boolean,
	RejectReason: string?,
}

export type FaceLockState = {
	TargetPieceId: string?,
	TargetBoxIndex: number?,
	TargetFaceId: FaceId?,
	CandidateBoxIndex: number?,
	CandidateFaceId: FaceId?,
	LastSnappedPosition: Vector3?,
}

export type FaceSnapInput = {
	BaseLocalCFrame: CFrame,
	CandidateItemId: string,
	CandidateSize: Vector3,
	CandidateAttachments: { ConnectionMath.AttachmentSpec },
	CandidatePartBoxes: { VehicleTypes.PartBoxSpec }?,
	ExistingPieces: { ConnectionMath.PieceGeometrySpec },
	SpatialIndex: ConnectionMath.SpatialIndex?,
	TargetPieceId: string?,
	SurfaceHitLocal: Vector3?,
	SurfaceNormalLocal: Vector3?,
	RayOriginLocal: Vector3?,
	RayDirectionLocal: Vector3?,
	BuildZoneSize: Vector3?,
	MaxZoneHeight: number?,
	AssemblyOffset: { HeightOffset: number?, LateralOffset: number? }?,
	LockState: FaceLockState?,
	MaxRadius: number?,
	MinContactOverlap: number?,
	MinNormalDot: number?,
	Hysteresis: number?,
	MaxPassiveJump: number?,
}

export type FaceSnapResult = {
	Matched: boolean,
	SnappedLocalCFrame: CFrame,
	VisualTarget: FaceSnapVisualTarget?,
	RejectReason: string?,
	RejectedPieceId: string?,
	Score: number?,
}

local FaceSnapMath = {}

local LOCAL_FACES: { { Id: FaceId, AxisIndex: number, Sign: number } } = {
	{ Id = "+X", AxisIndex = 1, Sign = 1 },
	{ Id = "-X", AxisIndex = 1, Sign = -1 },
	{ Id = "+Y", AxisIndex = 2, Sign = 1 },
	{ Id = "-Y", AxisIndex = 2, Sign = -1 },
	{ Id = "+Z", AxisIndex = 3, Sign = 1 },
	{ Id = "-Z", AxisIndex = 3, Sign = -1 },
}

function FaceSnapMath.CreateLockState(): FaceLockState
	return {
		TargetPieceId = nil,
		TargetBoxIndex = nil,
		TargetFaceId = nil,
		CandidateBoxIndex = nil,
		CandidateFaceId = nil,
		LastSnappedPosition = nil,
	}
end

function FaceSnapMath.ClearLockState(lockState: FaceLockState?)
	if not lockState then
		return
	end
	lockState.TargetPieceId = nil
	lockState.TargetBoxIndex = nil
	lockState.TargetFaceId = nil
	lockState.CandidateBoxIndex = nil
	lockState.CandidateFaceId = nil
	lockState.LastSnappedPosition = nil
end

local function extractBoxFaces(boxCF: CFrame, boxSize: Vector3, boxIndex: number): { BoxFace }
	local axX = boxCF.RightVector
	local axY = boxCF.UpVector
	local axZ = -boxCF.LookVector
	local axes = { axX, axY, axZ }
	local halves = { boxSize.X * 0.5, boxSize.Y * 0.5, boxSize.Z * 0.5 }
	local center = boxCF.Position

	local faces: { BoxFace } = table.create(6)
	for i, def in ipairs(LOCAL_FACES) do
		local aIdx = def.AxisIndex
		local sign = def.Sign
		local uIdx = if aIdx == 1 then 2 elseif aIdx == 2 then 1 else 1
		local vIdx = if aIdx == 1 then 3 elseif aIdx == 2 then 3 else 2

		faces[i] = {
			FaceId = def.Id,
			BoxIndex = boxIndex,
			Center = center + axes[aIdx] * (halves[aIdx] * sign),
			Normal = axes[aIdx] * sign,
			TangentU = axes[uIdx],
			TangentV = axes[vIdx],
			HalfU = halves[uIdx],
			HalfV = halves[vIdx],
		}
	end
	return faces
end

--[=[
	Devuelve todas las caras de todas las sub-cajas OBB de una pieza en espacio local de BuildZone.
]=]
function FaceSnapMath.ExtractPieceFaces(
	pieceCF: CFrame,
	pieceSize: Vector3,
	partBoxes: { VehicleTypes.PartBoxSpec }?
): { BoxFace }
	if not partBoxes or #partBoxes == 0 then
		return extractBoxFaces(pieceCF, pieceSize, 1)
	end

	local allFaces: { BoxFace } = table.create(#partBoxes * 6)
	for boxIdx, box in ipairs(partBoxes) do
		local worldBoxCF = pieceCF * box.LocalCFrame
		local boxFaces = extractBoxFaces(worldBoxCF, box.Size, boxIdx)
		for _, face in ipairs(boxFaces) do
			table.insert(allFaces, face)
		end
	end
	return allFaces
end

local function computeCandidateHalfRadius(size: Vector3, partBoxes: { VehicleTypes.PartBoxSpec }?): number
	if not partBoxes or #partBoxes <= 1 then
		return size.Magnitude * 0.5
	end
	local maxR = 0
	for _, box in ipairs(partBoxes) do
		local r = box.LocalCFrame.Position.Magnitude + box.Size.Magnitude * 0.5
		if r > maxR then
			maxR = r
		end
	end
	return maxR
end

local function validatePlacementBoundsAndOverlap(
	candidateSpec: ConnectionMath.PieceGeometrySpec,
	existingPieces: { ConnectionMath.PieceGeometrySpec },
	spatialIndex: ConnectionMath.SpatialIndex?,
	buildZoneSize: Vector3?,
	maxZoneHeight: number?,
	assemblyOffset: { HeightOffset: number?, LateralOffset: number? }?
): (boolean, string?, string?)
	if buildZoneSize then
		local minBound, maxBound = ConnectionMath.ComputePieceLocalAABB(candidateSpec)
		local boundsOk, boundsReason = BuildGrid.ValidateBoundsMinMax(
			buildZoneSize,
			minBound,
			maxBound,
			maxZoneHeight,
			assemblyOffset
		)
		if not boundsOk then
			local errCode = if boundsReason == "BelowFloor" or boundsReason == "AboveCeiling" or boundsReason == "OutOfBoundsX" or boundsReason == "OutOfBoundsZ"
				then "OutOfBounds"
				else (boundsReason or "OutOfBounds")
			return false, errCode, nil
		end
	end

	local hasOverlap, overlappingPiece = ConnectionMath.AnyOverlap(
		candidateSpec,
		existingPieces,
		GameConfig.Building.OverlapTolerance,
		spatialIndex
	)
	if hasOverlap then
		return false, "PieceOverlap", if overlappingPiece then overlappingPiece.InstanceId else nil
	end

	return true, nil, nil
end

local function isSameLockTarget(lockState: FaceLockState?, targetPieceId: string, tFace: BoxFace, cFace: BoxFace): boolean
	if not lockState or lockState.TargetPieceId == nil then
		return false
	end
	return lockState.TargetPieceId == targetPieceId
		and lockState.TargetBoxIndex == tFace.BoxIndex
		and lockState.TargetFaceId == tFace.FaceId
		and lockState.CandidateBoxIndex == cFace.BoxIndex
		and lockState.CandidateFaceId == cFace.FaceId
end

--[=[
	Calcula el mejor ajuste cara con cara (`FaceSnap`) para el ghost en `BaseLocalCFrame`,
	preservando la rotación exacta del jugador, rechazando superposiciones o salidas de BuildZone
	y aplicando histéresis para estabilidad del cursor.
]=]
function FaceSnapMath.ComputeFaceSnap(input: FaceSnapInput): FaceSnapResult
	local baseCF = input.BaseLocalCFrame
	local basePos = baseCF.Position
	local baseRot = baseCF.Rotation

	local radius = input.MaxRadius or GameConfig.Building.FaceSnapRadius
	local hysteresis = input.Hysteresis or GameConfig.Building.FaceSnapHysteresis
	local minNormalDot = input.MinNormalDot or GameConfig.Building.FaceSnapMinNormalDot
	local minContactOverlap = input.MinContactOverlap or GameConfig.Building.FaceSnapMinContactOverlap
	local maxPassiveJump = input.MaxPassiveJump or GameConfig.Building.FaceSnapMaxPassiveJump

	local candSpecTemp: ConnectionMath.PieceGeometrySpec = {
		InstanceId = "__facesnap_query__",
		ItemId = input.CandidateItemId,
		LocalCFrame = baseCF,
		Size = input.CandidateSize,
		Attachments = input.CandidateAttachments,
		PartBoxes = input.CandidatePartBoxes,
	}
	ConnectionMath.PreparePieceSpec(candSpecTemp)
	local candHalfExt = candSpecTemp._HalfExtents :: Vector3

	local searchMargin = radius + hysteresis + 1.0
	local queryMin = basePos - candHalfExt - Vector3.new(searchMargin, searchMargin, searchMargin)
	local queryMax = basePos + candHalfExt + Vector3.new(searchMargin, searchMargin, searchMargin)

	local nearbyPieces: { ConnectionMath.PieceGeometrySpec }
	if input.SpatialIndex then
		nearbyPieces = input.SpatialIndex:QueryAABB(queryMin, queryMax)
	else
		nearbyPieces = input.ExistingPieces
	end

	-- Si el raycast apuntó a una pieza concreta que no quedó en la query por distancia tangencial, incluirla también
	if input.TargetPieceId and input.SpatialIndex then
		local foundTarget = false
		for _, p in ipairs(nearbyPieces) do
			if p.InstanceId == input.TargetPieceId then
				foundTarget = true
				break
			end
		end
		if not foundTarget then
			for _, p in ipairs(input.ExistingPieces) do
				if p.InstanceId == input.TargetPieceId then
					table.insert(nearbyPieces, p)
					break
				end
			end
		end
	end

	if #nearbyPieces == 0 then
		FaceSnapMath.ClearLockState(input.LockState)
		return {
			Matched = false,
			SnappedLocalCFrame = baseCF,
		}
	end

	local candFaces = FaceSnapMath.ExtractPieceFaces(baseCF, input.CandidateSize, input.CandidatePartBoxes)
	local candRadius = computeCandidateHalfRadius(input.CandidateSize, input.CandidatePartBoxes)

	local normRayDir: Vector3? = if input.RayDirectionLocal and input.RayDirectionLocal.Magnitude > 1e-4
		then input.RayDirectionLocal.Unit
		else nil
	local normSurfNormal: Vector3? = if input.SurfaceNormalLocal and input.SurfaceNormalLocal.Magnitude > 1e-4
		then input.SurfaceNormalLocal.Unit
		else nil

	type CandidatePair = {
		Score: number,
		TargetPieceId: string,
		TargetFace: BoxFace,
		CandFace: BoxFace,
		SnappedCF: CFrame,
		ContactPoint: Vector3,
		IsLocked: boolean,
	}

	local validPairs: { CandidatePair } = {}
	local bestInvalidTarget: FaceSnapVisualTarget? = nil
	local bestInvalidScore = math.huge
	local bestInvalidReason: string? = nil
	local bestInvalidOverlapPieceId: string? = nil

	for _, targetPiece in ipairs(nearbyPieces) do
		local isDirectHitPiece = input.TargetPieceId ~= nil and targetPiece.InstanceId == input.TargetPieceId
		local targetMaxRadius = radius + (if isDirectHitPiece then hysteresis + 0.5 else hysteresis)
		local targetExt = if targetPiece.PartBoxes and #targetPiece.PartBoxes > 1
			then computeCandidateHalfRadius(targetPiece.Size, targetPiece.PartBoxes)
			else targetPiece.Size.Magnitude * 0.5
		if (targetPiece.LocalCFrame.Position - basePos).Magnitude > candRadius + targetExt + targetMaxRadius + 2.0 then
			continue
		end

		local targetFaces = FaceSnapMath.ExtractPieceFaces(
			targetPiece.LocalCFrame,
			targetPiece.Size,
			targetPiece.PartBoxes
		)

		for _, tFace in ipairs(targetFaces) do
			local isDirectHitFace = isDirectHitPiece and normSurfNormal ~= nil and tFace.Normal:Dot(normSurfNormal) >= 0.85

			for _, cFace in ipairs(candFaces) do
				local dotNormal = cFace.Normal:Dot(tFace.Normal)
				if dotNormal <= minNormalDot then
					local lockedPair = isSameLockTarget(input.LockState, targetPiece.InstanceId, tFace, cFace)
					local effectiveRadius = radius + (if lockedPair then hysteresis else 0) + (if isDirectHitFace then 0.5 else 0)

					local signedGap = (cFace.Center - tFace.Center):Dot(tFace.Normal)
					local absGap = math.abs(signedGap)

					if absGap <= effectiveRadius then
						local shift = -tFace.Normal * signedGap
						local jumpDist = shift.Magnitude
						if isDirectHitFace or lockedPair or jumpDist <= maxPassiveJump then
							local snappedPos = basePos + shift
							local snappedCandFaceCenter = cFace.Center + shift

							-- Proyección del rectángulo de la cara candidata sobre la tangente U/V de la cara destino
							local candProjHalfU = math.abs(cFace.TangentU:Dot(tFace.TangentU)) * cFace.HalfU
								+ math.abs(cFace.TangentV:Dot(tFace.TangentU)) * cFace.HalfV
							local candProjHalfV = math.abs(cFace.TangentU:Dot(tFace.TangentV)) * cFace.HalfU
								+ math.abs(cFace.TangentV:Dot(tFace.TangentV)) * cFace.HalfV

							local deltaOnPlane = snappedCandFaceCenter - tFace.Center
							local distU = math.abs(deltaOnPlane:Dot(tFace.TangentU))
							local distV = math.abs(deltaOnPlane:Dot(tFace.TangentV))

							local overlapU = (tFace.HalfU + candProjHalfU) - distU
							local overlapV = (tFace.HalfV + candProjHalfV) - distV

							local reqOverlapU = math.min(minContactOverlap, candProjHalfU * 0.5, tFace.HalfU * 0.5)
							local reqOverlapV = math.min(minContactOverlap, candProjHalfV * 0.5, tFace.HalfV * 0.5)

							if overlapU >= reqOverlapU and overlapV >= reqOverlapV then
								local snappedCF = baseRot + snappedPos

								local testSpec: ConnectionMath.PieceGeometrySpec = {
									InstanceId = "__facesnap_cand__",
									ItemId = input.CandidateItemId,
									LocalCFrame = snappedCF,
									Size = input.CandidateSize,
									Attachments = input.CandidateAttachments,
									PartBoxes = input.CandidatePartBoxes,
								}
								ConnectionMath.PreparePieceSpec(testSpec)

								local score = absGap * 1.0
								if isDirectHitFace then
									score -= 0.75
								elseif isDirectHitPiece then
									score -= 0.15
								end

								if input.SurfaceHitLocal then
									local hitDist = (input.SurfaceHitLocal - snappedCandFaceCenter).Magnitude
									score += math.min(2.0, hitDist) * 0.12
								else
									score += math.sqrt(distU * distU + distV * distV) * 0.05
								end

								if normRayDir then
									local facing = tFace.Normal:Dot(-normRayDir)
									if facing > 0.15 then
										score -= facing * 0.12
									elseif facing < -0.25 and not lockedPair then
										-- Evitar elegir caras de espalda a la cámara cuando existe cara frontal equivalente
										score += 0.25
									end
								end

								local maxSpanU = math.max(0.1, tFace.HalfU + candProjHalfU)
								local maxSpanV = math.max(0.1, tFace.HalfV + candProjHalfV)
								local areaScore = (overlapU / maxSpanU) * (overlapV / maxSpanV)
								score -= areaScore * 0.06

								if lockedPair then
									score -= hysteresis
								end

								local contactMid = (tFace.Center + snappedCandFaceCenter) * 0.5
								local valid, failReason, overlapId = validatePlacementBoundsAndOverlap(
									testSpec,
									input.ExistingPieces,
									input.SpatialIndex,
									input.BuildZoneSize,
									input.MaxZoneHeight,
									input.AssemblyOffset
								)

								if valid then
									table.insert(validPairs, {
										Score = score,
										TargetPieceId = targetPiece.InstanceId,
										TargetFace = tFace,
										CandFace = cFace,
										SnappedCF = snappedCF,
										ContactPoint = contactMid,
										IsLocked = lockedPair,
									})
								elseif isDirectHitFace or absGap <= 0.35 then
									if score < bestInvalidScore then
										bestInvalidScore = score
										bestInvalidReason = failReason
										bestInvalidOverlapPieceId = overlapId
										bestInvalidTarget = {
											TargetPieceId = targetPiece.InstanceId,
											TargetFaceId = tFace.FaceId,
											TargetBoxIndex = tFace.BoxIndex,
											CandidateFaceId = cFace.FaceId,
											CandidateBoxIndex = cFace.BoxIndex,
											TargetFaceCenter = tFace.Center,
											TargetFaceNormal = tFace.Normal,
											TargetTangentU = tFace.TangentU,
											TargetTangentV = tFace.TangentV,
											TargetHalfU = tFace.HalfU,
											TargetHalfV = tFace.HalfV,
											ContactPoint = contactMid,
											IsValid = false,
											RejectReason = failReason,
										}
									end
								end
							end
						end
					end
				end
			end
		end
	end

	if #validPairs == 0 then
		FaceSnapMath.ClearLockState(input.LockState)
		return {
			Matched = false,
			SnappedLocalCFrame = baseCF,
			VisualTarget = bestInvalidTarget,
			RejectReason = bestInvalidReason,
			RejectedPieceId = bestInvalidOverlapPieceId,
		}
	end

	table.sort(validPairs, function(a, b)
		if math.abs(a.Score - b.Score) > 1e-4 then
			return a.Score < b.Score
		end
		if a.TargetPieceId ~= b.TargetPieceId then
			return a.TargetPieceId < b.TargetPieceId
		end
		if a.TargetFace.FaceId ~= b.TargetFace.FaceId then
			return a.TargetFace.FaceId < b.TargetFace.FaceId
		end
		return a.CandFace.FaceId < b.CandFace.FaceId
	end)

	local best = validPairs[1]
	if input.LockState then
		input.LockState.TargetPieceId = best.TargetPieceId
		input.LockState.TargetBoxIndex = best.TargetFace.BoxIndex
		input.LockState.TargetFaceId = best.TargetFace.FaceId
		input.LockState.CandidateBoxIndex = best.CandFace.BoxIndex
		input.LockState.CandidateFaceId = best.CandFace.FaceId
		input.LockState.LastSnappedPosition = best.SnappedCF.Position
	end

	return {
		Matched = true,
		SnappedLocalCFrame = best.SnappedCF,
		Score = best.Score,
		VisualTarget = {
			TargetPieceId = best.TargetPieceId,
			TargetFaceId = best.TargetFace.FaceId,
			TargetBoxIndex = best.TargetFace.BoxIndex,
			CandidateFaceId = best.CandFace.FaceId,
			CandidateBoxIndex = best.CandFace.BoxIndex,
			TargetFaceCenter = best.TargetFace.Center,
			TargetFaceNormal = best.TargetFace.Normal,
			TargetTangentU = best.TargetFace.TangentU,
			TargetTangentV = best.TargetFace.TangentV,
			TargetHalfU = best.TargetFace.HalfU,
			TargetHalfV = best.TargetFace.HalfV,
			ContactPoint = best.ContactPoint,
			IsValid = true,
			RejectReason = nil,
		},
	}
end

return FaceSnapMath

