local Players = game:GetService("Players") -- We'll need the Players service for most of the stuff involving other players
local DataStoreService = game:GetService("DataStoreService") -- Lets go ahead and grab the DataStoreService so we can interact with the shop's datastore(s)
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- We'll need ReplicatedStorage for communication with the client
local StoreDataStore = nil; -- This will be the DataStore that will hold all of the shop items
local UsersDataStore = nil; -- This will hold the Users registry, every user will contain a number that is the point count, and a table of the items they have bought.
local ServerComm = ReplicatedStorage.ServerComm; -- This is the remote to communicate with the shop on from the client to the server
local ClientComm = ReplicatedStorage.ClientComm; -- This is the remote to communicate with the shop on from the server to the client
local BadgeService = game:GetService("BadgeService") -- We'll need the BadgeService in order to actually award the badge for the first time join

-- Default Items, these will be written to the DataStore if there are no items in it yet

local DefaultItems = {
	[1] = {
		Price = 100,
		Description = "This is a test sample item, it does absolutely nothing.",
		Name = "Sample item"
	},
	[2] = {
		Price = 550,
		Description = "Be able to walk very fast",
		Name = "Speed walk"
	}
}

local function InitStoreDataStore()
	StoreDataStore = DataStoreService:GetDataStore("Store");
	UsersDataStore = DataStoreService:GetDataStore("Users");
	local Success, Items = pcall(function()
		return StoreDataStore:GetAsync("Items")
	end)
	-- If the Items key doesn't exist yet, we'll go ahead and write the default items to it
	if(Success and not Items) then
		local SetSuccess, SetErr = pcall(function()
			StoreDataStore:SetAsync("Items", DefaultItems)
		end)
		if(not SetSuccess) then
		end
	end
end

-- Begin Item API --
local StoreItems = {};

--[[
	StoreItems:GetItemById() will fetch the Items table from the StoreDataStore
	wrapped in a pcall, if it succeeds, and return the item by it's Id, if not
	then just return nil
]]
function StoreItems:GetItemById(Id: number)
	local Items = StoreItems:GetItems()
	if(Items) then
		return Items[Id]
	end
	return nil
end

--[[
	StoreItems:GetItems() will fetch and return the items table
	from the StoreDataStore
]]
function StoreItems:GetItems()
	local Success, Items = pcall(function()
		return StoreDataStore:GetAsync("Items")
	end)
	if(Success) then
		return Items
	end
	return nil
end

-- End Item API

-- Begin user handling --

--[[
	The User system will consist of a User's ID as the key,
	and a table of Points and Items as the value. We will
	cache each user in the game when they join.
]]

--[[
	These are the possible results that BuyItem can return,
	we keep them here and on the client so we can handle
	each case accordingly without magic numbers everywhere.
]]
local ERRCODES = {
	OWNED = 1,
	DONTEXIST = 2,
	INSUFFICIENTFUND = 3,	
	SUCCESS = 4
}

local UserSession = {}
UserSession["__index"] = UserSession

--[[
	UserSession.New will create a new UserSession object table and return it
]]
function UserSession.New(Player: Player, Data: {Points: number, Items: {number}})
	local UserId = tostring(Player.UserId)
	local self = setmetatable({}, UserSession)
	self.Player = Player
	self.Points = Data.Points
	self.Items = Data.Items
	-- We store the key as a string since DataStores require string keys
	self.UserDataStoreKey = UserId
	return self
end

--[[
	UserSession:SetBalance() will set the cached balance
	into the UserSession object at the Points field
]]
function UserSession:SetBalance(Amount: number)
	self.Points = Amount
end

--[[
	UserSession:GetBalance() will return the cached balance
	from the UserSession object.
]]
function UserSession:GetBalance()
	return self.Points
end

--[[
	UserSession:UpdateClientStats() sends the new balance/owned items to the client
	via the RemoteFunction ServerComm
]]
function UserSession:UpdateClientStats()
	ClientComm:FireClient(self.Player, {CmdName = "UpdateBalance", Value = self.Points});
	ClientComm:FireClient(self.Player, {CmdName = "UpdateOwnedItems", Value = self.Items})
end

--[[
	UserSession:SaveData() will save the cached data to the UsersDataStore,
	we will use pcall and UpdateAsync to update the data, if it succeeds then 
	the function returns true, if it fails we will return false
]]
function UserSession:SaveData()
	local Success, Result = pcall(function()
		return UsersDataStore:UpdateAsync(self.UserDataStoreKey, function(Data)
			-- Just incase there is no original data entry, we will write the template one
			Data = Data or {
				Points = 1000,
				Items = {}
			}

			Data.Points = self.Points
			Data.Items = self.Items

			return Data
		end)
	end)
	if(Success) then
		return true
	end
	return false
end

--[[
	UserSession:OwnsItem() indexes the UserSession's Items table,
	and uses table.find to see whether or not an object is returned,
	if so then return the table.find result ~= nil, if it is ~= nil,
	then it will return true, if not then it will return false.
]]
function UserSession:OwnsItem(ItemID: number)
	return table.find(self.Items, ItemID) ~= nil
end

--[[
	UserSession:BuyItem() will run through a series of checks to make sure
	the purchase is valid, and if it is then we'll subtract the owed amount
	of points, then insert the item into the Items table, and notify the client 
	of the changes. The function will return one of the error codes defined in
	the ERRCODES table
]]
function UserSession:BuyItem(ItemID: number)
	if(self:OwnsItem(ItemID)) then
		return ERRCODES.OWNED
	end
	local Item = StoreItems:GetItemById(ItemID)
	if(not Item) then
		return ERRCODES.DONTEXIST
	end
	if(self.Points < Item.Price) then
		return ERRCODES.INSUFFICIENTFUND
	end
	-- The actual purchase logic
	table.insert(self.Items, ItemID)
	self.Points -= Item.Price
	-- Update Player client status
	self:UpdateClientStats()
	-- Send perks to client after purchase
	self:SendPerks()
	
	return ERRCODES.SUCCESS
end

--[[
	UserSession:SendPerks() get player's owned items,
	and if they own a specific item that is handled,
	it will send the the perks to the client.
]]
function UserSession:SendPerks()
	-- 2 is the Speed tool ID in the store
	if(not table.find(self.Items, 2)) then
		return
	end

	local Backpack = self.Player:FindFirstChild("Backpack")

	if(not Backpack) then
		return
	end

	if(Backpack:FindFirstChild("Speed tool")) then
		return
	end

	script["Speed tool"]:Clone().Parent = Backpack
end
-- End user handling

--[[
	This will be the cache of the UserSession objects, 
	every time a player joins, PlayerAdded will add 
	a new UserSession object to this table, and when 
	a player leaves, PlayerRemoved will remove it 
	from the table.
]]
local UserSessionCache = {} 

--[[
	CreateUserEntry() will check if the player already has a DataStore entry,
	if they don't then we'll create one with the default Points and Items values
	and return true so the caller knows this is a first time join. If they already
	have an entry, or the DataStore call fails, we return false.
]]
local function CreateUserEntry(Player: Player) 
	local UserId = tostring(Player.UserId)
	local Success, User = pcall(function()
		return UsersDataStore:GetAsync(UserId)
	end)
	if(Success and not User) then
		local UserData = {
			Points = 1000,
			Items = {}
		}
		local SetSuccess, SetErr = pcall(function()
			UsersDataStore:SetAsync(UserId, UserData)
		end)
		if(not SetSuccess) then
			return false
		end
		return true
	end
	return false
end

-- Begin Entrypoint --
local function Init()
	InitStoreDataStore() -- Ensure the StoreDataStore and UsersDataStore are correctly initialized before we do anything else
	local function PlayerAdded(Player: Player) 
		local UserId = tostring(Player.UserId)
		local UserDataStoreCreated = CreateUserEntry(Player)
		local SessionObject = nil
		-- If the DataStore was just created, this is their first time joining so we award the badge
		if(UserDataStoreCreated) then
			BadgeService:AwardBadgeAsync(tonumber(UserId), 2920507214602345) -- Since the UserId was a string initially, lets convert it to a number
		end
		local Success, Data = pcall(function()
			return UsersDataStore:GetAsync(UserId)
		end)
		if(Success and Data) then
			SessionObject = UserSession.New(Player, Data)
			-- We use tostring here because DataStore keys have to be strings as it is defined that way
			UserSessionCache[UserId] = SessionObject
		end

		-- Send the initial perks that they own (if any)
		SessionObject:SendPerks()

		--[[
			Whenever a player has a new character assigned (e.g respawn, or initial character)
			we'll send them their perks
		]]

		Player.CharacterAdded:Connect(function()
			SessionObject:SendPerks()
		end)
	end

	-- Every time a Player leaves, we obviously need to remove their UserSession object from the cache
	local function PlayerRemoving(Player: Player)
		local UserId = tostring(Player.UserId)
		if(UserSessionCache[UserId]) then
			UserSessionCache[UserId]:SaveData()
			UserSessionCache[UserId] = nil
		end
	end

	-- This is the communication between the client and the server
	ServerComm.OnServerInvoke = function(PlayerObj: Player, Data: table)
		local UserId = tostring(PlayerObj.UserId)
		local CmdName = Data.CmdName
		-- We will index the UserSessionCache with the key to get the UserSession object, however we will use a timeout just incase the session fails to load
		local Session = UserSessionCache[UserId]

		local Timeout = 5
		local Start = tick()

		-- If the session is not found, we will wait until it is or the timeout is reached
		while(not Session and tick() - Start < Timeout) do
			task.wait(0.5)
			Session = UserSessionCache[UserId]
		end

		if(not Session) then
			PlayerObj:Kick("Failed to initialize the session!") -- Kick the player if the session did not load correctly
			return nil
		end
		if(CmdName == "FetchItems") then
			return StoreItems:GetItems()
		elseif(CmdName == "FetchOwnedItems") then
			return Session.Items
		elseif(CmdName == "FetchPoints") then
			return Session.Points
		elseif(CmdName == "PurchaseItem") then
			return Session:BuyItem(Data["Value"])
		else
			return nil
		end
	end

	--[[
		We will use BindToClose to ensure that we save all player data
		when the server shuts down, just incase they weren't saved
		when they left
	]]
	game:BindToClose(function()
		for I, V in pairs(UserSessionCache) do
			V:SaveData()
		end
	end)

	Players.PlayerAdded:Connect(PlayerAdded)
	Players.PlayerRemoving:Connect(PlayerRemoving)

	-- Just incase a Player that was already here didn't get the check done, we will do it on them directly
	for I,V in pairs(Players:GetPlayers()) do
		PlayerAdded(V)
	end
	warn("Server init done!")
end

Init()
-- End Entrypoint
