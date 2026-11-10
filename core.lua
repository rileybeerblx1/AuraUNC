--!strict

type Function = (...any) -> ...any?

local EncodingService = game:GetService("EncodingService")
local UserInputService = game:GetService("UserInputService")
local Player = game:GetService("Players").LocalPlayer
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local LogService = game:GetService("LogService")

local function GetPlayerScripts(): Instance
	return Player:FindFirstChild("PlayerScripts") or game:GetService("StarterPlayer").StarterPlayerScripts
end

local function GetPlayerModule(): any
	local PlayerModule = GetPlayerScripts():FindFirstChild("PlayerModule") or game:GetService("StarterPlayer"):FindFirstChild("PlayerModule", true)
	if not PlayerModule then
		error({Skipped = "this game has no PlayerModule", Environment = true})
	end
	return PlayerModule
end

local function FindFirstFunction(Name: string, Environment: {[string]: any}?): any
	local Value = Environment or getfenv()
	while Value ~= nil and Name ~= "" do
		local Library, NewName = string.match(Name, "^([^.]+)%.?(.*)$")
		local Success, Found = pcall(function()
			return Value[Library or ""]
		end)
		Value = if Success then Found else nil
		Name = NewName or ""
	end
	return Value
end

local TestThreads: {[thread]: string} = {}
local Cleanups: {[thread]: {() -> ()}} = {}

local function AddCleanup(Cleanup: () -> ())
	local Thread = coroutine.running()
	Cleanups[Thread] = Cleanups[Thread] or {}
	table.insert(Cleanups[Thread], Cleanup)
end

local function RunCleanups(Thread: thread)
	for _, Cleanup in Cleanups[Thread] or {} do
		pcall(Cleanup)
	end
	Cleanups[Thread] = nil
end

local Dependencies: {[string]: {[string]: boolean}} = {}

local Formatters = {
	CheckReturnType = function(Result: any, Type: string)
		assert(typeof(Result) == Type, `didn't return a {Type}`)
	end,

	CheckEqual = function(Result: any, Expected: any, Name: string)
		assert(Result == Expected, `expected {Name} to be {Expected}, got {Result}`)
	end,

	CheckExist = function(FunctionName: string): any
		local TestName = TestThreads[coroutine.running()]
		local FoundFunction = FindFirstFunction(FunctionName)
		if TestName then
			Dependencies[TestName] = Dependencies[TestName] or {}
			Dependencies[TestName][FunctionName] = true
		end
		assert(FoundFunction, `'{FunctionName}' does not exist, and is required for this test`)
		return FoundFunction
	end,
}

local function RemovePath(FunctionName: string, Path: string)
	local Remove = getfenv()[FunctionName]
	if not Remove then
		return
	end
	pcall(Remove, Path)
end

local function WaitFor(Check: () -> boolean, Timeout: number): boolean
	local StartTime = tick()
	repeat
		task.wait()
	until Check() or tick() - StartTime >= Timeout
	return Check()
end

local function CreateRandomString(Length: number): string
	local Characters = table.create(Length)
	for Index = 1, Length do
		Characters[Index] = string.char(math.random(0, 255))
	end
	return table.concat(Characters)
end

local AllBytes = (function()
	local Characters = table.create(256)
	for Byte = 0, 255 do
		Characters[Byte + 1] = string.char(Byte)
	end
	return table.concat(Characters)
end)()

local FocusLost = false
local HasFocus = true
local MissedFocusLoss = false
local MessageBoxTime = 0

local FocusConnection = UserInputService.WindowFocusReleased:Connect(function()
	FocusLost = true
	HasFocus = false
	local IsRobloxActive = isrbxactive
	if not IsRobloxActive then
		return
	end
	if not WaitFor(function()
		return HasFocus or not IsRobloxActive()
	end, 1) then
		MissedFocusLoss = true
	end
end)

local FocusGainedConnection = UserInputService.WindowFocused:Connect(function()
	HasFocus = true
end)

local InputTests: {[string]: boolean} = {}

local function IsRobloxFocused(): boolean
	local IsRobloxActive = isrbxactive
	if IsRobloxActive then
		local Success, Active = pcall(IsRobloxActive)
		if Success then
			return Active == true
		end
	end
	return HasFocus
end

local function MoveFocusToConsole()
	if not IsRobloxFocused() then
		return
	end
	local CreateConsole = rconsolecreate
	if not CreateConsole then
		return
	end
	pcall(CreateConsole)
	pcall(rconsoleshow or function() end)
	WaitFor(function()
		return not IsRobloxFocused()
	end, 2)
end

local function CheckInputFree()
	local TestName = TestThreads[coroutine.running()]
	if TestName then
		InputTests[TestName] = true
	end
	local IdentifyExecutor = identifyexecutor
	local ExecutorName = IdentifyExecutor and tostring((IdentifyExecutor()))
	if ExecutorName and table.find({"athena", "bunni"}, ExecutorName:lower()) and not IsRobloxFocused() then
		error(`input only works while Roblox is focused, {ExecutorName} sends it to whatever window is focused instead`)
	end
	if not WaitFor(function()
		return UserInputService.MouseBehavior == Enum.MouseBehavior.Default
			and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
			and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
			and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton3)
	end, 1) then
		error({Skipped = "a mouse button is being held or the mouse is locked", Environment = true})
	end
	local LastInput = os.clock()
	local function OnInput()
		LastInput = os.clock()
	end
	local Connections = {
		UserInputService.InputBegan:Connect(OnInput),
		UserInputService.InputChanged:Connect(OnInput),
		UserInputService.InputEnded:Connect(OnInput),
	}
	local Quiet = WaitFor(function()
		return os.clock() - LastInput >= 0.25
	end, 3)
	for _, Connection in Connections do
		Connection:Disconnect()
	end
	if not Quiet then
		error({Skipped = "the mouse or keyboard was being used during the test", Environment = true})
	end
end

local function WaitForInput(Signal: RBXScriptSignal, Check: (InputObject) -> boolean, Action: () -> ()): boolean
	local Detected = false
	local Connection = Signal:Connect(function(Input)
		if typeof(Input) ~= "Instance" or not Input:IsA("InputObject") or not Check(Input) then
			return
		end
		Detected = true
	end)
	AddCleanup(function()
		Connection:Disconnect()
	end)
	Action()
	local Result = WaitFor(function()
		return Detected
	end, 1)
	Connection:Disconnect()
	return Result
end

local function CenterMouse()
	local MouseMoveAbsolute = mousemoveabs
	if not MouseMoveAbsolute then
		return
	end
	local Center = workspace.CurrentCamera.ViewportSize / 2
	MouseMoveAbsolute(Center.X, Center.Y)
	task.wait()
end

local function CheckPressAndRelease(PressName: string, ReleaseName: string, TestedName: string, IsHeld: () -> boolean, IsInput: (InputObject) -> boolean, Argument: any?)
	local Release = if TestedName == PressName or TestedName == ReleaseName then Formatters.CheckExist(ReleaseName) else getfenv()[ReleaseName]
	local Detected
	if Release then
		AddCleanup(function()
			if IsHeld() then
				Release(Argument)
			end
		end)
	end
	if TestedName == ReleaseName then
		Formatters.CheckExist(PressName)(Argument)
		if not WaitFor(IsHeld, 1) then
			Release(Argument)
			error("the input was never held down, so it can't be released")
		end
		Detected = WaitForInput(UserInputService.InputEnded, IsInput, function()
			Release(Argument)
		end)
	else
		Detected = WaitForInput(UserInputService.InputBegan, IsInput, function()
			getfenv()[TestedName](Argument)
		end)
		if TestedName == PressName then
			Release(Argument)
		end
	end
	local Released = WaitFor(function()
		return not IsHeld()
	end, 1)
	if not Released and Release then
		Release(Argument)
	end
	assert(Detected, "the input wasn't detected")
	assert(Released, "the input was left held down")
end

local function CheckMouseButton(Button: number, TestedName: string)
	local InputType = if Button == 1 then Enum.UserInputType.MouseButton1 else Enum.UserInputType.MouseButton2
	local TouchHeld = false
	if Button == 1 then
		local Connections = {
			UserInputService.InputBegan:Connect(function(Input)
				TouchHeld = TouchHeld or Input.UserInputType == Enum.UserInputType.Touch
			end),
			UserInputService.InputEnded:Connect(function(Input)
				TouchHeld = TouchHeld and Input.UserInputType ~= Enum.UserInputType.Touch
			end),
		}
		AddCleanup(function()
			for _, Connection in Connections do
				Connection:Disconnect()
			end
		end)
	end
	CheckInputFree()
	CenterMouse()
	CheckPressAndRelease(`mouse{Button}press`, `mouse{Button}release`, TestedName, function()
		return UserInputService:IsMouseButtonPressed(InputType) or TouchHeld
	end, function(Input)
		return Input.UserInputType == InputType or (Button == 1 and Input.UserInputType == Enum.UserInputType.Touch)
	end)
end

local function CheckKey(TestedName: string)
	CheckInputFree()
	CheckPressAndRelease("keypress", "keyrelease", TestedName, function()
		return UserInputService:IsKeyDown(Enum.KeyCode.J)
	end, function(Input)
		return Input.KeyCode == Enum.KeyCode.J
	end, 0x4A)
end

local function CheckPacketHook(Direction: string, CheckRemove: boolean)
	local RakNet = raknet
	local Count = 0
	local PacketId
	local MatchedData
	local function OnPacket(Packet)
		Count += 1
		PacketId = PacketId or Packet.PacketId
		if MatchedData ~= nil then
			return
		end
		MatchedData = Packet.Size == #Packet.AsString and buffer.tostring(Packet.AsBuffer) == Packet.AsString
	end
	RakNet[`add{Direction}hook`](OnPacket)
	local Fired = WaitFor(function()
		return Count > 0
	end, 3)
	RakNet[`remove{Direction}hook`](OnPacket)
	local CountAtRemoval = Count
	if CheckRemove and not Fired then
		error({Skipped = `the {Direction} hook never fired, so removing it can't be checked`})
	end
	assert(Fired, `the {Direction} hook wasn't called within 3 seconds`)
	assert(typeof(PacketId) == "number", `expected the packet to have a number PacketId, got {typeof(PacketId)}`)
	assert(MatchedData, "the packet's Size, AsString and AsBuffer don't match each other")
	if not CheckRemove then
		return
	end
	local ControlCount = 0
	local function OnControlPacket()
		ControlCount += 1
	end
	RakNet[`add{Direction}hook`](OnControlPacket)
	AddCleanup(function()
		RakNet[`remove{Direction}hook`](OnControlPacket)
	end)
	WaitFor(function()
		return ControlCount >= 3
	end, 3)
	assert(Count == CountAtRemoval, `the {Direction} hook was still called after it was removed`)
end

local function RunOnNewActor(Code: string): {[string]: any}
	local RunOnActor = Formatters.CheckExist("runonactor")
	local Actor = Instance.new("Actor")
	Actor.Parent = workspace
	AddCleanup(function()
		Actor:Destroy()
	end)
	RunOnActor(Actor, `local Actor = ... {Code} Actor:SetAttribute("Done", true)`, Actor)
	WaitFor(function()
		return Actor:GetAttribute("Done") == true
	end, 2)
	local Attributes = Actor:GetAttributes()
	Actor:Destroy()
	return Attributes
end

local function CheckOffThreadHook()
	local OffThreadHooks = oth
	local Target = math.ldexp
	local InHookThread
	local RootCallback
	local OriginalThread
	local HookThread
	local Original
	local OriginalResult
	AddCleanup(function()
		OffThreadHooks.unhook(Target)
	end)
	Original = OffThreadHooks.hook(Target, function(...)
		OriginalResult = Original(...)
		HookThread = coroutine.running()
		InHookThread = OffThreadHooks.is_hook_thread()
		RootCallback = OffThreadHooks.get_root_callback()
		OriginalThread = OffThreadHooks.get_original_thread()
		return "AURAUNC Hooked"
	end)
	local HookedResult = Target(1, 2)
	OffThreadHooks.unhook(Target)
	Formatters.CheckReturnType(Original, "function")
	Formatters.CheckEqual(HookedResult, "AURAUNC Hooked", "the hooked function's result")
	Formatters.CheckEqual(OriginalResult, 4, "the original function's result")
	Formatters.CheckEqual(Target(1, 2), 4, "the result after unhooking")
	assert(InHookThread == true, "is_hook_thread returned false inside the hook")
	assert(OffThreadHooks.is_hook_thread() == false, "is_hook_thread returned true outside of a hook")
	assert(typeof(RootCallback) == "function", `get_root_callback should return a function inside the hook, got {typeof(RootCallback)}`)
	assert(OriginalThread == coroutine.running(), "get_original_thread didn't return the thread that called the function")
	assert(HookThread ~= coroutine.running(), "the hook ran on the same thread as the caller")
	assert(typeof(OriginalThread) == "thread", `get_original_thread should return a thread inside the hook, got {typeof(OriginalThread)}`)
	local NewCClosure = newcclosure
	if not NewCClosure then
		return
	end
	local WrappedTarget = NewCClosure(function()
		return "AURAUNC Original"
	end)
	AddCleanup(function()
		OffThreadHooks.unhook(WrappedTarget)
	end)
	OffThreadHooks.hook(WrappedTarget, function()
		return "AURAUNC Hooked"
	end)
	local WrappedResult = WrappedTarget()
	OffThreadHooks.unhook(WrappedTarget)
	Formatters.CheckEqual(WrappedResult, "AURAUNC Hooked", "the hooked newcclosure function's result")
	Formatters.CheckEqual(WrappedTarget(), "AURAUNC Original", "the newcclosure function's result after unhooking")
end

local function CheckCommChannel()
	local CreateCommChannel = Formatters.CheckExist("createcommchannel")
	local GetCommChannel = Formatters.CheckExist("getcommchannel")
	local Marker = `AURAUNC {math.random()}`
	local ChannelId, Channel = CreateCommChannel()
	local Received
	assert(typeof(ChannelId) == "number", `expected a number id, got {typeof(ChannelId)}`)
	assert(GetCommChannel(ChannelId) == Channel, "getcommchannel didn't return the channel that was made")
	Formatters.CheckEqual(GetCommChannel(math.random()), nil, "a channel that was never made")
	Channel.Event:Once(function(...)
		Received = table.pack(...)
	end)
	RunOnNewActor(`getcommchannel({ChannelId}):Fire("{Marker}", game, nil)`)
	WaitFor(function()
		return Received ~= nil
	end, 1)
	assert(Received, "the channel didn't get the message fired from the actor")
	Formatters.CheckEqual(Received[1], Marker, "the message from the actor")
	assert(Received[2] == game, "game sent from the actor didn't arrive as the same game")
	Formatters.CheckEqual(Received.n, 3, "the number of values sent, counting the nil")
end

local function CheckConsole()
	local IsHidden = rconsolehidden
	local Show = rconsoleshow
	if not IsHidden or not Show then
		return
	end
	Formatters.CheckExist("rconsolecreate")()
	AddCleanup(function()
		rconsoledestroy()
	end)
	Show()
	assert(IsHidden() ~= true, "rconsolehidden returned true after rconsoleshow, so the console didn't open")
end

local function CallAsync(Function: (...any) -> ...any, ...: any): ...any
	local Results
	local Thread = task.spawn(function(...)
		Results = table.pack(pcall(Function, ...))
	end, ...)
	assert(coroutine.status(Thread) ~= "dead", "it finished before returning, so it blocks like the normal version instead of running in the background")
	assert(WaitFor(function()
		return Results ~= nil
	end, 5), "it never finished")
	if not Results[1] then
		error(Results[2], 0)
	end
	return table.unpack(Results, 2, Results.n)
end

local function CheckClipboard()
	local GetClipboard = getclipboard
	if not GetClipboard then
		return
	end
	local Text = `AURAUNC{math.random(1, 1e6)}`
	Formatters.CheckExist("setclipboard")(Text)
	assert(WaitFor(function()
		return GetClipboard() == Text
	end, 1), "the clipboard didn't have the text that was copied")
end

local function CheckScriptThread()
	local GetScriptThread = Formatters.CheckExist("getscriptthread")
	local LocalScript
	local Thread
	for _, Descendant in GetPlayerScripts():GetDescendants() do
		if not Descendant:IsA("LocalScript") then
			continue
		end
		LocalScript = Descendant
		Thread = GetScriptThread(Descendant)
		if Thread then
			break
		end
	end
	if Thread == nil then
		error({Skipped = "no LocalScript has a running thread right now"})
	end
	assert(typeof(Thread) == "thread", `getscriptthread should return a thread, got {typeof(Thread)}`)
	assert(Formatters.CheckExist("getscriptfromthread")(coroutine.running()) == nil, "getscriptfromthread should return nil for the thread running this test")
	assert(Formatters.CheckExist("getscriptfromthread")(Thread) == LocalScript, "getscriptfromthread didn't give back the script the thread belongs to")
end

local function CheckProtoHook()
	local HookProto = Formatters.CheckExist("hookproto")
	local IsProtoHooked = Formatters.CheckExist("isprotohooked")
	local function Outer()
		local function Inner()
			return "AURAUNC Original"
		end
		return Inner
	end
	local Proto = Formatters.CheckExist("debug.getproto")(Outer, 1)
	assert(IsProtoHooked(Proto) == false, "isprotohooked returned true before the proto was hooked")
	AddCleanup(function()
		if not IsProtoHooked(Proto) then
			return
		end
		restoreproto(Proto)
	end)
	HookProto(Proto, function()
		return "AURAUNC Hooked"
	end)
	local HookedBefore = IsProtoHooked(Proto)
	local HookedResult = Outer()()
	Formatters.CheckExist("restoreproto")(Proto)
	assert(HookedBefore == true, "isprotohooked returned false after the proto was hooked")
	Formatters.CheckEqual(HookedResult, "AURAUNC Hooked", "a new closure's result after hooking its proto")
	assert(IsProtoHooked(Proto) == false, "isprotohooked still returned true after restoreproto")
	Formatters.CheckEqual(Outer()(), "AURAUNC Original", "a new closure's result after restoreproto")
end

local function GetRootPart(): BasePart?
	local RootPart
	WaitFor(function()
		RootPart = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
		return RootPart ~= nil
	end, 10)
	assert(RootPart, "your character didn't load within 10 seconds")
	return RootPart
end

local TestImage = buffer.tostring(EncodingService:Base64Decode(buffer.fromstring(
	"iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)))

local function GetAssetStatus(AssetId: string): Enum.AssetFetchStatus?
	local ImageLabel = Instance.new("ImageLabel")
	ImageLabel.Image = AssetId
	local FetchStatus
	pcall(function()
		game:GetService("ContentProvider"):PreloadAsync({ImageLabel}, function(_, Status)
			FetchStatus = Status
		end)
	end)
	ImageLabel:Destroy()
	return FetchStatus
end

local function CheckWrongKey(Crypt: any, Encrypted: string, InitializationVector: string, Text: string)
	local Success, Result = pcall(Crypt.decrypt, Encrypted, Crypt.generatekey(), InitializationVector)
	assert(not Success or Result ~= Text, "decrypting with the wrong key still gave back the original text")
end

local function FindFingerprintHeader(Headers: {[string]: any}): string?
	for Header in Headers do
		if Header:lower():find("fingerprint") then
			return Header
		end
	end
	return nil
end

local function FindConstant(TestedFunction: Function, Value: any): number?
	for Index, Constant in Formatters.CheckExist("debug.getconstants")(TestedFunction) do
		if Constant == Value then
			return Index
		end
	end
	return nil
end

local Tests: any = {
	getrenv = {
		Test = function()
			local Environment = getrenv()
			for _, Global: string in {
				"delay", "elapsedTime", "printidentity", "settings", "spawn", "stats", "tick", "time",
				"typeof", "UserSettings", "version", "wait", "warn", "ypcall", "Enum", "game", "shared", "_G", "workspace",
			} do
				assert(Environment[Global] ~= nil, `missing '{Global}'`)
			end
			local Value = math.random()
			Environment.AURAUNC = Value
			local Stored = getrenv().AURAUNC
			Environment.AURAUNC = nil
			assert(Environment.game == game, "its 'game' isn't the real game")
			assert(Environment.print == print, "its 'print' isn't the real print")
			assert(Environment._G ~= _G, "its _G is the same as the executor's _G")
			assert(Environment ~= getgenv(), "it's the same table as getgenv(), not Roblox's environment")
			assert(Environment.getgenv == nil and Environment.hookfunction == nil, "it has executor functions in it, so game scripts can find them")
			Formatters.CheckEqual(Stored, Value, "a value written to it")
			local Animate = Player.Character and Player.Character:FindFirstChild("Animate")
			local ScriptEnvironment = Animate and Formatters.CheckExist("getsenv")(Animate)
			assert(ScriptEnvironment, "couldn't get the Animate script's environment to compare with")
			assert(ScriptEnvironment._G == Environment._G, "its _G isn't the same _G game scripts use")
			assert(ScriptEnvironment.shared == Environment.shared, "its shared isn't the same shared game scripts use")
			assert(Environment.printidentity == printidentity and ScriptEnvironment.printidentity == printidentity, "printidentity isn't the same function everywhere, so it's been replaced in one environment")
			assert(Formatters.CheckExist("debug.info")(printidentity, "s") == "[C]" and debug.info(printidentity, "n") == "printidentity", "printidentity isn't Roblox's real C function anymore")
			assert(not pcall(setfenv, printidentity, getfenv()), "setfenv worked on printidentity, so it's a LuaClosure pretending to be Roblox's")
			for _, Name in {"getgenv", "hookfunction", "identifyexecutor", "getrenv", "newcclosure"} do
				for Place, Table in {["a game script's environment"] = ScriptEnvironment, ["the game's _G"] = Environment._G, ["the game's shared"] = Environment.shared} do
					assert(rawget(Table, Name) == nil and Table[Name] == nil, `{Name} can be reached from {Place}, so game scripts can detect the executor`)
				end
			end
		end,
		ReturnType = "table",
	},

	getgenv = {
		Test = function()
			local Environment = getgenv()
			local Key = `AURAUNC{math.random(1, 1e6)}`
			local Value = math.random()
			Environment[Key] = Value
			local Seen = loadstring(`return {Key}`)()
			Environment[Key] = nil
			Formatters.CheckEqual(Seen, Value, "a global set in the environment and read by another chunk")
			for FunctionName in getfenv() do
				assert(Environment[FunctionName], `missing '{FunctionName}'`)
			end
		end,
		ReturnType = "table",
	},

	gettenv = {
		Test = function()
			local GetThreadEnvironment: (thread?) -> {[string]: any} = gettenv
			assert(GetThreadEnvironment() == getfenv(), "with no thread given, it should return the current environment like getfenv")
			local Thread = task.spawn(function()
				task.wait(1)
			end)
			AddCleanup(function()
				task.cancel(Thread)
			end)
			local ThreadEnvironment = GetThreadEnvironment(Thread)
			Formatters.CheckReturnType(ThreadEnvironment, "table")
			assert(ThreadEnvironment == getfenv(), "a thread started by this script should have the same environment as it")
			for FunctionName in ThreadEnvironment do
				assert(getfenv()[FunctionName], `the thread environment has '{FunctionName}' but getfenv() doesn't`)
			end
			local Finished = task.spawn(function() end)
			local Success, FinishedEnvironment = pcall(GetThreadEnvironment, Finished)
			assert(Success and FinishedEnvironment == getfenv(), "didn't keep the environment of a thread that already finished")
		end,
	},

	readfile = {
		Test = function()
			local ReadFile: (Path: string) -> string = readfile
			assert(not pcall(ReadFile, "doesntexist.txt"), "expected an error when reading a file that doesn't exist")
			local GeneratedResult = `{math.random()}\0AURAUNC`
			local FileName = `File_{math.random()}.txt`
			Formatters.CheckExist("writefile")(FileName, GeneratedResult)
			local Result = ReadFile(FileName)
			Formatters.CheckExist("writefile")(FileName, "")
			local EmptyResult = ReadFile(FileName)
			RemovePath("delfile", FileName)
			assert(Result == GeneratedResult, "the test file didn't return what was written into it")
			Formatters.CheckEqual(EmptyResult, "", "an empty file's contents")
		end,
	},

	writefile = {
		Test = function()
			local GeneratedResult = `{math.random()}\0AURAUNC`
			local FileName = `File_{math.random()}.txt`
			writefile(FileName, GeneratedResult)
			local Result = Formatters.CheckExist("readfile")(FileName)
			writefile(FileName, "AURAUNC")
			local ShorterResult = Formatters.CheckExist("readfile")(FileName)
			RemovePath("delfile", FileName)
			local Large = string.rep(CreateRandomString(1024), 1024)
			writefile(FileName, Large)
			local LargeIntact = Formatters.CheckExist("readfile")(FileName) == Large
			RemovePath("delfile", FileName)
			assert(typeof(Result) == "string", "'readfile' failed to read the file, can't continue the test")
			assert(Result == GeneratedResult, "'writefile' didn't write to the file")
			assert(LargeIntact, "a 1 MB file didn't read back the same as what was written")
			Formatters.CheckEqual(ShorterResult, "AURAUNC", "the file after writing shorter text over it")
		end,
	},

	isfile = {
		Test = function()
			local FileName = `File_{math.random()}.txt`
			Formatters.CheckExist("writefile")(FileName, "Test")
			local IsFile = isfile
			local Exists = IsFile(FileName)
			RemovePath("delfile", FileName)
			assert(Exists, "failed to find the file")
			assert(IsFile(`Missing_{math.random()}.txt`) == false, "found a file that doesn't exist")
			local FolderName = `Folder_{math.random()}`
			Formatters.CheckExist("makefolder")(FolderName)
			local FolderIsFile = IsFile(FolderName)
			RemovePath("delfolder", FolderName)
			assert(FolderIsFile == false, "said a folder is a file")
		end,
	},

	appendfile = {
		Test = function()
			local AppendFile: (Path: string, Data: string) -> () = appendfile
			local ReadFile: (Path: string) -> string = Formatters.CheckExist("readfile")
			local GeneratedResult = tostring(math.random())
			local FileName = `File_{math.random()}.txt`
			if not pcall(AppendFile, FileName, GeneratedResult) then
				Formatters.CheckExist("writefile")(FileName, GeneratedResult)
			end
			local Created = ReadFile(FileName) == GeneratedResult
			AppendFile(FileName, "Append")
			local Result = ReadFile(FileName)
			RemovePath("delfile", FileName)
			assert(Created, "failed to create the file")
			Formatters.CheckEqual(Result, `{GeneratedResult}Append`, "the file's text after adding to it")
		end,
	},

	listfiles = {
		Test = function()
			local ListFiles: (Path: string) -> {string} = listfiles
			local FolderName = `Folder_{math.random()}`
			local FileName = `{FolderName}/File_{math.random()}.txt`
			Formatters.CheckExist("makefolder")(FolderName)
			local ReturnedTable = typeof(ListFiles(FolderName)) == "table"
			Formatters.CheckExist("writefile")(FileName, tostring(math.random()))
			local InnerFolder = `{FolderName}/Inner`
			Formatters.CheckExist("makefolder")(InnerFolder)
			Formatters.CheckExist("writefile")(`{InnerFolder}/Deeper.txt`, "AURAUNC")
			local Result = ListFiles(FolderName)
			RemovePath("delfolder", FolderName)
			local Found = {}
			for _, Path in Result do
				Found[(Path:gsub("\\", "/"):gsub("/$", ""):gsub("^%./", ""))] = true
			end
			assert(ReturnedTable, "didn't return a table")
			assert(Found[FileName], "didn't find the written file")
			assert(Found[InnerFolder], "didn't find the folder inside it")
			Formatters.CheckEqual(#Result, 2, "the number of things listed, since only the folder's direct children should be there,")
		end,
	},

	delfile = {
		Test = function()
			local IsFile: (Path: string) -> boolean = Formatters.CheckExist("isfile")
			local FileName = `File_{math.random()}.txt`
			Formatters.CheckExist("writefile")(FileName, "Test")
			assert(IsFile(FileName), "failed to write to the file, can't continue the test")
			delfile(FileName)
			assert(not IsFile(FileName), "'isfile' returned true after the file was meant to be deleted")
		end,
	},

	loadfile = {
		Test = function()
			local FileName = `File_{math.random()}.txt`
			local GeneratedNumber = math.random()
			Formatters.CheckExist("writefile")(FileName, "local Number = ...; return Number + 1")
			local LoadedFunction, ErrorMessage = loadfile(FileName)
			RemovePath("delfile", FileName)
			assert(assert(LoadedFunction, ErrorMessage)(GeneratedNumber) == GeneratedNumber + 1, "didn't return the correct number")
		end,
	},

	makefolder = {
		Test = function()
			local FolderName = `Folder_{math.random()}`
			makefolder(FolderName)
			local Exists = Formatters.CheckExist("isfolder")(FolderName) == true
			RemovePath("delfolder", FolderName)
			assert(Exists, "failed to find the folder after it was made")
			local FileName = `File_{math.random()}.txt`
			Formatters.CheckExist("writefile")(FileName, "AURAUNC")
			AddCleanup(function()
				RemovePath("delfile", FileName)
				RemovePath("delfolder", FileName)
			end)
			pcall(makefolder, FileName)
			local Success, Contents = pcall(Formatters.CheckExist("readfile"), FileName)
			RemovePath("delfile", FileName)
			RemovePath("delfolder", FileName)
			assert(Success, "the file was gone after makefolder was called on its path")
			Formatters.CheckEqual(Contents, "AURAUNC", "a file after makefolder was called on its path")
		end,
	},

	isfolder = {
		Test = function()
			local IsFolder: (Path: string) -> boolean = isfolder
			assert(IsFolder(`Missing_{math.random()}`) == false, "didn't return false for a folder that doesn't exist")
			local FolderName = `Folder_{math.random()}`
			Formatters.CheckExist("makefolder")(FolderName)
			local Exists = IsFolder(FolderName)
			RemovePath("delfolder", FolderName)
			assert(Exists, "the folder wasn't found after it was made")
			local FileName = `File_{math.random()}.txt`
			Formatters.CheckExist("writefile")(FileName, "AURAUNC")
			local FileIsFolder = IsFolder(FileName)
			RemovePath("delfile", FileName)
			assert(FileIsFolder == false, "said a file is a folder")
		end,
	},

	delfolder = {
		Test = function()
			local IsFolder: (Path: string) -> boolean = Formatters.CheckExist("isfolder")
			local FolderName = `Folder_{math.random()}`
			Formatters.CheckExist("makefolder")(FolderName)
			assert(IsFolder(FolderName), "failed to find the folder after it was made")
			Formatters.CheckExist("writefile")(`{FolderName}/File.txt`, "AURAUNC")
			delfolder(FolderName)
			assert(not IsFolder(FolderName), "'isfolder' found a folder with a file in it after it should've been deleted")
		end,
	},

	hookfunction = {
		Test = function()
			local HookFunction: (FunctionToHook: (...any) -> (...any), Hook: (...any) -> ()) -> () -> () = hookfunction
			local NewCClosure: (((...any) -> ...any) -> (...any) -> ...any)? = newcclosure
			local RestoreFunction = restorefunction
			local function HookAndRestore(CClosure: any, Hook: Function, ...): (boolean, any)
				local Original = HookFunction(CClosure, Hook)
				AddCleanup(function()
					if not pcall(RestoreFunction, CClosure) then
						HookFunction(CClosure, Original)
					end
				end)
				local Success, Result = pcall(CClosure, ...)
				RestoreFunction(CClosure)
				return Success, Result
			end
			do
				local function FirstFunction()
					return true
				end
				local Original = HookFunction(FirstFunction, function()
					return false
				end)
				assert(typeof(Original) == "function", `should return the original function, got {typeof(Original)}`)
				local HookedResult = FirstFunction()
				HookFunction(FirstFunction, Original)
				assert(Original() == true, "the returned function isn't giving the expected result when called")
				assert(HookedResult == false, "the hooked function didn't return the hook's result")
				assert(FirstFunction() == true, "hooking the function back to the returned original didn't restore it")
			end
			do
				local OriginalRuns, HookRuns = 0, 0
				local function Target()
					OriginalRuns += 1
					return "AURAUNC Original"
				end
				local Environment = getfenv(Target)
				local function Hook()
					HookRuns += 1
					return "AURAUNC Hooked"
				end
				setfenv(Hook, setmetatable({}, {__index = Environment}))
				local Original = HookFunction(Target, Hook)
				local Result = Target()
				local OriginalRunsFromHookedCall = OriginalRuns
				assert(Original ~= Target, "returned the hooked function itself instead of a separate original")
				Formatters.CheckEqual(Result, "AURAUNC Hooked", "the hooked function's result")
				Formatters.CheckEqual(HookRuns, 1, "the number of times the hook ran for one call")
				Formatters.CheckEqual(OriginalRunsFromHookedCall, 0, "the number of times the original ran when only the hooked function was called")
				Formatters.CheckEqual(Original(), "AURAUNC Original", "the returned original's result")
				assert(getfenv(Target) == Environment, "the hooked function took on the hook's environment, so getfenv can tell it was hooked")
			end
			do
				local IsLoaded = game.IsLoaded
				local Restored = false
				local Original = HookFunction(IsLoaded, function()
					return "AURAUNC"
				end)
				AddCleanup(function()
					if not Restored then
						HookFunction(IsLoaded, Original)
					end
				end)
				local HookedResult = IsLoaded(game)
				local OriginalResult = Original(game)
				HookFunction(IsLoaded, Original)
				Restored = true
				Formatters.CheckEqual(HookedResult, "AURAUNC", "game.IsLoaded's result while hooked")
				Formatters.CheckEqual(OriginalResult, true, "the result of game.IsLoaded's returned original")
				Formatters.CheckEqual(IsLoaded(game), true, "game.IsLoaded's result after hooking it back")
				local function Target()
					return "AURAUNC Original"
				end
				HookFunction(Target, game.GetFullName)
				Formatters.CheckEqual(Target(workspace), workspace:GetFullName(), "a function hooked with game.GetFullName, given workspace,")
			end
			do
				local function Target(...)
					return select("#", ...)
				end
				local FirstOriginal
				FirstOriginal = HookFunction(Target, function(...)
					task.wait()
					return FirstOriginal(...) + 1
				end)
				Formatters.CheckEqual(Target(1, nil, nil), 4, "a function with a yielding hook, given 3 arguments ending in nils,")
				local SecondOriginal
				SecondOriginal = HookFunction(Target, function(...)
					return SecondOriginal(...) * 10
				end)
				Formatters.CheckEqual(Target(1, nil, nil), 40, "a function hooked twice, where the second hook's original should call the first hook,")
			end
			do
				local ErrorObject = {}
				local function Target() end
				HookFunction(Target, function()
					error(ErrorObject)
				end)
				local Success, Caught = pcall(Target)
				assert(not Success and Caught == ErrorObject, "an error object thrown inside a hook didn't reach the caller unchanged")
			end
			assert(not pcall(HookFunction, function() end), "hooking a function without giving a hook should error")
			assert(not pcall(HookFunction, 1, function() end), "hooking something that isn't a function should error")
			do
				local function LuaClosure()
					return true
				end
				HookFunction(LuaClosure, tick)
				assert(type(LuaClosure()) == "number", "expected the LuaClosure to return a number when hooked as 'tick'")
			end
			if NewCClosure then
				local function LuaClosure() end
				HookFunction(LuaClosure, NewCClosure(function()
					return true
				end))
				assert(LuaClosure() == true, "calling the LuaClosure didn't return the NewCClosure's result")
			end
			if RestoreFunction then
				local Success, Result = HookAndRestore(tostring, tonumber, "5")
				assert(Success and Result == 5, "expected tostring to return a number when hooked as tonumber and given '5'")
				local NumberSuccess, NumberResult = HookAndRestore(tonumber, function()
					return true
				end)
				assert(NumberSuccess and NumberResult == true, "expected tonumber to return a boolean when hooked as a LuaClosure that returns true")
			end
			if RestoreFunction and NewCClosure then
				local Success, Result = HookAndRestore(table.create, NewCClosure(function()
					return true
				end))
				assert(Success and Result == true, "expected table.create to return a boolean when hooked as a NewCClosure that returns true")
			end
			if not NewCClosure then
				return
			end
			do
				local FirstNewCClosure = NewCClosure(function() end)
				HookFunction(FirstNewCClosure, NewCClosure(function()
					return true
				end))
				assert(FirstNewCClosure() == true, "expected NewCClosure to return a boolean when hooked as a NewCClosure that returns true")
			end
			do
				local HookedNewCClosure = NewCClosure(function() end)
				HookFunction(HookedNewCClosure, function()
					return true
				end)
				assert(HookedNewCClosure() == true, "expected NewCClosure to return a boolean when hooked as a LuaClosure that returns true")
				assert(Formatters.CheckExist("debug.info")(HookedNewCClosure, "s") == "[C]", "a C function hooked with a LuaClosure stopped showing as [C]")
			end
			do
				local function NamedTarget()
					return "AURAUNC Original"
				end
				local Address = tostring(NamedTarget)
				local Name = debug.info(NamedTarget, "n")
				HookFunction(NamedTarget, NewCClosure(function()
					return "AURAUNC Hooked"
				end))
				Formatters.CheckEqual(tostring(NamedTarget), Address, "the hooked function's address")
				Formatters.CheckEqual(debug.info(NamedTarget, "n"), Name, "the name of a function hooked with a NewCClosure")
			end
			local HookedNewCClosure = NewCClosure(function() end)
			HookFunction(HookedNewCClosure, task.wait)
			assert(type(HookedNewCClosure()) == "number", "expected NewCClosure to return a number when hooked as task.wait")
		end,
	},

	iscclosure = {
		Test = function()
			local IsCClosure: (Function: (any?) -> ()) -> (boolean) = iscclosure
			assert(IsCClosure(assert) == true, "should return true for assert, which is a C closure")
			assert(IsCClosure(print) == true, "should return true for print, which is a C closure")
			assert(IsCClosure(task.wait) == true, "should return true for task.wait, which is a C closure")
			assert(not IsCClosure(function() end), "should return false for a function made in the executor")
		end,
	},

	clonefunction = {
		Test = function()
			local CloneFunction: ((any?) -> any?) -> ((any?) -> any?) = clonefunction
			local GeneratedNumber = math.random()
			local TestEnvironment = {}
			local function Original()
				return GeneratedNumber
			end
			local PreviousEnvironmentClone = CloneFunction(Original)
			setfenv(Original, TestEnvironment)
			local Clone = CloneFunction(Original)
			assert(Clone ~= Original, "the cloned and original function shouldn't have the same reference")
			assert(Clone() == Original(), "the cloned and original function should return the same value")
			assert(getfenv(Clone) == TestEnvironment, "didn't clone the function's environment")
			assert(getfenv(PreviousEnvironmentClone) ~= TestEnvironment, "the earlier clone picked up the original function's new environment")
			local OriginalInfo = {Formatters.CheckExist("debug.info")(Original, "slna")}
			local ClonedInfo = {Formatters.CheckExist("debug.info")(Clone, "slna")}
			for CheckName, Position in {Source = 1, Line = 2, Name = 3, Parameters = 4, VariableArguments = 5} do
				assert(ClonedInfo[Position] == OriginalInfo[Position], `"{CheckName}" isn't the same, it returned "{ClonedInfo[Position]}" instead of "{OriginalInfo[Position]}"`)
			end
			local WaitForChild = game.WaitForChild
			local NewWaitForChild = CloneFunction(WaitForChild)
			assert(WaitForChild ~= NewWaitForChild, "the cloned and original C function shouldn't have the same reference")
			local Terrain = workspace:FindFirstChildWhichIsA("Terrain")
			local Succes, Result = pcall(NewWaitForChild, workspace, Terrain.Name :: any)
			assert(Succes, `the new WaitForChild failed with "{Result}"`)
			assert(Result == Terrain, `the new WaitForChild returned "{Result}" instead of "{Terrain.Name}"`)
			local HookFunction = hookfunction
			if not HookFunction then
				return
			end
			local function Original()
				return "AURAUNC Original"
			end
			local Clone = clonefunction(Original)
			HookFunction(Original, function()
				return "AURAUNC Hooked"
			end)
			Formatters.CheckEqual(Clone(), "AURAUNC Original", "a clone's result after the function it was cloned from got hooked")
		end,
	},

	request = {
		Test = function()
			local HttpService = game:GetService("HttpService")
			local Marker = tostring(math.random(1, 1e9))
			local Success, Result = pcall(request, {
				Url = `https://httpbin.org/get?AURAUNC={Marker}`,
				Method = "GET",
				Headers = {["X-AURAUNC"] = Marker},
			})
			assert(Success, `the request errored with {Result}`)
			Formatters.CheckReturnType(Result, "table")
			assert(Result.StatusCode == 200, `failed to request, got status {Result.StatusCode} {Result.StatusMessage}`)
			assert(Result.StatusMessage == "OK", "StatusMessage should be 'OK' when the StatusCode is 200")
			assert(typeof(Result.Body) == "string", "expected a string from the Body")
			local Decoded = HttpService:JSONDecode(Result.Body)
			Formatters.CheckReturnType(Decoded, "table")
			local Headers = Decoded.headers
			assert(Headers, "the decoded body doesn't contain the headers")
			assert(Headers["X-AURAUNC"] == Marker, "the header that was sent didn't come back, so the request may not have really gone out")
			assert(Decoded.args and Decoded.args.AURAUNC == Marker, "the query that was sent didn't come back, so the request may not have really gone out")
			local HeaderNames = {}
			for Header in Headers do
				table.insert(HeaderNames, Header)
			end
			assert(FindFingerprintHeader(Headers), `missing the fingerprint (hwid) header, got {table.concat(HeaderNames, ", ")}`)
			local function Send(Options: {[string]: any}): {[string]: any}
				for Attempt = 1, 3 do
					local Response = request(Options)
					if typeof(Response.StatusCode) ~= "number" or Response.StatusCode ~= 429 and Response.StatusCode < 500 then
						return Response
					end
					task.wait(Attempt)
				end
				error({Skipped = "httpbin.org kept rate limiting or failing the requests", Environment = true})
			end
			for _, Method in {"POST", "PUT", "PATCH", "DELETE"} do
				local MethodResult = Send({Url = "https://httpbin.org/anything", Method = Method, Body = Marker})
				assert(MethodResult.StatusCode == 200 and HttpService:JSONDecode(MethodResult.Body).method == Method, `a {Method} request didn't go out as {Method}, got status {MethodResult.StatusCode}`)
			end
			local Missing = Send({Url = "https://httpbin.org/status/404", Method = "GET"})
			assert(Missing.StatusCode == 404 and Missing.Success == false, `a 404 should come back as a response with Success set to false, got status {Missing.StatusCode} and Success {Missing.Success}`)
			assert(typeof(Missing.Headers) == "table", "the response doesn't have its headers")
			Formatters.CheckEqual(#Send({Url = "https://httpbin.org/bytes/1024", Method = "GET"}).Body, 1024, "the length of 1024 random bytes")
			Formatters.CheckEqual(Send({Url = "https://httpbin.org/redirect/2", Method = "GET"}).StatusCode, 200, "the status after following 2 redirects")
			local Gzip = Send({Url = "https://httpbin.org/gzip", Method = "GET"})
			local GzipSuccess, GzipDecoded = pcall(HttpService.JSONDecode, HttpService, Gzip.Body)
			assert(GzipSuccess and GzipDecoded.gzipped == true, `a gzip response wasn't decoded, got status {Gzip.StatusCode} and body '{tostring(Gzip.Body):sub(1, 40)}'`)
			local Frames = 0
			local StartTime = os.clock()
			local Connection = game:GetService("RunService").Heartbeat:Connect(function()
				Frames += 1
			end)
			AddCleanup(function()
				Connection:Disconnect()
			end)
			Send({Url = "https://httpbin.org/delay/2", Method = "GET"})
			Connection:Disconnect()
			assert(Frames > (os.clock() - StartTime) * 5, `the game froze while waiting for a request, only {Frames} frames ran`)
		end,
		Retry = true,
	},

	require = {
		Test = function()
			local Module = GetPlayerModule()
			local Success, Result = pcall(require, Module)
			assert(Success, `expected success when requiring '{Module.Name}', got the error {Result}`)
			Formatters.CheckReturnType(Result, "table")
			assert(require(Module) == Result, "requiring the same module twice gave different results")
		end,
	},

	fireclickdetector = {
		Test = function()
			local Part = Instance.new("Part")
			local ClickDetector = Instance.new("ClickDetector", Part)
			Part.Anchored = true
			Part.Parent = workspace
			AddCleanup(function()
				Part:Destroy()
			end)
			local WasClicked = false
			ClickDetector.MouseClick:Once(function(ClickingPlayer)
				WasClicked = ClickingPlayer == Player
			end)
			fireclickdetector(ClickDetector)
			local Clicked = WaitFor(function()
				return WasClicked
			end, 1)
			assert(Clicked, "the connection wasn't fired")
			for _, EventName in {"RightMouseClick", "MouseHoverEnter", "MouseHoverLeave"} do
				local Fired = false
				local Connection = (ClickDetector :: any)[EventName]:Once(function()
					Fired = true
				end)
				fireclickdetector(ClickDetector, 0, EventName)
				local Worked = WaitFor(function()
					return Fired
				end, 1)
				Connection:Disconnect()
				assert(Worked, `{EventName} didn't fire when it was passed as the event`)
			end
			Part.Position = Vector3.new(0, 10000, 0)
			local MaxActivationDistance = ClickDetector.MaxActivationDistance
			local FarClicked = false
			ClickDetector.MouseClick:Once(function()
				FarClicked = true
			end)
			fireclickdetector(ClickDetector)
			local FiredFar = WaitFor(function()
				return FarClicked
			end, 1)
			Part:Destroy()
			assert(FiredFar, "didn't fire for a ClickDetector 10000 studs away")
			Formatters.CheckEqual(ClickDetector.MaxActivationDistance, MaxActivationDistance, "MaxActivationDistance after firing")
		end,
	},

	fireproximityprompt = {
		Test = function()
			local Part = Instance.new("Part")
			Part.Parent = workspace
			AddCleanup(function()
				Part:Destroy()
			end)
			Part.Anchored = true
			Part.Position = Vector3.new(0, 10000, 0)
			local ProximityPrompt = Instance.new("ProximityPrompt")
			ProximityPrompt.HoldDuration = 5
			ProximityPrompt.Parent = Part
			local Before = {
				HoldDuration = ProximityPrompt.HoldDuration,
				MaxActivationDistance = ProximityPrompt.MaxActivationDistance,
				RequiresLineOfSight = ProximityPrompt.RequiresLineOfSight,
				Enabled = ProximityPrompt.Enabled,
			}
			local WasTriggered = false
			ProximityPrompt.Triggered:Once(function(TriggeringPlayer)
				WasTriggered = TriggeringPlayer == Player
			end)
			fireproximityprompt(ProximityPrompt)
			local Triggered = WaitFor(function()
				return WasTriggered
			end, 1)
			for Property, Value in Before do
				assert((ProximityPrompt :: any)[Property] == Value, `left the prompt's {Property} changed after firing it`)
			end
			Part:Destroy()
			assert(Triggered, "didn't fire within a second for a prompt 10000 studs away with a 5 second HoldDuration")
		end,
	},

	firesignal = {
		Test = function()
			local NumberValue = Instance.new("NumberValue")
			local GeneratedValue = math.random()
			local DidChange = false
			NumberValue.Changed:Once(function(Value)
				DidChange = Value == GeneratedValue
			end)
			firesignal(NumberValue.Changed, GeneratedValue)
			assert(WaitFor(function()
				return DidChange
			end, 1), "the connection wasn't fired")
			local Event = Instance.new("BindableEvent")
			local Count
			Event.Event:Once(function(...)
				Count = select("#", ...)
			end)
			firesignal(Event.Event, nil, 2)
			WaitFor(function()
				return Count ~= nil
			end, 1)
			Event:Destroy()
			Formatters.CheckEqual(Count, 2, "the number of values passed when the first one is nil")
		end,
	},

	getloadedmodules = {
		Test = function()
			local LoadedModules = getloadedmodules()
			Formatters.CheckReturnType(LoadedModules, "table")
			local SeenModules = {}
			for _, Module in LoadedModules do
				assert(typeof(Module) == "Instance" and Module:IsA("ModuleScript"), `'{Module}' isn't a ModuleScript`)
				assert(not SeenModules[Module], `'{Module}' is in the returned table more than once`)
				SeenModules[Module] = true
			end
			assert(not table.find(LoadedModules, game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("PlayerModule") or false), "StarterPlayerScripts.PlayerModule shouldn't be in the returned table")
			assert(table.find(LoadedModules, GetPlayerModule()), "couldn't find 'PlayerScripts.PlayerModule' in the returned table")
			local Clone = GetPlayerModule().CommonUtils.CameraWrapper:Clone()
			Clone.Parent = Player:FindFirstChild("PlayerScripts") or Player.PlayerGui
			AddCleanup(function()
				Clone:Destroy()
			end)
			local FoundClone = table.find(getloadedmodules(), Clone)
			Clone:Destroy()
			assert(not FoundClone, "found a module that was never required")
		end,
		ReturnType = "table",
	},

	getconnections = {
		Test = function()
			local GetConnections = getconnections
			local NumberValue = Instance.new("NumberValue")
			local GeneratedValue = math.random()
			local DidChange = false
			local Calls = 0
			local WrongValue
			local function OnChanged(Value)
				Calls += 1
				if Value ~= GeneratedValue then
					WrongValue = WrongValue or Value
					return
				end
				DidChange = true
			end
			NumberValue.Changed:Connect(OnChanged)
			local Connections = GetConnections(NumberValue.Changed)
			assert(typeof(Connections) == "table", `expected a table, got {typeof(Connections)}`)
			assert(#Connections == 1, `expected 1 connection in the table, got {#Connections}`)
			assert(Connections[1].Fire, "expected method 'Fire' in the table")
			assert(Connections[1].Function == OnChanged, ".Function isn't the function that was connected")
			Connections[1]:Fire(GeneratedValue)
			assert(WaitFor(function()
				return DidChange
			end, 1), if WrongValue ~= nil then `the connection was fired with the wrong value, expected number '{GeneratedValue}' and got {typeof(WrongValue)} '{WrongValue}'` else "the connection wasn't fired")
			assert(typeof(Connections[1].Thread) == "thread", `.Thread should be a thread, got {typeof(Connections[1].Thread)}`)
			for Field, Type in {Enabled = "boolean", ForeignState = "boolean", LuaConnection = "boolean", Function = "function", Fire = "function", Defer = "function", Disconnect = "function", Disable = "function", Enable = "function"} do
				local Success, Value = pcall(function()
					return Connections[1][Field]
				end)
				assert(Success and type(Value) == Type, `.{Field} should be a {Type}, got {if Success then type(Value) else "an error"}`)
			end
			assert(Connections[1].Enabled == true, ".Enabled should be true for an active connection")
			Connections[1]:Disable()
			assert(Connections[1].Enabled == false, ".Enabled should be false after :Disable()")
			local CallsBeforeDisabled = Calls
			NumberValue.Value = GeneratedValue + 1
			task.wait()
			assert(Calls == CallsBeforeDisabled, "the connection still fired after :Disable()")
			Connections[1]:Enable()
			assert(Connections[1].Enabled == true, ".Enabled should be true after :Enable()")
			NumberValue.Value = GeneratedValue + 2
			assert(WaitFor(function()
				return Calls > CallsBeforeDisabled
			end, 1), "the connection didn't fire again after :Enable()")
			Connections[1]:Disconnect()
			DidChange = false
			NumberValue.Value = GeneratedValue
			task.wait()
			assert(not DidChange, "the connection still fired after :Disconnect()")
			assert(#GetConnections(NumberValue.Changed) == 0, "the connection is still listed after :Disconnect()")
			local OnceConnection = NumberValue.Changed:Once(function() end)
			Formatters.CheckEqual(#GetConnections(NumberValue.Changed), 1, "the number of connections after connecting with :Once()")
			OnceConnection:Disconnect()
		end,
	},

	getscripts = {
		Test = function()
			local Scripts = getscripts()
			assert(table.find(Scripts, GetPlayerModule()), "didn't find PlayerModule")
			for _, CurrentScript: BaseScript | ModuleScript in Scripts do
				assert(typeof(CurrentScript) == "Instance", `expected an instance, got {typeof(CurrentScript)} '{CurrentScript}'`)
				assert(CurrentScript:IsA("BaseScript") or CurrentScript:IsA("ModuleScript"), `instance '{CurrentScript}' isn't a script, its ClassName is {CurrentScript.ClassName}`)
			end
		end,
		ReturnType = "table",
	},

	setfpscap = {
		Test = function()
			local SetFPSCap: (FPSCap: number) -> () = setfpscap
			local function MeasureFPS(): number
				local StartTime = os.clock()
				local Frames = 0
				repeat
					task.wait()
					Frames += 1
				until os.clock() - StartTime >= 1
				return Frames / (os.clock() - StartTime)
			end
			local FPSCap = math.max(math.floor(MeasureFPS() / 4), 5)
			AddCleanup(function()
				SetFPSCap(0)
			end)
			SetFPSCap(FPSCap)
			WaitFor(function()
				local FrameStart = os.clock()
				task.wait()
				return os.clock() - FrameStart >= 0.8 / FPSCap
			end, 2)
			local CappedFPS = MeasureFPS()
			SetFPSCap(0)
			if CappedFPS <= FPSCap * 1.2 and MeasureFPS() <= FPSCap * 1.5 then
				error({Skipped = "the frame rate stayed low after the cap was removed, so the cap can't be told apart from lag", Environment = true})
			end
			assert(CappedFPS <= FPSCap * 1.2, `the frame rate averaged {math.floor(CappedFPS)} over a second, which is above the cap of {FPSCap}`)
		end,
		RunLast = true,
	},

	base64encode = {
		Test = function()
			local GeneratedString = CreateRandomString(math.random(1, 64))
			Formatters.CheckEqual(base64encode(GeneratedString), buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(GeneratedString))), "the encoded random string")
			Formatters.CheckEqual(base64encode(AllBytes), buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(AllBytes))), "every byte from 0 to 255 encoded")
			Formatters.CheckEqual(base64encode(""), "", "an empty string encoded")
		end,
	},

	loadstring = {
		Test = function()
			local Loaded = loadstring("return 'AURAUNC'")
			assert(typeof(Loaded) == "function", `expected the return type to be a function, got {typeof(Loaded)}`)
			assert(Loaded() == "AURAUNC", "failed to return the expected value")
			local ChunkName = `AURAUNC{math.random(1, 1e6)}`
			local Compiled, CompileError = loadstring("local x x", ChunkName)
			assert(Compiled == nil, "bad code compiled into a function")
			assert(tostring(CompileError):find(ChunkName, 1, true), `the compile error doesn't mention the chunk name, got '{CompileError}'`)
			assert(loadstring("return game")() == game, "the loaded code can't see the game global")
			local WithEnvironment = loadstring("return AURAUNCValue")
			setfenv(WithEnvironment, {AURAUNCValue = 5})
			Formatters.CheckEqual(WithEnvironment(), 5, "a value read after setfenv")
			local Modern, ModernError = loadstring([[
				--!strict
				type Pair<T> = {First: T, Second: T}
				local Total = 0
				for Index = 1, 4 do
					if Index == 2 then
						continue
					end
					Total += Index // 1
				end
				return if Total > 0 then `total {Total}` else ""
			]])
			assert(Modern, `current Luau syntax failed to compile with '{ModernError}'`)
			Formatters.CheckEqual(Modern(), "total 8", "the result of current Luau syntax")
		end,
	},

	getfpscap = {
		Test = function()
			local GetFPSCap: () -> number = getfpscap
			local SetFPSCap: (FPSCap: number) -> () = Formatters.CheckExist("setfpscap")
			AddCleanup(function()
				SetFPSCap(0)
			end)
			SetFPSCap(10)
			local Result = GetFPSCap()
			SetFPSCap(0)
			Formatters.CheckEqual(Result, 10, "the fps cap")
			assert(GetFPSCap() ~= Result, "set the fps cap to 0 but the result stayed at 10")
		end,
	},

	newcclosure = {
		Test = function()
			local function TestFunction()
				return "AURAUNC"
			end
			local NewClosure = newcclosure(TestFunction)
			assert(Formatters.CheckExist("debug.info")(NewClosure, "s") == "[C]", `expected the returned closure to be in [C], got '{Formatters.CheckExist("debug.info")(NewClosure, "s")}'`)
			assert(NewClosure ~= TestFunction, "the returned function is the same as the function given")
			assert(NewClosure() == "AURAUNC", "failed to return the expected value")
			assert(NewClosure() == "AURAUNC", "failed to return the expected value on the second call")
			Formatters.CheckEqual(newcclosure(function(First, Second)
				task.wait()
				return First + Second
			end)(2, 3), 5, "a wrapped function that yields")
			Formatters.CheckEqual(select("#", newcclosure(function(...)
				return ...
			end)(1, nil, nil)), 3, "the number of values passed through with trailing nils")
			if identifyexecutor and identifyexecutor() == "Delta" and not (shared.CrashTests or (shared.Settings and shared.Settings.CrashTests)) then
				error("catching an error thrown after a yield crashes Roblox on Delta, so it wasn't run, use shared.CrashTests = true to try it")
			end
			local ErrorObject = {}
			local Success, Caught = pcall(newcclosure(function()
				task.wait()
				error(ErrorObject)
			end))
			assert(not Success and Caught == ErrorObject, "an error object thrown after a yield didn't come back unchanged")
		end,
	},

	isscriptable = {
		Test = function()
			local IsScriptable: (Object: Object, Property: string) -> boolean = isscriptable
			assert(IsScriptable(game, "Parent") == true, "should return true for game.Parent")
			local HiddenSuccess, HiddenResult = pcall(IsScriptable, Instance.new("Fire"), "size_xml")
			assert(not HiddenSuccess or HiddenResult == false, "should return false for Fire.size_xml, which is a hidden property")
			local InvalidSuccess, InvalidResult = pcall(IsScriptable, game, "a")
			assert(not InvalidSuccess or not InvalidResult, "should return false or error for game.a, which isn't a real property")
		end,
	},

	firetouchinterest = {
		Test = function()
			local FireTouchInterest: (FireTouch: BasePart, WithPart: BasePart, Ended: number) -> () = firetouchinterest
			local RootPart = GetRootPart()
			local Pad = Instance.new("Part")
			Pad.Anchored = true
			Pad.CanCollide = false
			Pad.Position = RootPart.Position + Vector3.new(0, 100, 0)
			Pad.Parent = workspace
			AddCleanup(function()
				Pad:Destroy()
			end)
			local Complete = false
			Pad.Touched:Connect(function(Part)
				if RootPart ~= Part then
					return
				end
				Complete = true
			end)
			local Ended = false
			Pad.TouchEnded:Connect(function(Part)
				Ended = Ended or RootPart == Part
			end)
			FireTouchInterest(Pad, RootPart, 0)
			FireTouchInterest(Pad, RootPart, 1)
			local Touched = WaitFor(function()
				return Complete
			end, 5)
			local TouchEnded = WaitFor(function()
				return Ended
			end, 5)
			Pad:Destroy()
			assert(Touched, "failed to fire the touched event within 5 seconds")
			assert(TouchEnded, "failed to fire the touch ended event within 5 seconds")
		end,
	},

	hookmetamethod = {
		Test = function()
			local OriginalIndex = function() end
			local Metatable = setmetatable({}, {__index = OriginalIndex})
			local HookMetamethod = hookmetamethod
			local Original = HookMetamethod(Metatable, "__index", function()
				return "AURAUNC"
			end)
			Formatters.CheckReturnType(Original, "function")
			local HookedValue = Metatable.yay
			local KeptProto = getmetatable(Metatable).__index == OriginalIndex
			HookMetamethod(Metatable, "__index", Original)
			assert(HookedValue == "AURAUNC", "indexing the metatable failed to return the hooked value")
			assert(KeptProto, "replaced the metamethod's function instead of its proto")
			assert(Metatable.yay == nil, "hooking __index back to the returned original didn't undo the hook")
			local CheckCaller = Formatters.CheckExist("checkcaller")
			local GetNamecallMethod = Formatters.CheckExist("getnamecallmethod")
			local Seen = 0
			local Restored = false
			local GameOriginal
			GameOriginal = HookMetamethod(game, "__namecall", (newcclosure or function(Function)
				return Function
			end)(function(Self, ...)
				if CheckCaller() and Self == game and GetNamecallMethod() == "GetService" then
					Seen += 1
				end
				return GameOriginal(Self, ...)
			end))
			AddCleanup(function()
				if not Restored then
					HookMetamethod(game, "__namecall", GameOriginal)
				end
			end)
			local Service = game:GetService("Workspace")
			HookMetamethod(game, "__namecall", GameOriginal)
			Restored = true
			assert(Seen > 0, "hooking game's __namecall didn't catch a game:GetService call")
			assert(Service == workspace, "game:GetService gave the wrong result while __namecall was hooked")
			local function Capture(Metamethod: string): Function
				local Captured
				xpcall(function()
					if Metamethod == "__index" then
						return (game :: any)[{}]
					end
					return (game :: any):AURAUNCMissingMethod()
				end, function()
					Captured = debug.info(2, "f")
				end)
				return Captured
			end
			local function Outcome(Function: Function, ...): string
				local Success, Result = pcall(Function, ...)
				return if Success then "succeeded" else tostring(Result)
			end
			local CapturedIndex = Capture("__index")
			local CapturedNamecall = Capture("__namecall")
			assert(typeof(CapturedIndex) == "function" and typeof(CapturedNamecall) == "function", "couldn't capture the game's __index and __namecall the way game scripts do")
			local BadCalls = {
				{Name = "__index with a string as self", Call = function() return Outcome(CapturedIndex, "AURAUNC", "Name") end},
				{Name = "__index with a table as the key", Call = function() return Outcome(CapturedIndex, game, {}) end},
				{Name = "__index with no arguments", Call = function() return Outcome(CapturedIndex) end},
				{Name = "__namecall with no arguments", Call = function() return Outcome(CapturedNamecall) end},
				{Name = "__namecall with a string as self", Call = function() return Outcome(CapturedNamecall, "AURAUNC") end},
			}
			local Before = {}
			for Index, BadCall in BadCalls do
				Before[Index] = BadCall.Call()
			end
			local HookCalls = 0
			local IndexOriginal, NamecallOriginal
			local function Unhook()
				if IndexOriginal then
					pcall(HookMetamethod, game, "__index", IndexOriginal)
					IndexOriginal = nil
				end
				if NamecallOriginal then
					pcall(HookMetamethod, game, "__namecall", NamecallOriginal)
					NamecallOriginal = nil
				end
			end
			AddCleanup(Unhook)
			IndexOriginal = HookMetamethod(game, "__index", function(...)
				HookCalls += 1
				return IndexOriginal(...)
			end)
			NamecallOriginal = HookMetamethod(game, "__namecall", function(...)
				HookCalls += 1
				return NamecallOriginal(...)
			end)
			local After = {}
			for Index, BadCall in BadCalls do
				After[Index] = BadCall.Call()
			end
			local HookCallsFromBadCalls = HookCalls
			Unhook()
			for Index, BadCall in BadCalls do
				assert(After[Index] == Before[Index], `calling the game's {BadCall.Name} gave "{After[Index]}" once it was hooked instead of "{Before[Index]}", so game scripts can detect the hook`)
			end
			assert(HookCallsFromBadCalls == 0, `the hook ran for bad calls that should have errored before reaching it ({HookCallsFromBadCalls} times)`)
			local StackOriginal
			local StackRestored = false
			local HookEnvironment = setmetatable({}, {__index = getfenv()})
			local function StackHook(...)
				return StackOriginal(...)
			end
			setfenv(StackHook, HookEnvironment)
			StackOriginal = HookMetamethod(game, "__namecall", StackHook)
			AddCleanup(function()
				if not StackRestored then
					HookMetamethod(game, "__namecall", StackOriginal)
				end
			end)
			local FoundOnStack = false
			xpcall(function()
				return (game :: any):AURAUNCMissingMethod()
			end, function()
				for Level = 1, 50 do
					local Function = debug.info(Level, "f")
					if not Function then
						break
					end
					if Function == StackHook or getfenv(Function) == HookEnvironment then
						FoundOnStack = true
					end
				end
			end)
			local YieldSuccess, YieldResult = pcall(function()
				return workspace:WaitForChild(`AURAUNC{math.random(1, 1e6)}`, 0.1)
			end)
			HookMetamethod(game, "__namecall", StackOriginal)
			StackRestored = true
			assert(not FoundOnStack, "the __namecall hook could be found on the stack from an error handler, so game scripts can detect it")
			assert(YieldSuccess and YieldResult == nil, `WaitForChild couldn't yield through the hooked __namecall, got "{YieldResult}"`)
		end,
	},

	["debug.info"] = {
		Test = function()
			assert(typeof(debug.info) == "function", "scripts get a debug library without info, so any script using debug.info breaks")
			Formatters.CheckEqual(debug.info(print, "s"), "[C]", "the source of print")
		end,
	},

	setstackhidden = {
		Test = function()
			local SetStackHidden = setstackhidden
			local GetInfo = Formatters.CheckExist("debug.info")
			local function Inner(Mode: string): any
				if Mode == "frames" then
					local Functions = {}
					for Level = 1, 6 do
						local Function = GetInfo(Level, "f")
						if not Function then
							break
						end
						table.insert(Functions, Function)
					end
					return Functions
				end
				if Mode == "traceback" then
					return debug.traceback()
				end
				error("AURAUNC", 2)
			end
			local function HiddenCaller(Mode: string): any
				return Inner(Mode)
			end
			AddCleanup(function()
				SetStackHidden(HiddenCaller, false)
			end)
			assert(table.find(HiddenCaller("frames"), HiddenCaller), "the function wasn't on the stack before it was hidden")
			SetStackHidden(HiddenCaller, true)
			assert(not table.find(HiddenCaller("frames"), HiddenCaller), "debug.info still found the function on the stack after it was hidden")
			assert(not HiddenCaller("traceback"):find("HiddenCaller", 1, true), "debug.traceback still shows the function after it was hidden")
			Formatters.CheckEqual(select(2, pcall(HiddenCaller, "error")), "AURAUNC", "the error from a hidden function, which shouldn't have its location")
			SetStackHidden(HiddenCaller, false)
			assert(table.find(HiddenCaller("frames"), HiddenCaller), "the function stayed hidden after setting it back to false")
		end,
	},

	isstackhidden = {
		Test = function()
			local IsStackHidden = isstackhidden
			local SetStackHidden = Formatters.CheckExist("setstackhidden")
			local function Target() end
			AddCleanup(function()
				SetStackHidden(Target, false)
			end)
			Formatters.CheckEqual(IsStackHidden(Target), false, "the result for a function that isn't hidden")
			SetStackHidden(Target, true)
			Formatters.CheckEqual(IsStackHidden(Target), true, "the result after hiding the function")
			SetStackHidden(Target, false)
			Formatters.CheckEqual(IsStackHidden(Target), false, "the result after showing the function again")
		end,
	},

	["DirectoryWatcher.new"] = {
		Test = function()
			local CrashTests = shared.CrashTests or (shared.Settings and shared.Settings.CrashTests)
			if identifyexecutor and identifyexecutor() == "Synapse Z" and not CrashTests then
				error("this crashes Roblox on Synapse Z, so it wasn't run, use shared.CrashTests = true to try it")
			end
			local WriteFile = Formatters.CheckExist("writefile")
			local FolderName = `Folder_{math.random()}`
			local OtherFolderName = `Folder_{math.random()}`
			local FileName = `File_{math.random()}.txt`
			local Changed = {}
			Formatters.CheckExist("makefolder")(FolderName)
			makefolder(OtherFolderName)
			local Watcher = DirectoryWatcher.new(FolderName)
			AddCleanup(function()
				Watcher:Destroy()
			end)
			Watcher.OnChanged:Connect(function(Path)
				table.insert(Changed, tostring(Path))
			end)
			WriteFile(`{OtherFolderName}/{FileName}`, "AURAUNC")
			WriteFile(`{FolderName}/{FileName}`, "AURAUNC")
			local Detected = WaitFor(function()
				return #Changed > 0
			end, 2)
			local Count = #Changed
			local Control = DirectoryWatcher.new(FolderName)
			local ControlFired = false
			AddCleanup(function()
				Control:Destroy()
			end)
			Control.OnChanged:Connect(function()
				ControlFired = true
			end)
			Watcher:Destroy()
			WriteFile(`{FolderName}/{FileName}`, "AURAUNC Again")
			WaitFor(function()
				return ControlFired
			end, 2)
			assert(Detected, "OnChanged didn't fire after a file in the folder was written")
			assert(table.concat(Changed, " "):find(FileName, 1, true), `OnChanged didn't give the changed file's path, got '{table.concat(Changed, ", ")}'`)
			assert(not table.concat(Changed, " "):find(OtherFolderName, 1, true), "OnChanged fired for a file in a different folder")
			Formatters.CheckEqual(#Changed, Count, "the number of changes after Destroy")
		end,
	},

	["WebSocket.connect"] = {
		Test = function()
			local Socket = WebSocket.connect("wss://echo.websocket.org")
			local Marker = `AURAUNC {math.random()} привет ✓`
			local Messaged = false
			local Closed = false
			local Connection = Socket.OnMessage:Connect(function(Message)
				if Message ~= Marker then
					return
				end
				Messaged = true
			end)
			Socket.OnClose:Once(function()
				Closed = true
			end)
			AddCleanup(function()
				Connection:Disconnect()
				if not Closed then
					Socket:Close()
				end
			end)
			Socket:Send(Marker)
			WaitFor(function()
				return Messaged
			end, 5)
			Connection:Disconnect()
			Socket:Close()
			assert(Messaged, "the echo server didn't send back the message within 5 seconds")
			assert(WaitFor(function()
				return Closed
			end, 1), "OnClose failed to fire when :Close() was called")
		end,
		Retry = true,
	},

	["cache.invalidate"] = {
		Test = function()
			local Container = Instance.new("Folder")
			local Part = Instance.new("Part", Container)
			cache.invalidate(Container:FindFirstChild("Part"))
			assert(not rawequal(Part, Container:FindFirstChild("Part")), "the reference to the part couldn't be invalidated")
		end,
	},

	["cache.iscached"] = {
		Test = function()
			local IsCached = cache.iscached
			local Part = Instance.new("Part")
			assert(IsCached(Part), "the part should be cached")
			Formatters.CheckExist("cache.invalidate")(Part)
			assert(not IsCached(Part), "the part shouldn't be cached")
		end,
	},

	["cache.replace"] = {
		Test = function()
			local Folder = Instance.new("Folder")
			local Part = Instance.new("Part") :: Instance
			local Fire = Instance.new("Fire") :: Instance
			Part.Parent = Folder
			cache.replace(Part, Fire)
			assert(Folder:FindFirstChildWhichIsA("Instance") == Fire, "looking up the part still gave back the part instead of the fire")
		end,
	},

	cloneref = {
		Test = function()
			local Part = Instance.new("Part")
			local ClonedReference = cloneref(Part) :: Part
			local NewPosition = Vector3.new(69, 67, 420)
			assert(typeof(ClonedReference) == "Instance", `expected an Instance, got {typeof(ClonedReference)}`)
			assert(not rawequal(ClonedReference, Part), "the cloned reference shouldn't be the same as the original reference")
			Part.Position = NewPosition
			assert(ClonedReference:GetPivot().Position == NewPosition, "setting the Position property of the original reference doesn't update the cloned reference")
		end,
	},

	compareinstances = {
		Test = function()
			local Part = Instance.new("Part")
			local Clone = Formatters.CheckExist("cloneref")(Part)
			assert(not rawequal(Part, Clone), "the clone shouldn't be equal to the original")
			assert(compareinstances(Part, Instance.new("Part")) == false, "two different parts shouldn't be equal")
			assert(compareinstances(Part, Clone), "the clone should be equal to the original when using compareinstances()")
		end,
	},

	checkcaller = {
		Test = function()
			local CheckCaller = checkcaller
			assert(CheckCaller() == true, "should return true when called by the executor")
			local FoundModule, CameraModule = pcall(function()
				return GetPlayerModule().CameraModule
			end)
			assert(FoundModule, "BaseCamera doesn't exist, go to a normal game")
			local Success, Camera = pcall(require, CameraModule.BaseCamera)
			assert(Success, `failed to require BaseCamera with the error {Camera}`)
			local Old = Camera.GetSubjectPosition
			local Called: boolean?
			Camera.GetSubjectPosition = function(...)
				Camera.GetSubjectPosition = Old
				Called = CheckCaller()
				return Old(...)
			end
			WaitFor(function()
				return Called ~= nil
			end, 2)
			Camera.GetSubjectPosition = Old
			if Called == nil then
				error({Skipped = "the camera never called the hooked function", Environment = true})
			end
			assert(Called == false, "should return false when called by the CameraModule.BaseCamera")
		end,
	},

	isfunctionhooked = {
		Test = function()
			local IsFunctionHooked: ((...any?) -> ...any?) -> boolean = isfunctionhooked
			local RestoreFunction = restorefunction
			local function Test()
				return "AURAUNC Original"
			end
			assert(IsFunctionHooked(Test) == false, "an unhooked function should return false")
			Formatters.CheckExist("hookfunction")(Test, function()
				return "AURAUNC Hooked"
			end)
			assert(IsFunctionHooked(Test) == true, "a hooked function should return true")
			if not RestoreFunction then
				return
			end
			RestoreFunction(Test)
			assert(IsFunctionHooked(Test) == false, "a restored hooked function should return false")
		end,
	},

	base64decode = {
		Test = function()
			local GeneratedString = CreateRandomString(math.random(1, 64))
			Formatters.CheckEqual(base64decode(buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(GeneratedString)))), GeneratedString, "the decoded random string")
			assert(base64decode(buffer.tostring(EncodingService:Base64Encode(buffer.fromstring(AllBytes)))) == AllBytes, "decoding every byte from 0 to 255 didn't give them all back unchanged")
			Formatters.CheckEqual(base64decode(""), "", "an empty string decoded")
		end,
	},

	setrawmetatable = {
		Test = function()
			local LockedProxy = newproxy()
			assert(getmetatable(LockedProxy) == nil, "a new proxy shouldn't have a metatable")
			local MainMetatable = {__call = function()
				return "AURAUNC"
			end}
			setrawmetatable(LockedProxy, MainMetatable)
			assert(getmetatable(LockedProxy) == MainMetatable, "the new proxy's metatable wasn't set to the expected one")
			local Success, Result = pcall(LockedProxy)
			assert(Success, `errored while calling the new proxy with {Result}`)
			assert(Result == "AURAUNC", "calling the new proxy failed to return the expected value")
		end,
	},

	lz4compress = {
		Test = function()
			local Compress = lz4compress
			local Repeated = string.rep(CreateRandomString(8), 100)
			assert(Compress("AURAUNC") == "`AURAUNC", "failed to compress the string with lz4")
			assert(#Compress(Repeated) < #Repeated / 4, "a string repeated 100 times barely got smaller, so it isn't really compressing")
			Formatters.CheckEqual(Formatters.CheckExist("lz4decompress")(Compress(Repeated), #Repeated), Repeated, "the decompressed string")
		end,
	},

	lz4decompress = {
		Test = function()
			local GeneratedString = CreateRandomString(math.random(16, 256))
			assert(lz4decompress("`AURAUNC", 6) == "AURAUNC", "failed to decompress the string with lz4")
			Formatters.CheckEqual(lz4decompress("\x1Aa\x01\x00\x50aaaaa", 20), string.rep("a", 20), "a known compressed block")
			Formatters.CheckEqual(lz4decompress(Formatters.CheckExist("lz4compress")(GeneratedString), #GeneratedString), GeneratedString, "the decompressed random string")
			assert(lz4decompress(Formatters.CheckExist("lz4compress")(AllBytes), #AllBytes) == AllBytes, "every byte from 0 to 255 didn't survive compressing and decompressing")
		end,
	},

	["debug.getproto"] = {
		Test = function()
			local Proto = debug.getproto(function()
				local function Inner()
					return "AURAUNC"
				end
			end, 1)
			assert(Proto, "didn't return anything")
			if typeof(Proto) ~= "function" then
				return
			end
			Formatters.CheckEqual(Formatters.CheckExist("debug.info")(Proto, "n"), "Inner", "the name of the inner function")
		end,
	},

	["debug.getprotos"] = {
		Test = function()
			local Protos = debug.getprotos(function()
				local function First()
					return "AURAUNC First"
				end
				local function Second()
					return "AURAUNC Second"
				end
			end)
			Formatters.CheckReturnType(Protos, "table")
			Formatters.CheckEqual(#Protos, 2, "the number of inner functions")
			for Index, Name in {"First", "Second"} do
				if typeof(Protos[Index]) ~= "function" then
					continue
				end
				Formatters.CheckEqual(Formatters.CheckExist("debug.info")(Protos[Index], "n"), Name, "the name of the inner function")
			end
		end,
	},

	getnamecallmethod = {
		Test = function()
			local GetNamecallMethod: () -> string = getnamecallmethod
			local ProxyTest = newproxy(true)
			local Detected
			getmetatable(ProxyTest).__namecall = function()
				Detected = GetNamecallMethod()
			end
			local Method = `AURAUNC{math.random(1, 1e6)}`
			local Success, Result = pcall(loadstring(`local ProxyTest = ... ProxyTest:{Method}()`) :: Function, ProxyTest)
			assert(Success, `errored while calling the new proxy with namecall, got {Result}`)
			Formatters.CheckEqual(Detected, Method, "the namecall method inside __namecall")
			local Outside = Method
			task.spawn(function()
				local Success, Result = pcall(GetNamecallMethod)
				Outside = if Success then Result else nil
			end)
			Formatters.CheckEqual(Outside, nil, "the namecall method on a new thread that never made a namecall")
		end,
	},

	getcallingscript = {
		Test = function()
			local Success, CameraWrapper = pcall(require, GetPlayerModule().CommonUtils.CameraWrapper)
			assert(Success, "your executor needs to support 'require' to run this test")
			local GetCameraOriginal = CameraWrapper.getCamera
			local CallingScript
			local Called = false
			CameraWrapper.getCamera = function(...)
				CameraWrapper.getCamera = GetCameraOriginal
				Called = true
				CallingScript = getcallingscript()
				return GetCameraOriginal(...)
			end
			if not WaitFor(function()
				return Called
			end, 2) then
				CameraWrapper.getCamera = GetCameraOriginal
				error({Skipped = "the camera never called the hooked function", Environment = true})
			end
			assert(CallingScript, "returned nil when it should've returned a script")
			assert(CallingScript:IsDescendantOf(GetPlayerModule()), `the calling script of CameraWrapper.getCamera should be inside of PlayerModule, got '{CallingScript}'`)
		end,
	},

	isnetworkowner = {
		RunLast = true,
		Test = function()
			local IsNetworkOwner = isnetworkowner
			local RootPart = GetRootPart()
			assert(IsNetworkOwner(RootPart) == true, "should return true on your HumanoidRootPart")
			for _, Descendant in workspace:GetDescendants() do
				if not Descendant:IsA("BasePart") or not Descendant.Anchored or Descendant:IsDescendantOf(RootPart.Parent :: Instance) then
					continue
				end
				assert(IsNetworkOwner(Descendant) == false, `should return false on '{Descendant:GetFullName()}', an anchored part the server owns`)
				return
			end
		end,
	},

	replicatesignal = {
		Test = function()
			local ReplicateSignal = replicatesignal
			assert(not pcall(ReplicateSignal, workspace.ChildAdded), "should error on a signal that can't be replicated")
			local RootPart = GetRootPart()
			local Character = RootPart.Parent :: Model
			local Died = false
			(Character:FindFirstChildWhichIsA("Humanoid") :: Humanoid).Died:Once(function()
				Died = true
			end)
			ReplicateSignal(Player.Kill)
			assert(WaitFor(function()
				return Died
			end, 5), "you weren't killed within 5 seconds after replicating Player.Kill")
			WaitFor(function()
				local NewCharacter = Player.Character
				return NewCharacter ~= nil and NewCharacter ~= Character and NewCharacter:FindFirstChild("HumanoidRootPart") ~= nil
			end, game:GetService("Players").RespawnTime + 10)
		end,
		RunLast = true,
	},

	["game.HttpPost"] = {
		Test = function()
			local Marker = `AURAUNC {math.random(1, 1e9)}`
			local Success, Result = pcall(game.HttpPost, game, "https://httpbin.org/post", Marker, "text/plain")
			assert(Success, `failed to post to httpbin with the error {Result}`)
			Formatters.CheckReturnType(Result, "string")
			local DecodeSuccess, Decoded = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), Result)
			assert(DecodeSuccess, `httpbin didn't answer with its JSON echo, so the request may not have gone out as a POST, got '{Result:sub(1, 80)}'`)
			Formatters.CheckEqual(Decoded.data, Marker, "the body httpbin got")
			assert(tostring(Decoded.headers["Content-Type"]):find("text/plain", 1, true), `the content type wasn't sent, httpbin got '{Decoded.headers["Content-Type"]}'`)
		end,
		Retry = true,
	},

	["game.HttpGet"] = {
		Test = function()
			local MissingSuccess, MissingResult = pcall(game.HttpGet, game, "https://awqbcduwendewbnzd.aaaaaa")
			assert(not MissingSuccess or not MissingResult or MissingResult == "", "game:HttpGet on a website that doesn't exist should return an error, nil, or an empty string")
			local Marker = tostring(math.random(1, 1e9))
			local Success, Result = pcall(game.HttpGet, game, `https://httpbin.org/get?AURAUNC={Marker}`)
			assert(Success, `failed to get httpbin with the error {Result}`)
			local DecodeSuccess, Decoded = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), Result)
			assert(DecodeSuccess, "the response wasn't the JSON httpbin sends back")
			assert(Decoded.args and Decoded.args.AURAUNC == Marker, "the query that was sent didn't come back, so the request may not have really gone out")
			local Cached = false
			for _, Page in {
				{Kind = "JSON", Url = `https://httpbin.org/uuid?AURAUNC={math.random(1, 1e9)}`},
				{Kind = "HTML", Url = `https://www.random.org/integers/?num=1&min=1&max=1000000000&col=1&base=10&format=html&rnd=new&AURAUNC={math.random(1, 1e9)}`},
				{Kind = "plain text", Url = `https://www.random.org/integers/?num=1&min=1&max=1000000000&col=1&base=10&format=plain&rnd=new&AURAUNC={math.random(1, 1e9)}`},
			} do
				local First = game:HttpGet(Page.Url)
				local Second = game:HttpGet(Page.Url)
				local NoCacheSuccess, Fresh = pcall(game.HttpGet, game, Page.Url, true)
				assert(NoCacheSuccess, `passing true for NoCache errored with {Fresh}`)
				assert(typeof(Fresh) == "string" and #Fresh > 0, `passing true for NoCache didn't return the {Page.Kind} response`)
				assert(game:HttpGet(Page.Url, true) ~= Fresh, `two {Page.Kind} requests with NoCache set to true gave the same cached response, so true may be treated as cache instead of no cache`)
				if First == Second then
					Cached = true
					assert(Fresh ~= First, `the same {Page.Kind} url gave a cached response even with NoCache set to true`)
				end
			end
			assert(Cached, "requesting the same url twice never gave a cached response, so NoCache has nothing to skip")
		end,
		Retry = true,
	},

	identifyexecutor = {
		Test = function()
			local Name, ExecutorVersion = identifyexecutor()
			assert(typeof(Name) == "string", "the first returned value, the executor's name, should be a string")
			assert(typeof(ExecutorVersion) == "string", "the second returned value, the executor's version, should be a string")
			assert(Name ~= "", "the executor's name is empty")
			assert(ExecutorVersion:find("%d"), `the executor's version should have a number in it, got '{ExecutorVersion}'`)
			assert(ExecutorVersion:lower():gsub("^v", "") ~= ({
				Lucid = "1.0.0",
				Bunni = "2.0",
				athena = "1.0",
			})[Name], `the version '{ExecutorVersion}' never changes between updates, it should be the real version of each release`)
		end,
	},

	gethwid = {
		Test = function()
			local GetHardwareId = gethwid
			local HardwareId = GetHardwareId()
			local Request = request
			assert(typeof(HardwareId) == "string", "the returned value (user's hwid/fingerprint) should be a string")
			assert(HardwareId ~= "", "the hwid is empty")
			assert(GetHardwareId() == HardwareId, "calling it twice gave different hwids")
			if not Request then
				return
			end
			local Success, Result = pcall(Request, {
				Url = "https://httpbin.org/get",
				Method = "GET",
			})
			if not Success then
				return
			end
			local Decoded, Response = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), Result.Body)
			if not Decoded then
				return
			end
			local Header = FindFingerprintHeader(Response.headers)
			if not Header then
				return
			end
			assert(Response.headers[Header] == HardwareId, `the hwid doesn't match the '{Header}' header that request sends`)
		end,
	},

	getrawmetatable = {
		Test = function()
			local GetRawMetatable: (Table: {[any]: any}) -> any = getrawmetatable
			local Detector = newproxy(true)
			local FakeMetatable = {__index = function()
				return true
			end}
			local DetectorMetatable = getmetatable(Detector)
			local IndexFunction = function()
				return (function()
					return error("first AURAUNC", 2)
				end)()
			end
			DetectorMetatable.__index = IndexFunction
			DetectorMetatable.__metatable = FakeMetatable
			local RawDetectorMetatable = GetRawMetatable(Detector)
			assert(RawDetectorMetatable == GetRawMetatable(Detector), "didn't return the same thing twice")
			assert(RawDetectorMetatable ~= FakeMetatable, "it's just getmetatable under another name")
			assert(RawDetectorMetatable == DetectorMetatable, "failed to return the original metatable")
			assert(rawequal(RawDetectorMetatable, DetectorMetatable), "failed to return the original metatable and tried to fake it")
			assert(not table.isfrozen(RawDetectorMetatable), "returned a read-only metatable")
			assert(IndexFunction == RawDetectorMetatable.__index, "didnt return the original __index")
			local NewIndexFunction = `AURAUNC {math.random()}`
			DetectorMetatable.__index = NewIndexFunction
			assert(NewIndexFunction == RawDetectorMetatable.__index, `changed __index to {NewIndexFunction} but it still returns the old one`)
			assert(getmetatable(Detector) == FakeMetatable, "getmetatable stopped returning the locked __metatable value")
			local StringMetatable = GetRawMetatable("")
			assert(typeof(StringMetatable) == "table" and StringMetatable.__index == string, "didn't return the string metatable")
			assert(typeof(GetRawMetatable(Vector3.zero)) == "table", "didn't return a Vector3's metatable")
			assert(GetRawMetatable({}) == nil, "returned a metatable for a table that doesn't have one")
			local FirstPart = Instance.new("Part") :: any
			local FirstPartMetatable = GetRawMetatable(FirstPart)
			assert(FirstPartMetatable == GetRawMetatable(Instance.new("Part") :: any), "didn't return the same metatable for unmodified parts")
			assert(table.isfrozen(FirstPartMetatable), "returned a part metatable that isn't read-only")
			for _, MetamethodName in {"__index", "__newindex", "__namecall", "__metatable"} do
				assert(FirstPartMetatable[MetamethodName], `{MetamethodName} isn't valid in a part`)
			end
			local IndexMetamethod
			xpcall(function()
				return FirstPart[{}]
			end, function()
				IndexMetamethod = Formatters.CheckExist("debug.info")(2, "f")
			end)
			assert(FirstPartMetatable.__index == IndexMetamethod, `__index gave {FirstPartMetatable.__index} instead of {IndexMetamethod} (__index may not be a CClosure)`)
		end,
	},

	["debug.getinfo"] = {
		Test = function()
			local GetInfo = Formatters.CheckExist("debug.getinfo")
			local function AurauncIsBetterThanSunc() end
			local LuaInfo = GetInfo(AurauncIsBetterThanSunc)
			assert(LuaInfo.what == "Lua", ".what should be 'Lua' when used on a Lua function")
			assert(LuaInfo.name == "AurauncIsBetterThanSunc", ".name should match the name of the Lua function")
			local CInfo = GetInfo(task.wait)
			assert(CInfo.what == "C", ".what should be 'C' when used on task.wait")
			assert(CInfo.name == "wait", ".name should be 'wait' when used on task.wait")
			local function WithArguments(First, Second, ...) end
			local Arguments = GetInfo(WithArguments)
			assert(Arguments.func == WithArguments, ".func should be the function")
			Formatters.CheckEqual(Arguments.numparams, 2, ".numparams")
			Formatters.CheckEqual(Arguments.is_vararg, 1, ".is_vararg")
		end,
	},

	setreadonly = {
		Test = function()
			local SetReadOnly: (Table: any, ReadOnly: boolean) -> () = setreadonly
			local ReadOnlyTable = ColorSequence :: any
			local function ReadOnlyEditTest()
				if not pcall(function()
					ReadOnlyTable[1] = "AURAUNC"
				end) then
					return false
				end
				pcall(function()
					ReadOnlyTable[1] = nil
				end)
				return true
			end
			assert(table.isfrozen(ReadOnlyTable), "ColorSequence isn't frozen")
			assert(not ReadOnlyEditTest(), "shouldn't be able to write to ColorSequence while it's frozen")
			AddCleanup(function()
				table.freeze(ReadOnlyTable)
			end)
			SetReadOnly(ReadOnlyTable, false)
			local WriteSuccess, WriteError = pcall(function()
				ReadOnlyTable[123] = "AURAUNC"
			end)
			pcall(function()
				ReadOnlyTable[123] = nil
			end)
			local Unfrozen = not table.isfrozen(ReadOnlyTable)
			SetReadOnly(ReadOnlyTable, true)
			local StillWritable = ReadOnlyEditTest()
			if StillWritable then
				pcall(table.freeze, ReadOnlyTable)
			end
			assert(WriteSuccess, `failed to write after unfreezing, got {WriteError}`)
			assert(Unfrozen, "the table still looks frozen after unfreezing")
			assert(not StillWritable, "the table didn't become read-only again")
			local Plain = {}
			SetReadOnly(Plain, true)
			assert(not pcall(function()
				Plain.AURAUNC = true
			end), "a normal table could still be written to after making it read-only")
			local GameMetatable = Formatters.CheckExist("getrawmetatable")(game)
			AddCleanup(function()
				SetReadOnly(GameMetatable, true)
			end)
			SetReadOnly(GameMetatable, false)
			local GameUnlocked = not table.isfrozen(GameMetatable)
			SetReadOnly(GameMetatable, true)
			assert(GameUnlocked, "game's metatable stayed read-only after unlocking it")
			assert(table.isfrozen(GameMetatable), "game's metatable didn't become read-only again")
		end,
	},

	getsenv = {
		Test = function()
			local GetScriptEnvironment: (Script: LocalScript) -> any = getsenv
			local PlayerScripts = GetPlayerScripts()
			local Value = math.random()
			local function CreateNewModuleTest(SetParent: boolean)
				local New = PlayerScripts.RbxCharacterSounds:Clone()
				local AtomicBinding = New:FindFirstChildWhichIsA("ModuleScript")
				assert(AtomicBinding, "failed to find the 'AtomicBinding' ModuleScript in the cloned RbxCharacterSounds")
				local Called = false
				require(AtomicBinding).new = function()
					if SetParent then
						New.Parent = nil
					end
					Called = true
					getfenv(2).AURAUNC = Value
					return task.wait(9e9)
				end
				New.Parent = Player:FindFirstChild("PlayerScripts") or Player.PlayerGui
				AddCleanup(function()
					New:Destroy()
				end)
				return WaitFor(function()
					return Called
				end, 2), New
			end
			local Called, NewSoundsScript = CreateNewModuleTest(false)
			local ScriptEnvironment = Called and GetScriptEnvironment(NewSoundsScript)
			NewSoundsScript:Destroy()
			assert(Called, "the script took too long to respond")
			assert(ScriptEnvironment, "getsenv returned nil")
			assert(ScriptEnvironment.script == NewSoundsScript, ".script doesn't point to the script being used in the function call")
			Formatters.CheckEqual(ScriptEnvironment.AURAUNC, Value, "a global set by the running script")
			local NilParentCalled, NewSoundsNilScript = CreateNewModuleTest(true)
			local NilParentEnvironment = NilParentCalled and GetScriptEnvironment(NewSoundsNilScript)
			NewSoundsNilScript:Destroy()
			assert(NilParentCalled, "the script took too long to respond when its parent was nil")
			assert(NilParentEnvironment, "getsenv returned nil when the parent was nil")
		end,
	},

	decompile = {
		Test = function()
			local Decompile = decompile
			local GetScriptClosure = getscriptclosure
			local CameraModule = GetPlayerModule().CameraModule
			local Result = Decompile(CameraModule)
			Formatters.CheckReturnType(Result, "string")
			assert(not Result:find("\0", 1, true), "the result has null bytes, so it isn't readable code")
			assert(Result:find("__index"), `couldn't find '__index' in the decompiled 'CameraModule', it started with '{Result:sub(1, 300)}'`)
			assert(Decompile(CameraModule.Parent.ControlModule) ~= Result, "'CameraModule' and 'ControlModule' decompiled to the same thing")
			if not GetScriptClosure then
				return
			end
			for _, Constant in Formatters.CheckExist("debug.getconstants")(GetScriptClosure(CameraModule)) do
				if typeof(Constant) ~= "string" or #Constant < 5 or not Constant:match("^[%w_]+$") then
					continue
				end
				assert(Result:find(Constant, 1, true), `couldn't find the string '{Constant}' from the script's own constants in the decompiled 'CameraModule'`)
			end
		end,
	},

	mouse1click = {
		Test = function()
			CheckMouseButton(1, "mouse1click")
		end,
		RunLast = true,
	},

	mouse1press = {
		Test = function()
			CheckMouseButton(1, "mouse1press")
		end,
		RunLast = true,
	},

	mouse1release = {
		Test = function()
			CheckMouseButton(1, "mouse1release")
		end,
		RunLast = true,
	},

	mouse2click = {
		Test = function()
			CheckMouseButton(2, "mouse2click")
		end,
		RunLast = true,
	},

	mouse2press = {
		Test = function()
			CheckMouseButton(2, "mouse2press")
		end,
		RunLast = true,
	},

	mouse2release = {
		Test = function()
			CheckMouseButton(2, "mouse2release")
		end,
		RunLast = true,
	},

	mousemoveabs = {
		Test = function()
			CheckInputFree()
			local Center = workspace.CurrentCamera.ViewportSize / 2
			local function MoveTo(Target: Vector2): Vector2
				local Before = UserInputService:GetMouseLocation()
				mousemoveabs(Target.X, Target.Y)
				WaitFor(function()
					return UserInputService:GetMouseLocation() ~= Before
				end, 1)
				return UserInputService:GetMouseLocation()
			end
			local FirstTarget = Center - Vector2.new(math.random(30, 60), math.random(30, 60))
			local SecondTarget = Center + Vector2.new(math.random(30, 60), math.random(30, 60))
			local LastTarget = Center + Vector2.new(math.random(-50, 50), math.random(-50, 50))
			local First = MoveTo(FirstTarget)
			local Second = MoveTo(SecondTarget)
			local Scale = (Second - First) / (SecondTarget - FirstTarget)
			assert(Scale.X > 0 and math.abs(Scale.X - Scale.Y) < Scale.X * 0.02, `the mouse went to {First} then {Second}, which doesn't match moving to {FirstTarget} then {SecondTarget}`)
			local Expected = First + (LastTarget - FirstTarget) * Scale.X
			local Last = MoveTo(LastTarget)
			assert((Last - Expected).Magnitude < 2, `the mouse went to {Last} instead of {Expected}`)
		end,
		RunLast = true,
	},

	mousemoverel = {
		Test = function()
			CheckInputFree()
			CenterMouse()
			local function MoveBy(Amount: number): Vector2
				local Before = UserInputService:GetMouseLocation()
				mousemoverel(Amount, Amount)
				WaitFor(function()
					return UserInputService:GetMouseLocation() ~= Before
				end, 1)
				return UserInputService:GetMouseLocation() - Before
			end
			local FirstMove = MoveBy(25)
			local SecondMove = MoveBy(50)
			assert(FirstMove.X > 0 and math.abs(FirstMove.X - FirstMove.Y) < 2 and (SecondMove - FirstMove * 2).Magnitude < 3, `the mouse moved by {FirstMove} then {SecondMove}, but moving by 25 then 50 should go the same way twice as far`)
		end,
		RunLast = true,
	},

	mousescroll = {
		Test = function()
			CheckInputFree()
			local MouseMoveAbsolute = mousemoveabs
			if MouseMoveAbsolute then
				local Target = Vector2.new(workspace.CurrentCamera.ViewportSize.X / 2, 65)
				MouseMoveAbsolute(Target.X, Target.Y)
				WaitFor(function()
					return (UserInputService:GetMouseLocation() - Target).Magnitude < 2
				end, 2)
			end
			local MouseScroll = mousescroll
			local Detected = WaitForInput(UserInputService.InputChanged, function(Input)
				return Input.UserInputType == Enum.UserInputType.MouseWheel and Input.Position.Z > 0
			end, function()
				MouseScroll(120)
			end)
			local DetectedDown = WaitForInput(UserInputService.InputChanged, function(Input)
				return Input.UserInputType == Enum.UserInputType.MouseWheel and Input.Position.Z < 0
			end, function()
				MouseScroll(-120)
			end)
			assert(Detected, "the scroll up wasn't detected")
			assert(DetectedDown, "the scroll down wasn't detected")
		end,
		RunLast = true,
	},

	keypress = {
		Test = function()
			CheckKey("keypress")
		end,
		RunLast = true,
	},

	keyrelease = {
		Test = function()
			CheckKey("keyrelease")
		end,
		RunLast = true,
	},

	sethiddenproperty = {
		Test = function()
			local Fire = Instance.new("Fire")
			local NewValue = math.random(6, 20)
			local Part = Instance.new("Part")
			sethiddenproperty(Part, "Transparency", 0.5)
			Formatters.CheckEqual(Part.Transparency, 0.5, "a part's Transparency")
			sethiddenproperty(Fire, "size_xml", NewValue)
			Formatters.CheckEqual(Formatters.CheckExist("gethiddenproperty")(Fire, "size_xml"), NewValue, "size_xml")
		end,
	},

	gethiddenproperty = {
		Test = function()
			local Fire = Instance.new("Fire")
			local Size = math.random(6, 20)
			Fire.Size = Size
			Formatters.CheckEqual(gethiddenproperty(Fire, "size_xml"), Size, "size_xml")
		end,
	},

	setscriptable = {
		Test = function()
			local SetScriptable = setscriptable
			local Fire = Instance.new("Fire")
			local function CanRead()
				return pcall(function()
					return (Fire :: any).size_xml
				end)
			end
			local ReadBefore = CanRead()
			SetScriptable(Fire, "size_xml", true)
			local ReadWhileOn = CanRead()
			SetScriptable(Fire, "size_xml", false)
			assert(not ReadBefore, "size_xml could be read before it was made scriptable")
			assert(ReadWhileOn, "size_xml couldn't be read after it was made scriptable")
			assert(not CanRead(), "size_xml could still be read after it was made unscriptable")
		end,
	},

	getthreadidentity = {
		Test = function()
			local GetThreadIdentity = getthreadidentity
			local SetThreadIdentity = Formatters.CheckExist("setthreadidentity")
			local Original = GetThreadIdentity()
			coroutine.resume(coroutine.create(function()
				SetThreadIdentity(3)
			end))
			Formatters.CheckEqual(GetThreadIdentity(), Original, "this thread's identity after another thread changed its own")
			local PrintedIdentity
			local Connection = game:GetService("LogService").MessageOut:Connect(function(Message)
				PrintedIdentity = PrintedIdentity or tonumber(Message:match("Current identity is (%d+)"))
			end)
			AddCleanup(function()
				Connection:Disconnect()
			end)
			SetThreadIdentity(2)
			local Result = GetThreadIdentity()
			printidentity()
			SetThreadIdentity(Original)
			WaitFor(function()
				return PrintedIdentity ~= nil
			end, 1)
			Connection:Disconnect()
			Formatters.CheckEqual(Result, 2, "the identity")
			if PrintedIdentity == nil then
				return
			end
			Formatters.CheckEqual(Result, PrintedIdentity, "the identity Roblox's printidentity() shows")
		end,
	},

	setthreadidentity = {
		Test = function()
			local SetThreadIdentity = setthreadidentity
			local Original = Formatters.CheckExist("getthreadidentity")()
			local CoreGui = game:GetService("CoreGui")
			local function CanReadCoreGui()
				return pcall(function()
					return CoreGui:GetChildren()
				end)
			end
			SetThreadIdentity(2)
			local ReadAtTwo = CanReadCoreGui()
			SetThreadIdentity(8)
			local ReadAtEight = CanReadCoreGui()
			local Inherited
			local AfterYield
			task.spawn(function()
				SetThreadIdentity(2)
				task.spawn(function()
					Inherited = Formatters.CheckExist("getthreadidentity")()
				end)
				task.wait()
				AfterYield = Formatters.CheckExist("getthreadidentity")()
			end)
			local MainIdentity = Formatters.CheckExist("getthreadidentity")()
			WaitFor(function()
				return AfterYield ~= nil
			end, 2)
			SetThreadIdentity(Original)
			local function CanUseRobloxScript()
				return pcall(function()
					return game:GetService("CorePackages").Name
				end)
			end
			local function CanUseRobloxSecurity()
				return pcall(function()
					return Instance.new("SurfaceAppearance").TexturePack
				end)
			end
			local Capabilities
			task.spawn(function()
				SetThreadIdentity(2)
				local RobloxScriptAtTwo, RobloxSecurityAtTwo = CanUseRobloxScript(), CanUseRobloxSecurity()
				SetThreadIdentity(8)
				Capabilities = {RobloxScriptAtTwo, RobloxSecurityAtTwo, CanUseRobloxScript(), CanUseRobloxSecurity()}
			end)
			WaitFor(function()
				return Capabilities ~= nil
			end, 2)
			local StringIdentity
			local GetThreadIdentity = Formatters.CheckExist("getthreadidentity")
			task.spawn(function()
				local Success = pcall(SetThreadIdentity, "AURAUNC")
				StringIdentity = {Success, GetThreadIdentity()}
			end)
			WaitFor(function()
				return StringIdentity ~= nil
			end, 2)
			assert(not ReadAtTwo, "CoreGui could still be read at identity 2")
			assert(ReadAtEight, "CoreGui couldn't be read at identity 8")
			assert(Capabilities, "a thread that changed its identity never finished")
			assert(not Capabilities[1] and not Capabilities[2], "a thread at identity 2 could still use RobloxScript or RobloxSecurity members, so the identity only changed in name")
			assert(Capabilities[3] and Capabilities[4], "a thread at identity 8 couldn't use RobloxScript or RobloxSecurity members")
			assert(StringIdentity, "a thread that tried setting a string identity never finished")
			assert(not StringIdentity[1], "should error when given something that isn't a number")
			Formatters.CheckEqual(StringIdentity[2], Original, "the identity after trying to set it to a string")
			Formatters.CheckEqual(MainIdentity, 8, "this thread's identity after another thread changed its own")
			Formatters.CheckEqual(Inherited, 2, "the identity of a thread started from an identity 2 thread")
			Formatters.CheckEqual(AfterYield, 2, "the identity after a yield")
		end,
	},

	restorefunction = {
		Test = function()
			local HookFunction = Formatters.CheckExist("hookfunction")
			local GetInfo = Formatters.CheckExist("debug.info")
			local NewCClosure = newcclosure
			local Frexp = math.frexp
			local FrexpError = select(2, pcall(Frexp, "AURAUNC"))
			AddCleanup(function()
				pcall(restorefunction, Frexp)
			end)
			local Targets = {
				{Name = "a LuaClosure", Expected = "AURAUNC Original", Create = function()
					return function()
						return "AURAUNC Original"
					end
				end},
				{Name = "a C function", Expected = 0.5, Create = function()
					return Frexp
				end},
			}
			local Hooks = {
				{Name = "a LuaClosure", Expected = "AURAUNC Hooked", Hook = function()
					return "AURAUNC Hooked"
				end},
				{Name = "a C function", Expected = 1, Hook = math.sign},
			}
			if NewCClosure then
				table.insert(Targets, {Name = "a NewCClosure", Expected = "AURAUNC Original", Create = function()
					return NewCClosure(function()
						return "AURAUNC Original"
					end)
				end})
				table.insert(Hooks, {Name = "a NewCClosure", Expected = "AURAUNC Hooked", Hook = NewCClosure(function()
					return "AURAUNC Hooked"
				end)})
			end
			for _, Target in Targets do
				for _, Hook in Hooks do
					local Function = Target.Create()
					local Source = GetInfo(Function, "s")
					local Pair = `{Target.Name} hooked with {Hook.Name}`
					HookFunction(Function, Hook.Hook)
					local HookedResult = Function(8)
					restorefunction(Function)
					assert(HookedResult == Hook.Expected, `hookfunction didn't hook {Pair}, can't check restoring it`)
					Formatters.CheckEqual(Function(8), Target.Expected, `the result of {Pair} after restoring it`)
					Formatters.CheckEqual(GetInfo(Function, "s"), Source, `the source of {Pair} after restoring it`)
				end
			end
			Formatters.CheckEqual(select(2, pcall(Frexp, "AURAUNC")), FrexpError, "math.frexp's error after hooking and restoring it")
			local function Again()
				return "AURAUNC Original"
			end
			for Round = 1, 2 do
				HookFunction(Again, function()
					return "AURAUNC Hooked"
				end)
				local Hooked = Again() == "AURAUNC Hooked"
				restorefunction(Again)
				assert(Hooked, `hooking a restored function again didn't work on round {Round}`)
			end
			assert(Again() == "AURAUNC Original", "hooking and restoring the same function twice didn't bring back the original")
			local function First()
				return "AURAUNC First"
			end
			local function Second()
				return "AURAUNC Second"
			end
			for _, Function in {First, Second} do
				HookFunction(Function, function()
					return "AURAUNC Hooked"
				end)
			end
			restorefunction(First)
			local SecondStillHooked = Second() == "AURAUNC Hooked"
			restorefunction(Second)
			Formatters.CheckEqual(First(), "AURAUNC First", "the restored function's result")
			assert(SecondStillHooked, "restoring one function also restored a different one")
			local function Stacked()
				return "AURAUNC Original"
			end
			for Layer = 1, 2 do
				Formatters.CheckExist("hookfunction")(Stacked, function()
					return `AURAUNC Hook {Layer}`
				end)
			end
			restorefunction(Stacked)
			assert(Stacked() == "AURAUNC Original", "restoring a function that was hooked twice didn't bring back the original")
			local function OriginalIndex()
				return "AURAUNC Original"
			end
			local Proxy = newproxy(true)
			getmetatable(Proxy).__index = OriginalIndex
			Formatters.CheckExist("hookmetamethod")(Proxy, "__index", function()
				return "AURAUNC Hooked"
			end)
			assert(Proxy.AURAUNC == "AURAUNC Hooked", "hookmetamethod didn't hook __index, can't check restoring it")
			restorefunction(OriginalIndex)
			Formatters.CheckEqual(Proxy.AURAUNC, "AURAUNC Original", "a hooked __index after restoring its original function")
			assert(not pcall(restorefunction, 1), "restoring something that isn't a function should error")
		end,
	},

	filtergc = {
		Test = function()
			local FilterGc = filtergc
			local Key = `AURAUNC {math.random()}`
			local Table = {[Key] = true}
			local function TestFunction()
				return Key
			end
			local PairKey = `AURAUNC pair {math.random()}`
			local PairValue = `AURAUNC value {math.random()}`
			local Metatable = {}
			local Marked = setmetatable({[PairKey] = PairValue}, Metatable)
			assert(FilterGc("table", {Keys = {Key}}, true) == Table, "didn't find the table by its key")
			assert(table.find(FilterGc("table", {Values = {PairValue}}), Marked), "didn't find the table by its value")
			assert(table.find(FilterGc("table", {KeyValuePairs = {[PairKey] = PairValue}}), Marked), "didn't find the table by its key and value pair")
			assert(table.find(FilterGc("table", {Metatable = Metatable}), Marked), "didn't find the table by its metatable")
			Formatters.CheckEqual(#FilterGc("table", {Keys = {Key}}), 1, "the number of tables with that key")
			assert(table.find(FilterGc("function", {Name = "TestFunction", IgnoreExecutor = false}), TestFunction), "didn't find the function by its name")
		end,
	},

	getmenv = {
		Test = function()
			local CameraWrapper = GetPlayerModule().CommonUtils.CameraWrapper
			local GetCamera = require(CameraWrapper).getCamera
			local Environment = getmenv(CameraWrapper)
			Formatters.CheckReturnType(Environment, "table")
			assert(Environment.script == CameraWrapper, ".script doesn't point to the module")
			assert(Environment == getfenv(GetCamera), "didn't return the environment that the module's functions use")
		end,
	},

	makewriteable = {
		Test = function()
			local Table = table.freeze({})
			makewriteable(Table)
			assert(not table.isfrozen(Table), "the table is still frozen")
			assert(pcall(function()
				Table.AURAUNC = true
			end), "couldn't write to the table")
		end,
	},

	["debug.getstack"] = {
		Test = function()
			local function Test()
				local Secret = math.random(1, 1e6) + 0.5
				return table.find(debug.getstack(1), Secret), Secret
			end
			assert(Test(), "couldn't find a local in the stack")
		end,
	},

	["debug.setstack"] = {
		Test = function()
			local function Test()
				local Secret = math.random(1, 1e6) + 0.5
				local Expected = Secret + 1
				local Index = table.find(Formatters.CheckExist("debug.getstack")(1), Secret)
				assert(Index, "couldn't find the local in the stack")
				debug.setstack(1, Index, Expected)
				return Secret, Expected
			end
			local Result, Expected = Test()
			assert(Result == Expected, `the local should've changed to {Expected}, got {Result}`)
		end,
	},

	["debug.getupvalues"] = {
		Test = function()
			local First, Second = {}, {}
			local function Test()
				error("AURAUNC")
				return First, Second
			end
			local Upvalues = debug.getupvalues(Test)
			assert(table.find(Upvalues, First) and table.find(Upvalues, Second), "didn't find both upvalues")
		end,
	},

	["debug.getupvalue"] = {
		Test = function()
			local First, Second = {}, {}
			local function Test()
				error("AURAUNC")
				return First, Second
			end
			local GetUpvalue = debug.getupvalue
			assert(GetUpvalue(Test, 1) == First, "didn't return the first upvalue")
			assert(GetUpvalue(Test, 2) == Second, "didn't return the second upvalue")
		end,
	},

	["debug.setupvalue"] = {
		Test = function()
			local Upvalue = {}
			local function Test()
				return Upvalue
			end
			local function Other()
				Upvalue = Upvalue
				return Upvalue
			end
			debug.setupvalue(Test, 1, "AURAUNC")
			assert(Test() == "AURAUNC", "the upvalue wasn't changed")
			assert(Other() == "AURAUNC", "another function using the same upvalue didn't see the change")
		end,
	},

	["debug.getconstants"] = {
		Test = function()
			local Constant = `AURAUNC{math.random(1, 1e6)}`
			local Test = loadstring(`print("{Constant}")`) :: Function
			Formatters.CheckReturnType(debug.getconstants(Test), "table")
			assert(FindConstant(Test, Constant), "didn't find the string constant")
		end,
	},

	["debug.getconstant"] = {
		Test = function()
			local Constant = `AURAUNC{math.random(1, 1e6)}`
			local Test = loadstring(`print("{Constant}")`) :: Function
			Formatters.CheckEqual(debug.getconstant(Test, FindConstant(Test, Constant)), Constant, "the string constant")
		end,
	},

	["debug.setconstant"] = {
		Test = function()
			local Test = loadstring("local Value = ... return `AURAUNC Before {Value}`") :: Function
			local Other = loadstring("local Value = ... return 'AURAUNC Before' .. Value") :: Function
			debug.setconstant(Other, FindConstant(Other, "AURAUNC Before"), "AURAUNC After")
			assert(Test("x") == "AURAUNC Before x", "changing a constant affected a different function")
			Formatters.CheckEqual(Other("x"), "AURAUNC Afterx", "the function's result with the changed constant")
		end,
	},

	["debug.getregistry"] = {
		Test = function()
			local Values = debug.getregistry()
			Formatters.CheckReturnType(Values, "table")
			local HasThread = false
			for _, Value in Values do
				if typeof(Value) ~= "thread" then
					continue
				end
				HasThread = true
				break
			end
			assert(HasThread, "the registry should hold at least one thread")
		end,
	},

	["crypt.hash"] = {
		Test = function()
			local Hash = crypt.hash
			local GeneratedString = CreateRandomString(math.random(1, 64))
			local RandomHash = Hash(GeneratedString, "sha256")
			assert(Hash("abc", "sha256"):lower() == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", `the sha256 hash of 'abc' was wrong, got {Hash("abc", "sha256")}`)
			assert(RandomHash:match("^%x+$") and #RandomHash == 64, `a sha256 hash should be 64 hex characters, got '{RandomHash}'`)
			assert(Hash(GeneratedString, "sha256") == RandomHash, "hashing the same random string twice gave different results")
			assert(Hash(`{GeneratedString}x`, "sha256") ~= RandomHash, "two different strings gave the same hash")
			for Algorithm, Expected in {
				md5 = "900150983cd24fb0d6963f7d28e17f72",
				sha1 = "a9993e364706816aba3e25717850c26c9cd0d89d",
				sha384 = "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7",
				sha512 = "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f",
			} do
				local Success, Result = pcall(Hash, "abc", Algorithm)
				assert(Success and typeof(Result) == "string" and Result:lower() == Expected, `the {Algorithm} hash of 'abc' was wrong, got {Result}`)
			end
			Formatters.CheckEqual(Hash("", "sha256"):lower(), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "the sha256 hash of an empty string")
			local MadeUpSuccess, MadeUpResult = pcall(Hash, "abc", "AURAUNC")
			assert(not MadeUpSuccess or MadeUpResult == nil, `hashing with an algorithm that doesn't exist gave '{MadeUpResult}' instead of erroring`)
			local Expected = EncodingService:ComputeBufferHash(buffer.fromstring(GeneratedString), Enum.HashAlgorithm.Sha256)
			Formatters.CheckEqual(RandomHash:lower(), buffer.tostring(Expected):gsub(".", function(Character)
				return string.format("%02x", Character:byte())
			end), "the sha256 hash of a random string")
		end,
	},

	["crypt.generatekey"] = {
		Test = function()
			local Key = crypt.generatekey()
			assert(#Formatters.CheckExist("base64decode")(Key) == 32, "the decoded key should be 32 bytes")
			assert(Key ~= crypt.generatekey(), "generated the same key twice")
		end,
	},

	["crypt.generatebytes"] = {
		Test = function()
			local Length = math.random(8, 64)
			assert(#Formatters.CheckExist("base64decode")(crypt.generatebytes(Length)) == Length, `the decoded bytes should be {Length} long`)
		end,
	},

	["crypt.encrypt"] = {
		Test = function()
			local Crypt = crypt
			local Key = Crypt.generatekey()
			local Text = `AURAUNC {math.random()}`
			local Encrypted, InitializationVector = Crypt.encrypt(Text, Key)
			assert(not Encrypted:find(Text, 1, true), "the encrypted text still has the original text in it")
			assert(Crypt.decrypt(Encrypted, Key, InitializationVector) == Text, "decrypting didn't give back the original text")
			assert(Crypt.encrypt(Text, Key) ~= Encrypted, "encrypting the same text twice gave the same result, so it isn't using a new iv each time")
			CheckWrongKey(Crypt, Encrypted, InitializationVector, Text)
			local Plain = buffer.tostring(EncodingService:Base64Decode(buffer.fromstring("a8G+4i5An5bpPX4Rc5MXKg==")))
			local Success, Result = pcall(Crypt.encrypt, Plain, "YD3rEBXKcb4rc67whX13gR81LAc7YQjXLZgQowkU3/Q=", "8PHy8/T19vf4+fr7/P3+/w==", "CTR")
			assert(Success, `encrypting in CTR mode errored with {Result}`)
			Formatters.CheckEqual(Result, "YB7DE3dXiaW3p/UEu/PSKA==", "the published AES-256 CTR test vector")
		end,
	},

	["Drawing.new"] = {
		Test = function()
			local Line = Drawing.new("Line")
			AddCleanup(function()
				Line:Remove()
			end)
			assert(not pcall(Drawing.new, "AURAUNC"), "should error on a type that doesn't exist")
			assert(not pcall(function()
				Line.Thickness = "AURAUNC"
			end), "should error when Thickness is set to a string")
			local Thickness = Line.Thickness
			local Visible = Line.Visible
			local Existed = Line.__OBJECT_EXISTS
			local Text = Drawing.new("Text")
			AddCleanup(function()
				Text:Remove()
			end)
			Text.Font = 3
			local AppliedFont = Text.Font
			Line:Remove()
			Text:Remove()
			Formatters.CheckEqual(AppliedFont, 3, "a Text object's Font after setting it to 3")
			for _, Type in {"Line", "Text", "Image", "Circle", "Square", "Quad", "Triangle"} do
				local Object = Drawing.new(Type)
				local StartedVisible = Object.Visible
				Object:Remove()
				Formatters.CheckEqual(StartedVisible, false, `a new {Type}'s Visible`)
			end
			local Decimal = Drawing.new("Line")
			Decimal.Thickness = 2.5
			Decimal.Transparency = 0.25
			local KeptThickness = Decimal.Thickness
			local KeptTransparency = Decimal.Transparency
			Decimal:Remove()
			Formatters.CheckEqual(KeptThickness, 2.5, "Thickness after setting it to 2.5")
			Formatters.CheckEqual(KeptTransparency, 0.25, "Transparency after setting it to 0.25")
			assert(typeof(Thickness) == "number", "Thickness should be a number")
			assert(typeof(Visible) == "boolean", "Visible should be a boolean")
			assert(Existed == true, "__OBJECT_EXISTS should be true before :Remove()")
			assert(Line.__OBJECT_EXISTS == false, "__OBJECT_EXISTS should be false after :Remove()")
		end,
	},

	isrenderobj = {
		Test = function()
			local IsRenderObject = isrenderobj
			local Line = Formatters.CheckExist("Drawing.new")("Line")
			AddCleanup(function()
				Line:Remove()
			end)
			local Result = IsRenderObject(Line)
			Line:Remove()
			assert(Result == true, "should return true for a drawing object")
			assert(IsRenderObject({}) == false, "should return false for a table")
			assert(IsRenderObject(Instance.new("Part")) == false, "should return false for an Instance")
			assert(IsRenderObject(5) == false, "should return false for a number")
		end,
	},

	getrenderproperty = {
		Test = function()
			local Line = Formatters.CheckExist("Drawing.new")("Line")
			AddCleanup(function()
				Line:Remove()
			end)
			local Thickness = math.random(2, 9)
			Line.Thickness = Thickness
			local Result = getrenderproperty(Line, "Thickness")
			Line:Remove()
			Formatters.CheckEqual(Result, Thickness, "Thickness")
		end,
	},

	setrenderproperty = {
		Test = function()
			local Line = Formatters.CheckExist("Drawing.new")("Line")
			AddCleanup(function()
				Line:Remove()
			end)
			local Thickness = math.random(2, 9)
			setrenderproperty(Line, "Thickness", Thickness)
			local Result = Line.Thickness
			Line:Remove()
			Formatters.CheckEqual(Result, Thickness, "Thickness")
		end,
	},

	cleardrawcache = {
		Test = function()
			local Line = Formatters.CheckExist("Drawing.new")("Line")
			AddCleanup(function()
				Line:Remove()
			end)
			cleardrawcache()
			assert(Line.__OBJECT_EXISTS == false, "the drawing object still exists")
		end,
	},

	runonthread = {
		Test = function()
			local Thread = task.spawn(function()
				task.wait(2)
			end)
			local Value = math.random()
			runonthread(Thread, `shared.AURAUNCThreadValue = {Value}`)
			local Ran = WaitFor(function()
				return shared.AURAUNCThreadValue == Value
			end, 1)
			shared.AURAUNCThreadValue = nil
			task.cancel(Thread)
			assert(Ran, "the code didn't run on the thread")
			local Coroutine = coroutine.create(function()
				coroutine.yield()
			end)
			coroutine.resume(Coroutine)
			local CoroutineValue = math.random()
			runonthread(Coroutine, `shared.AURAUNCThreadValue = {CoroutineValue}`)
			local CoroutineRan = WaitFor(function()
				return shared.AURAUNCThreadValue == CoroutineValue
			end, 1)
			shared.AURAUNCThreadValue = nil
			assert(CoroutineRan, "the code didn't run on a thread made with coroutine.create")
		end,
	},

	runonactor = {
		Test = function()
			local Value = math.random()
			local Attributes = RunOnNewActor(`Actor:SetAttribute("Value", {Value}) Actor:SetAttribute("HasExecutor", typeof(getgenv) == "function" and typeof(hookfunction) == "function") Actor:SetAttribute("IsExecutor", checkcaller and checkcaller() == true)`)
			assert(Attributes.Value == Value, "the code didn't run on the actor")
			assert(Attributes.HasExecutor, "executor functions like getgenv and hookfunction aren't there inside the actor")
			assert(Attributes.IsExecutor, "checkcaller didn't return true for executor code running on the actor")
		end,
	},

	getactors = {
		Test = function()
			local RunOnActor = Formatters.CheckExist("runonactor")
			local GetActorFromThread = getactorfromthread
			local Actor = Instance.new("Actor")
			Actor.Parent = workspace
			AddCleanup(function()
				Actor:Destroy()
			end)
			local CountBefore = #getactors()
			RunOnActor(Actor, "")
			local Actors
			local function FindNewActor(): boolean
				for _, Value in Actors do
					if Value == Actor or (typeof(Value) == "thread" and GetActorFromThread and GetActorFromThread(Value) == Actor) then
						return true
					end
				end
				return typeof(Actors[1]) == "thread" and #Actors > CountBefore
			end
			local Found = WaitFor(function()
				Actors = getactors()
				return FindNewActor()
			end, 2)
			Actor:Destroy()
			for _, Value in Actors do
				assert(typeof(Value) == "thread" or (typeof(Value) == "Instance" and Value:IsA("Actor")), `should return Actors or actor threads, but got {if typeof(Value) == "Instance" then Value.ClassName else typeof(Value)}`)
			end
			assert(Found, "didn't find the new actor")
		end,
	},

	getactorthreads = {
		Test = function()
			RunOnNewActor("")
			local Threads = getactorthreads()
			Formatters.CheckReturnType(Threads, "table")
			assert(#Threads > 0, "expected at least one actor thread")
			assert(not table.find(Threads, coroutine.running()), "the thread running this test isn't on an actor")
			for _, Thread in Threads do
				assert(typeof(Thread) == "thread", `expected threads, got {typeof(Thread)}`)
			end
		end,
	},

	isparallel = {
		Test = function()
			assert(isparallel() == false, "should return false outside of an actor")
			assert(RunOnNewActor("Actor:SetAttribute('Parallel', isparallel())").Parallel == false, "should return false in an actor before it desynchronizes")
			assert(RunOnNewActor("task.desynchronize() local Result = isparallel() task.synchronize() Actor:SetAttribute('Parallel', Result)").Parallel == true, "should return true in a desynchronized actor")
		end,
	},

	getgc = {
		Test = function()
			local Holder = {Table = {}, Function = function() end}
			local GarbageCollected = getgc(true)
			Formatters.CheckReturnType(GarbageCollected, "table")
			assert(table.find(GarbageCollected, Holder.Function), "didn't find a new function")
			assert(table.find(GarbageCollected, Holder.Table), "didn't find a new table when including tables")
			local WithoutTables = getgc(false)
			local Seen = {}
			for _, Value in WithoutTables do
				assert(type(Value) ~= "table", "returned a table even though tables weren't asked for")
				assert(not Seen[Value], "returned the same value twice")
				Seen[Value] = true
			end
			local Fired = {}
			local Proxy = newproxy(true)
			local Metatable = getmetatable(Proxy)
			for _, Metamethod in {"__index", "__newindex", "__tostring", "__len", "__unm", "__add", "__eq", "__lt", "__le", "__concat", "__call"} do
				Metatable[Metamethod] = function()
					table.insert(Fired, Metamethod)
				end
			end
			getgc(true)
			getgc(false)
			assert(#Fired == 0, `ran {table.concat(Fired, ", ")} on a userdata it collected, so game scripts can detect it with a trapped newproxy`)
			local Weak = setmetatable({}, {__mode = "v"})
			Weak[1] = {}
			local Held = getgc(true)
			WaitFor(function()
				for _ = 1, 2000 do
					table.create(64, 0)
				end
				return Weak[1] == nil
			end, 6)
			local HeldMetatable = getrawmetatable and getrawmetatable(Held)
			assert(Weak[1] == nil, `kept garbage alive while its result was held, so game scripts can detect it with a weak table (__mode is {if HeldMetatable then tostring(HeldMetatable.__mode) else "not set"})`)
			local Counted, Info = collectgarbage("count"), gcinfo()
			assert(math.abs(Counted - Info) <= 64, `collectgarbage("count") said {Counted} but gcinfo() said {Info}, so one of them is being faked`)
		end,
	},

	getinstances = {
		Test = function()
			local Holder = {Part = Instance.new("Part")}
			assert(table.find(getinstances(), Holder.Part), "didn't find a new part")
		end,
	},

	getnilinstances = {
		Test = function()
			local Holder = {NilPart = Instance.new("Part")}
			local ParentedPart = Instance.new("Part")
			ParentedPart.Parent = workspace
			AddCleanup(function()
				ParentedPart:Destroy()
			end)
			local NilInstances = getnilinstances()
			ParentedPart:Destroy()
			assert(table.find(NilInstances, Holder.NilPart), "didn't find a part parented to nil")
			assert(not table.find(NilInstances, ParentedPart), "found a part that was parented to workspace")
		end,
	},

	getrunningscripts = {
		Test = function()
			local Disabled = GetPlayerScripts():FindFirstChildWhichIsA("LocalScript", true):Clone()
			Disabled.Disabled = true
			Disabled.Parent = Player:FindFirstChild("PlayerScripts") or Player.PlayerGui
			AddCleanup(function()
				Disabled:Destroy()
			end)
			local RunningScripts = getrunningscripts()
			local FoundDisabled = table.find(RunningScripts, Disabled)
			Disabled:Destroy()
			assert(not FoundDisabled, "found a disabled script")
			local FoundRunning = false
			for _, Descendant in GetPlayerScripts():GetDescendants() do
				if Descendant:IsA("LocalScript") and table.find(RunningScripts, Descendant) then
					FoundRunning = true
					break
				end
			end
			assert(FoundRunning, "didn't find a running LocalScript")
			local SeenScripts = {}
			for _, RunningScript in RunningScripts do
				assert(RunningScript:IsA("LuaSourceContainer"), `'{RunningScript}' isn't a script`)
				assert(not SeenScripts[RunningScript], `'{RunningScript}' is in the returned table more than once`)
				SeenScripts[RunningScript] = true
			end
		end,
	},

	isexecutorthread = {
		Test = function()
			local IsExecutorThread = isexecutorthread
			local Animate = Player.Character and Player.Character:FindFirstChild("Animate")
			local GameThread = Animate and Formatters.CheckExist("getscriptthread")(Animate)
			assert(IsExecutorThread(coroutine.running()) == true, "returned false for the thread running this test")
			assert(IsExecutorThread(task.spawn(function() end)) == true, "returned false for a thread this test started")
			assert(GameThread, "couldn't find the Animate script's thread to test with")
			assert(IsExecutorThread(GameThread) == false, "returned true for a game script's thread")
			assert(not pcall(IsExecutorThread, 1), "should error when given something that isn't a thread")
		end,
	},

	["Regex.new"] = {
		Test = function()
			local Pattern = Regex.new("d(e+)b")
			local Match = Pattern:Match("xdeeeb deb")
			assert(typeof(Match) == "table" and typeof(Match.Captures) == "table", if typeof(Match) == "table" then "Match returned a table without a Captures field" else `Match should return a table with Captures, got {typeof(Match)}`)
			Formatters.CheckEqual(Match.Captures[1], "deeeb", "the whole match")
			Formatters.CheckEqual(Match.Captures[2], "eee", "the first capture group")
			Formatters.CheckEqual(Pattern:Match("xyz"), nil, "Match on text with no match")
			Formatters.CheckEqual(Pattern:Replace("deb deeb", "Z"), "Z Z", "Replace on text with two matches")
		end,
	},

	["Regex.Escape"] = {
		Test = function()
			local Escaped = Regex.Escape("a.b*c")
			assert(Formatters.CheckExist("Regex.new")(Escaped):Match("a.b*c"), "the escaped pattern didn't match the text it was made from")
			assert(Formatters.CheckExist("Regex.new")(Escaped):Match("axb*c") == nil, `the escaped pattern '{Escaped}' still treats '.' as any character`)
		end,
	},

	getfflagtype = {
		Test = function()
			local GetFFlagType = getfflagtype
			Formatters.CheckEqual(GetFFlagType("DebugGraphicsPreferVulkan"), "bool", "the type of a true or false flag")
			Formatters.CheckEqual(GetFFlagType("TaskSchedulerTargetFps"), "int", "the type of a number flag")
		end,
	},

	getscriptbytecode = {
		Test = function()
			local GetScriptBytecode = getscriptbytecode
			local PlayerModule = GetPlayerModule()
			local Bytecode = GetScriptBytecode(PlayerModule)
			Formatters.CheckReturnType(Bytecode, "string")
			assert(#Bytecode > 0, "the bytecode is empty")
			assert(GetScriptBytecode(PlayerModule.CameraModule) ~= Bytecode, "'PlayerModule' and 'CameraModule' gave the same bytecode")
		end,
	},

	getscripthash = {
		Test = function()
			local GetScriptHash = getscripthash
			local LocalScript = GetPlayerScripts():FindFirstChildWhichIsA("LocalScript", true)
			local Hash = GetScriptHash(LocalScript)
			Formatters.CheckReturnType(Hash, "string")
			assert(#Hash > 0, "the hash is empty")
			assert(GetScriptHash(LocalScript) == Hash, "hashing the same script twice gave different results")
			assert(GetScriptHash(GetPlayerModule()) ~= Hash, "two different scripts gave the same hash")
			assert(#Hash == 96 and Hash:match("^%x+$"), `should be a 96 character sha384 hash, got {#Hash} characters`)
			local Crypt = crypt
			local GetScriptBytecode = getscriptbytecode
			if not Crypt or not GetScriptBytecode then
				return
			end
			local Supported, IsSha384 = pcall(function()
				return #Crypt.hash("abc", "sha384") == 96
			end)
			if not Supported or not IsSha384 then
				return
			end
			assert(Hash == Crypt.hash(GetScriptBytecode(LocalScript), "sha384"), "the hash isn't the sha384 of the script's bytecode")
		end,
	},

	getscriptclosure = {
		Test = function()
			local LocalScript = GetPlayerScripts():FindFirstChildWhichIsA("LocalScript", true)
			local Closure = getscriptclosure(LocalScript)
			Formatters.CheckReturnType(Closure, "function")
			assert(getfenv(Closure).script == LocalScript, "the closure's script doesn't match")
		end,
	},

	gethui = {
		Test = function()
			local HiddenGui = gethui()
			local ScreenGui = Instance.new("ScreenGui")
			ScreenGui.Parent = HiddenGui
			AddCleanup(function()
				ScreenGui:Destroy()
			end)
			local Parented = Formatters.CheckExist("compareinstances")(ScreenGui.Parent, HiddenGui)
			local InPlayerGui = ScreenGui:IsDescendantOf(Player.PlayerGui)
			ScreenGui:Destroy()
			assert(Parented, "couldn't parent a ScreenGui to it")
			assert(not InPlayerGui, "it's inside PlayerGui, where games can see it")
		end,
	},

	comparefunctions = {
		Test = function()
			local CompareFunctions = comparefunctions
			local function Test() end
			assert(CompareFunctions(Test, Test) == true, "a function should be equal to itself")
			assert(CompareFunctions(Test, print) == false, "two different functions shouldn't be equal")
		end,
	},

	getfunctionhash = {
		Test = function()
			local GetFunctionHash = getfunctionhash
			local function First()
				return 1
			end
			local function Second()
				return "AURAUNC"
			end
			local function SameAsFirst()
				return 1
			end
			local Hash = GetFunctionHash(First)
			Formatters.CheckReturnType(Hash, "string")
			assert(GetFunctionHash(First) == Hash, "hashing the same function twice gave different results")
			assert(GetFunctionHash(Second) ~= Hash, "two different functions gave the same hash")
			assert(GetFunctionHash(SameAsFirst) == Hash, "two functions with the same code gave different hashes, so it may not be hashing the function's code")
		end,
	},

	isexecutorclosure = {
		Test = function()
			local IsExecutorClosure = isexecutorclosure
			assert(IsExecutorClosure(function() end) == true, "should return true for a function made in the executor")
			assert(IsExecutorClosure(print) == false, "should return false for print")
			assert(IsExecutorClosure(IsExecutorClosure) == true, "should return true for itself")
			if newcclosure then
				assert(IsExecutorClosure(newcclosure(function() end)) == true, "should return true for a NewCClosure made in the executor")
			end
			assert(IsExecutorClosure(require(GetPlayerModule().CommonUtils.CameraWrapper).getCamera) == false, "should return false for a function from the game's PlayerModule")
		end,
	},

	islclosure = {
		Test = function()
			local IsLuaClosure = islclosure
			assert(IsLuaClosure(function() end) == true, "should return true for a Lua function")
			assert(IsLuaClosure(print) == false, "should return false for print")
			assert(IsLuaClosure(math.abs) == false, "should return false for math.abs")
		end,
	},

	isnewcclosure = {
		Test = function()
			local IsNewCClosure = isnewcclosure
			assert(IsNewCClosure(Formatters.CheckExist("newcclosure")(function() end)) == true, "should return true for a newcclosure")
			assert(IsNewCClosure(print) == false, "should return false for print")
			assert(IsNewCClosure(assert) == false, "should return false for assert")
			assert(IsNewCClosure(task.wait) == false, "should return false for task.wait")
			assert(IsNewCClosure(function() end) == false, "should return false for a Lua function")
		end,
	},

	getfflag = {
		Test = function()
			local Value = getfflag("MaxFrameBufferSize")
			Formatters.CheckReturnType(Value, "string")
			assert(Value ~= "", "the flag's value is empty")
			local Found, Missing = pcall(getfflag, `AURAUNC{math.random(1, 1e6)}`)
			assert(not Found or Missing == nil, "returned a value for a flag that doesn't exist")
		end,
	},

	setfflag = {
		Test = function()
			local GetFastFlag = Formatters.CheckExist("getfflag")
			local SetFastFlag = setfflag
			local Original = GetFastFlag("TaskSchedulerTargetFps")
			local NewValue = tostring(math.random(100, 200))
			AddCleanup(function()
				SetFastFlag("TaskSchedulerTargetFps", Original)
			end)
			SetFastFlag("TaskSchedulerTargetFps", NewValue)
			local Result = GetFastFlag("TaskSchedulerTargetFps")
			SetFastFlag("TaskSchedulerTargetFps", Original)
			Formatters.CheckEqual(Result, NewValue, "the flag")
		end,
	},

	["raknet.addsendhook"] = {
		Test = function()
			CheckPacketHook("send", false)
		end,
	},

	["raknet.removesendhook"] = {
		Test = function()
			CheckPacketHook("send", true)
		end,
	},

	["raknet.addreceivehook"] = {
		Test = function()
			CheckPacketHook("receive", false)
		end,
	},

	["raknet.removereceivehook"] = {
		Test = function()
			CheckPacketHook("receive", true)
		end,
	},

	["raknet.receive"] = {
		Test = function()
			local RakNet = raknet
			local Marker = `\255AURAUNC {math.random()}`
			local Received = false
			local HookFired = false
			local function OnReceive(Packet)
				HookFired = true
				if Packet.AsString ~= Marker then
					return
				end
				Received = true
				Packet:Block()
			end
			AddCleanup(function()
				RakNet.removereceivehook(OnReceive)
			end)
			RakNet.addreceivehook(OnReceive)
			RakNet.receive(Marker)
			WaitFor(function()
				return Received
			end, 3)
			RakNet.removereceivehook(OnReceive)
			if not HookFired then
				error({Skipped = "the receive hook never fired, so the packet can't be checked"})
			end
			assert(Received, "the receive hook didn't see the packet")
		end,
	},

	["raknet.send"] = {
		Test = function()
			local RakNet = raknet
			local Marker = `\255AURAUNC {math.random()}`
			RakNet.send(Marker)
			RakNet.send(buffer.fromstring(Marker))
			local Disconnected = RakNet.stats and WaitFor(function()
				return RakNet.stats().Connected == false
			end, 1)
			assert(not Disconnected, "got disconnected after sending a packet")
		end,
	},

	["debug.getcallstack"] = {
		Test = function()
			local GetCallStack = debug.getcallstack
			local function Inner()
				return GetCallStack()
			end
			local function Outer()
				local Stack = Inner()
				return Stack
			end
			local CallStack = Outer()
			Formatters.CheckReturnType(CallStack, "table")
			assert(CallStack[1].func == Inner and CallStack[2].func == Outer, "the running functions aren't in order")
			for _, Entry in CallStack do
				if Entry.func ~= Inner then
					continue
				end
				assert(typeof(Entry.currentline) == "number", "the stack entry for the calling function doesn't have a currentline number")
				return
			end
			error("couldn't find the calling function in the call stack")
		end,
	},

	["debug.isvalidlevel"] = {
		Test = function()
			local IsValidLevel = debug.isvalidlevel
			assert(IsValidLevel(1) == true, "level 1 should be valid")
			assert(IsValidLevel(500) == false, "level 500 shouldn't be valid")
			local Depth = 1
			while Formatters.CheckExist("debug.info")(Depth, "f") do
				Depth += 1
			end
			assert(IsValidLevel(Depth - 1) == true, `level {Depth - 1} exists and should be valid`)
			assert(IsValidLevel(Depth) == false, `level {Depth} is past the end of the stack and shouldn't be valid`)
		end,
	},

	["debug.setinfo"] = {
		Test = function()
			local function Test() end
			local Name = `AURAUNC{math.random(1, 1e6)}`
			debug.setinfo(Test, {name = Name})
			Formatters.CheckEqual(Formatters.CheckExist("debug.info")(Test, "n"), Name, "the function's name")
		end,
	},

	getallthreads = {
		Test = function()
			local Threads = getallthreads()
			assert(table.find(Threads, coroutine.running()), "didn't find the thread that's running this test")
			assert(#Threads > 1, "only found the thread that's running this test")
		end,
	},

	hasmetafield = {
		Test = function()
			local HasMetafield = hasmetafield
			assert(HasMetafield(setmetatable({}, {__index = {}}), "__index") == true, "should return true for a field the metatable has")
			assert(HasMetafield(setmetatable({}, {}), "__index") == false, "should return false for a field the metatable doesn't have")
			assert(HasMetafield(game, "__namecall") == true, "should see __namecall on game's locked metatable")
		end,
	},

	makereadonly = {
		Test = function()
			local Table = {}
			makereadonly(Table)
			assert(table.isfrozen(Table), "the table wasn't made read-only")
			assert(not pcall(function()
				Table.AURAUNC = true
			end), "could still write to the table after making it read-only")
		end,
	},

	iswriteable = {
		Test = function()
			local IsWriteable = iswriteable
			assert(IsWriteable({}) == true, "should return true for a normal table")
			assert(IsWriteable(table.freeze({})) == false, "should return false for a frozen table")
		end,
	},

	isreadonly = {
		Test = function()
			local IsReadOnly = isreadonly
			assert(IsReadOnly({}) == false, "should return false for a normal table")
			assert(IsReadOnly(table.freeze({})) == true, "should return true for a frozen table")
		end,
	},

	["crypt.hmac"] = {
		Test = function()
			local Hmac = crypt.hmac
			local GeneratedString = CreateRandomString(math.random(1, 64))
			Formatters.CheckEqual(Hmac("key", "The quick brown fox jumps over the lazy dog", "sha256"), "97yD9DBThCSxMpjmqm+xQ+9NWaFJRhdZl0edvC0aPNg=", "the known sha256 hmac")
			Formatters.CheckEqual(Hmac("Jefe", "what do ya want for nothing?", "sha256"), "W9zBRr9gdU5qBCQmCJV1x1oAPwidJzmDnexYuWTsOEM=", "the second known sha256 hmac")
			assert(Hmac("key", GeneratedString, "sha256") == Hmac("key", GeneratedString, "sha256"), "the same key and data gave different results")
			assert(Hmac("key", GeneratedString, "sha256") ~= Hmac("other key", GeneratedString, "sha256"), "two different keys gave the same result")
		end,
	},

	["crypt.random"] = {
		Test = function()
			local Random = crypt.random
			local Length = math.random(8, 64)
			local Bytes = Random(Length)
			Formatters.CheckEqual(#Bytes, Length, "the length of the random bytes")
			assert(Random(Length) ~= Bytes, "generated the same bytes twice")
			local Seen = {}
			for Byte in Random(64):gmatch(".") do
				Seen[Byte] = true
			end
			local Different = 0
			for _ in Seen do
				Different += 1
			end
			assert(Different > 8, `64 random bytes only had {Different} different values`)
		end,
	},

	["crypt.decrypt"] = {
		Test = function()
			local Crypt = crypt
			local Encrypt = Formatters.CheckExist("crypt.encrypt")
			local Key = Crypt.generatekey()
			for _ = 1, 50 do
				local Text = CreateRandomString(math.random(1, 64))
				local Encrypted, InitializationVector = Encrypt(Text, Key)
				local Decrypted = Crypt.decrypt(Encrypted, Key, InitializationVector)
				assert(Decrypted == Text, `decrypting {#Text} bytes of random text gave back {#Decrypted} bytes that don't match`)
			end
			local Text = CreateRandomString(math.random(1, 64))
			local Encrypted, InitializationVector = Encrypt(Text, Key)
			CheckWrongKey(Crypt, Encrypted, InitializationVector, Text)
		end,
	},

	getmodules = {
		Test = function()
			local Modules = getmodules()
			Formatters.CheckReturnType(Modules, "table")
			assert(table.find(Modules, GetPlayerModule()), "didn't find PlayerModule, which is always loaded")
			local NewModule = Instance.new("ModuleScript")
			NewModule.Parent = workspace
			AddCleanup(function()
				NewModule:Destroy()
			end)
			local FoundNew = table.find(getmodules(), NewModule)
			NewModule:Destroy()
			assert(FoundNew, "didn't find a new ModuleScript")
			for _, Module in Modules do
				assert(Module:IsA("ModuleScript"), `'{Module}' isn't a ModuleScript`)
			end
		end,
	},

	getrendersteppedlist = {
		Test = function()
			local RunService = game:GetService("RunService")
			local Name = `AURAUNC{math.random(1, 1e6)}`
			local function OnRenderStep() end
			AddCleanup(function()
				RunService:UnbindFromRenderStep(Name)
			end)
			RunService:BindToRenderStep(Name, 123, OnRenderStep)
			local List = getrendersteppedlist()
			RunService:UnbindFromRenderStep(Name)
			for _, Entry in List do
				if Entry.Name ~= Name then
					continue
				end
				assert(Entry.Function == OnRenderStep, ".Function isn't the function that was bound")
				Formatters.CheckEqual(Entry.Priority, 123, "the binding's priority")
				return
			end
			error("didn't find a newly bound RenderStep function")
		end,
	},

	cansignalreplicate = {
		Test = function()
			local CanSignalReplicate = cansignalreplicate
			assert(CanSignalReplicate(Player.Kill) == true, "should return true for Player.Kill")
			assert(CanSignalReplicate(workspace.ChildAdded) == false, "should return false for workspace.ChildAdded")
			assert(CanSignalReplicate(Instance.new("Part").Touched) == false, "should return false for a part's Touched")
		end,
	},

	getactorfromthread = {
		Test = function()
			assert(RunOnNewActor("Actor:SetAttribute('Matched', getactorfromthread(coroutine.running()) == Actor)").Matched == true, "didn't return the actor that the thread is running on")
			assert(getactorfromthread(coroutine.running()) == nil, "should return nil for a thread that isn't on an actor")
		end,
	},

	hooksignal = {
		Test = function()
			local NumberValue = Instance.new("NumberValue")
			local FiredCount = 0
			local HookArgument
			NumberValue.Changed:Connect(function()
				FiredCount += 1
			end)
			hooksignal(NumberValue.Changed, function(Info)
				HookArgument = Info
				return false
			end)
			NumberValue.Value = 1
			task.wait()
			assert(HookArgument ~= nil, "the hook wasn't called when the signal fired")
			assert(FiredCount == 0, "returning false from the hook didn't stop the connection from firing")
			local AllowedValue = Instance.new("NumberValue")
			local AllowedCount = 0
			AllowedValue.Changed:Connect(function()
				AllowedCount += 1
			end)
			hooksignal(AllowedValue.Changed, function()
				return true
			end)
			AllowedValue.Value = 1
			task.wait()
			assert(AllowedCount == 1, "returning true from the hook stopped the connection from firing")
		end,
	},

	issignalhooked = {
		Test = function()
			local IsSignalHooked = issignalhooked
			local NumberValue = Instance.new("NumberValue")
			NumberValue.Changed:Connect(function() end)
			assert(IsSignalHooked(NumberValue.Changed) == false, "should return false before the signal is hooked")
			Formatters.CheckExist("hooksignal")(NumberValue.Changed, function() end)
			assert(IsSignalHooked(NumberValue.Changed) == true, "should return true after the signal is hooked")
		end,
	},

	restoresignal = {
		Test = function()
			local NumberValue = Instance.new("NumberValue")
			local FiredCount = 0
			local HookCount = 0
			NumberValue.Changed:Connect(function()
				FiredCount += 1
			end)
			Formatters.CheckExist("hooksignal")(NumberValue.Changed, function()
				HookCount += 1
			end)
			NumberValue.Value = 1
			task.wait()
			assert(HookCount == 1, "hooksignal didn't hook the signal, can't continue the test")
			restoresignal(NumberValue.Changed)
			local FiredBefore = FiredCount
			NumberValue.Value = 2
			task.wait()
			assert(HookCount == 1, "the hook was still called after restoresignal")
			assert(FiredCount == FiredBefore + 1, "the connection didn't fire after restoresignal")
		end,
	},

	["oth.hook"] = {
		Test = CheckOffThreadHook,
	},

	["oth.unhook"] = {
		Test = CheckOffThreadHook,
	},

	["oth.is_hook_thread"] = {
		Test = CheckOffThreadHook,
	},

	["oth.get_root_callback"] = {
		Test = CheckOffThreadHook,
	},

	["oth.get_original_thread"] = {
		Test = CheckOffThreadHook,
	},

	keyclick = {
		Test = function()
			CheckInputFree()
			local Detected = WaitForInput(UserInputService.InputBegan, function(Input)
				return Input.KeyCode == Enum.KeyCode.J
			end, function()
				keyclick(0x4A)
			end)
			local Released = WaitFor(function()
				return not UserInputService:IsKeyDown(Enum.KeyCode.J)
			end, 1)
			if not Released then
				Formatters.CheckExist("keyrelease")(0x4A)
			end
			assert(Detected, "the key press wasn't detected")
			assert(Released, "the key was left held down, keyclick should press and release it")
		end,
		RunLast = true,
	},

	loadfileasync = {
		Test = function()
			local FileName = `File_{math.random()}.lua`
			local Value = math.random()
			Formatters.CheckExist("writefile")(FileName, `return {Value}`)
			local Loaded = CallAsync(loadfileasync, FileName)
			RemovePath("delfile", FileName)
			Formatters.CheckReturnType(Loaded, "function")
			Formatters.CheckEqual(Loaded(), Value, "the value the loaded file returned")
		end,
	},

	appendfileasync = {
		Test = function()
			local ReadFile = Formatters.CheckExist("readfile")
			local FileName = `File_{math.random()}.txt`
			local Appended = tostring(math.random())
			Formatters.CheckExist("writefile")(FileName, "AURAUNC")
			CallAsync(appendfileasync, FileName, Appended)
			local Found = WaitFor(function()
				return ReadFile(FileName) == `AURAUNC{Appended}`
			end, 2)
			RemovePath("delfile", FileName)
			assert(Found, "the text wasn't added to the end of the file within 2 seconds")
		end,
	},

	saveinstance = {
		Test = function()
			local PredictedMegabytes = #game:GetDescendants() * 10 / 1e6
			if PredictedMegabytes > 10 then
				error({Skipped = `the saved place would be about {math.floor(PredictedMegabytes)} MB, which is too large to test quickly`, Environment = true})
			end
			local ListFiles = listfiles
			local Before = {}
			for _, Path in if ListFiles then ListFiles("") else {} do
				Before[Path] = true
			end
			AddCleanup(function()
				for _, Path in if ListFiles then ListFiles("") else {} do
					if not Before[Path] and tostring(Path):lower():find("%.rbxlx?$") then
						RemovePath("delfile", Path)
					end
				end
			end)
			local FileName = saveinstance({noscripts = true})
			Formatters.CheckReturnType(FileName, "string")
			local Exists = Formatters.CheckExist("isfile")(FileName)
			local Size = Exists and #Formatters.CheckExist("readfile")(FileName)
			RemovePath("delfile", FileName)
			assert(Exists, `the saved file '{FileName}' doesn't exist`)
			assert(Size > 1000, `the saved file is only {Size} bytes, so it can't have the place in it`)
		end,
		RunLast = true,
	},

	getcustomasset = {
		Test = function()
			local FileName = `File_{math.random()}.png`
			Formatters.CheckExist("writefile")(FileName, TestImage)
			local Success, AssetId = pcall(getcustomasset, FileName)
			if not Success then
				RemovePath("delfile", FileName)
				error(`errored while getting the asset with {AssetId}`)
			end
			local FetchStatus = GetAssetStatus(AssetId)
			RemovePath("delfile", FileName)
			Formatters.CheckReturnType(AssetId, "string")
			assert(AssetId:find("^rbxasset://"), `expected an rbxasset:// id, got '{AssetId}'`)
			Formatters.CheckEqual(FetchStatus, Enum.AssetFetchStatus.Success, "the status of loading the asset")
			local GarbageName = `File_{math.random()}.png`
			Formatters.CheckExist("writefile")(GarbageName, "AURAUNC")
			local BadStatus = GetAssetStatus(getcustomasset(GarbageName))
			RemovePath("delfile", GarbageName)
			assert(BadStatus ~= Enum.AssetFetchStatus.Success, "a file that isn't an image loaded as one, so the file probably wasn't used")
		end,
	},

	getsignalarguments = {
		Test = function()
			local Arguments = getsignalarguments(Instance.new("Part").Touched)
			Formatters.CheckReturnType(Arguments, "table")
			Formatters.CheckEqual(#Arguments, 1, "the number of arguments Touched has")
			assert(Arguments[1] == "Instance" or Arguments[1] == "BasePart", `expected the type of Touched's argument to be Instance or BasePart, got {Arguments[1]}`)
			Formatters.CheckEqual(#getsignalarguments(UserInputService.InputBegan), 2, "the number of arguments InputBegan has")
		end,
	},

	getsignalargumentsinfo = {
		Test = function()
			local Info = getsignalargumentsinfo(Instance.new("Part").Touched)
			Formatters.CheckReturnType(Info, "table")
			assert(typeof(Info[1]) == "table", `expected a table for each argument, got {typeof(Info[1])}`)
			Formatters.CheckEqual(Info[1].Name, "otherPart", "the name of Touched's argument")
			assert(Info[1].Type == "Instance" or Info[1].Type == "BasePart", `expected the type of Touched's argument to be Instance or BasePart, got {Info[1].Type}`)
			local InputInfo = getsignalargumentsinfo(UserInputService.InputBegan)
			Formatters.CheckEqual(#InputInfo, 2, "the number of arguments InputBegan has")
			Formatters.CheckEqual(InputInfo[2].Name, "gameProcessedEvent", "the name of InputBegan's second argument")
		end,
	},

	getsignalwhitelist = {
		Test = function()
			local Whitelist = getsignalwhitelist()
			Formatters.CheckReturnType(Whitelist, "table")
			assert(#Whitelist > 1, "the whitelist should have more than one signal")
			for _, Entry in Whitelist do
				assert(typeof(Entry) == "table" and typeof(Entry.Event) == "string" and typeof(Entry.Parent) == "string", "each entry should be a table with an Event and a Parent string")
			end
		end,
	},

	createcommchannel = {
		Test = CheckCommChannel,
	},

	getcommchannel = {
		Test = CheckCommChannel,
	},

	["Drawing.Fonts"] = {
		Test = function()
			local Fonts = Drawing.Fonts
			for Name, Value in {UI = 0, System = 1, Plex = 2, Monospace = 3} do
				Formatters.CheckEqual(Fonts[Name], Value, `Drawing.Fonts.{Name}`)
			end
		end,
		ValueType = "table",
	},

	["Signal.new"] = {
		Test = function()
			local CreatedSignal = Signal.new()
			local Value = math.random()
			local Received
			local OnceCount = 0
			local Connection = CreatedSignal:Connect(function(...)
				Received = table.pack(...)
			end)
			CreatedSignal:Once(function()
				OnceCount += 1
			end)
			CreatedSignal:Fire(Value, "AURAUNC")
			Connection:Disconnect()
			local ReceivedAfterFire = Received
			Received = nil
			CreatedSignal:Fire(Value)
			task.delay(0.1, function()
				CreatedSignal:Fire(Value)
			end)
			assert(ReceivedAfterFire and ReceivedAfterFire[1] == Value and ReceivedAfterFire[2] == "AURAUNC", "the connection didn't get the values it was fired with")
			assert(Received == nil, "the connection still fired after :Disconnect()")
			Formatters.CheckEqual(OnceCount, 1, "the number of times a :Once connection fired")
			Formatters.CheckEqual(CreatedSignal:Wait(), Value, "the value :Wait() returned")
		end,
	},

	setnamecallmethod = {
		Test = function()
			local ProxyTest = newproxy(true)
			local NewMethod = `AURAUNC{math.random(1, 1e6)}`
			local Detected
			local FullName
			getmetatable(ProxyTest).__namecall = function()
				setnamecallmethod(NewMethod)
				Detected = Formatters.CheckExist("getnamecallmethod")()
				setnamecallmethod("GetFullName")
				FullName = Formatters.CheckExist("getrawmetatable")(game).__namecall(game)
			end
			ProxyTest:Original()
			Formatters.CheckEqual(Detected, NewMethod, "the namecall method after setting it")
			Formatters.CheckEqual(FullName, game:GetFullName(), "the result of calling game's __namecall after setting the method")
		end,
	},

	newlclosure = {
		Test = function()
			local NewLClosure = newlclosure
			local Wrapped = NewLClosure(math.abs)
			assert(Wrapped ~= math.abs, "the returned function is the same as the function given")
			assert(Formatters.CheckExist("islclosure")(Wrapped), "the returned function isn't a Lua closure")
			Formatters.CheckEqual(Wrapped(-5), 5, "the wrapped math.abs(-5)")
		end,
	},

	getproperties = {
		Test = function()
			local Part = Instance.new("Part")
			local Size = Vector3.new(math.random(1, 9), math.random(1, 9), math.random(1, 9))
			Part.Size = Size
			local Properties = getproperties(Part)
			Formatters.CheckReturnType(Properties, "table")
			Formatters.CheckEqual(Properties.Size, Size, "the Size in the returned table")
			Formatters.CheckEqual(Properties.Name, "Part", "the Name in the returned table")
			Formatters.CheckEqual(getproperties(Instance.new("Fire")).Heat, 9, "a Fire's Heat in the returned table")
		end,
	},

	gethiddenproperties = {
		Test = function()
			local Part = Instance.new("Part")
			local Properties = gethiddenproperties(Part)
			Formatters.CheckReturnType(Properties, "table")
			assert(next(Properties) ~= nil, "the table of hidden properties is empty")
			assert(Properties.Size == nil, "Size isn't hidden, so it shouldn't be in the table")
			local FoundHidden = false
			for Name in Properties do
				if pcall(function()
					return (Part :: any)[Name]
				end) then
					continue
				end
				FoundHidden = true
				break
			end
			assert(FoundHidden, "none of the returned properties are actually hidden")
			local Fire = Instance.new("Fire")
			local Size = math.random(6, 20)
			Fire.Size = Size
			Formatters.CheckEqual(gethiddenproperties(Fire).size_xml, Size, "size_xml")
		end,
	},

	hasmetatable = {
		Test = function()
			local HasMetatable = hasmetatable
			assert(HasMetatable(setmetatable({}, {})) == true, "should return true for a table with a metatable")
			assert(HasMetatable({}) == false, "should return false for a table without a metatable")
			assert(HasMetatable(game) == true, "should return true for game, which has a locked metatable")
		end,
	},

	getmetafield = {
		Test = function()
			local GetMetafield = getmetafield
			local Value = math.random()
			Formatters.CheckEqual(GetMetafield(setmetatable({}, {__index = Value}), "__index"), Value, "the __index field")
			Formatters.CheckReturnType(GetMetafield(game, "__namecall"), "function")
		end,
	},

	iscorescript = {
		Test = function()
			local IsCoreScript = iscorescript
			local CoreScript = game:GetService("CoreGui"):FindFirstChildWhichIsA("ModuleScript", true)
			assert(IsCoreScript(GetPlayerModule()) == false, "should return false for PlayerModule, which isn't a core script")
			if not CoreScript then
				error({Skipped = "no core script was found to check", Environment = true})
			end
			assert(IsCoreScript(CoreScript) == true, `should return true for '{CoreScript:GetFullName()}', which is a core script`)
		end,
	},

	getscriptthread = {
		Test = CheckScriptThread,
	},

	getscriptfromthread = {
		Test = CheckScriptThread,
	},

	readfileasync = {
		Test = function()
			local FileName = `File_{math.random()}.txt`
			local Text = tostring(math.random())
			Formatters.CheckExist("writefile")(FileName, Text)
			local Result = CallAsync(readfileasync, FileName)
			RemovePath("delfile", FileName)
			Formatters.CheckEqual(Result, Text, "the text read from the file")
		end,
	},

	writefileasync = {
		Test = function()
			local ReadFile = Formatters.CheckExist("readfile")
			local FileName = `File_{math.random()}.txt`
			local Text = tostring(math.random())
			CallAsync(writefileasync, FileName, Text)
			local Written = WaitFor(function()
				return pcall(ReadFile, FileName) and ReadFile(FileName) == Text
			end, 2)
			RemovePath("delfile", FileName)
			assert(Written, "the text wasn't written to the file within 2 seconds")
		end,
	},

	writecustomasset = {
		Test = function()
			local FileName = `File_{math.random()}.png`
			local AssetId = writecustomasset(FileName, TestImage)
			local Exists = Formatters.CheckExist("isfile")(FileName)
			local FetchStatus = GetAssetStatus(AssetId)
			RemovePath("delfile", FileName)
			assert(Exists, "the file wasn't written")
			assert(typeof(AssetId) == "string" and AssetId:find("^rbxasset://"), `expected an rbxasset:// id, got '{AssetId}'`)
			Formatters.CheckEqual(FetchStatus, Enum.AssetFetchStatus.Success, "the status of loading the asset")
		end,
	},

	dofile = {
		Test = function()
			local WriteFile = Formatters.CheckExist("writefile")
			local DoFile = dofile
			local FileName = `File_{math.random()}.lua`
			local Value = math.random()
			local Marker = `AURAUNC{math.random(1, 1e6)}`
			WriteFile(FileName, `return {Value}`)
			local Success, Result = pcall(DoFile, FileName)
			WriteFile(FileName, `error("{Marker}")`)
			local Ran, ErrorMessage = pcall(DoFile, FileName)
			RemovePath("delfile", FileName)
			assert(Success, `errored while running the file with {Result}`)
			Formatters.CheckEqual(Result, Value, "the value the file returned")
			assert(not Ran, "an error inside of the file didn't reach the caller")
			assert(tostring(ErrorMessage):find(Marker, 1, true), `the file's error message was lost, got '{ErrorMessage}'`)
		end,
	},

	getobjects = {
		Test = function()
			local Objects = getobjects("rbxassetid://125013769")
			Formatters.CheckReturnType(Objects, "table")
			local Sword = Objects[1]
			assert(typeof(Sword) == "Instance", `expected an instance, got {typeof(Sword)}`)
			local ClassName, Name, Parent, HasHandle = Sword.ClassName, Sword.Name, Sword.Parent, Sword:FindFirstChild("Handle") ~= nil
			Sword:Destroy()
			Formatters.CheckEqual(ClassName, "Tool", "the loaded model's class")
			Formatters.CheckEqual(Name, "LinkedSword", "the loaded model's name")
			assert(Parent == nil, "the loaded model shouldn't be parented to anything")
			assert(HasHandle, "the loaded model doesn't have the sword's Handle")
		end,
	},

	hookproto = {
		Test = CheckProtoHook,
	},

	isprotohooked = {
		Test = CheckProtoHook,
	},

	restoreproto = {
		Test = CheckProtoHook,
	},

	getcallbackvalue = {
		Test = function()
			local GetCallbackValue = getcallbackvalue
			local BindableFunction = Instance.new("BindableFunction")
			local function OnInvoke()
				return "AURAUNC"
			end
			assert(GetCallbackValue(BindableFunction, "OnInvoke") == nil, "should return nil when no callback is set")
			local Calls = 0
			BindableFunction.OnInvoke = function()
				Calls += 1
			end
			BindableFunction.OnInvoke = OnInvoke
			assert(GetCallbackValue(BindableFunction, "OnInvoke") == OnInvoke, "didn't return the callback that was set")
			Formatters.CheckEqual(Calls, 0, "the number of times reading a replaced callback called it")
			BindableFunction.OnInvoke = nil
			assert(GetCallbackValue(BindableFunction, "OnInvoke") == nil, "should return nil after the callback is cleared")
			local Wrapped = (newcclosure or function(Function)
				return Function
			end)(OnInvoke)
			BindableFunction.OnInvoke = Wrapped
			assert(GetCallbackValue(BindableFunction, "OnInvoke") == Wrapped, "didn't return a NewCClosure callback that was set")
			local RemoteFunction = Instance.new("RemoteFunction")
			RemoteFunction.OnClientInvoke = OnInvoke
			assert(GetCallbackValue(RemoteFunction, "OnClientInvoke") == OnInvoke, "didn't return a RemoteFunction's OnClientInvoke")
			local OnClose = function() end
			game.OnClose = OnClose
			local DataModelCallback = GetCallbackValue(game, "OnClose")
			game.OnClose = nil
			assert(DataModelCallback == OnClose, "didn't return game.OnClose, a callback on the DataModel")
			assert(not pcall(GetCallbackValue, BindableFunction, "Name"), "should error for a property that isn't a callback")
		end,
	},

	getfunctionbytecode = {
		Test = function()
			local GetFunctionBytecode = getfunctionbytecode
			local function First()
				return 1
			end
			local function Second()
				return "AURAUNC"
			end
			local Bytecode = GetFunctionBytecode(First)
			Formatters.CheckReturnType(Bytecode, "string")
			assert(#Bytecode > 0, "the bytecode is empty")
			assert(GetFunctionBytecode(Second) ~= Bytecode, "two different functions gave the same bytecode")
		end,
	},

	getobjectreferences = {
		Test = function()
			local Box = {Holder = {{}}}
			local References = getobjectreferences(Box.Holder[1])
			assert(table.find(References, Box.Holder), "didn't find the table holding the object")
		end,
	},

	getfunctionreferences = {
		Test = function()
			local Box = {Holder = {function() end}}
			assert(table.find(getfunctionreferences(Box.Holder[1]), Box.Holder), "didn't find the table holding the function")
		end,
	},

	trampolinecall = {
		OtherNames = {"trampoline_call", "syn.trampoline_call"},
		Test = function()
			local TrampolineCall = FindFirstFunction("trampolinecall") or FindFirstFunction("trampoline_call") or FindFirstFunction("syn.trampoline_call")
			local GetIdentity = getthreadidentity
			local GetScriptThread = getscriptthread
			local CheckCaller = checkcaller
			local GetCallingScript = getcallingscript
			local GetInfo = Formatters.CheckExist("debug.info")
			local Line = math.random(100, 999)
			local Value = math.random()
			local function FakeCaller() end
			local StackSuccess, Name, CurrentLine = TrampolineCall(function()
				return GetInfo(2, "nl")
			end, {
				{
					func = FakeCaller,
					currentline = Line,
				},
			}, {})
			assert(typeof(StackSuccess) == "boolean", `the first value it returns should be whether the call worked, got {typeof(StackSuccess)} instead, so it probably just called the function`)
			assert(StackSuccess == true, "should return true when the function doesn't error")
			Formatters.CheckEqual(Name, "FakeCaller", "the name of the fake caller")
			Formatters.CheckEqual(CurrentLine, Line, "the line of the fake caller")
			local ArgumentSuccess, Result = TrampolineCall(function(Argument)
				return Argument
			end, {}, {}, Value)
			assert(ArgumentSuccess == true and Result == Value, "the arguments or return values didn't get passed through")
			local ErrorSuccess, ErrorMessage = TrampolineCall(function()
				error("AURAUNC", 0)
			end, {}, {})
			assert(ErrorSuccess == false, "should return false when the function errors")
			Formatters.CheckEqual(ErrorMessage, "AURAUNC", "the error message")
			local EnvironmentSuccess, EnvironmentValue = TrampolineCall(function()
				return AURAUNC
			end, {}, {
				env = {AURAUNC = Value},
			})
			assert(EnvironmentSuccess == true, `the env option errored with {EnvironmentValue}`)
			Formatters.CheckEqual(EnvironmentValue, Value, "the value in the given environment")
			if GetIdentity then
				local Identity = GetIdentity()
				local IdentitySuccess, NewIdentity = TrampolineCall(GetIdentity, {}, {identity = 2})
				assert(IdentitySuccess == true, `the identity option errored with {NewIdentity}`)
				Formatters.CheckEqual(NewIdentity, 2, "the identity inside of the call")
				Formatters.CheckEqual(GetIdentity(), Identity, "the identity after the call")
			end
			if not GetScriptThread or not CheckCaller or not GetCallingScript or not Player.Character then
				return
			end
			local Animate = Player.Character:FindFirstChild("Animate")
			local Thread = Animate and GetScriptThread(Animate)
			if not Thread then
				return
			end
			local ThreadSuccess, IsExecutor, CallingScript = TrampolineCall(function()
				return CheckCaller(), GetCallingScript()
			end, {}, {thread = Thread})
			assert(ThreadSuccess == true, `the thread option errored with {IsExecutor}`)
			assert(IsExecutor == false, "checkcaller should return false on a game script's thread")
			Formatters.CheckEqual(CallingScript, Animate, "the calling script on the game script's thread")
		end,
	},

	getclipboard = {
		Test = CheckClipboard,
		RunLast = true,
	},

	setclipboard = {
		Test = CheckClipboard,
		RunLast = true,
	},

	getfilesize = {
		Test = function()
			local FileName = `File_{math.random()}.txt`
			local Text = string.rep("AURAUNC", math.random(1, 100))
			Formatters.CheckExist("writefile")(FileName, Text)
			local Size = getfilesize(FileName)
			RemovePath("delfile", FileName)
			Formatters.CheckEqual(Size, #Text, "the size of the file")
		end,
	},

	renamefile = {
		Test = function()
			local IsFile = Formatters.CheckExist("isfile")
			local OldName = `File_{math.random()}.txt`
			local NewName = `File_{math.random()}.txt`
			local Text = tostring(math.random())
			Formatters.CheckExist("writefile")(OldName, Text)
			renamefile(OldName, NewName)
			local OldExists = IsFile(OldName)
			local Result = Formatters.CheckExist("readfile")(NewName)
			RemovePath("delfile", NewName)
			assert(not OldExists, "the old file still exists")
			Formatters.CheckEqual(Result, Text, "the renamed file's text")
		end,
	},

	movefile = {
		Test = function()
			local FolderName = `Folder_{math.random()}`
			local FileName = `File_{math.random()}.txt`
			local Text = tostring(math.random())
			Formatters.CheckExist("makefolder")(FolderName)
			Formatters.CheckExist("writefile")(FileName, Text)
			movefile(FileName, `{FolderName}/{FileName}`)
			local OldExists = Formatters.CheckExist("isfile")(FileName)
			local Result = Formatters.CheckExist("readfile")(`{FolderName}/{FileName}`)
			RemovePath("delfolder", FolderName)
			assert(not OldExists, "the old file still exists")
			Formatters.CheckEqual(Result, Text, "the moved file's text")
		end,
	},
}

local EconomyUrl = "https://economy.roblox.com/v1/user/currency"

local function CheckLoginHidden(Get: () -> string)
	local Success, Body = pcall(Get)
	if not Success or typeof(Body) ~= "string" then
		return
	end
	assert(not Body:find('"robux"', 1, true) and not Body:find('"isPremium"', 1, true), "your login was sent along, so any script could read your account through it")
end

local function CheckReached(Success: boolean, Result: any): boolean
	if Success then
		return Result ~= nil and Result ~= ""
	end
	local Message = tostring(Result)
	return Message:find("Argument %d+ missing") ~= nil or Message:find("Unable to cast") ~= nil or Message:find("invalid argument") ~= nil
end

local function CheckMethodsBlocked(Methods: {{any}}, Reason: string)
	local Unblocked = {}
	for _, Method in Methods do
		local ServiceName, MethodName, Argument = Method[1], Method[2], Method[3]
		local Found, Service = pcall(game.GetService, game, ServiceName)
		if not Found then
			continue
		end
		local Reached = CheckReached(pcall(function()
			return Service[MethodName](Service, Argument)
		end)) or CheckReached(pcall(loadstring(`local Service, Argument = ... return Service:{MethodName}(Argument)`) :: Function, Service, Argument))
		if Reached then
			table.insert(Unblocked, `{ServiceName}:{MethodName}`)
		end
	end
	assert(#Unblocked == 0, `{table.concat(Unblocked, ", ")} can be called, which lets scripts {Reason}`)
end

local SecurityTests: {[string]: any} = {
	["security: purchases need your approval"] = {
		Test = function()
			CheckMethodsBlocked({
				{"MarketplaceService", "PerformPurchase"},
				{"MarketplaceService", "PerformPurchaseV2"},
				{"MarketplaceService", "PerformBulkPurchase"},
				{"MarketplaceService", "PerformSubscriptionPurchase"},
				{"MarketplaceService", "PerformSubscriptionPurchaseV2"},
				{"MarketplaceService", "PerformCancelSubscription"},
				{"MarketplaceService", "PrepareCollectiblesPurchase"},
				{"MarketplaceService", "PromptPurchase"},
				{"MarketplaceService", "PromptProductPurchase"},
				{"MarketplaceService", "PromptGamePassPurchase"},
				{"MarketplaceService", "PromptBundlePurchase"},
				{"MarketplaceService", "PromptBulkPurchase"},
				{"MarketplaceService", "PromptPremiumPurchase"},
				{"MarketplaceService", "PromptSubscriptionPurchase"},
				{"MarketplaceService", "PromptCancelSubscription"},
				{"MarketplaceService", "PromptRobloxSubscriptionPurchase"},
				{"MarketplaceService", "PromptVIPServerPurchase"},
				{"MarketplaceService", "PromptCollectiblesPurchase"},
				{"MarketplaceService", "PromptNativePurchase"},
				{"MarketplaceService", "PromptNativePurchaseWithContext"},
				{"MarketplaceService", "PromptNativePurchaseWithLocalPlayer"},
				{"MarketplaceService", "PromptNativePurchaseWithLocalPlayerWithPaymentSessionId"},
				{"MarketplaceService", "PromptNativePurchaseWithPaymentSessionId"},
				{"MarketplaceService", "PromptRobloxPurchase"},
				{"MarketplaceService", "PromptThirdPartyPurchase"},
			}, "spend your Robux without asking")
		end,
	},

	["security: requests can't use your login"] = {
		Test = function()
			local Request = request
			if Request then
				CheckLoginHidden(function()
					return Request({
						Url = EconomyUrl,
						Method = "GET",
					}).Body
				end)
			end
			CheckLoginHidden(function()
				return game:HttpGet(EconomyUrl)
			end)
			CheckMethodsBlocked({
				{"HttpRbxApiService", "GetAsyncFullUrl", EconomyUrl},
				{"HttpRbxApiService", "GetAsync"},
				{"HttpRbxApiService", "PostAsync"},
				{"HttpRbxApiService", "PostAsyncFullUrl"},
				{"HttpRbxApiService", "RequestAsync"},
				{"HttpService", "RequestInternal"},
				{"HttpService", "requestInternal"},
				{"OpenCloudService", "HttpRequestAsync"},
				{"ContentProvider", "SetBaseUrl"},
				{"OpenCloudService", "InvokeAsync"},
				{"OpenCloudService", "GetApiV1"},
			}, "send web requests logged in as you")
		end,
	},

	["security: account data and tokens stay private"] = {
		Test = function()
			CheckMethodsBlocked({
				{"MarketplaceService", "GetRobuxBalance"},
				{"AccountService", "GetCredentialsHeaders"},
				{"AccountService", "GetDeviceAccessToken"},
				{"AccountService", "GetDeviceIntegrityToken"},
				{"AccountService", "GetDeviceIntegrityTokenYield"},
				{"MarketplaceService", "GetUserSubscriptionPaymentHistoryAsync"},
				{"MarketplaceService", "GetUserSubscriptionDetailsInternalAsync"},
				{"CaptureService", "RetrieveCaptures"},
				{"CaptureService", "GetCaptureUploadDataAsync"},
			}, "reach your private account data")
		end,
	},

	["security: scripts can't run things outside Roblox"] = {
		Test = function()
			CheckMethodsBlocked({
				{"LinkingService", "OpenUrl"},
				{"MessageBusService", "Call"},
				{"MessageBusService", "Publish"},
				{"MessageBusService", "MakeRequest"},
				{"BrowserService", "OpenBrowserWindow"},
				{"BrowserService", "ExecuteJavaScript"},
				{"GuiService", "OpenBrowserWindow"},
				{"ScriptContext", "AddCoreScriptLocal"},
				{"MessageBusService", "PublishProtocolMethodRequest"},
				{"MessageBusService", "PublishProtocolMethodResponse"},
				{"MessageBusService", "Subscribe"},
				{"MessageBusService", "GetLast"},
				{"BrowserService", "OpenNativeOverlay"},
				{"GuiService", "OpenNativeOverlay"},
			}, "open links or run things outside of Roblox")
		end,
	},

	["security: your account can't be changed without asking"] = {
		Test = function()
			CheckMethodsBlocked({
				{"AvatarEditorService", "NoPromptApplyProfileConfiguration"},
				{"AvatarEditorService", "NoPromptCreateOutfit"},
				{"AvatarEditorService", "NoPromptDeleteOutfit"},
				{"AvatarEditorService", "NoPromptRenameOutfit"},
				{"AvatarEditorService", "NoPromptSaveAvatar"},
				{"AvatarEditorService", "NoPromptSaveAvatarThumbnailCustomization"},
				{"AvatarEditorService", "NoPromptSetFavorite"},
				{"AvatarEditorService", "NoPromptUpdateOutfit"},
				{"AvatarEditorService", "PerformCreateOutfitWithDescription"},
				{"AvatarEditorService", "PerformRenameOutfit"},
				{"AvatarEditorService", "PerformSaveAvatarWithDescription"},
				{"AvatarEditorService", "PerformUpdateOutfit"},
				{"CaptureService", "CreatePostAsync"},
				{"Players", "ReportAbuse"},
				{"Players", "ReportAbuseV3"},
				{"AvatarEditorService", "SetAllowInventoryReadAccess"},
				{"AvatarEditorService", "PerformDeleteOutfit"},
				{"AvatarEditorService", "PerformSetFavorite"},
				{"CaptureService", "DeleteCapture"},
				{"CaptureService", "DeleteCapturesAsync"},
			}, "change your account without asking")
		end,
	},

	["security: file:// is blocked"] = {
		Test = function()
			local Request = request
			if Request then
				local Success, Response = pcall(Request, {
					Url = "file:///C:/",
					Method = "GET",
				})
				assert(not Success or not Response or not Response.Success or Response.Body == "", "request can read files on your computer through file://")
			end
			local Success, Result = pcall(game.HttpGet, game, "file:///C:/")
			assert(not Success or Result == nil or Result == "", "game:HttpGet can read files on your computer through file://")
			for Name, Read in {
				["game:HttpGetAsync"] = function()
					return game:HttpGetAsync("file:///C:/")
				end,
				["game:HttpPost"] = function()
					return game:HttpPost("file:///C:/", "")
				end,
			} do
				local ReadSuccess, ReadResult = pcall(Read)
				assert(not ReadSuccess or ReadResult == nil or ReadResult == "", `{Name} can read files on your computer through file://`)
			end
			CheckMethodsBlocked({
				{"InsertService", "GetLocalFileContents", "rbxasset://fonts/families/SourceSansPro.json"},
			}, "read files on your computer")
		end,
	},

	["security: scripts can't write programs"] = {
		Test = function()
			local WriteFile = writefile
			local ListFiles = listfiles
			if not WriteFile or not ListFiles then
				return
			end
			local Written = {}
			local Extensions = {"exe", "bat", "cmd", "com", "scr", "ps1", "vbs", "lnk", "msi"}
			local Names = {"AURAUNC.EXE", "AURAUNC.txt.exe", "AURAUNC.exe.", "AURAUNC.exe ", "AURAUNC.exe::$DATA", "AURAUNC.exe\0.txt"}
			for _, Extension in Extensions do
				table.insert(Names, `AURAUNC.{Extension}`)
			end
			for _, Name in Names do
				pcall(WriteFile, Name, "AURAUNC")
				pcall(appendfile or WriteFile, Name, "AURAUNC")
			end
			local Success, Paths = pcall(ListFiles, "")
			if not Success then
				Success, Paths = pcall(ListFiles, ".")
			end
			for _, Path in if Success then Paths else {} do
				local Name = tostring(Path):lower():match("[^/\\]*$")
				if not Name:find("^auraunc%.") then
					continue
				end
				pcall(delfile, Path)
				if not table.find(Extensions, Name:match("%.(%w+)$")) then
					continue
				end
				table.insert(Written, tostring(Path))
			end
			for _, Extension in Extensions do
				local Name = `AURAUNC.{Extension}`
				if table.find(Written, Name) or not select(2, pcall(isfile or function() end, Name)) then
					continue
				end
				table.insert(Written, Name)
				pcall(delfile, Name)
			end
			assert(#Written == 0, `scripts can write program files like {table.concat(Written, ", ")}, which could be run on your computer`)
		end,
	},

	["security: game scripts don't get executor powers"] = {
		Test = function()
			local SetThreadIdentity = Formatters.CheckExist("setthreadidentity")
			local GameLoadstring = Formatters.CheckExist("getrenv")().loadstring
			local Results
			task.spawn(function()
				SetThreadIdentity(2)
				if pcall(function()
					return game:GetService("CorePackages").Name
				end) then
					Results = {Lowered = false}
					return
				end
				Results = {
					Lowered = true,
					Browser = pcall(function()
						game:GetService("BrowserService"):OpenBrowserWindow("")
					end),
					Locked = pcall(function()
						Instance.new("StringValue").RobloxLocked = true
					end),
					Loadstring = pcall(GameLoadstring, "return 1"),
				}
			end)
			WaitFor(function()
				return Results ~= nil
			end, 2)
			local Leftover = {}
			for _, Service in {"VirtualInputManager", "VirtualUser"} do
				if game:FindService(Service) then
					table.insert(Leftover, Service)
				end
			end
			assert(#Leftover == 0, `{table.concat(Leftover, " and ")} exists in the game, so game scripts can detect the executor through FindService`)
			assert(Results, "a thread at identity 2 never finished")
			if not Results.Lowered then
				error({Skipped = "setthreadidentity didn't really lower the identity, so what game scripts can do couldn't be checked"})
			end
			local Leaks = {}
			if Results.Browser then
				table.insert(Leaks, "BrowserService:OpenBrowserWindow")
			end
			if Results.Locked then
				table.insert(Leaks, "setting RobloxLocked")
			end
			if Results.Loadstring then
				table.insert(Leaks, "loadstring")
			end
			assert(#Leaks == 0, `{table.concat(Leaks, ", ")} works at the game's own identity, which lets game scripts use executor powers`)
		end,
	},

	["security: files outside the workspace stay hidden"] = {
		Test = function()
			for Name, Paths in {
				isfolder = {"C:/Windows", "/system"},
				isfile = {"C:/Windows/win.ini", "../../../../../../Windows/win.ini", "/system/build.prop"},
			} do
				local Check = getgenv()[Name]
				if not Check then
					continue
				end
				for _, Path in Paths do
					local Success, Found = pcall(Check, Path)
					assert(not (Success and Found), `{Name} can see '{Path}' outside of the workspace`)
				end
			end
		end,
	},

	["security: bytecode can't be loaded"] = {
		Test = function()
			local Bytecode = Formatters.CheckExist("getscriptbytecode")(GetPlayerScripts():FindFirstChildWhichIsA("LocalScript", true))
			assert(typeof(Bytecode) == "string" and #Bytecode > 0, "couldn't get any bytecode to test with")
			assert(loadstring(Bytecode) == nil, "loadstring ran raw bytecode, which lets scripts break out of the sandbox")
		end,
	},

	["security: blocks can't be bypassed"] = {
		Test = function()
			local Bypasses = {}
			for Name, GetRoot in {
				["stats().Parent"] = function()
					return stats().Parent
				end,
				["settings().Parent"] = function()
					return settings().Parent
				end,
				["UserSettings().Parent"] = function()
					return UserSettings().Parent
				end,
				["Stats service's Parent"] = function()
					return game:GetService("Stats").Parent
				end,
				["UserGameSettings service's Parent"] = function()
					return game:GetService("UserGameSettings").Parent
				end,
			} do
				local Success, Root = pcall(GetRoot)
				if not Success or typeof(Root) ~= "Instance" then
					continue
				end
				local Reached, Balance = pcall(function()
					return Root:GetService("MarketplaceService"):GetRobuxBalance()
				end)
				if Reached and Balance ~= nil then
					table.insert(Bypasses, Name)
				end
			end
			assert(#Bypasses == 0, `{table.concat(Bypasses, ", ")} reached a method that's blocked everywhere else`)
		end,
	},
}

for Name, Info in SecurityTests do
	Info.Security = true
	Tests[Name] = Info
end

local NoTests: {[string | number]: any} = {
	"queueonteleport",
	"setrbxclipboard",
	"setsimulationradius",
	"clearqueueonteleport",

	rconsolecreate = {
		Test = CheckConsole,
		RunLast = true,
	},

	rconsoleprint = {
		Test = CheckConsole,
		RunLast = true,
	},

	rconsoleinfo = {
		Test = CheckConsole,
		RunLast = true,
	},

	rconsolewarn = {
		Test = CheckConsole,
		RunLast = true,
	},

	rconsoleerr = {
		Test = CheckConsole,
		RunLast = true,
	},

	rconsolesettitle = {
		Test = function()
			CheckConsole()
			rconsolesettitle("AURAUNC")
		end,
		RunLast = true,
	},

	rconsoleclear = {
		Test = function()
			CheckConsole()
			rconsoleclear()
		end,
		RunLast = true,
	},

	rconsoledestroy = {
		Test = CheckConsole,
		RunLast = true,
	},

	isrbxactive = {
		ReturnType = "boolean",
		Test = function()
			assert(not MissedFocusLoss, "still returned true after the Roblox window lost focus")
			if not HasFocus then
				return
			end
			local function CheckLostFocus()
				return not HasFocus
			end
			local function CheckInactive()
				return HasFocus or not isrbxactive()
			end
			local CreateConsole = rconsolecreate
			if CreateConsole then
				AddCleanup(function()
					rconsoledestroy()
				end)
				pcall(CreateConsole)
				if WaitFor(CheckLostFocus, 1) then
					assert(WaitFor(CheckInactive, 1), "still returned true after the Roblox window lost focus")
					return
				end
			end
		end,
		RunLast = true,
	},

	messagebox = {
		Test = function()
			local MessageBox = messagebox
			local BoxStartTime = os.clock()
			local Frames = 0
			local Connection = game:GetService("RunService").Heartbeat:Connect(function()
				Frames += 1
			end)
			task.spawn(pcall, MessageBox, "AURAUNC test, you can close this", "AURAUNC", 0)
			task.wait(1)
			Connection:Disconnect()
			local Elapsed = os.clock() - BoxStartTime
			MessageBoxTime = math.max(Elapsed - 1, 0)
			assert(Elapsed < 2 and Frames > 10, `Roblox froze while the message box was open, only {Frames} frames ran in {math.floor(Elapsed * 10) / 10} seconds`)
		end,
		RunLast = true,
	},
}

for Index, Info in NoTests do
	assert(not Tests[Index] and not Tests[Info], `a test for {Index} or {Info} already exists`)
	if typeof(Index) == "string" then
		Tests[Index] = Info
		continue
	end
	Tests[Info] = {}
end

local GetGlobalEnvironment: () -> {[string]: any} = getgenv or function()
	return {}
end

local function RestoreFunctions()
	local GlobalEnvironment = GetGlobalEnvironment()
	if not GlobalEnvironment.OriginalFunctions then
		return
	end
	for Name, OriginalFunction in GlobalEnvironment.OriginalFunctions do
		getfenv()[Name] = OriginalFunction
	end
	for Name in GlobalEnvironment.NonExistentFunctions do
		getfenv()[Name] = nil
	end
	GlobalEnvironment.OriginalFunctions = nil
end

RestoreFunctions()

local ExecutorName, ExecutorVersion = (identifyexecutor or function()
	return "Unknown Executor", "0.0.0"
end)()

ExecutorName = ExecutorName or "Unknown Executor"
ExecutorVersion = ExecutorVersion or "0.0.0"

local function DisplayMessage(Message: string)
	if ExecutorName == "AWP" then
		print(Message)
		return
	end
	if not pcall(game:GetService("TestService").Message, game:GetService("TestService"), Message) then
		print(Message)
	end
end

local Settings: {[string]: any} = {
	FakeFunctions = false,
	GetTests = false,
	GetUnaddedFunctions = false,
	DebugMode = false,
	CrashTests = false,
}

for Name, Value in shared.Settings or {} do
	Settings[Name] = Value
end

for Name in Settings do
	local Saved = shared[Name]
	if Saved == nil then
		continue
	end
	Settings[Name] = Saved
end

if Settings.CrashTests then
	Tests["crash: hooking a running proto"] = {
		Test = function()
			assert(loadstring([[
				local Proto

				local function Outer()
					local function Inner(Depth)
						if Depth == 1 then
							hookproto(Proto, function() end)
							pcall(function() fullgc() end)
							pcall(function() collectgarbage("collect") end)

							local Filler = {}

							for Index = 1, 3000 do
								Filler[Index] = {}
							end
						end

						if Depth > 0 then
							return Inner(Depth - 1)
						end
					end

					return Inner
				end

				local Running = Outer()

				Proto = debug.getproto(Outer, 1)
				Running(2)
				restoreproto(Proto)
			]]))()
		end,
		Security = true,
		RunLast = true,
	}
end

pcall(game:GetService("StarterGui").SetCore, game:GetService("StarterGui"), "DevConsoleVisible", true)

DisplayMessage("If your Roblox crashes or freezes during these tests, run `shared.DebugMode = true` before AURAUNC to prevent it or find the crashing function.")

local IsFunctionHooked = isfunctionhooked

if Settings.FakeFunctions then
	local NewCClosure: ((...any) -> ...any) -> (...any) -> ...any = newcclosure
	local OriginalFunctions = {}
	local NonExistentFunctions = {}
	DisplayMessage("Faking functions is enabled")
	for FunctionName in Tests do
		if FunctionName == "getgenv" or FunctionName == "newcclosure" or Tests[FunctionName].Security then
			continue
		end
		local LibraryName, MemberName = FunctionName:match("^([^.]+)%.([^.]+)$")
		if LibraryName then
			local OriginalLibrary = getfenv()[LibraryName]
			if typeof(OriginalLibrary) ~= "table" then
				continue
			end
			if OriginalFunctions[LibraryName] == nil then
				OriginalFunctions[LibraryName] = OriginalLibrary
				getfenv()[LibraryName] = table.clone(OriginalLibrary)
			end
			getfenv()[LibraryName][MemberName] = NewCClosure(function() end)
			continue
		end
		if not getfenv()[FunctionName] then
			NonExistentFunctions[FunctionName] = true
		end
		OriginalFunctions[FunctionName] = getfenv()[FunctionName]
		getfenv()[FunctionName] = NewCClosure(function() end)
	end
	GetGlobalEnvironment().OriginalFunctions = OriginalFunctions
	GetGlobalEnvironment().NonExistentFunctions = NonExistentFunctions
end

local function StartCallLogging()
	local HookFunction = hookfunction
	local WriteFile = writefile
	local AppendFile = appendfile
	local RestoreFunction = restorefunction
	local CheckCaller = checkcaller
	if not HookFunction or not WriteFile then
		return
	end
	local Blacklist = {
		"__ws_poll", "__ws_send", "hookfunction", "info", "print",
		"profilebegin", "profileend", "tostring", "wait", "writefile",
	}
	local HookedTables = {}
	local HookedFunctions = {}
	local Log = ""
	local Logging = true
	local function Hook(Name, HookedFunction)
		if typeof(HookedFunction) == "table" then
			if HookedTables[HookedFunction] or getmetatable(HookedFunction) ~= nil then
				return
			end
			HookedTables[HookedFunction] = true
			for OtherName, OtherFunction in HookedFunction do
				Hook(OtherName, OtherFunction)
			end
			return
		end
		if table.find(Blacklist, Name) or typeof(HookedFunction) ~= "function" or HookedFunction == CheckCaller then
			return
		end
		local Original
		Original = HookFunction(HookedFunction, function(...)
			if Logging or (CheckCaller and not CheckCaller()) or tostring((...)) == "WebSocket" then
				return Original(...)
			end
			Logging = true
			local Arguments = {...}
			local Message = `Ran function {Name}`
			local ArgumentNames = {}
			print(Message)
			for _, Argument in Arguments do
				table.insert(ArgumentNames, tostring(Argument))
			end
			local Line = `{Message}{if Arguments[1] then ` with arguments {table.concat(ArgumentNames, ", ")}` else ""}\n`
			if AppendFile then
				AppendFile("LogFunctionCalls.txt", Line)
			else
				Log ..= Line
				WriteFile("LogFunctionCalls.txt", Log)
			end
			Logging = false
			task.wait(0.1)
			return Original(...)
		end)
		HookedFunctions[HookedFunction] = Original
	end
	WriteFile("LogFunctionCalls.txt", "")
	for Name, GlobalFunction in GetGlobalEnvironment() do
		Hook(Name, GlobalFunction)
	end
	print("Started logging function calls")
	Logging = false
	return function()
		Logging = true
		for HookedFunction, Original in HookedFunctions do
			if RestoreFunction and pcall(RestoreFunction, HookedFunction) then
				continue
			end
			pcall(HookFunction, HookedFunction, Original)
		end
	end
end

local StopCallLogging

if Settings.DebugMode then
	DisplayMessage("Debug Mode is enabled!")
	StopCallLogging = StartCallLogging()
end

if IsFunctionHooked and not Settings.DebugMode then
	assert(IsFunctionHooked(pcall) == false, "tests can't run if pcall is hooked")
	assert(IsFunctionHooked(loadstring) == false, "tests can't run if loadstring is hooked")
end

local TotalTests = 0
local CompletedTests = 0
local FailedTests = 0
local MissingFunctions = 0
local UntestableTests = 0
local EnvironmentSkips = 0

local Results: {[string]: string} = {}
local FailureMessages: {[string]: string} = {}

local function RunTest(Name: string, Info: any)
	TestThreads[coroutine.running()] = Name
	local Missing = false
	local TestedAlias = ""
	local Success, ErrorMessage = pcall(function()
		if not Info.Security then
			local TestedValue = FindFirstFunction(Name)
			for _, OtherName in Info.OtherNames or {} do
				if TestedValue then
					break
				end
				TestedValue = FindFirstFunction(OtherName)
				TestedAlias = if TestedValue then ` ({OtherName})` else ""
			end
			local ValueType = Info.ValueType or "function"
			Missing = TestedValue == nil
			assert(TestedValue, "doesn't exist")
			assert(typeof(TestedValue) == ValueType, `doesn't have '{ValueType}' type`)
			if IsFunctionHooked and ValueType == "function" and not Settings.DebugMode then
				assert(IsFunctionHooked(TestedValue) == false, "the function is hooked and can't be tested accurately")
			end
			if Info.ReturnType then
				Formatters.CheckReturnType(TestedValue(), Info.ReturnType)
			end
		end
		if not Info.Test then
			return
		end
		if not Info.Retry then
			Info.Test()
			return
		end
		local FirstSuccess, FirstError = pcall(Info.Test)
		if FirstSuccess then
			return
		end
		if typeof(FirstError) == "table" and FirstError.Skipped then
			error(FirstError, 0)
		end
		RunCleanups(coroutine.running())
		Info.Test()
	end)
	TestThreads[coroutine.running()] = nil
	RunCleanups(coroutine.running())
	if Results[Name] then
		return
	end
	TotalTests += 1
	if Success then
		print(`🟢 {Name}{TestedAlias}`)
		Results[Name] = "passed"
		CompletedTests += 1
		return
	end
	if typeof(ErrorMessage) == "table" and ErrorMessage.Skipped then
		warn(`🟠 {Name}: skipped because {ErrorMessage.Skipped}`)
		Results[Name] = "skipped"
		UntestableTests += 1
		EnvironmentSkips += if ErrorMessage.Environment then 1 else 0
		return
	end
	if not Settings.DebugMode then
		ErrorMessage = tostring(ErrorMessage):gsub("^.-:%d+: ", "")
	end
	if not Missing and InputTests[Name] and not IsRobloxFocused() and not tostring(ErrorMessage):find("focused") then
		ErrorMessage = `{ErrorMessage} while Roblox wasn't focused, input should still reach Roblox`
	end
	if Missing then
		warn(`🟡 {Name}`)
		Results[Name] = "missing"
		MissingFunctions += 1
		return
	end
	Results[Name] = "failed"
	FailureMessages[Name] = ErrorMessage
end

local function MarkUnfinished(Name: string)
	if Results[Name] then
		return
	end
	for Thread, TestName in TestThreads do
		if TestName ~= Name then
			continue
		end
		TestThreads[Thread] = nil
		pcall(task.cancel, Thread)
		RunCleanups(Thread)
	end
	TotalTests += 1
	Results[Name] = "failed"
	FailureMessages[Name] = `didn't finish within {if Settings.DebugMode then 600 else 60} seconds`
end

local TestTimeout = if Settings.DebugMode then 600 else 60

local function RunTestAlone(Name: string, Info: any)
	task.spawn(RunTest, Name, Info)
	WaitFor(function()
		return Results[Name] ~= nil
	end, TestTimeout)
	MarkUnfinished(Name)
end

local TestCount = 0
local LastTests = {}

for Name: string, Info in Tests do
	TestCount += 1
	if Info.RunLast then
		table.insert(LastTests, Name)
		continue
	end
	if Settings.DebugMode then
		RunTestAlone(Name, Info)
		task.wait(0.179)
		continue
	end
	task.spawn(RunTest, Name, Info)
	task.wait()
end

local StartTime = tick()

WaitFor(function()
	return TotalTests == TestCount - #LastTests
end, TestTimeout)

for Name, Info in Tests do
	if Info.RunLast then
		continue
	end
	MarkUnfinished(Name)
end

DisplayMessage("Don't touch your mouse or keyboard until the tests finish.")

for _, Name in {"rconsolecreate", "rconsoleprint", "rconsoleinfo", "rconsolewarn", "rconsoleerr", "rconsolesettitle", "rconsoleclear", "rconsoledestroy", "isrbxactive", "messagebox"} do
	table.insert(LastTests, table.remove(LastTests, table.find(LastTests, Name)))
end

MoveFocusToConsole()

for _, Name in LastTests do
	if Name == "rconsolecreate" then
		pcall(rconsoledestroy or function() end)
	end
	RunTestAlone(Name, Tests[Name])
end

FocusConnection:Disconnect()
FocusGainedConnection:Disconnect()

if StopCallLogging then
	StopCallLogging()
end

pcall(function()
	for _, Path in listfiles("") do
		local FileName = Path:match("[^/\\]+$")
		if FileName:match("^File_[%d%.e%-]+%.%a+$") then
			delfile(Path)
		elseif FileName:match("^Folder_[%d%.e%-]+$") then
			delfolder(Path)
		end
	end
end)

for Name, Message in FailureMessages do
	local BlockingDependency
	local BlockingReason
	for Dependency in Dependencies[Name] or {} do
		local DependencyResult = Results[Dependency] or if FindFirstFunction(Dependency) then nil else "missing"
		if (DependencyResult ~= "failed" and DependencyResult ~= "missing") or (Dependencies[Dependency] and Dependencies[Dependency][Name]) then
			continue
		end
		BlockingDependency = Dependency
		BlockingReason = if DependencyResult == "missing" then "is missing" else "failed"
		break
	end
	if BlockingDependency then
		warn(`🟠 {Name}: couldn't be tested because {BlockingDependency} {BlockingReason}`)
		UntestableTests += 1
		continue
	end
	warn(`🔴 {Name}: {Message}`)
	FailedTests += 1
end

local ElapsedTime = tick() - StartTime - MessageBoxTime
local PercentageComplete = math.floor(CompletedTests / math.max(TotalTests - EnvironmentSkips, 1) * 100)
local MinimumSeconds = 0.1

task.wait(0.5)

if ElapsedTime < MinimumSeconds and PercentageComplete > 80 then
	DisplayMessage(`This test is most likely faked as it took less than {MinimumSeconds} seconds.`)
end

DisplayMessage("❓ The score below is only for how many custom functions are supported and secure.")
DisplayMessage(`🔵 AURAUNC v2.11.0 Score for {ExecutorName} {ExecutorVersion}: {PercentageComplete}%`)
DisplayMessage(`🟣 Total tests: {TotalTests} (Took {math.floor(ElapsedTime * 100) / 100} seconds)`)
DisplayMessage(`🟢 Successful tests: {CompletedTests}`)
DisplayMessage(`🔴 Failed tests: {FailedTests}`)
DisplayMessage(`🟠 Skipped tests: {UntestableTests}`)
DisplayMessage(`🟡 Missing functions: {MissingFunctions}`)

local function Divider()
	print("---------------------------------------------------------------------------------------------------------")
end

Divider()

print("AURAUNC shared Settings:")

Divider()

for Name: string, Enabled: boolean in Settings do
	print(`{Name}: {Enabled}`)
end

Divider()

RestoreFunctions()

local function RunCompatibilityCheck()
	local Out_M = "[AURAUNC COMPATIBILITY]: "
	local Erros = {
		MissingFunc = {},
		MissingC = {},
		Called = {},
	}

	local function SimpleHttp()
		warn(Out_M .. "@Httpget: ")
		local Success, HttpGet = pcall(function()
			return game.HttpGet
		end)
		if Success and HttpGet then
			print("\t\tYour executor can index game.HttpGet")
			return true
		else
			print("\t\tYour executor can NOT index game.HttpGet")
			warn("\t\tyour exploit is bad you clown")
			return false
		end
	end

	local function FuncCheck()
		warn(Out_M .. "@ENV: ")
		local TBL, Suc = {
			["setthreadcontext"] = setthreadcaps or setthreadcontext or setthreadidentity or set_thread_context or set_thread_identity or 0,
			["hookfunction"] = hookfunc or hookfunction or 0,
			["hookmetamethod"] = hookmetamethod or 0,
			["newcclosure"] = newcclosure or 0,
			["checkcaller"] = checkcaller or 0,
			["getnamecallmethod"] = getnamecallmethod or 0,
			["getrawmetatable"] = getrawmetatable or 0,
			["setreadonly"] = setreadonly or make_writeable or 0,
			["isreadonly"] = isreadonly or 0,
			["getgc"] = getgc or 0,
			["getgenv"] = getgenv or 0,
			["getrenv"] = getrenv or 0,
			["getreg"] = getreg or 0,
			["getinfo"] = debug.getinfo or getinfo or 0,
			["getupvalue"] = getupvalue or 0,
			["getupvalues"] = getupvalues or 0,
			["setupvalue"] = setupvalue or 0,
			["getconstants"] = getconstants or 0,
			["setconstant"] = setconstant or 0,
			["getprotos"] = getprotos or 0,
			["getproto"] = getproto or 0,
			["cloneref"] = cloneref or 0,
			["isfunctionhooked"] = isfunctionhooked or 0,
			["identifyexecutor"] = identifyexecutor or 0,
			["isexecutorclosure"] = isexecutorclosure or 0,
			["gethui"] = gethui or 0,
			["request"] = http_request or request or 0,
			["firetouchinterest"] = firetouchinterest or 0,
			["fireproximityprompt"] = fireproximityprompt or 0,
			["firesignal"] = firesignal or 0,
			["getconnections"] = getconnections or 0,
			["restorefunction"] = restorefunction or restorefunc or restoreclosure or 0,
		}, {}
		for Name, Func in TBL do
			if type(Func) == "function" then
				Suc[Name] = {Txt = "\t✅ " .. Name, func = Func}
			else
				Suc[Name] = {Txt = "\t❌ " .. Name}
				table.insert(Erros.MissingFunc, Name)
			end
		end
		if debug.info then
			for Name, v in Suc do
				local Written, RName
				if v.func then
					pcall(function()
						Written, RName = debug.info(v.func, "sn")
					end)
				end
				if type(Written) == "string" and Written ~= "[C]" and Written ~= "C" then
					table.insert(Erros.MissingC, Name)
				end
				print(v.Txt .. " " .. (Written or "") .. " (" .. (RName or "") .. ")")
			end
		else
			for Name, v in Suc do
				print(v.Txt)
			end
			warn("[WARNING]: debug.info NOT found")
		end
		return true
	end

	local function RequestCheck()
		warn(Out_M .. "@RQ: ")
		local Request = http_request or request
		if not Request then
			return false
		end
		local Success, Response = pcall(function()
			return Request({Url = "https://httpbin.org/get", Method = "GET"})
		end)
		warn("\tOriginal RQ:")
		if Success and Response then
			if Response.StatusCode and Response.Success then
				print("\t\tSuccess")
			else
				print("\t\tStatusCode: " .. tostring(Response.StatusCode))
				print("\t\tSuccess: " .. tostring(Response.Success))
				return false
			end
		else
			print("\t\tFailed: " .. tostring(Response))
			return false
		end
		local LowerC = hookfunc or hookfunction
		local ResetC = restorefunction or restorefunc or restoreclosure
		if not LowerC then
			return false
		end
		local Success, Response = pcall(function()
			LowerC(Request, function(...)
				return "Hello World"
			end)
			return Request({Url = "https://httpbin.org/get", Method = "GET"})
		end)
		warn("\tHooked RQ:")
		if Success then
			if Response == "Hello World" then
				print("\t\tSuccess: " .. tostring(Response))
			else
				print("\t\tUnhookable: " .. tostring(Response))
			end
		else
			print("\t\tFailed: " .. tostring(Response))
			return false
		end
		if not ResetC then
			return false
		end
		warn("\tRestored RQ:")
		local Success, Response = pcall(function()
			ResetC(Request)
		end)
		if not Success then
			print("\t\tFailed: " .. tostring(Response))
		else
			print("\t\tSuccess")
		end
		local Success, Response = pcall(function()
			return Request({Url = "https://httpbin.org/get", Method = "GET"})
		end)
		warn("\tNext RQ:")
		if Success and Response then
			if Response.StatusCode and Response.Success then
				print("\t\tSuccess")
			else
				warn("\t\tSecurityVoltSharp")
				return false
			end
		else
			print("\t\tFailed: " .. tostring(Response))
			return false
		end
		return true
	end

	local function LuaTimeCheck()
		warn(Out_M .. "@LT:")
		if not isfunctionhooked then
			return false
		end
		local serve1 = tick()
		isfunctionhooked(print)
		local serve2 = tick()
		local serve3 = serve2 - serve1
		if serve3 > 0.00000250928955078125 then
			print("\t\tFailed: " .. tostring(serve3))
		else
			print("\t\tSuccess: " .. tostring(serve3))
		end
		return true
	end

	local function RequireCheck()
		warn(Out_M .. "@REQ:")
		if not require then
			return false
		end
		if not debug.info then
			return false
		end
		local Success, Written = pcall(function()
			return debug.info(require, "s")
		end)
		if Written ~= "C" and Written ~= "[C]" then
			print("\tFailed 2C")
			return false
		else
			print("\tSuccess 2C")
		end
		warn("\tREQ:")
		local Success, Response = pcall(function()
			return require(game:GetService("Players").LocalPlayer.PlayerScripts.PlayerModule)
		end)
		if Success and Response then
			print("\t\tSuccess: " .. tostring(Response))
		else
			print("\t\tFailed: " .. tostring(Response))
		end
		return true
	end

	local function GCCheck()
		warn(Out_M .. "@GC:")
		if not getgc then
			return
		end
		local Success, Response = pcall(function()
			return getgc(true)
		end)
		task.wait(3)
		if not Success then
			print("\tGC Failed: " .. tostring(Response))
			return false
		else
			local atleast1 = nil
			for i, v in Response do
				if type(v) == 'table' then
					if rawget(v, "cameras") and rawget(v, "controls") then
						atleast1 = v
					end
				end
			end
			if atleast1 then
				print("\tGC Success: " .. tostring(atleast1))
			else
				print("\tFake GC: " .. tostring(atleast1))
			end
		end
		return true
	end

	local function UPSCheck()
		warn(Out_M .. "@UPS:")
		local getup = getupvalue or debug.getupvalue
		local getcon = getconstants or debug.getconstants
		if not getup then
			return false
		end
		if not getcon then
			return false
		end
		local Success, Response = pcall(function()
			return require(game:GetService("Players").LocalPlayer.PlayerScripts.PlayerModule)
		end)
		if not Success then
			warn("\tProbably failed to double required")
			return false
		end
		local new = Response.controls
		new = new and new.activeControlModule
		new = new and new.new
		if not new then
			return false
		end
		local Success, Up = pcall(function()
			return getupvalue(new, 1)
		end)
		if not Success then
			print("\tFailed: " .. tostring(Up))
		else
			print("\tSuccess: " .. tostring(Up))
		end
		return true
	end

	for i, v in {
		["HttpGet"] = SimpleHttp(),
		["Func"] = FuncCheck(),
		["RQ"] = RequestCheck(),
		["LT"] = LuaTimeCheck(),
		["REQ"] = RequireCheck(),
		["GC"] = GCCheck(),
		["UPS"] = UPSCheck(),
	} do
		if not v then
			table.insert(Erros.Called, i)
		end
		if i == "HttpGet" and not v then
			return
		end
		if not v then
			warn(Out_M .. i .. " did not complete successfully")
		end
	end

	local execname = getexecutorname or function()
		return "Cannot identify executor!"
	end
	local getthread = getthreadcontext or getthreadidentity or getthreadcaps or get_thread_context or get_thread_identity or function()
		return "Unknown"
	end

	warn(Out_M .. "Executor: " .. tostring(execname()))
	warn(Out_M .. "Thread: " .. tostring(getthread()))
	warn(Out_M .. "MissingFunc: " .. tostring(#Erros.MissingFunc))
	warn(Out_M .. "MissingC: " .. tostring(#Erros.MissingC))
	warn(Out_M .. "FailedCall: " .. tostring(#Erros.Called))

	for i, v in Erros.Called do
		print("\t" .. v)
	end

	pcall(function()
		local setc = setclipboard or toclipboard
		if not setc then
			warn(Out_M .. "Clipboard function unavailable")
			return
		end
		local Report = {
			"========================================",
			"       AURAUNC COMPATIBILITY REPORT",
			"========================================",
			"",
			"Executor: " .. tostring(execname()),
			"Thread: " .. tostring(getthread()),
			"",
			"--------------- SUMMARY ----------------",
			"Missing Functions: " .. tostring(#Erros.MissingFunc),
			"Non-C Functions: " .. tostring(#Erros.MissingC),
			"Failed Checks: " .. tostring(#Erros.Called),
			"",
			"----------- MISSING FUNCTIONS ----------"
		}
		for _, v in Erros.MissingFunc do
			table.insert(Report, "[-] " .. tostring(v))
		end
		if #Erros.MissingFunc == 0 then
			table.insert(Report, "[+] None")
		end
		table.insert(Report, "")
		table.insert(Report, "------------- NON-C FUNCTIONS -----------")
		for _, v in Erros.MissingC do
			table.insert(Report, "[!] " .. tostring(v))
		end
		if #Erros.MissingC == 0 then
			table.insert(Report, "[+] None")
		end
		table.insert(Report, "")
		table.insert(Report, "-------------- FAILED CHECKS ------------")
		for _, v in Erros.Called do
			table.insert(Report, "[-] " .. tostring(v))
		end
		if #Erros.Called == 0 then
			table.insert(Report, "[+] None")
		end
		table.insert(Report, "")
		table.insert(Report, "========================================")
		table.insert(Report, "Generated by AURAUNC")
		table.insert(Report, "========================================")
		local FinalReport = table.concat(Report, "\n")
		setc(FinalReport)
	end)
end

local Success, Error = pcall(function()
	RunCompatibilityCheck()
end)

warn("[AURAUNC ERROR]: " .. tostring(Success) .. " " .. tostring(Error))
