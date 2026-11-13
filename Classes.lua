-- PlayerNotes: the class of the players you have a note on, so their names show in class colours.
--
-- The game cannot be asked for the class behind a name, so the class is learned wherever the game
-- shows a player: as a unit (target, focus, mouseover, group, nameplate), in chat (the sender's
-- GUID), in an invite, the friend list, the guild roster, a /who answer or the group finder.
--
-- Everyone seen is remembered for the session, so a note written a minute after meeting someone
-- still gets their class. A note that has no class yet (written before this version, or about
-- someone not in sight) gets it as soon as one of these sources shows that player.

local _, ns = ...

local Classes = {}
ns.Classes = Classes

local SWEEP_DELAY = 1 -- seconds: a burst of roster events starts one sweep, not twenty
local LOGIN_DELAY = 5 -- seconds after login: the friend list and guild roster arrive late

local seen = {}       -- key -> class file ("WARRIOR"), for every player seen this session

-- For /pn debug.
Classes.learned = 0   -- notes that got (or changed) their class this session
Classes.lastSource = nil
Classes.lastSweep = nil

-- A class file the game can colour ("MAGE"), or nil.
local function validClass(class)
	class = ns.Readable(class)
	if type(class) ~= "string" or class == "" then
		return nil
	end
	if RAID_CLASS_COLORS and not RAID_CLASS_COLORS[class] then
		return nil
	end
	return class
end

-- The friend list only gives the class in your language ("Mage", "Magier").
local fromLocalized = nil

local function classFromLocalized(text)
	text = ns.Readable(text)
	if type(text) ~= "string" or text == "" then
		return nil
	end
	if not fromLocalized then
		fromLocalized = {}
		for _, list in ipairs({ LOCALIZED_CLASS_NAMES_MALE, LOCALIZED_CLASS_NAMES_FEMALE }) do
			if type(list) == "table" then
				for file, localized in pairs(list) do
					fromLocalized[localized] = file
				end
			end
		end
		if GetNumClasses and GetClassInfo then
			for i = 1, GetNumClasses() do
				local localized, file = GetClassInfo(i)
				if type(localized) == "string" and type(file) == "string" then
					fromLocalized[localized] = file
				end
			end
		end
	end
	return validClass(fromLocalized[text]) or validClass(text:upper())
end

-- Refreshing ---------------------------------------------------------------------------

local refreshPending = nil -- when the refresh was scheduled; it never blocks for longer than a second

-- The window shows the new colour on the next frame; several classes learned at once are one
-- refresh.
local function scheduleRefresh()
	if refreshPending and GetTime() - refreshPending < 1 then
		return
	end
	refreshPending = GetTime()
	C_Timer.After(0, ns.Guard("class refresh", function()
		refreshPending = nil
		if ns.UI and ns.UI.OnClassesChanged then
			ns.UI.OnClassesChanged()
		end
	end))
end

-- Learning -----------------------------------------------------------------------------

-- The game showed this player with this class. A player with a note gets it straight away.
function Classes.Learn(rawName, class, source)
	rawName, class = ns.Readable(rawName), validClass(class)
	if type(rawName) ~= "string" or not class then
		return
	end
	-- A numeric realm ("Name-93") is not part of a character name.
	local key = ns.MakeKey((rawName:gsub("%-%d+$", "")))
	if not key then
		return
	end
	seen[key] = class
	local entry = ns.db and ns.db.players[key]
	if entry and entry.class ~= class then
		entry.class = class
		Classes.learned = Classes.learned + 1
		Classes.lastSource = source
		scheduleRefresh()
	end
end

function Classes.FromUnit(rawName, unit)
	Classes.Learn(rawName, (select(2, UnitClass(unit))), "unit")
end

-- The player behind a GUID, from chat or an invite.
function Classes.FromGUID(guid, source)
	guid = ns.Readable(guid)
	if type(guid) ~= "string" or not guid:find("^Player%-") or not GetPlayerInfoByGUID then
		return
	end
	local ok, _, class, _, _, _, name, realm = pcall(GetPlayerInfoByGUID, guid)
	if not ok then
		return
	end
	name, realm = ns.Readable(name), ns.Readable(realm)
	if type(name) == "string" and name ~= "" then
		Classes.Learn(ns.JoinName(name, realm), class, source)
	end
end

-- The class seen this session for a key, or nil.
function Classes.Seen(key)
	return seen[key]
end

-- Looking around -------------------------------------------------------------------------

local function readUnits()
	local units = { "target", "focus", "mouseover" }
	local prefix, count = "party", GetNumSubgroupMembers()
	if IsInRaid() then
		prefix, count = "raid", GetNumGroupMembers()
	end
	count = ns.Readable(count)
	for i = 1, type(count) == "number" and count or 0 do
		units[#units + 1] = prefix .. i
	end
	for i = 1, 40 do
		units[#units + 1] = "nameplate" .. i
	end
	for _, unit in ipairs(units) do
		local name = ns.ReadUnitName(unit)
		if name then
			Classes.FromUnit(name, unit)
		end
	end
end

local function readFriends()
	local friends = C_FriendList
	if not (friends and friends.GetNumFriends and friends.GetFriendInfoByIndex) then
		return
	end
	local count = ns.Readable(friends.GetNumFriends())
	for i = 1, type(count) == "number" and count or 0 do
		local info = friends.GetFriendInfoByIndex(i)
		if type(info) == "table" then
			local class = validClass(info.classFile) or validClass(info.classFilename) or classFromLocalized(info.className)
			Classes.Learn(info.name, class, "friend list")
		end
	end
end

local function readGuild()
	if not (IsInGuild and ns.Readable(IsInGuild()) and GetNumGuildMembers and GetGuildRosterInfo) then
		return
	end
	local count = ns.Readable((GetNumGuildMembers()))
	for i = 1, type(count) == "number" and count or 0 do
		local name, _, _, _, localized, _, _, _, _, _, file = GetGuildRosterInfo(i)
		Classes.Learn(name, validClass(file) or classFromLocalized(localized), "guild")
	end
end

-- Every place that knows players right now: units in reach, friend list, guild roster.
local function lookAround()
	readUnits()
	readFriends()
	readGuild()
end

local function countMissing()
	local missing = 0
	for _, entry in pairs(ns.db.players) do
		if not validClass(entry.class) then
			missing = missing + 1
		end
	end
	return missing
end

-- A new note: its class from what was seen this session, or else from a look around.
function Classes.Fill(entry, key)
	if validClass(entry.class) then
		return
	end
	if not seen[key] then
		lookAround()
	end
	if seen[key] and entry.class ~= seen[key] then
		entry.class = seen[key]
		Classes.learned = Classes.learned + 1
		Classes.lastSource = "new note"
	end
end

-- The check: every note without a class gets one if the game can show that player now.
-- Returns how many notes are still without a class.
function Classes.FixMissing()
	if not ns.db then
		return 0
	end
	for key, entry in pairs(ns.db.players) do
		if not validClass(entry.class) and seen[key] then
			Classes.Learn(entry.name, seen[key], "seen earlier")
		end
	end
	if countMissing() > 0 then
		lookAround()
	end
	local missing = countMissing()
	Classes.lastSweep = { when = time(), missing = missing }
	return missing
end

local sweepDue = nil -- when the scheduled check runs; a lost one never blocks the next

function Classes.ScheduleSweep(delay)
	delay = delay or SWEEP_DELAY
	if (sweepDue and GetTime() <= sweepDue) or not ns.db or countMissing() == 0 then
		return
	end
	sweepDue = GetTime() + delay
	C_Timer.After(delay, ns.Guard("class check", function()
		sweepDue = nil
		Classes.FixMissing()
	end))
end

-- Events --------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
local handlers = {}

handlers.PLAYER_LOGIN = function()
	-- Asks for the guild roster; GUILD_ROSTER_UPDATE starts the check once it is there.
	if IsInGuild and ns.Readable(IsInGuild()) then
		pcall(C_GuildInfo and C_GuildInfo.GuildRoster or GuildRoster or function() end)
	end
	Classes.ScheduleSweep(LOGIN_DELAY)
end

handlers.FRIENDLIST_UPDATE = function()
	Classes.ScheduleSweep()
end

handlers.GUILD_ROSTER_UPDATE = function()
	Classes.ScheduleSweep()
end

-- Chat: the sender's GUID is the twelfth argument of every CHAT_MSG event.
local function fromChat(_, _, _, _, _, _, _, _, _, _, _, guid)
	Classes.FromGUID(guid, "chat")
end

for _, event in ipairs({
	"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE",
	"CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_CHANNEL",
	"CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
}) do
	handlers[event] = fromChat
end

frame:SetScript("OnEvent", function(_, event, ...)
	local handler = handlers[event]
	if handler then
		ns.Guard(event, handler)(...)
	end
end)

for event in pairs(handlers) do
	if not pcall(frame.RegisterEvent, frame, event) then
		ns.eventsMissing[#ns.eventsMissing + 1] = event
	end
end
