--!strict
--[=[
	BlueprintSerializer
	Serialización, deserialización, copia profunda sin referencias compartidas
	y migración versionada (`SchemaVersion`) para VehicleBlueprint.
	Compatible con tablas JSON-safe para futura persistencia en DataStore.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildRotation = require(ReplicatedStorage.Shared.Building.BuildRotation)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type SerializedPiece = {
	InstanceId: string,
	ItemId: string,
	LocalCFrame: { number },
	InventoryInstanceId: string?,
	Config: { [string]: any }?,
}

export type SerializedBlueprint = {
	SchemaVersion: number,
	BlueprintId: string,
	OwnerUserId: number,
	Name: string,
	Revision: number,
	CreatedAt: number,
	UpdatedAt: number,
	VehicleOrigin: { number },
	Presentation: VehicleTypes.StandPresentationConfig,
	Metadata: VehicleTypes.BlueprintMetadata?,
	Pieces: { SerializedPiece },
	Connections: { VehicleTypes.BlueprintConnection },
}

local BlueprintSerializer = {}

local function isFiniteNumber(val: any): boolean
	return type(val) == "number" and val == val and val ~= math.huge and val ~= -math.huge
end

function BlueprintSerializer.DeepCloneTable(tbl: { [string]: any }?): { [string]: any }?
	if tbl == nil then
		return nil
	end
	local copy: { [string]: any } = {}
	for k, v in pairs(tbl) do
		if type(v) == "table" then
			copy[k] = BlueprintSerializer.DeepCloneTable(v)
		else
			copy[k] = v
		end
	end
	return copy
end

function BlueprintSerializer.SerializeCFrame(cf: CFrame): { number }
	return { cf:GetComponents() }
end

function BlueprintSerializer.DeserializeCFrame(raw: any): (boolean, CFrame?)
	if typeof(raw) == "CFrame" then
		local cf = raw :: CFrame
		local p = cf.Position
		if
			not isFiniteNumber(p.X)
			or not isFiniteNumber(p.Y)
			or not isFiniteNumber(p.Z)
			or not BuildRotation.IsOrthonormalRotation(cf, 0.05)
		then
			return false, nil
		end
		return true, cf
	end

	if type(raw) ~= "table" or #raw ~= 12 then
		return false, nil
	end

	local c: { number } = table.create(12)
	for i = 1, 12 do
		local n = raw[i]
		if not isFiniteNumber(n) or math.abs(n) > GameConfig.Building.MaxCoordinateMagnitude then
			return false, nil
		end
		c[i] = n
	end

	local cf = CFrame.new(c[1], c[2], c[3], c[4], c[5], c[6], c[7], c[8], c[9], c[10], c[11], c[12])
	if not BuildRotation.IsOrthonormalRotation(cf, 0.05) then
		return false, nil
	end
	return true, cf
end

function BlueprintSerializer.SanitizePresentation(raw: any): VehicleTypes.StandPresentationConfig
	if type(raw) ~= "table" then
		return {
			HeightOffset = GameConfig.Stand.DefaultHeightOffset,
			LateralOffset = GameConfig.Stand.DefaultLateralOffset,
		}
	end

	local rawH = raw.HeightOffset
	local rawL = raw.LateralOffset
	local h = if isFiniteNumber(rawH)
		then math.clamp(rawH, GameConfig.Stand.MinHeightOffset, GameConfig.Stand.MaxHeightOffset)
		else GameConfig.Stand.DefaultHeightOffset
	local l = if isFiniteNumber(rawL)
		then math.clamp(rawL, GameConfig.Stand.MinLateralOffset, GameConfig.Stand.MaxLateralOffset)
		else GameConfig.Stand.DefaultLateralOffset

	return {
		HeightOffset = h,
		LateralOffset = l,
	}
end

function BlueprintSerializer.ClonePiece(p: VehicleTypes.BlueprintPiece): VehicleTypes.BlueprintPiece
	return {
		InstanceId = p.InstanceId,
		ItemId = p.ItemId,
		LocalCFrame = p.LocalCFrame,
		InventoryInstanceId = p.InventoryInstanceId,
		Config = BlueprintSerializer.DeepCloneTable(p.Config),
	}
end

function BlueprintSerializer.CloneBlueprint(
	bp: VehicleTypes.VehicleBlueprint,
	overrideOwnerUserId: number?
): VehicleTypes.VehicleBlueprint
	local piecesCopy: { VehicleTypes.BlueprintPiece } = table.create(#bp.Pieces)
	for i, p in ipairs(bp.Pieces) do
		piecesCopy[i] = BlueprintSerializer.ClonePiece(p)
	end

	local connsCopy: { VehicleTypes.BlueprintConnection } = table.create(#bp.Connections)
	for i, c in ipairs(bp.Connections) do
		connsCopy[i] = {
			FromPieceId = c.FromPieceId,
			FromAttachment = c.FromAttachment,
			ToPieceId = c.ToPieceId,
			ToAttachment = c.ToAttachment,
		}
	end

	local pres = BlueprintSerializer.SanitizePresentation(bp.Presentation)
	local metaCopy = if bp.Metadata then BlueprintSerializer.DeepCloneTable(bp.Metadata :: any) else nil

	return {
		SchemaVersion = bp.SchemaVersion or GameConfig.Blueprints.CurrentSchemaVersion,
		BlueprintId = bp.BlueprintId,
		OwnerUserId = overrideOwnerUserId or bp.OwnerUserId,
		Name = bp.Name or `{GameConfig.Blueprints.DefaultNamePrefix} 1`,
		Revision = bp.Revision or 0,
		CreatedAt = bp.CreatedAt or os.time(),
		UpdatedAt = bp.UpdatedAt or os.time(),
		VehicleOrigin = bp.VehicleOrigin or CFrame.identity,
		Presentation = pres,
		Metadata = metaCopy :: VehicleTypes.BlueprintMetadata?,
		Pieces = piecesCopy,
		Connections = connsCopy,
	}
end

function BlueprintSerializer.SerializeBlueprint(bp: VehicleTypes.VehicleBlueprint): SerializedBlueprint
	local serializedPieces: { SerializedPiece } = table.create(#bp.Pieces)
	for i, piece in ipairs(bp.Pieces) do
		serializedPieces[i] = {
			InstanceId = piece.InstanceId,
			ItemId = piece.ItemId,
			LocalCFrame = BlueprintSerializer.SerializeCFrame(piece.LocalCFrame),
			InventoryInstanceId = piece.InventoryInstanceId,
			Config = BlueprintSerializer.DeepCloneTable(piece.Config),
		}
	end

	local connsCopy: { VehicleTypes.BlueprintConnection } = table.create(#bp.Connections)
	for i, conn in ipairs(bp.Connections) do
		connsCopy[i] = {
			FromPieceId = conn.FromPieceId,
			FromAttachment = conn.FromAttachment,
			ToPieceId = conn.ToPieceId,
			ToAttachment = conn.ToAttachment,
		}
	end

	return {
		SchemaVersion = bp.SchemaVersion or GameConfig.Blueprints.CurrentSchemaVersion,
		BlueprintId = bp.BlueprintId,
		OwnerUserId = bp.OwnerUserId,
		Name = bp.Name or `{GameConfig.Blueprints.DefaultNamePrefix} 1`,
		Revision = bp.Revision or 0,
		CreatedAt = bp.CreatedAt or os.time(),
		UpdatedAt = bp.UpdatedAt or os.time(),
		VehicleOrigin = BlueprintSerializer.SerializeCFrame(bp.VehicleOrigin or CFrame.identity),
		Presentation = BlueprintSerializer.SanitizePresentation(bp.Presentation),
		Metadata = if bp.Metadata then BlueprintSerializer.DeepCloneTable(bp.Metadata :: any) :: VehicleTypes.BlueprintMetadata else nil,
		Pieces = serializedPieces,
		Connections = connsCopy,
	}
end

function BlueprintSerializer.DeserializeBlueprint(
	raw: any,
	targetOwnerUserId: number?
): (boolean, VehicleTypes.VehicleBlueprint?, string?)
	if type(raw) ~= "table" then
		return false, nil, "Serialized blueprint must be a table"
	end

	local schemaVersion = raw.SchemaVersion
	if schemaVersion == nil then
		-- Migración automática desde esquema legacy sin SchemaVersion (Fase 2.2/2.3)
		schemaVersion = 0
	end
	if type(schemaVersion) ~= "number" or schemaVersion < 0 or schemaVersion % 1 ~= 0 then
		return false, nil, "Invalid SchemaVersion"
	end
	if schemaVersion > GameConfig.Blueprints.CurrentSchemaVersion then
		return false, nil, `Unsupported future SchemaVersion {schemaVersion}`
	end

	if type(raw.BlueprintId) ~= "string" or raw.BlueprintId == "" or #raw.BlueprintId > GameConfig.Building.MaxStringLength then
		return false, nil, "Invalid BlueprintId"
	end

	local ownerId = targetOwnerUserId or raw.OwnerUserId
	if not isFiniteNumber(ownerId) or ownerId < 0 then
		return false, nil, "Invalid OwnerUserId"
	end

	local rawRevision = if raw.Revision ~= nil then raw.Revision else 0
	if not isFiniteNumber(rawRevision) or rawRevision < 0 or rawRevision % 1 ~= 0 then
		return false, nil, "Invalid Revision"
	end

	local name = if type(raw.Name) == "string" and raw.Name ~= ""
		then string.sub(raw.Name, 1, GameConfig.Blueprints.MaxNameLength)
		else `{GameConfig.Blueprints.DefaultNamePrefix} 1`

	local now = os.time()
	local createdAt = if isFiniteNumber(raw.CreatedAt) and raw.CreatedAt > 0 then raw.CreatedAt else now
	local updatedAt = if isFiniteNumber(raw.UpdatedAt) and raw.UpdatedAt >= createdAt then raw.UpdatedAt else createdAt

	local originCF = CFrame.identity
	if raw.VehicleOrigin ~= nil then
		local okOrigin, parsedOrigin = BlueprintSerializer.DeserializeCFrame(raw.VehicleOrigin)
		if not okOrigin or not parsedOrigin then
			return false, nil, "Invalid VehicleOrigin"
		end
		originCF = parsedOrigin
	end

	if type(raw.Pieces) ~= "table" then
		return false, nil, "Pieces must be a table"
	end
	if #raw.Pieces > GameConfig.Building.MaxPiecesPerVehicle then
		return false, nil, "Piece count exceeds MaxPiecesPerVehicle"
	end

	local seenIds: { [string]: boolean } = {}
	local pieces: { VehicleTypes.BlueprintPiece } = table.create(#raw.Pieces)
	for i, rawPiece in ipairs(raw.Pieces) do
		if type(rawPiece) ~= "table" then
			return false, nil, `Piece #{i} is not a table`
		end
		if type(rawPiece.InstanceId) ~= "string" or rawPiece.InstanceId == "" or seenIds[rawPiece.InstanceId] then
			return false, nil, `Invalid or duplicate Piece.InstanceId at #{i}`
		end
		if type(rawPiece.ItemId) ~= "string" or rawPiece.ItemId == "" then
			return false, nil, `Invalid Piece.ItemId at #{i}`
		end
		local cfOk, cf = BlueprintSerializer.DeserializeCFrame(rawPiece.LocalCFrame)
		if not cfOk or not cf then
			return false, nil, `Invalid Piece.LocalCFrame at #{i}`
		end
		seenIds[rawPiece.InstanceId] = true
		pieces[i] = {
			InstanceId = rawPiece.InstanceId,
			ItemId = rawPiece.ItemId,
			LocalCFrame = cf,
			InventoryInstanceId = if type(rawPiece.InventoryInstanceId) == "string" then rawPiece.InventoryInstanceId else nil,
			Config = if type(rawPiece.Config) == "table" then BlueprintSerializer.DeepCloneTable(rawPiece.Config) else nil,
		}
	end

	local connections: { VehicleTypes.BlueprintConnection } = {}
	local seenEdgeKeys: { [string]: boolean } = {}
	if raw.Connections ~= nil then
		if type(raw.Connections) ~= "table" then
			return false, nil, "Connections must be a table"
		end
		for i, rawConn in ipairs(raw.Connections) do
			if type(rawConn) ~= "table" then
				return false, nil, `Connection #{i} is not a table`
			end
			if
				type(rawConn.FromPieceId) ~= "string"
				or type(rawConn.FromAttachment) ~= "string"
				or type(rawConn.ToPieceId) ~= "string"
				or type(rawConn.ToAttachment) ~= "string"
			then
				return false, nil, `Invalid connection endpoint types at #{i}`
			end
			local fromId = rawConn.FromPieceId
			local toId = rawConn.ToPieceId
			-- Podar silenciosamente referencias huérfanas, auto-lazos o aristas duplicadas
			if fromId ~= toId and seenIds[fromId] and seenIds[toId] then
				local edgeKey = if fromId < toId then `{fromId}|{toId}` else `{toId}|{fromId}`
				if not seenEdgeKeys[edgeKey] then
					seenEdgeKeys[edgeKey] = true
					table.insert(connections, {
						FromPieceId = fromId,
						FromAttachment = rawConn.FromAttachment,
						ToPieceId = toId,
						ToAttachment = rawConn.ToAttachment,
					})
				end
			end
		end
	end

	local bp: VehicleTypes.VehicleBlueprint = {
		SchemaVersion = GameConfig.Blueprints.CurrentSchemaVersion,
		BlueprintId = raw.BlueprintId,
		OwnerUserId = ownerId,
		Name = name,
		Revision = rawRevision,
		CreatedAt = createdAt,
		UpdatedAt = updatedAt,
		VehicleOrigin = originCF,
		Presentation = BlueprintSerializer.SanitizePresentation(raw.Presentation),
		Metadata = if type(raw.Metadata) == "table" then BlueprintSerializer.DeepCloneTable(raw.Metadata) :: VehicleTypes.BlueprintMetadata else nil,
		Pieces = pieces,
		Connections = connections,
	}

	return true, bp, nil
end

function BlueprintSerializer.SlotKey(slotIndex: number): string
	return tostring(math.floor(slotIndex))
end

function BlueprintSerializer.IsValidSlotIndex(slotIndex: any): boolean
	return type(slotIndex) == "number"
		and slotIndex == slotIndex
		and slotIndex % 1 == 0
		and slotIndex >= 1
		and slotIndex <= GameConfig.Blueprints.MaxSlots
end

function BlueprintSerializer.SerializePlayerStorage(storage: VehicleTypes.PlayerBlueprintStorage): { [string]: any }
	local serializedSlots: { [string]: any } = {}
	for slotIndex = 1, GameConfig.Blueprints.MaxSlots do
		local key = BlueprintSerializer.SlotKey(slotIndex)
		local slotBp = if storage.Slots then (storage.Slots[key] or (storage.Slots :: any)[slotIndex]) else nil
		if slotBp then
			serializedSlots[key] = BlueprintSerializer.SerializeBlueprint(slotBp)
		end
	end

	local overflowOut: { VehicleTypes.LegacyOverflowEntry } = {}
	if type(storage.LegacyOverflow) == "table" then
		for _, entry in ipairs(storage.LegacyOverflow) do
			if type(entry) == "table" and type(entry.OriginalBlueprintId) == "string" and type(entry.SerializedBlueprint) == "table" then
				table.insert(overflowOut, {
					OriginalBlueprintId = entry.OriginalBlueprintId,
					Name = tostring(entry.Name or GameConfig.Blueprints.DefaultNamePrefix),
					PieceCount = if type(entry.PieceCount) == "number" then entry.PieceCount else 0,
					UpdatedAt = if type(entry.UpdatedAt) == "number" then entry.UpdatedAt else os.time(),
					MigratedAt = if type(entry.MigratedAt) == "number" then entry.MigratedAt else os.time(),
					RecoveredToSlot = if type(entry.RecoveredToSlot) == "number" then entry.RecoveredToSlot else nil,
					SerializedBlueprint = BlueprintSerializer.DeepCloneTable(entry.SerializedBlueprint) :: { [string]: any },
				})
			end
		end
	end

	return {
		StorageSchemaVersion = GameConfig.Blueprints.StorageSchemaVersion,
		OwnerUserId = storage.OwnerUserId,
		StorageRevision = storage.StorageRevision or 0,
		UpdatedAt = storage.UpdatedAt or os.time(),
		WorkshopDraft = if storage.WorkshopDraft then BlueprintSerializer.SerializeBlueprint(storage.WorkshopDraft) else nil,
		Slots = serializedSlots,
		LegacyOverflow = if #overflowOut > 0 then overflowOut else nil,
	}
end

local function appendLegacyOverflow(
	overflowOut: { VehicleTypes.LegacyOverflowEntry },
	seenIds: { [string]: boolean },
	bp: VehicleTypes.VehicleBlueprint,
	now: number
)
	if #overflowOut >= GameConfig.Blueprints.MaxLegacyOverflowEntries then
		return
	end
	if seenIds[bp.BlueprintId] then
		return
	end
	seenIds[bp.BlueprintId] = true
	table.insert(overflowOut, {
		OriginalBlueprintId = bp.BlueprintId,
		Name = bp.Name,
		PieceCount = #bp.Pieces,
		UpdatedAt = bp.UpdatedAt,
		MigratedAt = now,
		RecoveredToSlot = nil,
		SerializedBlueprint = BlueprintSerializer.SerializeBlueprint(bp) :: any,
	})
end

function BlueprintSerializer.DeserializePlayerStorage(
	raw: any,
	targetOwnerUserId: number
): (boolean, VehicleTypes.PlayerBlueprintStorage?, boolean, string?)
	if type(raw) ~= "table" then
		return false, nil, false, "Player storage must be a table"
	end

	local now = os.time()
	local slots: { [string]: VehicleTypes.VehicleBlueprint? } = {}
	local legacyOverflow: { VehicleTypes.LegacyOverflowEntry } = {}
	local seenOverflowIds: { [string]: boolean } = {}
	local migrated = false
	local workshopDraft: VehicleTypes.VehicleBlueprint? = nil

	-- Soporte de formato v2 ({ StorageSchemaVersion = 2, Slots = { ["1"] = ..., ... }, WorkshopDraft = ..., LegacyOverflow = ... })
	if type(raw.StorageSchemaVersion) == "number" and raw.StorageSchemaVersion >= 2 then
		if type(raw.WorkshopDraft) == "table" then
			local okDraft, draftBp = BlueprintSerializer.DeserializeBlueprint(raw.WorkshopDraft, targetOwnerUserId)
			if okDraft and draftBp then
				workshopDraft = draftBp
			end
		end

		if type(raw.Slots) == "table" then
			for k, rawSlotBp in pairs(raw.Slots) do
				local numericSlot = if type(k) == "number" then k else tonumber(k)
				if numericSlot and BlueprintSerializer.IsValidSlotIndex(numericSlot) and type(rawSlotBp) == "table" then
					local okSlot, slotBp = BlueprintSerializer.DeserializeBlueprint(rawSlotBp, targetOwnerUserId)
					if okSlot and slotBp then
						slots[BlueprintSerializer.SlotKey(numericSlot)] = slotBp
					end
				elseif type(rawSlotBp) == "table" then
					local okExtra, extraBp = BlueprintSerializer.DeserializeBlueprint(rawSlotBp, targetOwnerUserId)
					if okExtra and extraBp then
						migrated = true
						appendLegacyOverflow(legacyOverflow, seenOverflowIds, extraBp, now)
					end
				end
			end
		end

		if type(raw.LegacyOverflow) == "table" then
			for _, rawEntry in ipairs(raw.LegacyOverflow) do
				if type(rawEntry) == "table" and type(rawEntry.SerializedBlueprint) == "table" then
					local okOv, ovBp = BlueprintSerializer.DeserializeBlueprint(rawEntry.SerializedBlueprint, targetOwnerUserId)
					if okOv and ovBp and not seenOverflowIds[ovBp.BlueprintId] then
						seenOverflowIds[ovBp.BlueprintId] = true
						table.insert(legacyOverflow, {
							OriginalBlueprintId = if type(rawEntry.OriginalBlueprintId) == "string"
								then rawEntry.OriginalBlueprintId
								else ovBp.BlueprintId,
							Name = if type(rawEntry.Name) == "string" and #rawEntry.Name > 0 then rawEntry.Name else ovBp.Name,
							PieceCount = #ovBp.Pieces,
							UpdatedAt = ovBp.UpdatedAt,
							MigratedAt = if type(rawEntry.MigratedAt) == "number" then rawEntry.MigratedAt else now,
							RecoveredToSlot = if type(rawEntry.RecoveredToSlot) == "number" then rawEntry.RecoveredToSlot else nil,
							SerializedBlueprint = BlueprintSerializer.SerializeBlueprint(ovBp) :: any,
						})
					end
				end
			end
		end

		return true, {
			StorageSchemaVersion = GameConfig.Blueprints.StorageSchemaVersion,
			OwnerUserId = targetOwnerUserId,
			StorageRevision = if isFiniteNumber(raw.StorageRevision) then raw.StorageRevision else 0,
			UpdatedAt = if isFiniteNumber(raw.UpdatedAt) then raw.UpdatedAt else now,
			WorkshopDraft = workshopDraft,
			Slots = slots,
			LegacyOverflow = if #legacyOverflow > 0 then legacyOverflow else nil,
		}, migrated, nil
	end

	-- Migración automática desde esquema legacy (hasta 10 blueprints en SavedBlueprints o lista directa)
	migrated = true
	local rawCandidateList: { any } = {}
	if type(raw.SavedBlueprints) == "table" then
		-- Preservar el diseño activo primero si existe en SavedBlueprints
		local activeId = raw.ActiveBlueprintId
		local seenCandidateIds: { [string]: boolean } = {}
		local ordered: { { order: number, bp: any } } = {}
		for _, item in pairs(raw.SavedBlueprints) do
			if type(item) == "table" and type(item.BlueprintId) == "string" and not seenCandidateIds[item.BlueprintId] then
				seenCandidateIds[item.BlueprintId] = true
				local prio = if activeId ~= nil and item.BlueprintId == activeId then 0 else 1
				table.insert(ordered, { order = prio, bp = item })
			end
		end
		table.sort(ordered, function(a, b)
			if a.order ~= b.order then
				return a.order < b.order
			end
			local au = if type(a.bp.UpdatedAt) == "number" then a.bp.UpdatedAt else 0
			local bu = if type(b.bp.UpdatedAt) == "number" then b.bp.UpdatedAt else 0
			return au > bu
		end)
		for _, entry in ipairs(ordered) do
			table.insert(rawCandidateList, entry.bp)
		end
	elseif #raw > 0 then
		for _, item in ipairs(raw) do
			if type(item) == "table" then
				table.insert(rawCandidateList, item)
			end
		end
	elseif type(raw.BlueprintId) == "string" and type(raw.Pieces) == "table" then
		table.insert(rawCandidateList, raw)
	end

	if type(raw.ActiveBlueprint) == "table" then
		local okDraft, draftBp = BlueprintSerializer.DeserializeBlueprint(raw.ActiveBlueprint, targetOwnerUserId)
		if okDraft and draftBp then
			workshopDraft = draftBp
		end
	elseif type(raw.WorkshopDraft) == "table" then
		local okDraft, draftBp = BlueprintSerializer.DeserializeBlueprint(raw.WorkshopDraft, targetOwnerUserId)
		if okDraft and draftBp then
			workshopDraft = draftBp
		end
	end

	local nextSlot = 1
	for _, rawBp in ipairs(rawCandidateList) do
		local okBp, bp = BlueprintSerializer.DeserializeBlueprint(rawBp, targetOwnerUserId)
		if okBp and bp then
			if nextSlot <= GameConfig.Blueprints.MaxSlots then
				slots[BlueprintSerializer.SlotKey(nextSlot)] = bp
				nextSlot += 1
			else
				appendLegacyOverflow(legacyOverflow, seenOverflowIds, bp, now)
			end
		end
	end

	return true, {
		StorageSchemaVersion = GameConfig.Blueprints.StorageSchemaVersion,
		OwnerUserId = targetOwnerUserId,
		StorageRevision = 1,
		UpdatedAt = now,
		WorkshopDraft = workshopDraft,
		Slots = slots,
		LegacyOverflow = if #legacyOverflow > 0 then legacyOverflow else nil,
	}, migrated, nil
end

return BlueprintSerializer

