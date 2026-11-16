--!strict
--[=[
	BuildAlignmentMath
	Matemática compartida y determinista de alineación y snap fino sobre superficies o ejes 1D:
	- Detecta alineaciones con ejes principales (X=0 / Z=0), centros de piezas, centros de caras,
	  bordes alineados, puntos de conexión `Conn_*` y contacto con superficies vecinas.
	- Aplica prioridades deterministas e histéresis para evitar saltos erráticos en bordes.
	- Genera segmentos y marcadores visuales informativos incluso cuando SmartSnap está desactivado.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local BuildTransformMath = require(ReplicatedStorage.Shared.Building.BuildTransformMath)
local ConnectionMath = require(ReplicatedStorage.Shared.Building.ConnectionMath)

export type AlignmentCategory =
	"Attachment"
	| "FaceCenter"
	| "PieceCenter"
	| "EdgeAlign"
	| "SurfaceContact"
	| "MainAxis"

export type AxisLock = {
	AxisKey: string,
	TargetCoord: number,
	Category: AlignmentCategory,
	Priority: number,
	TargetPieceId: string?,
}

export type AlignmentLockState = {
	LockU: AxisLock?,
	LockV: AxisLock?,
	Lock1D: AxisLock?,
}

export type AlignmentGuideSegment = {
	StartLocal: Vector3,
	EndLocal: Vector3,
	Category: AlignmentCategory,
	Color: Color3,
	Thickness: number,
	Label: string?,
}

export type AlignmentMarker = {
	PositionLocal: Vector3,
	Category: AlignmentCategory,
	Color: Color3,
	Radius: number,
}

export type AlignmentInput = {
	CandidateLocalCFrame: CFrame,
	CandidateItemId: string,
	CandidateSize: Vector3,
	CandidateAttachments: { ConnectionMath.AttachmentSpec },
	ExistingSpecs: { ConnectionMath.PieceGeometrySpec },
	SpatialIndex: ConnectionMath.SpatialIndex?,
	SurfaceNormalLocal: Vector3,
	SurfaceOriginLocal: Vector3?,
	FloorY: number?,
	PositionMode: ("Grid" | "Free")?,
	ExcludePieceId: string?,
	MoveAxisLocal: Vector3?,
	SmartSnapEnabled: boolean,
	GuidesEnabled: boolean?,
	ActiveLocks: AlignmentLockState?,
}

export type AlignmentResult = {
	FinalLocalCFrame: CFrame,
	WasSnapped: boolean,
	SmartSnapMatch: ConnectionMath.SmartSnapMatch?,
	SnappedCategories: { AlignmentCategory },
	Guides: { AlignmentGuideSegment },
	Markers: { AlignmentMarker },
	UpdatedLocks: AlignmentLockState,
}

local BuildAlignmentMath = {}

local PRIORITY_BY_CATEGORY: { [AlignmentCategory]: number } = {
	Attachment = 1,
	FaceCenter = 2,
	PieceCenter = 3,
	EdgeAlign = 4,
	SurfaceContact = 5,
	MainAxis = 6,
}

local MAX_GUIDE_SEGMENTS = 24
local MAX_MARKERS = 12

local function filterExistingExcluding(
	existingSpecs: { ConnectionMath.PieceGeometrySpec },
	excludeId: string?
): { ConnectionMath.PieceGeometrySpec }
	if not excludeId then
		return existingSpecs
	end
	local filtered = {}
	for _, spec in ipairs(existingSpecs) do
		if spec.InstanceId ~= excludeId then
			table.insert(filtered, spec)
		end
	end
	return filtered
end

local function collectNearbySpecs(
	center: Vector3,
	halfExtents: Vector3,
	radius: number,
	existingSpecs: { ConnectionMath.PieceGeometrySpec },
	spatialIndex: ConnectionMath.SpatialIndex?,
	excludeId: string?
): { ConnectionMath.PieceGeometrySpec }
	if #existingSpecs == 0 then
		return {}
	end
	if spatialIndex then
		local pad = Vector3.new(radius, radius, radius)
		return spatialIndex:QueryAABB(center - halfExtents - pad, center + halfExtents + pad, excludeId)
	end

	local out = {}
	for _, spec in ipairs(existingSpecs) do
		if spec.InstanceId ~= excludeId then
			local existPos = spec.LocalCFrame.Position
			local existHalf = BuildRotation.GetRotatedExtents(spec.Size, spec.LocalCFrame.Rotation) * 0.5
			if
				math.abs(center.X - existPos.X) <= halfExtents.X + existHalf.X + radius
				and math.abs(center.Y - existPos.Y) <= halfExtents.Y + existHalf.Y + radius
				and math.abs(center.Z - existPos.Z) <= halfExtents.Z + existHalf.Z + radius
			then
				table.insert(out, spec)
			end
		end
	end
	return out
end

type AxisCandidate = {
	TargetCoord: number,
	Category: AlignmentCategory,
	Priority: number,
	Delta: number,
	TargetPieceId: string?,
}

local function collectAxisCandidatesForDirection(
	basePos: Vector3,
	candHalf: Vector3,
	axisDir: Vector3,
	candWorldAtts: { ConnectionMath.WorldAttachmentSpec },
	nearby: { ConnectionMath.PieceGeometrySpec },
	candHalfAlong: number,
	snapTol: number,
	allowMainZero: boolean
): { AxisCandidate }
	local out: { AxisCandidate } = {}
	local baseCoord = basePos:Dot(axisDir)
	local surfTol = GameConfig.Building.SurfaceContactSnapTolerance

	if allowMainZero then
		local deltaZero = math.abs(baseCoord)
		if deltaZero <= snapTol then
			table.insert(out, {
				TargetCoord = 0,
				Category = "MainAxis",
				Priority = PRIORITY_BY_CATEGORY.MainAxis,
				Delta = deltaZero,
				TargetPieceId = nil,
			})
		end
	end

	for _, exist in ipairs(nearby) do
		local existPos = exist.LocalCFrame.Position
		local existHalf = BuildRotation.GetRotatedExtents(exist.Size, exist.LocalCFrame.Rotation) * 0.5
		local existCoord = existPos:Dot(axisDir)
		local existHalfAlong = math.abs(axisDir.X) * existHalf.X
			+ math.abs(axisDir.Y) * existHalf.Y
			+ math.abs(axisDir.Z) * existHalf.Z

		-- Centros de pieza y cara alineados sobre este eje
		local deltaCenter = math.abs(baseCoord - existCoord)
		if deltaCenter <= snapTol then
			local touchingPerp = (math.abs(basePos.X - existPos.X) <= candHalf.X + existHalf.X + 0.25)
				and (math.abs(basePos.Y - existPos.Y) <= candHalf.Y + existHalf.Y + 0.25)
				and (math.abs(basePos.Z - existPos.Z) <= candHalf.Z + existHalf.Z + 0.25)
			local cat: AlignmentCategory = if touchingPerp then "FaceCenter" else "PieceCenter"
			table.insert(out, {
				TargetCoord = existCoord,
				Category = cat,
				Priority = PRIORITY_BY_CATEGORY[cat],
				Delta = deltaCenter,
				TargetPieceId = exist.InstanceId,
			})
		end

		-- Bordes alineados (min-min, max-max)
		local alignMinMin = existCoord - existHalfAlong + candHalfAlong
		local deltaMinMin = math.abs(baseCoord - alignMinMin)
		if deltaMinMin <= snapTol then
			table.insert(out, {
				TargetCoord = alignMinMin,
				Category = "EdgeAlign",
				Priority = PRIORITY_BY_CATEGORY.EdgeAlign,
				Delta = deltaMinMin,
				TargetPieceId = exist.InstanceId,
			})
		end

		local alignMaxMax = existCoord + existHalfAlong - candHalfAlong
		local deltaMaxMax = math.abs(baseCoord - alignMaxMax)
		if deltaMaxMax <= snapTol then
			table.insert(out, {
				TargetCoord = alignMaxMax,
				Category = "EdgeAlign",
				Priority = PRIORITY_BY_CATEGORY.EdgeAlign,
				Delta = deltaMaxMax,
				TargetPieceId = exist.InstanceId,
			})
		end

		-- Contacto de borde/superficie contigua (min-max y max-min)
		local contactPos = existCoord + existHalfAlong + candHalfAlong
		local deltaContactPos = math.abs(baseCoord - contactPos)
		if deltaContactPos <= math.min(snapTol, surfTol) then
			table.insert(out, {
				TargetCoord = contactPos,
				Category = "SurfaceContact",
				Priority = PRIORITY_BY_CATEGORY.SurfaceContact,
				Delta = deltaContactPos,
				TargetPieceId = exist.InstanceId,
			})
		end

		local contactNeg = existCoord - existHalfAlong - candHalfAlong
		local deltaContactNeg = math.abs(baseCoord - contactNeg)
		if deltaContactNeg <= math.min(snapTol, surfTol) then
			table.insert(out, {
				TargetCoord = contactNeg,
				Category = "SurfaceContact",
				Priority = PRIORITY_BY_CATEGORY.SurfaceContact,
				Delta = deltaContactNeg,
				TargetPieceId = exist.InstanceId,
			})
		end

		-- Alineación directa de puntos Conn_* compatibles sobre este eje
		local existWorldAtts = ConnectionMath.ComputeWorldAttachments({
			InstanceId = exist.InstanceId,
			ItemId = exist.ItemId,
			LocalCFrame = exist.LocalCFrame,
			Size = exist.Size,
			Attachments = exist.Attachments,
		})
		for _, attCand in ipairs(candWorldAtts) do
			for _, attExist in ipairs(existWorldAtts) do
				if attCand.WorldNormal:Dot(attExist.WorldNormal) <= -0.7 then
					local shiftAlongAxis = (attExist.WorldPosition - attCand.WorldPosition):Dot(axisDir)
					local absShift = math.abs(shiftAlongAxis)
					if absShift <= snapTol then
						table.insert(out, {
							TargetCoord = baseCoord + shiftAlongAxis,
							Category = "Attachment",
							Priority = PRIORITY_BY_CATEGORY.Attachment,
							Delta = absShift,
							TargetPieceId = exist.InstanceId,
						})
					end
				end
			end
		end
	end

	return out
end

local function pickBestAxisCandidate(
	baseCoord: number,
	candidates: { AxisCandidate },
	prevLock: AxisLock?,
	axisKey: string,
	snapTol: number,
	hysteresis: number
): (number?, AxisLock?)
	if #candidates == 0 then
		if prevLock and math.abs(baseCoord - prevLock.TargetCoord) <= snapTol + hysteresis then
			return prevLock.TargetCoord, prevLock
		end
		return nil, nil
	end

	table.sort(candidates, function(a, b)
		if a.Priority ~= b.Priority then
			return a.Priority < b.Priority
		end
		if math.abs(a.Delta - b.Delta) > 1e-4 then
			return a.Delta < b.Delta
		end
		if math.abs(a.TargetCoord - b.TargetCoord) > 1e-4 then
			return a.TargetCoord < b.TargetCoord
		end
		return (a.TargetPieceId or "") < (b.TargetPieceId or "")
	end)

	local best = candidates[1]

	if prevLock then
		local prevDist = math.abs(baseCoord - prevLock.TargetCoord)
		if prevDist <= snapTol + hysteresis then
			local strictlyHigherPriority = best.Priority < prevLock.Priority
			local stronglyCloserSameOrBetter = best.Priority == prevLock.Priority
				and math.abs(best.TargetCoord - prevLock.TargetCoord) > 0.05
				and best.Delta < prevDist * 0.35
				and best.Delta < snapTol * 0.4

			if not strictlyHigherPriority and not stronglyCloserSameOrBetter then
				return prevLock.TargetCoord, prevLock
			end
		end
	end

	local newLock: AxisLock = {
		AxisKey = axisKey,
		TargetCoord = best.TargetCoord,
		Category = best.Category,
		Priority = best.Priority,
		TargetPieceId = best.TargetPieceId,
	}
	return best.TargetCoord, newLock
end

function BuildAlignmentMath.ComputeAlignments(input: AlignmentInput): AlignmentResult
	local baseCF = input.CandidateLocalCFrame
	local rot = if BuildRotation.IsOrthogonal90(baseCF.Rotation)
		then BuildRotation.Orthonormalize(baseCF.Rotation)
		else BuildRotation.OrthonormalizeGeneral(baseCF.Rotation)
	local basePos = baseCF.Position
	local candHalf = BuildRotation.GetRotatedExtents(input.CandidateSize, rot) * 0.5
	local activeLocks = input.ActiveLocks or {}
	local nextLocks: AlignmentLockState = {}

	local searchRadius = math.max(
		GameConfig.Building.SmartSnapRadius,
		GameConfig.Building.AlignmentGuideRadius,
		2.5
	)
	local nearby = collectNearbySpecs(
		basePos,
		candHalf,
		searchRadius,
		input.ExistingSpecs,
		input.SpatialIndex,
		input.ExcludePieceId
	)

	local candSpec: ConnectionMath.PieceGeometrySpec = ConnectionMath.PreparePieceSpec({
		InstanceId = input.ExcludePieceId or "__align_candidate__",
		ItemId = input.CandidateItemId,
		LocalCFrame = CFrame.new(basePos) * rot,
		Size = input.CandidateSize,
		Attachments = input.CandidateAttachments,
	})
	local candWorldAtts = ConnectionMath.ComputeWorldAttachments(candSpec)

	local finalCF = CFrame.new(basePos) * rot
	local wasSnapped = false
	local smartSnapMatch: ConnectionMath.SmartSnapMatch? = nil
	local snappedCategories: { AlignmentCategory } = {}

	local isFreeMode = input.PositionMode == GameConfig.Building.PositionModes.Free
	local fineSnapTol = if isFreeMode
		then GameConfig.Building.AlignmentSnapTolerance * 0.6
		else GameConfig.Building.AlignmentSnapTolerance
	local hysteresis = if isFreeMode
		then GameConfig.Building.AlignmentHysteresis * 0.6
		else GameConfig.Building.AlignmentHysteresis

	if input.SmartSnapEnabled then
		if input.MoveAxisLocal and input.MoveAxisLocal.Magnitude > 1e-4 then
			-- Modo gizmo de movimiento 1D: solo alinea a lo largo del eje arrastrado
			local moveDir = input.MoveAxisLocal.Unit
			local halfAlongMove = math.abs(moveDir.X) * candHalf.X
				+ math.abs(moveDir.Y) * candHalf.Y
				+ math.abs(moveDir.Z) * candHalf.Z
			local allowZero = math.abs(moveDir.Y) < 0.9
			local cands1D = collectAxisCandidatesForDirection(
				basePos,
				candHalf,
				moveDir,
				candWorldAtts,
				nearby,
				halfAlongMove,
				fineSnapTol,
				allowZero
			)
			local targetCoord, lock1D = pickBestAxisCandidate(
				basePos:Dot(moveDir),
				cands1D,
				activeLocks.Lock1D,
				"Move1D",
				fineSnapTol,
				hysteresis
			)
			nextLocks.Lock1D = lock1D
			if targetCoord ~= nil and lock1D ~= nil then
				local delta = targetCoord - basePos:Dot(moveDir)
				finalCF = CFrame.new(basePos + moveDir * delta) * rot
				wasSnapped = true
				table.insert(snappedCategories, lock1D.Category)
			end
		else
			-- Colocación sobre superficie (Grid o Free con SmartSnap ON)
			local filteredExisting = filterExistingExcluding(nearby, input.ExcludePieceId)
			local existingConns = if #filteredExisting > 0
				then ConnectionMath.FindCompatibleConnections(candSpec, filteredExisting)
				else {}

			if #existingConns == 0 and #filteredExisting > 0 then
				-- Pieza aún desconectada cerca de una estructura: intentar snap de conexión completo
				local match = ConnectionMath.ComputeSmartSnap(
					CFrame.new(basePos) * rot,
					input.CandidateSize,
					input.CandidateAttachments,
					input.ExistingSpecs,
					GameConfig.Building.SmartSnapRadius,
					input.FloorY,
					input.SpatialIndex,
					input.ExcludePieceId
				)
				if match then
					smartSnapMatch = match
					finalCF = match.SnappedLocalCFrame
					wasSnapped = true
					table.insert(snappedCategories, "Attachment")
				end
			else
				-- Ya apoya sobre superficie válida o está sola en BuildZone: aplicar snap fino determinista por ejes tangenciales U/V
				local tU, tV, sN = BuildTransformMath.ComputeSurfaceAxes(input.SurfaceNormalLocal)
				local halfAlongU = math.abs(tU.X) * candHalf.X + math.abs(tU.Y) * candHalf.Y + math.abs(tU.Z) * candHalf.Z
				local halfAlongV = math.abs(tV.X) * candHalf.X + math.abs(tV.Y) * candHalf.Y + math.abs(tV.Z) * candHalf.Z

				local allowZeroU = math.abs(tU.Y) < 0.9
				local allowZeroV = math.abs(tV.Y) < 0.9

				local candsU = collectAxisCandidatesForDirection(
					basePos,
					candHalf,
					tU,
					candWorldAtts,
					nearby,
					halfAlongU,
					fineSnapTol,
					allowZeroU
				)
				local candsV = collectAxisCandidatesForDirection(
					basePos,
					candHalf,
					tV,
					candWorldAtts,
					nearby,
					halfAlongV,
					fineSnapTol,
					allowZeroV
				)

				local targetU, lockU = pickBestAxisCandidate(basePos:Dot(tU), candsU, activeLocks.LockU, "U", fineSnapTol, hysteresis)
				local targetV, lockV = pickBestAxisCandidate(basePos:Dot(tV), candsV, activeLocks.LockV, "V", fineSnapTol, hysteresis)
				nextLocks.LockU = lockU
				nextLocks.LockV = lockV

				local offset = Vector3.zero
				if targetU ~= nil and lockU ~= nil then
					offset += tU * (targetU - basePos:Dot(tU))
					wasSnapped = true
					table.insert(snappedCategories, lockU.Category)
				end
				if targetV ~= nil and lockV ~= nil then
					offset += tV * (targetV - basePos:Dot(tV))
					wasSnapped = true
					table.insert(snappedCategories, lockV.Category)
				end

				-- Si hay una pieza adyacente en contacto lateral dentro de tolerancia sin overlap
				local adjustedPos = basePos + offset
				local candidateCheck: ConnectionMath.PieceGeometrySpec = ConnectionMath.PreparePieceSpec({
					InstanceId = candSpec.InstanceId,
					ItemId = input.CandidateItemId,
					LocalCFrame = CFrame.new(adjustedPos) * rot,
					Size = input.CandidateSize,
					Attachments = input.CandidateAttachments,
				})
				if #filteredExisting > 0 and ConnectionMath.AnyOverlap(candidateCheck, filteredExisting) then
					-- Evitar que un lock de eje empuje dentro de otra pieza
					offset = Vector3.zero
					wasSnapped = false
					table.clear(snappedCategories)
					nextLocks.LockU = nil
					nextLocks.LockV = nil
				else
					-- Mantener distancia respecto a normal de superficie intacta
					local nDelta = offset:Dot(sN)
					offset -= sN * nDelta
					finalCF = CFrame.new(basePos + offset) * rot
				end

				-- Si después del ajuste final la pieza ya cumple una conexión Conn_* explícita sin overlap, marcar Priority 1 activa
				local finalSpecCheck = ConnectionMath.PreparePieceSpec({
					InstanceId = candSpec.InstanceId,
					ItemId = input.CandidateItemId,
					LocalCFrame = finalCF,
					Size = input.CandidateSize,
					Attachments = input.CandidateAttachments,
				})
				local resolvedConns = ConnectionMath.FindCompatibleConnections(finalSpecCheck, filteredExisting)
				local explicitConn: VehicleTypes.BlueprintConnection? = nil
				for _, conn in ipairs(resolvedConns) do
					if string.sub(conn.FromAttachment, 1, 5) == "Conn_" and string.sub(conn.ToAttachment, 1, 5) == "Conn_" then
						explicitConn = conn
						break
					end
				end
				if explicitConn and not ConnectionMath.AnyOverlap(finalSpecCheck, filteredExisting) then
					smartSnapMatch = {
						SnappedLocalCFrame = finalCF,
						CandidateAttachment = explicitConn.FromAttachment,
						TargetPieceId = explicitConn.ToPieceId,
						TargetAttachment = explicitConn.ToAttachment,
						Distance = 0,
					}
					wasSnapped = true
					if not table.find(snappedCategories, "Attachment") then
						table.insert(snappedCategories, "Attachment")
					end
				end
			end
		end
	end

	-- Generar guías informativas (activas tanto con SmartSnap ON como OFF)
	local guides: { AlignmentGuideSegment } = {}
	local markers: { AlignmentMarker } = {}

	if input.GuidesEnabled ~= false then
		local fPos = finalCF.Position
		local guidePosTol = if input.SmartSnapEnabled then 0.08 else 0.14
		local candFinalSpec = ConnectionMath.PreparePieceSpec({
			InstanceId = candSpec.InstanceId,
			ItemId = input.CandidateItemId,
			LocalCFrame = finalCF,
			Size = input.CandidateSize,
			Attachments = input.CandidateAttachments,
		})
		local finalAtts = ConnectionMath.ComputeWorldAttachments(candFinalSpec)

		local function addGuide(startPos: Vector3, endPos: Vector3, cat: AlignmentCategory, col: Color3, thickness: number?, label: string?)
			if #guides >= MAX_GUIDE_SEGMENTS or (endPos - startPos).Magnitude < 0.05 then
				return
			end
			table.insert(guides, {
				StartLocal = startPos,
				EndLocal = endPos,
				Category = cat,
				Color = col,
				Thickness = thickness or 2.2,
				Label = label,
			})
		end

		local function addMarker(pos: Vector3, cat: AlignmentCategory, col: Color3, radius: number?)
			if #markers >= MAX_MARKERS then
				return
			end
			table.insert(markers, {
				PositionLocal = pos,
				Category = cat,
				Color = col,
				Radius = radius or 0.14,
			})
		end

		-- 1. Ejes principales X=0 / Z=0
		if math.abs(fPos.X) <= guidePosTol then
			local halfSpan = math.max(3, candHalf.Z + 1.5)
			addGuide(
				Vector3.new(0, fPos.Y, fPos.Z - halfSpan),
				Vector3.new(0, fPos.Y, fPos.Z + halfSpan),
				"MainAxis",
				GameConfig.Building.GizmoAxisZColor,
				2.5,
				"MainAxis_X0"
			)
		end
		if math.abs(fPos.Z) <= guidePosTol then
			local halfSpan = math.max(3, candHalf.X + 1.5)
			addGuide(
				Vector3.new(fPos.X - halfSpan, fPos.Y, 0),
				Vector3.new(fPos.X + halfSpan, fPos.Y, 0),
				"MainAxis",
				GameConfig.Building.GizmoAxisXColor,
				2.5,
				"MainAxis_Z0"
			)
		end

		-- 2. Guías contra piezas cercanas (centros, caras, bordes y puntos Conn_*)
		local attGuideRadius = GameConfig.Building.AlignmentGuideRadius
		for _, exist in ipairs(nearby) do
			local ePos = exist.LocalCFrame.Position
			local eHalf = BuildRotation.GetRotatedExtents(exist.Size, exist.LocalCFrame.Rotation) * 0.5

			local dx = math.abs(fPos.X - ePos.X)
			local dy = math.abs(fPos.Y - ePos.Y)
			local dz = math.abs(fPos.Z - ePos.Z)

			-- Alineación de centro en X o Z o Y
			if dx <= guidePosTol and (dz > 0.05 or dy > 0.05) then
				addGuide(fPos, ePos, "PieceCenter", GameConfig.Building.GuideCenterColor, 2.2, "CenterX")
				addMarker(ePos, "PieceCenter", GameConfig.Building.GuideCenterColor, 0.12)
			elseif dz <= guidePosTol and (dx > 0.05 or dy > 0.05) then
				addGuide(fPos, ePos, "PieceCenter", GameConfig.Building.GuideCenterColor, 2.2, "CenterZ")
				addMarker(ePos, "PieceCenter", GameConfig.Building.GuideCenterColor, 0.12)
			elseif dy <= guidePosTol and (dx > 0.05 or dz > 0.05) then
				addGuide(fPos, Vector3.new(ePos.X, fPos.Y, ePos.Z), "PieceCenter", GameConfig.Building.GuideCenterColor, 1.8, "LevelY")
			end

			-- Centro de cara en contacto directo (ej. viga centrada sobre bloque)
			if dx <= guidePosTol and dz <= guidePosTol and math.abs(dy - (candHalf.Y + eHalf.Y)) <= 0.12 then
				local contactFacePos = Vector3.new(ePos.X, (fPos.Y + ePos.Y) * 0.5, ePos.Z)
				addMarker(contactFacePos, "FaceCenter", GameConfig.Building.GuideCenterColor, 0.16)
				local cross = math.max(candHalf.X, candHalf.Z) + 0.5
				addGuide(
					contactFacePos - Vector3.new(cross, 0, 0),
					contactFacePos + Vector3.new(cross, 0, 0),
					"FaceCenter",
					GameConfig.Building.GuideCenterColor,
					2.4,
					"FaceCenterX"
				)
				addGuide(
					contactFacePos - Vector3.new(0, 0, cross),
					contactFacePos + Vector3.new(0, 0, cross),
					"FaceCenter",
					GameConfig.Building.GuideCenterColor,
					2.4,
					"FaceCenterZ"
				)
			end

			-- Bordes alineados (min/max X y min/max Z)
			local candMinX, candMaxX = fPos.X - candHalf.X, fPos.X + candHalf.X
			local exMinX, exMaxX = ePos.X - eHalf.X, ePos.X + eHalf.X
			if math.abs(candMinX - exMinX) <= guidePosTol or math.abs(candMinX - exMaxX) <= guidePosTol then
				addGuide(
					Vector3.new(candMinX, fPos.Y, math.min(fPos.Z, ePos.Z) - 1),
					Vector3.new(candMinX, fPos.Y, math.max(fPos.Z, ePos.Z) + 1),
					"EdgeAlign",
					GameConfig.Building.GuideEdgeColor,
					1.8,
					"EdgeMinX"
				)
			end
			if math.abs(candMaxX - exMaxX) <= guidePosTol or math.abs(candMaxX - exMinX) <= guidePosTol then
				addGuide(
					Vector3.new(candMaxX, fPos.Y, math.min(fPos.Z, ePos.Z) - 1),
					Vector3.new(candMaxX, fPos.Y, math.max(fPos.Z, ePos.Z) + 1),
					"EdgeAlign",
					GameConfig.Building.GuideEdgeColor,
					1.8,
					"EdgeMaxX"
				)
			end

			local candMinZ, candMaxZ = fPos.Z - candHalf.Z, fPos.Z + candHalf.Z
			local exMinZ, exMaxZ = ePos.Z - eHalf.Z, ePos.Z + eHalf.Z
			if math.abs(candMinZ - exMinZ) <= guidePosTol or math.abs(candMinZ - exMaxZ) <= guidePosTol then
				addGuide(
					Vector3.new(math.min(fPos.X, ePos.X) - 1, fPos.Y, candMinZ),
					Vector3.new(math.max(fPos.X, ePos.X) + 1, fPos.Y, candMinZ),
					"EdgeAlign",
					GameConfig.Building.GuideEdgeColor,
					1.8,
					"EdgeMinZ"
				)
			end
			if math.abs(candMaxZ - exMaxZ) <= guidePosTol or math.abs(candMaxZ - exMinZ) <= guidePosTol then
				addGuide(
					Vector3.new(math.min(fPos.X, ePos.X) - 1, fPos.Y, candMaxZ),
					Vector3.new(math.max(fPos.X, ePos.X) + 1, fPos.Y, candMaxZ),
					"EdgeAlign",
					GameConfig.Building.GuideEdgeColor,
					1.8,
					"EdgeMaxZ"
				)
			end

			-- Guías de conexión Conn_*
			local existAtts = ConnectionMath.ComputeWorldAttachments({
				InstanceId = exist.InstanceId,
				ItemId = exist.ItemId,
				LocalCFrame = exist.LocalCFrame,
				Size = exist.Size,
				Attachments = exist.Attachments,
			})
			local bestPairDist = math.huge
			local bestCandPos: Vector3? = nil
			local bestExistPos: Vector3? = nil
			for _, aC in ipairs(finalAtts) do
				for _, aE in ipairs(existAtts) do
					if aC.WorldNormal:Dot(aE.WorldNormal) <= -0.7 then
						local d = (aC.WorldPosition - aE.WorldPosition).Magnitude
						if d <= attGuideRadius and d < bestPairDist then
							bestPairDist = d
							bestCandPos = aC.WorldPosition
							bestExistPos = aE.WorldPosition
						end
					end
				end
			end
			if bestCandPos and bestExistPos then
				addMarker(bestExistPos, "Attachment", GameConfig.Building.GuideAttachmentColor, 0.15)
				if bestPairDist > 0.05 then
					addGuide(
						bestCandPos,
						bestExistPos,
						"Attachment",
						GameConfig.Building.GuideAttachmentColor,
						2.4,
						"ConnPair"
					)
				end
			end
		end
	end

	return {
		FinalLocalCFrame = finalCF,
		WasSnapped = wasSnapped,
		SmartSnapMatch = smartSnapMatch,
		SnappedCategories = snappedCategories,
		Guides = guides,
		Markers = markers,
		UpdatedLocks = nextLocks,
	}
end

return BuildAlignmentMath
