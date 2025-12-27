local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local AnalyticsService = game:GetService("AnalyticsService")

local SkipHatchBindable = ServerScriptService.Events.Bindables.SkipEggHatch
local AddMultiplierBindable = ServerScriptService.Events.Bindables.AddMultiplier
local AddEggLuckBindable = ServerScriptService.Events.Bindables.AddEggLuck
local SpawnEggBindable = ServerScriptService.Events.Bindables.SpawnEgg

local PetsFolder = ReplicatedStorage.Assets.Pets
local PlotsFolder = ServerScriptService.Assets.PlotModels

local Eggs = require(ReplicatedStorage.Shared.Modules.Core.Eggs) :: {any}
local Pets = require(ReplicatedStorage.Shared.Modules.Core.Pets) :: {any}
local DataService = require(ServerScriptService.Services.DataService)
local EggClass = require(ServerScriptService.Classes.Egg)
local PetClass = require(ServerScriptService.Classes.Pet)
local ProductIds = require(ReplicatedStorage.Shared.Modules.Game.ProductIds)
local Mutations = require(ReplicatedStorage.Shared.Modules.Core.Mutations)
local Rarities = require(ReplicatedStorage.Shared.Modules.Core.Rarities)
local Plots = require(ReplicatedStorage.Shared.Modules.Core.Plots)

local PetAction = ReplicatedStorage.Shared.Events.Remotes.PetAction
local IndexPet = ReplicatedStorage.Shared.Events.Remotes.IndexPet
local UpdateMultiplier = ReplicatedStorage.Shared.Events.Remotes.UpdateMultiplier
local ClientSound = ReplicatedStorage.Shared.Events.Remotes.ClientSound
local UnlockZoo = ReplicatedStorage.Shared.Events.Remotes.UnlockZoo

local Classes = ServerScriptService.Classes
local ConveyorClass = require(Classes.Conveyor)

local function PickRandom(Items, LuckMultiplier: number)
	LuckMultiplier = math.max(LuckMultiplier or 1, 1)

	local TotalWeight = 0
	for _, ItemData in ipairs(Items) do
		local AdjustedChance = ItemData.Chance
		local AdditionalLuck = 1
		
		AdjustedChance = AdjustedChance ^ (1 / (LuckMultiplier ^ AdditionalLuck))

		ItemData._AdjustedChance = AdjustedChance
		TotalWeight += AdjustedChance
	end

	local Roll = math.random() * TotalWeight
	local Accumulated = 0

	for _, ItemData in ipairs(Items) do
		Accumulated += ItemData._AdjustedChance
		if Roll <= Accumulated then
			return ItemData.Name
		end
	end
end
local f = math.floor
local l10 = math.log10
local function Abbreviate(Number: number, Decimals) : string
	return math.floor(((Number < 1 and Number) or math.floor(Number) / 10 ^ (math.log10(Number) - math.log10(Number) % 3)) * 10 ^ (Decimals or 3)) / 10 ^ (Decimals or 3)..(({"k", "M", "B", "T", "QA", "QN", "SX", "SP", "OC", "N"})[math.floor(math.log10(Number) / 3)] or "")
end

local function FormatTime(seconds: number): string
	seconds = math.max(0, math.floor(seconds))

	local hours = math.floor(seconds / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	local secs = seconds % 60

	if hours > 0 then
		return string.format("%d:%02d:%02d", hours, minutes, secs)
	else
		return string.format("%d:%02d", minutes, secs)
	end
end

local Plot = {}
Plot.__index = Plot

function Plot.new(Player: Player, PlotModel: Model, PlotInfo)
	local self = setmetatable({}, Plot)
	
	self.Player = Player
	self.Plot = PlotModel
	
	self.CurrentPlotModel = "Normal"
	self.PlotInfo = PlotInfo
	
	self.PlacedPets = {}
	self.PlacedEggs = {}
	
	self.EggQueue = {}
	
	self.NumPets = 0
	self.MaxPets = PlotInfo.MaxPets
	
	self.MoneyMultiplier = 1
	self.LuckMultiplier = 1
	self.EggLuckMultiplier = 1
	
	self.Potions = {}
	
	self.Currency = 0
	self.CurrencyOffline = 0
	
	self.CharacterAdded = nil
	
	self.LastJoin = os.time()

	-- Load plot model data
	self:LoadPlotModelWithData(self.PlotInfo)
	
	return self
end

function Plot:_loadActions()
	-- Setup plot information
	self.Plot.PlayerInfo.SurfaceGui.Player.Text = self.Player.Name .. "'s"
	self.Plot.PrimaryPart.Marker.Title.Text = [[<b>]] .. self.Player.Name .. [[</b>]] .. [['s Zoo]]
	
	-- Begin spawning eggs
	self.EggSpawn = task.spawn(function()
		while true do
			task.wait(2.5)

			if self.EggQueue and #self.EggQueue > 0 then
				local NextEgg = table.remove(self.EggQueue, 1)
				if NextEgg then
					self.Conveyor:Spawn(Eggs[NextEgg], NextEgg)
				else
					local NewTable = {}
					for EggName, EggData in pairs(Eggs) do
						table.insert(NewTable, {Name = EggName, Chance = EggData.Chance})
					end
					local ChosenEgg = PickRandom(NewTable, self.LuckMultiplier)
					self.Conveyor:Spawn(Eggs[ChosenEgg], ChosenEgg)
				end
			else
				local NewTable = {}
				for EggName, EggData in pairs(Eggs) do
					table.insert(NewTable, {Name = EggName, Chance = EggData.Chance})
				end
				local ChosenEgg = PickRandom(NewTable, self.LuckMultiplier)
				if self.Conveyor then
					self.Conveyor:Spawn(Eggs[ChosenEgg], ChosenEgg)
				end
			end
		end
	end)

	-- Begin updating currency
	self.CurrencyUpdate = task.spawn(function()
		while true do
			task.wait(1)
			if DataService.Profiles[self.Player] then
				if self.MoneyMultiplier > 1 then
					self.Plot.CollectCash.BillboardGui.Money.Text = `${Abbreviate(self.Currency, 1)} (x{self.MoneyMultiplier})`
				else
					self.Plot.CollectCash.BillboardGui.Money.Text = `${Abbreviate(self.Currency, 1)}`
				end
			end
		end
	end)

	-- When the owner touches the pad to collect money
	self.CollectCash = self.Plot.CollectCash.Touched:Connect(function(Hit)
		if Hit and Hit.Parent and Players:GetPlayerFromCharacter(Hit.Parent) == self.Player and self.Currency > 0 then
			DataService.AddCurrency(self.Player, (self.Currency + self.CurrencyOffline * self.MoneyMultiplier), true)
			ClientSound:FireClient(self.Player, 111773238101465)

			self.Currency = 0
			self.CurrencyOffline = 0

			self.Plot.CollectCash.BillboardGui.Money.Text = "$" .. self.Currency
			self.Plot.CollectCash:FindFirstChildWhichIsA("BillboardGui").Offline.Visible = false
		end
	end)

	-- Skip hatch time monetization
	self.SkipHatchBindable = SkipHatchBindable.Event:Connect(function(Player: Player, EggId: string, ReceiptInfo)
		if Player == self.Player then
			local Egg = self.PlacedEggs[EggId]
			if Egg then
				Egg:SetTime(0)
				Egg:UpdateProfile()
			end
		end
	end)

	-- Multipliers monetization
	self.AddMultiplierBindable = AddMultiplierBindable.Event:Connect(function(Player: Player, Type: string)
		if Player == self.Player then
			local Profile = DataService.Profiles[Player]
			if not Profile then return end

			if Type == "cash" or Type == "money" then
				self:SetMoneyMultiplier(Profile.Data.MoneyMultiplier)
			elseif Type == "luck" then
				self:SetLuckMultiplier(Profile.Data.LuckMultiplier)
			end
		end
	end)

	-- Egg luck monetization
	self.AddEggLuckBindable = AddEggLuckBindable.Event:Connect(function(Player: Player, Multiplier: number)
		if Player == self.Player then
			self:SetEggLuckMultiplier(Multiplier)
		end
	end)

	-- Spawn legendary egg monetization
	self.SpawnLegendaryEgg = self.Plot.SpawnLegendaryEgg:FindFirstChildWhichIsA("ClickDetector").MouseClick:Connect(function(Player: Player)
		if Player == self.Player then
			--TODO: random legendary egg
			SpawnEggBindable:Fire(Player, "Purchase", 3429283434)
		end
	end)

	-- Spawn mythical egg monetization
	self.SpawnMythicalEgg = self.Plot.SpawnMythicalEgg:FindFirstChildWhichIsA("ClickDetector").MouseClick:Connect(function(Player: Player)
		if Player == self.Player then
			--TODO: random mythical egg
			SpawnEggBindable:Fire(Player, "Purchase", 3429283718)
		end
	end)

	-- Handle spawning purchased eggs
	self.SpawnEggBindable = SpawnEggBindable.Event:Connect(function(Player, Action, ...)
		if Player == self.Player then
			if Action == "Spawn" then
				table.insert(self.EggQueue, ...)
			end
		end
	end)

	-- Guaranteed eggs
	local GuaranteedRarities = {"Legendary", "Mythical", "Secret"}
	local RarityTimes = {
		Legendary = 300,
		Mythical = 900,
		Secret = 3600,
	}

	self.GuaranteedEggSpawners = {}

	local function PickEggBasedRarity(Rarity)
		if Rarities[Rarity] then
			local ValidEggs = {}
			for _, Egg in Eggs do
				if Egg.Rarity == Rarity then
					table.insert(ValidEggs, Egg)
				end
			end
			if #ValidEggs > 0 then
				local RandomEgg = ValidEggs[math.random(1, #ValidEggs)]
				return RandomEgg
			else
				warn("No eggs found with rarity " .. Rarity .. "!")
			end
		else
			warn("Rarity " .. Rarity .. " not found within rarities!")
		end
	end

	for _, EggGui in self.Plot.GuaranteedEggs:FindFirstChildWhichIsA("SurfaceGui"):GetChildren() do
		if table.find(GuaranteedRarities, EggGui.Name) then
			local RarityName = GuaranteedRarities[table.find(GuaranteedRarities, EggGui.Name)]
			local Color: Color3 = EggGui:GetAttribute("EggColor") or Color3.fromRGB(255,255,255)

			self.GuaranteedEggSpawners[RarityName] = task.spawn(function()
				local TimeLeft = RarityTimes[RarityName]

				while true do
					task.wait(1)
					TimeLeft -= 1
					if TimeLeft <= 0 then
						TimeLeft = RarityTimes[RarityName]
						local ChosenEgg = PickEggBasedRarity(RarityName)
						if ChosenEgg ~= nil and ChosenEgg.Chance > 0 then
							table.insert(self.EggQueue, ChosenEgg.Name)
						end
					end
					EggGui.Text = [[Guaranteed <b><font color="rgb(]]
						.. math.floor(Color.R * 255) .. ", "
						.. math.floor(Color.G * 255) .. ", "
						.. math.floor(Color.B * 255) .. [[)">]]
						.. RarityName
						.. [[ Egg</font></b> in: <b>]] .. FormatTime(TimeLeft) .. [[</b>]]
				end
			end)
		end
	end
end

function Plot:_loadPlotModel(PlotInfo, NoInit: boolean?)
	if not PlotInfo then return end
	local PlotCFrame = self.Plot.PrimaryPart.CFrame
	if PlotInfo.Name ~= self.CurrentPlotModel then
		local NewPlotModel = PlotsFolder:FindFirstChild(PlotInfo.Name)
		if NewPlotModel then
			NewPlotModel = NewPlotModel:Clone()
			NewPlotModel.Name = self.Plot.Name
			NewPlotModel:SetAttribute("Occupied", self.Player.UserId)
			
			self:SoftCleanup()
			
			if self.Character ~= nil then
				if self.Character:FindFirstChildWhichIsA("Humanoid") then
					self.Character:FindFirstChildWhichIsA("Humanoid"):UnequipTools()
				end
			end
			
			NewPlotModel:PivotTo(PlotCFrame)
			NewPlotModel.Parent = workspace.Plots

			self.Plot = NewPlotModel
			self.CurrentPlotModel = PlotInfo.Name
			
			if self.Character ~= nil then
				self.Character:PivotTo(PlotCFrame)
			end
			
			self:InitNewModel()
			
			return "👍 Successfully switched zoos!"
		end
		return "❌ An error occured while switching zoos!"
	else
		if NoInit == nil or NoInit == false then
			self:InitNewModel()
		end
		return "🤔 Looks like you are already using that zoo."
	end
end

function Plot:_loadPlotInfo(PlotInfo)
	if not PlotInfo then return end
	self.MaxPets = PlotInfo.MaxPets
	self.PlotInfo = PlotInfo
	PetAction:FireClient(self.Player, "info", self.NumPets, self.MaxPets)
	self:RestoreMultipliers()
end

function Plot:LoadPlotModelWithData(PlotInfo, NoInit: boolean?)
	if not PlotInfo then return end
	
	local Message = self:_loadPlotModel(PlotInfo, NoInit)
	self:_loadPlotInfo(PlotInfo)
	if DataService.Profiles[self.Player] then
		DataService.Profiles[self.Player].Data.PlotData.CurrentPlot = PlotInfo.Name
	end
	UnlockZoo:FireClient(self.Player, "updateUsageGui", PlotInfo.Name)
	return Message
end

function Plot:Init()
	self.Character = self.Player.Character or self.Player.CharacterAdded:Wait()
	self.Character:PivotTo(self.Plot.PrimaryPart.CFrame)

	self.CharacterAdded = self.Player.CharacterAdded:Connect(function()
		self.Character:PivotTo(self.Plot.PrimaryPart.CFrame)
	end)
	
	-- Setup conveyor
	self.Conveyor = ConveyorClass.new(self.Player, self.Plot, self.Plot.Conveyor.PrimaryPart)
	self.Conveyor:Init()
	
	-- Fix the info stuff for player pets
	PetAction:FireClient(self.Player, "info", self.NumPets, self.MaxPets)
	if DataService.Profiles[self.Player] then
		UnlockZoo:FireClient(self.Player, "updateAll", DataService.Profiles[self.Player].Data.OwnedZoos)
	end
	
	-- Load plot data
	self:RestoreEggs()
	self:RestorePets()
	self:RestoreIndex()
	self:RestoreCash()
	self:RestoreMultipliers()
	
	-- Load actions
	self:_loadActions()
end

function Plot:InitNewModel()
	self.Character = self.Player.Character or self.Player.CharacterAdded:Wait()
	self.Character:PivotTo(self.Plot.PrimaryPart.CFrame)

	self.CharacterAdded = self.Player.CharacterAdded:Connect(function()
		self.Character:PivotTo(self.Plot.PrimaryPart.CFrame)
	end)

	-- Setup conveyor
	self.Conveyor = ConveyorClass.new(self.Player, self.Plot, self.Plot.Conveyor.PrimaryPart)
	self.Conveyor:Init()

	-- Fix the info stuff for player pets
	PetAction:FireClient(self.Player, "info", self.NumPets, self.MaxPets)
	if DataService.Profiles[self.Player] then
		UnlockZoo:FireClient(self.Player, "updateAll", DataService.Profiles[self.Player].Data.OwnedZoos)
	end

	-- Load plot data
	self:RestoreEggs()
	self:RestorePets()
	self:RestoreMultipliers()

	-- Load actions
	self:_loadActions()
end

function Plot:SetLuckMultiplier(Multiplier: number)
	self.LuckMultiplier = self.PlotInfo.LuckMultiplier * Multiplier
	self.Plot.ConveyorLuckCounter:FindFirstChildWhichIsA("SurfaceGui", true).Amount.Text = `x{self.LuckMultiplier}`
end

function Plot:SetEggLuckMultiplier(Multiplier: number)
	self.EggLuckMultiplier = self.PlotInfo.EggLuckMultiplier * Multiplier
	self.Plot.EggLuckCounter:FindFirstChildWhichIsA("SurfaceGui", true).Amount.Text = `x{self.EggLuckMultiplier}`
end

function Plot:SetMoneyMultiplier(Multiplier: number)
	self.MoneyMultiplier = self.PlotInfo.MoneyMultiplier * Multiplier
end

function Plot:RestoreMultipliers()
	local Profile = DataService.Profiles[self.Player]
	if not Profile then return end

	-- Set multipliers
	self.MoneyMultiplier = self.PlotInfo.MoneyMultiplier
	self.LuckMultiplier = self.PlotInfo.LuckMultiplier
	self.EggLuckMultiplier = self.PlotInfo.EggLuckMultiplier
	
	-- Add robux multipliers
	self.MoneyMultiplier *= Profile.Data.MoneyMultiplier or 1
	self.LuckMultiplier *= Profile.Data.LuckMultiplier or 1
	self.EggLuckMultiplier *= Profile.Data.EggLuckMultiplier or 1
	
	-- Set text
	self.Plot.ConveyorLuckCounter:FindFirstChildWhichIsA("SurfaceGui", true).Amount.Text = `x{self.LuckMultiplier}`
	self.Plot.EggLuckCounter:FindFirstChildWhichIsA("SurfaceGui", true).Amount.Text = `x{self.EggLuckMultiplier}`

	-- Update
	UpdateMultiplier:FireClient(self.Player, "money", Profile.Data.MoneyMultiplier)
	UpdateMultiplier:FireClient(self.Player, "luck", Profile.Data.LuckMultiplier)
end


function Plot:RestoreEggs()
	local Profile = DataService.Profiles[self.Player]
	if not Profile then return end

	local PlotData = Profile.Data.PlotData
	local LastLeaveTime = PlotData.LastLeaveTime or os.time()
	local OfflineDuration = os.time() - LastLeaveTime
	local HatchSpeed = Profile.Data.EggHatchSpeed or 1
	
	-- Load saved eggs
	for _, EggEntry in ipairs(PlotData.PlacedEggs) do
		local EggConfig = Eggs[EggEntry.EggName]
		if EggConfig then
			local RelativePos = Vector3.new(
				EggEntry.CFrame.Position.X,
				EggEntry.CFrame.Position.Y,
				EggEntry.CFrame.Position.Z
			)

			local EggModel = EggConfig.Model:Clone()
			EggModel:PivotTo(self.Plot.PrimaryPart.CFrame * CFrame.new(RelativePos))
			EggModel.Parent = self.Plot.PlacedEggs
			EggModel:SetAttribute("Id", EggEntry.Id)

			local Egg = EggClass.new(self.Player, EggEntry.EggName, EggModel, self, EggEntry.Id)
			Egg:CreateTimer()
			
			-- Adjust hatch offline timer
			local BaseTimeLeft = EggEntry.TimeLeft or EggConfig.HatchTime
			local AdjustedTimeLeft = math.max(0, (BaseTimeLeft - OfflineDuration) / HatchSpeed)
			Egg:SetTime(AdjustedTimeLeft)
			Egg:StartTimer()

			self.PlacedEggs[EggEntry.Id] = Egg
		end
	end
end

function Plot:RestorePets()
	local Profile = DataService.Profiles[self.Player]
	if not Profile then return end

	for _, PetEntry in ipairs(Profile.Data.PlotData.PlacedPets) do
		local PetConfig = Pets[PetEntry.Type]
		if PetConfig then
			local PetFolder: Folder = PetsFolder:FindFirstChild(PetEntry.Mutation)
			if PetFolder == nil then
				PetFolder = PetsFolder.Normal :: Folder
			end

			local PetModel: Model = PetFolder:FindFirstChild(PetEntry.Type):Clone()
			--local PetModel = PetConfig.Model:Clone()
			if PetModel then
				PetModel:SetAttribute("Id", PetEntry.Id)
				PetModel:SetAttribute("Type", PetEntry.Type)
				PetModel:SetAttribute("Scale", PetEntry.Scale)
				PetModel:SetAttribute("Mutation", PetEntry.Mutation)
				PetModel:ScaleTo(PetEntry.Scale)
				
				-- Optional: load pet position
				local RelativePos = Vector3.new(
					PetEntry.CFrame.Position.X,
					PetEntry.CFrame.Position.Y,
					PetEntry.CFrame.Position.Z
				)

				PetModel:PivotTo(self.Plot.PrimaryPart.CFrame * CFrame.new(RelativePos))
				PetModel.Parent = self.Plot.PlacedPets

				local Pet = PetClass.new(self.Player, self, PetModel, PetEntry.Mutation)
				
				-- Load pet data
				self.PlacedPets[PetEntry.Id] = {
					Id = PetEntry.Id,
					Pet = Pet,
					Scale = PetEntry.Scale,
					Mutation = PetEntry.Mutation,
					IncomeLoop = task.spawn(function()
						while true do
							task.wait(1)
							if self.Currency then
								self.Currency += math.round(PetEntry.Scale * PetConfig.Income * Mutations.Pets[PetEntry.Mutation].IncomeMultiplier)
							end
						end
					end),
					MovementLoop = task.spawn(function()
						while true do
							if not Pet.Moving then
								task.wait(math.random(3, 10))
								Pet:Wander()
							end
							task.wait()
						end
					end)
				}
				self.NumPets += 1
				
				-- Client side rendering call
				PetAction:FireClient(
					self.Player,
					"update",
					self.NumPets,
					self.MaxPets,
					PetConfig,
					PetEntry.Mutation,
					PetEntry.Scale,
					PetEntry.Scale * PetConfig.Income * Mutations.Pets[PetEntry.Mutation].IncomeMultiplier,
					PetEntry.Id
				)
			end
		end
	end
end

function Plot:RestoreIndex()
	local Profile = DataService.Profiles[self.Player]
	if not Profile then return end

	IndexPet:FireClient(self.Player, "load", Profile.Data.Index)
end

function Plot:RestoreCash()
	local Profile = DataService.Profiles[self.Player]
	if not Profile then return end

	local PlotData = Profile.Data.PlotData
	local StoredCash = PlotData.Cash or 0
	local OfflineCash = 0
	
	-- Load offline earnings
	if PlotData.LastLeaveTime then
		local TimeAway = os.time() - PlotData.LastLeaveTime
		local HoursAway = TimeAway / 3600
		local TotalIncomePerSecond = 0

		for _, PetData in ipairs(PlotData.PlacedPets or {}) do
			local PetConfig = Pets[PetData.Type]
			if PetConfig then
				TotalIncomePerSecond += PetConfig.Income
			end
		end

		local BaseRate = 0.30
		local StartDropHour = 2
		local EndDropHour = 5
		local StopHour = 8
		local Rate

		if HoursAway <= StartDropHour then
			Rate = BaseRate
		elseif HoursAway >= StopHour then
			Rate = 0
		else
			Rate = BaseRate / 3
		end

		local EstimatedEarnings = TotalIncomePerSecond * TimeAway
		OfflineCash = math.floor(EstimatedEarnings * Rate)
		PlotData.LastLeaveTime = nil
	end

	self.Currency = math.round(StoredCash)
	self.CurrencyOffline = math.round(OfflineCash)

	PlotData.Cash = self.Currency

	-- Update guis
	local Billboard = self.Plot.CollectCash:FindFirstChildWhichIsA("BillboardGui")
	if OfflineCash > 0 then
		if Profile.Data.MoneyMultiplier > 1 then
			self.Plot.CollectCash.BillboardGui.Offline.Text = `(Earned ${Abbreviate(self.CurrencyOffline, 1)} offline (x{Profile.Data.MoneyMultiplier}))`
		else
			self.Plot.CollectCash.BillboardGui.Offline.Text = `(Earned ${Abbreviate(self.CurrencyOffline, 1)} offline)`
		end
		Billboard.Offline.Visible = true
	else
		Billboard.Offline.Visible = false
	end
end

function Plot:SoftCleanup()
	pcall(function()
		-- Cancel loops
		if self.CurrencyUpdate then task.cancel(self.CurrencyUpdate) self.CurrencyUpdate = nil end
		if self.EggSpawn then task.cancel(self.EggSpawn) self.EggSpawn = nil end

		if self.GuaranteedEggSpawners then
			for Rarity, Thread in pairs(self.GuaranteedEggSpawners) do
				task.cancel(Thread)
				self.GuaranteedEggSpawners[Rarity] = nil
			end
			self.GuaranteedEggSpawners = nil
		end

		-- Conveyor
		if self.Conveyor then
			self.Conveyor:Destroy()
			self.Conveyor = nil
		end

		-- Disconnect signals
		local Disconnects = {
			"CharacterAdded",
			"CollectCash",
			"SkipHatchBindable",
			"AddMultiplierBindable",
			"AddEggLuckBindable",
			"SpawnLegendaryEgg",
			"SpawnMythicalEgg",
			"SpawnEggBindable",
		}
		for _, Key in ipairs(Disconnects) do
			if self[Key] then
				self[Key]:Disconnect()
				self[Key] = nil
			end
		end

		-- Stop pet tasks and destroy pet objects
		for Id, PetData in pairs(self.PlacedPets) do
			if PetData.IncomeLoop then
				task.cancel(PetData.IncomeLoop)
				PetData.IncomeLoop = nil
			end
			if PetData.MovementLoop then
				task.cancel(PetData.MovementLoop)
				PetData.MovementLoop = nil
			end
			if PetData.Pet then
				PetData.Pet:Destroy()
				PetData.Pet = nil
			end
			self.PlacedPets[Id] = nil
		end
		table.clear(self.PlacedPets)
		self.NumPets = 0

		-- Destroy egg objects
		for Id, Egg in pairs(self.PlacedEggs) do
			Egg:Destroy()
			self.PlacedEggs[Id] = nil
		end
		table.clear(self.PlacedEggs)

		-- Reset plot visuals
		self.Currency = 0
		self.CurrencyOffline = 0
		
		if self.Plot then
			local Collect = self.Plot:FindFirstChild("CollectCash")
			if Collect then
				local Billboard = Collect:FindFirstChildWhichIsA("BillboardGui")
				if Billboard then
					Billboard.Money.Text = "$0"
					if Billboard:FindFirstChild("Offline") then
						Billboard.Offline.Visible = false
					end
				end
			end

			local Info = self.Plot:FindFirstChild("PlayerInfo")
			if Info then
				local Gui = Info:FindFirstChildWhichIsA("SurfaceGui")
				if Gui and Gui:FindFirstChild("Player") then
					Gui.Player.Text = "Nobody's"
				end
			end

			self.Plot:Destroy()
		end
		self.Plot = nil
	end)
end

function Plot:Destroy()
	-- Fix plot model
	self:_loadPlotModel(Plots.Normal, true)
	
	-- Stop conveyor and currency updates
	if self.Conveyor then
		self.Conveyor:Destroy()
		self.Conveyor = nil
	end

	if self.CurrencyUpdate then
		task.cancel(self.CurrencyUpdate)
		self.CurrencyUpdate = nil
	end

	if self.EggSpawn then
		task.cancel(self.EggSpawn)
		self.EggSpawn = nil
	end

	-- Stop guaranteed egg spawners
	if self.GuaranteedEggSpawners then
		for Rarity, Thread in pairs(self.GuaranteedEggSpawners) do
			task.cancel(Thread)
			self.GuaranteedEggSpawners[Rarity] = nil
		end
		self.GuaranteedEggSpawners = nil
	end

	-- Disconnect character added connection
	if self.CharacterAdded then
		self.CharacterAdded:Disconnect()
		self.CharacterAdded = nil
	end

	-- Disconnect collect cash
	if self.CollectCash then
		self.CollectCash:Disconnect()
		self.CollectCash = nil
	end

	-- Disconnect monetization bindables
	if self.SkipHatchBindable then
		self.SkipHatchBindable:Disconnect()
		self.SkipHatchBindable = nil
	end

	if self.AddMultiplierBindable then
		self.AddMultiplierBindable:Disconnect()
		self.AddMultiplierBindable = nil
	end

	if self.AddEggLuckBindable then
		self.AddEggLuckBindable:Disconnect()
		self.AddEggLuckBindable = nil
	end

	if self.SpawnLegendaryEgg then
		self.SpawnLegendaryEgg:Disconnect()
		self.SpawnLegendaryEgg = nil
	end

	if self.SpawnMythicalEgg then
		self.SpawnMythicalEgg:Disconnect()
		self.SpawnMythicalEgg = nil
	end

	if self.SpawnEggBindable then
		self.SpawnEggBindable:Disconnect()
		self.SpawnEggBindable = nil
	end

	-- Stop pet tasks and destroy pet objects
	for Id, PetData in pairs(self.PlacedPets) do
		if PetData.IncomeLoop then
			task.cancel(PetData.IncomeLoop)
			PetData.IncomeLoop = nil
		end
		if PetData.MovementLoop then
			task.cancel(PetData.MovementLoop)
			PetData.MovementLoop = nil
		end
		if PetData.Pet then
			PetData.Pet:Destroy()
			PetData.Pet = nil
		end
		self.PlacedPets[Id] = nil
	end
	self.PlacedPets = nil

	-- Destroy egg objects
	for Id, Egg in pairs(self.PlacedEggs) do
		Egg:Destroy()
		self.PlacedEggs[Id] = nil
	end
	self.PlacedEggs = nil

	-- Cleanup data
	self.EggQueue = nil
	self.Potions = nil
	self.MoneyMultiplier = nil
	self.LuckMultiplier = nil
	self.EggLuckMultiplier = nil
	self.NumPets = nil
	self.MaxPets = nil

	self.Currency = 0
	self.CurrencyOffline = 0

	-- Reset Gui
	if self.Plot and self.Plot:FindFirstChild("CollectCash") then
		local Billboard = self.Plot.CollectCash:FindFirstChildWhichIsA("BillboardGui")
		if Billboard then
			Billboard.Money.Text = "$0"
			if Billboard:FindFirstChild("Offline") then
				Billboard.Offline.Visible = false
			end
		end
	end

	if self.Plot and self.Plot:FindFirstChild("PlayerInfo") then
		local Gui = self.Plot.PlayerInfo:FindFirstChildWhichIsA("SurfaceGui")
		if Gui and Gui:FindFirstChild("Player") then
			Gui.Player.Text = "Nobody's"
		end
	end
	
	if self.Plot and self.Plot.PrimaryPart and self.Plot.PrimaryPart:FindFirstChild("Marker") then
		local Gui = self.Plot.PrimaryPart:FindFirstChild("Marker")
		if Gui then
			Gui.Title.Text = [[<b>Nobody</b>'s Zoo]]
		end
	end

	-- Create nils
	self.Player = nil
	self.Plot = nil
	self.Character = nil
	
	table.clear(self)
end

return Plot
