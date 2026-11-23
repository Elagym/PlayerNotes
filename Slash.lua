-- PlayerNotes: the /pn command.

local _, ns = ...
local L = ns.L

local LIST_LIMIT = 40

-- What /pn list understands for the outstanding players.
local OUTSTANDING_WORDS = { outstanding = true, star = true, stars = true, starred = true }

local HELP = {
	L["|cffffd060/pn|r  open or close the window"],
	L["|cffffd060/pn add|r <player> <text>  add to your note on a player"],
	L["|cffffd060/pn cat|r <player> <category> [category...]  switch categories on or off"],
	L["|cffffd060/pn show|r <player>  print the note"],
	L["|cffffd060/pn del|r <player>  delete the note"],
	L["|cffffd060/pn star|r <player>  mark a player as outstanding, or take the mark off"],
	L["|cffffd060/pn role|r <player> <tank | healer | dps | none>  set the roles a player plays; several with commas: tank,dps"],
	L["|cffffd060/pn list|r [category | negative | positive | outstanding | tank | healer | dps]  list the players with a note"],
	L["|cffffd060/pn cats|r  list the categories"],
	L["|cffffd060/pn newcat|r [+|-]<name>  create a category: + positive, - negative, neither neutral"],
	L["|cffffd060/pn delcat|r <name>  delete a category"],
	L["|cffffd060/pn type|r <category> <positive | negative | neutral>  change what a category says"],
	L["|cffffd060/pn icon|r [<category> <icon>]  list the icons, or give a category one"],
	L["|cffffd060/pn alert|r [sound | <category>]  nearby alerts on or off, their sound, or a category"],
	L["|cffffd060/pn dates|r  date and zone on new notes, on or off"],
	L["|cffffd060/pn minimap|r  show or hide the minimap button"],
	L["|cffffd060/pn debug|r  what the addon sees on this client"],
	L["<player> is: |cffffffffFetto-Vandike|r, |cffffffff\"Fetto Vandike\"|r, |cffffffffFetto Vandike:|r (with the colon), or |cfffffffftarget|r."],
}

-- Splitting "<player> <the rest>" --------------------------------------------------------

-- Names have two words on this client and note text is free, so where the name stops has to be
-- settled before anything is saved. Returns name and rest, or nil and the reason.
local function parsePlayer(text)
	text = ns.Trim(text or "")
	if text == "" then
		local name = ns.ReadUnitName("target")
		if name then
			return name, ""
		end
		return nil, L["No player given, and no player targeted."]
	end

	local firstWord, afterFirst = text:match("^(%S+)%s*(.*)$")

	if firstWord:lower() == "target" then
		local name = ns.ReadUnitName("target")
		if name then
			return name, afterFirst
		end
		return nil, L["You have no player targeted."]
	end

	local quoted, afterQuote = text:match('^"([^"]+)"%s*(.*)$')
	if quoted then
		return quoted, afterQuote
	end

	-- "Fetto Vandike: griefed me". More than two words before the colon is note text, and a
	-- | means the colon belongs to an item link in the note.
	local beforeColon, afterColon = text:match("^([^:]+):%s*(.*)$")
	if beforeColon and not beforeColon:find("|", 1, true) then
		local _, spaces = ns.Trim(beforeColon):gsub("%s+", " ")
		if spaces <= 1 then
			return ns.Trim(beforeColon), afterColon
		end
	end

	-- Two words that name someone known right now: a note you have, your target, a groupmate.
	local word1, word2, afterSecond = text:match("^(%S+)%s+(%S+)%s*(.*)$")
	if word1 then
		local key = ns.MakeKey(word1 .. " " .. word2)
		local targetKey = ns.MakeKey((ns.ReadUnitName("target")))
		if key and (ns.db.players[key] or key == targetKey or ns.IsGroupMember(key)) then
			return word1 .. " " .. word2, afterSecond
		end
	end

	return firstWord, afterFirst
end

-- For commands where everything you type is the player: "/pn del Fetto Smith" must never fall
-- back to a note on some other Fetto because "Smith" was taken for the rest of the command.
local function parseWholePlayer(text)
	local name, rest = parsePlayer(text)
	if name and rest ~= "" then
		return ns.Trim(text), ""
	end
	return name, rest
end

-- A first name you typed refers to the one player with that first name. Returns the name to
-- use, or nil when it is ambiguous (after listing the candidates).
local function resolveExisting(name)
	local key = ns.MakeKey(name)
	if not key or ns.db.players[key] or key:find("-", 1, true) then
		return name
	end
	local results = ns.FindNotes(name)
	if #results == 1 then
		return results[1].entry.name
	end
	if #results > 1 then
		ns.Print(L["Several players are called %s; say which one:"]:format(name))
		for _, result in ipairs(results) do
			DEFAULT_CHAT_FRAME:AddMessage("   " .. ns.ColorName(result.entry.name, result.entry.class))
		end
		return nil
	end
	return name
end

-- After saving: if the player is your target, remember their class and spelling, and warn
-- when the note ended up under a first name alone.
local function afterSave(key)
	local targetName = ns.ReadUnitName("target")
	if targetName and ns.MakeKey(targetName) == key then
		ns.UpdateFromUnit(targetName, "target")
	end
	if key and not key:find("-", 1, true) then
		ns.Print(L["|cff999999Saved under a first name only. It can also match other players with that first name; \"First Surname\" is exact.|r"])
	end
end

-- Commands ----------------------------------------------------------------------------------

local commands = {}

function commands.help()
	for _, line in ipairs(HELP) do
		DEFAULT_CHAT_FRAME:AddMessage(line)
	end
end

function commands.add(args)
	local name, rest = parsePlayer(args)
	if not name then
		ns.Print(rest)
		return
	end
	if rest == "" then
		ns.Print(L["What should the note say? /pn add <player> <text>"])
		return
	end
	name = resolveExisting(name)
	if not name then
		return
	end
	local entry, key = ns.AddNote(name, rest)
	if not entry then
		ns.Print(key)
		return
	end
	afterSave(key)
	ns.Notify()
	ns.Print(L["Note saved:"])
	ns.PrintEntry(entry)
end

function commands.cat(args)
	local name, rest = parsePlayer(args)
	if not name then
		ns.Print(rest)
		return
	end
	if rest == "" then
		ns.Print(L["Which category? /pn cats lists them."])
		return
	end

	-- A whole phrase first ("bad healer"), then one category per word or comma.
	local chosen, unknown = {}, {}
	local whole = ns.FindCategory(rest)
	if whole then
		chosen[1] = whole
	else
		for word in rest:gmatch("[^%s,]+") do
			local category = ns.FindCategory(word)
			if category then
				chosen[#chosen + 1] = category
			else
				unknown[#unknown + 1] = word
			end
		end
	end
	-- "/pn cat Fetto Vandike griefer": one unknown word right after the name, followed by real
	-- categories, is the surname.
	if #unknown == 1 and #chosen > 0 and rest:find(unknown[1], 1, true) == 1 then
		name = name .. " " .. unknown[1]
		unknown = {}
	end
	if #unknown > 0 then
		ns.Print(L["Unknown category: %s. /pn cats lists them, /pn newcat creates one."]:format(table.concat(unknown, ", ")))
		return
	end

	name = resolveExisting(name)
	if not name then
		return
	end
	local entry, key = ns.GetOrCreateEntry(name)
	if not entry then
		ns.Print(key)
		return
	end
	for _, category in ipairs(chosen) do
		entry.categories[category.id] = (not entry.categories[category.id]) and true or nil
	end
	entry.updated = time()
	afterSave(key)
	ns.Notify()
	ns.PrintEntry(entry)
end

function commands.show(args)
	local name, rest = parseWholePlayer(args)
	if not name then
		ns.Print(rest)
		return
	end
	local results = ns.FindNotes(name)
	if #results == 0 then
		ns.Print(L["You have no note on %s."]:format(ns.DisplayName(name) or name))
		return
	end
	for _, result in ipairs(results) do
		ns.PrintEntry(result.entry)
	end
end

function commands.star(args)
	if ns.Trim(args) == "" then
		ns.Print(L["Who? /pn star <player>, or /pn star target"])
		return
	end
	local name, rest = parseWholePlayer(args)
	if not name then
		ns.Print(rest)
		return
	end
	name = resolveExisting(name)
	if not name then
		return
	end
	local on, why = ns.ToggleOutstanding(name)
	if on == nil then
		ns.Print(why)
		return
	end
	if on then
		afterSave(ns.MakeKey(name))
	end
end

-- "/pn role Fetto Vandike healer" or "... tank,dps": the last word is the roles, everything before
-- it the player (your target when there is nothing before it). The roles replace the old ones.
function commands.role(args)
	local playerText, roleText = ns.Trim(args):match("^(.-)%s*(%S+)$")
	local roles = roleText and ns.ParseRoles(roleText)
	if not roles then
		ns.Print(L["Which role? /pn role <player> <tank | healer | dps | none>, several with commas: tank,dps"])
		return
	end
	local name, rest = parseWholePlayer(playerText)
	if not name then
		ns.Print(rest)
		return
	end
	name = resolveExisting(name)
	if not name then
		return
	end
	local ok, why = ns.ChangeRoles(name, roles)
	if not ok then
		ns.Print(why)
		return
	end
	if next(roles) then
		afterSave(ns.MakeKey(name))
	end
end

function commands.del(args)
	local name, rest = parseWholePlayer(args)
	if not name then
		ns.Print(rest)
		return
	end
	name = resolveExisting(name)
	if not name then
		return
	end
	local key = ns.MakeKey(name)
	local entry = key and ns.DeleteEntry(key)
	if not entry then
		ns.Print(L["You have no note on %s."]:format(ns.DisplayName(name) or name))
		return
	end
	ns.Notify()
	-- Printed one last time, so a mistyped command costs nothing.
	ns.Print(L["Deleted your note on:"])
	ns.PrintEntry(entry)
end

function commands.list(args)
	local filter = nil
	if ns.Trim(args) ~= "" then
		-- A category of that name first, so a category called "Bad" still works.
		local category = ns.FindCategory(args)
		local kind = not category and ns.FindKind(args)
		local outstanding = not category and not kind and OUTSTANDING_WORDS[ns.Trim(args):lower()]
		local role = not category and not kind and not outstanding and ns.FindRole(args)
		role = role ~= "none" and role or nil
		filter = category and category.id or kind and ("@" .. kind.id) or outstanding and ns.OUTSTANDING.id
			or role and ("@role:" .. role.id)
		if not filter then
			ns.Print(L["Unknown category: %s. /pn cats lists them; negative, positive, outstanding, tank, healer and dps work too."]:format(ns.Trim(args)))
			return
		end
	end
	-- In the same order as the window's list.
	local items = ns.SortedEntries(filter, nil, ns.db.settings.sort)
	if #items == 0 then
		ns.Print(filter and L["Nobody in that category."] or L["You have no notes yet. /pn add <player> <text>"])
		return
	end
	ns.Print((#items == 1 and L["%d player:"] or L["%d players:"]):format(#items))
	for i = 1, math.min(#items, LIST_LIMIT) do
		local entry = items[i].entry
		local tags = ns.EntryTags(entry)
		DEFAULT_CHAT_FRAME:AddMessage("   " .. ns.VerdictTag(entry) .. ns.ColorName(entry.name, entry.class) .. (tags ~= "" and "  " .. tags or ""))
	end
	if #items > LIST_LIMIT then
		DEFAULT_CHAT_FRAME:AddMessage(L["   |cff999999...and %d more; the window (/pn) shows them all.|r"]:format(#items - LIST_LIMIT))
	end
end

function commands.cats()
	ns.Print(L["Categories:"])
	for _, kind in ipairs(ns.KINDS) do
		local labels = {}
		for _, category in ipairs(ns.db.categories) do
			if category.kind == kind.id then
				labels[#labels + 1] = ns.CategoryText(category)
			end
		end
		if #labels > 0 then
			DEFAULT_CHAT_FRAME:AddMessage("   " .. ns.KindText(kind.id) .. ": " .. table.concat(labels, ", "))
		end
	end
end

function commands.newcat(args)
	args = ns.Trim(args)
	local sign, label = args:match("^([%+%-])%s*(.*)$")
	local kindId = sign == "+" and "positive" or sign == "-" and "negative" or "neutral"
	local category, why = ns.AddCategory(label or args, kindId)
	if not category then
		ns.Print(why)
		return
	end
	ns.Notify()
	ns.Print(L["New %s category: %s"]:format(ns.KindText(category.kind, true), ns.CategoryText(category)))
end

function commands.type(args)
	local categoryText, kindText = ns.Trim(args):match("^(.-)%s+(%S+)$")
	local category = categoryText and ns.FindCategory(categoryText)
	local kind = kindText and ns.FindKind(kindText)
	if not category or not kind then
		ns.Print(L["Which category and type? /pn type <category> <positive | negative | neutral>"])
		return
	end
	category.kind = kind.id
	ns.Notify()
	ns.Print(L["%s is now %s."]:format(ns.CategoryText(category), ns.KindText(kind.id, true)))
end

function commands.delcat(args)
	local category = ns.FindCategory(args)
	if not category then
		ns.Print(L["Unknown category: %s. /pn cats lists them."]:format(ns.Trim(args)))
		return
	end
	ns.RemoveCategory(category.id)
	ns.Notify()
	ns.Print(L["Deleted the category %s and removed it from every player."]:format(ns.CategoryLabel(category)))
end

local function onOff(value)
	return value and L["|cff40ff40on|r"] or L["|cffff6060off|r"]
end

function commands.icon(args)
	args = ns.Trim(args)
	if args == "" then
		local names = {}
		for _, icon in ipairs(ns.ICONS) do
			names[#names + 1] = ns.InlineIcon(icon.path) .. " " .. icon.id
		end
		ns.Print(L["Icons: %s"]:format(table.concat(names, ", ")))
		ns.Print(L["Change one with /pn icon <category> <icon>."])
		return
	end
	local categoryText, iconText = args:match("^(.-)%s+(%S+)$")
	local category = categoryText and ns.FindCategory(categoryText)
	if not category then
		ns.Print(L["Which category and icon? /pn icon <category> <icon>; /pn cats and /pn icon list them."])
		return
	end
	local icon = ns.FindIcon(iconText)
	if not icon then
		ns.Print(L["Unknown icon: %s. /pn icon lists them."]:format(iconText))
		return
	end
	category.icon = icon.path
	ns.Notify()
	ns.Print(L["New icon: %s"]:format(ns.CategoryText(category)))
end

function commands.alert(args)
	args = ns.Trim(args)
	local settings = ns.db.settings
	if args == "" then
		settings.nearbyAlert = not settings.nearbyAlert
	elseif args:lower() == "sound" then
		settings.nearbySound = not settings.nearbySound
	else
		local category = ns.FindCategory(args)
		if not category then
			ns.Print(L["Unknown category: %s. /pn cats lists them."]:format(args))
			return
		end
		category.alert = not category.alert
		ns.Notify()
	end
	local alerting = {}
	for _, category in ipairs(ns.db.categories) do
		if category.alert then
			alerting[#alerting + 1] = ns.CategoryText(category)
		end
	end
	ns.Print(L["Nearby alerts %s, sound %s. Categories: %s"]:format(onOff(settings.nearbyAlert), onOff(settings.nearbySound),
		#alerting > 0 and table.concat(alerting, ", ") or L["none"]))
end

function commands.dates()
	local settings = ns.db.settings
	settings.datedNotes = not settings.datedNotes
	ns.Print(L["Date and zone on new notes: %s"]:format(onOff(settings.datedNotes)))
end

function commands.minimap()
	local hidden = not ns.db.settings.minimapHidden
	ns.MinimapButton.SetHidden(hidden)
	ns.Print(L["Minimap button: %s"]:format(onOff(not hidden)))
end

function commands.debug()
	local version, build, _, interface = GetBuildInfo()
	local say = function(text)
		DEFAULT_CHAT_FRAME:AddMessage("|cff66ccff[PlayerNotes]|r " .. text)
	end
	say(L["client %s (%s), interface %s"]:format(tostring(version), tostring(build), tostring(interface)))
	say(L["%d players, %d categories; saved data read at login: %s"]:format(ns.CountPlayers(), #ns.db.categories, ns.savedDataFound and L["yes"] or L["no (normal the first time)"]))
	say(L["invite hooks: %s"]:format(#ns.hooksInstalled > 0 and table.concat(ns.hooksInstalled, ", ") or L["NONE"]))
	say(L["right-click menus: %s"]:format(ns.unitMenusInstalled and L["yes"] or L["no"]))
	say(L["events the client refused: %s"]:format(#ns.eventsMissing > 0 and table.concat(ns.eventsMissing, ", ") or L["none"]))
	local scan = ns.lastScan
	say(scan and L["last group scan %ds ago: %d members, all names readable: %s"]:format(time() - scan.when, scan.members, scan.complete and L["yes"] or L["no"]) or L["no group scan yet"])
	local name, why = ns.ReadUnitName("target")
	say(L["target: %s (key %s)"]:format(tostring(name or L[why]), tostring(name and ns.MakeKey(name) or "-")))
	local who = ns.Online.lastWho
	say(who and L["last /who %ds ago: %s -> %s, %s result(s), first: %s"]:format(time() - who.when, who.filter, L[who.state], tostring(who.count or "?"), tostring(who.sample or "-")) or L["no /who sent yet"])
	if who then
		say(L["  event taken from %s frame(s); window had to be closed: %s"]:format(tostring(who.framesTaken or "?"), who.closedWindow and L["yes"] or L["no"]))
	end
	local finder = ns.GroupFinder
	local hookedNames = {}
	for functionName in pairs(finder.hooked) do
		hookedNames[#hookedNames + 1] = functionName
	end
	say(L["group finder: hooked %s; LFGBrowseFrame %s, LFGListFrame %s; %d rows drawn, %d icons, last name: %s"]:format(
		#hookedNames > 0 and table.concat(hookedNames, ", ") or L["NOTHING"],
		LFGBrowseFrame and L["yes"] or L["no"], LFGListFrame and L["yes"] or L["no"],
		finder.rowsSeen, finder.iconsShown, tostring(finder.lastName or "-")))
	local lfgForever = ns.LFGForever
	say(L["LFG Forever: %s; %d rows seen%s"]:format(L[lfgForever.state], lfgForever.rowsSeen,
		lfgForever.problem and (" (" .. lfgForever.problem .. ")") or ""))
	say(L["player tooltip: %s"]:format(tostring(ns.Tooltip.method or L["NOT INSTALLED"])))
	local classes = ns.Classes
	local missing = classes.FixMissing()
	say(L["class colours: %d note(s) still without a class; %d learned this session, last from %s"]:format(
		missing, classes.learned, L[classes.lastSource or "-"]))
	local nearby = ns.Nearby
	say(L["nearby: %s; %d players read, %d names hidden, %d alerts, last name: %s"]:format(ns.db.settings.nearbyAlert and L["on"] or L["off"],
		nearby.seen, nearby.hidden, nearby.alerts, tostring(nearby.lastName or "-")))
	say(L["last error: %s"]:format(tostring(ns.lastError or L["none"])))
end

-- Short and spelled-out forms of the same commands.
commands.note = commands.add
commands.delete = commands.del
commands.remove = commands.del
commands.category = commands.cat
commands.categories = commands.cats
commands.kind = commands.type
commands.outstanding = commands.star

-- The command -------------------------------------------------------------------------------

SLASH_PLAYERNOTES1 = "/pn"
SLASH_PLAYERNOTES2 = "/playernotes"

SlashCmdList["PLAYERNOTES"] = ns.Guard("slash", function(message)
	message = ns.Trim(message or "")
	if message == "" then
		ns.UI.Toggle()
		return
	end
	local word, args = message:match("^(%S+)%s*(.*)$")
	local command = commands[word:lower()]
	if command then
		command(args)
	else
		ns.Print(L["Unknown command: %s"]:format(word))
		commands.help()
	end
end)
