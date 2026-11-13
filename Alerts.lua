-- PlayerNotes: the reminders. They go to your own chat window through AddMessage, which only
-- draws on your screen; nothing is ever sent to the server or to another player.
--
-- A reminder fires when:
--   - you invite a player or ask to join them (hooks on the invite functions)
--   - a player invites you, or wants into your group (events)
--   - a player is in your group: you joined them or they joined you (roster scan)

local _, ns = ...

local ALERT_COOLDOWN = 120 -- seconds: inviting someone who then joins is one reminder, not two
local RETRY_DELAY = 3      -- seconds between scans while a member's name cannot be read yet
local MAX_RETRIES = 5

local recentAlerts = {}
local groupSeen = {}       -- keys of the members already handled in this group
local scanning = false     -- no roster scans before the first PLAYER_ENTERING_WORLD
local silentScan = false   -- after a /reload the group is not news: until one full scan is done
local retries = 0
local retryPending = false

ns.hooksInstalled = {}

-- A reminder ----------------------------------------------------------------------

function ns.Alert(reason, rawName)
	local results = ns.FindNotes(rawName)
	local now = GetTime()
	for _, result in ipairs(results) do
		local last = recentAlerts[result.key]
		if ns.HasContent(result.entry) and (not last or now - last >= ALERT_COOLDOWN) then
			recentAlerts[result.key] = now
			local entry = result.entry
			local who = ns.ColorName(ns.DisplayName(rawName), not result.loose and entry.class or nil)
			local tags = ns.EntryTags(entry)
			ns.Print(ns.VerdictTag(entry) .. reason:format(who) .. (tags ~= "" and "  " .. tags or ""))
			if result.loose then
				DEFAULT_CHAT_FRAME:AddMessage(("   |cff999999Name partly matches your note on %s; this may be a different player.|r"):format(entry.name))
			end
			ns.PrintNoteLines(entry, true)
		end
	end
end

-- The group -----------------------------------------------------------------------

function ns.IsGroupMember(key)
	return groupSeen[key] == true
end

local function scheduleRetry()
	if retryPending or retries >= MAX_RETRIES then
		return
	end
	retries = retries + 1
	retryPending = true
	C_Timer.After(RETRY_DELAY, ns.Guard("retry", function()
		retryPending = false
		ns.ScanGroup()
	end))
end

function ns.ScanGroup()
	local unitPrefix, count = "party", GetNumSubgroupMembers()
	if IsInRaid() then
		unitPrefix, count = "raid", GetNumGroupMembers()
	end
	local selfKey = ns.MakeKey((ns.ReadUnitName("player")))
	local members = {}
	local complete = true
	for i = 1, count do
		local unit = unitPrefix .. i
		local name, why = ns.ReadUnitName(unit)
		if name then
			local key = ns.MakeKey(name)
			if key and key ~= selfKey then
				members[key] = { name = name, unit = unit }
			end
		elseif why == "hidden" then
			complete = false
		end
	end

	for key, member in pairs(members) do
		ns.UpdateFromUnit(member.name, member.unit)
		if not groupSeen[key] then
			groupSeen[key] = true
			if not silentScan then
				ns.Alert("In your group: %s", member.name)
			end
		end
	end

	-- With names still hidden we cannot tell who left: forgetting someone now would remind
	-- you of them again as soon as they are readable.
	if complete then
		for key in pairs(groupSeen) do
			if not members[key] then
				groupSeen[key] = nil
			end
		end
		retries = 0
		silentScan = false
	else
		scheduleRetry()
	end
	ns.lastScan = { members = count, complete = complete, when = time() }
end

-- Invites ---------------------------------------------------------------------------

local function hookNameFunction(owner, functionName, reason)
	if type(owner) ~= "table" or type(owner[functionName]) ~= "function" then
		return
	end
	hooksecurefunc(owner, functionName, ns.Guard(functionName, function(name)
		name = ns.Readable(name)
		if type(name) == "string" then
			ns.Alert(reason, name)
		end
	end))
	ns.hooksInstalled[#ns.hooksInstalled + 1] = functionName
end

local function installHooks()
	hookNameFunction(C_PartyInfo, "InviteUnit", "You invited %s")
	hookNameFunction(C_PartyInfo, "ConfirmInviteUnit", "You invited %s")
	hookNameFunction(C_PartyInfo, "RequestInviteFromUnit", "You asked to join %s")
	hookNameFunction(C_PartyInfo, "ConfirmRequestInviteFromUnit", "You asked to join %s")
	-- Older spellings, only present if this client still has them.
	hookNameFunction(_G, "InviteUnit", "You invited %s")
	hookNameFunction(_G, "InviteToGroup", "You invited %s")
	hookNameFunction(_G, "RequestInviteFromUnit", "You asked to join %s")
end

-- The arguments follow the retail event: the sender's name, then the inviter's GUID seventh.
local function onPartyInvite(sender, _, _, _, _, _, guid)
	ns.Classes.FromGUID(guid, "invite")
	local name = ns.Readable(sender)
	if type(name) ~= "string" then
		name = nil
	end
	-- The GUID can give the surname when the name arrives without one (or not at all).
	if not name or not ns.MakeKey(name) or not ns.MakeKey(name):find("-", 1, true) then
		name = ns.NameFromGUID(guid) or name
	end
	if name then
		ns.Alert("%s invited you", name)
	end
end

-- Someone wants into your group (or a groupmate wants to invite them): the confirmation
-- the client asks you for names them. The functions are looked up carefully: if this client
-- does not have them, the group scan still reminds you once they are in.
local function onInviteConfirmation()
	if not (GetNextPendingInviteConfirmation and GetInviteConfirmationInfo) then
		return
	end
	local guid = GetNextPendingInviteConfirmation()
	if not guid then
		return
	end
	ns.Classes.FromGUID(guid, "invite")
	local _, name = GetInviteConfirmationInfo(guid)
	name = ns.Readable(name)
	if type(name) ~= "string" then
		name = ns.NameFromGUID(guid)
	end
	if name then
		ns.Alert("%s wants to join your group", name)
	end
end

-- Events ----------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local handlers = {}

handlers.ADDON_LOADED = function(addonName)
	if addonName ~= "PlayerNotes" then
		return
	end
	eventFrame:UnregisterEvent("ADDON_LOADED")
	ns.InitDB()
	installHooks()
	if ns.UI and ns.UI.InstallUnitMenus then
		ns.UI.InstallUnitMenus()
	end
	-- One failing does not stop the other; both report through /pn debug.
	if ns.Tooltip then
		ns.Guard("tooltip setup", ns.Tooltip.Install)()
	end
	if ns.MinimapButton then
		ns.Guard("minimap setup", ns.MinimapButton.Install)()
	end
end

handlers.PLAYER_ENTERING_WORLD = function(isInitialLogin, isReloadingUi)
	scanning = true
	if isReloadingUi then
		silentScan = true
	end
	ns.ScanGroup()
end

local function rescan()
	if scanning then
		retries = 0
		ns.ScanGroup()
	end
end

handlers.GROUP_ROSTER_UPDATE = rescan
-- Moments when names that were hidden may have become readable again.
handlers.PLAYER_REGEN_ENABLED = rescan
handlers.ENCOUNTER_END = rescan
handlers.ZONE_CHANGED_NEW_AREA = rescan

handlers.PARTY_INVITE_REQUEST = onPartyInvite
handlers.GROUP_INVITE_CONFIRMATION = onInviteConfirmation

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local handler = handlers[event]
	if handler then
		ns.Guard(event, handler)(...)
	end
end)

-- On this client, registering an event it does not know is an error: one missing event must
-- not stop the others.
ns.eventsMissing = {}
for event in pairs(handlers) do
	if not pcall(eventFrame.RegisterEvent, eventFrame, event) then
		ns.eventsMissing[#ns.eventsMissing + 1] = event
	end
end
