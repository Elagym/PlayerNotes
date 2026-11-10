-- PlayerNotes: the minimap button. Left-click opens the window, right-click the options, and
-- dragging moves it around the edge of the minimap.

local _, ns = ...

local MinimapButton = {}
ns.MinimapButton = MinimapButton

local ICON = "Interface\\Icons\\INV_Misc_Note_01"

local button

local function place()
	local angle = math.rad(ns.db.settings.minimapAngle)
	local x = math.cos(angle) * (Minimap:GetWidth() / 2 + 5)
	local y = math.sin(angle) * (Minimap:GetHeight() / 2 + 5)
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function followCursor()
	local centerX, centerY = Minimap:GetCenter()
	local scale = Minimap:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	ns.db.settings.minimapAngle = math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
	place()
end

local function settingToggle(name)
	return function()
		return ns.db.settings[name] == true
	end, function()
		ns.db.settings[name] = not ns.db.settings[name]
	end
end

function MinimapButton.OpenMenu(owner)
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle("PlayerNotes")
		local isOn, toggle = settingToggle("nearbyAlert")
		root:CreateCheckbox("Alert when a tagged player is nearby", isOn, toggle)
		isOn, toggle = settingToggle("nearbySound")
		root:CreateCheckbox("Play a sound with the alert", isOn, toggle)
		local categories = root:CreateButton("Categories that alert")
		for _, category in ipairs(ns.db.categories) do
			categories:CreateCheckbox(ns.CategoryText(category), function()
				return category.alert == true
			end, function()
				category.alert = not category.alert
				ns.Notify()
			end)
		end
		isOn, toggle = settingToggle("datedNotes")
		root:CreateCheckbox("Put the date and zone on new notes", isOn, toggle)
		root:CreateDivider()
		root:CreateButton("Hide this button", function()
			MinimapButton.SetHidden(true)
			ns.Print("Minimap button hidden. /pn minimap brings it back.")
		end)
	end)
end

local function showTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:AddLine("PlayerNotes", 0.4, 0.8, 1)
	GameTooltip:AddLine(("%d players with a note"):format(ns.CountPlayers()), 1, 1, 1)
	GameTooltip:AddLine("Left-click: open the window", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Right-click: options", 0.8, 0.8, 0.8)
	GameTooltip:AddLine("Drag: move this button", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

local function build()
	button = CreateFrame("Button", "PlayerNotesMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(24, 24)
	background:SetPoint("CENTER")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(18, 18)
	icon:SetPoint("CENTER")
	ns.SetIconTexture(icon, ICON)

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetSize(50, 50)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			MinimapButton.OpenMenu(self)
		else
			ns.UI.Toggle()
		end
	end)
	button:SetScript("OnEnter", showTooltip)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	button:SetScript("OnDragStart", function(self)
		GameTooltip:Hide()
		self:SetScript("OnUpdate", ns.Guard("minimap drag", followCursor))
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)
end

function MinimapButton.SetHidden(hidden)
	ns.db.settings.minimapHidden = hidden
	if button then
		button:SetShown(not hidden)
	end
end

function MinimapButton.Install()
	if button or not Minimap then
		return
	end
	build()
	place()
	button:SetShown(not ns.db.settings.minimapHidden)
end
