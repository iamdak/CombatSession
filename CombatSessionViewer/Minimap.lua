-- CombatSessionViewer :: Minimap button
--
-- Drawn rather than shipped as an image, for the same reason the tray icon is:
-- it is three bars on a baseline, and a .tga would be an extra file to ship and
-- keep in step with the one the application draws. The two are the same mark.
--
-- Position is an angle, not a point. A minimap button that remembers x and y
-- ends up detached from the minimap the moment anything resizes it, and every
-- other addon's button on the ring is placed the same way, so an angle is what
-- makes this one sit among them.

local ADDON, ns = ...

local BUTTON_SIZE = 31
local ICON_SIZE   = 17

local button

--------------------------------------------------------------------------------

-- Placement follows LibDBIcon, which is what almost every addon on the ring
-- uses, so this button sits with them rather than near them.
--
-- The radius is derived from the minimap rather than fixed: it is half the
-- minimap's width plus a small margin, so the button rides just outside the map
-- edge. A constant 80 was inside the map on a default-sized minimap, which is
-- why it orbited too tightly.
local function Radius()
    return (Minimap:GetWidth() / 2) + 5
end

local function Place(angle)
    local radians = math.rad(angle)
    local radius = Radius()
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER",
                    math.cos(radians) * radius,
                    math.sin(radians) * radius)
end

-- The bar chart, drawn straight onto the button.
--
-- Deliberately textures rather than a child frame holding textures: a child
-- frame draws above every texture of its parent whatever the layers say, so the
-- icon covered the ring border instead of sitting inside it. Layers alone give
-- the right order once everything belongs to the same frame.
--
-- Geometry matches LibDBIcon's: a 17x17 icon at (7, -5) inside a 31x31 button,
-- which is the hole the tracking border leaves.
local function DrawIcon(button)
    local function Region(layer)
        local tex = button:CreateTexture(nil, layer)
        return tex
    end

    local tile = Region("BACKGROUND")
    tile:SetSize(ICON_SIZE, ICON_SIZE)
    tile:SetPoint("TOPLEFT", 7, -5)
    tile:SetColorTexture(0.11, 0.11, 0.13, 1)

    local baseline = Region("BORDER")
    baseline:SetColorTexture(0.42, 0.42, 0.47, 1)
    baseline:SetPoint("BOTTOMLEFT", tile, "BOTTOMLEFT", 1, 2)
    baseline:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -1, 2)
    baseline:SetHeight(1)

    -- Same green as the application's idle state, so the two read as one tool.
    local heights = { 0.34, 0.58, 0.84 }
    local width = (ICON_SIZE - 4) / 5
    for i, height in ipairs(heights) do
        local bar = Region("ARTWORK")
        bar:SetColorTexture(0.25, 0.76, 0.35, 1)
        bar:SetSize(width, (ICON_SIZE - 5) * height)
        bar:SetPoint("BOTTOMLEFT", tile, "BOTTOMLEFT",
                     2 + (i - 1) * (width + 1.5), 3)
    end
end

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Right-click menu
--------------------------------------------------------------------------------

-- Everything the menu offers belongs to the recording addon, not to the viewer,
-- so each item resolves CombatSession at the moment it is used. The viewer can
-- be running with the library disabled, and a menu that errors is worse than
-- one that says what is wrong.
local function Library()
    return _G.CombatSession
end

local function PrintStatus()
    if SlashCmdList and SlashCmdList["COMBATSESSION"] then
        SlashCmdList["COMBATSESSION"]("status")
    else
        ns:Print("CombatSession is not loaded - there is no status to report.")
    end
end

-- Built fresh every time the menu opens, so the state in the label is the state
-- as of the click rather than as of login.
local function AutoLogLabel()
    local cs = Library()
    if not (cs and cs.AutoLogEnabled) then
        return "Auto Logging: |cff888888unavailable|r"
    end
    return "Auto Logging: " ..
        (cs:AutoLogEnabled() and "|cff33ff33On|r" or "|cffff5555Off|r")
end

local function ToggleAutoLog()
    local cs = Library()
    if not (cs and cs.SetAutoLog) then
        ns:Print("CombatSession is not loaded - logging cannot be changed here.")
        return
    end

    local on = cs:SetAutoLog(not cs:AutoLogEnabled())
    ns:Print("auto logging " .. (on and "|cff33ff33on|r" or "|cffff5555off|r"))
end

-- The only way back is a command, so the message has to carry it. A hidden
-- button with no way to find it again is how addons get uninstalled.
local function HideIcon()
    ns:SetMinimapButtonShown(false)
    ns:Print("minimap icon hidden - |cffffcc00/csv icon|r brings it back")
end

function ns:ShowMinimapMenu(owner)
    -- MenuUtil is the only menu system the client has had since 11.0. If a
    -- future build moves it, right-click falls back to what it did before
    -- there was a menu rather than throwing.
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        PrintStatus()
        return
    end

    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("CombatSession Viewer")
        root:CreateButton("Hide Icon", HideIcon)
        root:CreateButton(AutoLogLabel(), ToggleAutoLog)
        root:CreateButton("Status", PrintStatus)
    end)
end

--------------------------------------------------------------------------------

function ns:CreateMinimapButton()
    if button then return button end

    button = CreateFrame("Button", "CombatSessionViewerMinimapButton", Minimap)
    button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetMovable(true)

    DrawIcon(button)

    -- The standard ring overlay, drawn last and at OVERLAY so it frames the
    -- icon rather than being covered by it.
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    button:SetScript("OnClick", function(self, click)
        if click == "RightButton" then
            ns:ShowMinimapMenu(self)
        else
            ns.UI:Toggle()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("CombatSession Viewer", 1, 1, 1)
        GameTooltip:AddLine("Left click to open the viewer.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Right click for options.", 0.7, 0.7, 0.7)
        GameTooltip:AddLine("Drag to move around the minimap.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Dragging follows the cursor's angle from the minimap centre, so the button
    -- stays on the ring however far the pointer wanders from it.
    button:SetScript("OnDragStart", function(self)
        self.dragging = true
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = Minimap:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale

            local angle = math.deg(math.atan2(cy - my, cx - mx))
            ns.db.minimapAngle = angle
            Place(angle)
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self.dragging = false
        self:SetScript("OnUpdate", nil)
    end)

    Place(ns.db.minimapAngle or 198)
    button:SetShown(ns.db.minimapShown ~= false)
    return button
end

function ns:SetMinimapButtonShown(shown)
    self.db.minimapShown = shown and true or false
    if button then button:SetShown(self.db.minimapShown) end
    return self.db.minimapShown
end

function ns:ToggleMinimapButton()
    return self:SetMinimapButtonShown(self.db.minimapShown == false)
end
