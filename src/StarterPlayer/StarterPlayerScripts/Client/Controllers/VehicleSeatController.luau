--!strict
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Controller = {}
local action = "VehicleSeatBlockJump"
local connections = {}
local humanoid: Humanoid? = nil
local guarded: Humanoid? = nil
local previousJump = true
local changedCallback = nil
local playerConnection: RBXScriptConnection? = nil

function Controller.IsSeated(): boolean
	local seat = if humanoid then humanoid.SeatPart else nil
	return seat ~= nil and seat:GetAttribute("ManagedVehicleSeat") == true
end

local function restore()
	ContextActionService:UnbindAction(action)
	if guarded and guarded.Parent then
		guarded.Jump = false
		guarded:SetStateEnabled(Enum.HumanoidStateType.Jumping, previousJump)
	end
	guarded = nil
end

local function refresh()
	if Controller.IsSeated() and humanoid and humanoid.Health > 0 then
		if guarded ~= humanoid then
			restore()
			guarded = humanoid
			previousJump = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
			ContextActionService:BindActionAtPriority(action, function()
				if humanoid then humanoid.Jump = false end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value + 1, Enum.PlayerActions.CharacterJump, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
		end
		humanoid.Jump = false
	else restore() end
	if changedCallback then changedCallback() end
end

local function bindCharacter(character)
	restore()
	for _, conn in connections do conn:Disconnect() end
	table.clear(connections)
	humanoid = character:WaitForChild("Humanoid")
	table.insert(connections, humanoid:GetPropertyChangedSignal("SeatPart"):Connect(refresh))
	table.insert(connections, humanoid:GetPropertyChangedSignal("Jump"):Connect(function()
		if guarded and humanoid.Jump then humanoid.Jump = false end
	end))
	table.insert(connections, humanoid.Died:Connect(restore))
	table.insert(connections, UserInputService.JumpRequest:Connect(function()
		if guarded then guarded.Jump = false end
	end))
	refresh()
end

function Controller.Start(callback)
	if playerConnection then return end
	changedCallback = callback
	local player = Players.LocalPlayer
	playerConnection = player.CharacterAdded:Connect(bindCharacter)
	if player.Character then bindCharacter(player.Character) end
end

function Controller.Stop()
	restore()
	for _, conn in connections do conn:Disconnect() end
	table.clear(connections)
	if playerConnection then playerConnection:Disconnect(); playerConnection = nil end
	humanoid = nil
	changedCallback = nil
end

return Controller

