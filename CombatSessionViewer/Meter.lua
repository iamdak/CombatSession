-- CombatSessionViewer :: Meter window
--
-- A small window showing one measure for the current session, meant to be left
-- on screen while playing - the job a damage meter does. The main window is a
-- grid of twelve columns and a session list; this is a list of names and one
-- number, which is what can be read at a glance in the middle of a match.
--
-- It draws the same data the main window does, through the same API, and holds
-- nothing of its own. Two rules follow from that and shape the whole file:
--
--   * Only the measures the game's own meter can fill are offered. Seven of our
--     twelve columns are derived from the advanced log and appear when the
--     application delivers it, which is after the match; a window that updates
--     while you play has no business offering a column that cannot move until
--     you have stopped. The list comes from the library, so it stays right
--     whatever the meter does or does not report.
--
--   * There is no drill-down. A row is one bar wide and there is nowhere to put
--     a breakdown, so clicking a row hands off to the window that can show one:
--     UI:Reveal opens the main window on that session with that player already
--     expanded.
--
-- The session shown is the newest one that has anything to draw, which while a
-- match is being played is that match: live records outrank everything older,
-- and when the log arrives for them the stand-in is replaced by the real thing
-- under the same key. Nothing here has to know which of the two it is looking at.

local ADDON, ns = ...

local Meter = {}
ns.Meter = Meter

local TITLE_H = 24
local HEAD_H  = 15
local PAD     = 6
local INSET   = 4     -- text inset inside the list box

-- The rows, and the text in them, against the size the list was first drawn at.
-- One constant for both: a row scaled without its text is a row with more space
-- around the same writing, which is not what taller rows are for.
local ROW_BASE  = 18
local ROW_SCALE = 1.4
local ROW_H     = math.floor(ROW_BASE * ROW_SCALE + 0.5)

-- Everything between the top of the window and the first row: the title bar, the
-- gap under it, the list box's own two edges and its header. Named because the
-- peek works out how tall the window would have to be to hold every row, and
-- that sum has to match how the frame is actually built or the window opens to
-- slightly the wrong height.
local CHROME_H = TITLE_H + 2 + 1 + HEAD_H + 1 + PAD

-- Below these the list holds fewer than three rows and the title has nowhere to
-- put a name, which is not a window any more.
local MIN_W, MIN_H = 180, CHROME_H + (3 * ROW_H)

local frame, list
local view = { rows = {}, version = 0 }

local function Clamp(value, low, high)
    if value < low then return low end
    if value > high then return high end
    return value
end

--------------------------------------------------------------------------------
-- Opacity
--
-- The whole window, text and bars included: it is applied as the frame's own
-- alpha, which every region and child inherits. Stored, shown and set as the
-- same number - 90% on the slider is 0.90 here and is 90% opaque.
--------------------------------------------------------------------------------

local DEFAULT_OPACITY = 0.90

-- A window with no opacity is invisible and still takes every click that lands
-- on it, which is a hole in the screen nobody can find again. Enforced here as
-- well as on the slider, so a value written some other way is held to it too.
local MIN_OPACITY = 0.10

local function Opacity()
    local a = ns.db and ns.db.meterOpacity
    if type(a) ~= "number" then a = DEFAULT_OPACITY end
    return Clamp(a, MIN_OPACITY, 1)
end

--------------------------------------------------------------------------------
-- What is being shown
--------------------------------------------------------------------------------

-- The measures that can move while a match is being played, as {col, name}.
-- Asked for fresh rather than cached: the library resolves them against the
-- format, and this addon can outlive a format change without a reload.
local function Choices()
    local api = ns:API()
    if not (api and api.LiveColumns) then return {} end

    local defines = api:GetDefines()
    local names = (defines and defines.FORMAT) or {}

    local out = {}
    for _, col in ipairs(api:LiveColumns()) do
        if names[col] then out[#out + 1] = { col = col, name = names[col] } end
    end
    return out
end

-- The chosen column, or the first live one. Validated on every read rather than
-- on the way in, so a saved choice that is no longer among them - a column the
-- meter has stopped reporting - falls back instead of drawing an empty list
-- forever.
function Meter:Column()
    local choices = Choices()
    if #choices == 0 then return nil end

    local wanted = ns.db and ns.db.meterCol
    for _, choice in ipairs(choices) do
        if choice.col == wanted then return choice.col, choice.name end
    end
    return choices[1].col, choices[1].name
end

function Meter:SetColumn(col)
    if ns.db then ns.db.meterCol = col end
    self:Refresh()
end

--------------------------------------------------------------------------------
-- The rows
--------------------------------------------------------------------------------

-- The session to draw: the newest one that has a cache behind it.
--
-- Newest by key, which is a timestamp, so a match being played now always wins.
-- A queued session the addon has not built yet is skipped rather than shown
-- empty - the main window says that a backlog exists, and this window has no
-- room to.
local function Newest(api)
    local sessions = api:GetViewable()
    table.sort(sessions, function(a, b) return a.key > b.key end)

    for _, entry in ipairs(sessions) do
        local cache = api:GetCache(entry.key)
        if cache then return entry, cache end
    end
end

-- Zero rows are dropped, the way every meter drops them: in Healing Done a
-- battleground is mostly people who did none, and listing them pushes the four
-- who healed off the bottom of a window this size.
local function Build()
    view.key, view.entry, view.label = nil, nil, nil
    view.rows, view.max = {}, 0
    view.version = view.version + 1

    local api = ns:API()
    if not api then return end

    local col, name = Meter:Column()
    view.column, view.columnName = col, name
    if not col then return end

    local entry, cache = Newest(api)
    if not entry then return end

    view.key, view.entry = entry.key, entry
    view.label = ns.ShortName(entry.mapName or "")

    local players = api:Roster(entry, cache, api:GetMatch(entry))
    for _, player in ipairs(players) do
        local unit  = player.unit
        local value = (unit and unit.cols and unit.cols[col]) or 0
        if value > 0 then
            -- The log's spec id yields a class for a player the scoreboard
            -- never listed, which in a live session is most of the other side.
            local byId = ns.SpecById(player.specId)

            -- Fetched with a plain `if`, not an `and ... or` chain: `or` would
            -- test the secret for truth, and testing a secret throws.
            local secret
            if unit and unit.guid and api.SecretName then
                secret = api:SecretName(entry.key, unit.guid)
            end

            view.rows[#view.rows + 1] = {
                name  = player.name,
                class = player.class or (byId and byId.class) or nil,
                team  = player.team or player.inferredTeam,
                value = value,
                count = (unit and unit.counts and unit.counts[col]) or 0,
                -- The game's own name for a row it will not name to us yet,
                -- as a secret: drawn, never read. `name` stays the readable
                -- label, which is what sorting and the hand-off to the grid use.
                secret = secret,
            }
            if value > view.max then view.max = value end
        end
    end

    table.sort(view.rows, function(a, b)
        if a.value == b.value then return (a.name or "") < (b.name or "") end
        return a.value > b.value
    end)
end

--------------------------------------------------------------------------------
-- Drawing
--------------------------------------------------------------------------------

local isSecret = issecretvalue or function() return false end

-- A row's class colour as components. Applied with SetTextColor rather than as
-- an escape code, because an escape code around a withheld name would be
-- concatenation, and concatenating a secret throws.
local function NameColor(entry)
    local c = entry.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[entry.class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- The name a row shows. A withheld name is handed to the font string as the
-- secret it is - SetText will draw one - and otherwise the readable label is
-- used. Guarded, so a build that stopped accepting secrets there would cost the
-- row its name rather than cost the list its layout.
local function SetName(text, entry)
    text:SetTextColor(NameColor(entry))
    if isSecret(entry.secret) and pcall(text.SetText, text, entry.secret) then return end
    text:SetText(ns.ShortName(entry.name))
end

-- Track and bar for a side, from the same palette the main grid uses, so a
-- player who is blue in one window is blue in the other.
local function RowColors(team)
    if team == 1 then return ns.COLOR.team1Track, ns.COLOR.team1Bar end
    if team == 2 then return ns.COLOR.team2Track, ns.COLOR.team2Bar end
    return ns.COLOR.noTeamTrack, ns.COLOR.noTeamBar
end

-- The measure goes with the name: the grid opens on the column this row was read
-- in, and ranks by it, so the player clicked on is where the eye already is.
local function OnRowClick(row)
    if not (view.key and row.entry) then return end
    ns.UI:Reveal(view.key, row.entry.name, view.column)
end

local function OnRowEnter(row)
    row.hover:Show()

    local entry = row.entry
    if not entry then return end

    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    local r, g, b = NameColor(entry)
    if not (isSecret(entry.secret)
            and pcall(GameTooltip.AddLine, GameTooltip, entry.secret, r, g, b)) then
        GameTooltip:AddLine(ns.ShortName(entry.name), r, g, b)
    end
    -- The column's full name, not the grid's shortening of it. That exists to
    -- keep twelve headers inside a fixed cell width, which is a problem this
    -- window does not have.
    GameTooltip:AddDoubleLine(view.columnName,
                              ns.FormatExact(view.column, entry.value, entry.count),
                              0.7, 0.7, 0.7, 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click to open this player in the viewer.", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function OnRowLeave(row)
    row.hover:Hide()
    GameTooltip:Hide()
end

-- A row's text at the row's own scale. The size is read off the template rather
-- than named here, so this stays whatever font the client is running - which in
-- several locales is not the one a hardcoded path would name - and only the size
-- changes.
local function ScaleFont(text)
    local file, size, flags = text:GetFont()
    if file and size then text:SetFont(file, size * ROW_SCALE, flags) end
end

local function Row(index)
    local row = list.rows[index]
    if row then return row end

    row = CreateFrame("Button", nil, list.clip)
    row:SetHeight(ROW_H - 1)

    row.track = ns.Fill(row, ns.COLOR.noTeamTrack)

    row.bar = row:CreateTexture(nil, "BORDER")
    row.bar:SetPoint("TOPLEFT")
    row.bar:SetPoint("BOTTOMLEFT")

    row.hover = row:CreateTexture(nil, "ARTWORK")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(1, 1, 1, 0.08)
    row.hover:Hide()

    -- The value is placed first and the name given whatever is left, so a long
    -- name is truncated rather than running under the figure it belongs to.
    row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.value:SetPoint("RIGHT", -INSET, 0)
    row.value:SetJustifyH("RIGHT")
    ScaleFont(row.value)

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.name:SetPoint("LEFT", INSET, 0)
    row.name:SetPoint("RIGHT", row.value, "LEFT", -INSET, 0)
    row.name:SetJustifyH("LEFT")
    row.name:SetWordWrap(false)
    ScaleFont(row.name)

    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", OnRowLeave)

    list.rows[index] = row
    return row
end

local function Populate(row, entry)
    row.entry = entry

    local track, bar = RowColors(entry.team)
    row.track:SetColorTexture(track[1], track[2], track[3])
    row.bar:SetColorTexture(bar[1], bar[2], bar[3])

    -- Scaled to the largest in the list, so the leader's bar fills the row and
    -- everything else is read against it. A floor of two pixels keeps a small
    -- contribution visible as a mark rather than as nothing at all.
    local width = list.clip:GetWidth()
    local frac = (view.max > 0) and (entry.value / view.max) or 0
    if frac > 0 and width > 0 then
        row.bar:SetWidth(math.max(2, frac * width))
        row.bar:Show()
    else
        row.bar:Hide()
    end

    SetName(row.name, entry)
    row.value:SetText(ns.FormatCell(view.column, entry.value, entry.count))
end

local function Layout()
    if not (frame and frame:IsShown()) then return end

    local viewH = list.clip:GetHeight()
    local count = #view.rows

    list.scroll:SetMax(count * ROW_H - viewH)
    local scroll = list.scroll.cur

    local first = math.floor(scroll / ROW_H)
    local slots = math.ceil(viewH / ROW_H) + 2

    for slot = 1, slots do
        local index = first + slot
        local entry = view.rows[index]
        local row = Row(slot)
        if entry then
            -- Repopulated only when what it shows changed. During a scroll the
            -- slot a row occupies changes every frame while its contents mostly
            -- do not, and setting the same three strings every frame is the one
            -- cost a virtual list exists to avoid.
            if row.entry ~= entry or row.version ~= view.version then
                row.version = view.version
                Populate(row, entry)
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", list.clip, "TOPLEFT", 0,
                         -((index - 1) * ROW_H - scroll))
            row:SetPoint("TOPRIGHT", list.clip, "TOPRIGHT", 0,
                         -((index - 1) * ROW_H - scroll))
            row:Show()
        else
            row.entry = nil
            row:Hide()
        end
    end

    -- A shrunk window leaves rows behind that are no longer asked for.
    for slot = slots + 1, #list.rows do
        list.rows[slot].entry = nil
        list.rows[slot]:Hide()
    end

    -- Setting a slider fires its own OnValueChanged, which would call straight
    -- back into here. Guarded the way the main window guards its two.
    list.bar.syncing = true
    list.bar:SetMinMaxValues(0, math.max(1, list.scroll.max))
    list.bar:SetValue(list.scroll.cur)
    list.bar:SetShown(list.scroll.max > 0)
    list.bar.syncing = false
end

-- The title line: what is being measured, and which session it came from.
--
-- The session is named because this window chooses it rather than being told,
-- and a figure whose match is not obvious is worse than no figure. A live
-- session says so in the same place the main window's list does, and in the
-- same colour: its numbers are the meter's approximation and the log is still
-- to come.
local function LayoutTitle()
    frame.title.text:SetText(view.columnName or "|cff888888No meter data|r")

    local right = view.label or ""
    if view.entry and view.entry.pending then
        right = ("%s |cffdfa84f%s|r"):format(right, view.entry.pending)
    end
    frame.title.session:SetText(("|cff888888%s|r"):format(right))
end

local function LayoutEmpty()
    if #view.rows > 0 then
        list.empty:Hide()
        return
    end

    if not view.key then
        list.empty:SetText("|cff888888Nothing recorded yet.|r")
    else
        -- The session is there and this measure is empty in it, which is an
        -- answer rather than a fault: nobody has dispelled anything yet.
        list.empty:SetText(("|cff888888No %s yet.|r")
            :format((view.columnName or ""):lower()))
    end
    list.empty:Show()
end

function Meter:Refresh()
    if not (frame and frame:IsShown()) then return end
    Build()
    LayoutTitle()
    LayoutEmpty()
    Layout()
end

--------------------------------------------------------------------------------
-- The opacity slider, inside the menu
--
-- The menu system has no slider element. What it does have is initializers:
-- every element runs them against the frame it is drawn on, and one that returns
-- a width and a height sizes the element to them. So the slider is an ordinary
-- frame of our own, lent to an empty title for as long as the menu is open.
--
-- A title rather than a button because a title does nothing when clicked, so a
-- click that misses the knob cannot close the menu or trigger anything.
--
-- Element frames are pooled and handed on to whatever menu opens next, so the
-- slider must never be left on one. It takes itself back the moment it is
-- hidden, which is what happens to everything on an element frame when its menu
-- closes - and a menu that redraws itself, as it does after a checkbox click,
-- hides the old frame and runs the initializer again on the new one.
--------------------------------------------------------------------------------

local OPACITY_W, OPACITY_H = 180, 40

local opacity    -- the slider and its labels, made on first use
local parking    -- where it waits between menus: hidden and owned by nothing

local function ApplyOpacity()
    if frame then frame:SetAlpha(Opacity()) end
end

local function OpacityControl()
    if opacity then return opacity end

    parking = CreateFrame("Frame")
    parking:Hide()

    opacity = CreateFrame("Frame", nil, parking)
    opacity:SetSize(OPACITY_W, OPACITY_H)
    -- Takes every click that lands on it, so nothing on the element beneath
    -- can answer one.
    opacity:EnableMouse(true)

    local label = opacity:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", 0, -2)
    label:SetText("Opacity")

    local readout = opacity:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    readout:SetPoint("TOPRIGHT", 0, -2)

    local slider = CreateFrame("Slider", nil, opacity)
    slider:SetPoint("BOTTOMLEFT", 0, 2)
    slider:SetPoint("BOTTOMRIGHT", 0, 2)
    slider:SetHeight(ns.BAR_W)
    ns.StyleSlider(slider, true)
    slider:SetMinMaxValues(MIN_OPACITY * 100, 100)

    local function Say(percent)
        readout:SetText(("%d%%"):format(percent))
    end

    -- Applied on every step of the drag, so the window behind the menu shows
    -- the setting while it is being chosen rather than after.
    slider:SetScript("OnValueChanged", function(self, value)
        local percent = math.floor(value + 0.5)
        Say(percent)
        if self.syncing then return end
        ns.db.meterOpacity = percent / 100
        ApplyOpacity()
    end)

    opacity:SetScript("OnHide", function(self)
        self:SetParent(parking)
        self:ClearAllPoints()
    end)

    opacity.slider, opacity.Say = slider, Say
    return opacity
end

-- Lends the control to one element frame and sizes the element to hold it.
local function LendOpacity(element)
    local control = OpacityControl()
    control:SetParent(element)
    control:ClearAllPoints()
    control:SetAllPoints(element)
    control:SetFrameStrata(element:GetFrameStrata())
    control:SetFrameLevel(element:GetFrameLevel() + 2)

    -- From the stored value each time, since anything else may have changed it.
    -- Said outright as well: a slider set to the value it already holds does not
    -- fire, which would leave the readout blank on the first open.
    local percent = math.floor(Opacity() * 100 + 0.5)
    control.slider.syncing = true
    control.slider:SetValue(percent)
    control.slider.syncing = false
    control.Say(percent)

    control:Show()
    return OPACITY_W, OPACITY_H
end

--------------------------------------------------------------------------------
-- The menu
--------------------------------------------------------------------------------

local function IsColumn(col)    return view.column == col end
local function SelectColumn(col) Meter:SetColumn(col) end

local function IsLocked()    return ns.db and ns.db.meterLocked or false end
local function ToggleLocked() Meter:SetLocked(not IsLocked()) end

function Meter:ShowMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        ns:Print("this build of the client has no menu system - use |cffffcc00/csv meter|r")
        return
    end

    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("CombatSession Meter")

        local choices = Choices()
        if #choices == 0 then
            root:CreateButton("|cff888888No live measures available|r", function() end)
        end
        for _, choice in ipairs(choices) do
            root:CreateRadio(choice.name, IsColumn, SelectColumn, choice.col)
        end

        root:CreateDivider()
        root:CreateTitle(""):AddInitializer(LendOpacity)
        root:CreateDivider()
        root:CreateCheckbox("Lock Window", IsLocked, ToggleLocked)
        root:CreateButton("Open Viewer", function() ns.UI:Show() end)
        root:CreateButton("Hide", function() Meter:Hide() end)
    end)
end

--------------------------------------------------------------------------------
-- Peeking
--
-- A locked window cannot be dragged anywhere, which leaves the gesture free for
-- the thing a small list actually wants: pull the title bar up and the window
-- grows upward from a fixed bottom edge, showing the rows that were below it.
-- Let go and it drops back.
--
-- Height rather than scrolling because the whole point is to see more at once,
-- and rooted at the bottom because that is the edge the user is not holding: a
-- window that grew downward would push its own list out from under the cursor.
--
-- Nothing here is saved. The size is what the user set; this is a look at the
-- rest of the list, not a resize, so the window is put back exactly where and
-- how it was found.
--------------------------------------------------------------------------------

-- Opening is a gesture and follows the hand; closing is the window getting out
-- of the way, and is quicker.
local PEEK_OPEN  = 16
local PEEK_SHUT  = 26

local peek = {}

-- As tall as the window would have to be to hold every row, and never past the
-- top of the screen - which also keeps the screen clamp out of it, since a
-- clamped frame would be pushed back down and take its bottom edge with it.
local function PeekMax()
    local content = CHROME_H + (#view.rows * ROW_H)
    local room = (UIParent:GetHeight() or 0) - (peek.bottom or 0)
    return math.max(peek.base or 0, math.min(content, room))
end

local function PeekFinish()
    peek.cur, peek.want, peek.active = nil, nil, false

    frame:SetHeight(peek.base or ns.db.meterH)
    frame:ClearAllPoints()
    frame:SetPoint(ns.db.meterPoint, UIParent, ns.db.meterPoint,
                   ns.db.meterX, ns.db.meterY)
    frame:SetClampedToScreen(true)
end

local function PeekStart()
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    if not (left and bottom) then return end

    peek.left, peek.bottom = left, bottom
    peek.base = frame:GetHeight()
    peek.cur, peek.want = peek.base, peek.base
    peek.active = true

    local _, cursorY = GetCursorPosition()
    peek.startY = cursorY / UIParent:GetEffectiveScale()

    -- Re-anchored to its own bottom-left corner, so setting the height grows it
    -- upward whatever point the user placed it by. The saved placement is not
    -- touched; it is what gets put back.
    frame:ClearAllPoints()
    frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
    frame:SetClampedToScreen(false)
end

local function PeekStop()
    if not peek.active then return end
    peek.active = false
    peek.want = peek.base
end

-- Returns true while the height is still moving, so the caller knows to lay the
-- list out again: the rows on screen are a function of that height.
local function PeekStep(elapsed)
    if not peek.cur then return false end

    if peek.active then
        local _, cursorY = GetCursorPosition()
        cursorY = cursorY / UIParent:GetEffectiveScale()
        -- Upward only. Pulling down past where it started would shrink a window
        -- the user sized deliberately, which is not what this gesture is for.
        peek.want = Clamp(peek.base + (cursorY - peek.startY),
                          peek.base, PeekMax())
    end

    local diff = peek.want - peek.cur
    if math.abs(diff) < 0.5 then
        if peek.cur ~= peek.want then
            peek.cur = peek.want
            frame:SetHeight(peek.cur)
            return true
        end
        if not peek.active then PeekFinish() end
        return false
    end

    peek.cur = peek.cur + diff * math.min(1, elapsed * (peek.active and PEEK_OPEN or PEEK_SHUT))
    frame:SetHeight(peek.cur)
    return true
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function BuildTitle(parent)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetPoint("TOPLEFT")
    bar:SetPoint("TOPRIGHT")
    bar:SetHeight(TITLE_H)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")

    ns.Fill(bar, ns.COLOR.header)

    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bar.text:SetPoint("LEFT", PAD, 0)
    bar.text:SetWordWrap(false)

    -- Right-justified and clipped by its own anchors rather than shortened: at
    -- a narrow width the map name gives way to the measure, which is the thing
    -- the window is for.
    bar.session = bar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    bar.session:SetPoint("RIGHT", -PAD, 0)
    bar.session:SetPoint("LEFT", bar.text, "RIGHT", PAD, 0)
    bar.session:SetJustifyH("RIGHT")
    bar.session:SetWordWrap(false)

    -- Dragging is the title bar's job because the rows below it take their own
    -- clicks. Unlocked it moves the window; locked, where there is nothing to
    -- move, the same drag peeks the list open instead. A locked window keeps the
    -- menu either way: locking is about not moving it by accident, not about
    -- being unable to change what it shows.
    bar:SetScript("OnDragStart", function()
        if IsLocked() then PeekStart() else frame:StartMoving() end
    end)
    bar:SetScript("OnDragStop", function()
        if peek.active then
            PeekStop()
            return
        end
        frame:StopMovingOrSizing()
        local point, _, _, x, y = frame:GetPoint()
        ns.db.meterPoint, ns.db.meterX, ns.db.meterY = point, x, y
    end)

    bar:SetScript("OnMouseDown", function(self, click)
        if click == "RightButton" then Meter:ShowMenu(self) end
    end)

    bar:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine("CombatSession Meter", 1, 1, 1)
        GameTooltip:AddLine("Right click to choose what is shown, or to lock.",
                            0.7, 0.7, 0.7)
        if not IsLocked() then
            GameTooltip:AddLine("Drag to move.", 0.5, 0.5, 0.5)
        end
        GameTooltip:Show()
    end)
    bar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    return bar
end

local function BuildList(parent, title)
    list = { rows = {}, scroll = ns.NewScroller() }

    local box = CreateFrame("Frame", nil, parent)
    box:SetPoint("TOPLEFT", title, "BOTTOMLEFT", PAD, -2)
    box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD, PAD)
    ns.Fill(box, ns.COLOR.panel)
    ns.Border(box, ns.COLOR.line)
    list.box = box

    local head = CreateFrame("Frame", nil, box)
    head:SetPoint("TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", -1, -1)
    head:SetHeight(HEAD_H)
    ns.Fill(head, ns.COLOR.header)

    local rule = ns.Line(head, ns.COLOR.line)
    rule:SetPoint("BOTTOMLEFT")
    rule:SetPoint("BOTTOMRIGHT")
    rule:SetHeight(1)

    local left = head:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    left:SetPoint("LEFT", INSET, 0)
    left:SetText("Player Name")

    local right = head:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    right:SetPoint("RIGHT", -(INSET + ns.BAR_W), 0)
    right:SetText("Value")

    -- The gutter is reserved whether or not the bar is in it, so the rows keep
    -- one width and nothing reflows the moment a list grows past the window.
    local bar = CreateFrame("Slider", nil, box)
    bar:SetPoint("TOPRIGHT", head, "BOTTOMRIGHT", 0, 0)
    bar:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -1, 1)
    bar:SetWidth(ns.BAR_W)
    ns.StyleSlider(bar, false)
    bar:SetScript("OnValueChanged", function(self, value)
        if self.syncing then return end
        list.scroll:JumpTo(value)
        Layout()
    end)
    list.bar = bar

    local clip = CreateFrame("Frame", nil, box)
    clip:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, 0)
    clip:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", 0, 0)
    clip:SetClipsChildren(true)
    list.clip = clip

    list.empty = clip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    list.empty:SetPoint("TOPLEFT", INSET, -INSET)
    list.empty:SetPoint("TOPRIGHT", -INSET, -INSET)
    list.empty:SetJustifyH("LEFT")
    list.empty:Hide()

    -- Three rows a turn, eased, so a flick of the wheel reads as the list
    -- moving rather than as it jumping.
    box:EnableMouseWheel(true)
    box:SetScript("OnMouseWheel", function(_, delta)
        list.scroll:Nudge(-delta * ROW_H * 3)
    end)

    return box
end

function Meter:Create()
    if frame then return frame end

    frame = CreateFrame("Frame", "CombatSessionMeterFrame", UIParent)
    frame:SetSize(ns.db.meterW, ns.db.meterH)
    frame:SetPoint(ns.db.meterPoint, UIParent, ns.db.meterPoint,
                   ns.db.meterX, ns.db.meterY)
    -- The same strata as the main window and as most addon frames, raised
    -- within it when clicked. A meter sits among the other things on screen
    -- rather than over all of them.
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetClampedToScreen(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(MIN_W, MIN_H) end
    frame:SetScript("OnMouseDown", function(self) self:Raise() end)

    ns.Fill(frame, { 0.03, 0.03, 0.04, 0.92 })
    ns.Border(frame, ns.COLOR.line)

    frame.title = BuildTitle(frame)
    BuildList(frame, frame.title)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(14, 14)
    grip:SetPoint("BOTTOMRIGHT", -1, 1)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        ns.db.meterW, ns.db.meterH = frame:GetWidth(), frame:GetHeight()
    end)
    frame.grip = grip

    frame:SetScript("OnUpdate", function(_, elapsed)
        -- Bars are scaled to the width of the list, so every one of them is
        -- wrong the moment that width changes - which is on every frame of a
        -- drag on the grip, and once more when the window is first shown, since
        -- a frame's size from its anchors is not settled until it has been laid
        -- out. Watching the width covers both without either having to know
        -- about the other.
        local width = list.clip:GetWidth()
        if width ~= list.width then
            list.width = width
            view.version = view.version + 1
            Layout()
        end
        -- The peek changes the height, which changes how many rows there are
        -- room for, so the list is laid out again on every frame of it.
        if PeekStep(elapsed) then Layout() end
        if list.scroll:Step(elapsed) then Layout() end
    end)

    -- A window hidden mid-gesture would come back anchored by its bottom-left
    -- corner at whatever height it had reached, and stay that way.
    frame:SetScript("OnHide", function()
        if peek.cur then PeekFinish() end
    end)

    frame:Hide()
    self:SetLocked(IsLocked())
    ApplyOpacity()
    return frame
end

--------------------------------------------------------------------------------
-- Show, hide, lock
--------------------------------------------------------------------------------

function Meter:Show()
    if not ns:API() then
        ns:Print("CombatSession is not loaded - there is nothing to meter.")
        return
    end

    self:Create()
    ns.db.meterShown = true
    frame:Show()
    self:Refresh()
end

function Meter:Hide()
    if frame then frame:Hide() end
    if ns.db then ns.db.meterShown = false end
end

function Meter:Toggle()
    if frame and frame:IsShown() then self:Hide() else self:Show() end
    return ns.db and ns.db.meterShown or false
end

function Meter:IsShown()
    return frame and frame:IsShown() or false
end

-- Locking stops the window being moved or resized by accident and takes the
-- grip away with it. Everything else stays live: the rows still open the
-- viewer, the wheel still scrolls, and the menu still changes what is shown.
function Meter:SetLocked(locked)
    locked = locked and true or false
    if ns.db then ns.db.meterLocked = locked end

    if frame then
        frame:SetMovable(not locked)
        frame:SetResizable(not locked)
        frame.grip:SetShown(not locked)
    end
    return locked
end

function Meter:ToggleLock()
    return self:SetLocked(not IsLocked())
end
