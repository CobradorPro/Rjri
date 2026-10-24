-- FlightSystem.client.lua
-- LocalScript para StarterPlayer > StarterPlayerScripts
--
-- Controles:
-- F              Liga/desliga o voo
-- W/A/S/D        Movimento
-- Espaço         Subir
-- Ctrl           Descer
-- Shift          Acelerar
--
-- Mobile (aparece automaticamente em dispositivos touch):
-- Analógico padrão  Movimento
-- VOAR / SAIR       Liga/desliga o voo
-- SOBE / DESCE      Segurar para subir/descer
-- TURBO             Toque para ligar/desligar a aceleração
--
-- Compatível com R6, R15 Motor6D e R15 AnimationConstraint.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Player = Players.LocalPlayer

local Config = {
	ToggleKey = Enum.KeyCode.F,

	CruiseSpeed = 70,
	BoostSpeed = 135,

	Acceleration = 8,
	Deceleration = 11,

	OrientationResponsiveness = 35,
	PoseResponse = 13,

	AnimationIntensity = 1,
}

local character
local humanoid
local rootPart

local flightEnabled = false
local currentVelocity = Vector3.zero

local linearVelocity
local alignOrientation
local flightAttachment
local deathConnection

local oldAutoRotate
local oldPlatformStand

local originalTransforms = {}
local poseState = {}
local joints = {}

local keyState = {
	[Enum.KeyCode.W] = false,
	[Enum.KeyCode.A] = false,
	[Enum.KeyCode.S] = false,
	[Enum.KeyCode.D] = false,

	[Enum.KeyCode.Space] = false,
	[Enum.KeyCode.LeftControl] = false,
	[Enum.KeyCode.RightControl] = false,

	[Enum.KeyCode.LeftShift] = false,
	[Enum.KeyCode.RightShift] = false,
}

local gamepadVector = Vector3.zero

-- Entradas dos botões touch.
local virtualInput = {
	Up = false,
	Down = false,
	Boost = false,
}

local mobileUI = {}

-- Módulo de controles padrão da Roblox (teclado, gamepad e analógico touch).
local controls

task.spawn(function()
	local ok, result = pcall(function()
		local playerScripts = Player:WaitForChild("PlayerScripts")
		local playerModule = require(playerScripts:WaitForChild("PlayerModule"))
		return playerModule:GetControls()
	end)

	if ok then
		controls = result
	end
end)

local function smoothAlpha(speed, deltaTime)
	return 1 - math.exp(-speed * deltaTime)
end

local function normalizeName(name)
	local cleaned = string.gsub(name, "[^%w]", "")
	return string.lower(cleaned)
end

local function collectJoints(characterModel)
	local byName = {}

	for _, object in ipairs(characterModel:GetDescendants()) do
		if object:IsA("Motor6D") or object:IsA("AnimationConstraint") then
			byName[normalizeName(object.Name)] = object
		end
	end

	local function findJoint(...)
		for index = 1, select("#", ...) do
			local requestedName = select(index, ...)
			local found = byName[requestedName]

			if found then
				return found
			end
		end

		return nil
	end

	return {
		root = findJoint("root", "rootjoint"),
		waist = findJoint("waist"),

		neck = findJoint("neck"),

		leftShoulder = findJoint("leftshoulder"),
		rightShoulder = findJoint("rightshoulder"),

		leftElbow = findJoint("leftelbow"),
		rightElbow = findJoint("rightelbow"),

		leftWrist = findJoint("leftwrist"),
		rightWrist = findJoint("rightwrist"),

		leftHip = findJoint("lefthip"),
		rightHip = findJoint("righthip"),

		leftKnee = findJoint("leftknee"),
		rightKnee = findJoint("rightknee"),

		leftAnkle = findJoint("leftankle"),
		rightAnkle = findJoint("rightankle"),
	}
end

local function setJointPose(joint, targetTransform, deltaTime)
	if not joint or not joint.Parent then
		return
	end

	local previousTransform = poseState[joint] or joint.Transform
	local alpha = smoothAlpha(Config.PoseResponse, deltaTime)

	local smoothedTransform = previousTransform:Lerp(
		targetTransform,
		alpha
	)

	poseState[joint] = smoothedTransform
	joint.Transform = smoothedTransform
end

local function resetInput()
	for keyCode in pairs(keyState) do
		keyState[keyCode] = false
	end

	gamepadVector = Vector3.zero

	for key in pairs(virtualInput) do
		virtualInput[key] = false
	end
end

local function getMovementDirection()
	local camera = workspace.CurrentCamera

	if not camera then
		return Vector3.zero
	end

	local horizontal = 0
	local vertical = 0
	local forward = 0

	if controls then
		-- Cobre analógico touch, teclado e gamepad.
		local moveVector = controls:GetMoveVector()

		horizontal = moveVector.X
		forward = -moveVector.Z
	else
		-- Fallback caso o PlayerModule não esteja disponível.
		if keyState[Enum.KeyCode.D] then
			horizontal += 1
		end

		if keyState[Enum.KeyCode.A] then
			horizontal -= 1
		end

		if keyState[Enum.KeyCode.W] then
			forward += 1
		end

		if keyState[Enum.KeyCode.S] then
			forward -= 1
		end

		horizontal += gamepadVector.X
		forward += gamepadVector.Y
	end

	if keyState[Enum.KeyCode.Space] or virtualInput.Up then
		vertical += 1
	end

	if keyState[Enum.KeyCode.LeftControl]
		or keyState[Enum.KeyCode.RightControl]
		or virtualInput.Down then
		vertical -= 1
	end

	local direction =
		camera.CFrame.RightVector * horizontal
		+ camera.CFrame.LookVector * forward
		+ Vector3.yAxis * vertical

	if direction.Magnitude > 1 then
		direction = direction.Unit
	end

	return direction
end

local function updateMovement(deltaTime)
	if not flightEnabled then
		return
	end

	if not rootPart or not rootPart.Parent then
		return
	end

	if not linearVelocity or not alignOrientation then
		return
	end

	local camera = workspace.CurrentCamera
	local movementDirection = getMovementDirection()

	local isBoosting =
		keyState[Enum.KeyCode.LeftShift]
		or keyState[Enum.KeyCode.RightShift]
		or virtualInput.Boost

	local targetSpeed = isBoosting
		and Config.BoostSpeed
		or Config.CruiseSpeed

	local targetVelocity = movementDirection * targetSpeed

	local responseSpeed

	if movementDirection.Magnitude > 0.01 then
		responseSpeed = Config.Acceleration
	else
		responseSpeed = Config.Deceleration
	end

	currentVelocity = currentVelocity:Lerp(
		targetVelocity,
		smoothAlpha(responseSpeed, deltaTime)
	)

	linearVelocity.VectorVelocity = currentVelocity

	if camera then
		local lookDirection = camera.CFrame.LookVector

		if lookDirection.Magnitude > 0.01 then
			alignOrientation.CFrame = CFrame.lookAt(
				rootPart.Position,
				rootPart.Position + lookDirection,
				camera.CFrame.UpVector
			)
		end
	end
end

local function updateFlightAnimation(deltaTime)
	if not flightEnabled then
		return
	end

	if not rootPart or not rootPart.Parent then
		return
	end

	local intensity = Config.AnimationIntensity
	local clock = os.clock()

	local localVelocity =
		rootPart.CFrame:VectorToObjectSpace(currentVelocity)

	local forwardAmount = math.clamp(
		-localVelocity.Z / Config.BoostSpeed,
		-1,
		1
	)

	local sideAmount = math.clamp(
		localVelocity.X / Config.BoostSpeed,
		-1,
		1
	)

	local verticalAmount = math.clamp(
		localVelocity.Y / Config.BoostSpeed,
		-1,
		1
	)

	local speedAmount = math.clamp(
		currentVelocity.Magnitude / Config.BoostSpeed,
		0,
		1
	)

	local breathing =
		math.sin(clock * 2.2)
		* math.rad(1.4)
		* (1 - speedAmount * 0.45)
		* intensity

	local flyingPitch =
		math.rad(-8)
		* forwardAmount
		* intensity

	local flyingRoll =
		math.rad(-13)
		* sideAmount
		* intensity

	local verticalLean =
		math.rad(5)
		* verticalAmount
		* intensity

	-- Junta principal do R6.
	setJointPose(
		joints.root,
		CFrame.Angles(
			flyingPitch + breathing + verticalLean,
			0,
			flyingRoll
		),
		deltaTime
	)

	-- Coluna principal do R15.
	setJointPose(
		joints.waist,
		CFrame.Angles(
			flyingPitch * 0.7 + breathing * 0.5,
			0,
			flyingRoll * 0.65
		),
		deltaTime
	)

	-- Pescoço: pequena compensação para deixar a cabeça natural.
	setJointPose(
		joints.neck,
		CFrame.Angles(
			math.rad(4) * forwardAmount
				- breathing * 0.35,
			0,
			math.rad(-4) * sideAmount
		),
		deltaTime
	)

	-- Braços em posição de voo.
	setJointPose(
		joints.leftShoulder,
		CFrame.Angles(
			math.rad(-52)
				- math.rad(12) * forwardAmount
				+ breathing,
			0,
			math.rad(-14)
				- math.rad(4) * sideAmount
		),
		deltaTime
	)

	setJointPose(
		joints.rightShoulder,
		CFrame.Angles(
			math.rad(-52)
				- math.rad(12) * forwardAmount
				+ breathing,
			0,
			math.rad(14)
				- math.rad(4) * sideAmount
		),
		deltaTime
	)

	-- Cotovelos levemente flexionados.
	setJointPose(
		joints.leftElbow,
		CFrame.Angles(
			math.rad(-18)
				+ math.rad(5) * forwardAmount,
			0,
			0
		),
		deltaTime
	)

	setJointPose(
		joints.rightElbow,
		CFrame.Angles(
			math.rad(-18)
				+ math.rad(5) * forwardAmount,
			0,
			0
		),
		deltaTime
	)

	-- Pequena oscilação nos pulsos.
	local wristMotion =
		math.sin(clock * 2.7)
		* math.rad(2.5)
		* intensity

	setJointPose(
		joints.leftWrist,
		CFrame.Angles(
			wristMotion,
			0,
			math.rad(-4)
		),
		deltaTime
	)

	setJointPose(
		joints.rightWrist,
		CFrame.Angles(
			wristMotion,
			0,
			math.rad(4)
		),
		deltaTime
	)

	-- Pernas estendidas, com leve flexão.
	setJointPose(
		joints.leftHip,
		CFrame.Angles(
			math.rad(17)
				+ math.rad(4) * forwardAmount,
			0,
			math.rad(-7)
		),
		deltaTime
	)

	setJointPose(
		joints.rightHip,
		CFrame.Angles(
			math.rad(17)
				+ math.rad(4) * forwardAmount,
			0,
			math.rad(7)
		),
		deltaTime
	)

	setJointPose(
		joints.leftKnee,
		CFrame.Angles(
			math.rad(10)
				- math.rad(3) * verticalAmount,
			0,
			0
		),
		deltaTime
	)

	setJointPose(
		joints.rightKnee,
		CFrame.Angles(
			math.rad(10)
				- math.rad(3) * verticalAmount,
			0,
			0
		),
		deltaTime
	)

	setJointPose(
		joints.leftAnkle,
		CFrame.Angles(
			math.rad(-5),
			0,
			math.rad(-2)
		),
		deltaTime
	)

	setJointPose(
		joints.rightAnkle,
		CFrame.Angles(
			math.rad(-5),
			0,
			math.rad(2)
		),
		deltaTime
	)
end

local function exitFlight()
	if not flightEnabled then
		return
	end

	flightEnabled = false

	if deathConnection then
		deathConnection:Disconnect()
		deathConnection = nil
	end

	for joint, originalTransform in pairs(originalTransforms) do
		if joint and joint.Parent then
			joint.Transform = originalTransform
		end
	end

	if linearVelocity then
		linearVelocity:Destroy()
		linearVelocity = nil
	end

	if alignOrientation then
		alignOrientation:Destroy()
		alignOrientation = nil
	end

	if flightAttachment then
		flightAttachment:Destroy()
		flightAttachment = nil
	end

	if rootPart and rootPart.Parent then
		rootPart.AssemblyLinearVelocity = Vector3.zero
	end

	if humanoid and humanoid.Parent then
		humanoid.AutoRotate = oldAutoRotate
		humanoid.PlatformStand = oldPlatformStand

		if humanoid.Health > 0 and not oldPlatformStand then
			task.defer(function()
				if humanoid and humanoid.Parent then
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
			end)
		end
	end

	currentVelocity = Vector3.zero
	originalTransforms = {}
	poseState = {}
	joints = {}

	resetInput()

	if mobileUI.refresh then
		mobileUI.refresh()
	end
end

local function enterFlight()
	local currentCharacter = Player.Character

	if not currentCharacter then
		return
	end

	local currentHumanoid =
		currentCharacter:FindFirstChildOfClass("Humanoid")

	local currentRoot =
		currentCharacter:FindFirstChild("HumanoidRootPart")

	if not currentHumanoid or not currentRoot then
		return
	end

	character = currentCharacter
	humanoid = currentHumanoid
	rootPart = currentRoot

	joints = collectJoints(character)

	originalTransforms = {}
	poseState = {}

	for _, joint in pairs(joints) do
		if joint then
			originalTransforms[joint] = joint.Transform
			poseState[joint] = joint.Transform
		end
	end

	oldAutoRotate = humanoid.AutoRotate
	oldPlatformStand = humanoid.PlatformStand

	flightAttachment = Instance.new("Attachment")
	flightAttachment.Name = "FlightSystem_Attachment"
	flightAttachment.Parent = rootPart

	linearVelocity = Instance.new("LinearVelocity")
	linearVelocity.Name = "FlightSystem_LinearVelocity"
	linearVelocity.Attachment0 = flightAttachment
	linearVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	linearVelocity.VelocityConstraintMode =
		Enum.VelocityConstraintMode.Vector
	linearVelocity.MaxForce = math.huge
	linearVelocity.VectorVelocity = Vector3.zero
	linearVelocity.Parent = rootPart

	alignOrientation = Instance.new("AlignOrientation")
	alignOrientation.Name = "FlightSystem_AlignOrientation"
	alignOrientation.Attachment0 = flightAttachment
	alignOrientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOrientation.Responsiveness =
		Config.OrientationResponsiveness
	alignOrientation.MaxTorque = math.huge
	alignOrientation.MaxAngularVelocity = math.huge
	alignOrientation.RigidityEnabled = false
	alignOrientation.CFrame = rootPart.CFrame
	alignOrientation.Parent = rootPart

	currentVelocity = rootPart.AssemblyLinearVelocity

	if currentVelocity.Magnitude > Config.BoostSpeed then
		currentVelocity =
			currentVelocity.Unit * Config.BoostSpeed
	end

	linearVelocity.VectorVelocity = currentVelocity

	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)

	flightEnabled = true

	if mobileUI.refresh then
		mobileUI.refresh()
	end

	deathConnection = humanoid.Died:Connect(function()
		exitFlight()
	end)
end

local function toggleFlight()
	if flightEnabled then
		exitFlight()
	else
		enterFlight()
	end
end

-- Interface mobile ---------------------------------------------------------

local COLOR_IDLE = Color3.fromRGB(25, 28, 40)
local COLOR_ACTIVE = Color3.fromRGB(60, 140, 255)

local function setButtonActive(button, active)
	button.BackgroundColor3 = active and COLOR_ACTIVE or COLOR_IDLE
end

local function createMobileUI()
	if not UserInputService.TouchEnabled then
		return
	end

	local playerGui = Player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "FlightSystem_Mobile"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.Parent = playerGui

	-- Coluna à esquerda do botão de pulo, crescendo para cima.
	local container = Instance.new("Frame")
	container.Name = "Buttons"
	container.BackgroundTransparency = 1
	container.AnchorPoint = Vector2.new(1, 1)
	container.Position = UDim2.new(1, -130, 1, -24)
	container.Size = UDim2.fromOffset(64, 0)
	container.AutomaticSize = Enum.AutomaticSize.Y
	container.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Parent = container

	local function makeButton(name, text, order)
		local button = Instance.new("TextButton")
		button.Name = name
		button.LayoutOrder = order
		button.Size = UDim2.fromOffset(64, 64)
		button.BackgroundColor3 = COLOR_IDLE
		button.BackgroundTransparency = 0.25
		button.AutoButtonColor = false
		button.Text = text
		button.TextColor3 = Color3.new(1, 1, 1)
		button.TextSize = 14
		button.Font = Enum.Font.GothamBold

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = button

		local stroke = Instance.new("UIStroke")
		stroke.Color = Color3.new(1, 1, 1)
		stroke.Transparency = 0.6
		stroke.Thickness = 1.5
		stroke.Parent = button

		button.Parent = container

		return button
	end

	local function isPress(input)
		return input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseButton1
	end

	-- Botões de segurar (SOBE / DESCE).
	local function bindHold(button, key)
		button.InputBegan:Connect(function(input)
			if isPress(input) then
				virtualInput[key] = true
				setButtonActive(button, true)
			end
		end)

		button.InputEnded:Connect(function(input)
			if isPress(input) then
				virtualInput[key] = false
				setButtonActive(button, false)
			end
		end)
	end

	local boostButton = makeButton("Boost", "TURBO", 1)
	local upButton = makeButton("Up", "SOBE", 2)
	local downButton = makeButton("Down", "DESCE", 3)
	local flyButton = makeButton("Fly", "VOAR", 4)

	bindHold(upButton, "Up")
	bindHold(downButton, "Down")

	boostButton.Activated:Connect(function()
		virtualInput.Boost = not virtualInput.Boost
		setButtonActive(boostButton, virtualInput.Boost)
	end)

	flyButton.Activated:Connect(function()
		toggleFlight()
	end)

	mobileUI.refresh = function()
		flyButton.Text = flightEnabled and "SAIR" or "VOAR"
		setButtonActive(flyButton, flightEnabled)

		boostButton.Visible = flightEnabled
		upButton.Visible = flightEnabled
		downButton.Visible = flightEnabled

		setButtonActive(boostButton, virtualInput.Boost)
		setButtonActive(upButton, virtualInput.Up)
		setButtonActive(downButton, virtualInput.Down)
	end

	mobileUI.refresh()
end

createMobileUI()

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then
		return
	end

	if input.KeyCode == Config.ToggleKey then
		toggleFlight()
		return
	end

	if keyState[input.KeyCode] ~= nil then
		keyState[input.KeyCode] = true
	end
end)

UserInputService.InputEnded:Connect(function(input)
	if keyState[input.KeyCode] ~= nil then
		keyState[input.KeyCode] = false
	end
end)

UserInputService.InputChanged:Connect(function(input)
	if input.KeyCode == Enum.KeyCode.Thumbstick1 then
		-- Position.Y do thumbstick: positivo = para frente.
		gamepadVector = Vector3.new(
			input.Position.X,
			input.Position.Y,
			0
		)
	end
end)

Player.CharacterAdded:Connect(function(newCharacter)
	if flightEnabled then
		exitFlight()
	end

	character = newCharacter
end)

RunService.PreSimulation:Connect(function(deltaTime)
	if not flightEnabled then
		return
	end

	if not character
		or not character.Parent
		or not humanoid
		or humanoid.Health <= 0
		or not rootPart
		or not rootPart.Parent then

		exitFlight()
		return
	end

	deltaTime = math.clamp(deltaTime, 0, 0.1)

	updateMovement(deltaTime)
	updateFlightAnimation(deltaTime)
end)
