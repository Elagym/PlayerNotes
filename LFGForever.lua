-- PlayerNotes: the same icons as in the game's group finder, in the player list of the addon
-- LFG Forever, when it is installed. Without it this file does nothing at all.
--
-- LFG Forever keeps its code to itself, so there is no function to hook. What can be reached is
-- its window, LFGForeverFrame, built the first time you open it: the list sits at
-- .Content.ListPanel, its rows live in .ScrollBox, and each row is the game's own group finder
-- row with .resultID set, which is exactly what GroupFinder.lua already decorates. So:
--   * every row LFG Forever draws is decorated right after it is drawn (the ScrollBox's
--     "frame initialized" callback);
--   * a row it redraws in place (ListPanel:UpdateResult, e.g. a leader name that arrived late)
--     is decorated again after it.
--
-- None of this is promised by LFG Forever. Every step checks that what it expects is there, and
-- any surprise stops the integration quietly: PlayerNotes and LFG Forever both keep working,
-- only the icons in LFG Forever's list are missing, and /pn debug says why.

local _, ns = ...

local ADDON_NAME = "LFGForever"
local WINDOW_NAME = "LFGForeverFrame"
local RETRY_DELAY = 2 -- seconds between looks for the window, which is built when first opened

local LFGForever = {
	state = "not installed", -- for /pn debug: not installed, waiting for its window, attached, stopped
	rowsSeen = 0,
	problem = nil,
}
ns.LFGForever = LFGForever

local waiting = false

local function isLoaded()
	if C_AddOns and C_AddOns.IsAddOnLoaded then
		return C_AddOns.IsAddOnLoaded(ADDON_NAME) and true or false
	end
	return IsAddOnLoaded ~= nil and IsAddOnLoaded(ADDON_NAME) and true or false
end

-- Something was not as expected: stop for good, without a word in the chat.
local function stop(problem)
	LFGForever.state = "stopped"
	LFGForever.problem = problem
end

-- Runs fn protected; an error stops the integration instead of reaching the player.
local function quietly(label, fn)
	return function(...)
		if LFGForever.state == "stopped" then
			return
		end
		local ok, err = pcall(fn, ...)
		if not ok then
			stop(label .. ": " .. tostring(err))
		end
	end
end

local function decorate(frame)
	-- Only real listing rows: the box also holds the "Groups" / "Players" headers.
	if type(frame) ~= "table" or ns.Readable(frame.resultID) == nil then
		if type(frame) == "table" and frame.PlayerNotesIcon then
			frame.PlayerNotesIcon:Hide()
		end
		return
	end
	LFGForever.rowsSeen = LFGForever.rowsSeen + 1
	ns.GroupFinder.UpdateRow(frame)
end

-- The list panel and its ScrollBox, if LFG Forever's window exists and still looks the way this
-- file expects. Returns nil while the window has not been built yet.
local function findList()
	local window = _G[WINDOW_NAME]
	if type(window) ~= "table" then
		return nil
	end
	local content = window.Content
	local list = type(content) == "table" and content.ListPanel or nil
	local box = type(list) == "table" and list.ScrollBox or nil
	if type(box) ~= "table" or type(box.ForEachFrame) ~= "function" or type(box.RegisterCallback) ~= "function" then
		return nil, "its window is there, but not its list"
	end
	return list, box
end

local function attach(list, box)
	local onRow = quietly("row", decorate)

	-- Every row from now on, right after LFG Forever has drawn it. The callback registry calls
	-- back with (owner, frame, elementData).
	local events = ScrollBoxListMixin and ScrollBoxListMixin.Event
	local initialized = events and events.OnInitializedFrame
	if not initialized then
		stop("this client has no ScrollBox row callback")
		return
	end
	box:RegisterCallback(initialized, function(_, frame)
		onRow(frame)
	end, LFGForever)

	-- A row redrawn in place.
	if type(list.UpdateResult) == "function" then
		hooksecurefunc(list, "UpdateResult", quietly("updated row", function(_, resultID)
			resultID = ns.Readable(resultID)
			box:ForEachFrame(function(frame)
				if resultID ~= nil and ns.Readable(frame.resultID) == resultID then
					onRow(frame)
				end
			end)
		end))
	end

	LFGForever.state = "attached"
	-- The rows already on screen.
	box:ForEachFrame(function(frame)
		onRow(frame)
	end)
end

local tryAttach

-- Looks for the window now, and again a little later until it is there.
tryAttach = quietly("attach", function()
	if LFGForever.state == "attached" or not isLoaded() then
		return
	end
	local list, box = findList()
	if list then
		attach(list, box)
		return
	end
	if box then -- the second value: the window is not what this file knows
		stop(box)
		return
	end
	LFGForever.state = "waiting for its window"
	if not waiting then
		waiting = true
		C_Timer.After(RETRY_DELAY, function()
			waiting = false
			tryAttach()
		end)
	end
end)

-- Your notes changed: GroupFinder.Refresh redraws every decorated row, LFG Forever's included,
-- so nothing more is needed here.

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("ADDON_LOADED")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", function(_, event, addonName)
	if event == "PLAYER_LOGIN" or addonName == ADDON_NAME then
		tryAttach()
	end
end)
