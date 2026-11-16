--!strict
--[=[
	WheelAutoConfiguration
	Analizador geométrico puro y resolvedor de precedencia híbrida (Auto + Manual) para ruedas modulares.
	- Compartido entre cliente (inspector contextual) y servidor (validación, ensamblaje y launch prep).
	- Respeta precedencia estricta:
	  Defaults de catálogo/configuración < Detección automática geométrica < Sobrescrituras manuales persistidas.
	- No depende exclusivamente del centroide si existe DriverSeat válido; soporta 2, 3, 4, 6, 8+ ruedas
	  y layouts asimétricos con degradación segura y advertencias claras.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type WheelItemSpec = {
	WheelRadius: number,
	WheelWidth: number,
	LocalSpinAxis: Vector3,
}

export type AnalyzeOptions = {
	PrimaryPieceIds: { string }?,
	TargetPieceId: string?,
	PartMassByPieceId: { [string]: number }?,
	WheelGeometryByItemId: { [string]: WheelItemSpec }?,
}

local WheelAutoConfiguration = {}

local ALLOWED_WHEEL_CONFIG_KEYS: { [string]: boolean } = {
	SteeringMode = true,
	MaxSteeringAngle = true,
	SteeringSpeed = true,
	SteeringDirectionMultiplier = true,
	SuspensionEnabled = true,
	SuspensionTravel = true,
	SpringStiffness = true,
	SpringDamping = true,
	RideHeight = true,
	IsDriven = true,
	DriveDirection = true,
}

local function isFiniteNumber(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function isWheelItemId(itemId: string): boolean
	local def = ItemRegistry.TryGet(itemId)
	return def ~= nil and def.Category == "Wheels"
end

function WheelAutoConfiguration.IsWheelItem(itemId: string): boolean
	return isWheelItemId(itemId)
end

function WheelAutoConfiguration.ResolveWheelItemSpec(
	itemId: string,
	customSpecs: { [string]: WheelItemSpec }?
): WheelItemSpec
	if customSpecs and customSpecs[itemId] then
		return customSpecs[itemId]
	end
	return {
		WheelRadius = GameConfig.Wheels.DefaultWheelRadius,
		WheelWidth = GameConfig.Wheels.DefaultWheelWidth,
		LocalSpinAxis = GameConfig.Wheels.DefaultLocalSpinAxis,
	}
end

--[=[
	Valida y extrae únicamente sobrescrituras manuales válidas para Piece.Config.Wheel.
	Devuelve (ok, cleanedOverrides?, errCode?, errMsg?).
	Un nil o tabla vacía normaliza a nil (todo en modo Auto).
]=]
function WheelAutoConfiguration.ValidateManualOverrides(rawWheelTable: any): (
	boolean,
	VehicleTypes.WheelPieceConfigOverrides?,
	string?,
	string?
)
	if rawWheelTable == nil then
		return true, nil, nil, nil
	end
	if type(rawWheelTable) ~= "table" or getmetatable(rawWheelTable) ~= nil then
		return false, nil, "InvalidPayload", "Config.Wheel debe ser una tabla plana"
	end

	local W = GameConfig.Wheels
	local cleaned: { [string]: any } = {}
	local hasAny = false

	for k, v in pairs(rawWheelTable) do
		if type(k) ~= "string" or not ALLOWED_WHEEL_CONFIG_KEYS[k] then
			return false, nil, "InvalidPayload", `Clave de configuración de rueda no permitida: {tostring(k)}`
		end

		if k == "SteeringMode" then
			if v == "Auto" then
				-- "Auto" equivale a limpiar sobrescritura manual
				continue
			elseif v ~= "Enabled" and v ~= "Disabled" then
				return false, nil, "InvalidPayload", "SteeringMode debe ser 'Auto', 'Enabled' o 'Disabled'"
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "MaxSteeringAngle" then
			if not isFiniteNumber(v) then
				return false, nil, "InvalidConfigRange", "MaxSteeringAngle debe ser un número finito"
			end
			if v < W.MinSteeringAngleDeg or v > W.MaxSteeringAngleDeg then
				return false,
					nil,
					"InvalidConfigRange",
					`MaxSteeringAngle fuera de rango ({W.MinSteeringAngleDeg}..{W.MaxSteeringAngleDeg}°)`
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "SteeringSpeed" then
			if not isFiniteNumber(v) then
				return false, nil, "InvalidConfigRange", "SteeringSpeed debe ser un número finito"
			end
			if v < W.MinSteeringSpeedDegPerSec or v > W.MaxSteeringSpeedDegPerSec then
				return false,
					nil,
					"InvalidConfigRange",
					`SteeringSpeed fuera de rango ({W.MinSteeringSpeedDegPerSec}..{W.MaxSteeringSpeedDegPerSec} °/s)`
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "SteeringDirectionMultiplier" then
			if not isFiniteNumber(v) or (v ~= 1 and v ~= -1) then
				return false, nil, "InvalidConfigRange", "SteeringDirectionMultiplier debe ser 1 o -1"
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "SuspensionEnabled" or k == "IsDriven" then
			if type(v) ~= "boolean" then
				return false, nil, "InvalidPayload", `{k} debe ser booleano`
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "SuspensionTravel" then
			if not isFiniteNumber(v) then
				return false, nil, "InvalidConfigRange", "SuspensionTravel debe ser un número finito"
			end
			if v < W.MinSuspensionTravelStuds or v > W.MaxSuspensionTravelStuds then
				return false,
					nil,
					"InvalidConfigRange",
					`SuspensionTravel fuera de rango ({W.MinSuspensionTravelStuds}..{W.MaxSuspensionTravelStuds})`
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "SpringStiffness" then
			if not isFiniteNumber(v) then
				return false, nil, "InvalidConfigRange", "SpringStiffness debe ser un número finito"
			end
			if v < W.MinSpringStiffness or v > W.MaxSpringStiffness then
				return false,
					nil,
					"InvalidConfigRange",
					`SpringStiffness fuera de rango ({W.MinSpringStiffness}..{W.MaxSpringStiffness})`
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "SpringDamping" then
			if not isFiniteNumber(v) then
				return false, nil, "InvalidConfigRange", "SpringDamping debe ser un número finito"
			end
			if v < W.MinSpringDamping or v > W.MaxSpringDamping then
				return false,
					nil,
					"InvalidConfigRange",
					`SpringDamping fuera de rango ({W.MinSpringDamping}..{W.MaxSpringDamping})`
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "RideHeight" then
			if not isFiniteNumber(v) then
				return false, nil, "InvalidConfigRange", "RideHeight debe ser un número finito"
			end
			if v < W.MinRideHeightOffset or v > W.MaxRideHeightOffset then
				return false,
					nil,
					"InvalidConfigRange",
					`RideHeight fuera de rango ({W.MinRideHeightOffset}..{W.MaxRideHeightOffset})`
			end
			cleaned[k] = v
			hasAny = true
		elseif k == "DriveDirection" then
			if not isFiniteNumber(v) or (v ~= 1 and v ~= -1) then
				return false, nil, "InvalidConfigRange", "DriveDirection debe ser 1 o -1"
			end
			cleaned[k] = v
			hasAny = true
		end
	end

	if not hasAny then
		return true, nil, nil, nil
	end
	return true, cleaned :: VehicleTypes.WheelPieceConfigOverrides, nil, nil
end

function WheelAutoConfiguration.ExtractManualOverrides(piece: VehicleTypes.BlueprintPiece): VehicleTypes.WheelPieceConfigOverrides?
	local cfg = piece.Config
	if type(cfg) ~= "table" then
		return nil
	end
	local rawWheel = cfg.Wheel
	if type(rawWheel) ~= "table" then
		return nil
	end
	local ok, cleaned = WheelAutoConfiguration.ValidateManualOverrides(rawWheel)
	if ok and cleaned then
		return cleaned
	end
	return nil
end

local function collectConnectedComponentIds(
	startPieceId: string,
	piecesById: { [string]: VehicleTypes.BlueprintPiece },
	connections: { VehicleTypes.BlueprintConnection }
): { [string]: boolean }
	local adj: { [string]: { string } } = {}
	for _, conn in ipairs(connections) do
		if piecesById[conn.FromPieceId] and piecesById[conn.ToPieceId] then
			local listA = adj[conn.FromPieceId]
			if not listA then
				listA = {}
				adj[conn.FromPieceId] = listA
			end
			table.insert(listA, conn.ToPieceId)

			local listB = adj[conn.ToPieceId]
			if not listB then
				listB = {}
				adj[conn.ToPieceId] = listB
			end
			table.insert(listB, conn.FromPieceId)
		end
	end

	local visited: { [string]: boolean } = { [startPieceId] = true }
	local queue = { startPieceId }
	local head = 1
	while head <= #queue do
		local cur = queue[head]
		head += 1
		local neighbors = adj[cur]
		if neighbors then
			for _, nb in ipairs(neighbors) do
				if not visited[nb] then
					visited[nb] = true
					table.insert(queue, nb)
				end
			end
		end
	end

	return visited
end

local function estimatePieceMass(piece: VehicleTypes.BlueprintPiece, massOverrides: { [string]: number }?): number
	if massOverrides and isFiniteNumber(massOverrides[piece.InstanceId]) then
		return math.max(0.1, massOverrides[piece.InstanceId])
	end
	local known = GameConfig.Wheels.EstimatedStudioMassByItemId[piece.ItemId]
	if isFiniteNumber(known) then
		return known
	end
	local def = ItemRegistry.TryGet(piece.ItemId)
	if def and isFiniteNumber(def.Stats.Weight) then
		return math.max(0.1, def.Stats.Weight)
	end
	return 2.5
end

local function computeAutoSpringTuning(effMassPerWheel: number): (number, number)
	local W = GameConfig.Wheels
	local stiffness = math.round(effMassPerWheel * (W.AutoSpringOmega * W.AutoSpringOmega))
	stiffness = math.clamp(stiffness, W.MinSpringStiffness, W.MaxSpringStiffness)

	local critical = 2 * math.sqrt(stiffness * math.max(0.5, effMassPerWheel))
	local damping = math.round(W.AutoSpringDampingRatio * critical)
	local safeMaxDamping = math.min(W.MaxSpringDamping, W.AutoSpringMaxDamping or W.MaxSpringDamping)
	damping = math.clamp(damping, W.MinSpringDamping, safeMaxDamping)
	return stiffness, damping
end

--[=[
	Analiza geométricamente las ruedas del vehículo (o componente activo) y resuelve
	cada propiedad combinando Auto + Sobrescrituras Manuales persistidas.
]=]
function WheelAutoConfiguration.AnalyzeBlueprint(
	blueprint: VehicleTypes.VehicleBlueprint,
	options: AnalyzeOptions?
): VehicleTypes.VehicleWheelAnalysis
	local W = GameConfig.Wheels
	local piecesById: { [string]: VehicleTypes.BlueprintPiece } = {}
	for _, piece in ipairs(blueprint.Pieces) do
		piecesById[piece.InstanceId] = piece
	end

	-- Determinar subconjunto relevante de piezas (componente del TargetPieceId o PrimaryPieceIds)
	local scopeSet: { [string]: boolean }? = nil
	if options and options.PrimaryPieceIds and #options.PrimaryPieceIds > 0 then
		scopeSet = {}
		for _, pid in ipairs(options.PrimaryPieceIds) do
			if piecesById[pid] then
				(scopeSet :: { [string]: boolean })[pid] = true
			end
		end
	elseif options and options.TargetPieceId and piecesById[options.TargetPieceId] then
		scopeSet = collectConnectedComponentIds(options.TargetPieceId, piecesById, blueprint.Connections)
	end

	local scopePieces: { VehicleTypes.BlueprintPiece } = {}
	local wheelPieces: { VehicleTypes.BlueprintPiece } = {}
	local driverSeats: { VehicleTypes.BlueprintPiece } = {}

	for _, piece in ipairs(blueprint.Pieces) do
		if not scopeSet or scopeSet[piece.InstanceId] then
			table.insert(scopePieces, piece)
			if isWheelItemId(piece.ItemId) then
				table.insert(wheelPieces, piece)
			elseif piece.ItemId == GameConfig.LaunchPrep.DriverSeatItemId then
				table.insert(driverSeats, piece)
			end
		end
	end

	-- Si hay TargetPieceId pero no vino scopeSet, ya cubierto; si no hubo Primary ni Target, elegir componente del primer DriverSeat si existe
	if not scopeSet and #driverSeats == 1 and #wheelPieces > 0 then
		local seatComp = collectConnectedComponentIds(driverSeats[1].InstanceId, piecesById, blueprint.Connections)
		local filteredScope: { VehicleTypes.BlueprintPiece } = {}
		local filteredWheels: { VehicleTypes.BlueprintPiece } = {}
		for _, p in ipairs(scopePieces) do
			if seatComp[p.InstanceId] then
				table.insert(filteredScope, p)
				if isWheelItemId(p.ItemId) then
					table.insert(filteredWheels, p)
				end
			end
		end
		if #filteredWheels > 0 then
			scopePieces = filteredScope
			wheelPieces = filteredWheels
		end
	end

	local globalWarnings: { string } = {}
	local hasSeatReference = (#driverSeats == 1)
	local vehicleForward = Vector3.new(0, 0, -1)
	local vehicleRight = Vector3.new(1, 0, 0)
	local vehicleUp = Vector3.new(0, 1, 0)
	local layoutAmbiguous = false

	if #driverSeats == 1 then
		local seatCF = driverSeats[1].LocalCFrame
		vehicleForward = seatCF.LookVector.Unit
		vehicleRight = seatCF.RightVector.Unit
		vehicleUp = seatCF.UpVector.Unit
	elseif #driverSeats > 1 then
		local seatCF = driverSeats[1].LocalCFrame
		vehicleForward = seatCF.LookVector.Unit
		vehicleRight = seatCF.RightVector.Unit
		vehicleUp = seatCF.UpVector.Unit
		layoutAmbiguous = true
		table.insert(globalWarnings, "Múltiples DriverSeat detectados; orientación automática ambigua")
	else
		layoutAmbiguous = true
		table.insert(globalWarnings, "Sin DriverSeat de referencia; agrega uno para confirmar frente y atrás")
	end

	if #wheelPieces == 0 then
		return {
			HasSeatReference = hasSeatReference,
			VehicleForward = vehicleForward,
			VehicleRight = vehicleRight,
			VehicleUp = vehicleUp,
			WheelCount = 0,
			AxleCount = 0,
			EstimatedChassisMass = 0,
			IsAmbiguous = layoutAmbiguous,
			AmbiguityWarnings = globalWarnings,
			ByPieceId = {},
			OrderedWheelIds = {},
		}
	end

	-- Calcular masa total suspendida (chasis + utilidades + motores + carga conductor estimada)
	local suspendedMass = 0
	for _, p in ipairs(scopePieces) do
		if not isWheelItemId(p.ItemId) then
			suspendedMass += estimatePieceMass(p, if options then options.PartMassByPieceId else nil)
		end
	end
	local effectiveTotalSupportedMass = suspendedMass + W.EstimatedDriverMass

	-- Determinar centro lateral/vertical de las ruedas y proyecciones longitudinales brutas
	type WheelRawInfo = {
		Piece: VehicleTypes.BlueprintPiece,
		Spec: WheelItemSpec,
		RawLongitudinal: number,
		RawLateral: number,
		RawVertical: number,
		ForwardDot: number,
		RightDot: number,
		UpDot: number,
		OrientationBlocksSteering: boolean,
		OrientationBlocksSuspension: boolean,
		OrientationWarning: string?,
		AxleGroupIndex: number,
	}

	local minLong, maxLong = math.huge, -math.huge
	local minLat, maxLat = math.huge, -math.huge
	local minVert, maxVert = math.huge, -math.huge
	local rawList: { WheelRawInfo } = table.create(#wheelPieces)

	for _, wp in ipairs(wheelPieces) do
		local spec = WheelAutoConfiguration.ResolveWheelItemSpec(wp.ItemId, if options then options.WheelGeometryByItemId else nil)
		local pos = wp.LocalCFrame.Position
		local longVal = pos:Dot(vehicleForward)
		local latVal = pos:Dot(vehicleRight)
		local vertVal = pos:Dot(vehicleUp)

		if longVal < minLong then
			minLong = longVal
		end
		if longVal > maxLong then
			maxLong = longVal
		end
		if latVal < minLat then
			minLat = latVal
		end
		if latVal > maxLat then
			maxLat = latVal
		end
		if vertVal < minVert then
			minVert = vertVal
		end
		if vertVal > maxVert then
			maxVert = vertVal
		end

		local spinWorld = wp.LocalCFrame:VectorToWorldSpace(spec.LocalSpinAxis).Unit
		local fwdDot = spinWorld:Dot(vehicleForward)
		local rightDot = spinWorld:Dot(vehicleRight)
		local upDot = spinWorld:Dot(vehicleUp)

		local blocksSteer = false
		local blocksSusp = false
		local orientWarn: string? = nil

		if math.abs(upDot) >= W.OrientationUpFlatBlockDot then
			blocksSteer = true
			blocksSusp = true
			orientWarn = "Rueda orientada horizontalmente; su eje de giro apunta verticalmente"
		elseif math.abs(rightDot) < W.OrientationAxisMinAlignment then
			blocksSteer = true
			orientWarn = "Eje de giro perpendicular al avance; rotá la rueda para rodamiento normal"
		end

		table.insert(rawList, {
			Piece = wp,
			Spec = spec,
			RawLongitudinal = longVal,
			RawLateral = latVal,
			RawVertical = vertVal,
			ForwardDot = fwdDot,
			RightDot = rightDot,
			UpDot = upDot,
			OrientationBlocksSteering = blocksSteer,
			OrientationBlocksSuspension = blocksSusp,
			OrientationWarning = orientWarn,
			AxleGroupIndex = 1,
		})
	end

	-- Ordenar de adelante hacia atrás (mayor proyección longitudinal primero), desempate izquierda -> derecha
	table.sort(rawList, function(a, b)
		if math.abs(a.RawLongitudinal - b.RawLongitudinal) > 1e-4 then
			return a.RawLongitudinal > b.RawLongitudinal
		end
		if math.abs(a.RawLateral - b.RawLateral) > 1e-4 then
			return a.RawLateral < b.RawLateral
		end
		return a.Piece.InstanceId < b.Piece.InstanceId
	end)

	local midLong = (minLong + maxLong) * 0.5
	local midLat = (minLat + maxLat) * 0.5
	local midVert = (minVert + maxVert) * 0.5

	-- Agrupar por ejes longitudinales
	local axleGroups: { { RawLongCenter: number, Items: { WheelRawInfo } } } = {}
	for _, info in ipairs(rawList) do
		local placedGroupIdx: number? = nil
		for gIdx, grp in ipairs(axleGroups) do
			if math.abs(info.RawLongitudinal - grp.RawLongCenter) <= W.AxleGroupLongitudinalToleranceStuds then
				placedGroupIdx = gIdx
				break
			end
		end
		if placedGroupIdx then
			local grp = axleGroups[placedGroupIdx :: number]
			table.insert(grp.Items, info)
			local sumL = 0
			for _, item in ipairs(grp.Items) do
				sumL += item.RawLongitudinal
			end
			grp.RawLongCenter = sumL / #grp.Items
		else
			table.insert(axleGroups, {
				RawLongCenter = info.RawLongitudinal,
				Items = { info },
			})
		end
	end

	for gIdx, grp in ipairs(axleGroups) do
		for _, item in ipairs(grp.Items) do
			item.AxleGroupIndex = gIdx
		end
	end

	local axleCount = #axleGroups
	local wheelCount = #rawList

	-- Evaluar simetría / ambigüedad global del layout respecto al eje central del chasis (o ruedas si no hay chasis)
	local minChassisLat, maxChassisLat = math.huge, -math.huge
	local nonWheelLatCount = 0
	for _, p in ipairs(scopePieces) do
		if not isWheelItemId(p.ItemId) then
			local latC = p.LocalCFrame.Position:Dot(vehicleRight)
			if latC < minChassisLat then
				minChassisLat = latC
			end
			if latC > maxChassisLat then
				maxChassisLat = latC
			end
			nonWheelLatCount += 1
		end
	end
	local refCenterLat = if nonWheelLatCount > 0 then (minChassisLat + maxChassisLat) * 0.5 else midLat

	local leftCount, rightCount = 0, 0
	for _, info in ipairs(rawList) do
		local relLat = info.RawLateral - refCenterLat
		if relLat < -W.CenterLineToleranceStuds then
			leftCount += 1
		elseif relLat > W.CenterLineToleranceStuds then
			rightCount += 1
		end
	end

	local asymmetricFlag = false
	if wheelCount >= 3 and math.abs(leftCount - rightCount) >= 2 then
		asymmetricFlag = true
		table.insert(globalWarnings, "Disposición lateral asimétrica de ruedas; revisá configuración manual")
	elseif wheelCount == 2 and axleCount == 1 then
		asymmetricFlag = true
		table.insert(globalWarnings, "Solo se detectó un eje (2 ruedas paralelas); verificá si querés dirección")
	elseif wheelCount == 1 then
		asymmetricFlag = true
		table.insert(globalWarnings, "Solo 1 rueda en el ensamblaje; detección de dirección automática desactivada")
	elseif axleCount == 1 and wheelCount > 1 then
		asymmetricFlag = true
		table.insert(globalWarnings, "Todas las ruedas están sobre un único eje; se requiere confirmación manual para dirección")
	end

	if asymmetricFlag then
		layoutAmbiguous = true
	end

	-- Calcular cuántas ruedas tienen suspensión activa estimada para repartir rigidez auto
	local estimatedSuspendedCount = 0
	for _, info in ipairs(rawList) do
		local manual = WheelAutoConfiguration.ExtractManualOverrides(info.Piece)
		local suspOverride = if manual then manual.SuspensionEnabled else nil
		local autoSusp = not info.OrientationBlocksSuspension
		local effSusp = if suspOverride ~= nil then suspOverride else autoSusp
		if effSusp then
			estimatedSuspendedCount += 1
		end
	end

	local effMassPerWheel = effectiveTotalSupportedMass / math.max(1, if estimatedSuspendedCount > 0 then estimatedSuspendedCount else wheelCount)
	local autoStiffness, autoDamping = computeAutoSpringTuning(effMassPerWheel)

	local byPieceId: { [string]: VehicleTypes.ResolvedWheelConfig } = {}
	local orderedIds: { string } = table.create(wheelCount)

	for i, info in ipairs(rawList) do
		local piece = info.Piece
		local relLong = info.RawLongitudinal - midLong
		local relLat = info.RawLateral - midLat
		local relVert = info.RawVertical - midVert

		local sideRole: VehicleTypes.WheelSideRole
		if relLat < -W.CenterLineToleranceStuds then
			sideRole = "Left"
		elseif relLat > W.CenterLineToleranceStuds then
			sideRole = "Right"
		else
			sideRole = "Center"
		end

		local axleRole: VehicleTypes.WheelAxlePositionRole
		if not hasSeatReference then
			axleRole = if axleCount <= 1
				then "SingleAxle"
				elseif info.AxleGroupIndex == 1 then "Front"
				elseif info.AxleGroupIndex == axleCount then "Rear"
				else "Middle"
		elseif axleCount <= 1 then
			axleRole = "SingleAxle"
		elseif info.AxleGroupIndex == 1 then
			axleRole = "Front"
		elseif info.AxleGroupIndex == axleCount then
			axleRole = "Rear"
		else
			axleRole = "Middle"
		end

		-- Política Auto de dirección conservadora y clara
		local autoSteerEnabled = false
		local localAmbiguous = layoutAmbiguous or info.OrientationWarning ~= nil
		local localReason: string? = info.OrientationWarning

		if info.OrientationBlocksSteering then
			autoSteerEnabled = false
			localAmbiguous = true
		elseif not hasSeatReference then
			autoSteerEnabled = false
			localAmbiguous = true
			localReason = localReason or "Falta DriverSeat para determinar eje delantero"
		elseif axleCount <= 1 then
			autoSteerEnabled = false
			localAmbiguous = true
			localReason = localReason or "Un solo eje detectado; dirección automática en espera"
		elseif axleRole == "Front" then
			-- En 3 ruedas, verificar que rueda delantera única no esté severamente descentrada respecto a traseras
			if wheelCount == 3 and #axleGroups[1].Items == 1 and math.abs(relLat) > 1.25 then
				autoSteerEnabled = true
				localAmbiguous = true
				localReason = localReason or "Triciclo asimétrico: rueda delantera desplazada; verificá respuesta"
			else
				autoSteerEnabled = true
			end
		elseif axleRole == "Middle" then
			-- En 6 u 8 ruedas, los ejes intermedios quedan sin dirección salvo configuración manual
			autoSteerEnabled = false
		else
			autoSteerEnabled = false
		end

		local autoSuspEnabled = not info.OrientationBlocksSuspension
		local autoSteeringDirMult = 1
		local autoMaxAngle = W.DefaultMaxSteeringAngleDeg
		local autoSteeringSpeed = W.DefaultSteeringSpeedDegPerSec
		local autoTravel = W.DefaultSuspensionTravelStuds
		local autoRideHeight = W.DefaultRideHeightOffset
		local autoIsDriven = true
		local autoDriveDir = 1

		-- Leer sobrescrituras manuales y combinar con precedencia estricta
		local manual = WheelAutoConfiguration.ExtractManualOverrides(piece)
		local hasManual = manual ~= nil

		local sources: VehicleTypes.WheelResolvedSources = {
			SteeringMode = if manual and manual.SteeringMode ~= nil then "Manual" else "Auto",
			MaxSteeringAngle = if manual and manual.MaxSteeringAngle ~= nil then "Manual" else "Auto",
			SteeringSpeed = if manual and manual.SteeringSpeed ~= nil then "Manual" else "Auto",
			SteeringDirectionMultiplier = if manual and manual.SteeringDirectionMultiplier ~= nil then "Manual" else "Auto",
			SuspensionEnabled = if manual and manual.SuspensionEnabled ~= nil then "Manual" else "Auto",
			SuspensionTravel = if manual and manual.SuspensionTravel ~= nil then "Manual" else "Auto",
			SpringStiffness = if manual and manual.SpringStiffness ~= nil then "Manual" else "Auto",
			SpringDamping = if manual and manual.SpringDamping ~= nil then "Manual" else "Auto",
			RideHeight = if manual and manual.RideHeight ~= nil then "Manual" else "Auto",
			IsDriven = if manual and manual.IsDriven ~= nil then "Manual" else "Auto",
			DriveDirection = if manual and manual.DriveDirection ~= nil then "Manual" else "Auto",
		}

		local steeringMode: VehicleTypes.WheelSteeringMode = if manual and manual.SteeringMode ~= nil
			then manual.SteeringMode
			else "Auto"

		local effectiveSteer: boolean
		if steeringMode == "Enabled" then
			effectiveSteer = not info.OrientationBlocksSteering
		elseif steeringMode == "Disabled" then
			effectiveSteer = false
		else
			effectiveSteer = autoSteerEnabled
		end

		local maxAngle = math.clamp(
			if manual and manual.MaxSteeringAngle ~= nil then manual.MaxSteeringAngle else autoMaxAngle,
			W.MinSteeringAngleDeg,
			W.MaxSteeringAngleDeg
		)
		local steerSpeed = math.clamp(
			if manual and manual.SteeringSpeed ~= nil then manual.SteeringSpeed else autoSteeringSpeed,
			W.MinSteeringSpeedDegPerSec,
			W.MaxSteeringSpeedDegPerSec
		)
		local steerMult = if manual and manual.SteeringDirectionMultiplier ~= nil
			then (if manual.SteeringDirectionMultiplier < 0 then -1 else 1)
			else autoSteeringDirMult

		local suspEnabled = if manual and manual.SuspensionEnabled ~= nil then manual.SuspensionEnabled else autoSuspEnabled
		local effectiveSusp = suspEnabled and (not info.OrientationBlocksSuspension)

		local travel = math.clamp(
			if manual and manual.SuspensionTravel ~= nil then manual.SuspensionTravel else autoTravel,
			W.MinSuspensionTravelStuds,
			W.MaxSuspensionTravelStuds
		)
		local stiffness = math.clamp(
			if manual and manual.SpringStiffness ~= nil then manual.SpringStiffness else autoStiffness,
			W.MinSpringStiffness,
			W.MaxSpringStiffness
		)
		local damping = math.clamp(
			if manual and manual.SpringDamping ~= nil then manual.SpringDamping else autoDamping,
			W.MinSpringDamping,
			W.MaxSpringDamping
		)
		local rideHeight = math.clamp(
			if manual and manual.RideHeight ~= nil then manual.RideHeight else autoRideHeight,
			W.MinRideHeightOffset,
			W.MaxRideHeightOffset
		)
		local isDriven = if manual and manual.IsDriven ~= nil then manual.IsDriven else autoIsDriven
		local driveDir = if manual and manual.DriveDirection ~= nil
			then (if manual.DriveDirection < 0 then -1 else 1)
			else autoDriveDir

		local wheelWarnings: { string } = {}
		if info.OrientationWarning then
			table.insert(wheelWarnings, info.OrientationWarning)
		end
		if localReason and localReason ~= info.OrientationWarning and steeringMode == "Auto" then
			table.insert(wheelWarnings, localReason)
		elseif steeringMode == "Enabled" and info.OrientationBlocksSteering then
			table.insert(wheelWarnings, "Dirección manual forzada bloqueada porque el eje de rueda es vertical")
		end
		if #rawList == 2 and axleCount == 2 and i == 1 then
			table.insert(wheelWarnings, "Diseño de 2 ruedas en línea; equilibrio lateral sensible")
		end

		local analysis: VehicleTypes.WheelGeometryAnalysis = {
			PieceInstanceId = piece.InstanceId,
			ItemId = piece.ItemId,
			AxleGroupIndex = info.AxleGroupIndex,
			TotalAxleGroups = axleCount,
			AxleRole = axleRole,
			SideRole = sideRole,
			LongitudinalOffset = relLong,
			LateralOffset = relLat,
			VerticalOffset = relVert,
			LocalSpinAxis = info.Spec.LocalSpinAxis,
			ForwardAlignmentDot = info.ForwardDot,
			RightAlignmentDot = info.RightDot,
			UpAlignmentDot = info.UpDot,
			WheelRadius = info.Spec.WheelRadius,
			WheelWidth = info.Spec.WheelWidth,
			OrientationWarning = info.OrientationWarning,
			OrientationBlocksSteering = info.OrientationBlocksSteering,
			OrientationBlocksSuspension = info.OrientationBlocksSuspension,
			IsAmbiguous = localAmbiguous and steeringMode == "Auto",
			AmbiguityReason = localReason,
			HasSeatReference = hasSeatReference,
		}

		byPieceId[piece.InstanceId] = {
			PieceInstanceId = piece.InstanceId,
			ItemId = piece.ItemId,
			WheelRadius = info.Spec.WheelRadius,
			WheelWidth = info.Spec.WheelWidth,
			LocalSpinAxis = info.Spec.LocalSpinAxis,
			SteeringMode = steeringMode,
			EffectiveSteeringEnabled = effectiveSteer,
			MaxSteeringAngle = maxAngle,
			SteeringSpeed = steerSpeed,
			SteeringDirectionMultiplier = steerMult,
			SuspensionEnabled = suspEnabled,
			EffectiveSuspensionEnabled = effectiveSusp,
			SuspensionTravel = travel,
			SpringStiffness = stiffness,
			SpringDamping = damping,
			RideHeight = rideHeight,
			IsDriven = isDriven,
			DriveDirection = driveDir,
			HasManualOverrides = hasManual,
			Sources = sources,
			Analysis = analysis,
			Warnings = wheelWarnings,
		}
		orderedIds[i] = piece.InstanceId
	end

	return {
		HasSeatReference = hasSeatReference,
		VehicleForward = vehicleForward,
		VehicleRight = vehicleRight,
		VehicleUp = vehicleUp,
		WheelCount = wheelCount,
		AxleCount = axleCount,
		EstimatedChassisMass = suspendedMass,
		IsAmbiguous = layoutAmbiguous,
		AmbiguityWarnings = globalWarnings,
		ByPieceId = byPieceId,
		OrderedWheelIds = orderedIds,
	}
end

return WheelAutoConfiguration
