-- PlayerNotes: the window. On the left the players with a note (search and category filter),
-- on the right the note and categories of the selected player. Nothing here is protected, so
-- the window opens and closes normally in combat.
--
-- Edits are held in a draft until Save. So that nothing typed is ever lost, the draft is also
-- saved when you select another player or close the window.

local _, ns = ...

local UI = {}
ns.UI = UI

local FRAME_WIDTH, FRAME_HEIGHT = 700, 560
local LIST_WIDTH = 224
local ROW_HEIGHT = 20
local PANE_LEFT = LIST_WIDTH + 58
local PANE_WIDTH = FRAME_WIDTH - PANE_LEFT - 18
local GRID_COLUMNS = 3
local GRID_ROW_HEIGHT = 23
local GRID_TOP = -96
local KIND_HEADER_HEIGHT = 16
local NOTE_MAX_LETTERS = 2000

local frame
local widgets = {}
local rows = {}
local categoryChecks = {}
local kindHeaders = {}

local state = {
	selectedKey = nil, -- the player in the editor; nil while writing a new one
	draftCategories = {},
	draftOutstanding = false,
	dirty = false,
	filter = nil, -- a category id, "@negative" / "@positive" for a whole kind, or "@outstanding"
	search = "",
	newKind = "negative", -- the kind a category made in the window gets
}

local function setStatus(text)
	widgets.status:SetText(text or "")
end

-- Widget helpers -------------------------------------------------------------------

local function newLabel(parent, text, font)
	local label = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
	label:SetJustifyH("LEFT")
	label:SetText(text or "")
	return label
end

local function newButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	return button
end

local function newInput(parent, width)
	local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	input:SetSize(width, 20)
	input:SetAutoFocus(false)
	input:SetScript("OnEscapePressed", input.ClearFocus)
	return input
end

local function newPanel(parent)
	local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	panel:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	panel:SetBackdropColor(0, 0, 0, 0.45)
	panel:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.9)
	return panel
end

-- The list --------------------------------------------------------------------------

local selectEntry -- defined with the editor below

local function newRow(index)
	local row = CreateFrame("Button", nil, widgets.listChild)
	row:SetSize(LIST_WIDTH, ROW_HEIGHT)
	row:SetPoint("TOPLEFT", widgets.listChild, "TOPLEFT", 0, -(index - 1) * ROW_HEIGHT)

	row.selected = row:CreateTexture(nil, "BACKGROUND")
	row.selected:SetAllPoints()
	row.selected:SetColorTexture(0.25, 0.5, 0.9, 0.35)
	row.selected:Hide()

	-- Outstanding players glow in legendary orange, under the selection.
	row.outstanding = row:CreateTexture(nil, "BACKGROUND", nil, -1)
	row.outstanding:SetAllPoints()
	row.outstanding:SetColorTexture(1, 0.5, 0, 0.22)
	row.outstanding:Hide()

	row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")

	-- A thin bar on the left in the colour of the verdict: red, green, or yellow when mixed.
	row.verdict = row:CreateTexture(nil, "ARTWORK")
	row.verdict:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
	row.verdict:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 2)
	row.verdict:SetWidth(3)
	row.verdict:Hide()

	row.text = newLabel(row, "", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", row, "LEFT", 6, 0)
	row.text:SetPoint("RIGHT", row, "RIGHT", -4, 0)
	row.text:SetWordWrap(false)

	row:SetScript("OnClick", function(self)
		if self.key then
			selectEntry(self.key)
			-- A click is what allows a /who, so this is where the lookup can happen.
			UI.RefreshOnline(true)
		end
	end)
	rows[index] = row
	return row
end

local function filterLabel()
	if state.filter == ns.OUTSTANDING.id then
		return ns.OUTSTANDING.label
	end
	local kind = state.filter and ns.GetKind(state.filter:match("^@(.+)$"))
	if kind then
		return "All " .. kind.label:lower()
	end
	local category = state.filter and ns.GetCategory(state.filter)
	return category and category.label or "All categories"
end

local function sortMode()
	local current = ns.db.settings.sort
	for _, mode in ipairs(ns.SORT_MODES) do
		if mode.id == current then
			return mode
		end
	end
	return ns.SORT_MODES[1]
end

local function refreshList()
	local mode = sortMode()
	local items = ns.SortedEntries(state.filter, state.search, mode.id)
	for i, item in ipairs(items) do
		local row = rows[i] or newRow(i)
		local icons = ns.CategoryIcons(item.entry)
		row.key = item.key
		row.text:SetText(ns.ColorName(item.entry.name, item.entry.class) .. (icons ~= "" and "  " .. icons or ""))
		local r, g, b = ns.VerdictColor(item.entry)
		if r then
			row.verdict:SetColorTexture(r, g, b, 0.9)
			row.verdict:Show()
		else
			row.verdict:Hide()
		end
		row.verdictShown = r ~= nil -- for the tests
		row.outstanding:SetShown(item.entry.outstanding == true)
		row.selected:SetShown(item.key == state.selectedKey)
		row:Show()
	end
	for i = #items + 1, #rows do
		rows[i].key = nil
		rows[i]:Hide()
	end
	widgets.listChild:SetHeight(math.max(1, #items * ROW_HEIGHT))
	widgets.filterButton:SetText(filterLabel())
	widgets.sortButton:SetText("Sort: " .. mode.short)
	widgets.count:SetText(("%d of %d players"):format(#items, ns.CountPlayers()))
	widgets.empty:SetShown(#items == 0)
	if #items == 0 then
		widgets.empty:SetText(ns.CountPlayers() == 0 and "No notes yet.\nClick New to write one." or "Nobody matches.")
	end
end

local function openFilterMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Show players in")
		root:CreateButton("All categories", function()
			state.filter = nil
			refreshList()
		end)
		root:CreateButton(ns.CategoryText(ns.OUTSTANDING), function()
			state.filter = ns.OUTSTANDING.id
			refreshList()
		end)
		for _, kindId in ipairs({ "negative", "positive" }) do
			root:CreateButton("All " .. ns.KindText(kindId):lower(), function()
				state.filter = "@" .. kindId
				refreshList()
			end)
		end
		for _, kind in ipairs(ns.KINDS) do
			for _, category in ipairs(ns.db.categories) do
				if category.kind == kind.id then
					local id = category.id
					root:CreateButton(ns.CategoryText(category), function()
						state.filter = id
						refreshList()
					end)
				end
			end
		end
	end)
end

local function openSortMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("Sort by")
		for _, mode in ipairs(ns.SORT_MODES) do
			local id = mode.id
			root:CreateButton(mode.label, function()
				ns.db.settings.sort = id
				refreshList()
			end)
		end
	end)
end

-- Online status -----------------------------------------------------------------------

local ONLINE_LOOK = {
	online = { color = "40ff40", icon = "Interface\\FriendsFrame\\StatusIcon-Online" },
	offline = { color = "ff6060", icon = "Interface\\FriendsFrame\\StatusIcon-Offline" },
	maybe = { color = "ffd060", icon = "Interface\\FriendsFrame\\StatusIcon-Away" },
	notfound = { color = "ffd060", icon = "Interface\\FriendsFrame\\StatusIcon-Away" },
	otherfaction = { color = "ffd060", icon = "Interface\\FriendsFrame\\StatusIcon-Away" },
}

local function showOnline(key, result)
	if key ~= state.selectedKey then
		return -- the answer came back after you had moved on to someone else
	end
	local look = ONLINE_LOOK[result.state]
	widgets.onlineText:SetText("|cff" .. (look and look.color or "aaaaaa") .. result.text .. "|r")
	if look then
		widgets.onlineIcon:SetTexture(look.icon)
		widgets.onlineIcon:Show()
	else
		widgets.onlineIcon:Hide()
	end
end

-- `canSendWho` only from a click; `force` skips the remembered answer.
function UI.RefreshOnline(canSendWho, force)
	local key = state.selectedKey
	if not key then
		widgets.onlineText:SetText("")
		widgets.onlineIcon:Hide()
		widgets.checkButton:Disable()
		return
	end
	widgets.checkButton:Enable()
	ns.Online.Check(key, { canSendWho = canSendWho, force = force }, function(result)
		showOnline(key, result)
	end)
end

-- The editor ------------------------------------------------------------------------

-- The category boxes in one section per kind (Positive, Negative, Neutral), each with its own
-- heading; an empty section takes no room. What follows the grid moves up or down with it.
local function refreshCategories()
	local columnWidth = math.floor(PANE_WIDTH / GRID_COLUMNS)
	local y = GRID_TOP
	local slot = 0
	for _, kind in ipairs(ns.KINDS) do
		local inKind = {}
		for _, category in ipairs(ns.db.categories) do
			if (category.kind or "neutral") == kind.id then
				inKind[#inKind + 1] = category
			end
		end
		local header = kindHeaders[kind.id]
		if #inKind > 0 then
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", frame, "TOPLEFT", PANE_LEFT + 2, y)
			header:Show()
			y = y - KIND_HEADER_HEIGHT
			for i, category in ipairs(inKind) do
				slot = slot + 1
				local check = categoryChecks[slot]
				local column = (i - 1) % GRID_COLUMNS
				local line = math.floor((i - 1) / GRID_COLUMNS)
				check:ClearAllPoints()
				check:SetPoint("TOPLEFT", frame, "TOPLEFT", PANE_LEFT + column * columnWidth, y - line * GRID_ROW_HEIGHT)
				check.categoryId = category.id
				check.label:SetText(ns.CategoryText(category))
				check:SetChecked(state.draftCategories[category.id] == true)
				check:Show()
			end
			y = y - math.ceil(#inKind / GRID_COLUMNS) * GRID_ROW_HEIGHT
		else
			header:Hide()
		end
	end
	for i = slot + 1, #categoryChecks do
		local check = categoryChecks[i]
		check.categoryId = nil
		check:Hide()
	end
	widgets.newCategoryLabel:ClearAllPoints()
	widgets.newCategoryLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PANE_LEFT, y - 8)
	widgets.newKindButton:SetText(ns.KindText(state.newKind))
end

local function loadEditor(key)
	local entry = key and ns.db.players[key]
	state.selectedKey = entry and key or nil
	wipe(state.draftCategories)
	if entry then
		for id in pairs(entry.categories or {}) do
			state.draftCategories[id] = true
		end
	end
	-- A saved player's name is fixed: it shows as plain text, and only a new draft can be typed.
	widgets.nameBox:SetText(entry and entry.name or "")
	widgets.nameText:SetText(entry and entry.name or "")
	if entry then
		widgets.nameBox:ClearFocus()
		widgets.nameBox:Hide()
		widgets.nameText:Show()
		widgets.useTarget:Disable()
	else
		widgets.nameText:Hide()
		widgets.nameBox:Show()
		widgets.useTarget:Enable()
	end
	state.draftOutstanding = entry ~= nil and entry.outstanding == true
	widgets.outstandingCheck:SetChecked(state.draftOutstanding)
	widgets.noteBox:SetText(entry and entry.note or "")
	widgets.noteBox:SetCursorPosition(0)
	widgets.noteScroll:SetVerticalScroll(0)
	state.dirty = false
	refreshCategories()
	if entry then
		widgets.deleteButton:Enable()
		setStatus(entry.updated and ("Last changed " .. date("%Y-%m-%d %H:%M", entry.updated)) or "")
	else
		widgets.deleteButton:Disable()
		setStatus("")
	end
	UI.RefreshOnline(false)
end

local function markDirty()
	state.dirty = true
	setStatus("|cffffd060Not saved yet|r")
end

-- The draft's categories, without any that were deleted in the meantime.
local function draftCategoriesCopy()
	local copy = {}
	for id in pairs(state.draftCategories) do
		if ns.GetCategory(id) then
			copy[id] = true
		end
	end
	return copy
end

-- Writes the draft to the saved data. Returns false and the reason, also shown in the window,
-- when it cannot.
local function saveDraft()
	local players = ns.db.players
	if state.selectedKey and not players[state.selectedKey] then
		local why = "That player has no note any more."
		setStatus("|cffff6060" .. why .. "|r")
		return false, why
	end
	-- A saved player keeps their name; only a new draft takes the name from the box.
	local rawName = state.selectedKey and players[state.selectedKey].name or widgets.nameBox:GetText()
	local display, key = ns.ValidateName(rawName)
	if not display then
		setStatus("|cffff6060" .. key .. "|r")
		return false, key
	end
	local noteText = ns.Trim(widgets.noteBox:GetText() or "")
	local merged = false

	if state.selectedKey then
		local entry = players[state.selectedKey]
		key = state.selectedKey
		-- A first note on a player who only had categories is new, so it gets the stamp too.
		entry.note = entry.note == "" and ns.StampNote(noteText) or noteText
		entry.categories = draftCategoriesCopy()
		entry.outstanding = state.draftOutstanding or nil
		entry.updated = time()
	elseif players[key] then
		-- A new draft for someone who already has a note: add to it, never replace it.
		local entry = ns.AddNote(rawName, noteText)
		for id in pairs(draftCategoriesCopy()) do
			entry.categories[id] = true
		end
		if state.draftOutstanding then
			entry.outstanding = true
		end
		merged = true
	else
		local entry = ns.GetOrCreateEntry(rawName)
		entry.note = ns.StampNote(noteText)
		entry.categories = draftCategoriesCopy()
		entry.outstanding = state.draftOutstanding or nil
	end

	loadEditor(key)
	refreshList()
	ns.GroupFinder.Refresh()
	setStatus(merged and "Added to the note you already had on this player." or "Saved.")
	return true
end

-- Before the editor moves on. With `keepDraft`, a draft that cannot be saved yet (no name)
-- simply stays in the editor; otherwise it is dropped, and you are told what it said.
local function saveIfDirty(keepDraft)
	if not state.dirty then
		return
	end
	local saved, why = saveDraft()
	if not saved and not keepDraft then
		ns.Print("A draft could not be saved and was dropped: " .. why)
		local text = ns.Trim(widgets.noteBox:GetText() or "")
		if text ~= "" then
			DEFAULT_CHAT_FRAME:AddMessage("   " .. text)
		end
		state.dirty = false
	end
end

selectEntry = function(key)
	saveIfDirty()
	loadEditor(key)
	refreshList()
end

local function targetName()
	return (ns.ReadUnitName("target"))
end

local function startNew(rawName)
	saveIfDirty()
	loadEditor(nil)
	refreshList()
	local name = rawName or targetName()
	if name then
		widgets.nameBox:SetText(ns.DisplayName(name) or "")
		widgets.noteBox:SetFocus()
	else
		widgets.nameBox:SetFocus()
	end
end

local function addCategoryFromInput()
	local category, why = ns.AddCategory(widgets.newCategoryBox:GetText(), state.newKind)
	if not category then
		setStatus("|cffff6060" .. why .. "|r")
		return
	end
	widgets.newCategoryBox:SetText("")
	widgets.newCategoryBox:ClearFocus()
	state.draftCategories[category.id] = true
	refreshCategories()
	markDirty()
end

-- A new line at the end of the note, starting with today's date and zone, ready for typing.
local function addDatedLine()
	local noteBox = widgets.noteBox
	local text = noteBox:GetText() or ""
	if text ~= "" and text:sub(-1) ~= "\n" then
		text = text .. "\n"
	end
	noteBox:SetText(text .. ns.Stamp() .. ": ")
	noteBox:SetFocus()
	noteBox:SetCursorPosition(NOTE_MAX_LETTERS * 4) -- past the end; the box stops at the end
	markDirty()
end

-- Dialogs -----------------------------------------------------------------------------

StaticPopupDialogs["PLAYERNOTES_DELETE_PLAYER"] = {
	text = "Delete your note on %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, key)
		ns.DeleteEntry(key)
		if state.selectedKey == key then
			state.selectedKey = nil
			state.dirty = false
		end
		ns.Notify()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

StaticPopupDialogs["PLAYERNOTES_DELETE_CATEGORY"] = {
	text = "Delete the category %s? It is removed from every player.",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, id)
		ns.RemoveCategory(id)
		state.draftCategories[id] = nil
		if state.filter == id then
			state.filter = nil
		end
		ns.Notify()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Right-clicking a category: positive or negative, its icon, whether it alerts, and deleting it.
local function openCategoryMenu(owner, id)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		local category = ns.GetCategory(id)
		if not category then
			return
		end
		root:CreateTitle(ns.CategoryText(category))
		local kindMenu = root:CreateButton("Type: " .. ns.KindText(category.kind))
		for _, kind in ipairs(ns.KINDS) do
			local kindId = kind.id
			kindMenu:CreateRadio(ns.KindText(kindId), function()
				return category.kind == kindId
			end, function()
				category.kind = kindId
				ns.Notify()
			end)
		end
		local iconMenu = root:CreateButton("Change icon")
		for _, icon in ipairs(ns.ICONS) do
			local path = icon.path
			iconMenu:CreateButton(ns.InlineIcon(path, 16) .. " " .. icon.label, function()
				category.icon = path
				ns.Notify()
			end)
		end
		root:CreateCheckbox("Alert when nearby", function()
			return category.alert == true
		end, function()
			category.alert = not category.alert
			ns.Notify()
		end)
		root:CreateDivider()
		root:CreateButton("Delete category", function()
			StaticPopup_Show("PLAYERNOTES_DELETE_CATEGORY", category.label, nil, id)
		end)
	end)
end

-- Building the window --------------------------------------------------------------------

local function buildList()
	local searchLabel = newLabel(frame, "Search:", "GameFontHighlightSmall")
	searchLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -44)

	local search = newInput(frame, LIST_WIDTH - 44)
	search:SetPoint("LEFT", searchLabel, "RIGHT", 10, 0)
	search:SetScript("OnEnterPressed", search.ClearFocus)
	search:SetScript("OnTextChanged", function(self)
		state.search = self:GetText() or ""
		refreshList()
	end)

	local filterButton = newButton(frame, "All categories", 136)
	filterButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -68)
	filterButton:SetScript("OnClick", openFilterMenu)
	widgets.filterButton = filterButton

	local newPlayer = newButton(frame, "New", LIST_WIDTH - 136 + 28)
	newPlayer:SetPoint("LEFT", filterButton, "RIGHT", 4, 0)
	newPlayer:SetScript("OnClick", function() startNew() end)

	local panel = newPanel(frame)
	panel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -94)
	panel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", LIST_WIDTH + 44, 34)

	local scroll = CreateFrame("ScrollFrame", "PlayerNotesListScroll", panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 5, -5)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -27, 5)

	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(LIST_WIDTH, 1)
	scroll:SetScrollChild(child)
	widgets.listChild = child

	widgets.empty = newLabel(panel, "", "GameFontDisable")
	widgets.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -14)
	widgets.empty:SetPoint("RIGHT", panel, "RIGHT", -12, 0)

	widgets.count = newLabel(frame, "", "GameFontDisableSmall")
	widgets.count:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 16)

	local sortButton = newButton(frame, "Sort: Name", 116)
	sortButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", LIST_WIDTH + 44, 9)
	sortButton:SetScript("OnClick", openSortMenu)
	widgets.sortButton = sortButton
end

local function newCategoryCheck(index)
	local check = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	check:SetSize(22, 22) -- placed by refreshCategories, in the section of its kind
	check:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	check.label = newLabel(check, "", "GameFontHighlightSmall")
	check.label:SetPoint("LEFT", check, "RIGHT", 2, 0)
	check.label:SetWidth(math.floor(PANE_WIDTH / GRID_COLUMNS) - 28)
	check.label:SetWordWrap(false)

	check:SetScript("OnClick", function(self, mouseButton)
		local id = self.categoryId
		if not id then
			return
		end
		if mouseButton == "RightButton" then
			-- The click toggled the box; a right click is only for the menu.
			self:SetChecked(state.draftCategories[id] == true)
			openCategoryMenu(self, id)
			return
		end
		state.draftCategories[id] = self:GetChecked() and true or nil
		markDirty()
	end)
	check:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Right-click: type, icon, nearby alert, delete", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	check:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	categoryChecks[index] = check
end

local function buildEditor()
	local checkButton = newButton(frame, "Check", 64)
	checkButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -36, -12)
	checkButton:SetScript("OnClick", function()
		UI.RefreshOnline(true, true)
	end)
	checkButton:Disable()
	widgets.checkButton = checkButton

	local onlineIcon = frame:CreateTexture(nil, "OVERLAY")
	onlineIcon:SetSize(14, 14)
	onlineIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", PANE_LEFT, -16)
	onlineIcon:Hide()
	widgets.onlineIcon = onlineIcon

	local onlineText = newLabel(frame, "", "GameFontHighlightSmall")
	onlineText:SetPoint("LEFT", onlineIcon, "RIGHT", 4, 0)
	onlineText:SetPoint("RIGHT", checkButton, "LEFT", -6, 0)
	onlineText:SetWordWrap(false)
	widgets.onlineText = onlineText

	local nameLabel = newLabel(frame, "Player")
	nameLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PANE_LEFT, -44)

	local nameBox = newInput(frame, 210)
	nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 12, 0)
	nameBox:SetMaxLetters(64)
	nameBox:SetScript("OnEnterPressed", function() widgets.noteBox:SetFocus() end)
	nameBox:SetScript("OnTextChanged", function(_, userInput)
		if userInput then
			markDirty()
		end
	end)
	widgets.nameBox = nameBox

	-- Shown in the box's place for a saved player, whose name cannot be changed.
	local nameText = newLabel(frame, "", "GameFontHighlight")
	nameText:SetPoint("LEFT", nameBox, "LEFT", 0, 0)
	nameText:SetPoint("RIGHT", nameBox, "RIGHT", 0, 0)
	nameText:SetWordWrap(false)
	nameText:Hide()
	widgets.nameText = nameText

	local useTarget = newButton(frame, "Use target", 92)
	useTarget:SetPoint("LEFT", nameBox, "RIGHT", 8, 0)
	widgets.useTarget = useTarget
	useTarget:SetScript("OnClick", function()
		local name = targetName()
		if name then
			nameBox:SetText(ns.DisplayName(name) or "")
			markDirty()
		else
			setStatus("|cffff6060Target a player first.|r")
		end
	end)

	local categoriesLabel = newLabel(frame, "Categories")
	categoriesLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PANE_LEFT, -76)

	-- The outstanding mark, on the same line as "Categories", at the right.
	local outstandingCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
	outstandingCheck:SetSize(22, 22)
	outstandingCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", FRAME_WIDTH - 170, -72)
	outstandingCheck.isOutstanding = true
	local outstandingLabel = newLabel(outstandingCheck, ns.CategoryText(ns.OUTSTANDING), "GameFontHighlight")
	outstandingLabel:SetPoint("LEFT", outstandingCheck, "RIGHT", 2, 0)
	outstandingCheck:SetScript("OnClick", function(self)
		state.draftOutstanding = self:GetChecked() and true or false
		markDirty()
	end)
	outstandingCheck:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(ns.CategoryText(ns.OUTSTANDING))
		GameTooltip:AddLine("A player you never want to forget: shown first in the list, highlighted, and first in every reminder.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	outstandingCheck:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	widgets.outstandingCheck = outstandingCheck

	for i = 1, ns.MAX_CATEGORIES do
		newCategoryCheck(i)
	end
	for _, kind in ipairs(ns.KINDS) do
		kindHeaders[kind.id] = newLabel(frame, "|cff" .. kind.color .. kind.label .. "|r", "GameFontNormalSmall")
	end

	-- Placed by refreshCategories, under the last section; the note follows it.
	local newCategoryLabel = newLabel(frame, "New category:", "GameFontHighlightSmall")
	newCategoryLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", PANE_LEFT, GRID_TOP - 8)
	widgets.newCategoryLabel = newCategoryLabel

	local newCategoryBox = newInput(frame, 120)
	newCategoryBox:SetPoint("LEFT", newCategoryLabel, "RIGHT", 12, 0)
	newCategoryBox:SetMaxLetters(24)
	newCategoryBox:SetScript("OnEnterPressed", addCategoryFromInput)
	widgets.newCategoryBox = newCategoryBox

	-- The kind the new category gets; each click moves to the next one.
	local newKindButton = newButton(frame, ns.KindText(state.newKind), 80)
	newKindButton:SetPoint("LEFT", newCategoryBox, "RIGHT", 6, 0)
	newKindButton:SetScript("OnClick", function()
		for i, kind in ipairs(ns.KINDS) do
			if kind.id == state.newKind then
				state.newKind = ns.KINDS[i % #ns.KINDS + 1].id
				break
			end
		end
		newKindButton:SetText(ns.KindText(state.newKind))
	end)
	widgets.newKindButton = newKindButton

	local addCategory = newButton(frame, "Add", 50)
	addCategory:SetPoint("LEFT", newKindButton, "RIGHT", 4, 0)
	addCategory:SetScript("OnClick", addCategoryFromInput)

	local noteLabel = newLabel(frame, "Note")
	noteLabel:SetPoint("TOPLEFT", newCategoryLabel, "TOPLEFT", 0, -28)

	local notePanel = newPanel(frame)
	notePanel:SetPoint("TOPLEFT", newCategoryLabel, "TOPLEFT", -2, -46)
	notePanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 62)

	local noteScroll = CreateFrame("ScrollFrame", "PlayerNotesNoteScroll", notePanel, "UIPanelScrollFrameTemplate")
	noteScroll:SetPoint("TOPLEFT", notePanel, "TOPLEFT", 7, -7)
	noteScroll:SetPoint("BOTTOMRIGHT", notePanel, "BOTTOMRIGHT", -27, 7)

	local noteBox = CreateFrame("EditBox", nil, noteScroll)
	noteBox:SetMultiLine(true)
	noteBox:SetAutoFocus(false)
	noteBox:SetFontObject(ChatFontNormal)
	noteBox:SetMaxLetters(NOTE_MAX_LETTERS)
	noteBox:SetWidth(PANE_WIDTH - 40)
	noteBox:SetHeight(100)
	noteBox:SetScript("OnEscapePressed", noteBox.ClearFocus)
	noteBox:SetScript("OnTextChanged", function(_, userInput)
		if userInput then
			markDirty()
		end
	end)
	-- Keeps the cursor in view while typing past the bottom of the box.
	noteBox:SetScript("OnCursorChanged", function(_, _, y, _, cursorHeight)
		local top = -y
		local offset = noteScroll:GetVerticalScroll()
		if top < offset then
			noteScroll:SetVerticalScroll(top)
		else
			local bottom = top + cursorHeight - noteScroll:GetHeight()
			if bottom > offset then
				noteScroll:SetVerticalScroll(bottom)
			end
		end
	end)
	noteScroll:SetScrollChild(noteBox)
	widgets.noteBox = noteBox
	widgets.noteScroll = noteScroll

	-- A click anywhere in the box, also below the last line, starts typing.
	notePanel:EnableMouse(true)
	notePanel:SetScript("OnMouseDown", function() noteBox:SetFocus() end)

	local saveButton = newButton(frame, "Save", 90)
	saveButton:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PANE_LEFT, 32)
	saveButton:SetScript("OnClick", function()
		noteBox:ClearFocus()
		saveDraft()
	end)

	local deleteButton = newButton(frame, "Delete", 90)
	deleteButton:SetPoint("LEFT", saveButton, "RIGHT", 6, 0)
	deleteButton:SetScript("OnClick", function()
		local key = state.selectedKey
		local entry = key and ns.db.players[key]
		if entry then
			StaticPopup_Show("PLAYERNOTES_DELETE_PLAYER", entry.name, nil, key)
		end
	end)
	widgets.deleteButton = deleteButton

	local datedLine = newButton(frame, "Add dated line", 116)
	datedLine:SetPoint("LEFT", deleteButton, "RIGHT", 6, 0)
	datedLine:SetScript("OnClick", addDatedLine)

	widgets.status = newLabel(frame, "", "GameFontHighlightSmall")
	widgets.status:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PANE_LEFT, 14)
	widgets.status:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -16, 14)
	widgets.status:SetWordWrap(false)
end

local function restorePosition()
	local saved = ns.db.window
	frame:ClearAllPoints()
	if type(saved) == "table" and saved.point and saved.relativePoint then
		frame:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x or 0, saved.y or 0)
	else
		frame:SetPoint("CENTER")
	end
end

local function build()
	frame = CreateFrame("Frame", "PlayerNotesFrame", UIParent, "BackdropTemplate")
	frame:Hide()
	frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self)
		self:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relativePoint, x, y = self:GetPoint()
		ns.db.window = { point = point, relativePoint = relativePoint, x = x, y = y }
	end)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.06, 0.06, 0.09, 0.96)
	frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
	restorePosition()

	local title = newLabel(frame, "PlayerNotes", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -14)

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -3, -3)

	buildList()
	buildEditor()

	frame:SetScript("OnShow", function()
		refreshList()
		refreshCategories()
		if not state.dirty then
			loadEditor(state.selectedKey)
			refreshList()
		end
	end)
	frame:SetScript("OnHide", function()
		saveIfDirty(true)
	end)

	-- Escape closes the window.
	tinsert(UISpecialFrames, "PlayerNotesFrame")
end

-- Public -------------------------------------------------------------------------------

function UI.Toggle()
	if not frame then
		build()
	end
	frame:SetShown(not frame:IsShown())
end

-- Opens the window on a player: their note when they have one, a new draft otherwise.
function UI.OpenFor(rawName)
	if not frame then
		build()
	end
	frame:Show()
	local key = ns.MakeKey(rawName)
	if key and ns.db.players[key] then
		selectEntry(key)
	else
		startNew(rawName)
	end
end

function UI.OnDataChanged()
	if not (frame and frame:IsShown()) then
		return
	end
	refreshList()
	refreshCategories()
	if not state.dirty then
		loadEditor(state.selectedKey)
		refreshList()
	end
end

-- Right-click menus on players -------------------------------------------------------------

local UNIT_MENUS = {
	"MENU_UNIT_PLAYER",
	"MENU_UNIT_ENEMY_PLAYER",
	"MENU_UNIT_PARTY",
	"MENU_UNIT_RAID_PLAYER",
	"MENU_UNIT_FRIEND",
	"MENU_UNIT_FRIEND_OFFLINE",
	"MENU_UNIT_GUILD",
	"MENU_UNIT_GUILD_OFFLINE",
	"MENU_UNIT_CHAT_ROSTER",
	"MENU_UNIT_COMMUNITIES_GUILD_MEMBER",
	"MENU_UNIT_COMMUNITIES_WOW_MEMBER",
}

local function nameFromMenu(contextData)
	local unit = ns.Readable(contextData.unit)
	if type(unit) == "string" then
		local name = ns.ReadUnitName(unit)
		if name then
			return name
		end
	end
	local name = ns.Readable(contextData.name)
	if type(name) ~= "string" or name == "" then
		return nil
	end
	local server = ns.Readable(contextData.server)
	if not name:find("-", 1, true) then
		name = ns.JoinName(name, server)
	end
	return name
end

function UI.InstallUnitMenus()
	if not (Menu and Menu.ModifyMenu) then
		return
	end
	for _, tag in ipairs(UNIT_MENUS) do
		pcall(Menu.ModifyMenu, tag, ns.Guard("menu", function(_, root, contextData)
			local name = contextData and nameFromMenu(contextData)
			if not name then
				return
			end
			local key = ns.MakeKey(name)
			local hasNote = key and ns.db.players[key] ~= nil
			if root.CreateDivider then
				root:CreateDivider()
			end
			root:CreateTitle("PlayerNotes")
			root:CreateButton(hasNote and "Edit note" or "Add note", function()
				UI.OpenFor(name)
			end)
			root:CreateCheckbox(ns.CategoryText(ns.OUTSTANDING), function()
				local entry = key and ns.db.players[key]
				return entry ~= nil and entry.outstanding == true
			end, function()
				ns.ToggleOutstanding(name)
			end)
		end))
	end
	ns.unitMenusInstalled = true
end
