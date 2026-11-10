-- PlayerNotes: an alert when a player in an alerting category comes close. Griefer is one by
-- default; right-click a category in the window to change that.
--
-- "Nearby" means the game showed you the player: a nameplate appeared, you hovered over them or
-- you targeted them. The combat log is closed to addons, so someone without a visible nameplate
-- (friendly nameplates switched off, for one) is only noticed through hover or target. The alert
-- only ever draws on your own screen and plays a sound for you; nothing is sent to anyone.

local _, ns = ...

local Nearby = {}
ns.Nearby = Nearby

local COOLDOWN = 300    -- seconds per player: they walk in and out of nameplate range all the time
local RESCAN_DELAY = 2  -- seconds before looking again at nameplates whose name was hidden
local MAX_RESCANS = 3
local MAX_NAMEPLATES = 40

local lastAlert = {}
local rescanPending = false
local rescansLeft = MAX_RESCANS

-- For /pn debug: what this client really lets through.
Nearby.seen = 0
Nearby.hidden = 0
Nearby.alerts = 0
Nearby.lastName = nil

local function alertingCategory(entry)
	-- CategoriesOf puts the alerting ones first.
	local category = ns.CategoriesOf({ entry })[1]
	return category and category.alert and category or nil
end

local function showOnScreen(text)
	if RaidNotice_AddMessage and RaidWarningFrame and ChatTypeInfo and ChatTypeInfo.RAID_WARNING then
		RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo.RAID_WARNING)
	elseif UIErrorsFrame then
		UIErrorsFrame:AddMessage(text, 1, 0.3, 0.3)
	end
end

local function playSound()
	if ns.db.settings.nearbySound and PlaySound then
		PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959, "Master")
	end
end

local function announce(category, name, result, unit)
	local entry = result.entry
	local who = ns.ColorName(ns.DisplayName(name), not result.loose and entry.class or nil)
	local line = ("%s nearby: %s"):format(ns.CategoryText(category), who)
	ns.Print(line)
	if result.loose then
		-- Could be someone else, so no fanfare for this one.
		DEFAULT_CHAT_FRAME:AddMessage(("   |cff999999Name partly matches your note on %s; this may be a different player.|r"):format(entry.name))
	else
		ns.UpdateFromUnit(name, unit)
		showOnScreen(line)
		playSound()
	end
	ns.PrintNoteLines(entry, true)
	Nearby.alerts = Nearby.alerts + 1
end

-- Returns false when the name could not be read yet.
local function checkUnit(unit)
	if not (ns.db and ns.db.settings.nearbyAlert) then
		return true
	end
	local name, why = ns.ReadUnitName(unit)
	if not name then
		if why == "hidden" then
			Nearby.hidden = Nearby.hidden + 1
			return false
		end
		return true
	end
	Nearby.seen = Nearby.seen + 1
	Nearby.lastName = name

	local key = ns.MakeKey(name)
	-- Not yourself, and groupmates already got their reminder when they joined.
	if not key or key == ns.MakeKey((ns.ReadUnitName("player"))) or ns.IsGroupMember(key) then
		return true
	end
	local now = GetTime()
	for _, result in ipairs(ns.FindNotes(name)) do
		local category = alertingCategory(result.entry)
		local last = lastAlert[result.key]
		if category and (not last or now - last >= COOLDOWN) then
			lastAlert[result.key] = now
			announce(category, name, result, unit)
		end
	end
	return true
end

local function scanNameplates()
	local allRead = true
	for i = 1, MAX_NAMEPLATES do
		if not checkUnit("nameplate" .. i) then
			allRead = false
		end
	end
	return allRead
end

local function scheduleRescan()
	if rescanPending or rescansLeft <= 0 then
		return
	end
	rescansLeft = rescansLeft - 1
	rescanPending = true
	C_Timer.After(RESCAN_DELAY, ns.Guard("nearby rescan", function()
		rescanPending = false
		if not scanNameplates() then
			scheduleRescan()
		end
	end))
end

local frame = CreateFrame("Frame")
local handlers = {}

handlers.NAME_PLATE_UNIT_ADDED = function(unit)
	unit = ns.Readable(unit)
	if type(unit) == "string" and not checkUnit(unit) then
		rescansLeft = MAX_RESCANS
		scheduleRescan()
	end
end

handlers.UPDATE_MOUSEOVER_UNIT = function()
	checkUnit("mouseover")
end

handlers.PLAYER_TARGET_CHANGED = function()
	checkUnit("target")
end

-- Names hidden during a fight may be readable now.
handlers.PLAYER_REGEN_ENABLED = function()
	if not scanNameplates() then
		rescansLeft = MAX_RESCANS
		scheduleRescan()
	end
end

frame:SetScript("OnEvent", function(_, event, ...)
	ns.Guard(event, handlers[event])(...)
end)

for event in pairs(handlers) do
	if not pcall(frame.RegisterEvent, frame, event) then
		ns.eventsMissing[#ns.eventsMissing + 1] = event
	end
end
