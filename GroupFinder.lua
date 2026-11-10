-- PlayerNotes: icons in the group finder, next to the name on a row where the leader or a member
-- has a note: the icons of their categories, or a warning sign for a note without a category.
-- Hovering the icons shows the notes.
--
-- Blizzard builds each row in a global function that takes the row, which knows its resultID.
-- hooksecurefunc runs after that function and leaves it untouched, and the window may load late,
-- so the hook is tried again each time an addon finishes loading.

local _, ns = ...

local GroupFinder = {}
ns.GroupFinder = GroupFinder

local ICON_SIZE = 16
local ICON_GAP = 1
local MAX_ROW_ICONS = 3 -- the row has little room; the tooltip always names every category
local TOOLTIP_NOTE_LIMIT = 600
local WARNING_ATLAS = "services-icon-warning"
local WARNING_TEXTURE = "Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew"

-- The Classic-style list Forever is reported to use, and the retail list, in case it is that one.
local ROW_FUNCTIONS = { "LFGBrowseSearchEntry_Update", "LFGListSearchEntry_Update" }

local knownRows = {}

-- For /pn debug: what this client really does, and how it spells names.
GroupFinder.hooked = {}
GroupFinder.rowsSeen = 0
GroupFinder.iconsShown = 0
GroupFinder.lastName = nil

-- Who is on a row -----------------------------------------------------------------------

-- The readable names on a listing: the leader, then the members of a group.
local function namesInResult(resultID)
	local info = C_LFGList.GetSearchResultInfo(resultID)
	if type(info) ~= "table" then
		return {}
	end
	local names = {}
	local leader = ns.Readable(info.leaderName)
	if type(leader) == "string" and leader ~= "" then
		names[1] = leader
		GroupFinder.lastName = leader
	end
	local count = ns.Readable(info.numMembers)
	if type(count) == "number" and count > 1 and C_LFGList.GetSearchResultPlayerInfo then
		for i = 1, count do
			local member = C_LFGList.GetSearchResultPlayerInfo(resultID, i)
			local name = member and ns.Readable(member.name)
			if type(name) == "string" and name ~= "" then
				names[#names + 1] = name
			end
		end
	end
	return names
end

-- The notes that apply to a listing, one per noted player even if a name comes up twice.
local function matchesForResult(resultID)
	local matches = {}
	if not next(ns.db.players) then
		return matches
	end
	local seen = {}
	for _, name in ipairs(namesInResult(resultID)) do
		for _, found in ipairs(ns.FindNotes(name)) do
			if not seen[found.key] and ns.HasContent(found.entry) then
				seen[found.key] = true
				matches[#matches + 1] = { name = name, entry = found.entry, loose = found.loose }
			end
		end
	end
	return matches
end

-- The tooltip ---------------------------------------------------------------------------

local function showTooltip(icon)
	GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
	GameTooltip:AddLine("PlayerNotes", 0.4, 0.8, 1)
	for index, match in ipairs(icon.matches or {}) do
		if index > 1 then
			GameTooltip:AddLine(" ")
		end
		local entry = match.entry
		local tags = ns.CategoryTags(entry)
		GameTooltip:AddLine(ns.VerdictTag(entry) .. ns.ColorName(entry.name, entry.class) .. (tags ~= "" and "  " .. tags or ""), 1, 1, 1)
		if match.loose then
			GameTooltip:AddLine(("Name partly matches: this is %s, and may be a different player."):format(ns.DisplayName(match.name)), 0.6, 0.6, 0.6, true)
		end
		ns.AddNoteToTooltip(GameTooltip, entry, TOOLTIP_NOTE_LIMIT)
	end
	GameTooltip:Show()
end

-- The icons -----------------------------------------------------------------------------

local function createIcon(row)
	local icon = CreateFrame("Frame", nil, row)
	icon:SetSize(ICON_SIZE, ICON_SIZE)
	icon:EnableMouse(true)
	-- A click on the icon still selects the row, or opens its right-click menu.
	if icon.SetPropagateMouseClicks then
		icon:SetPropagateMouseClicks(true)
	end

	icon.textures = {}
	for i = 1, MAX_ROW_ICONS do
		local texture = icon:CreateTexture(nil, "OVERLAY")
		texture:SetSize(ICON_SIZE, ICON_SIZE)
		texture:SetPoint("LEFT", icon, "LEFT", (i - 1) * (ICON_SIZE + ICON_GAP), 0)
		icon.textures[i] = texture
	end

	icon:SetScript("OnEnter", ns.Guard("group finder tooltip", showTooltip))
	icon:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	row.PlayerNotesIcon = icon
	return icon
end

local function showWarningSign(texture)
	if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(WARNING_ATLAS) then
		texture:SetTexCoord(0, 1, 0, 1)
		texture:SetAtlas(WARNING_ATLAS)
	else
		ns.SetIconTexture(texture, WARNING_TEXTURE)
	end
end

-- One icon per category on the row, up to the limit; the warning sign when nobody has one.
local function drawIcons(icon, matches)
	local entries = {}
	for i, match in ipairs(matches) do
		entries[i] = match.entry
	end
	local categories = ns.CategoriesOf(entries)
	local count = math.max(1, math.min(#categories, MAX_ROW_ICONS))
	for i, texture in ipairs(icon.textures) do
		if categories[i] and i <= count then
			ns.SetIconTexture(texture, categories[i].icon)
			texture:Show()
		elseif i == 1 then
			showWarningSign(texture)
			texture:Show()
		else
			texture:Hide()
		end
	end
	icon:SetWidth(count * ICON_SIZE + (count - 1) * ICON_GAP)
	icon.iconCount = count
end

-- The icon goes after the last thing on the name's line. The Classic-style row chains them:
-- Name, Level, ClassIcon, NewPlayerFriendlyIcon. Other rows have Name at least.
local function lastOnNameLine(row)
	for _, key in ipairs({ "NewPlayerFriendlyIcon", "ClassIcon", "Level" }) do
		local region = row[key]
		if region and region:IsShown() then
			return region
		end
	end
	return row.Name
end

local function updateRow(row)
	if not ns.db or not C_LFGList then
		return
	end
	knownRows[row] = true
	GroupFinder.rowsSeen = GroupFinder.rowsSeen + 1

	local resultID = ns.Readable(row.resultID)
	local matches = resultID and matchesForResult(resultID) or {}
	if #matches == 0 then
		if row.PlayerNotesIcon then
			row.PlayerNotesIcon.matches = nil
			row.PlayerNotesIcon:Hide()
		end
		return
	end

	local icon = row.PlayerNotesIcon or createIcon(row)
	icon.matches = matches
	drawIcons(icon, matches)
	icon:ClearAllPoints()
	local anchor = lastOnNameLine(row)
	if anchor then
		icon:SetPoint("LEFT", anchor, "RIGHT", 3, 0)
	else
		icon:SetPoint("LEFT", row, "LEFT", 4, 0)
	end
	icon:Show()
	GroupFinder.iconsShown = GroupFinder.iconsShown + 1
end

-- Your notes changed: the rows on screen follow straight away.
function GroupFinder.Refresh()
	for row in pairs(knownRows) do
		if row:IsShown() then
			updateRow(row)
		end
	end
end

-- Hooking -------------------------------------------------------------------------------

local rowHook = ns.Guard("group finder row", updateRow)

local function tryHook()
	for _, functionName in ipairs(ROW_FUNCTIONS) do
		if not GroupFinder.hooked[functionName] and type(_G[functionName]) == "function" then
			hooksecurefunc(functionName, rowHook)
			GroupFinder.hooked[functionName] = true
		end
	end
end

local loadWatcher = CreateFrame("Frame")
loadWatcher:RegisterEvent("ADDON_LOADED")
loadWatcher:SetScript("OnEvent", ns.Guard("group finder hook", tryHook))
ns.Guard("group finder hook", tryHook)()
