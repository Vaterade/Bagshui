-- Bagshui Mail to Alts (OctoWoW addition)
-- Exposes: BsMailToAlts (and Bagshui.components.MailToAlts)
-- Consumes: MAIL_SHOW, MAIL_CLOSED, MAIL_SEND_SUCCESS, MAIL_FAILED, BAGSHUI_INVENTORY_CACHE_UPDATE
--
-- Items can be marked to be mailed to another character on the realm, either by item
-- (every copy of that item ID) or by category (every item Bagshui places in it). A
-- per-item mark wins over a category mark, and "Keep" on an item overrides its category.
--
-- At a mailbox, a panel next to the mail window lists the marked items in the bags,
-- grouped by recipient. Each recipient's button either:
-- - fills Aegis: Courier's attachment list and recipient when Courier's window is open
--   (Courier's own Send button then sends them), or
-- - sends them itself: vanilla mail carries ONE attachment, so it is one mail per stack,
--   sent back to back, each waiting for MAIL_SEND_SUCCESS before the next.
--
-- Marks are account-wide and keyed by character ID ("Name - Realm"), so they only apply
-- on the target's realm.

Bagshui:AddComponent(function()


-- Key in _G.BagshuiData where marks are stored.
local DATA_STORAGE_KEY = "mailToAlts"

-- Re-attempts for one mail after MAIL_FAILED before skipping it.
local MAX_RETRIES = 2

-- Seconds to wait for MAIL_SEND_SUCCESS/MAIL_FAILED before treating a mail as failed.
local SEND_TIMEOUT = 10

-- Seconds to wait for a bag slot to unlock before skipping it.
local LOCK_TIMEOUT = 5

-- Panel layout.
local PANEL_WIDTH = 270
local PANEL_HEIGHT = 340
local ROW_HEIGHT = 20
local ICON_SIZE = 16

-- Bags that can hold mailable items (backpack + 4 bags).
local BAG_IDS = { 0, 1, 2, 3, 4 }


if type(_G.BagshuiData[DATA_STORAGE_KEY]) ~= "table" then
	_G.BagshuiData[DATA_STORAGE_KEY] = {}
end
local data = _G.BagshuiData[DATA_STORAGE_KEY]
-- `{ [itemId] = characterId | false }` (false = keep, overriding a category mark).
data.items = data.items or {}
-- `{ [categoryId] = characterId }`
data.categories = data.categories or {}


local MailToAlts = {
	data = data,

	atMailbox = false,

	-- Item IDs unticked in the panel this session: `{ [characterId] = { [itemId] = true } }`.
	unchecked = {},

	-- Send engine state.
	sending = false,
	queue = nil,
	to = nil,
	toId = nil,
	inFlight = false,
	sentAt = 0,
	waitStart = nil,
	retries = 0,
	sentCount = 0,
	skippedCount = 0,
	nextStepAt = nil,

	-- Panel rows, reused between refreshes.
	rows = {},
}
Bagshui.environment.BsMailToAlts = MailToAlts
Bagshui.components.MailToAlts = MailToAlts



--- Split a Bagshui character ID into name and realm.
---@param characterId string `"Name - Realm"`.
---@return string? name
---@return string? realm
local function splitCharacterId(characterId)
	local _, _, name, realm = string.find(characterId or "", "^(.-) %- (.+)$")
	return name, realm
end



--- Characters on the current realm that Bagshui knows about, sorted by name.
--- Includes the current character so marks can be made from any character.
---@return string[] characterIds
function MailToAlts:GetRealmCharacters()
	local list = {}
	for characterId, _ in pairs(Bagshui.characters) do
		local name, realm = splitCharacterId(characterId)
		if name and realm == Bagshui.currentRealm then
			table.insert(list, characterId)
		end
	end
	table.sort(list)
	return list
end



--- Display name of a character ID (just the name; marks never cross realms).
---@param characterId string
---@return string
function MailToAlts:CharacterName(characterId)
	return (splitCharacterId(characterId)) or tostring(characterId)
end



--- Where should this item go?
---@param item table Bagshui inventory cache item.
---@return string? characterId Recipient, or nil when it stays.
---@return string? source `"item"` or `"category"`.
function MailToAlts:GetTarget(item)
	if not item or (item.id or 0) <= 0 or item.emptySlot == 1 then
		return nil
	end
	local target = data.items[item.id]
	local source = "item"
	if target == false then
		return nil
	end
	if target == nil and item.bagshuiCategoryId and item.bagshuiCategoryId ~= "" then
		target = data.categories[item.bagshuiCategoryId]
		source = "category"
	end
	if not target then
		return nil
	end
	return target, source
end



--- Mark an item ID (characterId, false = keep, nil = follow its category).
function MailToAlts:SetItemTarget(itemId, characterId)
	if (itemId or 0) <= 0 then
		return
	end
	data.items[itemId] = characterId
	self:QueueRefresh()
end



--- Mark a category (characterId or nil).
function MailToAlts:SetCategoryTarget(categoryId, characterId)
	if not categoryId or categoryId == "" then
		return
	end
	data.categories[categoryId] = characterId
	self:QueueRefresh()
end



--- Is this item one the mail can't carry?
---@param item table
---@return boolean
local function isUnmailable(item)
	local tooltip = item.tooltip or ""
	return
		string.find(tooltip, _G.ITEM_SOULBOUND, 1, true) ~= nil
		or (_G.ITEM_BIND_QUEST and string.find(tooltip, _G.ITEM_BIND_QUEST, 1, true) ~= nil)
		or (_G.ITEM_CONJURED and string.find(tooltip, _G.ITEM_CONJURED, 1, true) ~= nil)
end



--- Gather marked items in the bags, grouped by recipient.
--- Recipients that are the current character are left out (the server refuses them).
---@return table groups `{ [characterId] = { entries = { {itemId, name, texture, quality, count, stacks = { {bag, slot, count} } } } } }`
---@return string[] order Recipients sorted by name.
function MailToAlts:Collect()
	local groups = {}
	local order = {}
	local bags = Bagshui.components.Bags
	if not bags or not bags.inventory then
		return groups, order
	end

	for _, bagNum in ipairs(BAG_IDS) do
		local container = bags.inventory[bagNum]
		if container then
			for slotNum, item in ipairs(container) do
				local target = self:GetTarget(item)
				if
					target
					and target ~= Bagshui.currentCharacterId
					and not isUnmailable(item)
				then
					local group = groups[target]
					if not group then
						group = { entries = {}, byId = {}, mails = 0 }
						groups[target] = group
						table.insert(order, target)
					end
					local entry = group.byId[item.id]
					if not entry then
						entry = {
							itemId = item.id,
							name = item.name,
							texture = item.texture,
							quality = item.quality,
							count = 0,
							stacks = {},
						}
						group.byId[item.id] = entry
						table.insert(group.entries, entry)
					end
					entry.count = entry.count + (item.count or 1)
					table.insert(entry.stacks, { bag = item.bagNum or bagNum, slot = item.slotNum or slotNum, count = item.count or 1 })
				end
			end
		end
	end

	for _, target in ipairs(order) do
		local group = groups[target]
		table.sort(group.entries, function(a, b) return (a.name or "") < (b.name or "") end)
		for _, entry in ipairs(group.entries) do
			if not self:IsUnchecked(target, entry.itemId) then
				group.mails = group.mails + table.getn(entry.stacks)
			end
		end
	end
	table.sort(order)

	return groups, order
end



function MailToAlts:IsUnchecked(characterId, itemId)
	return self.unchecked[characterId] and self.unchecked[characterId][itemId] or false
end



function MailToAlts:SetUnchecked(characterId, itemId, unchecked)
	if not self.unchecked[characterId] then
		self.unchecked[characterId] = {}
	end
	self.unchecked[characterId][itemId] = unchecked or nil
end



--- Is Aegis: Courier's window up and able to take attachments?
---@return table? courier The `AegisCourier` table when it can be used.
function MailToAlts:GetCourier()
	local courier = _G.AegisCourier
	if
		type(courier) == "table"
		and type(courier.send) == "table"
		and type(courier.send.Attach) == "function"
		and type(courier.ui) == "table"
		and courier.ui.frame
		and courier.ui.frame:IsVisible()
	then
		return courier
	end
end



--- The frame the panel sits beside: Courier's window if it's up, otherwise the stock mail frame.
---@return table? frame
---@return number xOffset
---@return number yOffset
function MailToAlts:GetHostFrame()
	local courier = self:GetCourier()
	if courier then
		return courier.ui.frame, 2, 0
	end
	if _G.MailFrame and _G.MailFrame:IsVisible() then
		-- The stock frame's art is narrower than the frame.
		return _G.MailFrame, -30, -12
	end
	return nil, 0, 0
end



-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function MailToAlts:OnEvent(event)

	if event == "MAIL_SHOW" then
		self.atMailbox = true
		-- Let Courier open its window first so the panel knows where to go.
		Bagshui:QueueClassCallback(self, self.MailboxOpened, 0.2)
		return
	end

	if event == "MAIL_CLOSED" then
		self.atMailbox = false
		if self.sending then
			self:Finish(L.MailToAlts_Aborted_MailboxClosed)
		end
		if self.uiFrame then
			self.uiFrame:Hide()
		end
		if self.toggleButton then
			self.toggleButton:Hide()
		end
		return
	end

	if event == "MAIL_SEND_SUCCESS" then
		if self.sending and self.inFlight then
			self.inFlight = false
			self.retries = 0
			self.sentCount = self.sentCount + 1
			table.remove(self.queue, 1)
			self.nextStepAt = 0
			self:UpdateProgress()
		end
		return
	end

	if event == "MAIL_FAILED" then
		if self.sending and self.inFlight then
			self:MailFailed()
		end
		return
	end

	if event == "BAGSHUI_INVENTORY_CACHE_UPDATE" then
		self:QueueRefresh()
		return
	end
end



function MailToAlts:MailboxOpened()
	if not self.atMailbox then
		return
	end
	local _, order = self:Collect()
	if table.getn(order) > 0 then
		self:Open()
	else
		self:ShowToggleButton()
	end
end



function MailToAlts:QueueRefresh()
	if self.uiFrame and self.uiFrame:IsVisible() and not self.sending then
		Bagshui:QueueClassCallback(self, self.Refresh, 0.2)
	end
end



-- ---------------------------------------------------------------------------
-- Send engine (used when Courier isn't open)
-- ---------------------------------------------------------------------------

--- Is the bag slot still holding this item ID?
local function slotHasItem(bag, slot, itemId)
	local link = _G.GetContainerItemLink(bag, slot)
	if not link then
		return false
	end
	local _, _, id = string.find(link, "item:(%d+)")
	return tonumber(id) == itemId
end



--- Find another stack of this item ID that isn't already queued.
local function findItem(itemId, queue)
	for _, bag in ipairs(BAG_IDS) do
		for slot = 1, _G.GetContainerNumSlots(bag) do
			if slotHasItem(bag, slot, itemId) then
				local taken = false
				for _, queued in ipairs(queue) do
					if queued.bag == bag and queued.slot == slot then
						taken = true
						break
					end
				end
				if not taken then
					return bag, slot
				end
			end
		end
	end
end



--- Take anything off the mail's attachment slot and put it back in the bags.
local function clearAttachment()
	if _G.GetSendMailItem() then
		_G.ClearCursor()
		_G.ClickSendMailItemButton()
		_G.ClearCursor()
	end
end



--- Send the ticked items for one recipient, one mail per stack.
---@param characterId string
function MailToAlts:StartSending(characterId)
	if self.sending then
		return
	end
	if not self.atMailbox then
		Bagshui:PrintError(L.MailToAlts_Error_NotAtMailbox)
		return
	end
	if _G.GetSendMailItem() then
		Bagshui:PrintError(L.MailToAlts_Error_AttachmentInUse)
		return
	end
	if _G.CursorHasItem() then
		Bagshui:PrintError(L.MailToAlts_Error_CursorBusy)
		return
	end

	local groups = self:Collect()
	local group = groups[characterId]
	if not group or group.mails == 0 then
		return
	end

	local queue = {}
	for _, entry in ipairs(group.entries) do
		if not self:IsUnchecked(characterId, entry.itemId) then
			for _, stack in ipairs(entry.stacks) do
				table.insert(queue, { bag = stack.bag, slot = stack.slot, itemId = entry.itemId, name = entry.name })
			end
		end
	end

	local postage = (_G.GetSendMailPrice and _G.GetSendMailPrice() or 30) * table.getn(queue)
	if postage > _G.GetMoney() then
		Bagshui:PrintError(L.MailToAlts_Error_NotEnoughMoney)
		return
	end

	self.queue = queue
	self.total = table.getn(queue)
	self.to = self:CharacterName(characterId)
	self.toId = characterId
	self.sending = true
	self.inFlight = false
	self.retries = 0
	self.sentCount = 0
	self.skippedCount = 0
	self.waitStart = nil
	self.nextStepAt = 0
	self.driver:Show()
	self:UpdateProgress()
	-- First mail goes out from the click.
	self:Step()
end



--- Skip the mail at the head of the queue.
---@param reason string? Message to print.
function MailToAlts:Skip(reason)
	if reason then
		Bagshui:PrintWarning(reason)
	end
	clearAttachment()
	table.remove(self.queue, 1)
	self.skippedCount = self.skippedCount + 1
	self.retries = 0
	self.waitStart = nil
	self.nextStepAt = 0
	self:UpdateProgress()
end



function MailToAlts:MailFailed()
	self.inFlight = false
	self.retries = self.retries + 1
	if self.retries > MAX_RETRIES then
		local queued = self.queue[1]
		self:Skip(string.format(L.MailToAlts_Error_SendFailed, queued and queued.name or "?"))
	else
		clearAttachment()
		-- Give the server a moment before retrying.
		self.nextStepAt = _G.GetTime() + 0.5
	end
end



--- Send the next mail. Called from the click, then from the driver's OnUpdate.
function MailToAlts:Step()
	if not self.sending or self.inFlight then
		return
	end
	self.nextStepAt = nil

	local queued = self.queue[1]
	if not queued then
		self:Finish()
		return
	end

	-- Stacks move when bags are sorted or restacked; find the item again if it did.
	if not slotHasItem(queued.bag, queued.slot, queued.itemId) then
		local bag, slot = findItem(queued.itemId, self.queue)
		if not bag then
			table.remove(self.queue, 1)
			self.nextStepAt = 0
			return
		end
		queued.bag, queued.slot = bag, slot
	end

	-- Wait for a locked slot (e.g. just moved) to settle.
	local _, _, locked = _G.GetContainerItemInfo(queued.bag, queued.slot)
	if locked then
		self.waitStart = self.waitStart or _G.GetTime()
		if _G.GetTime() - self.waitStart > LOCK_TIMEOUT then
			self:Skip(string.format(L.MailToAlts_Error_Locked, queued.name or "?"))
		else
			self.nextStepAt = _G.GetTime() + 0.1
		end
		return
	end
	self.waitStart = nil

	clearAttachment()
	_G.ClearCursor()
	_G.PickupContainerItem(queued.bag, queued.slot)
	_G.ClickSendMailItemButton()
	local attachedName, _, attachedCount = _G.GetSendMailItem()
	if not attachedName then
		_G.ClearCursor()
		self:Skip(string.format(L.MailToAlts_Error_CannotMail, queued.name or "?"))
		return
	end

	local subject = attachedName
	if (attachedCount or 1) > 1 then
		subject = subject .. " x" .. attachedCount
	end

	self.inFlight = true
	self.sentAt = _G.GetTime()
	_G.SendMail(self.to, subject, "")
end



--- End the run and report.
---@param reason string? Why it stopped early.
function MailToAlts:Finish(reason)
	if self.inFlight then
		-- Nothing will acknowledge it now.
		self.inFlight = false
	end
	clearAttachment()
	self.sending = false
	self.nextStepAt = nil
	if self.driver then
		self.driver:Hide()
	end
	if reason then
		Bagshui:PrintWarning(reason)
	end
	Bagshui:Print(string.format(L.MailToAlts_Done, self.sentCount, self.to or "?", self.skippedCount))
	self.queue = nil
	if self.uiFrame and self.uiFrame:IsVisible() then
		self:Refresh()
	end
end



function MailToAlts:OnUpdate()
	if not self.sending then
		self.driver:Hide()
		return
	end
	local now = _G.GetTime()
	if self.inFlight then
		if now - self.sentAt > SEND_TIMEOUT then
			self:MailFailed()
		end
		return
	end
	if self.nextStepAt and now >= self.nextStepAt then
		self:Step()
	end
end



-- ---------------------------------------------------------------------------
-- Courier hand-off
-- ---------------------------------------------------------------------------

--- Put the ticked stacks for a recipient into Courier's attachment list.
---@param characterId string
function MailToAlts:SendViaCourier(characterId)
	local courier = self:GetCourier()
	if not courier then
		return
	end
	local send, ui = courier.send, courier.ui
	local name = self:CharacterName(characterId)

	if send.sending then
		Bagshui:PrintError(L.MailToAlts_Error_CourierBusy)
		return
	end
	local currentTo = ui.sendTo and ui.sendTo:GetText() or ""
	if send.Count() > 0 and string.lower(currentTo) ~= string.lower(name) then
		Bagshui:PrintError(L.MailToAlts_Error_CourierHasAttachments)
		return
	end

	local groups = self:Collect()
	local group = groups[characterId]
	if not group then
		return
	end

	local added, left = 0, 0
	for _, entry in ipairs(group.entries) do
		if not self:IsUnchecked(characterId, entry.itemId) then
			for _, stack in ipairs(entry.stacks) do
				if send.IndexOf(stack.bag, stack.slot) then
					-- Already queued.
				elseif send.Count() < (send.MAX_ATTACHMENTS or 12) then
					if send.Attach(stack.bag, stack.slot) then
						added = added + 1
					end
				else
					left = left + 1
				end
			end
		end
	end

	if type(ui.OpenTab) == "function" then
		ui.OpenTab("Send")
	end
	if ui.sendTo then
		ui.sendTo:SetText(name)
	end
	if type(ui.RefreshSend) == "function" then
		ui.RefreshSend()
	end

	if left > 0 then
		Bagshui:Print(string.format(L.MailToAlts_CourierAddedMore, added, name, left))
	else
		Bagshui:Print(string.format(L.MailToAlts_CourierAdded, added, name))
	end
end



-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

function MailToAlts:InitUi()
	if self.uiFrame then
		return
	end

	self.ui = Bagshui.prototypes.Ui:New("MailToAlts")
	local ui = self.ui

	local frame = ui:CreateWindowFrame("Window", nil, PANEL_WIDTH, PANEL_HEIGHT, L.MailToAlts_Title, true)
	self.uiFrame = frame

	local header = frame.bagshuiData.header

	local hint = frame:CreateFontString(nil, nil, "GameFontDisableSmall")
	hint:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 10, 8)
	hint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 8)
	hint:SetJustifyH("LEFT")
	self.hint = hint

	local scrollFrame, scrollChild, content = ui:CreateScrollableContent("BagshuiMailToAltsList", frame)
	scrollFrame:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
	scrollFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -30, 24)
	scrollChild:SetHeight(1)
	self.scrollFrame = scrollFrame
	self.scrollChild = scrollChild
	self.content = content

	frame:SetScript("OnShow", function()
		Bagshui:RaiseEvent("BAGSHUI_WINDOW_OPENED", false, frame)
		if MailToAlts.toggleButton then
			MailToAlts.toggleButton:Hide()
		end
	end)
	frame:SetScript("OnHide", function()
		Bagshui:RaiseEvent("BAGSHUI_WINDOW_CLOSED", false, frame)
		if MailToAlts.atMailbox then
			MailToAlts:ShowToggleButton()
		end
	end)

end



--- Get (or create) a panel row.
---@param index number
---@return table row
function MailToAlts:GetRow(index)
	local row = self.rows[index]
	if row then
		return row
	end

	local content = self.content
	row = _G.CreateFrame("Frame", nil, content)
	row:SetHeight(ROW_HEIGHT)
	row:EnableMouse(true)

	-- Recipient header parts.
	row.button = self.ui:CreateButton("RowButton" .. index, row, "", function()
		local r = _G.this.bagshuiMailRow
		if MailToAlts:GetCourier() then
			MailToAlts:SendViaCourier(r.characterId)
		else
			MailToAlts:StartSending(r.characterId)
		end
	end)
	-- Skins can reparent controls (the pfUI skin moves checkboxes into a backdrop frame),
	-- so controls keep a direct reference to their row instead of using GetParent().
	row.button.bagshuiMailRow = row
	row.button:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.button:SetHeight(ROW_HEIGHT)

	-- Item parts.
	row.check = self.ui:CreateCheckbox("RowCheck" .. index, row, nil, nil, function()
		local r = _G.this.bagshuiMailRow
		MailToAlts:SetUnchecked(r.characterId, r.itemId, not _G.this:GetChecked())
		MailToAlts:Refresh()
	end, ROW_HEIGHT - 2, ROW_HEIGHT - 2)
	row.check.bagshuiMailRow = row
	-- With a skin backdrop, the checkbox is its child; show and hide the backdrop so it
	-- doesn't stay visible on header rows.
	row.checkFrame = row.check.backdrop or row.check
	row.check:SetPoint("LEFT", row, "LEFT", 4, 0)

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetWidth(ICON_SIZE)
	row.icon:SetHeight(ICON_SIZE)
	row.icon:SetPoint("LEFT", row.check, "RIGHT", 2, 0)

	row.text = row:CreateFontString(nil, nil, "GameFontHighlightSmall")
	row.text:SetJustifyH("LEFT")
	row.text:SetHeight(ROW_HEIGHT)

	-- Item tooltip.
	row:SetScript("OnEnter", function()
		local r = _G.this
		if r.itemId then
			_G.GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
			_G.GameTooltip:SetHyperlink("item:" .. r.itemId .. ":0:0:0")
			_G.GameTooltip:Show()
		end
	end)
	row:SetScript("OnLeave", function()
		_G.GameTooltip:Hide()
	end)

	self.rows[index] = row
	return row
end



--- Rebuild the panel from the current bag contents.
function MailToAlts:Refresh()
	if not self.uiFrame then
		return
	end

	local groups, order = self:Collect()
	local courier = self:GetCourier()
	local postage = _G.GetSendMailPrice and _G.GetSendMailPrice() or 30
	local rowNum = 0
	local y = 0

	local function place(row, indent)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", self.content, "TOPLEFT", indent or 0, -y)
		row:SetPoint("RIGHT", self.content, "RIGHT", 0, 0)
		row:Show()
		y = y + ROW_HEIGHT
	end

	for _, characterId in ipairs(order) do
		local group = groups[characterId]

		-- Recipient header.
		rowNum = rowNum + 1
		local row = self:GetRow(rowNum)
		row.characterId = characterId
		row.itemId = nil
		row.checkFrame:Hide()
		row.icon:Hide()
		row.button:Show()
		local buttonText = courier and L.MailToAlts_ToCourier or string.format(L.MailToAlts_SendCount, group.mails)
		row.button:SetText(buttonText)
		row.button:SetWidth(_G[row.button:GetName() .. "Text"]:GetStringWidth() + 20)
		if group.mails > 0 and not self.sending and (courier or self.atMailbox) then
			row.button:Enable()
		else
			row.button:Disable()
		end
		row.text:ClearAllPoints()
		row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
		row.text:SetPoint("RIGHT", row.button, "LEFT", -4, 0)
		row.text:SetFontObject("GameFontNormal")
		local cost = (group.mails > 0) and (" " .. GRAY_FONT_COLOR_CODE .. BsUtil.FormatMoneyString(postage * group.mails) .. FONT_COLOR_CODE_CLOSE) or ""
		row.text:SetText(self:CharacterName(characterId) .. cost)
		place(row)

		-- Items.
		for _, entry in ipairs(group.entries) do
			rowNum = rowNum + 1
			row = self:GetRow(rowNum)
			row.characterId = characterId
			row.itemId = entry.itemId
			row.button:Hide()
			row.checkFrame:Show()
			row.check:Show()
			row.check:SetChecked(not self:IsUnchecked(characterId, entry.itemId))
			row.icon:Show()
			row.icon:SetTexture(entry.texture)
			row.text:ClearAllPoints()
			row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
			row.text:SetPoint("RIGHT", row, "RIGHT", -2, 0)
			row.text:SetFontObject("GameFontHighlightSmall")
			local _, _, _, qualityColor = _G.GetItemQualityColor(entry.quality or 1)
			local stacks = table.getn(entry.stacks)
			row.text:SetText(
				(qualityColor or "") .. (entry.name or "?") .. FONT_COLOR_CODE_CLOSE
				.. " x" .. entry.count
				.. ((stacks > 1) and (GRAY_FONT_COLOR_CODE .. " (" .. string.format(L.MailToAlts_Stacks, stacks) .. ")" .. FONT_COLOR_CODE_CLOSE) or "")
			)
			place(row, 8)
		end

		y = y + 4
	end

	-- Hide unused rows.
	for i = rowNum + 1, table.getn(self.rows) do
		self.rows[i]:Hide()
	end

	if rowNum == 0 then
		self.hint:SetText(L.MailToAlts_Empty)
	elseif courier then
		self.hint:SetText(L.MailToAlts_Hint_Courier)
	else
		self.hint:SetText(L.MailToAlts_Hint)
	end
	self:UpdateProgress()

	self.scrollChild:SetHeight(math.max(y, 1))
	self.scrollFrame:UpdateScrollChildRect()
end



function MailToAlts:UpdateProgress()
	if not self.hint then
		return
	end
	if self.sending then
		self.hint:SetText(string.format(L.MailToAlts_Progress, self.sentCount, self.total or 0, self.to or "?"))
	end
end



function MailToAlts:Open()
	self:InitUi()
	local host, x, y = self:GetHostFrame()
	self.uiFrame:ClearAllPoints()
	if host then
		self.uiFrame:SetPoint("TOPLEFT", host, "TOPRIGHT", x, y)
	else
		self.uiFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 0)
	end
	self.uiFrame:Show()
	self:Refresh()
end



function MailToAlts:Toggle()
	self:InitUi()
	if self.uiFrame:IsVisible() then
		self.uiFrame:Hide()
	else
		self:Open()
	end
end



--- Small button beside the mail window to open the panel when it isn't open.
function MailToAlts:ShowToggleButton()
	self:InitUi()
	if not self.toggleButton then
		self.toggleButton = self.ui:CreateButton("ToggleButton", _G.UIParent, L.MailToAlts_Title, function()
			MailToAlts:Open()
		end)
		self.toggleButton:SetFrameStrata("HIGH")
	end
	local host, x, y = self:GetHostFrame()
	if not host or self.uiFrame:IsVisible() then
		self.toggleButton:Hide()
		return
	end
	self.toggleButton:ClearAllPoints()
	self.toggleButton:SetPoint("TOPLEFT", host, "TOPRIGHT", x, y)
	self.toggleButton:Show()
end



-- ---------------------------------------------------------------------------
-- Item menu support (used by Inventory.Menus.lua)
-- ---------------------------------------------------------------------------

--- Fill a level-2 menu with "Mail to" choices.
---@param menu table Level-2 menu table created with `Menus:InitializeEmptyMenu()`.
---@param menus table Menus instance (for `HideMenuItems`).
---@param item table Bagshui item.
---@param forCategory boolean Fill the category submenu instead of the item one.
function MailToAlts:FillMenu(menu, menus, item, forCategory)
	local n = 0
	local current
	if forCategory then
		current = data.categories[item.bagshuiCategoryId]
	else
		current = data.items[item.id]
	end

	local function add(text, value, checked, tooltipText)
		n = n + 1
		local menuItem = menu[n]
		if not menuItem then
			return
		end
		menuItem._bagshuiHide = false
		menuItem.text = text
		menuItem.checked = checked
		menuItem.arg1 = item
		menuItem.arg2 = { forCategory = forCategory, value = value }
		menuItem.tooltipTitle = text
		menuItem.tooltipText = tooltipText
	end

	if forCategory then
		add(L.MailToAlts_Menu_None, nil, current == nil, L.MailToAlts_Menu_CategoryNone_TooltipText)
	else
		local categoryTarget = item.bagshuiCategoryId and data.categories[item.bagshuiCategoryId]
		add(
			string.format(L.MailToAlts_Menu_FollowCategory, categoryTarget and self:CharacterName(categoryTarget) or L.MailToAlts_Menu_None),
			nil,
			current == nil,
			L.MailToAlts_Menu_FollowCategory_TooltipText
		)
		add(L.MailToAlts_Menu_Keep, false, current == false, L.MailToAlts_Menu_Keep_TooltipText)
	end

	for _, characterId in ipairs(self:GetRealmCharacters()) do
		local name = self:CharacterName(characterId)
		if characterId == Bagshui.currentCharacterId then
			name = name .. " " .. GRAY_FONT_COLOR_CODE .. L.MailToAlts_Menu_CurrentCharacter .. FONT_COLOR_CODE_CLOSE
		end
		add(name, characterId, current == characterId, nil)
	end

	menus:HideMenuItems(menu, n + 1)
end



--- OnClick for the "Mail to" menu entries.
function MailToAlts.MenuClick(item, choice)
	if choice.forCategory then
		MailToAlts:SetCategoryTarget(item.bagshuiCategoryId, choice.value)
	else
		MailToAlts:SetItemTarget(item.id, choice.value)
	end
	Bagshui:CloseMenus()
end



--- Line for the item tooltip, or nil.
---@param item table
---@return string?
function MailToAlts:TooltipLine(item)
	local target = self:GetTarget(item)
	if target and target ~= Bagshui.currentCharacterId then
		return string.format(L.MailToAlts_TooltipLine, self:CharacterName(target))
	end
end



-- Send driver: must stay shown for the whole run so OnUpdate keeps ticking.
-- It isn't parented to the panel so closing the panel doesn't stop a run.
MailToAlts.driver = _G.CreateFrame("Frame")
MailToAlts.driver:Hide()
MailToAlts.driver:SetScript("OnUpdate", function()
	MailToAlts:OnUpdate()
end)


-- Slash command: /bagshui alts
BsSlash:AddHandler("Alts", function()
	MailToAlts:Toggle()
end)


Bagshui:RegisterEvent("MAIL_SHOW", MailToAlts)
Bagshui:RegisterEvent("MAIL_CLOSED", MailToAlts)
Bagshui:RegisterEvent("MAIL_SEND_SUCCESS", MailToAlts)
Bagshui:RegisterEvent("MAIL_FAILED", MailToAlts)
Bagshui:RegisterEvent("BAGSHUI_INVENTORY_CACHE_UPDATE", MailToAlts)


end)
