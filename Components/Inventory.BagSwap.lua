-- Bagshui Inventory Prototype: Bag Swapping
--
-- The game refuses to replace an equipped bag that still has items in it, failing with
-- ERR_DESTROY_NONEMPTY_BAG. This does the tedious part automatically:
-- 1. Move everything out of the old bag into free slots elsewhere.
-- 2. Equip the new bag.
-- 3. Move the items into the new bag, keeping their slot numbers where possible.
--
-- A swap is triggered in two ways (methodology of the error trigger is based on Swapper
-- by Gabriele Cimolino, https://github.com/cubenicke/Swapper):
-- * The game's error, which covers every way of equipping a bag. When it fires, the new
--   bag and the bag slot are both still locked, which is how we identify them.
-- * Clicking a bag slot while holding a bag picked up from a Bagshui window. This has to
--   be caught before the click reaches `PutItemInBag()`, which may put the new bag
--   *inside* the old one if there's room.
--
-- The game state is read live instead of from the inventory cache, since the cache lags
-- behind while items are moving and can hold another character's data.

Bagshui:AddComponent(function()
local Inventory = Bagshui.prototypes.Inventory


-- Seconds between steps. Same pacing as `Inventory:ProcessRestackQueue()`.
local STEP_DELAY = 0.15
-- Seconds to wait for a move to take effect before attempting it again.
local RETRY_DELAY = 1
-- Attempts before giving up on a single move.
local MAX_ATTEMPTS = 3
-- Seconds without progress before giving up on the swap (the player may be holding something).
local STALL_TIMEOUT = 15
-- Seconds to let the bag slot settle after equipping, since its contents
-- can update slightly after the locks are released.
local EQUIP_SETTLE_TIME = 0.5


--- Is there an item in this slot?
---@param bagNum number
---@param slotNum number
---@return boolean
local function SlotOccupied(bagNum, slotNum)
	return _G.GetContainerItemInfo(bagNum, slotNum) ~= nil
end


--- Is the item in this slot locked?
---@param bagNum number
---@param slotNum number
---@return any locked
local function SlotLocked(bagNum, slotNum)
	local _, _, locked = _G.GetContainerItemInfo(bagNum, slotNum)
	return locked
end


--- Get `GetItemInfo()` properties from an item link.
---@param itemLink string?
---@return string? subclass
---@return string? equipLocation
local function GetLinkInfo(itemLink)
	local itemString = BsItemInfo:ParseItemLink(itemLink)
	if not itemString then
		return
	end
	local _, _, _, _, _, subclass, _, equipLocation = _G.GetItemInfo(itemString)
	return subclass, equipLocation
end


--- Is the item in this slot a bag that can be equipped?
---@param bagNum number
---@param slotNum number
---@return boolean
local function SlotHasBag(bagNum, slotNum)
	local _, equipLocation = GetLinkInfo(_G.GetContainerItemLink(bagNum, slotNum))
	return equipLocation == "INVTYPE_BAG" or equipLocation == "INVTYPE_QUIVER"
end


--- Is the bind-on-equip confirmation waiting for an answer?
---@return boolean
local function EquipConfirmationVisible()
	return (_G.StaticPopup_Visible("EQUIP_BIND") or _G.StaticPopup_Visible("AUTOEQUIP_BIND")) and true or false
end


--- Call a function with all modifier keys reporting as up, since some addons hook the
--- item functions and change their behavior when a modifier is pressed.
--- (See the same safeguard in `Inventory:ProcessRestackQueue()`.)
---@param func function
---@param arg1 any?
---@param arg2 any?
---@param arg3 any?
---@param arg4 any?
local function WithoutModifiers(func, arg1, arg2, arg3, arg4)
	local oldIsAltKeyDown = _G.IsAltKeyDown
	local oldIsControlKeyDown = _G.IsControlKeyDown
	local oldIsShiftKeyDown = _G.IsShiftKeyDown
	_G.IsAltKeyDown = BsUtil.ReturnFalse
	_G.IsControlKeyDown = BsUtil.ReturnFalse
	_G.IsShiftKeyDown = BsUtil.ReturnFalse
	func(arg1, arg2, arg3, arg4)
	_G.IsAltKeyDown = oldIsAltKeyDown
	_G.IsControlKeyDown = oldIsControlKeyDown
	_G.IsShiftKeyDown = oldIsShiftKeyDown
end


local function MoveItem(sourceBagNum, sourceSlotNum, targetBagNum, targetSlotNum)
	_G.PickupContainerItem(sourceBagNum, sourceSlotNum)
	_G.PickupContainerItem(targetBagNum, targetSlotNum)
end


local function EquipItem(bagNum, slotNum, inventorySlotId)
	_G.PickupContainerItem(bagNum, slotNum)
	_G.EquipCursorItem(inventorySlotId)
end



--- Get the subclass of the bag in a container ("Bag", "Herb Bag", etc).
---@param bagNum number Container owned by this class.
---@return string? bagType
function Inventory:BagSwap_GetBagType(bagNum)
	if bagNum == self.primaryContainer.id then
		return BsGameInfo.itemSubclasses["Container"]["Bag"]
	end
	return (GetLinkInfo(_G.GetInventoryItemLink("player", _G.ContainerIDToInventoryID(bagNum))))
end



--- Get this class and any other classes whose slots can be used during a swap.
--- (The Bank can hold items for the Bags and vice versa when the player is at the bank.)
---@return table[] inventoryClasses
function Inventory:BagSwap_GetStorageClasses()
	local classes = { self }
	if type(self.bagSwappingSupplementalStorage) == "table" then
		for _, inventoryClassName in ipairs(self.bagSwappingSupplementalStorage) do
			local supplemental = Bagshui.components[inventoryClassName]
			if supplemental and supplemental.online then
				table.insert(classes, supplemental)
			end
		end
	end
	return classes
end



--- Find every free slot that can temporarily hold items from the given bag. Profession bags
--- aren't used because there's no way to know what they accept without trying it.
---@param excludeBagNum number Bag being swapped.
---@return table[] freeSlots Array of `{ bagNum, slotNum }`.
function Inventory:BagSwap_GetFreeSlots(excludeBagNum)
	local freeSlots = {}
	for _, inventoryClass in ipairs(self:BagSwap_GetStorageClasses()) do
		for _, bagNum in ipairs(inventoryClass.containerIds) do
			if
				bagNum ~= excludeBagNum
				and inventoryClass:BagSwap_GetBagType(bagNum) == BsGameInfo.itemSubclasses["Container"]["Bag"]
			then
				for slotNum = 1, _G.GetContainerNumSlots(bagNum) do
					if not SlotOccupied(bagNum, slotNum) then
						table.insert(freeSlots, { bagNum = bagNum, slotNum = slotNum })
					end
				end
			end
		end
	end
	return freeSlots
end



--- Does the given bag have any items in it?
---@param bagNum number
---@return boolean
local function BagHasItems(bagNum)
	for slotNum = 1, _G.GetContainerNumSlots(bagNum) do
		if SlotOccupied(bagNum, slotNum) then
			return true
		end
	end
	return false
end



--- Begin swapping a bag, or explain why it isn't possible.
---@param newBagNum number Container holding the new bag.
---@param newSlotNum number Slot holding the new bag.
---@param bagNum number Container owned by this class whose bag is being replaced.
function Inventory:BagSwap_Start(newBagNum, newSlotNum, bagNum)
	local freeSlots = self:BagSwap_GetFreeSlots(bagNum)

	-- Plan all moves up front.
	local moves = {}
	local slotsNeeded = 0
	for slotNum = 1, _G.GetContainerNumSlots(bagNum) do
		if SlotOccupied(bagNum, slotNum) then
			local freeSlot = freeSlots[table.getn(moves) + 1]
			if freeSlot then
				local isNewBag = (bagNum == newBagNum and slotNum == newSlotNum)
				table.insert(moves, {
					sourceBagNum = bagNum,
					sourceSlotNum = slotNum,
					targetBagNum = freeSlot.bagNum,
					targetSlotNum = freeSlot.slotNum,
					isNewBag = isNewBag,
				})
				-- The new bag is inside the one it's replacing, so
				-- it has to be equipped from where it's moved to.
				if isNewBag then
					newBagNum = freeSlot.bagNum
					newSlotNum = freeSlot.slotNum
				end
			else
				slotsNeeded = slotsNeeded + 1
			end
		end
	end

	if slotsNeeded > 0 then
		Bagshui:ShowErrorMessage(string.format(L.Bag_SlotsNeededToSwap, slotsNeeded), self.inventoryType)
		return
	end

	-- These will be recalculated from scratch, and a stale value would make the
	-- cache think that bags have been moved between slots (see `Bagshui:PickupInventoryItem()`).
	Bagshui.cursorBagSlotNum = nil
	Bagshui.pickedUpBagSlotNum = nil
	Bagshui.putDownBagSlotNum = nil

	Bagshui.bagSwapActive = true
	self.bagSwap = {
		bagNum = bagNum,
		inventorySlotId = _G.ContainerIDToInventoryID(bagNum),
		oldBagType = self:BagSwap_GetBagType(bagNum),
		newBagNum = newBagNum,
		newSlotNum = newSlotNum,
		phase = "empty",
		moves = moves,
		moveIndex = 1,
		lastProgress = _G.GetTime(),
	}
	self:BagSwap_QueueStep()
end



function Inventory:BagSwap_QueueStep()
	Bagshui:QueueClassCallback(self, self.BagSwap_Step, STEP_DELAY)
end



--- Work on the current move in the swap.
---@param swap table `self.bagSwap`.
---@return "wait"|"next"|"failed"|"done" status
local function ProcessMove(swap)
	local move = swap.moves[swap.moveIndex]
	if not move then
		return "done"
	end

	local now = _G.GetTime()

	if
		SlotLocked(move.sourceBagNum, move.sourceSlotNum)
		or SlotLocked(move.targetBagNum, move.targetSlotNum)
		or (move.lastAttempt and now - move.lastAttempt < RETRY_DELAY and SlotOccupied(move.sourceBagNum, move.sourceSlotNum))
	then
		return "wait"
	end

	local sourceOccupied = SlotOccupied(move.sourceBagNum, move.sourceSlotNum)
	local targetOccupied = SlotOccupied(move.targetBagNum, move.targetSlotNum)

	if targetOccupied and not sourceOccupied then
		move.moved = true
		swap.moveIndex = swap.moveIndex + 1
		swap.lastProgress = now
		return "next"
	end

	-- Never drop onto an occupied slot, since that would swap
	-- the two items and scatter something that wasn't part of this.
	if targetOccupied or not sourceOccupied or (move.attempts or 0) >= MAX_ATTEMPTS then
		return "failed"
	end

	move.attempts = (move.attempts or 0) + 1
	move.lastAttempt = now
	swap.lastProgress = now
	WithoutModifiers(MoveItem, move.sourceBagNum, move.sourceSlotNum, move.targetBagNum, move.targetSlotNum)
	-- The game refused, so put the item back.
	if _G.CursorHasItem() then
		_G.ClearCursor()
	end
	return "wait"
end



--- Plan moving items into the new bag. Items that don't fit stay where they are.
---@param swap table `self.bagSwap`.
function Inventory:BagSwap_PlanFill(swap)
	local emptied = swap.moves
	swap.moves = {}
	swap.moveIndex = 1

	-- A profession bag won't accept most items, so they're left in their new locations.
	local bagType = self:BagSwap_GetBagType(swap.bagNum)
	if
		bagType ~= swap.oldBagType
		and bagType ~= BsGameInfo.itemSubclasses["Container"]["Bag"]
	then
		return
	end

	local numSlots = _G.GetContainerNumSlots(swap.bagNum)
	local taken = {}
	local displaced = {}

	-- First priority: keep items in the slots they came from.
	for _, move in ipairs(emptied) do
		if move.moved and not move.isNewBag then
			if move.sourceSlotNum <= numSlots and not SlotOccupied(swap.bagNum, move.sourceSlotNum) then
				taken[move.sourceSlotNum] = true
				table.insert(swap.moves, {
					sourceBagNum = move.targetBagNum,
					sourceSlotNum = move.targetSlotNum,
					targetBagNum = swap.bagNum,
					targetSlotNum = move.sourceSlotNum,
				})
			else
				table.insert(displaced, move)
			end
		end
	end

	-- Then use any free slots for the rest.
	local slotNum = 1
	for _, move in ipairs(displaced) do
		while slotNum <= numSlots and (taken[slotNum] or SlotOccupied(swap.bagNum, slotNum)) do
			slotNum = slotNum + 1
		end
		if slotNum > numSlots then
			break
		end
		taken[slotNum] = true
		table.insert(swap.moves, {
			sourceBagNum = move.targetBagNum,
			sourceSlotNum = move.targetSlotNum,
			targetBagNum = swap.bagNum,
			targetSlotNum = slotNum,
		})
	end
end



--- Go straight to putting things back after a problem during the swap.
---@param swap table `self.bagSwap`.
---@param errorMessage string
function Inventory:BagSwap_Fail(swap, errorMessage)
	Bagshui:ShowErrorMessage(errorMessage, self.inventoryType)
	swap.lastProgress = _G.GetTime()
	swap.phase = "planFill"
end



--- End the swap and bring the windows up to date.
function Inventory:BagSwap_Finish()
	self.bagSwap = nil
	Bagshui.bagSwapActive = false
	for _, inventoryClass in ipairs(self:BagSwap_GetStorageClasses()) do
		inventoryClass.cacheUpdateNeeded = true
		inventoryClass.forceResort = true
		inventoryClass:QueueUpdate()
	end
end



--- Advance the swap by one step. Calls itself until the swap is complete.
function Inventory:BagSwap_Step()
	local swap = self.bagSwap
	if not swap then
		return
	end

	local now = _G.GetTime()

	-- The player can take as long as they want to answer the bind confirmation.
	if EquipConfirmationVisible() then
		swap.lastProgress = now
		swap.equipTime = now
		self:BagSwap_QueueStep()
		return
	end

	-- Don't let a stuck swap run forever.
	if now - swap.lastProgress > STALL_TIMEOUT then
		if swap.phase == "fill" or swap.phase == "planFill" then
			Bagshui:ShowErrorMessage(L.Error_BagSwap_Stopped, self.inventoryType)
			self:BagSwap_Finish()
			return
		end
		self:BagSwap_Fail(swap, L.Error_BagSwap_EmptyOldFailed)
	end

	-- The player has picked something up, and starting a move
	-- now would take it from them. Wait for them to finish.
	if _G.CursorHasItem() then
		self:BagSwap_QueueStep()
		return
	end


	if swap.phase == "empty" then
		local status = ProcessMove(swap)
		if status == "done" then
			swap.phase = "equip"
		elseif status == "failed" then
			self:BagSwap_Fail(swap, L.Error_BagSwap_EmptyOldFailed)
		end


	elseif swap.phase == "equip" then
		if
			not _G.IsInventoryItemLocked(swap.inventorySlotId)
			and not SlotLocked(swap.newBagNum, swap.newSlotNum)
		then
			if BagHasItems(swap.bagNum) or not SlotHasBag(swap.newBagNum, swap.newSlotNum) then
				self:BagSwap_Fail(swap, L.Error_BagSwap_EquipNewFailed)
			else
				swap.oldBagLink = _G.GetInventoryItemLink("player", swap.inventorySlotId)
				swap.newBagLink = _G.GetContainerItemLink(swap.newBagNum, swap.newSlotNum)
				swap.equipTime = now
				swap.lastProgress = now
				swap.phase = "equipping"
				WithoutModifiers(EquipItem, swap.newBagNum, swap.newSlotNum, swap.inventorySlotId)
				-- The game refused, so put the bag back.
				if _G.CursorHasItem() and not EquipConfirmationVisible() then
					_G.ClearCursor()
				end
			end
		end


	elseif swap.phase == "equipping" then
		if
			now - swap.equipTime >= EQUIP_SETTLE_TIME
			and not _G.IsInventoryItemLocked(swap.inventorySlotId)
			and not SlotLocked(swap.newBagNum, swap.newSlotNum)
		then
			-- Identical bags have identical links, but then it doesn't matter either way.
			if
				swap.oldBagLink ~= swap.newBagLink
				and _G.GetInventoryItemLink("player", swap.inventorySlotId) ~= swap.newBagLink
			then
				Bagshui:ShowErrorMessage(L.Error_BagSwap_EquipNewFailed, self.inventoryType)
			end
			swap.lastProgress = now
			swap.phase = "planFill"
		end


	elseif swap.phase == "fill" then
		local status = ProcessMove(swap)
		if status == "done" then
			self:BagSwap_Finish()
			return
		elseif status == "failed" then
			-- Whatever can't go back is safe where it is, so carry on with the rest.
			swap.moveIndex = swap.moveIndex + 1
			swap.lastProgress = now
		end
	end


	-- This is outside the block above so that a failure in any phase starts refilling right away.
	if swap.phase == "planFill" then
		self:BagSwap_PlanFill(swap)
		swap.phase = "fill"
	end

	self:BagSwap_QueueStep()
end



--- Should a bag slot click be handled as a swap? Starts the swap if so.
--- Native bag replacement is fine when the old bag is empty, so that's left alone.
---@param bagNum number? Container whose bag slot was clicked.
---@return boolean handled `true` when the click should go no further.
function Inventory:BagSwap_TryFromCursor(bagNum)
	local item = Bagshui:GetCursorItem()
	if
		not item
		or not bagNum
		or Bagshui.bagSwapActive
		or not self.online
		or self.editMode
		or bagNum == self.primaryContainer.id
		or not self.myContainerIds[bagNum]
		or _G.GetContainerNumSlots(bagNum) == 0
		or not BagHasItems(bagNum)
		or not SlotHasBag(item.bagNum, item.slotNum)
	then
		return false
	end
	-- Put the new bag back so that it can be picked up again when it's time to equip it.
	_G.ClearCursor()
	self:BagSwap_Start(item.bagNum, item.slotNum, bagNum)
	return true
end



--- Start a swap in response to the game's error about the old bag having items in it.
--- Reached from both the event and the `UIErrorsFrame_OnEvent()` hook, which can arrive
--- in either order (pfUI can turn off the error frame's event, so the hook isn't enough
--- on its own, but the event arrives too late to keep the error off the screen).
---@param message string? Error text.
---@return boolean handled `true` when the error shouldn't be displayed.
function Inventory:BagSwap_OnError(message)
	if message ~= _G.ERR_DESTROY_NONEMPTY_BAG or not self.initialized then
		return false
	end

	-- Already dealt with by the other path or another class, or it's the result of
	-- our own equip attempt, which `Inventory:BagSwap_Step()` will notice and report.
	local now = _G.GetTime()
	if Bagshui.bagSwapActive or Bagshui.bagSwapErrorTime == now then
		return true
	end

	-- Find the slot of the bag being replaced.
	local bagNum
	for _, containerId in ipairs(self.containerIds) do
		if
			containerId ~= self.primaryContainer.id
			and _G.GetContainerNumSlots(containerId) > 0
			and _G.IsInventoryItemLocked(_G.ContainerIDToInventoryID(containerId))
		then
			if bagNum then
				return false
			end
			bagNum = containerId
		end
	end
	if not bagNum then
		return false
	end

	-- Find the new bag. Having more than one candidate means something
	-- else is going on and we shouldn't be guessing.
	local newBagNum, newSlotNum
	for _, inventoryClass in ipairs(self:BagSwap_GetStorageClasses()) do
		for _, containerId in ipairs(inventoryClass.containerIds) do
			for slotNum = 1, _G.GetContainerNumSlots(containerId) do
				if SlotLocked(containerId, slotNum) and SlotHasBag(containerId, slotNum) then
					if newBagNum then
						return false
					end
					newBagNum, newSlotNum = containerId, slotNum
				end
			end
		end
	end
	if not newBagNum then
		return false
	end

	Bagshui.bagSwapErrorTime = now
	self:BagSwap_Start(newBagNum, newSlotNum, bagNum)
	return true
end



--- Keep the game's error off the screen when a swap is taking care of it.
---@param wowApiFunctionName string Hooked WoW API function that triggered this call.
---@param event string
---@param message string?
function Inventory:UIErrorsFrame_OnEvent(wowApiFunctionName, event, message)
	if event == "UI_ERROR_MESSAGE" and self:BagSwap_OnError(message) then
		-- Returning without calling through could break other addons hooking
		-- this function, so blank the message instead.
		message = ""
	end
	self.hooks:OriginalHook(wowApiFunctionName, event, message)
end


end)
