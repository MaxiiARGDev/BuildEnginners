--!strict
--[=[
	BuildFaceSnapVisualizer
	Renderiza localmente en el cliente la retroalimentación visual del modo `FaceSnap`:
	- Resalta la cara destino sobre la que se produce el acople cara con cara.
	- Muestra la normal de contacto y el punto medio de unión.
	- Colorea en verde/cian si la colocación resultante es válida y en rojo si hay bloqueo/colisión.
	Utiliza un pool fijo de LineHandleAdornment y SphereHandleAdornment sin crear BaseParts.
]=]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local FaceSnapMath = require(ReplicatedStorage.Shared.Building.FaceSnapMath)

local BuildFaceSnapVisualizer = {}

local MAX_LINES = 5 -- 4 bordes del rectángulo destino + 1 normal de contacto
local _containerFolder: Folder? = nil
local _linePool: { LineHandleAdornment } = {}
local _contactSphere: SphereHandleAdornment? = nil
local _lastAdornee: BasePart? = nil

local function getVisualParent(): Instance
	return Workspace.CurrentCamera or Workspace
end

local function ensurePoolInitialized(buildZone: BasePart)
	local host = getVisualParent()
	if _containerFolder and _containerFolder.Parent ~= host then
		_containerFolder:Destroy()
		_containerFolder = nil
		table.clear(_linePool)
		_contactSphere = nil
		_lastAdornee = nil
	end

	if not _containerFolder then
		local folder = Instance.new("Folder")
		folder.Name = "BuildFaceSnapVisualizerPool"
		folder.Parent = host
		_containerFolder = folder

		for i = 1, MAX_LINES do
			local line = Instance.new("LineHandleAdornment")
			line.Name = `FaceSnapLine_{i}`
			line.AlwaysOnTop = false
			line.ZIndex = 4
			line.Thickness = if i == 5 then 3 else 2.2
			line.Visible = false
			line.Length = 1
			line.Parent = folder
			_linePool[i] = line
		end

		local sphere = Instance.new("SphereHandleAdornment")
		sphere.Name = "FaceSnapContactSphere"
		sphere.AlwaysOnTop = false
		sphere.ZIndex = 5
		sphere.Radius = 0.14
		sphere.Visible = false
		sphere.Parent = folder
		_contactSphere = sphere
	end

	if _lastAdornee ~= buildZone then
		_lastAdornee = buildZone
		for _, line in ipairs(_linePool) do
			line.Adornee = buildZone
		end
		if _contactSphere then
			_contactSphere.Adornee = buildZone
		end
	end
end

local function setLineSegment(line: LineHandleAdornment, startPos: Vector3, endPos: Vector3, color: Color3, thickness: number, transparency: number)
	local delta = endPos - startPos
	local len = delta.Magnitude
	if len < 1e-4 then
		line.Visible = false
		return
	end
	local dir = delta / len
	local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	line.CFrame = CFrame.lookAt(startPos, endPos, up)
	line.Length = len
	line.Color3 = color
	line.Thickness = thickness
	line.Transparency = transparency
	line.Visible = true
end

function BuildFaceSnapVisualizer.Hide()
	for _, line in ipairs(_linePool) do
		line.Visible = false
	end
	if _contactSphere then
		_contactSphere.Visible = false
	end
end

function BuildFaceSnapVisualizer.Render(
	buildZone: BasePart?,
	visualTarget: FaceSnapMath.FaceSnapVisualTarget?,
	assemblyOffsetCFrame: CFrame?
)
	if not buildZone or not visualTarget then
		BuildFaceSnapVisualizer.Hide()
		return
	end

	ensurePoolInitialized(buildZone)

	local offsetCF = assemblyOffsetCFrame or CFrame.identity
	local color = if visualTarget.IsValid
		then GameConfig.Building.FaceSnapValidColor
		else GameConfig.Building.FaceSnapInvalidColor

	local n = offsetCF:VectorToWorldSpace(visualTarget.TargetFaceNormal)
	local u = offsetCF:VectorToWorldSpace(visualTarget.TargetTangentU)
	local v = offsetCF:VectorToWorldSpace(visualTarget.TargetTangentV)
	local center = offsetCF:PointToWorldSpace(visualTarget.TargetFaceCenter) + n * 0.025
	local contact = offsetCF:PointToWorldSpace(visualTarget.ContactPoint) + n * 0.025

	local hu = math.max(0.05, visualTarget.TargetHalfU)
	local hv = math.max(0.05, visualTarget.TargetHalfV)

	local c1 = center - u * hu - v * hv
	local c2 = center + u * hu - v * hv
	local c3 = center + u * hu + v * hv
	local c4 = center - u * hu + v * hv

	setLineSegment(_linePool[1], c1, c2, color, 2.2, 0.12)
	setLineSegment(_linePool[2], c2, c3, color, 2.2, 0.12)
	setLineSegment(_linePool[3], c3, c4, color, 2.2, 0.12)
	setLineSegment(_linePool[4], c4, c1, color, 2.2, 0.12)
	setLineSegment(_linePool[5], contact, contact + n * 0.85, color, 3.0, 0.05)

	if _contactSphere then
		_contactSphere.CFrame = CFrame.new(contact)
		_contactSphere.Color3 = color
		_contactSphere.Transparency = 0.1
		_contactSphere.Visible = true
	end
end

function BuildFaceSnapVisualizer.Destroy()
	if _containerFolder then
		_containerFolder:Destroy()
		_containerFolder = nil
	end
	table.clear(_linePool)
	_contactSphere = nil
	_lastAdornee = nil
end

return BuildFaceSnapVisualizer

