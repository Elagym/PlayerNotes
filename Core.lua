-- PlayerNotes: the data. Everything about names, notes and categories lives here;
-- Alerts, UI and Slash only call these functions.
--
-- Two things about World of Warcraft: Forever (retail client, Interface 16001) shape this file:
--
-- 1. Values read from the API can be "secret": addon code may display them but not compare
--    them, concatenate them or use them as table keys. ns.Readable turns a secret into nil,
--    and must wrap anything that comes from the API before it is used.
--
-- 2. Characters have a first name and a surname ("Glory Boy"). Depending on the API the same
--    player arrives as "Glory Boy", "Glory-Boy", or "Glory" with "Boy" in the realm slot, and
--    some places give the first name alone. ns.MakeKey folds the full forms into one key
--    ("glory-boy"), and ns.FindNotes handles the first-name-only case as a loose match.

local _, ns = ...

ns.MAX_CATEGORIES = 20

-- What a category says about a player. The order is the order of the sections in the window.
ns.KINDS = {
	{ id = "positive", label = "Positive", color = "40ff40" },
	{ id = "negative", label = "Negative", color = "ff5050" },
	{ id = "neutral", label = "Neutral", color = "aaaaaa" },
}

-- The verdict on a player, from the kinds of their categories. Neutral has no tag.
local VERDICTS = {
	negative = { label = "Caution", color = "ff5050" },
	mixed = { label = "Mixed", color = "ffd040" },
	positive = { label = "Good", color = "40ff40" },
}

local PREFIX = "|cff66ccff[PlayerNotes]|r "
local NOTE_COLOR = "|cffffe9a8"

local RAID_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_"
local ICON_FOLDER = "Interface\\Icons\\"

-- The icons a category can have. All of them date from the original game.
ns.ICONS = {
	{ id = "skull", label = "Skull", path = RAID_ICON .. "8" },
	{ id = "cross", label = "Cross", path = RAID_ICON .. "7" },
	{ id = "square", label = "Square", path = RAID_ICON .. "6" },
	{ id = "moon", label = "Moon", path = RAID_ICON .. "5" },
	{ id = "triangle", label = "Triangle", path = RAID_ICON .. "4" },
	{ id = "diamond", label = "Diamond", path = RAID_ICON .. "3" },
	{ id = "circle", label = "Circle", path = RAID_ICON .. "2" },
	{ id = "star", label = "Star", path = RAID_ICON .. "1" },
	{ id = "stealth", label = "Stealth", path = ICON_FOLDER .. "Ability_Stealth" },
	{ id = "silence", label = "Silence", path = ICON_FOLDER .. "Spell_Shadow_ImpPhaseShift" },
	{ id = "sprint", label = "Sprint", path = ICON_FOLDER .. "Ability_Rogue_Sprint" },
	{ id = "coin", label = "Coin", path = ICON_FOLDER .. "INV_Misc_Coin_02" },
	{ id = "poison", label = "Poison", path = ICON_FOLDER .. "Spell_Nature_CorrosiveBreath" },
	{ id = "mug", label = "Mug", path = ICON_FOLDER .. "INV_Drink_05" },
	{ id = "heal", label = "Heal", path = ICON_FOLDER .. "Spell_Holy_Renew" },
	{ id = "heart", label = "Heart", path = ICON_FOLDER .. "INV_ValentinesCandy" },
	{ id = "sword", label = "Sword", path = ICON_FOLDER .. "INV_Sword_04" },
	{ id = "shield", label = "Shield", path = ICON_FOLDER .. "INV_Shield_06" },
	{ id = "bag", label = "Bag", path = ICON_FOLDER .. "INV_Misc_Bag_08" },
	{ id = "note", label = "Note", path = ICON_FOLDER .. "INV_Misc_Note_01" },
	{ id = "crown", label = "Crown", path = ICON_FOLDER .. "INV_Crown_01" },
}

-- A player you marked as outstanding. Not a category you can delete but a mark of its own,
-- shown first wherever the player's categories are, in legendary orange with a crown. It counts
-- as positive.
ns.OUTSTANDING = {
	id = "@outstanding",
	label = "Outstanding",
	color = "ff8000",
	icon = ICON_FOLDER .. "INV_Crown_01",
	kind = "positive",
}

-- The role a player plays: tank, healer or DPS. A player without one is "n/a". The icons are the
-- game's own role icons; `coords` is their place on that texture, in pixels (left, right, top,
-- bottom of 64).
local ROLE_TEXTURE = "Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"
ns.ROLES = {
	{ id = "tank", label = "Tank", plural = "Tanks", color = "6fa8ff", coords = { 0, 19, 22, 41 } },
	{ id = "healer", label = "Healer", plural = "Healers", color = "40ff80", coords = { 20, 39, 1, 20 } },
	{ id = "dps", label = "DPS", plural = "DPS", color = "ff7060", coords = { 20, 39, 22, 41 } },
}

local DEFAULT_CATEGORIES = {
	{ id = "social", label = "Social", color = "4dd08a", icon = ICON_FOLDER .. "INV_Drink_05", kind = "positive" },
	{ id = "helpful", label = "Helpful", color = "5aa9ff", icon = ICON_FOLDER .. "Spell_Holy_Renew", kind = "positive" },
	{ id = "skilled", label = "Skilled", color = "7fe0ff", icon = RAID_ICON .. "1", kind = "positive" },
	{ id = "generous", label = "Generous", color = "ffd700", icon = ICON_FOLDER .. "INV_ValentinesCandy", kind = "positive" },
	{ id = "griefer", label = "Griefer", color = "ff5a5a", icon = RAID_ICON .. "8", kind = "negative", alert = true },
	{ id = "ninja", label = "Ninja", color = "ff9a3d", icon = ICON_FOLDER .. "Ability_Stealth", kind = "negative" },
	{ id = "scammer", label = "Scammer", color = "d77bff", icon = ICON_FOLDER .. "INV_Misc_Coin_02", kind = "negative" },
	{ id = "toxic", label = "Toxic", color = "e0d040", icon = ICON_FOLDER .. "Spell_Nature_CorrosiveBreath", kind = "negative" },
	{ id = "asocial", label = "Asocial", color = "b0b0b0", icon = ICON_FOLDER .. "Spell_Shadow_ImpPhaseShift", kind = "negative" },
	{ id = "unhelpful", label = "Unhelpful", color = "c08060", icon = RAID_ICON .. "7", kind = "negative" },
	{ id = "quitter", label = "Quitter", color = "ff7f9f", icon = ICON_FOLDER .. "Ability_Rogue_Sprint", kind = "negative" },
}

-- Categories that saved data from before version 3 does not have yet; they are added once.
local NEW_IN_VERSION_3 = { "skilled", "generous", "asocial", "unhelpful", "quitter" }

-- Colours and icons handed out to the categories you create yourself.
local CUSTOM_COLORS = { "40d0d0", "ff7fb0", "a0e060", "c0a0ff", "ffc070", "80c0c0" }
local CUSTOM_ICONS = { RAID_ICON .. "1", RAID_ICON .. "2", RAID_ICON .. "3", RAID_ICON .. "4", RAID_ICON .. "5", RAID_ICON .. "6" }

local DEFAULT_SETTINGS = {
	nearbyAlert = true,
	nearbySound = true,
	datedNotes = true,
	minimapHidden = false,
	minimapAngle = 215,
	sort = "name",
}

-- The orders the list can have. `short` goes on the button.
ns.SORT_MODES = {
	{ id = "name", label = "Name", short = "Name" },
	{ id = "updated", label = "Recently changed", short = "Changed" },
	{ id = "added", label = "Recently added", short = "Added" },
	{ id = "category", label = "Category", short = "Category" },
}

-- Helpers --------------------------------------------------------------------

function ns.IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value) == true
end

function ns.Readable(value)
	if value == nil or ns.IsSecret(value) then
		return nil
	end
	return value
end

function ns.Trim(text)
	return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

function ns.Print(message)
	DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. message)
end

-- Cuts at most `max` bytes without splitting a UTF-8 character.
function ns.Truncate(text, max)
	if #text <= max then
		return text, false
	end
	local cut = max
	while cut > 0 do
		local byte = text:byte(cut + 1)
		if not byte or byte < 0x80 or byte >= 0xC0 then
			break
		end
		cut = cut - 1
	end
	return text:sub(1, cut), true
end

-- Runs handlers protected: one error is announced once and kept for /pn debug, so a client
-- surprise in an event can never break anything else or spam the chat.
function ns.Guard(label, fn)
	return function(...)
		local ok, err = pcall(fn, ...)
		if not ok then
			ns.lastError = label .. ": " .. tostring(err)
			if not ns.errorShown then
				ns.errorShown = true
				ns.Print("|cffff6060Something went wrong; /pn debug has the details.|r")
			end
		end
	end
end

-- Names ------------------------------------------------------------------------

local function nameParts(raw)
	if type(raw) ~= "string" then
		return nil
	end
	local parts = {}
	for part in raw:gmatch("[^%s%-]+") do
		parts[#parts + 1] = part
	end
	return #parts > 0 and parts or nil
end

-- "Fetto Vandike", "Fetto-Vandike" and "fetto vandike" -> "fetto-vandike"
function ns.MakeKey(raw)
	local parts = nameParts(raw)
	if not parts then
		return nil
	end
	return table.concat(parts, "-"):lower()
end

-- "fetto-vandike" -> "Fetto Vandike"
function ns.DisplayName(raw)
	local parts = nameParts(raw)
	if not parts then
		return nil
	end
	for i, part in ipairs(parts) do
		parts[i] = part:sub(1, 1):upper() .. part:sub(2)
	end
	return table.concat(parts, " ")
end

-- For names typed by you. Returns display name and key, or nil and the reason.
function ns.ValidateName(raw)
	if type(raw) ~= "string" or ns.Trim(raw) == "" then
		return nil, "No player name given."
	end
	local parts = nameParts(raw)
	if not parts or #parts > 3 or #raw > 64 or raw:find('[|:;,"%d%c]') then
		return nil, ("'%s' does not look like a character name."):format(raw)
	end
	return ns.DisplayName(raw), ns.MakeKey(raw)
end

-- The second value from UnitName is a surname on Forever. Character names have no digits, so
-- a value with digits is a real realm id (this client's realm folder is "93") and is dropped.
function ns.JoinName(name, realm)
	if type(realm) == "string" and realm ~= "" and not realm:find("%d") then
		return name .. "-" .. realm
	end
	return name
end

-- The name of a player unit. Without a name the second value says why:
-- "absent" (no such player, nothing to wait for) or "hidden" (secret or not loaded yet).
function ns.ReadUnitName(unit)
	local exists = UnitExists(unit)
	if ns.IsSecret(exists) then
		return nil, "hidden"
	end
	if not exists then
		return nil, "absent"
	end
	local isPlayer = UnitIsPlayer(unit)
	if ns.IsSecret(isPlayer) then
		return nil, "hidden"
	end
	if not isPlayer then
		return nil, "absent"
	end
	local name, realm = UnitName(unit)
	if ns.IsSecret(name) or ns.IsSecret(realm) then
		return nil, "hidden"
	end
	if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then
		return nil, "hidden"
	end
	return ns.JoinName(name, realm)
end

-- The name behind a GUID, or nil.
function ns.NameFromGUID(guid)
	guid = ns.Readable(guid)
	if type(guid) ~= "string" or not guid:find("^Player%-") or not GetPlayerInfoByGUID then
		return nil
	end
	local ok, _, _, _, _, _, name, realm = pcall(GetPlayerInfoByGUID, guid)
	if not ok or ns.IsSecret(name) or ns.IsSecret(realm) or type(name) ~= "string" or name == "" then
		return nil
	end
	return ns.JoinName(name, realm)
end

function ns.ColorName(display, class)
	local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if color and color.colorStr then
		return "|c" .. color.colorStr .. display .. "|r"
	end
	return "|cffffffff" .. display .. "|r"
end

-- Saved data -------------------------------------------------------------------

function ns.InitDB()
	ns.savedDataFound = type(PlayerNotesDB) == "table"
	if not ns.savedDataFound then
		PlayerNotesDB = {}
	end
	local db = PlayerNotesDB
	local savedVersion = type(db.version) == "number" and db.version or 1
	db.version = 3
	if type(db.players) ~= "table" then
		db.players = {}
	end
	local function newCategory(default)
		return { id = default.id, label = default.label, color = default.color }
	end
	local function defaultFor(id)
		for _, default in ipairs(DEFAULT_CATEGORIES) do
			if default.id == id then
				return default
			end
		end
		return nil
	end
	if type(db.categories) ~= "table" then
		db.categories = {}
		for i, default in ipairs(DEFAULT_CATEGORIES) do
			db.categories[i] = newCategory(default)
		end
	elseif savedVersion < 3 then
		-- The categories this version brings, unless you already made one with that name.
		for _, id in ipairs(NEW_IN_VERSION_3) do
			local exists = false
			for _, category in ipairs(db.categories) do
				exists = exists or category.id == id
			end
			if not exists and #db.categories < ns.MAX_CATEGORIES then
				db.categories[#db.categories + 1] = newCategory(defaultFor(id))
			end
		end
	end
	-- Categories saved by an earlier version get an icon, a kind and an alert setting here, and
	-- so do new ones. A choice you made is kept, including "no alert".
	for i, category in ipairs(db.categories) do
		local default = defaultFor(category.id)
		if type(category.icon) ~= "string" then
			category.icon = default and default.icon or CUSTOM_ICONS[(i - 1) % #CUSTOM_ICONS + 1]
		end
		if not ns.GetKind(category.kind) then
			category.kind = default and default.kind or "neutral"
		end
		if category.alert == nil then
			category.alert = default and default.alert or false
		end
	end
	if type(db.settings) ~= "table" then
		db.settings = {}
	end
	for name, value in pairs(DEFAULT_SETTINGS) do
		if db.settings[name] == nil then
			db.settings[name] = value
		end
	end
	ns.db = db
end

-- Tells an open window that the data changed from elsewhere (slash command, dialog).
function ns.Notify()
	if ns.UI and ns.UI.OnDataChanged then
		ns.UI.OnDataChanged()
	end
	if ns.GroupFinder then
		ns.GroupFinder.Refresh()
	end
end

-- Categories ---------------------------------------------------------------------

function ns.GetCategory(id)
	for _, category in ipairs(ns.db.categories) do
		if category.id == id then
			return category
		end
	end
	return nil
end

-- Icons in Interface\Icons have a border built into the image; this cuts it off.
local function hasIconBorder(path)
	return path:sub(1, #ICON_FOLDER) == ICON_FOLDER
end

-- An icon inside a line of text.
function ns.InlineIcon(path, size)
	size = size or 14
	if hasIconBorder(path) then
		return ("|T%s:%d:%d:0:0:64:64:5:59:5:59|t"):format(path, size, size)
	end
	return ("|T%s:%d:%d|t"):format(path, size, size)
end

-- An icon on a texture object.
function ns.SetIconTexture(texture, path)
	texture:SetTexture(path)
	if hasIconBorder(path) then
		texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	else
		texture:SetTexCoord(0, 1, 0, 1)
	end
end

function ns.FindIcon(text)
	text = ns.Trim(text or ""):lower()
	for _, icon in ipairs(ns.ICONS) do
		if icon.id == text then
			return icon
		end
	end
	return nil
end

function ns.CategoryText(category)
	return ns.InlineIcon(category.icon) .. " |cff" .. category.color .. category.label .. "|r"
end

-- Kinds -----------------------------------------------------------------------------

function ns.GetKind(id)
	for _, kind in ipairs(ns.KINDS) do
		if kind.id == id then
			return kind
		end
	end
	return nil
end

-- "pos", "+", "good" and the like, for what you type.
local KIND_WORDS = {
	positive = "positive", pos = "positive", good = "positive", ["+"] = "positive",
	negative = "negative", neg = "negative", bad = "negative", ["-"] = "negative",
	neutral = "neutral", none = "neutral", other = "neutral",
}

function ns.FindKind(text)
	return ns.GetKind(KIND_WORDS[ns.Trim(text or ""):lower()])
end

function ns.KindText(kindId)
	local kind = ns.GetKind(kindId) or ns.GetKind("neutral")
	return "|cff" .. kind.color .. kind.label .. "|r"
end

function ns.HasKind(entry, kindId)
	if kindId == "positive" and entry.outstanding then
		return true
	end
	for id in pairs(entry.categories or {}) do
		local category = ns.GetCategory(id)
		if category and category.kind == kindId then
			return true
		end
	end
	return false
end

-- "negative", "positive", "mixed" (both) or "neutral".
function ns.Verdict(entry)
	local negative, positive = ns.HasKind(entry, "negative"), ns.HasKind(entry, "positive")
	if negative and positive then
		return "mixed"
	end
	return negative and "negative" or positive and "positive" or "neutral"
end

-- "Caution: " in red, "Good: " in green, "Mixed: " in yellow; nothing for neutral.
function ns.VerdictTag(entry)
	local look = VERDICTS[ns.Verdict(entry)]
	return look and ("|cff%s%s:|r "):format(look.color, look.label) or ""
end

-- The colour of the verdict, as r, g, b, or nil for neutral.
function ns.VerdictColor(entry)
	local look = VERDICTS[ns.Verdict(entry)]
	if not look then
		return nil
	end
	local hex = look.color
	return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end

-- Every category in the order it is shown on a player: the ones that alert, then the other
-- negative ones, neutral, and positive last; list order within each.
function ns.CategoryOrder()
	local order = {}
	local function add(test)
		for _, category in ipairs(ns.db.categories) do
			if test(category) then
				order[#order + 1] = category
			end
		end
	end
	add(function(c) return c.alert == true end)
	for _, kindId in ipairs({ "negative", "neutral", "positive" }) do
		add(function(c) return c.alert ~= true and (c.kind or "neutral") == kindId end)
	end
	return order
end

-- The categories on these entries, each once, in that order; the outstanding mark comes first.
function ns.CategoriesOf(entries)
	local found = {}
	for _, entry in ipairs(entries) do
		if entry.outstanding then
			found[1] = ns.OUTSTANDING
			break
		end
	end
	for _, category in ipairs(ns.CategoryOrder()) do
		for _, entry in ipairs(entries) do
			if entry.categories and entry.categories[category.id] then
				found[#found + 1] = category
				break
			end
		end
	end
	return found
end

-- The entry's categories with icon and colour: "Griefer, Ninja". Empty when none.
function ns.CategoryTags(entry)
	local tags = {}
	for _, category in ipairs(ns.CategoriesOf({ entry })) do
		tags[#tags + 1] = ns.CategoryText(category)
	end
	return table.concat(tags, ", ")
end

-- The same, as icons only, for where space is short.
function ns.CategoryIcons(entry, size)
	local icons = {}
	for _, category in ipairs(ns.CategoriesOf({ entry })) do
		icons[#icons + 1] = ns.InlineIcon(category.icon, size)
	end
	return table.concat(icons, " ")
end

-- Roles ------------------------------------------------------------------------------

function ns.GetRole(id)
	for _, role in ipairs(ns.ROLES) do
		if role.id == id then
			return role
		end
	end
	return nil
end

-- What you can type for a role. "none" (and the like) means n/a: no role.
local ROLE_WORDS = {
	tank = "tank", tanks = "tank", t = "tank", prot = "tank",
	healer = "healer", healers = "healer", heal = "healer", heals = "healer", h = "healer",
	dps = "dps", damage = "dps", dd = "dps", damager = "dps", d = "dps",
	none = "none", na = "none", ["n/a"] = "none", ["-"] = "none", clear = "none", off = "none",
}

-- The role for what you typed, "none" for n/a, or nil when it is not a role word.
function ns.FindRole(text)
	local id = ROLE_WORDS[ns.Trim(text or ""):lower()]
	if id == "none" then
		return "none"
	end
	return ns.GetRole(id)
end

function ns.RoleIcon(roleId, size)
	local role = ns.GetRole(roleId)
	if not role then
		return ""
	end
	size = size or 14
	local c = role.coords
	return ("|T%s:%d:%d:0:0:64:64:%d:%d:%d:%d|t"):format(ROLE_TEXTURE, size, size, c[1], c[2], c[3], c[4])
end

-- The role with its icon and colour, "n/a" in grey without one.
function ns.RoleLabel(roleId)
	local role = ns.GetRole(roleId)
	if not role then
		return "|cff999999n/a|r"
	end
	return ns.RoleIcon(role.id) .. " |cff" .. role.color .. role.label .. "|r"
end

-- The player's role, or "" when they have none.
function ns.RoleText(entry)
	return ns.GetRole(entry.role) and ns.RoleLabel(entry.role) or ""
end

-- What is shown after a player's name: their role, then their categories.
function ns.EntryTags(entry)
	local role, tags = ns.RoleText(entry), ns.CategoryTags(entry)
	if role ~= "" and tags ~= "" then
		return role .. "  " .. tags
	end
	return role .. tags
end

-- The same as icons only, for the list.
function ns.EntryIcons(entry, size)
	local role, icons = ns.RoleIcon(entry.role, size), ns.CategoryIcons(entry, size)
	if role ~= "" and icons ~= "" then
		return role .. " " .. icons
	end
	return role .. icons
end

-- Gives a player a role, or takes it away with nil or "none". A player who had nothing else is
-- removed again. Returns the entry (nil when removed) and its key, or nil and the reason.
function ns.SetRole(rawName, roleId)
	local entry, key = ns.GetOrCreateEntry(rawName)
	if not entry then
		return nil, key
	end
	entry.role = ns.GetRole(roleId) and roleId or nil
	entry.updated = time()
	if not ns.HasContent(entry) then
		ns.db.players[key] = nil
		return nil, key
	end
	return entry, key
end

-- Sets the role, tells you in the chat and refreshes what is on screen. Returns true, or nil and
-- the reason.
function ns.ChangeRole(rawName, roleId)
	local display = ns.ValidateName(rawName)
	local entry, why = ns.SetRole(rawName, roleId)
	if not entry and not display then
		return nil, why
	end
	ns.Notify()
	local who = ns.ColorName(entry and entry.name or display, entry and entry.class)
	if ns.GetRole(roleId) then
		ns.Print(("%s plays %s."):format(who, ns.RoleLabel(roleId)))
	else
		ns.Print(("%s has no role any more (n/a)."):format(who))
	end
	return true
end

-- `kindId` is "positive", "negative" or "neutral" (the default).
function ns.AddCategory(label, kindId)
	label = ns.Trim(label or "")
	if label == "" then
		return nil, "Give the category a name."
	end
	if #label > 24 or label:find('[|,"@%c]') then
		return nil, "Category names are at most 24 characters, without | , @ or quotes."
	end
	local id = label:lower()
	if ns.GetCategory(id) then
		return nil, ("Category '%s' already exists."):format(label)
	end
	local categories = ns.db.categories
	if #categories >= ns.MAX_CATEGORIES then
		return nil, ("You can have at most %d categories."):format(ns.MAX_CATEGORIES)
	end
	local category = {
		id = id,
		label = label,
		color = CUSTOM_COLORS[#categories % #CUSTOM_COLORS + 1],
		icon = CUSTOM_ICONS[#categories % #CUSTOM_ICONS + 1],
		kind = ns.GetKind(kindId) and kindId or "neutral",
		alert = false,
	}
	categories[#categories + 1] = category
	return category
end

-- Removes the category from the list and from every player.
function ns.RemoveCategory(id)
	local categories = ns.db.categories
	for i, category in ipairs(categories) do
		if category.id == id then
			table.remove(categories, i)
			for _, entry in pairs(ns.db.players) do
				if entry.categories then
					entry.categories[id] = nil
				end
			end
			return true
		end
	end
	return false
end

-- Players ------------------------------------------------------------------------

function ns.HasContent(entry)
	return entry.outstanding == true or ns.GetRole(entry.role) ~= nil or (entry.note and entry.note ~= "") or (entry.categories and next(entry.categories) ~= nil)
end

-- Marks a player as outstanding, or takes the mark off. A player who had nothing else is
-- removed again with it. Returns the entry (nil when removed) and its key, or nil and the reason.
function ns.SetOutstanding(rawName, on)
	local entry, key = ns.GetOrCreateEntry(rawName)
	if not entry then
		return nil, key
	end
	entry.outstanding = on and true or nil
	entry.updated = time()
	if not on and not ns.HasContent(entry) then
		ns.db.players[key] = nil
		return nil, key
	end
	return entry, key
end

-- Switches the mark, tells you in the chat and refreshes what is on screen. Returns whether the
-- player is outstanding now, or nil and the reason.
function ns.ToggleOutstanding(rawName)
	local key = ns.MakeKey(rawName)
	local current = key and ns.db.players[key]
	local on = not (current and current.outstanding)
	local entry, why = ns.SetOutstanding(rawName, on)
	if on and not entry then
		return nil, why
	end
	ns.Notify()
	local who = ns.ColorName(entry and entry.name or ns.DisplayName(rawName), entry and entry.class)
	if on then
		ns.Print(("%s is now %s."):format(who, ns.CategoryText(ns.OUTSTANDING)))
	else
		ns.Print(("%s is no longer outstanding."):format(who))
	end
	return on
end

-- The entry for a name, created when needed. Returns entry and key, or nil and the reason.
function ns.GetOrCreateEntry(rawName)
	local display, key = ns.ValidateName(rawName)
	if not display then
		return nil, key
	end
	local entry = ns.db.players[key]
	if not entry then
		entry = { name = display, note = "", categories = {}, added = time(), updated = time() }
		ns.db.players[key] = entry
	end
	return entry, key
end

-- Today and where you are: "2026-11-07, Stormwind City". The zone is left out when unreadable.
function ns.Stamp()
	local today = date("%Y-%m-%d")
	local zone = GetRealZoneText and ns.Readable(GetRealZoneText())
	if type(zone) == "string" and zone ~= "" then
		return today .. ", " .. zone
	end
	return today
end

-- A new piece of note with the stamp in front, unless it already starts with a date or dated
-- notes are switched off.
function ns.StampNote(text)
	if text == "" or not ns.db.settings.datedNotes or text:find("^%d%d%d%d%-%d%d%-%d%d") then
		return text
	end
	return ns.Stamp() .. ": " .. text
end

-- Adds to what is already there: a note is never overwritten from here.
function ns.AddNote(rawName, text)
	local entry, key = ns.GetOrCreateEntry(rawName)
	if not entry then
		return nil, key
	end
	text = ns.StampNote(ns.Trim(text or ""))
	if entry.note ~= "" and text ~= "" then
		entry.note = entry.note .. "\n" .. text
	elseif text ~= "" then
		entry.note = text
	end
	entry.updated = time()
	return entry, key
end

function ns.DeleteEntry(key)
	local entry = ns.db.players[key]
	ns.db.players[key] = nil
	return entry
end

-- Moves an entry to another name; refuses to overwrite a different player.
function ns.RenameEntry(oldKey, newName)
	local display, newKey = ns.ValidateName(newName)
	if not display then
		return nil, newKey
	end
	local players = ns.db.players
	local entry = players[oldKey]
	if not entry then
		return nil, "That player has no note any more."
	end
	if newKey ~= oldKey then
		if players[newKey] then
			return nil, ("%s already has a note."):format(players[newKey].name)
		end
		players[newKey] = entry
		players[oldKey] = nil
	end
	entry.name = display
	return entry, newKey
end

-- The notes for a name as the game reports it: the exact player when known, or else a loose
-- match on the first name when one of the two sides has no surname. Returns a sorted list of
-- { key, entry, loose }.
function ns.FindNotes(rawName)
	local key = ns.MakeKey(rawName)
	if not key then
		return {}
	end
	local players = ns.db.players
	if players[key] then
		return { { key = key, entry = players[key], loose = false } }
	end
	local results = {}
	local first = key:match("^[^%-]+")
	if key:find("-", 1, true) then
		if players[first] then
			results[1] = { key = first, entry = players[first], loose = true }
		end
	else
		for otherKey, entry in pairs(players) do
			if otherKey:match("^[^%-]+") == first then
				results[#results + 1] = { key = otherKey, entry = entry, loose = true }
			end
		end
		table.sort(results, function(a, b) return a.key < b.key end)
	end
	return results
end

-- Stores what the game just told us about a player who has a note (class, faction, spelling).
function ns.UpdateFromUnit(rawName, unit)
	local key = ns.MakeKey(rawName)
	local entry = key and ns.db.players[key]
	if not entry then
		return
	end
	entry.name = ns.DisplayName(rawName) or entry.name
	local class = ns.Readable((select(2, UnitClass(unit))))
	if type(class) == "string" then
		entry.class = class
	end
	local faction = ns.Readable((UnitFactionGroup(unit)))
	if type(faction) == "string" then
		entry.faction = faction
	end
end

-- Sorting by category: players under the first category they have in ns.CategoryOrder (alerting,
-- negative, neutral, positive), and players without a category last.
local function categoryRanker()
	local ranks, rank = {}, 0
	for _, category in ipairs(ns.CategoryOrder()) do
		rank = rank + 1
		ranks[category.id] = rank
	end
	return function(entry)
		local best = rank + 1
		for id in pairs(entry.categories or {}) do
			if ranks[id] and ranks[id] < best then
				best = ranks[id]
			end
		end
		return best
	end
end

-- Lower sorts first; players with the same value go by name.
local function sortValue(mode)
	if mode == "updated" then
		return function(entry) return -(entry.updated or 0) end
	elseif mode == "added" then
		return function(entry) return -(entry.added or 0) end
	elseif mode == "category" then
		return categoryRanker()
	end
	return function() return 0 end
end

-- Entries for the list: optional filter, search text and sort mode (by name without one).
-- The filter is a category id, "@negative" / "@positive" / "@neutral" for every player with a
-- category of that kind, "@outstanding", or "@role:tank" (healer, dps) for a role. Outstanding
-- players always come first.
function ns.SortedEntries(filter, search, mode)
	local items = {}
	local valueOf = sortValue(mode)
	local roleFilter = filter and filter:match("^@role:(.+)$")
	local kindFilter = not roleFilter and filter and filter:match("^@(.+)$")
	search = search and ns.Trim(search):lower() or ""
	for key, entry in pairs(ns.db.players) do
		local keep
		if filter == ns.OUTSTANDING.id then
			keep = entry.outstanding == true
		elseif roleFilter then
			keep = entry.role == roleFilter
		elseif kindFilter then
			keep = ns.HasKind(entry, kindFilter)
		else
			keep = not filter or (entry.categories and entry.categories[filter])
		end
		if keep and search ~= "" then
			keep = entry.name:lower():find(search, 1, true) or (entry.note or ""):lower():find(search, 1, true)
		end
		if keep then
			items[#items + 1] = { key = key, entry = entry, value = valueOf(entry), top = entry.outstanding == true }
		end
	end
	table.sort(items, function(a, b)
		if a.top ~= b.top then
			return a.top
		end
		if a.value ~= b.value then
			return a.value < b.value
		end
		return a.key < b.key
	end)
	return items
end

function ns.CountPlayers()
	local count = 0
	for _ in pairs(ns.db.players) do
		count = count + 1
	end
	return count
end

-- Tooltips -----------------------------------------------------------------------

-- The note on a tooltip, shortened to `limit` bytes and `maxLines` lines.
function ns.AddNoteToTooltip(tooltip, entry, limit, maxLines)
	local note, shortened = ns.Truncate(entry.note or "", limit)
	local shown = 0
	for line in (note .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then
			if maxLines and shown == maxLines then
				shortened = true
				break
			end
			tooltip:AddLine(line, 1, 0.91, 0.66, true)
			shown = shown + 1
		end
	end
	if shortened then
		tooltip:AddLine(("... more with /pn show \"%s\""):format(entry.name), 0.6, 0.6, 0.6, true)
	end
end

-- Printing -----------------------------------------------------------------------

-- The note in the chat, line by line. With `brief`, a long note is shortened for the alerts.
function ns.PrintNoteLines(entry, brief)
	local note = entry.note or ""
	if note == "" then
		return
	end
	local shortened = false
	if brief then
		note, shortened = ns.Truncate(note, 300)
	end
	local shown = 0
	for line in (note .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then
			if brief and shown == 4 then
				shortened = true
				break
			end
			DEFAULT_CHAT_FRAME:AddMessage("   " .. NOTE_COLOR .. line .. "|r")
			shown = shown + 1
		end
	end
	if shortened then
		DEFAULT_CHAT_FRAME:AddMessage(("   |cff999999... more with /pn show \"%s\"|r"):format(entry.name))
	end
end

-- "<Name>  <role>  <categories>" then the note.
function ns.PrintEntry(entry)
	local tags = ns.EntryTags(entry)
	ns.Print(ns.VerdictTag(entry) .. ns.ColorName(entry.name, entry.class) .. (tags ~= "" and "  " .. tags or ""))
	ns.PrintNoteLines(entry)
end
