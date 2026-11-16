--!strict
--[=[
	ConnectionMath
	Matemática compartida (cliente y servidor) para extracción de attachments `Conn_*`,
	índice espacial AABB por celdas, detección de conexiones compatibles, snap inteligente
	entre piezas, detección de superposiciones AABB y verificación de conectividad del grafo.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type AttachmentSpec = {
	Name: string,
	LocalPosition: Vector3, -- Relativo al PrimaryPart de la pieza
	LocalNormal: Vector3, -- Vector normal unitario saliente en el espacio local de la pieza
}

export type WorldAttachmentSpec = {
	Name: string,
	WorldPosition: Vector3, -- Relativo al espacio local de BuildZone
	WorldNormal: Vector3,
}

export type PieceGeometrySpec = {
	InstanceId: string,
	ItemId: string,
	LocalCFrame: CFrame, -- En espacio local de BuildZone
	Size: Vector3,
	Attachments: { AttachmentSpec },
	PartBoxes: { VehicleTypes.PartBoxSpec }?,
	_HalfExtents: Vector3?,
	_WorldAttachments: { WorldAttachmentSpec }?,
}

export type SmartSnapMatch = {
	SnappedLocalCFrame: CFrame,
	CandidateAttachment: string,
	TargetPieceId: string,
	TargetAttachment: string,
	Distance: number,
}

export type SpatialIndex = {
	CellSize: number,
	Insert: (self: SpatialIndex, spec: PieceGeometrySpec) -> (),
	Remove: (self: SpatialIndex, instanceId: string) -> boolean,
	QueryAABB: (self: SpatialIndex, minBound: Vector3, maxBound: Vector3, excludeId: string?) -> { PieceGeometrySpec },
	GetAll: (self: SpatialIndex) -> { PieceGeometrySpec },
	Count: (self: SpatialIndex) -> number,
	Clear: (self: SpatialIndex) -> (),
}

local ConnectionMath = {}

local CELL_COORD_BIAS = 512
local CELL_STRIDE_Y = 1024
local CELL_STRIDE_Z = 1048576

local function hashCell(cx: number, cy: number, cz: number): number | string
	if
		cx >= -CELL_COORD_BIAS
		and cx < CELL_COORD_BIAS
		and cy >= -CELL_COORD_BIAS
		and cy < CELL_COORD_BIAS
		and cz >= -CELL_COORD_BIAS
		and cz < CELL_COORD_BIAS
	then
		return (cx + CELL_COORD_BIAS) + (cy + CELL_COORD_BIAS) * CELL_STRIDE_Y + (cz + CELL_COORD_BIAS) * CELL_STRIDE_Z
	end
	return `{cx},{cy},{cz}`
end

local function computeOutwardNormal(localPos: Vector3, partSize: Vector3): Vector3
	local hx = math.max(0.01, partSize.X * 0.5)
	local hy = math.max(0.01, partSize.Y * 0.5)
	local hz = math.max(0.01, partSize.Z * 0.5)

	local nx = localPos.X / hx
	local ny = localPos.Y / hy
	local nz = localPos.Z / hz

	local ax = math.abs(nx)
	local ay = math.abs(ny)
	local az = math.abs(nz)

	if ax >= ay and ax >= az then
		return Vector3.new(if nx >= 0 then 1 else -1, 0, 0)
	elseif ay >= ax and ay >= az then
		return Vector3.new(0, if ny >= 0 then 1 else -1, 0)
	else
		return Vector3.new(0, 0, if nz >= 0 then 1 else -1)
	end
end

local function hasCompositePartBoxes(spec: PieceGeometrySpec): boolean
	local boxes = spec.PartBoxes
	if not boxes or #boxes == 0 then
		return false
	end
	if #boxes > 1 then
		return true
	end
	local first = boxes[1]
	return first.LocalCFrame ~= CFrame.identity
end

local function computeCompositeBoundsInSpace(
	cf: CFrame,
	size: Vector3,
	partBoxes: { VehicleTypes.PartBoxSpec }?
): (Vector3, Vector3)
	if not partBoxes or #partBoxes == 0 then
		local half = BuildRotation.GetRotatedExtents(size, cf.Rotation) * 0.5
		return cf.Position - half, cf.Position + half
	end

	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, box in ipairs(partBoxes) do
		local worldBoxCF = cf * box.LocalCFrame
		local boxHalf = BuildRotation.GetRotatedExtents(box.Size, worldBoxCF.Rotation) * 0.5
		local pos = worldBoxCF.Position
		if pos.X - boxHalf.X < minX then
			minX = pos.X - boxHalf.X
		end
		if pos.Y - boxHalf.Y < minY then
			minY = pos.Y - boxHalf.Y
		end
		if pos.Z - boxHalf.Z < minZ then
			minZ = pos.Z - boxHalf.Z
		end
		if pos.X + boxHalf.X > maxX then
			maxX = pos.X + boxHalf.X
		end
		if pos.Y + boxHalf.Y > maxY then
			maxY = pos.Y + boxHalf.Y
		end
		if pos.Z + boxHalf.Z > maxZ then
			maxZ = pos.Z + boxHalf.Z
		end
	end

	return Vector3.new(minX, minY, minZ), Vector3.new(maxX, maxY, maxZ)
end

local function ensureHalfExtents(spec: PieceGeometrySpec): Vector3
	local cached = spec._HalfExtents
	if cached then
		return cached
	end

	local half: Vector3
	if hasCompositePartBoxes(spec) then
		local minBound, maxBound = computeCompositeBoundsInSpace(spec.LocalCFrame, spec.Size, spec.PartBoxes)
		local pos = spec.LocalCFrame.Position
		half = Vector3.new(
			math.max(math.abs(minBound.X - pos.X), math.abs(maxBound.X - pos.X)),
			math.max(math.abs(minBound.Y - pos.Y), math.abs(maxBound.Y - pos.Y)),
			math.max(math.abs(minBound.Z - pos.Z), math.abs(maxBound.Z - pos.Z))
		)
	else
		half = BuildRotation.GetRotatedExtents(spec.Size, spec.LocalCFrame.Rotation) * 0.5
	end

	spec._HalfExtents = half
	return half
end

--[=[
	Devuelve las sub-cajas OBB locales de una pieza (`PartBoxes` si es compuesta o una sola caja del PrimaryPart).
]=]
function ConnectionMath.GetEffectivePartBoxes(spec: PieceGeometrySpec): { VehicleTypes.PartBoxSpec }
	if spec.PartBoxes and #spec.PartBoxes > 0 then
		return spec.PartBoxes
	end
	return {
		{
			LocalCFrame = CFrame.identity,
			Size = spec.Size,
		},
	}
end

--[=[
	Calcula el AABB real en el espacio de BuildZone de una pieza (soportando geometrías compuestas multi-BasePart).
]=]
function ConnectionMath.ComputePieceLocalAABB(spec: PieceGeometrySpec): (Vector3, Vector3)
	return computeCompositeBoundsInSpace(spec.LocalCFrame, spec.Size, spec.PartBoxes)
end

local function ensureWorldAttachments(spec: PieceGeometrySpec): { WorldAttachmentSpec }
	local cached = spec._WorldAttachments
	if cached then
		return cached
	end
	local cf = spec.LocalCFrame
	local list: { WorldAttachmentSpec } = table.create(#spec.Attachments)
	for i, att in ipairs(spec.Attachments) do
		list[i] = {
			Name = att.Name,
			WorldPosition = cf:PointToWorldSpace(att.LocalPosition),
			WorldNormal = cf:VectorToWorldSpace(att.LocalNormal),
		}
	end
	spec._WorldAttachments = list
	return list
end

--[=[
	Precalcula y almacena en caché en el propio `PieceGeometrySpec` los semiejes rotados
	y las posiciones/normales de sus attachments en el espacio de BuildZone.
]=]
function ConnectionMath.PreparePieceSpec(spec: PieceGeometrySpec): PieceGeometrySpec
	ensureHalfExtents(spec)
	ensureWorldAttachments(spec)
	return spec
end

function ConnectionMath.ComputeWorldAttachments(spec: PieceGeometrySpec): { WorldAttachmentSpec }
	return ensureWorldAttachments(spec)
end

--[=[
	Crea un índice espacial hash 3D por celdas para acelerar búsquedas de proximidad
	en vehículos de hasta 200+ piezas sin alterar las reglas exactas de geometría.
]=]
function ConnectionMath.CreateSpatialIndex(cellSize: number?): SpatialIndex
	local step = cellSize or GameConfig.Building.SpatialCellSize
	local buckets: { [number | string]: { PieceGeometrySpec } } = {}
	local pieceCellsById: { [string]: { number | string } } = {}
	local piecesById: { [string]: PieceGeometrySpec } = {}
	local seenStampBySpec: { [PieceGeometrySpec]: number } = {}
	local stamp = 0
	local count = 0

	local index = {} :: SpatialIndex
	index.CellSize = step

	function index:Remove(instanceId: string): boolean
		local existing = piecesById[instanceId]
		if not existing then
			return false
		end
		local cellKeys = pieceCellsById[instanceId]
		if cellKeys then
			for _, key in ipairs(cellKeys) do
				local bucket = buckets[key]
				if bucket then
					local pos = table.find(bucket, existing)
					if pos then
						local last = #bucket
						bucket[pos] = bucket[last]
						bucket[last] = nil
						if #bucket == 0 then
							buckets[key] = nil
						end
					end
				end
			end
		end
		pieceCellsById[instanceId] = nil
		piecesById[instanceId] = nil
		seenStampBySpec[existing] = nil
		count -= 1
		return true
	end

	function index:Insert(spec: PieceGeometrySpec)
		if piecesById[spec.InstanceId] then
			self:Remove(spec.InstanceId)
		end

		ConnectionMath.PreparePieceSpec(spec)
		local pos = spec.LocalCFrame.Position
		local half = spec._HalfExtents :: Vector3

		local minCX = math.floor((pos.X - half.X) / step)
		local maxCX = math.floor((pos.X + half.X) / step)
		local minCY = math.floor((pos.Y - half.Y) / step)
		local maxCY = math.floor((pos.Y + half.Y) / step)
		local minCZ = math.floor((pos.Z - half.Z) / step)
		local maxCZ = math.floor((pos.Z + half.Z) / step)

		local cellKeys: { number | string } = {}
		for cx = minCX, maxCX do
			for cy = minCY, maxCY do
				for cz = minCZ, maxCZ do
					local key = hashCell(cx, cy, cz)
					local bucket = buckets[key]
					if not bucket then
						bucket = {}
						buckets[key] = bucket
					end
					table.insert(bucket, spec)
					table.insert(cellKeys, key)
				end
			end
		end

		piecesById[spec.InstanceId] = spec
		pieceCellsById[spec.InstanceId] = cellKeys
		count += 1
	end

	function index:QueryAABB(minBound: Vector3, maxBound: Vector3, excludeId: string?): { PieceGeometrySpec }
		local results: { PieceGeometrySpec } = {}
		if count == 0 then
			return results
		end

		stamp += 1
		local currentStamp = stamp

		local minCX = math.floor(minBound.X / step)
		local maxCX = math.floor(maxBound.X / step)
		local minCY = math.floor(minBound.Y / step)
		local maxCY = math.floor(maxBound.Y / step)
		local minCZ = math.floor(minBound.Z / step)
		local maxCZ = math.floor(maxBound.Z / step)

		for cx = minCX, maxCX do
			for cy = minCY, maxCY do
				for cz = minCZ, maxCZ do
					local bucket = buckets[hashCell(cx, cy, cz)]
					if bucket then
						for _, spec in ipairs(bucket) do
							if spec.InstanceId ~= excludeId and seenStampBySpec[spec] ~= currentStamp then
								seenStampBySpec[spec] = currentStamp
								table.insert(results, spec)
							end
						end
					end
				end
			end
		end

		return results
	end

	function index:GetAll(): { PieceGeometrySpec }
		local list: { PieceGeometrySpec } = table.create(count)
		for _, spec in pairs(piecesById) do
			table.insert(list, spec)
		end
		return list
	end

	function index:Count(): number
		return count
	end

	function index:Clear()
		table.clear(buckets)
		table.clear(pieceCellsById)
		table.clear(piecesById)
		table.clear(seenStampBySpec)
		count = 0
		stamp = 0
	end

	return index
end

--[=[
	Extrae las especificaciones de attachments `Conn_*`, el tamaño del PrimaryPart,
	todas las sub-cajas OBB físicas (`PartBoxes`) y los límites locales reales de un modelo.
]=]
function ConnectionMath.ExtractModelGeometry(
	model: Model
): ({ AttachmentSpec }, Vector3, { VehicleTypes.PartBoxSpec }, Vector3, Vector3)
	local primary = model.PrimaryPart or model:FindFirstChild("Primary") :: BasePart? or model:FindFirstChildWhichIsA("BasePart", true)
	if not primary then
		local defaultSize = Vector3.new(2, 2, 2)
		return {}, defaultSize, { { LocalCFrame = CFrame.identity, Size = defaultSize } }, -defaultSize * 0.5, defaultSize * 0.5
	end

	local partSize = primary.Size
	local primaryCF = primary.CFrame
	local specs: { AttachmentSpec } = {}
	local partBoxes: { VehicleTypes.PartBoxSpec } = {}

	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(partBoxes, {
				LocalCFrame = primaryCF:ToObjectSpace(descendant.CFrame),
				Size = descendant.Size,
			})
		elseif descendant:IsA("Attachment") and string.sub(descendant.Name, 1, #GameConfig.ConnectionPrefix) == GameConfig.ConnectionPrefix then
			local worldPos = descendant.WorldCFrame.Position
			local relPos = primaryCF:PointToObjectSpace(worldPos)
			local normal = computeOutwardNormal(relPos, partSize)
			table.insert(specs, {
				Name = descendant.Name,
				LocalPosition = relPos,
				LocalNormal = normal,
			})
		end
	end

	if #partBoxes == 0 then
		table.insert(partBoxes, {
			LocalCFrame = CFrame.identity,
			Size = partSize,
		})
	end

	table.sort(specs, function(a, b)
		return a.Name < b.Name
	end)

	local boundsMin, boundsMax = computeCompositeBoundsInSpace(CFrame.identity, partSize, partBoxes)
	return specs, partSize, partBoxes, boundsMin, boundsMax
end

--[=[
	Extrae las especificaciones de todos los Attachments `Conn_*` de un modelo respecto a su PrimaryPart.
]=]
function ConnectionMath.ExtractModelAttachments(model: Model): ({ AttachmentSpec }, Vector3)
	local specs, partSize = ConnectionMath.ExtractModelGeometry(model)
	return specs, partSize
end

local function isAxisAligned90(cf: CFrame): boolean
	local r = cf.RightVector
	local u = cf.UpVector
	local maxR = math.max(math.abs(r.X), math.abs(r.Y), math.abs(r.Z))
	local maxU = math.max(math.abs(u.X), math.abs(u.Y), math.abs(u.Z))
	return maxR >= 0.999 and maxU >= 0.999
end

local function obbAxesOverlap(
	posA: Vector3,
	cfA: CFrame,
	sizeA: Vector3,
	posB: Vector3,
	cfB: CFrame,
	sizeB: Vector3,
	tol: number
): boolean
	local halfLocalA = Vector3.new(
		math.max(0.01, sizeA.X * 0.5 - tol * 0.5),
		math.max(0.01, sizeA.Y * 0.5 - tol * 0.5),
		math.max(0.01, sizeA.Z * 0.5 - tol * 0.5)
	)
	local halfLocalB = Vector3.new(
		math.max(0.01, sizeB.X * 0.5 - tol * 0.5),
		math.max(0.01, sizeB.Y * 0.5 - tol * 0.5),
		math.max(0.01, sizeB.Z * 0.5 - tol * 0.5)
	)

	local ax = { cfA.RightVector, cfA.UpVector, -cfA.LookVector }
	local bx = { cfB.RightVector, cfB.UpVector, -cfB.LookVector }
	local extA = { halfLocalA.X, halfLocalA.Y, halfLocalA.Z }
	local extB = { halfLocalB.X, halfLocalB.Y, halfLocalB.Z }
	local delta = posB - posA

	local R11, R12, R13 = ax[1]:Dot(bx[1]), ax[1]:Dot(bx[2]), ax[1]:Dot(bx[3])
	local R21, R22, R23 = ax[2]:Dot(bx[1]), ax[2]:Dot(bx[2]), ax[2]:Dot(bx[3])
	local R31, R32, R33 = ax[3]:Dot(bx[1]), ax[3]:Dot(bx[2]), ax[3]:Dot(bx[3])
	local R = {
		{ R11, R12, R13 },
		{ R21, R22, R23 },
		{ R31, R32, R33 },
	}
	local AbsR = {
		{ math.abs(R11) + 1e-5, math.abs(R12) + 1e-5, math.abs(R13) + 1e-5 },
		{ math.abs(R21) + 1e-5, math.abs(R22) + 1e-5, math.abs(R23) + 1e-5 },
		{ math.abs(R31) + 1e-5, math.abs(R32) + 1e-5, math.abs(R33) + 1e-5 },
	}

	local t = { delta:Dot(ax[1]), delta:Dot(ax[2]), delta:Dot(ax[3]) }

	-- 3 ejes de A
	for i = 1, 3 do
		local ra = extA[i]
		local rb = extB[1] * AbsR[i][1] + extB[2] * AbsR[i][2] + extB[3] * AbsR[i][3]
		if math.abs(t[i]) >= ra + rb then
			return false
		end
	end

	-- 3 ejes de B
	for j = 1, 3 do
		local ra = extA[1] * AbsR[1][j] + extA[2] * AbsR[2][j] + extA[3] * AbsR[3][j]
		local rb = extB[j]
		local proj = t[1] * R[1][j] + t[2] * R[2][j] + t[3] * R[3][j]
		if math.abs(proj) >= ra + rb then
			return false
		end
	end

	-- 9 ejes producto cruz A_i x B_j
	for i = 1, 3 do
		local i1 = (i % 3) + 1
		local i2 = ((i + 1) % 3) + 1
		for j = 1, 3 do
			local j1 = (j % 3) + 1
			local j2 = ((j + 1) % 3) + 1
			local ra = extA[i1] * AbsR[i2][j] + extA[i2] * AbsR[i1][j]
			local rb = extB[j1] * AbsR[i][j2] + extB[j2] * AbsR[i][j1]
			local proj = math.abs(t[i2] * R[i1][j] - t[i1] * R[i2][j])
			if proj >= ra + rb then
				return false
			end
		end
	end

	return true
end

local function fastBoxesOverlap(
	posA: Vector3,
	halfA: Vector3,
	posB: Vector3,
	halfB: Vector3,
	tol: number
): boolean
	local dx = math.abs(posA.X - posB.X)
	if dx >= halfA.X + halfB.X - tol then
		return false
	end
	local dy = math.abs(posA.Y - posB.Y)
	if dy >= halfA.Y + halfB.Y - tol then
		return false
	end
	local dz = math.abs(posA.Z - posB.Z)
	return dz < halfA.Z + halfB.Z - tol
end

--[=[
	Comprueba si dos cajas orientadas (OBB con camino rápido AABB para rotaciones ortogonales de 90°)
	se superponen por más de `tolerance`.
]=]
function ConnectionMath.BoxesOverlap(
	cframeA: CFrame,
	sizeA: Vector3,
	cframeB: CFrame,
	sizeB: Vector3,
	tolerance: number?
): boolean
	local tol = tolerance or GameConfig.Building.OverlapTolerance
	local halfA = BuildRotation.GetRotatedExtents(sizeA, cframeA.Rotation) * 0.5
	local halfB = BuildRotation.GetRotatedExtents(sizeB, cframeB.Rotation) * 0.5
	if not fastBoxesOverlap(cframeA.Position, halfA, cframeB.Position, halfB, tol) then
		return false
	end
	if isAxisAligned90(cframeA) and isAxisAligned90(cframeB) then
		return true
	end
	return obbAxesOverlap(cframeA.Position, cframeA, sizeA, cframeB.Position, cframeB, sizeB, tol)
end

local function singleSpecsOverlap(
	specA: PieceGeometrySpec,
	specB: PieceGeometrySpec,
	tol: number
): boolean
	if not hasCompositePartBoxes(specA) and not hasCompositePartBoxes(specB) then
		if isAxisAligned90(specA.LocalCFrame) and isAxisAligned90(specB.LocalCFrame) then
			return true
		end
		return obbAxesOverlap(
			specA.LocalCFrame.Position,
			specA.LocalCFrame,
			specA.Size,
			specB.LocalCFrame.Position,
			specB.LocalCFrame,
			specB.Size,
			tol
		)
	end

	local boxesA = ConnectionMath.GetEffectivePartBoxes(specA)
	local boxesB = ConnectionMath.GetEffectivePartBoxes(specB)
	for _, boxA in ipairs(boxesA) do
		local worldCFA = specA.LocalCFrame * boxA.LocalCFrame
		for _, boxB in ipairs(boxesB) do
			local worldCFB = specB.LocalCFrame * boxB.LocalCFrame
			if ConnectionMath.BoxesOverlap(worldCFA, boxA.Size, worldCFB, boxB.Size, tol) then
				return true
			end
		end
	end
	return false
end

--[=[
	Comprueba si dos especificaciones geométricas de piezas se superponen (soporta geometrías compuestas multi-BasePart).
]=]
function ConnectionMath.SpecsOverlap(
	specA: PieceGeometrySpec,
	specB: PieceGeometrySpec,
	tolerance: number?
): boolean
	local tol = tolerance or GameConfig.Building.OverlapTolerance
	local halfA = ensureHalfExtents(specA)
	local halfB = ensureHalfExtents(specB)
	if not fastBoxesOverlap(specA.LocalCFrame.Position, halfA, specB.LocalCFrame.Position, halfB, tol) then
		return false
	end
	return singleSpecsOverlap(specA, specB, tol)
end

--[=[
	Comprueba rápidamente si un candidato se superpone con alguna pieza existente,
	utilizando filtro previo AABB o un SpatialIndex si se provee (y SAT exacto / sub-OBBs en rotaciones o piezas compuestas).
]=]
function ConnectionMath.AnyOverlap(
	candidate: PieceGeometrySpec,
	existingPieces: { PieceGeometrySpec },
	tolerance: number?,
	spatialIndex: SpatialIndex?
): (boolean, PieceGeometrySpec?)
	local tol = tolerance or GameConfig.Building.OverlapTolerance
	local candHalf = ensureHalfExtents(candidate)
	local candPos = candidate.LocalCFrame.Position

	local candidates = if spatialIndex
		then spatialIndex:QueryAABB(candPos - candHalf, candPos + candHalf, candidate.InstanceId)
		else existingPieces

	for _, existing in ipairs(candidates) do
		if existing.InstanceId ~= candidate.InstanceId then
			local existHalf = ensureHalfExtents(existing)
			if fastBoxesOverlap(candPos, candHalf, existing.LocalCFrame.Position, existHalf, tol) then
				if singleSpecsOverlap(candidate, existing, tol) then
					return true, existing
				end
			end
		end
	end

	return false, nil
end

type OBBFace = {
	FaceId: string,
	BoxCenter: Vector3,
	Center: Vector3,
	Normal: Vector3,
	TangentU: Vector3,
	TangentV: Vector3,
	HalfU: number,
	HalfV: number,
}

local function extractBoxFaces(boxWorldCF: CFrame, size: Vector3): { OBBFace }
	local pos = boxWorldCF.Position
	local right = boxWorldCF.RightVector
	local up = boxWorldCF.UpVector
	local forward = boxWorldCF.LookVector -- -Z en local space de Roblox
	local back = -forward -- +Z en local space de Roblox
	local hx = size.X * 0.5
	local hy = size.Y * 0.5
	local hz = size.Z * 0.5

	return {
		{ FaceId = "+X", BoxCenter = pos, Center = pos + right * hx, Normal = right, TangentU = up, TangentV = back, HalfU = hy, HalfV = hz },
		{ FaceId = "-X", BoxCenter = pos, Center = pos - right * hx, Normal = -right, TangentU = up, TangentV = back, HalfU = hy, HalfV = hz },
		{ FaceId = "+Y", BoxCenter = pos, Center = pos + up * hy, Normal = up, TangentU = right, TangentV = back, HalfU = hx, HalfV = hz },
		{ FaceId = "-Y", BoxCenter = pos, Center = pos - up * hy, Normal = -up, TangentU = right, TangentV = back, HalfU = hx, HalfV = hz },
		{ FaceId = "+Z", BoxCenter = pos, Center = pos + back * hz, Normal = back, TangentU = right, TangentV = up, HalfU = hx, HalfV = hy },
		{ FaceId = "-Z", BoxCenter = pos, Center = pos - back * hz, Normal = -back, TangentU = right, TangentV = up, HalfU = hx, HalfV = hy },
	}
end

local function projectFaceRectOverlap(faceA: OBBFace, faceB: OBBFace): (number, number)
	local delta = faceB.Center - faceA.Center
	local cU = delta:Dot(faceA.TangentU)
	local rUB = math.abs(faceB.TangentU:Dot(faceA.TangentU)) * faceB.HalfU
		+ math.abs(faceB.TangentV:Dot(faceA.TangentU)) * faceB.HalfV
	local ovU = math.min(faceA.HalfU, cU + rUB) - math.max(-faceA.HalfU, cU - rUB)

	local cV = delta:Dot(faceA.TangentV)
	local rVB = math.abs(faceB.TangentU:Dot(faceA.TangentV)) * faceB.HalfU
		+ math.abs(faceB.TangentV:Dot(faceA.TangentV)) * faceB.HalfV
	local ovV = math.min(faceA.HalfV, cV + rVB) - math.max(-faceA.HalfV, cV - rVB)

	return ovU, ovV
end

local function findBestFlushFacePairForBoxes(
	boxCFA: CFrame,
	sizeA: Vector3,
	boxCFB: CFrame,
	sizeB: Vector3,
	surfTol: number,
	overlapTol: number
): (OBBFace?, OBBFace?, number?, number?)
	local halfA = BuildRotation.GetRotatedExtents(sizeA, boxCFA.Rotation) * 0.5
	local halfB = BuildRotation.GetRotatedExtents(sizeB, boxCFB.Rotation) * 0.5
	local posA = boxCFA.Position
	local posB = boxCFB.Position

	if
		math.abs(posA.X - posB.X) > halfA.X + halfB.X + surfTol
		or math.abs(posA.Y - posB.Y) > halfA.Y + halfB.Y + surfTol
		or math.abs(posA.Z - posB.Z) > halfA.Z + halfB.Z + surfTol
	then
		return nil, nil, nil, nil
	end

	-- Rechazar cajas con penetración volumétrica real (manteniendo rasantes dentro de overlapTol)
	if ConnectionMath.BoxesOverlap(boxCFA, sizeA, boxCFB, sizeB, overlapTol) then
		return nil, nil, nil, nil
	end

	local facesA = extractBoxFaces(boxCFA, sizeA)
	local facesB = extractBoxFaces(boxCFB, sizeB)
	local minBaseOverlap = GameConfig.Building.FaceSnapMinContactOverlap

	local bestFaceA: OBBFace? = nil
	local bestFaceB: OBBFace? = nil
	local bestGap = math.huge
	local bestArea = -1

	for _, fA in ipairs(facesA) do
		for _, fB in ipairs(facesB) do
			if fA.Normal:Dot(fB.Normal) <= -0.9 then
				-- Verificar que las caras enfrentadas apunten una hacia la otra (no espaldas opuestas)
				if
					(fB.BoxCenter - fA.BoxCenter):Dot(fA.Normal) > 1e-4
					and (fA.BoxCenter - fB.BoxCenter):Dot(fB.Normal) > 1e-4
				then
					local nDiff = fA.Normal - fB.Normal
					local nAvg = if nDiff.Magnitude > 1e-4 then nDiff.Unit else fA.Normal
					local signedGap = (fB.Center - fA.Center):Dot(nAvg)
					local absGap = math.abs(signedGap)

					if signedGap >= -(overlapTol + 1e-3) and absGap <= surfTol then
						local ovUA, ovVA = projectFaceRectOverlap(fA, fB)
						local ovUB, ovVB = projectFaceRectOverlap(fB, fA)
						local minReq = math.max(
							0.02,
							math.min(minBaseOverlap, math.min(fA.HalfU, fB.HalfU) * 0.5, math.min(fA.HalfV, fB.HalfV) * 0.5)
						)
						if ovUA >= minReq and ovVA >= minReq and ovUB >= minReq and ovVB >= minReq then
							local area = math.min(ovUA, ovUB) * math.min(ovVA, ovVB)
							if
								bestFaceA == nil
								or absGap < bestGap - 1e-4
								or (math.abs(absGap - bestGap) <= 1e-4 and area > bestArea)
							then
								bestFaceA = fA
								bestFaceB = fB
								bestGap = absGap
								bestArea = area
							end
						end
					end
				end
			end
		end
	end

	return bestFaceA, bestFaceB, bestGap, bestArea
end

local function specsShareFlushSurface(
	specA: PieceGeometrySpec,
	specB: PieceGeometrySpec,
	surfTol: number,
	overlapTol: number
): (OBBFace?, OBBFace?, number?)
	local boxesA = ConnectionMath.GetEffectivePartBoxes(specA)
	local boxesB = ConnectionMath.GetEffectivePartBoxes(specB)

	local bestFaceA: OBBFace? = nil
	local bestFaceB: OBBFace? = nil
	local bestGap = math.huge
	local bestArea = -1

	for _, boxA in ipairs(boxesA) do
		local worldCFA = specA.LocalCFrame * boxA.LocalCFrame
		for _, boxB in ipairs(boxesB) do
			local worldCFB = specB.LocalCFrame * boxB.LocalCFrame
			local fA, fB, gap, area = findBestFlushFacePairForBoxes(worldCFA, boxA.Size, worldCFB, boxB.Size, surfTol, overlapTol)
			if fA and fB and gap ~= nil and area ~= nil then
				if
					bestFaceA == nil
					or gap < bestGap - 1e-4
					or (math.abs(gap - bestGap) <= 1e-4 and area > bestArea)
				then
					bestFaceA = fA
					bestFaceB = fB
					bestGap = gap
					bestArea = area
				end
			end
		end
	end

	if bestFaceA and bestFaceB then
		return bestFaceA, bestFaceB, bestGap
	end
	return nil, nil, nil
end

local function pickSurfaceAttachmentName(
	face: OBBFace,
	worldAtts: { WorldAttachmentSpec },
	maxOffsetTol: number
): string
	local bestName: string? = nil
	local bestDist = math.huge
	for _, att in ipairs(worldAtts) do
		if att.WorldNormal:Dot(face.Normal) >= 0.9 then
			local d = (att.WorldPosition - face.Center).Magnitude
			if d <= maxOffsetTol and d < bestDist then
				bestDist = d
				bestName = att.Name
			end
		end
	end
	return bestName or `Surface_{face.FaceId}`
end

local function fastBoxesTouchOnPlane(
	posA: Vector3,
	halfA: Vector3,
	posB: Vector3,
	halfB: Vector3,
	planeNormal: Vector3,
	surfaceTol: number
): boolean
	local dx = math.abs(posA.X - posB.X)
	local dy = math.abs(posA.Y - posB.Y)
	local dz = math.abs(posA.Z - posB.Z)

	local sumX = halfA.X + halfB.X
	local sumY = halfA.Y + halfB.Y
	local sumZ = halfA.Z + halfB.Z

	if math.abs(planeNormal.X) > 0.9 then
		return math.abs(dx - sumX) <= surfaceTol and dy <= sumY - 0.05 and dz <= sumZ - 0.05
	elseif math.abs(planeNormal.Y) > 0.9 then
		return math.abs(dy - sumY) <= surfaceTol and dx <= sumX - 0.05 and dz <= sumZ - 0.05
	else
		return math.abs(dz - sumZ) <= surfaceTol and dx <= sumX - 0.05 and dy <= sumY - 0.05
	end
end

--[=[
	Encuentra todas las conexiones válidas entre una pieza candidata y las piezas existentes.
	Combina:
	  1. Emparejamiento explícito de attachments `Conn_*` compatibles.
	  2. Detección geométrica OBB cara-con-cara (soporte multi-box `PartBoxes` y rotaciones arbitrarias),
	     respetando estrictamente `SurfaceConnectionTolerance` y el solapamiento mínimo tangencial,
	     sin conectar jamás piezas separadas por aire.
]=]
function ConnectionMath.FindCompatibleConnections(
	candidate: PieceGeometrySpec,
	existingPieces: { PieceGeometrySpec },
	posTolerance: number?,
	surfaceTolerance: number?,
	spatialIndex: SpatialIndex?
): { VehicleTypes.BlueprintConnection }
	local posTol = posTolerance or GameConfig.Building.ConnectionPositionTolerance
	local surfTol = surfaceTolerance or GameConfig.Building.SurfaceConnectionTolerance
	local overlapTol = GameConfig.Building.OverlapTolerance
	local broadMargin = math.max(posTol, surfTol) + 0.05

	local candPos = candidate.LocalCFrame.Position
	local candHalf = ensureHalfExtents(candidate)
	local candWorldAtts = ensureWorldAttachments(candidate)

	local searchList = if spatialIndex
		then spatialIndex:QueryAABB(
			candPos - candHalf - Vector3.new(broadMargin, broadMargin, broadMargin),
			candPos + candHalf + Vector3.new(broadMargin, broadMargin, broadMargin),
			candidate.InstanceId
		)
		else existingPieces

	local connections: { VehicleTypes.BlueprintConnection } = {}
	local candHasComposite = hasCompositePartBoxes(candidate)
	local candOrtho = isAxisAligned90(candidate.LocalCFrame)

	for _, existing in ipairs(searchList) do
		if existing.InstanceId == candidate.InstanceId then
			continue
		end

		local existPosCenter = existing.LocalCFrame.Position
		local existHalf = ensureHalfExtents(existing)

		-- Filtro amplio AABB: en 3 comparaciones escalares descarta piezas lejanas
		if
			math.abs(candPos.X - existPosCenter.X) > candHalf.X + existHalf.X + broadMargin
			or math.abs(candPos.Y - existPosCenter.Y) > candHalf.Y + existHalf.Y + broadMargin
			or math.abs(candPos.Z - existPosCenter.Z) > candHalf.Z + existHalf.Z + broadMargin
		then
			continue
		end

		local existWorldAtts = ensureWorldAttachments(existing)
		local bestCandAtt: string? = nil
		local bestExistAtt: string? = nil
		local bestDist = math.huge

		local canFastPlane = not candHasComposite
			and not hasCompositePartBoxes(existing)
			and candOrtho
			and isAxisAligned90(existing.LocalCFrame)

		local cachedFlushComputed = false
		local cachedFlushA: OBBFace? = nil
		local cachedFlushB: OBBFace? = nil

		local function getFlushFaces(): (OBBFace?, OBBFace?)
			if not cachedFlushComputed then
				cachedFlushComputed = true
				local fA, fB = specsShareFlushSurface(candidate, existing, surfTol, overlapTol)
				cachedFlushA = fA
				cachedFlushB = fB
			end
			return cachedFlushA, cachedFlushB
		end

		-- Paso 1: Emparejamiento por attachments Conn_*
		for _, attCand in ipairs(candWorldAtts) do
			local cPos = attCand.WorldPosition
			local cNorm = attCand.WorldNormal

			for _, attExist in ipairs(existWorldAtts) do
				local eNorm = attExist.WorldNormal
				if cNorm:Dot(eNorm) <= -0.7 then
					local ePos = attExist.WorldPosition
					local planeDist = math.abs((cPos - ePos):Dot(cNorm))
					if planeDist <= surfTol then
						local dist = (cPos - ePos).Magnitude
						local isDirectMatch = dist <= posTol
						local isSurfaceMatch = false
						if not isDirectMatch then
							if canFastPlane then
								isSurfaceMatch = fastBoxesTouchOnPlane(candPos, candHalf, existPosCenter, existHalf, cNorm, surfTol)
							else
								local fA, fB = getFlushFaces()
								isSurfaceMatch = (fA ~= nil and fB ~= nil and fA.Normal:Dot(cNorm) >= 0.7 and fB.Normal:Dot(eNorm) >= 0.7)
							end
						end

						if (isDirectMatch or isSurfaceMatch) and dist < bestDist then
							bestDist = dist
							bestCandAtt = attCand.Name
							bestExistAtt = attExist.Name
						end
					end
				end
			end
		end

		-- Paso 2: Respaldo geométrico OBB cara-con-cara para piezas sin Conn_* en esa cara
		-- o con desplazamiento lateral/rotación respecto al centro del attachment.
		if not bestCandAtt or not bestExistAtt then
			local fA, fB = getFlushFaces()
			if fA and fB then
				bestCandAtt = pickSurfaceAttachmentName(fA, candWorldAtts, posTol)
				bestExistAtt = pickSurfaceAttachmentName(fB, existWorldAtts, posTol)
			end
		end

		if bestCandAtt and bestExistAtt then
			table.insert(connections, {
				FromPieceId = candidate.InstanceId,
				FromAttachment = bestCandAtt,
				ToPieceId = existing.InstanceId,
				ToAttachment = bestExistAtt,
			})
		end
	end

	return connections
end

--[=[
	Genera un resumen diagnóstico detallado cuando una pieza candidata no logra conectarse
	con ninguna pieza existente, indicando el par de attachments o caras más cercano,
	distancia, separación planar, producto punto de normales y contacto de caras.
]=]
function ConnectionMath.DiagnoseConnectionFailure(
	candidate: PieceGeometrySpec,
	existingPieces: { PieceGeometrySpec }
): string
	if #existingPieces == 0 then
		return "NoExistingPieces"
	end

	local candPosCenter = candidate.LocalCFrame.Position
	local candHalf = ensureHalfExtents(candidate)
	local candWorldAtts = ensureWorldAttachments(candidate)
	local surfTol = GameConfig.Building.SurfaceConnectionTolerance
	local overlapTol = GameConfig.Building.OverlapTolerance

	local bestSummary = if #candWorldAtts == 0 then `NoSurfaceContactAndNoAttachments({candidate.ItemId})` else "NoAttachmentOrSurfacePairsFound"
	local bestScore = math.huge

	for _, existing in ipairs(existingPieces) do
		if existing.InstanceId == candidate.InstanceId then
			continue
		end

		local existPosCenter = existing.LocalCFrame.Position
		local existHalf = ensureHalfExtents(existing)
		local existWorldAtts = ensureWorldAttachments(existing)

		local fA, fB, flushGap = specsShareFlushSurface(candidate, existing, surfTol, overlapTol)
		if fA and fB and flushGap ~= nil then
			return string.format(
				"surfaceTouch=%s[%s] %s->%s gap=%.3f",
				existing.InstanceId,
				existing.ItemId,
				fA.FaceId,
				fB.FaceId,
				flushGap
			)
		end

		local centerDist = (candPosCenter - existPosCenter).Magnitude
		local aabbGap = math.max(
			math.abs(candPosCenter.X - existPosCenter.X) - (candHalf.X + existHalf.X),
			math.abs(candPosCenter.Y - existPosCenter.Y) - (candHalf.Y + existHalf.Y),
			math.abs(candPosCenter.Z - existPosCenter.Z) - (candHalf.Z + existHalf.Z)
		)

		if #candWorldAtts == 0 or #existWorldAtts == 0 then
			if centerDist < bestScore then
				bestScore = centerDist
				bestSummary = string.format(
					"nearest=%s[%s] aabbGap=%.2f centerDist=%.2f",
					existing.InstanceId,
					existing.ItemId,
					aabbGap,
					centerDist
				)
			end
			continue
		end

		for _, attCand in ipairs(candWorldAtts) do
			local cPos = attCand.WorldPosition
			local cNorm = attCand.WorldNormal

			for _, attExist in ipairs(existWorldAtts) do
				local ePos = attExist.WorldPosition
				local eNorm = attExist.WorldNormal
				local dist = (cPos - ePos).Magnitude
				local dot = cNorm:Dot(eNorm)
				local planeDist = math.abs((cPos - ePos):Dot(cNorm))
				local penalty = if dot <= -0.7 then 0 else 10
				local score = dist + penalty

				if score < bestScore then
					bestScore = score
					local touchPlane = fastBoxesTouchOnPlane(
						candPosCenter,
						candHalf,
						existPosCenter,
						existHalf,
						cNorm,
						surfTol
					)
					bestSummary = string.format(
						"closest=%s[%s] %s->%s dist=%.2f planeGap=%.2f aabbGap=%.2f dot=%.2f planeContact=%s",
						existing.InstanceId,
						existing.ItemId,
						attCand.Name,
						attExist.Name,
						dist,
						planeDist,
						aabbGap,
						dot,
						tostring(touchPlane)
					)
				end
			end
		end
	end

	return bestSummary
end

--[=[
	Calcula un snap inteligente hacia el attachment o cara compatible más cercano dentro de `snapRadius`
	que no provoque superposición con piezas existentes ni entierre la pieza bajo `floorY`.
	Utiliza filtro previo por AABB o SpatialIndex para escalar suavemente a 200+ piezas.
]=]
function ConnectionMath.ComputeSmartSnap(
	baseLocalCFrame: CFrame,
	candidateSize: Vector3,
	candidateAttachments: { AttachmentSpec },
	existingPieces: { PieceGeometrySpec },
	snapRadius: number?,
	floorY: number?,
	spatialIndex: SpatialIndex?,
	excludePieceId: string?
): SmartSnapMatch?
	if #existingPieces == 0 or #candidateAttachments == 0 then
		return nil
	end

	local radius = snapRadius or GameConfig.Building.SmartSnapRadius
	local surfTol = GameConfig.Building.SurfaceConnectionTolerance
	local overlapTol = GameConfig.Building.OverlapTolerance
	local broadMargin = radius + surfTol + overlapTol + 0.1

	local rawRot = baseLocalCFrame.Rotation
	local rot = if BuildRotation.IsOrthogonal90(rawRot)
		then BuildRotation.Orthonormalize(rawRot)
		else BuildRotation.OrthonormalizeGeneral(rawRot)
	local basePos = baseLocalCFrame.Position
	local candHalf = BuildRotation.GetRotatedExtents(candidateSize, rot) * 0.5
	local minCenterY = if floorY ~= nil then floorY + candHalf.Y else nil

	-- Precalcular una sola vez los offsets locales rotados de los attachments del candidato
	type CandPrecomputed = {
		Name: string,
		RelOffset: Vector3,
		WorldNormal: Vector3,
		BasePos: Vector3,
		IsHoriz: boolean,
	}
	local candPre: { CandPrecomputed } = table.create(#candidateAttachments)
	for i, attCand in ipairs(candidateAttachments) do
		local relOffset = rot:VectorToWorldSpace(attCand.LocalPosition)
		local worldNorm = rot:VectorToWorldSpace(attCand.LocalNormal)
		candPre[i] = {
			Name = attCand.Name,
			RelOffset = relOffset,
			WorldNormal = worldNorm,
			BasePos = basePos + relOffset,
			IsHoriz = math.abs(worldNorm.Y) < 0.5,
		}
	end

	-- Recolectar únicamente piezas dentro del radio amplio de snap/overlap
	local nearbyPieces: { PieceGeometrySpec }
	if spatialIndex then
		local pad = Vector3.new(broadMargin, broadMargin, broadMargin)
		nearbyPieces = spatialIndex:QueryAABB(basePos - candHalf - pad, basePos + candHalf + pad, excludePieceId)
	else
		nearbyPieces = {}
		for _, existing in ipairs(existingPieces) do
			if existing.InstanceId ~= excludePieceId then
				local existPos = existing.LocalCFrame.Position
				local existHalf = ensureHalfExtents(existing)
				if
					math.abs(basePos.X - existPos.X) <= candHalf.X + existHalf.X + broadMargin
					and math.abs(basePos.Y - existPos.Y) <= candHalf.Y + existHalf.Y + broadMargin
					and math.abs(basePos.Z - existPos.Z) <= candHalf.Z + existHalf.Z + broadMargin
				then
					table.insert(nearbyPieces, existing)
				end
			end
		end
	end

	if #nearbyPieces == 0 then
		return nil
	end

	local bestMatch: SmartSnapMatch? = nil
	local candOrtho = isAxisAligned90(rot)

	local function tryCandidateSnap(
		snappedCenter: Vector3,
		attCandName: string,
		existing: PieceGeometrySpec,
		attExistName: string,
		metricDist: number,
		isHorizontalAttachment: boolean
	)
		local adjustedCenter = snappedCenter
		if minCenterY ~= nil then
			if adjustedCenter.Y < minCenterY - 1e-4 then
				adjustedCenter = Vector3.new(adjustedCenter.X, minCenterY, adjustedCenter.Z)
			elseif
				isHorizontalAttachment
				and math.abs(basePos.Y - minCenterY) < 0.05
				and math.abs(adjustedCenter.Y - minCenterY) <= 0.55
			then
				adjustedCenter = Vector3.new(adjustedCenter.X, minCenterY, adjustedCenter.Z)
			end
		end

		local candCF = CFrame.new(adjustedCenter) * rot
		for _, other in ipairs(nearbyPieces) do
			local otherHalf = ensureHalfExtents(other)
			if fastBoxesOverlap(adjustedCenter, candHalf, other.LocalCFrame.Position, otherHalf, overlapTol) then
				if candOrtho and isAxisAligned90(other.LocalCFrame) then
					return
				elseif obbAxesOverlap(adjustedCenter, candCF, candidateSize, other.LocalCFrame.Position, other.LocalCFrame, other.Size, overlapTol) then
					return
				end
			end
		end

		local snappedCF = candCF
		local candidateSpec: PieceGeometrySpec = {
			InstanceId = "__snap_candidate__",
			ItemId = "",
			LocalCFrame = snappedCF,
			Size = candidateSize,
			Attachments = candidateAttachments,
			_HalfExtents = candHalf,
		}
		local conns = ConnectionMath.FindCompatibleConnections(candidateSpec, { existing })
		if #conns == 0 then
			return
		end

		if bestMatch == nil or metricDist < (bestMatch :: SmartSnapMatch).Distance - 1e-4 then
			bestMatch = {
				SnappedLocalCFrame = snappedCF,
				CandidateAttachment = attCandName,
				TargetPieceId = existing.InstanceId,
				TargetAttachment = attExistName,
				Distance = metricDist,
			}
		end
	end

	for _, existing in ipairs(nearbyPieces) do
		local existPosCenter = existing.LocalCFrame.Position
		local existHalf = ensureHalfExtents(existing)
		local existWorldAtts = ensureWorldAttachments(existing)

		for _, attExist in ipairs(existWorldAtts) do
			local ePos = attExist.WorldPosition
			local eNorm = attExist.WorldNormal

			for _, attCand in ipairs(candPre) do
				if attCand.WorldNormal:Dot(eNorm) <= -0.7 then
					local dist = (attCand.BasePos - ePos).Magnitude
					if dist <= radius then
						local directCenter = ePos - attCand.RelOffset
						tryCandidateSnap(directCenter, attCand.Name, existing, attExist.Name, dist, attCand.IsHoriz)
					end

					local planeDelta = (ePos - attCand.BasePos):Dot(attCand.WorldNormal)
					local absPlaneDelta = math.abs(planeDelta)
					if absPlaneDelta <= radius then
						local planarCenter = basePos + attCand.WorldNormal * planeDelta
						if fastBoxesTouchOnPlane(planarCenter, candHalf, existPosCenter, existHalf, attCand.WorldNormal, surfTol) then
							local planarMetric = absPlaneDelta + 0.25
							tryCandidateSnap(planarCenter, attCand.Name, existing, attExist.Name, planarMetric, attCand.IsHoriz)
						end
					end
				end
			end
		end
	end

	return bestMatch
end

--[=[
	Comprueba mediante recorrido en anchura (BFS) indexado por enteros si al eliminar `removedPieceId`
	el resto de las piezas del vehículo continúan formando una única componente conexa.
]=]
function ConnectionMath.IsGraphConnectedAfterRemoval(
	pieces: { VehicleTypes.BlueprintPiece },
	connections: { VehicleTypes.BlueprintConnection },
	removedPieceId: string
): boolean
	local remainingCount = 0
	local indexById: { [string]: number } = {}

	for _, piece in ipairs(pieces) do
		if piece.InstanceId ~= removedPieceId then
			remainingCount += 1
			indexById[piece.InstanceId] = remainingCount
		end
	end

	if remainingCount <= 1 then
		return true
	end

	local adj: { { number } } = table.create(remainingCount)
	for i = 1, remainingCount do
		adj[i] = {}
	end

	for _, conn in ipairs(connections) do
		local u = indexById[conn.FromPieceId]
		local v = indexById[conn.ToPieceId]
		if u and v then
			table.insert(adj[u], v)
			table.insert(adj[v], u)
		end
	end

	local visited: { boolean } = table.create(remainingCount, false)
	local queue: { number } = table.create(remainingCount)
	queue[1] = 1
	visited[1] = true

	local head = 1
	local tail = 1
	while head <= tail do
		local current = queue[head]
		head += 1

		for _, neighbor in ipairs(adj[current]) do
			if not visited[neighbor] then
				visited[neighbor] = true
				tail += 1
				queue[tail] = neighbor
			end
		end
	end

	return tail == remainingCount
end

--[=[
	Analiza todas las componentes conexas de un blueprint basándose exclusivamente en su grafo explícito
	de conexiones (`Connections`), sin unir piezas únicamente próximas visualmente.
	Determina PrimaryAssembly (por DriverSeat o selección explícita), SecondaryAssembly y LoosePiece.
]=]
function ConnectionMath.AnalyzeAssemblies(
	pieces: { VehicleTypes.BlueprintPiece },
	connections: { VehicleTypes.BlueprintConnection },
	preferredPrimaryGroupId: string?,
	pieceSpecsById: { [string]: PieceGeometrySpec }?
): VehicleTypes.AssemblyAnalysis
	local driverSeatItemId = GameConfig.LaunchPrep.DriverSeatItemId
	local pieceById: { [string]: VehicleTypes.BlueprintPiece } = {}
	local sortedIds: { string } = table.create(#pieces)

	for i, piece in ipairs(pieces) do
		pieceById[piece.InstanceId] = piece
		sortedIds[i] = piece.InstanceId
	end
	table.sort(sortedIds)

	local adj: { [string]: { string } } = {}
	for _, id in ipairs(sortedIds) do
		adj[id] = {}
	end
	for _, conn in ipairs(connections) do
		if pieceById[conn.FromPieceId] and pieceById[conn.ToPieceId] and conn.FromPieceId ~= conn.ToPieceId then
			table.insert(adj[conn.FromPieceId], conn.ToPieceId)
			table.insert(adj[conn.ToPieceId], conn.FromPieceId)
		end
	end

	local visited: { [string]: boolean } = {}
	local rawGroups: { VehicleTypes.AssemblyComponentSummary } = {}
	local driverSeatGroupIds: { string } = {}
	local groupById: { [string]: VehicleTypes.AssemblyComponentSummary } = {}
	local driverSeatGroupLookup: { [string]: boolean } = {}

	for _, startId in ipairs(sortedIds) do
		if not visited[startId] then
			visited[startId] = true
			local queue: { string } = { startId }
			local head = 1
			local compIds: { string } = {}
			local seatCount = 0
			local minX, minY, minZ = math.huge, math.huge, math.huge
			local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
			local hasBounds = false

			while head <= #queue do
				local curr = queue[head]
				head += 1
				table.insert(compIds, curr)

				local piece = pieceById[curr]
				if piece.ItemId == driverSeatItemId then
					seatCount += 1
				end

				if pieceSpecsById then
					local spec = pieceSpecsById[curr]
					if spec then
						local pMin, pMax = ConnectionMath.ComputePieceLocalAABB(spec)
						hasBounds = true
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
					end
				end

				for _, neighbor in ipairs(adj[curr]) do
					if not visited[neighbor] then
						visited[neighbor] = true
						table.insert(queue, neighbor)
					end
				end
			end

			table.sort(compIds)
			local groupId = "grp_" .. compIds[1]
			local hasSeat = seatCount > 0
			if hasSeat then
				table.insert(driverSeatGroupIds, groupId)
				driverSeatGroupLookup[groupId] = true
			end

			local summary: VehicleTypes.AssemblyComponentSummary = {
				GroupId = groupId,
				PieceIds = compIds,
				PieceCount = #compIds,
				DriverSeatCount = seatCount,
				HasDriverSeat = hasSeat,
				Role = if #compIds == 1 then "LoosePiece" else "SecondaryAssembly",
				BoundsMin = if hasBounds then Vector3.new(minX, minY, minZ) else nil,
				BoundsMax = if hasBounds then Vector3.new(maxX, maxY, maxZ) else nil,
			}
			table.insert(rawGroups, summary)
			groupById[groupId] = summary
		end
	end

	local primaryGroupId: string? = nil
	local needsPrimarySelection = false
	local ambiguousPrimary = false

	if #rawGroups > 0 then
		if #driverSeatGroupIds == 1 then
			primaryGroupId = driverSeatGroupIds[1]
		elseif #driverSeatGroupIds > 1 then
			if preferredPrimaryGroupId and groupById[preferredPrimaryGroupId] and driverSeatGroupLookup[preferredPrimaryGroupId] then
				primaryGroupId = preferredPrimaryGroupId
			else
				ambiguousPrimary = true
				needsPrimarySelection = true
				primaryGroupId = nil
			end
		else
			if preferredPrimaryGroupId and groupById[preferredPrimaryGroupId] then
				primaryGroupId = preferredPrimaryGroupId
			else
				-- Sin DriverSeat en ninguna componente: seleccionar la componente de mayor tamaño para diagnósticos claros
				local best = rawGroups[1]
				for i = 2, #rawGroups do
					local g = rawGroups[i]
					if g.PieceCount > best.PieceCount or (g.PieceCount == best.PieceCount and g.GroupId < best.GroupId) then
						best = g
					end
				end
				primaryGroupId = best.GroupId
			end
		end
	end

	local groupIdByPieceId: { [string]: string } = {}
	local roleByPieceId: { [string]: VehicleTypes.AssemblyRole } = {}
	local primaryPieceIds: { string } = {}
	local workshopPieceIds: { string } = {}

	for _, group in ipairs(rawGroups) do
		local role: VehicleTypes.AssemblyRole
		if primaryGroupId ~= nil and group.GroupId == primaryGroupId then
			role = "PrimaryAssembly"
		elseif group.PieceCount == 1 then
			role = "LoosePiece"
		else
			role = "SecondaryAssembly"
		end
		group.Role = role

		for _, pid in ipairs(group.PieceIds) do
			groupIdByPieceId[pid] = group.GroupId
			roleByPieceId[pid] = role
			if role == "PrimaryAssembly" then
				table.insert(primaryPieceIds, pid)
			else
				table.insert(workshopPieceIds, pid)
			end
		end
	end

	table.sort(rawGroups, function(a, b)
		if a.Role == "PrimaryAssembly" and b.Role ~= "PrimaryAssembly" then
			return true
		end
		if b.Role == "PrimaryAssembly" and a.Role ~= "PrimaryAssembly" then
			return false
		end
		if a.HasDriverSeat ~= b.HasDriverSeat then
			return a.HasDriverSeat
		end
		if a.PieceCount ~= b.PieceCount then
			return a.PieceCount > b.PieceCount
		end
		return a.GroupId < b.GroupId
	end)

	return {
		Groups = rawGroups,
		GroupIdByPieceId = groupIdByPieceId,
		RoleByPieceId = roleByPieceId,
		PrimaryGroupId = primaryGroupId,
		PrimaryPieceIds = primaryPieceIds,
		WorkshopPieceIds = workshopPieceIds,
		DriverSeatGroupIds = driverSeatGroupIds,
		NeedsPrimarySelection = needsPrimarySelection,
		AmbiguousPrimary = ambiguousPrimary,
	}
end

return ConnectionMath
