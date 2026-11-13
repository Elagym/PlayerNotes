-- PlayerNotes: is this player online? The game has no direct way to ask, so the answer comes
-- from the first source that knows:
--
--   1. Units in reach (target, focus, group, nameplates), then the friend list and guild roster.
--      These are certain, cost nothing, and only they can say "offline".
--   2. /who. It needs a real mouse or keyboard action (C_FriendList.SendWho is hardware-event
--      restricted), so it only runs from a click, never from a timer or an event. The server
--      silently drops queries sent too often, and /who cannot see the other faction: finding
--      nobody therefore means "not found", not "offline".
--
-- Results reach the callback as { state = ..., text = ... }, with state one of:
-- online, offline, maybe, notfound, otherfaction, checking, unchecked, busy, combat, noanswer.

local _, ns = ...

local Online = {}
ns.Online = Online

local WHO_TIMEOUT = 5      -- seconds before a /who without an answer is given up on
local WHO_MIN_INTERVAL = 6 -- seconds between two /who: faster ones would be dropped anyway
local CACHE_SECONDS = 60   -- browsing back to someone does not spend another /who
local RESTORE_DELAY = 0.5  -- seconds after an answer before the other frames get the event back
local LATE_ANSWER_GRACE = 2 -- same, after a timeout: an answer may still be on its way
local WHO_TAB = 2          -- the Who tab of the Friends window (Blizzard's own number)

local cache = {}
local pending = nil        -- the /who in flight
local lastSend = nil

local function result(state, text)
	return { state = state, text = text }
end

-- "level 40, Elwynn Forest", or "" when the client tells us neither.
local function describe(level, area)
	level, area = ns.Readable(level), ns.Readable(area)
	local parts = {}
	if type(level) == "number" and level > 0 then
		parts[#parts + 1] = "level " .. level
	end
	if type(area) == "string" and area ~= "" then
		parts[#parts + 1] = area
	end
	return table.concat(parts, ", ")
end

local function onlineText(source, level, area)
	local details = describe(level, area)
	if details ~= "" then
		return ("Online: %s (%s)"):format(details, source)
	end
	return ("Online (%s)"):format(source)
end

-- Certain sources ----------------------------------------------------------------------

local function fromUnits(key)
	local units = { "target", "focus" }
	local prefix, count = "party", GetNumSubgroupMembers()
	if IsInRaid() then
		prefix, count = "raid", GetNumGroupMembers()
	end
	local firstGroupUnit = #units + 1
	for i = 1, count do
		units[#units + 1] = prefix .. i
	end
	local lastGroupUnit = #units
	for i = 1, 40 do
		units[#units + 1] = "nameplate" .. i
	end

	for index, unit in ipairs(units) do
		local name = ns.ReadUnitName(unit)
		if name and ns.MakeKey(name) == key then
			ns.UpdateFromUnit(name, unit)
			local inGroup = index >= firstGroupUnit and index <= lastGroupUnit
			if ns.Readable(UnitIsConnected(unit)) == false then
				return result("offline", "Offline (in your group)")
			end
			return result("online", onlineText(inGroup and "in your group" or "nearby"))
		end
	end
	return nil
end

local function fromFriends(key)
	local friends = C_FriendList
	if not (friends and friends.GetNumFriends and friends.GetFriendInfoByIndex) then
		return nil
	end
	local count = ns.Readable(friends.GetNumFriends())
	for i = 1, type(count) == "number" and count or 0 do
		local info = friends.GetFriendInfoByIndex(i)
		local name = info and ns.Readable(info.name)
		if type(name) == "string" and ns.MakeKey(name) == key then
			local connected = ns.Readable(info.connected)
			if connected == nil then
				return nil
			end
			if connected then
				return result("online", onlineText("friend list", info.level, info.area))
			end
			return result("offline", "Offline (friend list)")
		end
	end
	return nil
end

local function fromGuild(key)
	if not (IsInGuild and IsInGuild() and GetGuildRosterInfo) then
		return nil
	end
	local count = ns.Readable((GetNumGuildMembers()))
	for i = 1, type(count) == "number" and count or 0 do
		local name, _, _, level, _, zone, _, _, online = GetGuildRosterInfo(i)
		name = ns.Readable(name)
		if type(name) == "string" and ns.MakeKey(name) == key then
			online = ns.Readable(online)
			if online == nil then
				return nil
			end
			if online then
				return result("online", onlineText("guild", level, zone))
			end
			return result("offline", "Offline (guild)")
		end
	end
	return nil
end

local function fromCertainSources(key)
	return fromUnits(key) or fromFriends(key) or fromGuild(key)
end

-- /who ----------------------------------------------------------------------------------

local whoFrame = CreateFrame("Frame")

local function setWhoToUi(value)
	local friends = C_FriendList
	local setter = friends.SetWhoToUi or friends.SetWhoToUI
	if setter then
		setter(value)
	end
end

-- The Who window opens because WHO_LIST_UPDATE reaches the Friends window, whose handler calls
-- ShowUIPanel. So while our query runs, nobody but us gets that event.
local takenFrames = nil      -- the frames we took it from; nil when /who is back to normal
local restoreToken = nil     -- identifies the scheduled restore that is still valid
local friendsWasOpen = false
local closeHookInstalled = false

-- The safety net, should the window open anyway while /who is ours: close it again. Not when you
-- had it open already, and not for another tab, which can only be you pressing the friends key.
local function installCloseHook()
	if closeHookInstalled or not FriendsFrame then
		return
	end
	closeHookInstalled = true
	FriendsFrame:HookScript("OnShow", function(self)
		if not takenFrames or friendsWasOpen then
			return
		end
		if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(self) ~= WHO_TAB then
			return
		end
		-- Next frame: this runs inside ShowUIPanel, which must finish first.
		C_Timer.After(0, ns.Guard("close who window", function()
			if self:IsShown() and not InCombatLockdown() then
				HideUIPanel(self)
				Online.lastWho.closedWindow = true
			end
		end))
	end)
end

local function takeOverWho()
	restoreToken = nil -- a restore still scheduled must not undo this new query
	if takenFrames then
		return
	end
	installCloseHook()
	friendsWasOpen = FriendsFrame ~= nil and FriendsFrame:IsShown() == true
	takenFrames = {}
	for _, frame in ipairs({ GetFramesRegisteredForEvent("WHO_LIST_UPDATE") }) do
		if frame ~= whoFrame and not (frame.IsForbidden and frame:IsForbidden()) then
			frame:UnregisterEvent("WHO_LIST_UPDATE")
			takenFrames[#takenFrames + 1] = frame
		end
	end
	Online.lastWho.framesTaken = #takenFrames
	whoFrame:RegisterEvent("WHO_LIST_UPDATE")
	setWhoToUi(true)
end

local function restoreWho()
	whoFrame:UnregisterEvent("WHO_LIST_UPDATE")
	for _, frame in ipairs(takenFrames or {}) do
		frame:RegisterEvent("WHO_LIST_UPDATE")
	end
	takenFrames = nil
	setWhoToUi(false)
end

-- Never directly from our event handler: a frame registered while the event is being delivered
-- goes to the end of the list and still receives it, which opens the window after all.
local function scheduleRestore(delay)
	local token = {}
	restoreToken = token
	C_Timer.After(delay, ns.Guard("who restore", function()
		if restoreToken == token then
			restoreToken = nil
			restoreWho()
		end
	end))
end

local function firstPart(key)
	return key:match("^[^%-]+")
end

-- What the /who list says about this player.
local function readWhoResults(key)
	local count = ns.Readable((C_FriendList.GetNumWhoResults()))
	local maybe = nil
	local sampleName = nil
	for i = 1, type(count) == "number" and count or 0 do
		local info = C_FriendList.GetWhoInfo(i)
		local name = info and ns.Readable(info.fullName)
		if type(name) == "string" then
			ns.Classes.Learn(name, info.filename, "/who")
			sampleName = sampleName or name
			-- The docs promise Name-Realm; a numeric realm is not part of a character name.
			local otherKey = ns.MakeKey((name:gsub("%-%d+$", "")))
			if otherKey == key then
				Online.lastWho.sample = name
				return result("online", onlineText("/who", info.level, info.area))
			end
			-- One side has no surname: it may or may not be the same person.
			if otherKey and firstPart(otherKey) == firstPart(key)
				and (not otherKey:find("-", 1, true) or not key:find("-", 1, true)) then
				maybe = maybe or result("maybe", ("Maybe online: found %s (%s)"):format(ns.DisplayName(name), describe(info.level, info.area)))
			end
		end
	end
	Online.lastWho.sample = sampleName
	Online.lastWho.count = count
	return maybe or result("notfound", "Not found by /who: offline, or not visible to you")
end

local function finishWho(outcome, restoreDelay)
	local query = pending
	scheduleRestore(restoreDelay)
	pending = nil
	cache[query.key] = (outcome.state ~= "noanswer") and { result = outcome, at = GetTime() } or nil
	Online.lastWho.state = outcome.state
	query.callback(outcome)
end

whoFrame:SetScript("OnEvent", ns.Guard("who", function()
	if pending then
		finishWho(readWhoResults(pending.key), RESTORE_DELAY)
	end
end))

local function sendWho(key, entry, callback)
	local firstName = (ns.DisplayName(entry.name) or entry.name):match("^%S+")
	local filter = ('n-"%s"'):format(firstName)
	local query = { key = key, callback = callback }
	pending = query
	lastSend = GetTime()
	Online.lastWho = { filter = filter, state = "sent", when = time() }
	takeOverWho()
	local origin = Enum and Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Social or 1
	local ok, err = pcall(C_FriendList.SendWho, filter, origin)
	if not ok then
		ns.lastError = "SendWho: " .. tostring(err)
		finishWho(result("noanswer", "/who is not available here"), 0)
		return result("noanswer", "/who is not available here")
	end
	C_Timer.After(WHO_TIMEOUT, ns.Guard("who timeout", function()
		if pending == query then
			finishWho(result("noanswer", "No answer from /who; click Check to try again"), LATE_ANSWER_GRACE)
		end
	end))
	return result("checking", "Checking with /who...")
end

-- Asking ---------------------------------------------------------------------------------

-- Options: canSendWho (only from a click), force (a fresh /who even if a recent answer exists).
-- The callback may run right away and again later, when /who answers.
function Online.Check(key, options, callback)
	local entry = ns.db.players[key]
	if not entry then
		return
	end

	local certain = fromCertainSources(key)
	if certain then
		callback(certain)
		return
	end

	local myFaction = ns.Readable((UnitFactionGroup("player")))
	if entry.faction and myFaction and entry.faction ~= myFaction then
		callback(result("otherfaction", "Unknown: /who cannot see the other faction"))
		return
	end

	if pending and pending.key == key then
		pending.callback = callback
		callback(result("checking", "Checking with /who..."))
		return
	end

	local cached = cache[key]
	if cached and not options.force and GetTime() - cached.at < CACHE_SECONDS then
		callback(result(cached.result.state, ("%s, %ds ago"):format(cached.result.text, GetTime() - cached.at)))
		return
	end

	if not options.canSendWho then
		callback(result("unchecked", "Online status not checked yet"))
		return
	end

	if GuildRoster or (C_GuildInfo and C_GuildInfo.GuildRoster) then
		-- Asks for a fresher roster for the next look; the answer is not waited for.
		pcall(C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster)
	end

	if InCombatLockdown() then
		callback(result("combat", "In combat: click Check afterwards"))
		return
	end
	if pending or (lastSend and GetTime() - lastSend < WHO_MIN_INTERVAL) then
		callback(result("busy", "/who is cooling down: click Check in a few seconds"))
		return
	end

	callback(sendWho(key, entry, callback))
end
