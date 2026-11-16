--!strict
--[=[
	BuildInputController
	Gestiona las entradas de teclado, mouse y pantalla táctil del editor (Fases 2.1 y 2.2).
	- Controles PC:
	  - B: activar/desactivar editor
	  - R / T / Y: rotar 90° en ejes locales Y / X / Z
	  - Clic izquierdo: colocar pieza o seleccionar pieza existente en EditableVehicle
	  - Delete / Backspace: eliminar pieza seleccionada
	  - Esc: cancelar selección o salir del editor
	- Sin conexiones duplicadas.
]=]

local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

export type InputCallbacks = {
	OnToggleEditor: () -> (),
	OnRotateY: () -> (),
	OnRotateX: () -> (),
	OnRotateZ: () -> (),
	OnPrimaryClick: () -> (),
	OnDeleteSelected: () -> (),
	OnCancelOrExit: () -> (),
	OnPrimaryRelease: (() -> ())?,
	OnConfirmTransform: (() -> ())?,
	OnTogglePositionMode: (() -> ())?,
	OnSelectMoveTool: (() -> ())?,
	OnSelectRotateTool: (() -> ())?,
	OnToggleSmartSnap: (() -> ())?,
	OnToggleFaceSnap: (() -> ())?,
	OnToggleGuides: (() -> ())?,
}

local BuildInputController = {}

local _inputConnection: RBXScriptConnection? = nil
local _inputEndedConnection: RBXScriptConnection? = nil
local _lastTouchScreenPos: Vector2? = nil
local _touchConnection: RBXScriptConnection? = nil

function BuildInputController.Bind(callbacks: InputCallbacks)
	BuildInputController.Unbind()

	_inputConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessedEvent: boolean)
		if gameProcessedEvent then
			return
		end

		if input.UserInputType == Enum.UserInputType.Keyboard then
			if input.KeyCode == Enum.KeyCode.B then
				callbacks.OnToggleEditor()
			elseif input.KeyCode == Enum.KeyCode.R then
				callbacks.OnRotateY()
			elseif input.KeyCode == Enum.KeyCode.T then
				callbacks.OnRotateX()
			elseif input.KeyCode == Enum.KeyCode.Y then
				callbacks.OnRotateZ()
			elseif input.KeyCode == Enum.KeyCode.Delete or input.KeyCode == Enum.KeyCode.Backspace then
				callbacks.OnDeleteSelected()
			elseif input.KeyCode == Enum.KeyCode.Escape then
				callbacks.OnCancelOrExit()
			elseif (input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter) and callbacks.OnConfirmTransform then
				callbacks.OnConfirmTransform()
			elseif input.KeyCode == Enum.KeyCode.F and callbacks.OnTogglePositionMode then
				callbacks.OnTogglePositionMode()
			elseif input.KeyCode == Enum.KeyCode.G and callbacks.OnSelectMoveTool then
				callbacks.OnSelectMoveTool()
			elseif input.KeyCode == Enum.KeyCode.V and callbacks.OnSelectRotateTool then
				callbacks.OnSelectRotateTool()
			elseif input.KeyCode == Enum.KeyCode.J and callbacks.OnToggleSmartSnap then
				callbacks.OnToggleSmartSnap()
			elseif input.KeyCode == Enum.KeyCode.K and callbacks.OnToggleFaceSnap then
				callbacks.OnToggleFaceSnap()
			elseif input.KeyCode == Enum.KeyCode.H and callbacks.OnToggleGuides then
				callbacks.OnToggleGuides()
			end
		elseif input.UserInputType == Enum.UserInputType.MouseButton1 then
			callbacks.OnPrimaryClick()
		elseif input.UserInputType == Enum.UserInputType.Touch then
			_lastTouchScreenPos = Vector2.new(input.Position.X, input.Position.Y)
			callbacks.OnPrimaryClick()
		end
	end)

	_inputEndedConnection = UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			if callbacks.OnPrimaryRelease then
				callbacks.OnPrimaryRelease()
			end
		end
	end)

	_touchConnection = UserInputService.TouchMoved:Connect(function(touch: InputObject, gameProcessedEvent: boolean)
		if not gameProcessedEvent then
			_lastTouchScreenPos = Vector2.new(touch.Position.X, touch.Position.Y)
		end
	end)
end

function BuildInputController.Unbind()
	if _inputConnection then
		_inputConnection:Disconnect()
		_inputConnection = nil
	end
	if _inputEndedConnection then
		_inputEndedConnection:Disconnect()
		_inputEndedConnection = nil
	end
	if _touchConnection then
		_touchConnection:Disconnect()
		_touchConnection = nil
	end
	_lastTouchScreenPos = nil
end

function BuildInputController.IsBound(): boolean
	return _inputConnection ~= nil
end

function BuildInputController.GetPointerRay(): (Vector3?, Vector3?)
	local camera = Workspace.CurrentCamera
	if not camera then
		return nil, nil
	end

	local screenPos = _lastTouchScreenPos or UserInputService:GetMouseLocation()
	local unitRay = camera:ViewportPointToRay(screenPos.X, screenPos.Y)
	return unitRay.Origin, unitRay.Direction
end

return BuildInputController
