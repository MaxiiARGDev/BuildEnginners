--!strict
--[=[
	BoosterBehavior
	Contrato modular de propulsor para ServerStorage.ItemAssets.Propulsores.SmallBooster (Fase 3.4 / 5.1).
	- Cero bucles RunService.Heartbeat por pieza: la simulación y vectorización de empuje
	  corren centralizadas en VehicleBoosterService.
	- Inicializa atributos base, nodo de tobera (+Z = +1.5) y efectos reactivos replicados en
	  Workspace (ParticleEmitter, PointLight, Sound) gobernados por cambios de atributos del modelo.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local VehicleTypes = require(ReplicatedStorage.Shared.Types.VehicleTypes)

local BoosterBehavior = {}

local _connectionsByModel: { [Model]: { RBXScriptConnection } } = {}

local function disconnectForModel(model: Model)
	local conns = _connectionsByModel[model]
	if conns then
		for _, conn in ipairs(conns) do
			if conn.Connected then
				conn:Disconnect()
			end
		end
		_connectionsByModel[model] = nil
	end
end

local function ensureNozzleVisuals(primaryPart: BasePart, stats: any): (Attachment, ParticleEmitter, ParticleEmitter, PointLight, Sound)
	local nozzleAtt = primaryPart:FindFirstChild("NozzleAttachment")
	if not nozzleAtt or not nozzleAtt:IsA("Attachment") then
		nozzleAtt = Instance.new("Attachment")
		nozzleAtt.Name = "NozzleAttachment"
		nozzleAtt.Position = GameConfig.Boosters.DefaultNozzleLocalOffset
		nozzleAtt.Parent = primaryPart
	else
		(nozzleAtt :: Attachment).Position = GameConfig.Boosters.DefaultNozzleLocalOffset
	end

	local rarityId = if type(stats) == "table" and type(stats.RarityId) == "string" then stats.RarityId else "Common"
	local flameColorPrimary = Color3.fromRGB(255, 168, 46)
	local flameColorCore = Color3.fromRGB(255, 240, 170)
	if rarityId == "Rare" then
		flameColorPrimary = Color3.fromRGB(72, 188, 255)
		flameColorCore = Color3.fromRGB(215, 245, 255)
	elseif rarityId == "Epic" then
		flameColorPrimary = Color3.fromRGB(192, 118, 255)
		flameColorCore = Color3.fromRGB(245, 220, 255)
	elseif rarityId == "Legendary" then
		flameColorPrimary = Color3.fromRGB(255, 200, 56)
		flameColorCore = Color3.fromRGB(255, 248, 205)
	elseif rarityId == "Mythic" then
		flameColorPrimary = Color3.fromRGB(255, 78, 128)
		flameColorCore = Color3.fromRGB(255, 225, 240)
	end

	local flame = nozzleAtt:FindFirstChild("FlameEmitter")
	if not flame or not flame:IsA("ParticleEmitter") then
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "FlameEmitter"
		pe.EmissionDirection = Enum.NormalId.Back
		pe.Lifetime = NumberRange.new(0.16, 0.34)
		pe.Speed = NumberRange.new(18, 34)
		pe.SpreadAngle = Vector2.new(8, 8)
		pe.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.72),
			NumberSequenceKeypoint.new(0.55, 0.45),
			NumberSequenceKeypoint.new(1, 0.05),
		})
		pe.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, flameColorCore),
			ColorSequenceKeypoint.new(0.45, flameColorPrimary),
			ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 90, 24)),
		})
		pe.LightEmission = 0.85
		pe.LightInfluence = 0
		pe.Rate = 0
		pe.Enabled = false
		pe.Parent = nozzleAtt
		flame = pe
	end

	local smoke = nozzleAtt:FindFirstChild("SmokeEmitter")
	if not smoke or not smoke:IsA("ParticleEmitter") then
		local se = Instance.new("ParticleEmitter")
		se.Name = "SmokeEmitter"
		se.EmissionDirection = Enum.NormalId.Back
		se.Lifetime = NumberRange.new(0.35, 0.75)
		se.Speed = NumberRange.new(10, 20)
		se.SpreadAngle = Vector2.new(14, 14)
		se.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.45),
			NumberSequenceKeypoint.new(1, 1.35),
		})
		se.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.35),
			NumberSequenceKeypoint.new(1, 1),
		})
		se.Color = ColorSequence.new(Color3.fromRGB(190, 196, 208))
		se.Rate = 0
		se.Enabled = false
		se.Parent = nozzleAtt
		smoke = se
	end

	local light = nozzleAtt:FindFirstChild("NozzleLight")
	if not light or not light:IsA("PointLight") then
		local pl = Instance.new("PointLight")
		pl.Name = "NozzleLight"
		pl.Color = flameColorPrimary
		pl.Range = 14
		pl.Brightness = 0
		pl.Enabled = false
		pl.Parent = nozzleAtt
		light = pl
	end

	local sound = primaryPart:FindFirstChild("ThrustSound")
	if not sound or not sound:IsA("Sound") then
		local snd = Instance.new("Sound")
		snd.Name = "ThrustSound"
		snd.Looped = true
		snd.Volume = 0
		snd.PlaybackSpeed = 1.0
		snd.RollOffMaxDistance = 95
		snd.RollOffMinDistance = 10
		snd.Parent = primaryPart
		sound = snd
	end

	return nozzleAtt :: Attachment, flame :: ParticleEmitter, smoke :: ParticleEmitter, light :: PointLight, sound :: Sound
end

local function applyReactiveVisualState(
	model: Model,
	flame: ParticleEmitter,
	smoke: ParticleEmitter,
	light: PointLight,
	sound: Sound
)
	local frac = math.clamp(tonumber(model:GetAttribute("ThrottleFraction")) or 0, 0, 1)
	local state = tostring(model:GetAttribute("BoosterState") or "Idle")
	local emitting = frac > 0.02 and (state == "Igniting" or state == "Active" or state == "RampDown")

	flame.Enabled = emitting
	flame.Rate = if emitting then math.round(28 + frac * 68) else 0
	flame.Speed = if emitting then NumberRange.new(14 + frac * 14, 24 + frac * 22) else NumberRange.new(18, 34)

	smoke.Enabled = emitting
	smoke.Rate = if emitting then math.round(10 + frac * 24) else 0

	light.Enabled = emitting
	light.Brightness = if emitting then (0.6 + frac * 2.4) else 0
	light.Range = if emitting then (9 + frac * 8) else 10

	sound.Volume = if emitting then (0.15 + frac * 0.55) else 0
	sound.PlaybackSpeed = 0.85 + frac * 0.40
	if emitting and sound.SoundId ~= "" and not sound.IsPlaying then
		pcall(function()
			sound:Play()
		end)
	elseif not emitting and sound.IsPlaying then
		pcall(function()
			sound:Stop()
		end)
	end
end

function BoosterBehavior.Init(runtime: VehicleTypes.VehicleRuntime, partState: VehicleTypes.RuntimePartState, model: Model)
	if runtime then
		runtime.BoosterPieceIds = runtime.BoosterPieceIds or {}
		if runtime.BoosterPieceIds and not table.find(runtime.BoosterPieceIds, partState.PieceInstanceId) then
			table.insert(runtime.BoosterPieceIds, partState.PieceInstanceId)
		end
	end

	disconnectForModel(model)

	local resolvedStats = if type(partState.Config) == "table" then partState.Config._ResolvedBoosterStats else nil
	local bstCfg = if type(partState.Config) == "table" and type(partState.Config.Booster) == "table"
		then partState.Config.Booster
		else nil

	model:SetAttribute("BoosterActive", false)
	model:SetAttribute("BoosterState", "Idle")
	model:SetAttribute("ThrottleFraction", 0)
	model:SetAttribute("AppliedThrust", 0)
	model:SetAttribute("WorldThrustDirection", Vector3.new(0, 0, -1))
	model:SetAttribute("ThrustLimitRatio", if bstCfg and type(bstCfg.ThrustLimitRatio) == "number" then bstCfg.ThrustLimitRatio else 1.0)
	model:SetAttribute("BoosterEnabled", if bstCfg and type(bstCfg.Enabled) == "boolean" then bstCfg.Enabled else true)
	model:SetAttribute("BehaviorInitialized", true)

	local primaryPart = partState.PrimaryPart or model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
	if primaryPart and primaryPart:IsA("BasePart") then
		local _, flame, smoke, light, sound = ensureNozzleVisuals(primaryPart, resolvedStats)
		applyReactiveVisualState(model, flame, smoke, light, sound)

		local conns: { RBXScriptConnection } = {}
		table.insert(conns, model:GetAttributeChangedSignal("ThrottleFraction"):Connect(function()
			applyReactiveVisualState(model, flame, smoke, light, sound)
		end))
		table.insert(conns, model:GetAttributeChangedSignal("BoosterState"):Connect(function()
			applyReactiveVisualState(model, flame, smoke, light, sound)
		end))
		_connectionsByModel[model] = conns
	end
end

function BoosterBehavior.Destroy(_runtime: VehicleTypes.VehicleRuntime, _partState: VehicleTypes.RuntimePartState, model: Model)
	disconnectForModel(model)
	model:SetAttribute("BoosterActive", false)
	model:SetAttribute("BoosterState", "Idle")
	model:SetAttribute("ThrottleFraction", 0)
	model:SetAttribute("AppliedThrust", 0)
	local nozzleAtt = model:FindFirstChild("NozzleAttachment", true)
	if nozzleAtt and nozzleAtt:IsA("Attachment") then
		local flame = nozzleAtt:FindFirstChild("FlameEmitter")
		if flame and flame:IsA("ParticleEmitter") then
			flame.Enabled = false
			flame.Rate = 0
		end
		local smoke = nozzleAtt:FindFirstChild("SmokeEmitter")
		if smoke and smoke:IsA("ParticleEmitter") then
			smoke.Enabled = false
			smoke.Rate = 0
		end
		local light = nozzleAtt:FindFirstChild("NozzleLight")
		if light and light:IsA("PointLight") then
			light.Enabled = false
			light.Brightness = 0
		end
	end
	local snd = model:FindFirstChild("ThrustSound", true)
	if snd and snd:IsA("Sound") then
		snd.Volume = 0
		if snd.IsPlaying then
			pcall(function()
				snd:Stop()
			end)
		end
	end
end

return BoosterBehavior
