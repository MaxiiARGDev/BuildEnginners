--!strict
--[=[
	AerodynamicsService
	Orquestador modular en servidor de superficies aerodinámicas (Fase 5.3).

	Principios físicos y de arquitectura:
	- Un único bucle RunService.Heartbeat para todos los vehículos activos (cero scripts por pieza).
	- No clasifica vehículos ni exige motores de avión: cada pieza aerodinámica conectada al ensamblaje
	  activo calcula su propia sustentación, resistencia y fuerza lateral estabilizadora según su
	  velocidad local real en el punto (v_CoM + omega × r), su orientación 3D y ángulo de ataque.
	- Aplica fuerzas mediante VectorForce (ApplyAtCenterOfMass = false, RelativeTo = World) en el
	  Attachment del centro de presión local de cada pieza, produciendo momentos reales de cabeceo,
	  balanceo y guiñada respecto al centro de masa sin CFrame manual ni estabilización mágica.
	- Mantiene 100% de funcionalidad mientras CurrentHealth > 0 (sin degradación progresiva por daño parcial)
	  y desactiva/destruye inmediatamente el VectorForce al llegar a 0 HP o desprenderse del vehículo.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AerodynamicsConfig = require(ReplicatedStorage.Shared.Config.AerodynamicsConfig)
local ItemRegistry = require(ReplicatedStorage.Shared.Catalog.ItemRegistry)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

export type PlayerLike = Player | {
	UserId: number,
	Name: string,
}

export type EvaluatedAeroForces = {
	IsStalled: boolean,
	Airspeed: number,
	ChordAirspeed: number,
	AngleOfAttackDeg: number,
	SideslipAngleDeg: number,
	LiftCoefficient: number,
	DragCoefficient: number,
	SideForceCoefficient: number,
	LiftForceMagnitude: number,
	DragForceMagnitude: number,
	SideForceMagnitude: number,
	LiftVectorWorld: Vector3,
	DragVectorWorld: Vector3,
	SideForceVectorWorld: Vector3,
	TotalForceWorld: Vector3,
}

type InternalAeroSurfaceSlot = {
	PieceInstanceId: string,
	ItemId: string,
	Spec: AerodynamicsConfig.AeroSurfaceSpec,
	PartState: VehicleTypes.RuntimePartState,
	PrimaryPart: BasePart?,
	ModelInstance: Model?,
	ForceAttachment: Attachment?,
	VectorForce: VectorForce?,
	LastState: VehicleTypes.AeroSurfaceRuntimeState,
}

type VehicleAeroContext = {
	Runtime: VehicleTypes.VehicleRuntime,
	OwnerUserId: number,
	SurfaceSlots: { InternalAeroSurfaceSlot },
	SurfaceSlotsByPieceId: { [string]: InternalAeroSurfaceSlot },
	ControlInputs: {
		Pitch: number,
		Roll: number,
		Yaw: number,
	},
	SimulatedTime: number,
	LastTelemetryWriteClock: number,
	LastSnapshot: VehicleTypes.AerodynamicsTelemetrySnapshot,
}

local AerodynamicsService = {
	Name = "AerodynamicsService",
}

local _initialized = false
local _started = false
local _heartbeatConn: RBXScriptConnection? = nil
local _contextsByUserId: { [number]: VehicleAeroContext } = {}
local _windVelocityOverride: Vector3? = nil

local function extractUserId(playerOrUserId: PlayerLike | number): number
	if type(playerOrUserId) == "number" then
		return playerOrUserId
	elseif typeof(playerOrUserId) == "Instance" and playerOrUserId:IsA("Player") then
		return playerOrUserId.UserId
	elseif type(playerOrUserId) == "table" and type((playerOrUserId :: any).UserId) == "number" then
		return (playerOrUserId :: any).UserId
	end
	error("[AerodynamicsService] Invalid player or userId", 3)
end

local function isFiniteNumber(n: number): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

local function sanitizeVector3(v: Vector3?): Vector3
	if typeof(v) ~= "Vector3" then
		return Vector3.zero
	end
	if not isFiniteNumber(v.X) or not isFiniteNumber(v.Y) or not isFiniteNumber(v.Z) then
		return Vector3.zero
	end
	return v
end

local function signNonZero(x: number): number
	return if x < 0 then -1 else 1
end

local function isSurfaceOperational(partState: VehicleTypes.RuntimePartState?): boolean
	if not partState then
		return false
	end
	if not partState.IsFunctional or partState.IsDetached or partState.IsDestroyed then
		return false
	end
	local curHealth = if partState.CurrentHealth ~= nil then partState.CurrentHealth else partState.CurrentDurability
	if type(curHealth) == "number" and curHealth <= 0 then
		return false
	end
	if partState.HealthState == "Disabled" then
		return false
	end
	return true
end

local function computeControlDeflectionDeg(
	spec: AerodynamicsConfig.AeroSurfaceSpec,
	inputs: { Pitch: number, Roll: number, Yaw: number }?
): number
	if not inputs or spec.ControlAuthorityDeg <= 0 then
		return 0
	end
	if spec.ControlRole == "Aileron" then
		return math.clamp(inputs.Roll, -1, 1) * spec.ControlAuthorityDeg * spec.ControlInvertSign
	elseif spec.ControlRole == "Elevator" then
		return math.clamp(inputs.Pitch, -1, 1) * spec.ControlAuthorityDeg * spec.ControlInvertSign
	elseif spec.ControlRole == "Rudder" then
		return math.clamp(inputs.Yaw, -1, 1) * spec.ControlAuthorityDeg * spec.ControlInvertSign
	end
	return 0
end

--[=[
	Evalúa de manera pura y determinista las fuerzas aerodinámicas sobre una superficie individual
	dados su CFrame en el mundo y la velocidad puntual de la superficie en el espacio del mundo.
]=]
function AerodynamicsService.EvaluateSurfaceForces(
	spec: AerodynamicsConfig.AeroSurfaceSpec,
	surfaceWorldCFrame: CFrame,
	pointVelocityWorld: Vector3,
	windVelocityWorld: Vector3?,
	controlDeflectionDeg: number?
): EvaluatedAeroForces
	local S = AerodynamicsConfig.Simulation
	local vPoint = sanitizeVector3(pointVelocityWorld)
	local vWind = sanitizeVector3(windVelocityWorld or _windVelocityOverride)
	local vRel = vPoint - vWind
	local rawSpeed = vRel.Magnitude

	if rawSpeed < S.MinAirspeedStudsPerSec then
		return {
			IsStalled = false,
			Airspeed = rawSpeed,
			ChordAirspeed = 0,
			AngleOfAttackDeg = 0,
			SideslipAngleDeg = 0,
			LiftCoefficient = 0,
			DragCoefficient = 0,
			SideForceCoefficient = 0,
			LiftForceMagnitude = 0,
			DragForceMagnitude = 0,
			SideForceMagnitude = 0,
			LiftVectorWorld = Vector3.zero,
			DragVectorWorld = Vector3.zero,
			SideForceVectorWorld = Vector3.zero,
			TotalForceWorld = Vector3.zero,
		}
	end

	local effSpeed = math.min(rawSpeed, S.MaxEffectiveAirspeedStudsPerSec)
	if rawSpeed > effSpeed and rawSpeed > 1e-6 then
		vRel = vRel * (effSpeed / rawSpeed)
	end

	local forwardAxis = sanitizeVector3(surfaceWorldCFrame.LookVector)
	local upAxis = sanitizeVector3(surfaceWorldCFrame.UpVector)
	local rightAxis = sanitizeVector3(surfaceWorldCFrame.RightVector)

	local vFwd = vRel:Dot(forwardAxis)
	local vUp = vRel:Dot(upAxis)
	local vLat = vRel:Dot(rightAxis)

	local chordSpeed = math.sqrt(vFwd * vFwd + vUp * vUp)
	local deflectionRad = math.rad(controlDeflectionDeg or 0)

	local alphaRad = 0
	local alphaDeg = 0
	local isStalled = false
	local cl = 0
	local liftVec = Vector3.zero
	local liftMag = 0

	if chordSpeed >= S.MinChordAirspeedStudsPerSec then
		-- Ángulo de ataque respecto al plano de cuerda: positivo cuando el aire incide desde abajo (vUp < 0)
		alphaRad = math.atan2(-vUp, math.abs(vFwd)) + deflectionRad
		alphaDeg = math.deg(alphaRad)

		local flowEff = if vFwd >= 0 then 1.0 else S.ReverseFlowLiftEfficiency
		local forwardRatio = vFwd / chordSpeed
		local camberFactor = forwardRatio * math.cos(alphaRad)
		if vFwd < 0 then
			camberFactor *= S.ReverseFlowLiftEfficiency
		end

		local absAlphaDeg = math.abs(alphaDeg)
		local stallDeg = math.max(1.0, spec.StallAngleDeg)
		local fullStallDeg = math.max(stallDeg + 2.0, spec.FullStallAngleDeg)

		local function evalLinearCL(angRad: number): number
			local rawCL = spec.ZeroAlphaLiftCoefficient * camberFactor
				+ spec.LiftCoefficientSlope * angRad * flowEff
			return math.clamp(rawCL, -spec.MaxLiftCoefficient, spec.MaxLiftCoefficient)
		end

		if absAlphaDeg <= stallDeg then
			isStalled = false
			cl = evalLinearCL(alphaRad)
		else
			isStalled = true
			local signA = signNonZero(alphaRad)
			local peakRad = signA * math.rad(stallDeg)
			local clPeak = evalLinearCL(peakRad)
			local flatPlateCL = S.PostStallLiftScale * math.sin(2 * alphaRad) * flowEff
			-- Garantizar que en pérdida la sustentación sea menor que el pico previo al stall
			local maxPostMag = math.abs(clPeak) * 0.58
			if math.abs(flatPlateCL) > maxPostMag then
				flatPlateCL = signNonZero(flatPlateCL) * maxPostMag
			end

			if absAlphaDeg < fullStallDeg then
				local t = math.clamp((absAlphaDeg - stallDeg) / (fullStallDeg - stallDeg), 0, 1)
				local smoothT = t * t * (3 - 2 * t)
				cl = clPeak + (flatPlateCL - clPeak) * smoothT
			else
				cl = flatPlateCL
			end
		end

		local qChord = 0.5 * S.AirDensity * chordSpeed * chordSpeed
		-- Vector unitario perpendicular al flujo en el plano (forwardAxis, upAxis), orientado hacia +upAxis cuando CL > 0
		local fSign = signNonZero(vFwd)
		local rawLiftDir = (upAxis * math.abs(vFwd) - forwardAxis * (fSign * vUp)) / chordSpeed
		local unitLiftDir = if rawLiftDir.Magnitude > 1e-5 then rawLiftDir.Unit else upAxis

		local signedLiftForce = qChord * spec.WingArea * cl
		liftVec = unitLiftDir * signedLiftForce
		liftMag = math.abs(signedLiftForce)
	end

	-- Fuerza lateral pasiva del estabilizador vertical (AircraftTail / derivas)
	local betaDeg = 0
	local cy = 0
	local sideVec = Vector3.zero
	local sideMag = 0

	if spec.VerticalStabilizerArea > 0 then
		local yawSpeed = math.sqrt(vFwd * vFwd + vLat * vLat)
		if yawSpeed >= S.MinChordAirspeedStudsPerSec then
			local betaRad = math.atan2(-vLat, math.abs(vFwd))
			betaDeg = math.deg(betaRad)
			local flowEffYaw = if vFwd >= 0 then 1.0 else S.ReverseFlowLiftEfficiency
			local absBeta = math.abs(betaDeg)
			if absBeta <= S.SideslipStallAngleDeg then
				cy = math.clamp(
					spec.YawLiftSlope * betaRad * flowEffYaw,
					-spec.MaxYawSideForceCoefficient,
					spec.MaxYawSideForceCoefficient
				)
			else
				local peakBetaRad = signNonZero(betaRad) * math.rad(S.SideslipStallAngleDeg)
				local cyPeak = math.clamp(
					spec.YawLiftSlope * peakBetaRad * flowEffYaw,
					-spec.MaxYawSideForceCoefficient,
					spec.MaxYawSideForceCoefficient
				)
				local flatCy = S.PostStallLiftScale * math.sin(2 * betaRad) * flowEffYaw
				local t = math.clamp(
					(absBeta - S.SideslipStallAngleDeg) / math.max(1, S.SideslipFullStallAngleDeg - S.SideslipStallAngleDeg),
					0,
					1
				)
				cy = cyPeak + (flatCy - cyPeak) * t
			end

			local qYaw = 0.5 * S.AirDensity * yawSpeed * yawSpeed
			local fSign = signNonZero(vFwd)
			local rawSideDir = (rightAxis * math.abs(vFwd) - forwardAxis * (fSign * vLat)) / yawSpeed
			local unitSideDir = if rawSideDir.Magnitude > 1e-5 then rawSideDir.Unit else rightAxis
			local signedSideForce = qYaw * spec.VerticalStabilizerArea * cy
			sideVec = unitSideDir * signedSideForce
			sideMag = math.abs(signedSideForce)
		end
	end

	-- Resistencia aerodinámica total (siempre opuesta al vector velocidad relativa 3D)
	local qTotal = 0.5 * S.AirDensity * effSpeed * effSpeed
	local sinAlpha = math.sin(alphaRad)
	local stallWakeDrag = if isStalled then (0.38 * spec.PostStallDragCoefficient) else 0
	local cd = spec.BaseDragCoefficient
		+ spec.InducedDragFactor * (cl * cl)
		+ spec.PostStallDragCoefficient * (sinAlpha * sinAlpha)
		+ stallWakeDrag

	local effectiveDragArea = spec.WingArea + spec.VerticalStabilizerArea * 0.35
	local dragMag = qTotal * effectiveDragArea * cd
	if spec.VerticalStabilizerArea > 0 and math.abs(cy) > 1e-4 then
		dragMag += qTotal * spec.VerticalStabilizerArea * (0.055 * cy * cy)
	end

	local dragDir = -vRel.Unit
	local dragVec = dragDir * dragMag

	local totalForce = liftVec + dragVec + sideVec
	local totalMag = totalForce.Magnitude
	if totalMag > S.MaxForcePerSurface and totalMag > 1e-6 then
		local scale = S.MaxForcePerSurface / totalMag
		totalForce *= scale
		liftVec *= scale
		dragVec *= scale
		sideVec *= scale
		liftMag *= scale
		dragMag *= scale
		sideMag *= scale
	end

	return {
		IsStalled = isStalled,
		Airspeed = effSpeed,
		ChordAirspeed = chordSpeed,
		AngleOfAttackDeg = alphaDeg,
		SideslipAngleDeg = betaDeg,
		LiftCoefficient = cl,
		DragCoefficient = cd,
		SideForceCoefficient = cy,
		LiftForceMagnitude = liftMag,
		DragForceMagnitude = dragMag,
		SideForceMagnitude = sideMag,
		LiftVectorWorld = sanitizeVector3(liftVec),
		DragVectorWorld = sanitizeVector3(dragVec),
		SideForceVectorWorld = sanitizeVector3(sideVec),
		TotalForceWorld = sanitizeVector3(totalForce),
	}
end

local function writeSlotAttributes(slot: InternalAeroSurfaceSlot)
	local model = slot.ModelInstance
	if not model or not model.Parent then
		return
	end
	local st = slot.LastState
	model:SetAttribute("AeroIsFunctional", st.IsFunctional)
	model:SetAttribute("AeroIsStalled", st.IsStalled)
	model:SetAttribute("AeroAirspeed", math.round(st.Airspeed * 10) / 10)
	model:SetAttribute("AeroAoADeg", math.round(st.AngleOfAttackDeg * 10) / 10)
	model:SetAttribute("AeroLiftForce", math.round(st.LiftForceMagnitude * 10) / 10)
	model:SetAttribute("AeroDragForce", math.round(st.DragForceMagnitude * 10) / 10)
end

local function writeRootTelemetryAttributes(ctx: VehicleAeroContext, snap: VehicleTypes.AerodynamicsTelemetrySnapshot)
	local root = ctx.Runtime.RootModel
	if not root or not root.Parent then
		return
	end
	root:SetAttribute("AERO_SurfaceCount", snap.SurfaceCount)
	root:SetAttribute("AERO_FunctionalSurfaceCount", snap.FunctionalSurfaceCount)
	root:SetAttribute("AERO_ActiveForceSurfaceCount", snap.ActiveForceSurfaceCount)
	root:SetAttribute("AERO_StalledSurfaceCount", snap.StalledSurfaceCount)
	root:SetAttribute("AERO_TotalLiftMagnitude", math.round(snap.TotalLiftMagnitude * 10) / 10)
	root:SetAttribute("AERO_TotalDragMagnitude", math.round(snap.TotalDragMagnitude * 10) / 10)
	root:SetAttribute("AERO_TotalSideForceMagnitude", math.round(snap.TotalSideForceMagnitude * 10) / 10)
	root:SetAttribute("AERO_NetLiftVector", snap.NetLiftVectorWorld)
	root:SetAttribute("AERO_NetDragVector", snap.NetDragVectorWorld)
	root:SetAttribute("AERO_NetForceVector", snap.NetAeroForceWorld)
	root:SetAttribute("AERO_NetTorqueAboutCoM", snap.NetAeroTorqueAboutCoMWorld)
end

local function stepVehicleAerodynamics(ctx: VehicleAeroContext, dt: number)
	local S = AerodynamicsConfig.Simulation
	local runtime = ctx.Runtime
	local rootModel = runtime.RootModel
	if not rootModel or not rootModel.Parent then
		return
	end

	ctx.SimulatedTime += math.max(0, dt)

	local refPart = runtime.DriverSeatPart or runtime.PrimaryPart
	local refVel = if refPart and refPart.Parent then sanitizeVector3(refPart.AssemblyLinearVelocity) else Vector3.zero
	local comWorld = if refPart and refPart.Parent then sanitizeVector3(refPart.AssemblyCenterOfMass) else Vector3.zero
	local vehicleSpeed = refVel.Magnitude

	local functionalCount = 0
	local activeForceCount = 0
	local stalledCount = 0
	local totalLiftMag = 0
	local totalDragMag = 0
	local totalSideMag = 0
	local netLiftVec = Vector3.zero
	local netDragVec = Vector3.zero
	local netForceVec = Vector3.zero
	local netTorqueVec = Vector3.zero

	local pendingForcesBySlot: { [InternalAeroSurfaceSlot]: Vector3 } = {}
	local surfaceStates: { VehicleTypes.AeroSurfaceRuntimeState } = table.create(#ctx.SurfaceSlots)

	for _, slot in ipairs(ctx.SurfaceSlots) do
		local primary = slot.PrimaryPart
		local operational = isSurfaceOperational(slot.PartState)
			and primary ~= nil
			and primary.Parent ~= nil
			and not primary.Anchored
			and primary:IsDescendantOf(rootModel)

		if not operational then
			if slot.VectorForce and slot.VectorForce.Parent then
				slot.VectorForce.Force = Vector3.zero
				slot.VectorForce.Enabled = false
			end
			local zeroState: VehicleTypes.AeroSurfaceRuntimeState = {
				PieceInstanceId = slot.PieceInstanceId,
				ItemId = slot.ItemId,
				SurfaceType = slot.Spec.SurfaceType,
				Side = slot.Spec.Side,
				ControlRole = slot.Spec.ControlRole,
				IsFunctional = false,
				IsDetached = slot.PartState.IsDetached == true,
				IsStalled = false,
				Airspeed = 0,
				ChordAirspeed = 0,
				AngleOfAttackDeg = 0,
				SideslipAngleDeg = 0,
				LiftCoefficient = 0,
				DragCoefficient = 0,
				SideForceCoefficient = 0,
				LiftForceMagnitude = 0,
				DragForceMagnitude = 0,
				SideForceMagnitude = 0,
				LiftVectorWorld = Vector3.zero,
				DragVectorWorld = Vector3.zero,
				SideForceVectorWorld = Vector3.zero,
				TotalForceWorld = Vector3.zero,
				WorldApplicationPosition = if primary then primary.Position else Vector3.zero,
				TorqueAboutCoMWorld = Vector3.zero,
			}
			slot.LastState = zeroState
			table.insert(surfaceStates, zeroState)
			continue
		end

		functionalCount += 1
		local part = primary :: BasePart
		local att = slot.ForceAttachment
		local appWorldPos = if att and att.Parent then att.WorldPosition else part.CFrame:PointToWorldSpace(slot.Spec.CenterOfPressureLocalOffset)
		local partCoM = sanitizeVector3(part.AssemblyCenterOfMass)
		if comWorld == Vector3.zero then
			comWorld = partCoM
		end

		local linVel = sanitizeVector3(part.AssemblyLinearVelocity)
		local angVel = sanitizeVector3(part.AssemblyAngularVelocity)
		local rotVel = angVel:Cross(appWorldPos - partCoM)
		if rotVel.Magnitude > S.MaxAngularVelocityContributionStudsPerSec and rotVel.Magnitude > 1e-6 then
			rotVel = rotVel * (S.MaxAngularVelocityContributionStudsPerSec / rotVel.Magnitude)
		end
		local pointVel = linVel + rotVel

		local deflectionDeg = computeControlDeflectionDeg(slot.Spec, ctx.ControlInputs)
		local eval = AerodynamicsService.EvaluateSurfaceForces(
			slot.Spec,
			part.CFrame,
			pointVel,
			_windVelocityOverride,
			deflectionDeg
		)

		if eval.IsStalled then
			stalledCount += 1
		end

		local leverArm = appWorldPos - comWorld
		local torqueWorld = sanitizeVector3(leverArm:Cross(eval.TotalForceWorld))

		pendingForcesBySlot[slot] = eval.TotalForceWorld
		totalLiftMag += eval.LiftForceMagnitude
		totalDragMag += eval.DragForceMagnitude
		totalSideMag += eval.SideForceMagnitude
		netLiftVec += eval.LiftVectorWorld
		netDragVec += eval.DragVectorWorld
		netForceVec += eval.TotalForceWorld
		netTorqueVec += torqueWorld

		local st: VehicleTypes.AeroSurfaceRuntimeState = {
			PieceInstanceId = slot.PieceInstanceId,
			ItemId = slot.ItemId,
			SurfaceType = slot.Spec.SurfaceType,
			Side = slot.Spec.Side,
			ControlRole = slot.Spec.ControlRole,
			IsFunctional = true,
			IsDetached = false,
			IsStalled = eval.IsStalled,
			Airspeed = eval.Airspeed,
			ChordAirspeed = eval.ChordAirspeed,
			AngleOfAttackDeg = eval.AngleOfAttackDeg,
			SideslipAngleDeg = eval.SideslipAngleDeg,
			LiftCoefficient = eval.LiftCoefficient,
			DragCoefficient = eval.DragCoefficient,
			SideForceCoefficient = eval.SideForceCoefficient,
			LiftForceMagnitude = eval.LiftForceMagnitude,
			DragForceMagnitude = eval.DragForceMagnitude,
			SideForceMagnitude = eval.SideForceMagnitude,
			LiftVectorWorld = eval.LiftVectorWorld,
			DragVectorWorld = eval.DragVectorWorld,
			SideForceVectorWorld = eval.SideForceVectorWorld,
			TotalForceWorld = eval.TotalForceWorld,
			WorldApplicationPosition = appWorldPos,
			TorqueAboutCoMWorld = torqueWorld,
		}
		slot.LastState = st
		table.insert(surfaceStates, st)
	end

	-- Tope global proporcional por vehículo para preservar equilibrio de momentos ante velocidades extremas
	local globalScale = 1.0
	local netMag = netForceVec.Magnitude
	if netMag > S.MaxTotalAerodynamicForce and netMag > 1e-6 then
		globalScale = S.MaxTotalAerodynamicForce / netMag
		netForceVec *= globalScale
		netLiftVec *= globalScale
		netDragVec *= globalScale
		netTorqueVec *= globalScale
		totalLiftMag *= globalScale
		totalDragMag *= globalScale
		totalSideMag *= globalScale
	end

	for _, slot in ipairs(ctx.SurfaceSlots) do
		local force = pendingForcesBySlot[slot]
		local vf = slot.VectorForce
		if vf and vf.Parent then
			if force and force.Magnitude * globalScale >= S.MinAppliedForceThreshold then
				local scaledForce = sanitizeVector3(force * globalScale)
				vf.Force = scaledForce
				vf.Enabled = true
				activeForceCount += 1
			else
				vf.Force = Vector3.zero
				vf.Enabled = false
			end
		end
	end

	local snapshot: VehicleTypes.AerodynamicsTelemetrySnapshot = {
		RuntimeId = runtime.RuntimeId,
		OwnerUserId = ctx.OwnerUserId,
		SurfaceCount = #ctx.SurfaceSlots,
		FunctionalSurfaceCount = functionalCount,
		ActiveForceSurfaceCount = activeForceCount,
		StalledSurfaceCount = stalledCount,
		VehicleSpeedStudsPerSec = vehicleSpeed,
		TotalLiftMagnitude = totalLiftMag,
		TotalDragMagnitude = totalDragMag,
		TotalSideForceMagnitude = totalSideMag,
		NetLiftVectorWorld = netLiftVec,
		NetDragVectorWorld = netDragVec,
		NetAeroForceWorld = netForceVec,
		NetAeroTorqueAboutCoMWorld = netTorqueVec,
		Surfaces = surfaceStates,
	}
	ctx.LastSnapshot = snapshot

	if (ctx.SimulatedTime - ctx.LastTelemetryWriteClock) >= S.TelemetryUpdateIntervalSeconds then
		ctx.LastTelemetryWriteClock = ctx.SimulatedTime
		for _, slot in ipairs(ctx.SurfaceSlots) do
			writeSlotAttributes(slot)
		end
		writeRootTelemetryAttributes(ctx, snapshot)
	end
end

function AerodynamicsService.RegisterRuntime(runtime: VehicleTypes.VehicleRuntime)
	if not runtime then
		return
	end
	local userId = runtime.OwnerUserId
	AerodynamicsService.UnregisterRuntime(runtime)

	local S = AerodynamicsConfig.Simulation
	local surfaceSlots: { InternalAeroSurfaceSlot } = {}
	local surfaceSlotsByPieceId: { [string]: InternalAeroSurfaceSlot } = {}
	local aeroPieceIds: { string } = {}

	local sortedIds: { string } = {}
	for pid in pairs(runtime.Parts) do
		table.insert(sortedIds, pid)
	end
	table.sort(sortedIds)

	for _, pid in ipairs(sortedIds) do
		local partState = runtime.Parts[pid]
		local spec = AerodynamicsConfig.GetSurfaceSpec(partState.ItemId)
		if not spec then
			continue
		end

		local primaryPart = partState.PrimaryPart
		local forceAtt: Attachment? = nil
		local vectorForce: VectorForce? = nil

		if primaryPart then
			local existingAtt = primaryPart:FindFirstChild(S.AttachmentName)
			if existingAtt and existingAtt:IsA("Attachment") then
				existingAtt.Position = spec.CenterOfPressureLocalOffset
				forceAtt = existingAtt
			else
				local att = Instance.new("Attachment")
				att.Name = S.AttachmentName
				att.Position = spec.CenterOfPressureLocalOffset
				att.Parent = primaryPart
				forceAtt = att
			end

			local existingVf = primaryPart:FindFirstChild(S.VectorForceName)
			if existingVf and existingVf:IsA("VectorForce") then
				existingVf.Attachment0 = forceAtt
				existingVf.ApplyAtCenterOfMass = false
				existingVf.RelativeTo = Enum.ActuatorRelativeTo.World
				existingVf.Force = Vector3.zero
				existingVf.Enabled = false
				vectorForce = existingVf
			else
				local vf = Instance.new("VectorForce")
				vf.Name = S.VectorForceName
				vf.Attachment0 = forceAtt
				vf.ApplyAtCenterOfMass = false
				vf.RelativeTo = Enum.ActuatorRelativeTo.World
				vf.Force = Vector3.zero
				vf.Enabled = false
				vf.Parent = primaryPart
				vectorForce = vf
			end
		end

		local initialState: VehicleTypes.AeroSurfaceRuntimeState = {
			PieceInstanceId = pid,
			ItemId = partState.ItemId,
			SurfaceType = spec.SurfaceType,
			Side = spec.Side,
			ControlRole = spec.ControlRole,
			IsFunctional = isSurfaceOperational(partState),
			IsDetached = partState.IsDetached == true,
			IsStalled = false,
			Airspeed = 0,
			ChordAirspeed = 0,
			AngleOfAttackDeg = 0,
			SideslipAngleDeg = 0,
			LiftCoefficient = 0,
			DragCoefficient = 0,
			SideForceCoefficient = 0,
			LiftForceMagnitude = 0,
			DragForceMagnitude = 0,
			SideForceMagnitude = 0,
			LiftVectorWorld = Vector3.zero,
			DragVectorWorld = Vector3.zero,
			SideForceVectorWorld = Vector3.zero,
			TotalForceWorld = Vector3.zero,
			WorldApplicationPosition = if primaryPart then primaryPart.Position else Vector3.zero,
			TorqueAboutCoMWorld = Vector3.zero,
		}

		local slot: InternalAeroSurfaceSlot = {
			PieceInstanceId = pid,
			ItemId = partState.ItemId,
			Spec = spec,
			PartState = partState,
			PrimaryPart = primaryPart,
			ModelInstance = partState.ModelInstance,
			ForceAttachment = forceAtt,
			VectorForce = vectorForce,
			LastState = initialState,
		}

		writeSlotAttributes(slot)
		table.insert(surfaceSlots, slot)
		surfaceSlotsByPieceId[pid] = slot
		table.insert(aeroPieceIds, pid)
	end

	runtime.AerodynamicPieceIds = aeroPieceIds

	local ctx: VehicleAeroContext = {
		Runtime = runtime,
		OwnerUserId = userId,
		SurfaceSlots = surfaceSlots,
		SurfaceSlotsByPieceId = surfaceSlotsByPieceId,
		ControlInputs = {
			Pitch = 0,
			Roll = 0,
			Yaw = 0,
		},
		SimulatedTime = 0,
		LastTelemetryWriteClock = -10,
		LastSnapshot = nil :: any,
	}

	_contextsByUserId[userId] = ctx
	stepVehicleAerodynamics(ctx, 0)
	writeRootTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function AerodynamicsService.DetachPiece(runtime: VehicleTypes.VehicleRuntime, pieceId: string)
	if not runtime then
		return
	end
	local ctx = _contextsByUserId[runtime.OwnerUserId]
	if not ctx or ctx.Runtime ~= runtime then
		return
	end

	for i = #ctx.SurfaceSlots, 1, -1 do
		local slot = ctx.SurfaceSlots[i]
		if slot.PieceInstanceId == pieceId or slot.PartState == runtime.Parts[pieceId] then
			if slot.VectorForce then
				slot.VectorForce.Force = Vector3.zero
				slot.VectorForce.Enabled = false
				slot.VectorForce:Destroy()
				slot.VectorForce = nil
			end
			if slot.ForceAttachment then
				slot.ForceAttachment:Destroy()
				slot.ForceAttachment = nil
			end
			slot.LastState.IsFunctional = false
			slot.LastState.IsDetached = true
			slot.LastState.IsStalled = false
			slot.LastState.LiftForceMagnitude = 0
			slot.LastState.DragForceMagnitude = 0
			slot.LastState.SideForceMagnitude = 0
			slot.LastState.LiftVectorWorld = Vector3.zero
			slot.LastState.DragVectorWorld = Vector3.zero
			slot.LastState.SideForceVectorWorld = Vector3.zero
			slot.LastState.TotalForceWorld = Vector3.zero
			slot.LastState.TorqueAboutCoMWorld = Vector3.zero
			writeSlotAttributes(slot)
			table.remove(ctx.SurfaceSlots, i)
		end
	end

	ctx.SurfaceSlotsByPieceId[pieceId] = nil

	if runtime.AerodynamicPieceIds then
		local idx = table.find(runtime.AerodynamicPieceIds, pieceId)
		if idx then
			table.remove(runtime.AerodynamicPieceIds, idx)
		end
	end

	stepVehicleAerodynamics(ctx, 0)
	writeRootTelemetryAttributes(ctx, ctx.LastSnapshot)
end

function AerodynamicsService.UnregisterRuntime(runtimeOrUserId: VehicleTypes.VehicleRuntime | PlayerLike | number)
	local userId: number
	local targetRuntime: VehicleTypes.VehicleRuntime? = nil
	if type(runtimeOrUserId) == "table" and type((runtimeOrUserId :: any).OwnerUserId) == "number" then
		targetRuntime = runtimeOrUserId :: VehicleTypes.VehicleRuntime
		userId = targetRuntime.OwnerUserId
	else
		userId = extractUserId(runtimeOrUserId :: any)
	end

	local ctx = _contextsByUserId[userId]
	if not ctx then
		return
	end
	if targetRuntime and ctx.Runtime ~= targetRuntime then
		return
	end

	for _, slot in ipairs(ctx.SurfaceSlots) do
		if slot.VectorForce then
			slot.VectorForce.Force = Vector3.zero
			slot.VectorForce.Enabled = false
			slot.VectorForce:Destroy()
			slot.VectorForce = nil
		end
	end

	_contextsByUserId[userId] = nil
end

function AerodynamicsService.SetControlInputs(
	playerOrUserId: PlayerLike | number,
	inputs: VehicleTypes.AeroFlightControlInputs?
)
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return
	end
	if not inputs then
		ctx.ControlInputs.Pitch = 0
		ctx.ControlInputs.Roll = 0
		ctx.ControlInputs.Yaw = 0
		return
	end
	ctx.ControlInputs.Pitch = if isFiniteNumber(inputs.Pitch :: any) then math.clamp(inputs.Pitch :: number, -1, 1) else 0
	ctx.ControlInputs.Roll = if isFiniteNumber(inputs.Roll :: any) then math.clamp(inputs.Roll :: number, -1, 1) else 0
	ctx.ControlInputs.Yaw = if isFiniteNumber(inputs.Yaw :: any) then math.clamp(inputs.Yaw :: number, -1, 1) else 0
end

function AerodynamicsService.StepRuntime(playerOrUserId: PlayerLike | number, dt: number): VehicleTypes.AerodynamicsTelemetrySnapshot?
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return nil
	end
	stepVehicleAerodynamics(ctx, dt)
	return ctx.LastSnapshot
end

function AerodynamicsService.StepAll(dt: number)
	for _, ctx in pairs(_contextsByUserId) do
		stepVehicleAerodynamics(ctx, dt)
	end
end

function AerodynamicsService.GetTelemetrySnapshot(playerOrUserId: PlayerLike | number): VehicleTypes.AerodynamicsTelemetrySnapshot?
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return nil
	end
	return ctx.LastSnapshot
end

function AerodynamicsService.GetSurfaceState(
	playerOrUserId: PlayerLike | number,
	pieceInstanceId: string
): VehicleTypes.AeroSurfaceRuntimeState?
	local userId = extractUserId(playerOrUserId)
	local ctx = _contextsByUserId[userId]
	if not ctx then
		return nil
	end
	local slot = ctx.SurfaceSlotsByPieceId[pieceInstanceId]
	return if slot then slot.LastState else nil
end

function AerodynamicsService.SetWindVelocityForTests(windVelocity: Vector3?)
	_windVelocityOverride = if windVelocity then sanitizeVector3(windVelocity) else nil
end

function AerodynamicsService.Init()
	if _initialized then
		return
	end
	ItemRegistry.Init()
	_initialized = true
end

function AerodynamicsService.Start()
	if not _initialized then
		AerodynamicsService.Init()
	end
	if _started then
		return
	end
	_started = true

	if _heartbeatConn then
		_heartbeatConn:Disconnect()
	end
	_heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		AerodynamicsService.StepAll(dt)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		AerodynamicsService.UnregisterRuntime(player.UserId)
	end)
end

function AerodynamicsService._ResetForTests()
	for userId in pairs(table.clone(_contextsByUserId)) do
		AerodynamicsService.UnregisterRuntime(userId)
	end
	table.clear(_contextsByUserId)
	_windVelocityOverride = nil
	if _heartbeatConn then
		_heartbeatConn:Disconnect()
		_heartbeatConn = nil
	end
	_initialized = false
	_started = false
end

return AerodynamicsService
