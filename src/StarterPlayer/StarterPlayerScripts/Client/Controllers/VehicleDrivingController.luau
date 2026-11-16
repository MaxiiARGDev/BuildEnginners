--!strict
--[=[
	VehicleDrivingController
	Controlador cliente de conducción (PC + Móvil) y HUD de telemetría en vivo (Fases 3.3 y 3.4).

	Controles PC:
	- W / Up: Acelerar
	- S / Down: Frenar / Reversa progresiva
	- A / Left, D / Right: Dirección
	- Space: bloqueado mientras se ocupa un asiento
	- LeftShift: Activar propulsores / Boost (Nitro)

	Controles Móvil:
	- Botones táctiles dedicados en pantalla durante conducción: Acelerar, Freno/Reversa, Boost y Dirección.

	HUD de Conducción:
	- Velocidad actual (studs/s), RPM actuales + barra con zona roja/limitador, Estado del motor,
	  Marcha / Dirección (D1..D4, N, BRK, R), Combustible Normal disponible,
	  Nitro (RocketFuel) separado + barra e indicador BOOST ON/OFF + estado de propulsores y alertas.
]=]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildProtocol = require(ReplicatedStorage.Shared.Building.BuildProtocol)

local BuildState = require(script.Parent.BuildState)

export type MountedDrivingHud = {
	HudFrame: Frame,
	TouchControlsFrame: Frame,
	RefreshVisibility: () -> (),
	Destroy: () -> (),
}

local VehicleDrivingController = {}

export type SimulatedDrivingInput = {
	Throttle: number?,
	Brake: number?,
	Steer: number?,
	Boost: boolean?,
}

local _activeConnections: { RBXScriptConnection } = {}
local _activeMountedHud: MountedDrivingHud? = nil
local _simulatedInput: SimulatedDrivingInput? = nil

local function disconnectAllActiveConnections()
	for _, conn in ipairs(_activeConnections) do
		if conn.Connected then
			conn:Disconnect()
		end
	end
	table.clear(_activeConnections)
	_activeMountedHud = nil
end

function VehicleDrivingController.SetSimulatedInput(simInput: SimulatedDrivingInput?)
	_simulatedInput = simInput
end

local function getDrivingInputRemote(): RemoteEvent?
	local remote = ReplicatedStorage:FindFirstChild(BuildProtocol.DrivingInputRemoteEventName)
	if remote and remote:IsA("RemoteEvent") then
		return remote
	end
	return nil
end

local function findLocalRuntimeModel(): Model?
	local plot = BuildState.AssignedPlot
	if (not plot or not plot.Parent) and RunService:IsRunning() then
		local livePlayer = Players.LocalPlayer
		if livePlayer then
			local resolvedPlot, resolvedBz = BuildState.ResolvePlayerPlot(livePlayer)
			if resolvedPlot then
				BuildState.SetPlot(resolvedPlot, resolvedBz)
				plot = resolvedPlot
			end
		end
	end
	if not plot or not plot.Parent then
		return nil
	end
	local dynName = GameConfig.PlotContainers.Dynamic
	if type(dynName) ~= "string" or dynName == "" then
		return nil
	end
	local dyn = plot:FindFirstChild(dynName)
	if not dyn then
		return nil
	end
	local modelName = GameConfig.Runtime.ModelName
	if type(modelName) ~= "string" or modelName == "" then
		return nil
	end
	local model = dyn:FindFirstChild(modelName)
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

function VehicleDrivingController.FindLocalRuntimeModel(): Model?
	return findLocalRuntimeModel()
end

function VehicleDrivingController.GetActiveConnectionCount(): number
	if _activeMountedHud and _activeMountedHud.HudFrame.Parent == nil then
		disconnectAllActiveConnections()
	end
	local count = 0
	for _, conn in ipairs(_activeConnections) do
		if conn.Connected then
			count += 1
		end
	end
	return count
end

function VehicleDrivingController.Unmount()
	disconnectAllActiveConnections()
end

function VehicleDrivingController.Mount(screenGui: ScreenGui): MountedDrivingHud
	disconnectAllActiveConnections()

	local keyState = {
		Forward = false,
		Backward = false,
		Left = false,
		Right = false,
		Boost = false,
	}
	local touchState = {
		Throttle = false,
		Brake = false,
		Left = false,
		Right = false,
		Boost = false,
	}

	local lastSentThrottle = -1
	local lastSentBrake = -1
	local lastSentSteer = -99
	local lastSentBoost = false
	local lastSendClock = 0

	-- Panel HUD de Conducción (inferior-centro, compacto y no intrusivo)
	local hudFrame = Instance.new("Frame")
	hudFrame.Name = "DrivingHudPanel"
	hudFrame.AnchorPoint = Vector2.new(0.5, 1)
	hudFrame.Position = UDim2.new(0.5, 0, 1, -16)
	hudFrame.Size = UDim2.fromOffset(480, 184)
	hudFrame.BackgroundColor3 = Color3.fromRGB(16, 20, 28)
	hudFrame.BackgroundTransparency = 0.10
	hudFrame.BorderSizePixel = 0
	hudFrame.Visible = false
	hudFrame.Parent = screenGui

	local hudCorner = Instance.new("UICorner")
	hudCorner.CornerRadius = UDim.new(0, 10)
	hudCorner.Parent = hudFrame

	local hudStroke = Instance.new("UIStroke")
	hudStroke.Color = Color3.fromRGB(68, 138, 215)
	hudStroke.Thickness = 1.2
	hudStroke.Parent = hudFrame

	-- Indicador de Marcha (Izquierda)
	local gearBox = Instance.new("TextLabel")
	gearBox.Name = "GearBadge"
	gearBox.Size = UDim2.fromOffset(64, 64)
	gearBox.Position = UDim2.fromOffset(12, 12)
	gearBox.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
	gearBox.Font = Enum.Font.GothamBlack
	gearBox.TextSize = 24
	gearBox.TextColor3 = Color3.fromRGB(120, 225, 255)
	gearBox.Text = "N"
	gearBox.Parent = hudFrame

	local gearCorner = Instance.new("UICorner")
	gearCorner.CornerRadius = UDim.new(0, 8)
	gearCorner.Parent = gearBox

	-- Velocímetro
	local speedLbl = Instance.new("TextLabel")
	speedLbl.Name = "SpeedLabel"
	speedLbl.Size = UDim2.fromOffset(136, 36)
	speedLbl.Position = UDim2.fromOffset(86, 10)
	speedLbl.BackgroundTransparency = 1
	speedLbl.Font = Enum.Font.GothamBlack
	speedLbl.TextSize = 24
	speedLbl.TextColor3 = Color3.fromRGB(245, 248, 255)
	speedLbl.TextXAlignment = Enum.TextXAlignment.Left
	speedLbl.Text = "0.0 st/s"
	speedLbl.Parent = hudFrame

	local rpmLbl = Instance.new("TextLabel")
	rpmLbl.Name = "RpmLabel"
	rpmLbl.Size = UDim2.fromOffset(230, 18)
	rpmLbl.Position = UDim2.fromOffset(238, 12)
	rpmLbl.BackgroundTransparency = 1
	rpmLbl.Font = Enum.Font.Code
	rpmLbl.TextSize = 13
	rpmLbl.TextColor3 = Color3.fromRGB(220, 232, 248)
	rpmLbl.TextXAlignment = Enum.TextXAlignment.Right
	rpmLbl.Text = "900 / 5800 RPM"
	rpmLbl.Parent = hudFrame

	-- Barra de RPM
	local rpmBarBg = Instance.new("Frame")
	rpmBarBg.Name = "RpmBarBg"
	rpmBarBg.Size = UDim2.fromOffset(382, 10)
	rpmBarBg.Position = UDim2.fromOffset(86, 44)
	rpmBarBg.BackgroundColor3 = Color3.fromRGB(32, 38, 48)
	rpmBarBg.BorderSizePixel = 0
	rpmBarBg.Parent = hudFrame

	local rpmBgCorner = Instance.new("UICorner")
	rpmBgCorner.CornerRadius = UDim.new(0, 6)
	rpmBgCorner.Parent = rpmBarBg

	local rpmBarFill = Instance.new("Frame")
	rpmBarFill.Name = "RpmBarFill"
	rpmBarFill.Size = UDim2.new(0.15, 0, 1, 0)
	rpmBarFill.BackgroundColor3 = Color3.fromRGB(58, 195, 118)
	rpmBarFill.BorderSizePixel = 0
	rpmBarFill.Parent = rpmBarBg

	local rpmFillCorner = Instance.new("UICorner")
	rpmFillCorner.CornerRadius = UDim.new(0, 6)
	rpmFillCorner.Parent = rpmBarFill

	-- Indicador y barra visual de combustible
	local fuelLbl = Instance.new("TextLabel")
	fuelLbl.Name = "FuelLabel"
	fuelLbl.Size = UDim2.fromOffset(382, 15)
	fuelLbl.Position = UDim2.fromOffset(86, 57)
	fuelLbl.BackgroundTransparency = 1
	fuelLbl.Font = Enum.Font.Code
	fuelLbl.TextSize = 11
	fuelLbl.TextColor3 = Color3.fromRGB(198, 224, 242)
	fuelLbl.TextXAlignment = Enum.TextXAlignment.Left
	fuelLbl.Text = "Comb.: 0.5400 / 0.54 (100.0%)"
	fuelLbl.Parent = hudFrame

	local fuelBarBg = Instance.new("Frame")
	fuelBarBg.Name = "FuelBarBg"
	fuelBarBg.Size = UDim2.fromOffset(382, 8)
	fuelBarBg.Position = UDim2.fromOffset(86, 74)
	fuelBarBg.BackgroundColor3 = Color3.fromRGB(32, 38, 48)
	fuelBarBg.BorderSizePixel = 0
	fuelBarBg.Parent = hudFrame

	local fuelBgCorner = Instance.new("UICorner")
	fuelBgCorner.CornerRadius = UDim.new(0, 4)
	fuelBgCorner.Parent = fuelBarBg

	local fuelBarFill = Instance.new("Frame")
	fuelBarFill.Name = "FuelBarFill"
	fuelBarFill.Size = UDim2.new(1, 0, 1, 0)
	fuelBarFill.BackgroundColor3 = Color3.fromRGB(58, 195, 118)
	fuelBarFill.BorderSizePixel = 0
	fuelBarFill.Parent = fuelBarBg

	local fuelFillCorner = Instance.new("UICorner")
	fuelFillCorner.CornerRadius = UDim.new(0, 4)
	fuelFillCorner.Parent = fuelBarFill

	-- Indicador BOOST (bajo Marcha) + Barra de Nitro (RocketFuel separado)
	local boostBadge = Instance.new("TextLabel")
	boostBadge.Name = "BoostBadge"
	boostBadge.Size = UDim2.fromOffset(64, 28)
	boostBadge.Position = UDim2.fromOffset(12, 82)
	boostBadge.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
	boostBadge.Font = Enum.Font.GothamBlack
	boostBadge.TextSize = 11
	boostBadge.TextColor3 = Color3.fromRGB(150, 175, 205)
	boostBadge.Text = "BOOST OFF"
	boostBadge.Parent = hudFrame

	local boostBadgeCorner = Instance.new("UICorner")
	boostBadgeCorner.CornerRadius = UDim.new(0, 6)
	boostBadgeCorner.Parent = boostBadge

	local nitroLbl = Instance.new("TextLabel")
	nitroLbl.Name = "NitroLabel"
	nitroLbl.Size = UDim2.fromOffset(382, 15)
	nitroLbl.Position = UDim2.fromOffset(86, 85)
	nitroLbl.BackgroundTransparency = 1
	nitroLbl.Font = Enum.Font.Code
	nitroLbl.TextSize = 11
	nitroLbl.TextColor3 = Color3.fromRGB(145, 220, 255)
	nitroLbl.TextXAlignment = Enum.TextXAlignment.Left
	nitroLbl.Text = "Nitro: N/A (Sin propulsores)"
	nitroLbl.Parent = hudFrame

	local nitroBarBg = Instance.new("Frame")
	nitroBarBg.Name = "NitroBarBg"
	nitroBarBg.Size = UDim2.fromOffset(382, 8)
	nitroBarBg.Position = UDim2.fromOffset(86, 102)
	nitroBarBg.BackgroundColor3 = Color3.fromRGB(28, 34, 46)
	nitroBarBg.BorderSizePixel = 0
	nitroBarBg.Parent = hudFrame

	local nitroBgCorner = Instance.new("UICorner")
	nitroBgCorner.CornerRadius = UDim.new(0, 4)
	nitroBgCorner.Parent = nitroBarBg

	local nitroBarFill = Instance.new("Frame")
	nitroBarFill.Name = "NitroBarFill"
	nitroBarFill.Size = UDim2.new(0, 0, 1, 0)
	nitroBarFill.BackgroundColor3 = Color3.fromRGB(56, 189, 248)
	nitroBarFill.BorderSizePixel = 0
	nitroBarFill.Parent = nitroBarBg

	local nitroFillCorner = Instance.new("UICorner")
	nitroFillCorner.CornerRadius = UDim.new(0, 4)
	nitroFillCorner.Parent = nitroBarFill

	-- Resumen de motor, propulsores, potencia y carga
	local summaryLbl = Instance.new("TextLabel")
	summaryLbl.Name = "SummaryLabel"
	summaryLbl.Size = UDim2.fromOffset(456, 18)
	summaryLbl.Position = UDim2.fromOffset(12, 116)
	summaryLbl.BackgroundTransparency = 1
	summaryLbl.Font = Enum.Font.GothamMedium
	summaryLbl.TextSize = 11
	summaryLbl.TextColor3 = Color3.fromRGB(190, 205, 228)
	summaryLbl.TextXAlignment = Enum.TextXAlignment.Left
	summaryLbl.Text = "Motores: 1/1 | Motrices: 4 | Par Rueda: 0 | Carga: 0%"
	summaryLbl.Parent = hudFrame

	local boosterSummaryLbl = Instance.new("TextLabel")
	boosterSummaryLbl.Name = "BoosterSummaryLabel"
	boosterSummaryLbl.Size = UDim2.fromOffset(456, 18)
	boosterSummaryLbl.Position = UDim2.fromOffset(12, 136)
	boosterSummaryLbl.BackgroundTransparency = 1
	boosterSummaryLbl.Font = Enum.Font.GothamMedium
	boosterSummaryLbl.TextSize = 11
	boosterSummaryLbl.TextColor3 = Color3.fromRGB(152, 212, 248)
	boosterSummaryLbl.TextXAlignment = Enum.TextXAlignment.Left
	boosterSummaryLbl.Text = "Propulsores: 0/0 | Activos: 0 | Empuje: 0 / 0"
	boosterSummaryLbl.Parent = hudFrame

	local bottomRowLbl = Instance.new("TextLabel")
	bottomRowLbl.Name = "BottomStatusLabel"
	bottomRowLbl.Size = UDim2.new(1, -24, 0, 20)
	bottomRowLbl.Position = UDim2.fromOffset(12, 158)
	bottomRowLbl.BackgroundTransparency = 1
	bottomRowLbl.Font = Enum.Font.GothamBold
	bottomRowLbl.TextSize = 11
	bottomRowLbl.TextColor3 = Color3.fromRGB(145, 225, 175)
	bottomRowLbl.TextXAlignment = Enum.TextXAlignment.Left
	bottomRowLbl.Text = "Controles: [W] Acelerar · [S] Freno/Rev · [A/D] Dir · [LeftShift] Boost"
	bottomRowLbl.Parent = hudFrame

	-- Controles táctiles para dispositivos móviles (y accesibles en pantalla)
	local touchFrame = Instance.new("Frame")
	touchFrame.Name = "MobileDrivingControls"
	touchFrame.Size = UDim2.new(1, 0, 1, 0)
	touchFrame.BackgroundTransparency = 1
	touchFrame.Visible = false
	touchFrame.Parent = screenGui

	local function createHoldControlBtn(
		name: string,
		label: string,
		pos: UDim2,
		anchor: Vector2,
		size: UDim2,
		baseColor: Color3,
		activeColor: Color3,
		onStateChanged: (pressed: boolean) -> ()
	): TextButton
		local btn = Instance.new("TextButton")
		btn.Name = name
		btn.AnchorPoint = anchor
		btn.Position = pos
		btn.Size = size
		btn.BackgroundColor3 = baseColor
		btn.BackgroundTransparency = 0.18
		btn.Font = Enum.Font.GothamBlack
		btn.TextSize = 13
		btn.TextColor3 = Color3.fromRGB(245, 248, 255)
		btn.Text = label
		btn.AutoButtonColor = false
		btn.Parent = touchFrame

		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 10)
		c.Parent = btn

		btn.InputBegan:Connect(function(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				btn.BackgroundColor3 = activeColor
				onStateChanged(true)
			end
		end)

		local function release(input: InputObject)
			if
				input.UserInputType == Enum.UserInputType.Touch
				or input.UserInputType == Enum.UserInputType.MouseButton1
			then
				btn.BackgroundColor3 = baseColor
				onStateChanged(false)
			end
		end

		btn.InputEnded:Connect(release)
		btn.MouseLeave:Connect(function()
			btn.BackgroundColor3 = baseColor
			onStateChanged(false)
		end)

		return btn
	end

	-- Botones derechos: Acelerador, Freno/Reversa, Boost
	createHoldControlBtn(
		"TouchThrottleBtn",
		"ACELERAR",
		UDim2.new(1, -20, 1, -24),
		Vector2.new(1, 1),
		UDim2.fromOffset(108, 72),
		Color3.fromRGB(40, 148, 86),
		Color3.fromRGB(64, 210, 120),
		function(pressed)
			touchState.Throttle = pressed
		end
	)

	createHoldControlBtn(
		"TouchBrakeBtn",
		"FRENO / REV",
		UDim2.new(1, -138, 1, -24),
		Vector2.new(1, 1),
		UDim2.fromOffset(104, 62),
		Color3.fromRGB(168, 86, 44),
		Color3.fromRGB(228, 118, 60),
		function(pressed)
			touchState.Brake = pressed
		end
	)


	createHoldControlBtn(
		"TouchBoostBtn",
		"BOOST",
		UDim2.new(1, -138, 1, -96),
		Vector2.new(1, 1),
		UDim2.fromOffset(104, 54),
		Color3.fromRGB(34, 128, 215),
		Color3.fromRGB(72, 198, 255),
		function(pressed)
			touchState.Boost = pressed
		end
	)

	-- Botones izquierdos: Dirección Izquierda / Derecha
	createHoldControlBtn(
		"TouchSteerLeftBtn",
		"◀ IZQ",
		UDim2.new(0, 20, 1, -24),
		Vector2.new(0, 1),
		UDim2.fromOffset(88, 62),
		Color3.fromRGB(44, 72, 118),
		Color3.fromRGB(72, 125, 205),
		function(pressed)
			touchState.Left = pressed
		end
	)

	createHoldControlBtn(
		"TouchSteerRightBtn",
		"DER ▶",
		UDim2.new(0, 118, 1, -24),
		Vector2.new(0, 1),
		UDim2.fromOffset(88, 62),
		Color3.fromRGB(44, 72, 118),
		Color3.fromRGB(72, 125, 205),
		function(pressed)
			touchState.Right = pressed
		end
	)

	local function isDrivingNow(): boolean
		return BuildState.RuntimeState == GameConfig.Runtime.States.Driving
	end

	local function resetInputs()
		keyState.Forward = false
		keyState.Backward = false
		keyState.Left = false
		keyState.Right = false
		keyState.Boost = false
		touchState.Throttle = false
		touchState.Brake = false
		touchState.Left = false
		touchState.Right = false
		touchState.Boost = false
		lastSentThrottle = -1
		lastSentBrake = -1
		lastSentSteer = -99
		lastSentBoost = false
	end

	local function updateHudTelemetry()
		local rtModel = findLocalRuntimeModel()
		if not rtModel then
			return
		end

		local speed = (rtModel:GetAttribute("PT_SpeedStudsPerSec") :: number?) or 0
		local rpm = (rtModel:GetAttribute("PT_CombinedRPM") :: number?) or 900
		local maxRpm = math.max(1000, (rtModel:GetAttribute("PT_CombinedMaxRPM") :: number?) or 5800)
		local limiter = (rtModel:GetAttribute("PT_LimiterActive") :: boolean?) == true
		local gearState = (rtModel:GetAttribute("PT_GearState") :: string?) or "Neutral"
		local gearIndex = (rtModel:GetAttribute("PT_ActiveGearIndex") :: number?) or 0
		local engCount = (rtModel:GetAttribute("PT_FunctionalEngineCount") :: number?) or 0
		local totalEngCount = (rtModel:GetAttribute("PT_EngineCount") :: number?) or 0
		local drivenWheels = (rtModel:GetAttribute("PT_DrivenWheelCount") :: number?) or 0
		local wheelTorque = (rtModel:GetAttribute("PT_TotalWheelDriveTorque") :: number?) or 0
		local loadFactor = (rtModel:GetAttribute("PT_CombinedLoadFactor") :: number?) or 0
		local availFuel = (rtModel:GetAttribute("PT_AvailableFuel") :: number?) or 0
		local totalFuel = (rtModel:GetAttribute("PT_TotalFuelCapacity") :: number?) or 0
		local attrFuelFrac = rtModel:GetAttribute("PT_FuelFraction") :: number?
		local fuelFraction = if type(attrFuelFrac) == "number"
			then math.clamp(attrFuelFrac, 0, 1)
			elseif totalFuel > 0 then math.clamp(availFuel / totalFuel, 0, 1)
			else 0
		local fuelRate = (rtModel:GetAttribute("PT_FuelConsumptionRate") :: number?) or 0
		local lowFuel = (rtModel:GetAttribute("PT_LowFuel") :: boolean?) == true
		local outOfFuel = (rtModel:GetAttribute("PT_OutOfFuel") :: boolean?) == true
		local noDrivenErr = (rtModel:GetAttribute("PT_NoDrivenWheelsError") :: boolean?) == true

		local totalBoosterCount = (rtModel:GetAttribute("BS_BoosterCount") :: number?) or 0
		local funcBoosterCount = (rtModel:GetAttribute("BS_FunctionalBoosterCount") :: number?) or 0
		local activeBoosterCount = (rtModel:GetAttribute("BS_ActiveBoosterCount") :: number?) or 0
		local anyBoostActive = (rtModel:GetAttribute("BS_AnyActive") :: boolean?) == true
		local appliedThrust = (rtModel:GetAttribute("BS_TotalAppliedThrust") :: number?) or 0
		local maxThrust = (rtModel:GetAttribute("BS_MaxPossibleThrust") :: number?) or 0
		local totalNitro = (rtModel:GetAttribute("BS_TotalNitroCapacity") :: number?) or 0
		local availNitro = (rtModel:GetAttribute("BS_AvailableNitro") :: number?) or 0
		local attrNitroFrac = rtModel:GetAttribute("BS_NitroFraction") :: number?
		local nitroFraction = if type(attrNitroFrac) == "number"
			then math.clamp(attrNitroFrac, 0, 1)
			elseif totalNitro > 0 then math.clamp(availNitro / totalNitro, 0, 1)
			else 0
		local nitroRate = (rtModel:GetAttribute("BS_NitroConsumptionRate") :: number?) or 0
		local lowNitro = (rtModel:GetAttribute("BS_LowNitro") :: boolean?) == true
		local outOfNitro = (rtModel:GetAttribute("BS_OutOfNitro") :: boolean?) == true

		speedLbl.Text = string.format("%.1f st/s", speed)
		rpmLbl.Text = if limiter
			then string.format("%d / %d RPM [CORTE]", rpm, maxRpm)
			else string.format("%d / %d RPM", rpm, maxRpm)

		local rpmFraction = math.clamp(rpm / maxRpm, 0.04, 1.0)
		rpmBarFill.Size = UDim2.new(rpmFraction, 0, 1, 0)
		if limiter or rpmFraction >= 0.92 then
			rpmBarFill.BackgroundColor3 = Color3.fromRGB(240, 72, 72)
		elseif rpmFraction >= 0.72 then
			rpmBarFill.BackgroundColor3 = Color3.fromRGB(245, 182, 56)
		else
			rpmBarFill.BackgroundColor3 = Color3.fromRGB(58, 195, 118)
		end

		if gearState == "Braking" then
			gearBox.Text = "BRK"
			gearBox.TextColor3 = Color3.fromRGB(255, 165, 72)
		elseif gearState == "Reverse" then
			gearBox.Text = "R"
			gearBox.TextColor3 = Color3.fromRGB(255, 208, 86)
		elseif gearState == "Forward" then
			gearBox.Text = `D{math.max(1, gearIndex)}`
			gearBox.TextColor3 = Color3.fromRGB(110, 240, 155)
		else
			gearBox.Text = "N"
			gearBox.TextColor3 = Color3.fromRGB(150, 210, 255)
		end

		local fuelPct = fuelFraction * 100
		if totalFuel > 0 then
			fuelLbl.Text = string.format("Comb.: %.4f / %.2f (%.1f%%) | Flujo: %.4f/s", availFuel, totalFuel, fuelPct, fuelRate)
		else
			fuelLbl.Text = "Comb.: N/A (Sin depósitos)"
		end

		local barWidth = if outOfFuel or totalFuel <= 0 then 0 else math.clamp(fuelFraction, 0.015, 1.0)
		fuelBarFill.Size = UDim2.new(barWidth, 0, 1, 0)
		if outOfFuel or totalFuel <= 0 then
			fuelBarFill.BackgroundColor3 = Color3.fromRGB(240, 72, 72)
			fuelLbl.TextColor3 = Color3.fromRGB(255, 130, 110)
		elseif lowFuel then
			fuelBarFill.BackgroundColor3 = Color3.fromRGB(245, 182, 56)
			fuelLbl.TextColor3 = Color3.fromRGB(255, 215, 110)
		else
			fuelBarFill.BackgroundColor3 = Color3.fromRGB(58, 195, 118)
			fuelLbl.TextColor3 = Color3.fromRGB(198, 224, 242)
		end

		summaryLbl.Text = string.format(
			"Motores: %d/%d | Motrices: %d | Par Rueda: %d | Carga: %d%%",
			engCount,
			totalEngCount,
			drivenWheels,
			wheelTorque,
			math.round(loadFactor * 100)
		)

		local nitroPct = nitroFraction * 100
		if totalNitro > 0 and totalBoosterCount > 0 then
			nitroLbl.Text = string.format("Nitro: %.0f / %.0f (%.1f%%) | Flujo: %.0f/s", availNitro, totalNitro, nitroPct, nitroRate)
		else
			nitroLbl.Text = "Nitro: N/A (Sin propulsores)"
		end

		local nitroBarWidth = if outOfNitro or totalNitro <= 0 or totalBoosterCount <= 0 then 0 else math.clamp(nitroFraction, 0.015, 1.0)
		nitroBarFill.Size = UDim2.new(nitroBarWidth, 0, 1, 0)
		if outOfNitro or (totalBoosterCount > 0 and totalNitro <= 0) then
			nitroBarFill.BackgroundColor3 = Color3.fromRGB(240, 72, 72)
			nitroLbl.TextColor3 = Color3.fromRGB(255, 130, 110)
		elseif lowNitro then
			nitroBarFill.BackgroundColor3 = Color3.fromRGB(245, 182, 56)
			nitroLbl.TextColor3 = Color3.fromRGB(255, 215, 110)
		elseif totalBoosterCount <= 0 then
			nitroBarFill.BackgroundColor3 = Color3.fromRGB(64, 82, 108)
			nitroLbl.TextColor3 = Color3.fromRGB(145, 165, 192)
		else
			nitroBarFill.BackgroundColor3 = Color3.fromRGB(56, 189, 248)
			nitroLbl.TextColor3 = Color3.fromRGB(145, 220, 255)
		end

		if totalBoosterCount <= 0 then
			boostBadge.Text = "NO BST"
			boostBadge.BackgroundColor3 = Color3.fromRGB(28, 36, 52)
			boostBadge.TextColor3 = Color3.fromRGB(120, 135, 160)
		elseif outOfNitro then
			boostBadge.Text = "NO NITRO"
			boostBadge.BackgroundColor3 = Color3.fromRGB(115, 36, 36)
			boostBadge.TextColor3 = Color3.fromRGB(255, 165, 150)
		elseif anyBoostActive then
			boostBadge.Text = "BOOST ON"
			boostBadge.BackgroundColor3 = Color3.fromRGB(34, 136, 225)
			boostBadge.TextColor3 = Color3.fromRGB(235, 250, 255)
		else
			boostBadge.Text = "BOOST OFF"
			boostBadge.BackgroundColor3 = Color3.fromRGB(36, 48, 68)
			boostBadge.TextColor3 = Color3.fromRGB(165, 205, 235)
		end

		boosterSummaryLbl.Text = string.format(
			"Propulsores: %d/%d | Activos: %d | Empuje: %.0f / %.0f",
			funcBoosterCount,
			totalBoosterCount,
			activeBoosterCount,
			appliedThrust,
			maxThrust
		)

		if noDrivenErr and totalBoosterCount == 0 then
			bottomRowLbl.Text = "⚠ ERROR TREN MOTRIZ: No hay ruedas motrices configuradas (NoDrivenWheels)."
			bottomRowLbl.TextColor3 = Color3.fromRGB(255, 105, 105)
		elseif totalBoosterCount > 0 and outOfNitro and (totalEngCount == 0 or outOfFuel) then
			bottomRowLbl.Text = "⚠ SIN NITRO (0%): Propulsores agotados."
			bottomRowLbl.TextColor3 = Color3.fromRGB(255, 120, 90)
		elseif outOfFuel and totalEngCount > 0 and totalBoosterCount == 0 then
			bottomRowLbl.Text = "⚠ SIN COMBUSTIBLE (0%): Tracción motora cortada (dirección y frenos activos)."
			bottomRowLbl.TextColor3 = Color3.fromRGB(255, 120, 90)
		elseif totalBoosterCount > 0 and outOfNitro then
			bottomRowLbl.Text = "⚠ NITRO AGOTADO (0%): Propulsores sin RocketFuel (motores normales activos)."
			bottomRowLbl.TextColor3 = Color3.fromRGB(255, 150, 95)
		elseif lowNitro and totalBoosterCount > 0 then
			bottomRowLbl.Text = string.format("⚠ NITRO BAJO (%.1f%%): Reserva RocketFuel próxima a agotarse.", nitroPct)
			bottomRowLbl.TextColor3 = Color3.fromRGB(255, 210, 95)
		elseif lowFuel and totalEngCount > 0 then
			bottomRowLbl.Text = string.format("⚠ COMBUSTIBLE BAJO (%.1f%%): Reserva próxima a agotarse.", fuelPct)
			bottomRowLbl.TextColor3 = Color3.fromRGB(255, 210, 95)
		elseif totalEngCount == 0 and totalBoosterCount > 0 then
			bottomRowLbl.Text = "🚀 SOLO PROPULSIÓN NITRO: Mantén [LeftShift] para Boost · [A/D] Dirección"
			bottomRowLbl.TextColor3 = Color3.fromRGB(115, 220, 255)
		elseif totalEngCount == 0 then
			bottomRowLbl.Text = "ℹ SIN MOTOR: Vehículo en rodamiento libre (instala un motor o propulsor en el taller)."
			bottomRowLbl.TextColor3 = Color3.fromRGB(220, 200, 120)
		elseif totalBoosterCount > 0 then
			bottomRowLbl.Text = "Controles: [W/S] Acel/Freno · [A/D] Dir · [LeftShift] Boost"
			bottomRowLbl.TextColor3 = Color3.fromRGB(145, 225, 175)
		else
			bottomRowLbl.Text = "Controles: [W] Acelerar · [S] Freno/Reversa · [A/D] Dirección"
			bottomRowLbl.TextColor3 = Color3.fromRGB(145, 225, 175)
		end
	end

	local function refreshVisibility()
		local driving = isDrivingNow()
		hudFrame.Visible = driving
		touchFrame.Visible = driving and UserInputService.TouchEnabled
		if not driving then
			resetInputs()
		else
			updateHudTelemetry()
		end
	end

	table.insert(
		_activeConnections,
		UserInputService.InputBegan:Connect(function(input: InputObject, _gameProcessed: boolean)
			if UserInputService:GetFocusedTextBox() ~= nil then
				return
			end
			if not isDrivingNow() then
				return
			end
			local kc = input.KeyCode
			if kc == Enum.KeyCode.W or kc == Enum.KeyCode.Up then
				keyState.Forward = true
			elseif kc == Enum.KeyCode.S or kc == Enum.KeyCode.Down then
				keyState.Backward = true
			elseif kc == Enum.KeyCode.A or kc == Enum.KeyCode.Left then
				keyState.Left = true
			elseif kc == Enum.KeyCode.D or kc == Enum.KeyCode.Right then
				keyState.Right = true
			elseif kc == Enum.KeyCode.LeftShift then
				keyState.Boost = true
			end
		end)
	)

	table.insert(
		_activeConnections,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			local kc = input.KeyCode
			if kc == Enum.KeyCode.W or kc == Enum.KeyCode.Up then
				keyState.Forward = false
			elseif kc == Enum.KeyCode.S or kc == Enum.KeyCode.Down then
				keyState.Backward = false
			elseif kc == Enum.KeyCode.A or kc == Enum.KeyCode.Left then
				keyState.Left = false
			elseif kc == Enum.KeyCode.D or kc == Enum.KeyCode.Right then
				keyState.Right = false
			elseif kc == Enum.KeyCode.LeftShift then
				keyState.Boost = false
			end
		end)
	)

	table.insert(
		_activeConnections,
		UserInputService.WindowFocusReleased:Connect(function()
			resetInputs()
		end)
	)

	table.insert(
		_activeConnections,
		RunService.RenderStepped:Connect(function()
			refreshVisibility()
			if not hudFrame.Visible then
				return
			end

			local noTextBox = UserInputService:GetFocusedTextBox() == nil
			local keyForward = keyState.Forward
				or (noTextBox and (UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up)))
			local keyBackward = keyState.Backward
				or (noTextBox and (UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down)))
			local keyLeft = keyState.Left
				or (noTextBox and (UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left)))
			local keyRight = keyState.Right
				or (noTextBox and (UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right)))
			local keyBoost = keyState.Boost
				or (noTextBox and UserInputService:IsKeyDown(Enum.KeyCode.LeftShift))

			local throttle = if (keyForward or touchState.Throttle) then 1.0 else 0.0
			local brake = if (keyBackward or touchState.Brake) then 1.0 else 0.0
			local steer = 0.0
			if keyLeft or touchState.Left then
				steer -= 1.0
			end
			if keyRight or touchState.Right then
				steer += 1.0
			end
			local boost = keyBoost or touchState.Boost

			local sim = _simulatedInput
			if sim then
				if type(sim.Throttle) == "number" then
					throttle = math.clamp(sim.Throttle, 0, 1)
				end
				if type(sim.Brake) == "number" then
					brake = math.clamp(sim.Brake, 0, 1)
				end
				if type(sim.Steer) == "number" then
					steer = math.clamp(sim.Steer, -1, 1)
				end
				if type(sim.Boost) == "boolean" then
					boost = sim.Boost
				end
			else
				local attrThrottle = hudFrame:GetAttribute("Sim_Throttle")
				local attrBrake = hudFrame:GetAttribute("Sim_Brake")
				local attrSteer = hudFrame:GetAttribute("Sim_Steer")
				local attrBoost = hudFrame:GetAttribute("Sim_Boost")
				if type(attrThrottle) == "number" then
					throttle = math.clamp(attrThrottle, 0, 1)
				end
				if type(attrBrake) == "number" then
					brake = math.clamp(attrBrake, 0, 1)
				end
				if type(attrSteer) == "number" then
					steer = math.clamp(attrSteer, -1, 1)
				end
				if type(attrBoost) == "boolean" then
					boost = attrBoost
				end
			end

			local now = os.clock()
			local changed = throttle ~= lastSentThrottle
				or brake ~= lastSentBrake
				or steer ~= lastSentSteer
				or boost ~= lastSentBoost

			if changed or (now - lastSendClock) >= 0.12 then
				lastSentThrottle = throttle
				lastSentBrake = brake
				lastSentSteer = steer
				lastSentBoost = boost
				lastSendClock = now

				local remote = getDrivingInputRemote()
				if remote then
					remote:FireServer({
						Throttle = throttle,
						Brake = brake,
						RawLongitudinal = throttle - brake,
						Steer = steer,
						Boost = boost,
					})
				end
			end

			updateHudTelemetry()
		end)
	)

	local function destroyHud()
		disconnectAllActiveConnections()
		if hudFrame.Parent then
			hudFrame:Destroy()
		end
		if touchFrame.Parent then
			touchFrame:Destroy()
		end
	end

	table.insert(_activeConnections, screenGui.Destroying:Connect(disconnectAllActiveConnections))
	table.insert(_activeConnections, hudFrame.Destroying:Connect(disconnectAllActiveConnections))
	hudFrame:SetAttribute("ActiveConnectionCount", #_activeConnections)

	local mounted: MountedDrivingHud = {
		HudFrame = hudFrame,
		TouchControlsFrame = touchFrame,
		RefreshVisibility = refreshVisibility,
		Destroy = destroyHud,
	}
	_activeMountedHud = mounted
	return mounted
end

return VehicleDrivingController

