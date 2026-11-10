-- PlayerNotes: your categories and note on the tooltip of a player you hover over.
--
-- The name comes from the unit, or else from the GUID in the tooltip's data. When the client
-- keeps both secret, which it can do for some players, the tooltip simply stays as it was.

local _, ns = ...

local Tooltip = {}
ns.Tooltip = Tooltip

local NOTE_LIMIT = 220
local NOTE_MAX_LINES = 3

Tooltip.method = nil -- for /pn debug: how the tooltip is reached on this client

local function nameOnTooltip(tooltip, data)
	local unit = "mouseover"
	if tooltip.GetUnit then
		local _, tooltipUnit = tooltip:GetUnit()
		tooltipUnit = ns.Readable(tooltipUnit)
		if type(tooltipUnit) == "string" then
			unit = tooltipUnit
		end
	end
	local name = ns.ReadUnitName(unit)
	if name then
		return name
	end
	return type(data) == "table" and ns.NameFromGUID(data.guid) or nil
end

local function addEntry(tooltip, result)
	local entry = result.entry
	local tags = ns.CategoryTags(entry)
	tooltip:AddLine(ns.VerdictTag(entry) .. (tags ~= "" and tags or "PlayerNotes"), 0.4, 0.8, 1)
	if result.loose then
		tooltip:AddLine(("Name partly matches your note on %s."):format(entry.name), 0.6, 0.6, 0.6, true)
	end
	ns.AddNoteToTooltip(tooltip, entry, NOTE_LIMIT, NOTE_MAX_LINES)
end

local function onUnitTooltip(tooltip, data)
	if not ns.db or tooltip ~= GameTooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then
		return
	end
	local name = nameOnTooltip(tooltip, data)
	if not name then
		return
	end
	local added = false
	for _, result in ipairs(ns.FindNotes(name)) do
		if ns.HasContent(result.entry) then
			addEntry(tooltip, result)
			added = true
		end
	end
	if added then
		tooltip:Show() -- resizes it around the new lines
	end
end

function Tooltip.Install()
	if Tooltip.method then
		return
	end
	local handler = ns.Guard("player tooltip", onUnitTooltip)
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Unit then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, handler)
		Tooltip.method = "TooltipDataProcessor"
	elseif GameTooltip and GameTooltip.HookScript and pcall(GameTooltip.HookScript, GameTooltip, "OnTooltipSetUnit", handler) then
		Tooltip.method = "OnTooltipSetUnit"
	end
end
