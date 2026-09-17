-- CombatSessionViewer :: Window
--
-- The grid. Three things here are worth knowing before reading the rest.
--
-- ROW RECYCLING. A battleground session has forty players and a drill-down can
-- add another thirty rows under one of them, each with eleven cells. Building a
-- frame per row would mean hundreds of frames rebuilt on every scroll tick. So
-- a pool of frames just large enough to cover the visible height is mapped onto
-- a slice of the flat row list, and scrolling re-anchors and repopulates them.
-- Cost is bounded by the window's height, not the session's size.
--
-- PIXEL SCROLLING. The scroll position is a float, eased toward its target in
-- OnUpdate rather than snapped. WoW's wheel events are discrete, so snapping
-- gives the stepped, jumpy feel of the older inspector; easing over a few
-- frames reads as motion and makes the row under the cursor traceable.
--
-- FROZEN NAMES. Names and values live in two clipping frames side by side, and
-- share a vertical offset. Only the value side takes the horizontal offset, so
-- names stay pinned while columns scroll under the header. One row is therefore
-- two frames kept in lockstep, which is why the pool holds pairs.

local ADDON, ns = ...

local Model = ns.Model
local UI = {}
ns.UI = UI

local ROW_H         = 22
local SEP_H         = 3     -- rule between root units
local ICON_W        = 16    -- honor, role and spec slots
local IDENT_W       = 3 * (ICON_W + 3)   -- fixed identity strip on a unit row
local BLOCK_GAP     = 5     -- black band bracketing an open block
local MARKER_W      = 2     -- yellow marker line thickness
local SESSION_ROW_H = 46
local NAME_W        = 300
local COL_W         = 76
local HEADER_H      = 26
local SESSION_W     = 232
local BAR_W         = 16    -- scrollbar gutter; the knob fills it
local KNOB_L        = 44    -- knob length along the bar
local SUMMARY_H     = 38
local PAD           = 8

-- The team-coloured band behind each summary line: how tall, how far short of
-- the outcome column it stops, and how solid it starts.
local SUMMARY_BAND_H     = 15
local SUMMARY_BAND_GAP   = 8
local SUMMARY_BAND_ALPHA = 0.90

-- The summary field that belongs to the match rather than to either team: how
-- long it ran on the top line, and the dampening it ended on beneath.
local SUMMARY_RIGHT = 8

local SCHOOL_W      = 5     -- school stripe down the left edge of a spell icon
local SPELL_W       = ROW_H - 6

-- How far a row's bar starts in from the left of the name cell. Root units fill
-- it; each level below steps in, so nesting reads from the bars and not only
-- from the labels.
local BAR_INDENT    = { unit = 0, source = 14, spell = 28 }

local frame, grid, sessions

-- The version mismatch line on the title bar. Held here rather than hung off
-- the frame because Refresh has to reach it on every layout pass.
local warning

--------------------------------------------------------------------------------
-- Cross-hair highlight
--
-- Hovering a cell lights its whole row and its whole column, name cell and
-- column header included. With eleven columns of six-digit numbers, finding
-- which row a cell belongs to means tracking back across the grid, and lighting
-- one cell did nothing to help with that - the crossing pair is what actually
-- answers "whose number is this, and of what".
--
-- Kept as module state rather than on the frames, because the highlight is not
-- a property of the thing under the pointer: one cell being hovered has to be
-- told to every row in the pool.
--------------------------------------------------------------------------------

local hover = { row = nil, col = nil }

local function ApplyHover()
    if not grid then return end

    for _, row in ipairs(grid.rows) do
        local lit = (hover.row ~= nil) and (row == hover.row)
        row.nameHi:SetShown(lit)
        for _, cell in ipairs(row.cells) do
            cell.hi:SetShown(lit or (hover.col ~= nil and cell.col == hover.col))
        end
    end

    for _, button in ipairs(grid.headers) do
        button.hi:SetShown(hover.col ~= nil and button.col == hover.col)
    end
end

local function SetHover(row, col)
    if hover.row == row and hover.col == col then return end
    hover.row, hover.col = row, col
    ApplyHover()
end

--------------------------------------------------------------------------------
-- The school line on a spell tooltip
--
-- Appending to the game's own spell tooltip cannot be done by calling AddLine
-- after SetSpellByID. Spell data is fetched asynchronously when it is not
-- already cached, and when it arrives the tooltip is rebuilt from scratch -
-- discarding anything added in between. That is why the line showed up on a
-- second hover but not the first, and why the blank spacer went with it: both
-- had been added to a tooltip that was then thrown away and rebuilt.
--
-- A post-call is the supported answer. It runs every time a spell tooltip is
-- built, first pass and refresh alike, so there is no race to lose. It is
-- global, which is why it is gated on a row of ours actually being hovered.
--
-- Declared here rather than beside the row that uses it because the row's
-- OnEnter closes over these: declared after that handler is written, the
-- handler would capture a global of the same name instead.
--------------------------------------------------------------------------------

local hoveredSchool = nil
local schoolHooked  = false

local function AppendSchool(tooltip)
    if not hoveredSchool then return end
    -- A blank line first: the game's tooltip ends with the spell's own
    -- description, and a line butted onto it reads as the last sentence of it.
    tooltip:AddLine(" ")
    tooltip:AddLine(("|cff888888School|r  %s")
        :format(ns.ColorizeRGB(hoveredSchool.name, hoveredSchool.color)))
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall
   and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Spell,
        function(tooltip)
            if tooltip == GameTooltip then AppendSchool(tooltip) end
        end)
    schoolHooked = true
end

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function Fill(parent, color, layer)
    local tex = parent:CreateTexture(nil, layer or "BACKGROUND")
    tex:SetAllPoints(parent)
    tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return tex
end

local function Line(parent, color)
    local tex = parent:CreateTexture(nil, "BORDER")
    tex:SetColorTexture(color[1], color[2], color[3], color[4] or 1)
    return tex
end

local function Border(parent, color)
    local t = Line(parent, color); t:SetPoint("TOPLEFT");    t:SetPoint("TOPRIGHT");    t:SetHeight(1)
    local b = Line(parent, color); b:SetPoint("BOTTOMLEFT"); b:SetPoint("BOTTOMRIGHT"); b:SetHeight(1)
    local l = Line(parent, color); l:SetPoint("TOPLEFT");    l:SetPoint("BOTTOMLEFT");  l:SetWidth(1)
    local r = Line(parent, color); r:SetPoint("TOPRIGHT");   r:SetPoint("BOTTOMRIGHT"); r:SetWidth(1)
end

-- Edges as four textures, so a box can be drawn around a frame without a
-- backdrop. `weight` is the line thickness: the markers want more than a hairline
-- to register against a busy grid.
local function Outline(parent, color, weight)
    weight = weight or 1
    local parts = {}
    local t = Line(parent, color); t:SetPoint("TOPLEFT");    t:SetPoint("TOPRIGHT");    t:SetHeight(weight)
    local b = Line(parent, color); b:SetPoint("BOTTOMLEFT"); b:SetPoint("BOTTOMRIGHT"); b:SetHeight(weight)
    local l = Line(parent, color); l:SetPoint("TOPLEFT");    l:SetPoint("BOTTOMLEFT");  l:SetWidth(weight)
    local r = Line(parent, color); r:SetPoint("TOPRIGHT");   r:SetPoint("BOTTOMRIGHT"); r:SetWidth(weight)
    parts[1], parts[2], parts[3], parts[4] = t, b, l, r
    return parts
end

-- A vertical scroll position that eases toward a target.
--
-- Kept as plain numbers with an explicit Apply callback rather than as a
-- ScrollFrame: the content is virtual, so there is no child frame whose height
-- could drive a real scroll, and owning the arithmetic is what makes the pool
-- mapping straightforward.
local function NewScroller()
    return {
        cur = 0, target = 0, max = 0,

        SetMax = function(self, max)
            self.max = math.max(0, max)
            self.target = math.min(self.target, self.max)
            self.cur    = math.min(self.cur, self.max)
        end,

        Nudge = function(self, delta)
            self.target = math.max(0, math.min(self.max, self.target + delta))
        end,

        JumpTo = function(self, value)
            value = math.max(0, math.min(self.max, value))
            self.target, self.cur = value, value
        end,

        -- Returns true while still moving, so the caller knows to redraw.
        Step = function(self, elapsed)
            local diff = self.target - self.cur
            if math.abs(diff) < 0.5 then
                if self.cur ~= self.target then
                    self.cur = self.target
                    return true
                end
                return false
            end
            self.cur = self.cur + diff * math.min(1, elapsed * 16)
            return true
        end,
    }
end

-- The stock slider thumb is a small round bead that sits in the middle of the
-- gutter, which at this size reads as a dot rather than as something to grab.
-- Replaced with a plain block filling the gutter's full width: the knob is then
-- the same shape as the track it runs in, and its length says how much of the
-- list is on screen the way a scrollbar is supposed to.
--
-- Colouring the thumb texture rather than supplying art of its own, because a
-- solid fill is exactly what is wanted and the game has no flat knob to borrow.
local function StyleSlider(slider, horizontal)
    slider:SetOrientation(horizontal and "HORIZONTAL" or "VERTICAL")
    slider:SetThumbTexture(horizontal
        and "Interface\\Buttons\\UI-SliderBar-Button-Horizontal"
        or  "Interface\\Buttons\\UI-SliderBar-Button-Vertical")
    slider:SetObeyStepOnDrag(true)
    slider:SetValueStep(1)

    Fill(slider, { 0.10, 0.10, 0.12 })

    local thumb = slider:GetThumbTexture()
    if not thumb then return end
    thumb:SetColorTexture(0.44, 0.44, 0.50)
    thumb:SetSize(horizontal and KNOB_L or BAR_W,
                  horizontal and BAR_W  or KNOB_L)

    -- Lit while the pointer is on the bar, so the knob answers the mouse the
    -- way every other control in the window does.
    slider:HookScript("OnEnter", function() thumb:SetColorTexture(0.62, 0.62, 0.70) end)
    slider:HookScript("OnLeave", function() thumb:SetColorTexture(0.44, 0.44, 0.50) end)
end

--------------------------------------------------------------------------------
-- Session list
--------------------------------------------------------------------------------

local function SessionRow(index)
    local row = sessions.rows[index]
    if row then return row end

    row = CreateFrame("Button", nil, sessions.clip)
    row:SetSize(SESSION_W - BAR_W - 2 * PAD, SESSION_ROW_H - 4)
    row.bg = Fill(row, ns.COLOR.header)
    Border(row, ns.COLOR.line)

    -- Faction crest, drawn larger than the row and cropped by it, so the row
    -- carries a mark that is caught while reading down the list rather than a
    -- badge that has to be looked at.
    --
    -- Its own clipping frame, because the list pane clips the LIST and not each
    -- entry: an oversized texture parented straight to the row would spill into
    -- the rows above and below it.
    row.crestClip = CreateFrame("Frame", nil, row)
    row.crestClip:SetFrameLevel(row:GetFrameLevel() + 1)
    row.crestClip:SetPoint("TOPRIGHT", -1, -1)
    row.crestClip:SetPoint("BOTTOMRIGHT", -1, 1)
    row.crestClip:SetWidth(SESSION_ROW_H)
    row.crestClip:SetClipsChildren(true)
    row.crestClip:EnableMouse(false)

    row.crest = row.crestClip:CreateTexture(nil, "ARTWORK")
    row.crest:SetSize(SESSION_ROW_H + 18, SESSION_ROW_H + 18)
    row.crest:SetPoint("CENTER", row.crestClip, "CENTER", 3, 0)
    -- Rotation is counter-clockwise for a positive angle, so the slight
    -- clockwise tilt is a small negative one. Held dim: the text is what is
    -- being read, and the crest sits behind it.
    row.crest:SetRotation(-0.13)
    row.crest:SetAlpha(0.30)
    row.crest:Hide()

    -- The labels live above the crest, for the same reason the grid rows have a
    -- content frame: a child frame draws over every texture its parent owns, so
    -- text on the row itself would go under the crest rather than over it.
    row.content = CreateFrame("Frame", nil, row)
    row.content:SetAllPoints(row)
    row.content:SetFrameLevel(row.crestClip:GetFrameLevel() + 1)
    row.content:EnableMouse(false)

    row.map = row.content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    row.map:SetPoint("TOPLEFT", 6, -5)
    row.map:SetPoint("RIGHT", -6, 0)
    row.map:SetJustifyH("LEFT")

    row.when = row.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.when:SetPoint("TOPLEFT", row.map, "BOTTOMLEFT", 0, -2)

    row.who = row.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    row.who:SetPoint("TOPLEFT", row.when, "BOTTOMLEFT", 0, -2)

    row:SetScript("OnClick", function(self)
        if not self.key then return end
        Model:Select(self.key)
        UI:Refresh()
    end)
    row:SetScript("OnEnter", function(self) self.bg:SetAlpha(0.75) end)
    row:SetScript("OnLeave", function(self) self.bg:SetAlpha(1) end)

    sessions.rows[index] = row
    return row
end

local function LayoutSessions()
    local list = sessions.list
    local viewH = sessions.clip:GetHeight()
    sessions.scroll:SetMax(#list * SESSION_ROW_H - viewH)

    local first = math.floor(sessions.scroll.cur / SESSION_ROW_H)
    local slots = math.ceil(viewH / SESSION_ROW_H) + 2

    for i = 1, slots do
        local index = first + i
        local entry = list[index]
        local row = SessionRow(i)
        if entry then
            local map, when, who = Model:SessionLabel(entry)
            row.key = entry.key
            row.map:SetText(map)
            row.when:SetText(when)
            row.who:SetText(who)

            -- Absent for a match recorded before the faction was stored, which
            -- leaves the row plain rather than guessing at a side.
            local _, faction = Model:SessionCharacter(entry)
            local crest = faction and ns.FACTION_EMBLEM[faction]
            if crest then
                row.crest:SetTexture(crest)
                row.crest:Show()
            else
                row.crest:Hide()
            end

            local selected = (Model:Selected() == entry.key)
            local c = selected and ns.COLOR.selected or ns.COLOR.header
            row.bg:SetColorTexture(c[1], c[2], c[3])

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", sessions.clip, "TOPLEFT", 0,
                         -((index - 1) * SESSION_ROW_H - sessions.scroll.cur))
            row:Show()
        else
            row:Hide()
        end
    end

    -- Setting a slider fires its own OnValueChanged, which would call straight
    -- back into this function. The guard is set here rather than by callers so
    -- there is no path that can forget it.
    sessions.bar.syncing = true
    sessions.bar:SetMinMaxValues(0, math.max(1, sessions.scroll.max))
    sessions.bar:SetValue(sessions.scroll.cur)
    sessions.bar:SetShown(sessions.scroll.max > 0)
    sessions.bar.syncing = false
end

--------------------------------------------------------------------------------
-- Grid rows
--------------------------------------------------------------------------------

-- Whether a counterpart row opens into anything. One with no spells recorded is
-- a leaf, and treating it as openable would bracket an empty block.
--
-- Declared ahead of the cell and row builders, whose click handlers close over it.
local function HasSpells(data)
    if not (data and data.kind == "source" and data.part) then return false end
    return (data.part.spells ~= nil) and (#data.part.spells > 0)
end

-- What a non-active column shows at one row of an open block.
--
-- Each column is its own ranked list, and the active column's length decides
-- how many rows there are. So another column can run out early - its remaining
-- rows read "--" - or have more than fit, in which case the last row stands in
-- for the rest as "..." and the rows leading into it fade, which says "this
-- carries on" without implying the list simply ended.
--
-- The fade needs rows to happen over. With fewer than FADE_ROWS above the
-- "...", a fade is a couple of rows at odd opacities rather than a fade, so it
-- is left out and only the "..." is shown - including the one-row case, where
-- the "..." is the whole of it.
--
-- Returns the text, an opacity, the entry shown (or nil), and how many entries
-- the "..." stands for (or nil).
local FADE_ROWS = 3

local function RankedCell(list, rank, count, col)
    local length = list and #list or 0

    if length <= count then
        local entry = list and list[rank]
        if not entry then return "--", 1, nil, nil end
        return ns.FormatCell(col, entry.v, entry.n), 1, entry, nil
    end

    if rank >= count then
        return "...", 1, nil, length - count + 1
    end

    local entry = list[rank]
    local alpha = 1
    if count - 1 >= FADE_ROWS then
        -- 1 for the row just above the "...", FADE_ROWS for the first to fade.
        local fromEnd = count - rank
        if fromEnd <= FADE_ROWS then alpha = fromEnd / (FADE_ROWS + 1) end
    end
    return ns.FormatCell(col, entry.v, entry.n), alpha, entry, nil
end

local function CellTooltip(cell)
    local data, col = cell.data, cell.col
    if not (data and col) then return end

    local columns = Model:Columns()
    GameTooltip:SetOwner(cell, "ANCHOR_RIGHT")
    GameTooltip:AddLine(columns[col] or ("Column " .. col), 1, 1, 1)

    -- Every figure the drill-down holds, labelled. The bare "111,202 (21)" left
    -- the second number to be guessed at, and a total plus a count still does not
    -- say whether those casts were alike: an average of 40k is a different story
    -- if the range is 38k-42k than if it is 2k-380k.
    local function Detail(value, count, mn, mx)
        local isTime = _G.CombatSession and _G.CombatSession.COLUMN_IS_TIME
                   and _G.CombatSession.COLUMN_IS_TIME[col]

        local function Amount(n)
            if isTime then return ("%.1fs"):format((n or 0) / 1000) end
            return ns.Commas(n or 0)
        end

        GameTooltip:AddDoubleLine("Total", Amount(value), 0.7, 0.7, 0.7, 1, 1, 1)
        if (count or 0) > 0 then
            GameTooltip:AddDoubleLine(isTime and "Applications" or "Casts",
                                      ns.Commas(count), 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine("Average", Amount(value / count),
                                      0.7, 0.7, 0.7, 1, 1, 1)
        end
        -- Only meaningful once there is more than one, and only when the stored
        -- figures are real: a column that counts occurrences rather than amounts
        -- has a range of one to one, which says nothing.
        if mn and mx and (count or 0) > 1 and mx > mn then
            GameTooltip:AddDoubleLine("Largest", Amount(mx), 0.7, 0.7, 0.7, 1, 1, 1)
            GameTooltip:AddDoubleLine("Smallest", Amount(mn), 0.7, 0.7, 0.7, 1, 1, 1)
        end
    end

    local isActive = (col == Model:ActiveColumn())
    local function Hint(text)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(text, 0.5, 0.7, 1)
    end

    if data.kind == "unit" and data.unit then
        Detail(data.unit.cols[col] or 0,
               data.unit.counts and data.unit.counts[col] or 0)
        if not isActive then
            Hint(Model:IsSelected(data.name)
                and "Click to make this the active column."
                or  "Click to select this player and make this the active column.")
        elseif Model:IsExpanded(data.name) then
            Hint("Click to close this breakdown.")
        else
            Hint("Click to break this value down by unit.")
        end

    elseif data.kind == "source" or data.kind == "spell" then
        -- In the active column the cell is the row's own figure. Anywhere else
        -- it is that column's entry at this rank, which is usually somebody or
        -- something else - so it is named, or the number is unreadable.
        local entry = cell.entry
        if entry then
            if not isActive then
                local label = entry.summary and ns.SPELL_TOTALS
                    or (data.kind == "source"
                        and ns.Colorize(ns.ShortName(entry.name) or "",
                                        Model:ClassOf(entry.name))
                        or entry.name)
                GameTooltip:AddLine(label or "", 1, 1, 1)
            end
            Detail(entry.v, entry.n, entry.mn, entry.mx)
        elseif cell.more then
            GameTooltip:AddLine(("%d more in this column than fit here."):format(cell.more),
                                0.7, 0.7, 0.7)
        else
            GameTooltip:AddLine("Nothing ranked this far down in this column.",
                                0.6, 0.6, 0.6)
        end

        if not isActive then
            Hint(cell.more and "Click to make this the active column and see all of them."
                            or "Click to make this the active column.")
        elseif data.kind == "source" and data.part.spells and #data.part.spells > 0 then
            Hint(Model:ActiveSource() == data.name and "Click to close its spells."
                                                   or "Click to break this down by spell.")
        end
    end
    GameTooltip:Show()
end

local function GridCell(row, index)
    local cell = row.cells[index]
    if cell then return cell end

    cell = CreateFrame("Button", nil, row.values)
    cell:SetSize(COL_W, ROW_H)
    cell:SetPoint("TOPLEFT", (index - 1) * COL_W, 0)

    -- The yellow wash on an opened value and on the figures it revealed. Under
    -- the hover light and the text, over the row's own track.
    cell.bg = cell:CreateTexture(nil, "BACKGROUND")
    cell.bg:SetAllPoints(cell)
    cell.bg:Hide()

    cell.hi = cell:CreateTexture(nil, "ARTWORK")
    cell.hi:SetAllPoints(cell)
    cell.hi:SetColorTexture(1, 1, 1, 0.07)
    cell.hi:Hide()

    cell.text = cell:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cell.text:SetPoint("RIGHT", -8, 0)

    cell.divider = Line(cell, ns.COLOR.line)
    cell.divider:SetPoint("TOPLEFT")
    cell.divider:SetPoint("BOTTOMLEFT")
    cell.divider:SetWidth(1)
    cell.divider:SetAlpha(0.35)

    cell.col = index
    cell:SetScript("OnEnter", function(self)
        SetHover(row, self.col)
        CellTooltip(self)
    end)
    cell:SetScript("OnLeave", function()
        SetHover(nil, nil)
        GameTooltip:Hide()
    end)
    -- A click outside the active column makes that column active and moves
    -- the cursor to the row, but opens nothing: the first click on a new
    -- measure is a request to look at it, and opening something on the same
    -- click would be two things at once. Inside the active column a click
    -- opens or closes whatever the cell belongs to.
    --
    -- Only a root row outside the selection moves the cursor. Rows inside it -
    -- the selected player, and the breakdown open beneath them - are already
    -- where the cursor is, so for them the click only changes the column, and
    -- an open breakdown carries on under the new one.
    cell:SetScript("OnClick", function(self)
        local data = self.data
        if not data or data.kind == "note" then return end

        if self.col ~= Model:ActiveColumn() then
            Model:SetActiveColumn(self.col)
            if data.kind == "unit" and not Model:IsSelected(data.name) then
                Model:SelectRow(data.name)
            end
        elseif data.kind == "unit" then
            Model:ToggleExpand(data.name, data.unit)
        elseif data.kind == "source" and HasSpells(data) then
            Model:ToggleSource(data.name)
        else
            return
        end
        UI:Refresh()
    end)

    row.cells[index] = cell
    return cell
end

-- One row: a name half and a value half, kept in lockstep.
--
-- Both halves are layered in three frames rather than by texture layer alone,
-- because a child frame always draws above every texture of its parent however
-- the layers are set. The hatching has to sit between the background and the
-- bar, and it needs a clipping frame of its own, so the things that must be
-- above it need a frame of their own too:
--
--   row.name            background
--   row.hatchName       diagonal hatching, clipped
--   row.content         bar, icons, label, rule
local function GridRow(index)
    local row = grid.rows[index]
    if row then return row end

    row = { cells = {} }

    row.name = CreateFrame("Button", nil, grid.nameClip)
    row.name:SetSize(NAME_W, ROW_H)
    row.nameBg = Fill(row.name, ns.COLOR.noTeamTrack)

    row.content = CreateFrame("Frame", nil, row.name)
    row.content:SetAllPoints(row.name)
    row.content:SetFrameLevel(row.name:GetFrameLevel() + 5)
    row.content:EnableMouse(false)

    -- The bar shares the name cell with the label rather than taking a column
    -- of its own: the name is the widest thing on the row, so it is where a
    -- length is legible, and it costs no horizontal space to read.
    row.nameBar = row.content:CreateTexture(nil, "BACKGROUND")
    row.nameBar:SetPoint("TOPLEFT", 0, -1)
    row.nameBar:SetPoint("BOTTOMLEFT")
    row.nameBar:SetWidth(1)

    -- Identity strip: honor level, role, spec (or class). Fixed positions so a
    -- name never moves because one of them failed to resolve.
    --
    -- The honor badge is untrimmed: it is already a badge rather than a square
    -- icon, so cropping its outer edge takes off part of the art.
    row.honorIcon = row.content:CreateTexture(nil, "ARTWORK")
    row.honorIcon:SetSize(ICON_W, ICON_W)
    row.honorIcon:SetPoint("LEFT", row.content, "LEFT", 8, 0)
    row.honorIcon:Hide()

    row.roleIcon = row.content:CreateTexture(nil, "ARTWORK")
    row.roleIcon:SetSize(ICON_W, ICON_W)
    row.roleIcon:SetPoint("LEFT", row.content, "LEFT", 8 + (ICON_W + 3), 0)
    row.roleIcon:Hide()

    row.specIcon = row.content:CreateTexture(nil, "ARTWORK")
    row.specIcon:SetSize(ICON_W, ICON_W)
    row.specIcon:SetPoint("LEFT", row.content, "LEFT", 8 + 2 * (ICON_W + 3), 0)
    row.specIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.specIcon:Hide()

    row.nameHi = row.content:CreateTexture(nil, "ARTWORK")
    row.nameHi:SetAllPoints(row.content)
    row.nameHi:SetColorTexture(1, 1, 1, 0.06)
    row.nameHi:Hide()

    -- Drawn on both halves so the rule runs unbroken across the frozen column
    -- boundary. Only root units get one: the drill-down beneath a unit reads as
    -- part of that unit, and ruling it off would break the block apart.
    row.nameSep = row.content:CreateTexture(nil, "OVERLAY")
    row.nameSep:SetPoint("TOPLEFT")
    row.nameSep:SetPoint("TOPRIGHT")
    row.nameSep:SetHeight(SEP_H)

    -- Spell rows only, and the school leads. The spell icon says which button
    -- was pressed; the school says what kind of damage arrived, which is a
    -- different question and the one that decides what you do about it - a
    -- warlock's Shadow Bolt and their Incinerate are the same picture at this
    -- size and are not the same thing to anyone trying to survive them.
    --
    -- The school as a stripe down the left edge of the spell icon, the icon's
    -- own height and flush against it: spell art beside spell art read as two
    -- spells, and a stripe attached to the icon reads as a property OF that
    -- spell rather than as a second thing in the row.
    --
    -- Two solid fills, because the art that would have suited it does not
    -- resolve on this client - see the note in Core.lua. The dark rectangle
    -- underneath is one pixel proud on three sides, which frames the stripe and
    -- leaves a hairline rule between it and the icon.
    row.schoolEdge = row.content:CreateTexture(nil, "ARTWORK", nil, 1)
    row.schoolEdge:SetSize(SCHOOL_W + 2, SPELL_W + 2)
    row.schoolEdge:SetColorTexture(0, 0, 0, 0.85)
    row.schoolEdge:Hide()

    row.schoolIcon = row.content:CreateTexture(nil, "ARTWORK", nil, 2)
    row.schoolIcon:SetSize(SCHOOL_W, SPELL_W)
    row.schoolIcon:SetPoint("LEFT", row.schoolEdge, "LEFT", 1, 0)
    row.schoolIcon:Hide()

    -- Sized to the row so the icon column is the row height and the label starts
    -- clear of it; trimmed because WoW icon art carries a border in the outer
    -- few percent of the texture.
    row.icon = row.content:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(SPELL_W, SPELL_W)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    row.icon:Hide()

    row.label = row.content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetPoint("LEFT", 8, 0)
    row.label:SetPoint("RIGHT", -8, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    -- The label sits on top of the bar, so a class colour can land on a team
    -- colour close enough to swallow it - a Shaman's blue on team blue. A black
    -- outline around every glyph plus a hard shadow keeps the name legible over
    -- any fill, which a shadow alone did not manage against the brighter bars.
    local file, size = row.label:GetFont()
    if file then row.label:SetFont(file, size, "OUTLINE") end
    row.label:SetShadowColor(0, 0, 0, 1)
    row.label:SetShadowOffset(1, -1)

    row.values = CreateFrame("Frame", nil, grid.valueClip)
    row.values:SetHeight(ROW_H)
    row.valueBg = Fill(row.values, ns.COLOR.noTeamTrack)

    row.valueSep = row.values:CreateTexture(nil, "OVERLAY")
    row.valueSep:SetPoint("TOPLEFT")
    row.valueSep:SetPoint("TOPRIGHT")
    row.valueSep:SetHeight(SEP_H)

    -- A name row is the whole row for highlight purposes, so hovering it lights
    -- the value cells beside it - but no column, because a name belongs to none.
    row.name:SetScript("OnEnter", function(self)
        SetHover(row, nil)

        if self.data and self.data.kind == "unit" then
            UI:UnitTooltip(self, self.data)
            return
        end

        -- A counterpart who is a player is described exactly as they are at the
        -- root. The data comes from the same builder, so the two can't drift.
        if self.data and self.data.playerData then
            UI:UnitTooltip(self, self.data.playerData)
            return
        end

        -- Only real spell ids get the game's tooltip. Dispel and purge entries
        -- carry a synthetic id standing for an aura-and-dispeller pair, which
        -- no client lookup resolves, so those fall back to the row's own text.
        if self.spellId then
            -- Read by the post-call, which is what actually writes the line.
            hoveredSchool = self.school
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetSpellByID(self.spellId)
            -- Only where there is no post-call to do it. On such a client the
            -- line is written directly and an uncached spell may still lose it,
            -- which is the old behaviour rather than a new failure.
            if not schoolHooked then AppendSchool(GameTooltip) end
            GameTooltip:Show()
        end
    end)
    row.name:SetScript("OnLeave", function()
        SetHover(nil, nil)
        -- Cleared here and nowhere else: the post-call is global, so this is
        -- what keeps the line off every other spell tooltip in the interface.
        hoveredSchool = nil
        GameTooltip:Hide()
    end)

    row.name:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row.name:SetScript("OnClick", function(self, button)
        local data = self.data
        if not data then return end

        if button == "RightButton" then
            -- Players only, root or counterpart. The menu copies a character
            -- name, which means nothing for "Spell Totals", a spell, or a pet.
            if data.kind == "unit" then
                UI:NameMenu(self, data)
            elseif data.playerData then
                UI:NameMenu(self, data.playerData)
            end
            return
        end

        -- A name always stands for its row's entry in the active column, so a
        -- click here is the same as a click on that column's cell.
        if data.kind == "unit" then
            Model:ToggleExpand(data.name, data.unit)
        elseif HasSpells(data) then
            Model:ToggleSource(data.name)
        else
            return
        end
        UI:Refresh()
    end)

    grid.rows[index] = row
    return row
end

-- GetSpellTexture moved under C_Spell, so both spellings are tried. A nil
-- result is a normal answer, not a failure: melee has no spell, and the
-- synthetic ids the dispel and purge columns use name a pair rather than a
-- spell, so nothing will resolve them.
local function SpellIcon(id)
    if not id or id <= 0 then return nil end
    if C_Spell and C_Spell.GetSpellTexture then return C_Spell.GetSpellTexture(id) end
    if GetSpellTexture then return GetSpellTexture(id) end
    return nil
end

-- The side a scoreboard-less player fought on, named the way that side is named
-- in this kind of match: a faction in a battleground, the arena team otherwise.
function UI:TeamName(index)
    local teams = Model:Teams()
    local entry = Model:Entry()
    local team = teams and teams[index]
    if not team then return ("Team %d"):format(index) end

    if team.teamName and team.teamName ~= "" then return team.teamName end
    if entry and entry.type == "battleground" and team.side ~= nil then
        return (team.side == 0) and "Horde" or "Alliance"
    end
    return ("Team %d"):format(index)
end

--------------------------------------------------------------------------------
-- Player row: tooltip and menu
--------------------------------------------------------------------------------

local ROLE_NAME = { TANK = "Tank", HEALER = "Healer", DAMAGER = "Damage" }

-- Everything known about the player on a root row, in one box.
--
-- The grid trims the realm off a name and shows the spec as a 16-pixel icon,
-- both of which are the right call for a table and neither of which answers
-- "who is this". The scoreboard figures are included where there are any: they
-- are what the player can check this addon against, and having them beside the
-- log-derived numbers is the whole of that comparison.
function UI:UnitTooltip(owner, data)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")

    local color = ns.ClassColor(data.class)
    GameTooltip:AddLine(ns.ShortName(data.name) or "", color[1], color[2], color[3])

    local realm = tostring(data.name or ""):match("^[^-]+%-(.+)$")
    if realm then GameTooltip:AddLine(realm, 0.55, 0.55, 0.55) end

    local spec = ns.SpecById(data.specId) or ns.SpecInfo(data.class, data.spec)
    local className = data.class
        and ((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[data.class])
             or data.class)

    -- Spec and class on one line, because "Frost" alone is ambiguous across
    -- three classes and "Mage" alone throws away what the scoreboard told us.
    if data.spec and data.spec ~= "" and className then
        GameTooltip:AddDoubleLine("Spec", ("%s %s"):format(data.spec, className),
                                  0.6, 0.6, 0.6, 1, 1, 1)
    elseif className then
        GameTooltip:AddDoubleLine("Class", className, 0.6, 0.6, 0.6, 1, 1, 1)
    end

    if spec and ROLE_NAME[spec.role] then
        GameTooltip:AddDoubleLine("Role", ROLE_NAME[spec.role], 0.6, 0.6, 0.6, 1, 1, 1)
    end

    local scoreboard = data.player and data.player.player
    if scoreboard and scoreboard.race then
        GameTooltip:AddDoubleLine("Race", scoreboard.race, 0.6, 0.6, 0.6, 1, 1, 1)
    end

    -- Spelled out as well as badged, because the badge only says which tier the
    -- level falls in and the number is the thing people compare.
    if data.honor then
        GameTooltip:AddDoubleLine("Honor level", tostring(data.honor),
                                  0.6, 0.6, 0.6, 1, 1, 1)
    end

    local side = data.team or data.departed
    if side then
        GameTooltip:AddDoubleLine("Side", UI:TeamName(side), 0.6, 0.6, 0.6, 1, 1, 1)
    end

    -- Item level for a player, which is what the advanced log block carries in
    -- the slot creatures use for their level.
    if data.unit and data.unit.level and data.unit.level > 0 then
        GameTooltip:AddDoubleLine("Item level", tostring(data.unit.level),
                                  0.6, 0.6, 0.6, 1, 1, 1)
    end

    if scoreboard then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Scoreboard", 1, 0.82, 0.2)
        if scoreboard.damage then
            GameTooltip:AddDoubleLine("Damage", ns.Short(scoreboard.damage),
                                      0.6, 0.6, 0.6, 1, 1, 1)
        end
        if scoreboard.healing then
            GameTooltip:AddDoubleLine("Healing", ns.Short(scoreboard.healing),
                                      0.6, 0.6, 0.6, 1, 1, 1)
        end
        if scoreboard.kb then
            GameTooltip:AddDoubleLine("Killing blows", tostring(scoreboard.kb),
                                      0.6, 0.6, 0.6, 1, 1, 1)
        end
        if scoreboard.deaths then
            GameTooltip:AddDoubleLine("Deaths", tostring(scoreboard.deaths),
                                      0.6, 0.6, 0.6, 1, 1, 1)
        end
    end

    if data.departed then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Fought here but is not on the scoreboard, so nothing\n"
                         .. "of theirs is counted in a team total.",
                            0.85, 0.65, 0.4, true)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Right-click to copy the name.", 0.5, 0.7, 1)
    GameTooltip:Show()
end

-- Copying a name out of the game.
--
-- An addon cannot write to the clipboard - there is no API for it - so the only
-- way to hand a name over is to put it in an edit box, select it, and let the
-- player press Ctrl+C. That is why this is a dialog and not a one-click action.
local copyFrame

function UI:CopyName(name)
    if not copyFrame then
        copyFrame = CreateFrame("Frame", "CombatSessionViewerCopyFrame", UIParent)
        copyFrame:SetSize(330, 84)
        copyFrame:SetPoint("CENTER")
        copyFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        copyFrame:EnableMouse(true)
        Fill(copyFrame, { 0.05, 0.05, 0.06, 0.98 })
        Border(copyFrame, ns.COLOR.line)

        local label = copyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", PAD, -PAD)
        label:SetText("|cff999999Ctrl+C to copy, Escape to close.|r")

        copyFrame.edit = CreateFrame("EditBox", nil, copyFrame, "InputBoxTemplate")
        copyFrame.edit:SetPoint("TOPLEFT", PAD + 6, -(PAD + 24))
        copyFrame.edit:SetPoint("TOPRIGHT", -PAD, -(PAD + 24))
        copyFrame.edit:SetHeight(22)
        copyFrame.edit:SetAutoFocus(false)
        copyFrame.edit:SetScript("OnEscapePressed", function() copyFrame:Hide() end)
        copyFrame.edit:SetScript("OnEnterPressed", function() copyFrame:Hide() end)

        -- Read-only in effect. The box has to be a real edit box for Ctrl+C to
        -- work at all, so a typed character is put straight back rather than
        -- left to be copied instead of the name.
        copyFrame.edit:SetScript("OnTextChanged", function(self, byUser)
            if not byUser then return end
            self:SetText(copyFrame.value or "")
            self:HighlightText()
        end)

        local close = CreateFrame("Button", nil, copyFrame, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -2, -2)

        tinsert(UISpecialFrames, "CombatSessionViewerCopyFrame")
        copyFrame:Hide()
    end

    copyFrame.value = tostring(name or "")
    copyFrame:Show()
    copyFrame.edit:SetText(copyFrame.value)
    copyFrame.edit:HighlightText()
    copyFrame.edit:SetFocus()
end

-- MenuUtil has been the only menu system since 11.0. Where it is missing there
-- is nothing to fall back to, so the one entry the menu would have offered is
-- performed directly rather than the click doing nothing.
function UI:NameMenu(owner, data)
    local name = data.name
    if not name or name == "" then return end

    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        self:CopyName(name)
        return
    end

    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(ns.ShortName(name))
        root:CreateButton("Copy Name-Realm", function() UI:CopyName(name) end)
    end)
end

--------------------------------------------------------------------------------

-- The coloured band behind a summary line. Nil clears it.
--
-- A gradient rather than a flat block, and it stops well short of the outcome:
-- a solid bar across the strip would read as a header row and fight the figures
-- sitting on it, where a band that fades out behind the name says which side
-- this line belongs to and then gets out of the way.
--
-- SetGradient modulates the texture's own colour, so the base is set to white
-- and the two stops carry the colour. A client without it falls back to a flat
-- wash, which is the same statement made less prettily.
function UI:SetSummaryBand(index, color)
    local band = grid.summaryBands and grid.summaryBands[index]
    if not band then return end

    if not color then
        band:Hide()
        return
    end

    if band.SetGradient and CreateColor then
        band:SetColorTexture(1, 1, 1, 1)
        band:SetGradient("HORIZONTAL",
            CreateColor(color[1], color[2], color[3], SUMMARY_BAND_ALPHA),
            CreateColor(color[1], color[2], color[3], 0))
    else
        band:SetColorTexture(color[1], color[2], color[3], 0.35)
    end
    band:Show()
end

-- Honor level, role and specialisation, in a strip of fixed width.
--
-- Each slot is drawn or left empty, never collapsed, because a name that shifts
-- depending on what happened to resolve is worse than a gap.
--
-- The third slot used to be reserved for a hero talent and was always empty:
-- there is no API for another player's talents and the scoreboard does not
-- carry them, so nothing was ever going to fill it. Honor level took the space,
-- and leads the strip because it is the one thing here that says something
-- about the player rather than about the character sheet.
function UI:SetIdentity(row, data)
    if data.kind ~= "unit" then
        row.honorIcon:Hide()
        row.roleIcon:Hide()
        row.specIcon:Hide()
        return
    end

    -- Empty for anyone the recorder never got a unit token for, and for every
    -- session recorded before honor was captured at all.
    local badge = ns.HonorBadge(data.honor)
    if badge then
        row.honorIcon:SetTexture(badge)
        row.honorIcon:Show()
    else
        row.honorIcon:Hide()
    end

    -- The log's spec id where there is one, since it carries the icon and role
    -- directly; the scoreboard's localised name only otherwise.
    local spec = ns.SpecById(data.specId) or ns.SpecInfo(data.class, data.spec)

    local roleAtlas = spec and ns.ROLE_ATLAS[spec.role]
    if roleAtlas then
        row.roleIcon:SetAtlas(roleAtlas)
        row.roleIcon:Show()
    else
        row.roleIcon:Hide()
    end

    local iconTexture = (spec and spec.icon) or ns.ClassIcon(data.class)
    if iconTexture then
        row.specIcon:SetTexture(iconTexture)
        row.specIcon:Show()
    else
        row.specIcon:Hide()
    end
end

-- Diagonal hatching over a row shown on a side but not counted in it.
--
-- Colour alone could not carry that: grey said "no side at all", and a plain
-- team colour would have said "counted in the total". The stripes are the row's
-- own colour lifted a little - texture rather than a second colour - so the side
-- still reads at a glance and the hatching does not shout over it.
--
-- Sits between the background and the bar. Each half gets a clipping frame of
-- its own at a level below the row's content frame: a rotated stripe is drawn
-- from its centre and is longer than the row is tall, so without a clip the
-- corners spill into the rows above and below.
function UI:SetDeparted(row, side)
    if not side then
        if row.hatchName then row.hatchName:Hide() end
        if row.hatchValue then row.hatchValue:Hide() end
        return
    end

    if not row.hatchName then
        local function Hatch(parent, width)
            local clip = CreateFrame("Frame", nil, parent)
            clip:SetFrameLevel(parent:GetFrameLevel() + 1)
            clip:SetPoint("TOPLEFT", 0, -SEP_H)
            clip:SetPoint("BOTTOMLEFT")
            clip:SetWidth(width)
            clip:SetClipsChildren(true)
            clip:EnableMouse(false)
            clip.stripes = {}
            for x = -ROW_H, width + ROW_H, 15 do
                local stripe = clip:CreateTexture(nil, "ARTWORK")
                stripe:SetSize(6, ROW_H * 3)
                stripe:SetPoint("CENTER", clip, "LEFT", x, 0)
                stripe:SetRotation(math.pi / 4)
                clip.stripes[#clip.stripes + 1] = stripe
            end
            return clip
        end

        row.hatchName  = Hatch(row.name, NAME_W)
        row.hatchValue = Hatch(row.values, 1600)
    end

    -- Lifted from the TRACK, not the bar. Against the bar colour the stripes
    -- read as a second highlight; a little above the background is all that is
    -- wanted, which is a pattern you notice without being able to name.
    local track = (side == 1) and ns.COLOR.team1Track
               or (side == 2) and ns.COLOR.team2Track
               or ns.COLOR.noTeamTrack
    local tint = ns.Shade(track, ns.SHADE.hatch)

    for _, clip in ipairs({ row.hatchName, row.hatchValue }) do
        for _, stripe in ipairs(clip.stripes) do
            stripe:SetColorTexture(math.min(1, tint[1]), math.min(1, tint[2]),
                                   math.min(1, tint[3]), 1)
        end
        clip:Show()
    end
end

-- Track behind the row, and the bar drawn over it. A nil bar means the row
-- carries no value worth comparing - a note, or a zero.
local function RowColors(data, expanded)
    if data.kind == "unit" then
        -- A player missing from the scoreboard still gets their side's colour.
        -- The hatching, not a different colour, is what says "not counted".
        local side = data.team or data.departed
        local track, bar
        if side == 1 then
            track, bar = expanded and ns.COLOR.team1Open or ns.COLOR.team1Track, ns.COLOR.team1Bar
        elseif side == 2 then
            track, bar = expanded and ns.COLOR.team2Open or ns.COLOR.team2Track, ns.COLOR.team2Bar
        else
            track, bar = expanded and ns.COLOR.noTeamOpen or ns.COLOR.noTeamTrack, ns.COLOR.noTeamBar
        end
        -- The whole root level recedes while a drill-down is open, including the
        -- rows that were not clicked, so the revealed level reads as the
        -- foreground rather than as one more thing competing for attention.
        if Model:IsOpen() then bar = ns.Shade(bar, ns.SHADE.unitOpen) end
        return track, bar
    end

    if data.kind == "source" then
        local anyOpen = Model:ActiveSource() ~= nil
        return ns.COLOR.source,
               ns.Shade(ns.ClassColor(data.class),
                        anyOpen and ns.SHADE.sourceOpen or ns.SHADE.source)
    elseif data.kind == "spell" then
        return ns.COLOR.spell, ns.Shade(ns.ClassColor(data.class), ns.SHADE.spell)
    end

    return ns.COLOR.spell, nil
end

local function Populate(row, data)
    local columns = Model:Columns()
    local expanded = (data.kind == "unit") and Model:IsExpanded(data.name)
    local activeCol = Model:ActiveColumn()
    local open = Model:IsOpen()

    -- The deepest level currently revealed: counterparts once a unit is open,
    -- spells once one of those counterparts is open. Nil when nothing is.
    local innermost
    if open then
        innermost = Model:ActiveSource() and "spell" or "source"
    end

    -- Whether this row sits inside the open block: the open unit itself, or
    -- anything revealed beneath it. Only one unit is ever open, so every
    -- counterpart and spell row belongs to it.
    local inBlock = expanded or data.kind == "source" or data.kind == "spell"

    -- Whether this row's active cell is one that was opened to reveal the level
    -- below it: the open unit, and - when its spells are showing - the open
    -- counterpart.
    local opened = expanded
        or (data.kind == "source" and Model:ActiveSource() == data.name)

    -- The selected row takes the lighter track an open row has, collapsed or
    -- not, so the row under the box reads as the focus and not only as boxed.
    local selected = (data.kind == "unit") and Model:IsSelected(data.name)
    local track, bar = RowColors(data, expanded or selected)
    row.nameBg:SetColorTexture(track[1], track[2], track[3])
    row.valueBg:SetColorTexture(track[1], track[2], track[3])

    local rule = (data.kind == "unit")
    if rule then
        local l = ns.COLOR.line
        row.nameSep:SetColorTexture(l[1], l[2], l[3])
        row.valueSep:SetColorTexture(l[1], l[2], l[3])
    end
    row.nameSep:SetShown(rule)
    row.valueSep:SetShown(rule)

    -- A nested row steps its bar in as well as its label, so the depth is
    -- legible from the bars alone. Root units keep the full width: they are the
    -- level everything else is measured against, and indenting them would give
    -- away name-cell width for nothing.
    local barIndent = BAR_INDENT[data.kind] or 0

    local frac = data.frac or 0
    row.nameBar:ClearAllPoints()
    row.nameBar:SetPoint("TOPLEFT", barIndent, rule and -SEP_H or 0)
    row.nameBar:SetPoint("BOTTOMLEFT", barIndent, 0)
    if bar and frac > 0 then
        row.nameBar:SetColorTexture(bar[1], bar[2], bar[3])
        -- A floor of two pixels so a small but non-zero contribution still
        -- registers as present rather than reading as nothing at all. Scaled to
        -- what is left of the cell after the indent, so a full bar still ends
        -- where a root unit's full bar ends.
        row.nameBar:SetWidth(math.max(2, frac * (NAME_W - barIndent)))
        row.nameBar:Show()
    else
        row.nameBar:Hide()
    end

    local indent, text, icon, school = 0, ns.ShortName(data.name) or "", nil, nil
    if data.kind == "unit" then
        -- Icons occupy a fixed strip whether or not each one resolves, so names
        -- start at the same x on every row. A missing honor badge or spec leaves
        -- a gap rather than shunting the name left and breaking the column.
        indent = IDENT_W

        text = ns.Colorize(text, data.class)
        if data.departed then
            -- Not on the scoreboard, so not in any team total - but the side
            -- they fought on is still known, and saying so is the whole point.
            text = text .. (" |cff888888(%s)|r"):format(UI:TeamName(data.departed))
        elseif not data.unit then
            text = text .. " |cff886644(no log data)|r"
        end
        -- The same open/closed marker a counterpart row carries, now that the
        -- name itself opens the row. Absent for a player with no log data,
        -- since there is nothing to open.
        if data.unit then
            text = (expanded and "|cffffcc00v|r " or "|cff777777>|r ") .. text
        end

    elseif data.kind == "source" then
        indent = 18
        local open = Model:ActiveSource() == data.name
        text = (open and "|cffffcc00v|r " or "|cff777777>|r ") .. text
        if data.summary then
            text = (open and "|cffffcc00v|r " or "|cff777777>|r ")
                .. "|cffffd964" .. ns.SPELL_TOTALS .. "|r"
        elseif not (data.part.spells and #data.part.spells > 0) then
            text = "|cff555555-|r " .. ns.ShortName(data.name)
        end
    elseif data.kind == "spell" then
        indent = 36
        text = "|cffaaaaaa" .. text .. "|r"
        icon = SpellIcon(data.id)
        school = ns.SchoolInfo(data.use and data.use.school)
    else
        indent = 18
        text = "|cff777777" .. text .. "|r"
    end

    UI:SetIdentity(row, data)
    UI:SetDeparted(row, (data.kind == "unit") and data.team == nil and data.departed or nil)

    -- Walked left to right and advanced past each thing that was actually
    -- drawn, so a spell with no school icon closes the gap rather than leaving
    -- a hole where one would have been.
    local x = 8 + indent

    if icon and school then
        -- Only the backing is placed; the stripe is anchored inside it once, at
        -- construction, and rides along with it. Set one pixel left of x so the
        -- stripe itself starts where the run does.
        row.schoolEdge:ClearAllPoints()
        row.schoolEdge:SetPoint("LEFT", row.name, "LEFT", x - 1, 0)
        row.schoolIcon:SetColorTexture(school.color[1], school.color[2],
                                       school.color[3])
        row.schoolEdge:Show()
        row.schoolIcon:Show()

        -- The stripe plus the hairline beside it. No gap: the icon butts
        -- straight up against the rule, so the two read as one object.
        x = x + SCHOOL_W + 1
    else
        row.schoolEdge:Hide()
        row.schoolIcon:Hide()
    end

    if icon then
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row.name, "LEFT", x, 0)
        row.icon:SetTexture(icon)
        row.icon:Show()
        x = x + SPELL_W + 4
    else
        row.icon:Hide()
    end

    -- Re-anchored rather than offset, because the pool reuses a row at one
    -- depth for a row at another and a stale LEFT would leave it indented wrong.
    row.label:ClearAllPoints()
    row.label:SetPoint("LEFT", row.name, "LEFT", x, 0)
    row.label:SetPoint("RIGHT", row.name, "RIGHT", -8, 0)
    row.label:SetText(text)
    row.name.data = data
    -- Only set when the lookup succeeded, so the OnEnter handler has a single
    -- unambiguous test for "this row has a real spell behind it".
    row.name.spellId = icon and data.id or nil
    row.name.school  = school
    row.name.clickable = HasSpells(data)
                      or (data.kind == "unit" and data.unit ~= nil)

    -- The cross-hair lights every row it passes over, so clickability can no
    -- longer be "this row highlights". It is carried by how brightly it does.
    row.nameHi:SetColorTexture(1, 1, 1, row.name.clickable and 0.11 or 0.05)

    row.values:SetWidth(math.max(1, #columns * COL_W))

    for i = 1, #columns do
        local cell = GridCell(row, i)
        cell.data = data
        cell:Show()

        -- Every column carries a value now. A unit row shows its own totals;
        -- a counterpart or spell row shows its own figure in the active column
        -- and, in every other column, that column's entry at the same rank.
        local value, alpha, entry, more = "", 1, nil, nil
        if data.kind == "unit" and data.unit then
            value = ns.FormatCell(i, data.unit.cols[i] or 0,
                                  data.unit.counts and data.unit.counts[i] or 0)
        elseif data.kind == "unit" then
            value = "--"
        elseif data.kind == "source" or data.kind == "spell" then
            if i == data.col then
                entry = (data.kind == "source") and data.part or data.use
                value = ns.FormatCell(i, entry.v, entry.n)
            else
                value, alpha, entry, more =
                    RankedCell(data.lists and data.lists[i], data.rank, data.count, i)
            end
        end
        cell.entry, cell.more = entry, more

        local isActiveCol = (i == activeCol)

        -- Yellow marks the innermost level on show and nothing above it. Marking
        -- every level in the open chain in the same yellow put it on the root
        -- row, on every counterpart and on every spell at once, which is three
        -- answers to "what am I looking at" and no emphasis at all. The chain
        -- is still traceable, but by a paler wash on each value that was
        -- opened, rather than by the same colour everywhere.
        local inner  = isActiveCol and innermost ~= nil and data.kind == innermost
        local parent = isActiveCol and opened

        local wash = (parent and ns.COLOR.cellParent)
                  or (inner and ns.COLOR.cellInner)
                  or nil
        if wash then
            cell.bg:SetColorTexture(wash[1], wash[2], wash[3], wash[4])
            cell.bg:Show()
        else
            cell.bg:Hide()
        end

        local color
        if value == "--" or value == "" then
            color = ns.TEXT.empty
        elseif parent then
            color = ns.TEXT.parent
        elseif inner then
            color = ns.TEXT.active
        elseif not open then
            color = ns.TEXT.normal
        elseif inBlock then
            -- Inside the open block, but not the figures being read. Lighter
            -- than the rest of the grid, because these are part of the answer:
            -- the other measures for the same unit, ranked alongside it.
            color = ns.TEXT.inBlock
        else
            -- While a drill-down is up everything outside it recedes, including
            -- the active column on other units: the same measure, but not what
            -- is being broken down.
            color = ns.TEXT.recede
        end

        cell.text:SetText(value)
        cell.text:SetTextColor(color[1], color[2], color[3])
        -- Always set, not only when fading: the pool hands a faded cell to the
        -- next row that needs one.
        cell.text:SetAlpha(alpha)
        cell:EnableMouse(data.kind ~= "note")
    end

    for i = #columns + 1, #row.cells do row.cells[i]:Hide() end
end

--------------------------------------------------------------------------------
-- Grid layout
--------------------------------------------------------------------------------

-- The arrow on whichever header is sorting. Ascending is up. White rather than
-- yellow, because yellow belongs to the active column.
local function SortMark(asc)
    return asc and "|cffffffff^|r " or "|cffffffffv|r "
end

-- A header's sorted look: a grey box and a darker grey fill. Deliberately not
-- the yellow of the active column, which is a separate choice now.
local function SetSorted(button, sorted)
    local fill = sorted and ns.COLOR.sortBg or ns.COLOR.header
    button.bg:SetColorTexture(fill[1], fill[2], fill[3])
    for _, edge in ipairs(button.outline) do edge:SetShown(sorted) end
end

local function LayoutHeader()
    local columns = Model:Columns()
    local sortCol, asc = Model:Sort()
    local activeCol = Model:ActiveColumn()

    local nameSorted = (sortCol == ns.NAME_COL)
    local nameLabel = "Player Name"
    if nameSorted then
        nameLabel = SortMark(asc) .. "|cffffffff" .. nameLabel .. "|r"
    else
        nameLabel = "|cff999999" .. nameLabel .. "|r"
    end
    grid.nameHeader.text:SetText(nameLabel)
    SetSorted(grid.nameHeader, nameSorted)

    for i = 1, #columns do
        local button = grid.headers[i]
        if not button then
            button = CreateFrame("Button", nil, grid.headerTrack)
            button:SetSize(COL_W, HEADER_H)
            button:SetPoint("TOPLEFT", (i - 1) * COL_W, 0)
            button.bg = Fill(button, ns.COLOR.header)

            -- Lit by the cross-hair when the pointer is anywhere in this
            -- column, so the header names what is being read without the eye
            -- having to travel up to find it.
            button.hi = button:CreateTexture(nil, "ARTWORK")
            button.hi:SetAllPoints(button)
            button.hi:SetColorTexture(1, 1, 1, 0.07)
            button.hi:Hide()

            button.text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            button.text:SetPoint("RIGHT", -8, 0)
            button.col = i
            button:SetScript("OnClick", function(self)
                Model:SetSort(self.col)
                UI:Refresh()
            end)
            button:SetScript("OnEnter", function(self)
                SetHover(nil, self.col)
                GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
                GameTooltip:AddLine(Model:Columns()[self.col] or "", 1, 1, 1)
                GameTooltip:AddLine("Click to sort by this column.", 0.5, 0.7, 1)
                if self.col ~= Model:ActiveColumn() then
                    GameTooltip:AddLine("Click a value below to make it the active column.",
                                        0.7, 0.7, 0.7, true)
                end
                GameTooltip:Show()
            end)
            button:SetScript("OnLeave", function()
                SetHover(nil, nil)
                GameTooltip:Hide()
            end)
            button.outline = Outline(button, ns.COLOR.sortBox, MARKER_W)
            grid.headers[i] = button
        end

        local label = ns.ColumnLabel(columns[i])
        local isSort   = (i == sortCol)
        local isActive = (i == activeCol)
        if isSort then label = SortMark(asc) .. label end

        -- The text names the active column, in the same yellow as the box that
        -- runs down it. The box and fill say what is sorted. The two can land
        -- on one column or two; each look is read on its own.
        if isActive then
            button.text:SetTextColor(ns.TEXT.active[1], ns.TEXT.active[2], ns.TEXT.active[3])
        elseif isSort then
            button.text:SetTextColor(1, 1, 1)
        else
            button.text:SetTextColor(0.75, 0.75, 0.75)
        end
        SetSorted(button, isSort)

        button.text:SetText(label)
        button:Show()
    end

    for i = #columns + 1, #grid.headers do grid.headers[i]:Hide() end
    grid.headerTrack:SetWidth(math.max(1, #columns * COL_W))
end

local function LayoutGrid()
    local rows  = grid.data
    local viewH = grid.nameClip:GetHeight()
    local columns = Model:Columns()

    grid.vscroll:SetMax(#rows * ROW_H - viewH)
    grid.hscroll:SetMax(#columns * COL_W - grid.valueClip:GetWidth())

    local first = math.floor(grid.vscroll.cur / ROW_H)
    local slots = math.ceil(viewH / ROW_H) + 2

    for i = 1, slots do
        local index = first + i
        local data  = rows[index]
        local row   = GridRow(i)
        local y     = grid.vscroll.cur - (index - 1) * ROW_H

        -- Clipping hides a frame but does not reliably stop it taking a click,
        -- and the pool deliberately runs two rows past the visible height so
        -- easing has something to scroll into. Those spare rows sit over the
        -- horizontal scrollbar, so they are hidden outright rather than left to
        -- swallow a click aimed at it.
        if data and y <= ROW_H and y > -(viewH + ROW_H) then
            Populate(row, data)
            row.name:ClearAllPoints()
            row.name:SetPoint("TOPLEFT", grid.nameClip, "TOPLEFT", 0, y)
            row.values:ClearAllPoints()
            row.values:SetPoint("TOPLEFT", grid.valueClip, "TOPLEFT", -grid.hscroll.cur, y)
            row.name:Show()
            row.values:Show()
        else
            row.name:Hide()
            row.values:Hide()
        end
    end
    for i = slots + 1, #grid.rows do
        grid.rows[i].name:Hide()
        grid.rows[i].values:Hide()
    end

    grid.headerTrack:ClearAllPoints()
    grid.headerTrack:SetPoint("TOPLEFT", grid.headerClip, "TOPLEFT", -grid.hscroll.cur, 0)

    -- The tall box marks the active column, which always exists now - it is
    -- what the bars measure whether or not anything is open, and with the
    -- header no longer carrying it this box is the only place it is shown.
    -- It lives inside the value pane and is clipped by it, rather than being
    -- hidden by hand when it scrolls out.
    local activeCol = Model:ActiveColumn()
    if Model:Cache() and activeCol <= #columns then
        grid.colBox:ClearAllPoints()
        grid.colBox:SetPoint("TOPLEFT", grid.valueClip, "TOPLEFT",
                             (activeCol - 1) * COL_W - grid.hscroll.cur, 0)
        -- Stops at the last row, not at the bottom of the window. A box running
        -- on past the data implied there was more of it below.
        local filled = math.max(0, #rows * ROW_H - grid.vscroll.cur)
        grid.colBox:SetSize(COL_W,
            math.max(1, math.min(grid.valueClip:GetHeight(), filled)))
        grid.colBox:Show()
    else
        grid.colBox:Hide()
    end

    -- Both blocks are placed the same way, so the positioning is written once.
    -- Extents come from the model's row ranges, not from the rows that happened
    -- to be drawn: a block's first row is often scrolled off the top while its
    -- children are still visible, and the bracket has to survive that.
    --
    -- Two halves, one per pane, because each is then clipped by its own pane - a
    -- single frame spanning both would draw over the header when a block is
    -- half-scrolled. The value half anchors to the pane rather than to a row's
    -- column track, so it wraps the block instead of sliding off with the
    -- columns.
    local function PlaceBlock(nameBox, valueBox, first, count)
        if not first then
            nameBox:Hide()
            valueBox:Hide()
            return
        end

        local y = grid.vscroll.cur - (first - 1) * ROW_H - SEP_H
        local h = math.max(1, count * ROW_H - SEP_H)

        nameBox:ClearAllPoints()
        nameBox:SetPoint("TOPLEFT", grid.nameClip, "TOPLEFT", 0, y)
        nameBox:SetSize(NAME_W, h)
        nameBox:Show()

        valueBox:ClearAllPoints()
        valueBox:SetPoint("TOPLEFT", grid.valueClip, "TOPLEFT", 0, y)
        valueBox:SetSize(math.max(1, grid.valueClip:GetWidth()), h)
        valueBox:Show()
    end

    PlaceBlock(grid.rowBoxName, grid.rowBoxValue, Model:OpenBlock())
    PlaceBlock(grid.srcBoxName, grid.srcBoxValue, Model:OpenSourceBlock())

    grid.vbar.syncing, grid.hbar.syncing = true, true
    grid.vbar:SetMinMaxValues(0, math.max(1, grid.vscroll.max))
    grid.vbar:SetValue(grid.vscroll.cur)
    grid.vbar:SetShown(grid.vscroll.max > 0)

    grid.hbar:SetMinMaxValues(0, math.max(1, grid.hscroll.max))
    grid.hbar:SetValue(grid.hscroll.cur)
    grid.hbar:SetShown(grid.hscroll.max > 0)
    grid.vbar.syncing, grid.hbar.syncing = false, false

    -- Re-applied last, because a row frame that was just repopulated - or newly
    -- created by the pool - would otherwise keep whatever highlight it had at
    -- the top of this pass.
    ApplyHover()
end

local function LayoutSummary()
    local teams = Model:Teams()
    local entry = Model:Entry()

    local function Blank()
        for _, row in ipairs(grid.summaryRows) do
            for _, text in ipairs(row) do text:SetText("") end
        end
        for i = 1, #grid.summaryBands do UI:SetSummaryBand(i, nil) end
    end

    if not teams then
        Blank()
        grid.summaryNote:SetText(Model:Selected()
            and "|cff886644This session has no cache built yet - /reload to consume it.|r"
            or  "|cff888888Select a session on the left.|r")
        return
    end
    grid.summaryNote:SetText("")

    -- Both sides losing is not two losses, it is a draw. The recorder reports a
    -- winner per side, so a match that ended without one marks neither as won.
    local draw = (teams[1].won == false) and (teams[2].won == false)

    -- What decided it, where there is a figure for that.
    local objective = Model:Objective()

    for i = 1, 2 do
        local team = teams[i]
        local fields = grid.summaryRows[i]

        local label = UI:TeamName(i)
        if entry and entry.type == "battleground" and team.side ~= nil then
            label = (team.side == 0) and "|cffdd4444Horde|r" or "|cff5599ffAlliance|r"
        end

        local outcome = ""
        if draw then
            outcome = "|cffcccc66Draw|r"
        elseif team.won ~= nil then
            outcome = team.won and "|cff66ff66Win|r" or "|cffff6666Lose|r"
        end

        -- Rated only, and a zero is not a rating: GetBattlefieldTeamInfo returns
        -- 0 for an unrated match, and 0 is truthy in Lua, so an unrated skirmish
        -- was showing a bare "0" where the rating goes.
        local rated = (entry and entry.rated) or false
        local rating, mmr = "", ""
        if rated and team.rating and team.rating > 0 then
            rating = tostring(team.rating)
            if team.ratingChange and team.ratingChange ~= 0 then
                rating = rating .. ((team.ratingChange > 0)
                    and ("  |cff66ff66+%d|r"):format(team.ratingChange)
                    or  ("  |cffff6666%d|r"):format(team.ratingChange))
            end
        end
        if rated and team.mmr and team.mmr > 0 then
            mmr = ("|cff888888MMR|r %d"):format(team.mmr)
        end

        -- The right-hand slot carries what belongs to the match rather than to
        -- either side: when it was played on the top line, and the dampening it
        -- ended on beneath. Neither is a team figure, which is why they sit
        -- clear of the columns that are.
        --
        -- Dampening is arenas only. A battleground reading "0%" would be
        -- stating a fact about a mechanic it does not have.
        local extra = ""
        if i == 1 then
            local span = ns.FormatDuration(Model:Duration())
            if span then extra = ("|cff888888Time|r %s"):format(span) end
        elseif entry and entry.type == "arena" then
            local value = Model:Dampening()
            if value and value > 0 then
                extra = ("|cff888888Dampening|r %d%%"):format(value)
            end
        end

        -- The side's own colour behind its line, solid under the name and gone
        -- before the outcome. The two team colours are otherwise only visible
        -- once you are reading rows, so the summary said nothing about which
        -- side was which until you looked away from it.
        UI:SetSummaryBand(i, (i == 1) and ns.COLOR.team1Bar or ns.COLOR.team2Bar)

        local goal = ""
        if objective and objective[i] then
            goal = ("|cff888888%s|r %s"):format(objective.label, ns.Commas(objective[i]))
        end

        fields[1]:SetText(("%s |cff888888(%d)|r"):format(label, team.count))
        fields[2]:SetText(outcome)
        fields[3]:SetText(goal)
        fields[4]:SetText(("|cff888888Damage|r %s"):format(ns.Short(team.damage)))
        fields[5]:SetText(("|cff888888Healing|r %s"):format(ns.Short(team.healing)))
        fields[6]:SetText(rating)
        fields[7]:SetText(mmr)
        fields[SUMMARY_RIGHT]:SetText(extra)
    end
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

-- Widening past the last column left the header strip and the row box running
-- on into empty space, which read as a table that had lost its columns. The
-- window is capped at exactly what the columns need instead, so the grid always
-- ends where the data does.
local function ClampWidth()
    local columns = Model:Columns()
    -- Walked left to right so this can be checked against the frame
    -- construction rather than tuned by eye:
    --   PAD        window margin
    --   SESSION_W  session list
    --   PAD        gap between the two panes
    --   PAD        grid pane's own left inset
    --   NAME_W     frozen name column
    --   columns    every value column at full width
    --   BAR_W      vertical scrollbar, which sits beside the values
    --   PAD        grid pane's right inset
    --   PAD        window margin
    local needed = (5 * PAD) + SESSION_W + NAME_W + (#columns * COL_W) + BAR_W
    local maxW = math.max(760, needed)

    if frame.SetResizeBounds then frame:SetResizeBounds(760, 380, maxW, 2400) end
    if frame:GetWidth() > maxW then
        frame:SetWidth(maxW)
        ns.db.width = maxW
    end
end

-- The title-bar warning, sized to whatever room the title and the byline have
-- left. Kept out of Refresh's own body only because it has to run from Show as
-- well, where there is not yet anything to lay out.
local function LayoutWarning()
    if not warning then return end

    local text, detail = ns:VersionWarning()
    if not text then
        warning:Hide()
        return
    end

    -- 230 for the name and version on the left, 190 for the byline and the
    -- close button on the right. Below the floor the line would be unreadable
    -- anyway, and a warning that overlaps the title is worse than one that
    -- runs to the edge.
    local room = math.max((frame:GetWidth() or 0) - 420, 240)
    warning:SetWidth(room)
    warning.text:SetText(text)
    warning.detail = detail
    warning:Show()
end

function UI:Refresh()
    if not frame or not frame:IsShown() then return end

    sessions.list = Model:Sessions()
    grid.data     = Model:Rows()

    LayoutWarning()
    ClampWidth()
    LayoutHeader()
    LayoutSummary()
    LayoutSessions()
    LayoutGrid()
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function BuildSessionPane(parent)
    sessions = { rows = {}, list = {} }

    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT", PAD, -30)
    pane:SetPoint("BOTTOMLEFT", PAD, PAD)
    pane:SetWidth(SESSION_W)
    Fill(pane, ns.COLOR.panel)
    Border(pane, ns.COLOR.line)

    local reload = CreateFrame("Button", nil, pane, "UIPanelButtonTemplate")
    reload:SetSize(SESSION_W - 2 * PAD, 22)
    reload:SetPoint("TOPLEFT", PAD, -PAD)
    reload:SetText("Reload UI")
    reload:SetScript("OnClick", function()
        -- Reopened on the way back. A reload asked for from inside the viewer
        -- is a round trip to pick up new sessions, not a way out of it, and
        -- coming back to a closed window loses the place the user was in.
        --
        -- Safe to set here: saved variables are written at the START of a
        -- reload, so this lands in the file that the next login reads.
        if ns.db then ns.db.reopen = true end
        ReloadUI()
    end)
    reload:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Reload the interface", 1, 1, 1)
        GameTooltip:AddLine("Sessions the application has written since you logged in\n"
                         .. "only appear after a reload.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    reload:SetScript("OnLeave", function() GameTooltip:Hide() end)

    sessions.clip = CreateFrame("Frame", nil, pane)
    sessions.clip:SetPoint("TOPLEFT", reload, "BOTTOMLEFT", 0, -PAD)
    sessions.clip:SetPoint("BOTTOMRIGHT", pane, "BOTTOMRIGHT", -(BAR_W + PAD), PAD)
    sessions.clip:SetClipsChildren(true)

    sessions.scroll = NewScroller()

    sessions.bar = CreateFrame("Slider", nil, pane)
    sessions.bar:SetPoint("TOPRIGHT", -PAD / 2, -(22 + 2 * PAD))
    sessions.bar:SetPoint("BOTTOMRIGHT", -PAD / 2, PAD)
    sessions.bar:SetWidth(BAR_W)
    StyleSlider(sessions.bar, false)
    sessions.bar:SetScript("OnValueChanged", function(self, value)
        if self.syncing then return end
        sessions.scroll:JumpTo(value)
        LayoutSessions()
    end)

    sessions.clip:EnableMouseWheel(true)
    sessions.clip:SetScript("OnMouseWheel", function(_, delta)
        sessions.scroll:Nudge(-delta * SESSION_ROW_H)
    end)

    return pane
end

local function BuildGridPane(parent, sessionPane)
    grid = { rows = {}, headers = {}, data = {} }

    local pane = CreateFrame("Frame", nil, parent)
    pane:SetPoint("TOPLEFT", sessionPane, "TOPRIGHT", PAD, 0)
    pane:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    Fill(pane, ns.COLOR.panel)
    Border(pane, ns.COLOR.line)

    -- Two summary rows built as real columns rather than one padded string per
    -- line. WoW's UI font is proportional, so padding with spaces lines nothing
    -- up - "Alliance" and "Horde" are different widths at the same character
    -- count, and colour codes count toward a %-16s while occupying no space at
    -- all. Fixed anchors are the only thing that actually produces columns.
    -- Team figures, then a last field for facts about the match itself,
    -- sitting past the MMR. The objective sits beside the outcome because it
    -- is the reason for it. It keeps its column in an arena, where it is empty,
    -- so the figures after it line up the same in every kind of match.
    --   name, outcome, objective, damage, healing, rating, MMR, match
    grid.summaryFields = { 0, 118, 172, 262, 362, 462, 542, 638 }

    -- One per summary line, behind the text. BORDER puts them over the pane's
    -- own fill and under the OVERLAY font strings, so no layering by hand.
    --
    -- Width is read off the field table rather than written down twice: the
    -- band has to stop short of whatever x the outcome sits at, and a second
    -- constant would be a second thing to remember to move.
    grid.summaryBands = {}
    for line = 1, 2 do
        local band = pane:CreateTexture(nil, "BORDER")
        band:SetPoint("TOPLEFT", PAD, -(PAD + (line - 1) * 15) + 1)
        band:SetSize(grid.summaryFields[2] - SUMMARY_BAND_GAP, SUMMARY_BAND_H)
        band:Hide()
        grid.summaryBands[line] = band
    end

    grid.summaryRows = {}
    for line = 1, 2 do
        local row = {}
        for field = 1, #grid.summaryFields do
            local text = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            text:SetPoint("TOPLEFT", PAD + grid.summaryFields[field],
                          -(PAD + (line - 1) * 15))
            text:SetJustifyH("LEFT")
            row[field] = text
        end
        grid.summaryRows[line] = row
    end

    -- Spans the whole strip, for messages that are not a team at all.
    grid.summaryNote = pane:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    grid.summaryNote:SetPoint("TOPLEFT", PAD, -PAD)
    grid.summaryNote:SetJustifyH("LEFT")

    -- Header sits above the value columns only, and takes the horizontal offset
    -- so a label never drifts away from the column it names.
    grid.headerClip = CreateFrame("Frame", nil, pane)
    grid.headerClip:SetPoint("TOPLEFT", PAD + NAME_W, -(SUMMARY_H + PAD))
    grid.headerClip:SetPoint("TOPRIGHT", -(BAR_W + PAD), -(SUMMARY_H + PAD))
    grid.headerClip:SetHeight(HEADER_H)
    grid.headerClip:SetClipsChildren(true)
    Fill(grid.headerClip, ns.COLOR.header)

    grid.headerTrack = CreateFrame("Frame", nil, grid.headerClip)
    grid.headerTrack:SetPoint("TOPLEFT")
    grid.headerTrack:SetHeight(HEADER_H)

    -- A button rather than a label, because the name column sorts like any
    -- other. It sits outside the header's clipping frame: the name column is
    -- frozen, so its header must not scroll with the value columns.
    grid.nameHeader = CreateFrame("Button", nil, pane)
    grid.nameHeader:SetPoint("TOPLEFT", grid.headerClip, "TOPLEFT", -NAME_W, 0)
    grid.nameHeader:SetSize(NAME_W, HEADER_H)
    grid.nameHeader.bg = Fill(grid.nameHeader, ns.COLOR.header)
    grid.nameHeader.outline = Outline(grid.nameHeader, ns.COLOR.sortBox, MARKER_W)

    grid.nameHeader.text =
        grid.nameHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    grid.nameHeader.text:SetPoint("LEFT", 8, 0)
    grid.nameHeader.text:SetJustifyH("LEFT")

    grid.nameHeader:SetScript("OnClick", function()
        Model:SetSort(ns.NAME_COL)
        UI:Refresh()
    end)
    grid.nameHeader:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Player Name", 1, 1, 1)
        GameTooltip:AddLine("Click to sort by name.", 0.5, 0.7, 1)
        GameTooltip:AddLine("Click a name to open its breakdown in the active column.",
                            0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    grid.nameHeader:SetScript("OnLeave", function() GameTooltip:Hide() end)

    grid.nameClip = CreateFrame("Frame", nil, pane)
    grid.nameClip:SetPoint("TOPLEFT", grid.headerClip, "BOTTOMLEFT", -NAME_W, -2)
    grid.nameClip:SetPoint("BOTTOM", pane, "BOTTOM", 0, BAR_W + PAD)
    grid.nameClip:SetWidth(NAME_W)
    grid.nameClip:SetClipsChildren(true)

    grid.valueClip = CreateFrame("Frame", nil, pane)
    grid.valueClip:SetPoint("TOPLEFT", grid.headerClip, "BOTTOMLEFT", 0, -2)
    grid.valueClip:SetPoint("TOPRIGHT", grid.headerClip, "BOTTOMRIGHT", 0, -2)
    grid.valueClip:SetPoint("BOTTOM", pane, "BOTTOM", 0, BAR_W + PAD)
    grid.valueClip:SetClipsChildren(true)

    -- Marker frames sit above the rows, so they are given a frame level well
    -- clear of the pooled row frames rather than relying on creation order.
    --
    -- `gap` adds a thick black band immediately above and below the frame. The
    -- open block is otherwise just another run of rows in a continuous list, and
    -- the eye has to work to find where the drill-down starts and stops; a hard
    -- break at both ends says "this, and only this, is what you are reading".
    local function Marker(parent, color, hideEdge, gap)
        local marker = CreateFrame("Frame", nil, parent)
        marker:SetFrameLevel(parent:GetFrameLevel() + 20)

        -- No colour means bands only. The counterpart block is bracketed but
        -- not boxed: it already sits inside the root's box, and a second
        -- outline there would read as two competing frames rather than as one
        -- nested inside the other.
        if color then
            local edges = Outline(marker, color, MARKER_W)
            if hideEdge then edges[hideEdge]:Hide() end
        end

        if gap then
            for _, corner in ipairs({ "TOP", "BOTTOM" }) do
                local band = marker:CreateTexture(nil, "OVERLAY")
                band:SetColorTexture(0, 0, 0, 1)
                band:SetHeight(BLOCK_GAP)
                if corner == "TOP" then
                    band:SetPoint("BOTTOMLEFT",  marker, "TOPLEFT")
                    band:SetPoint("BOTTOMRIGHT", marker, "TOPRIGHT")
                else
                    band:SetPoint("TOPLEFT",  marker, "BOTTOMLEFT")
                    band:SetPoint("TOPRIGHT", marker, "BOTTOMRIGHT")
                end
            end
        end

        marker:Hide()
        return marker
    end

    grid.colBox      = Marker(grid.valueClip, ns.COLOR.activeDim)
    grid.rowBoxName  = Marker(grid.nameClip,  ns.COLOR.active, 4, true)  -- no right edge
    grid.rowBoxValue = Marker(grid.valueClip, ns.COLOR.active, 3, true)  -- no left edge

    -- Bands only, one level in, so an open counterpart is bracketed the same way
    -- an open root is.
    grid.srcBoxName  = Marker(grid.nameClip,  nil, nil, true)
    grid.srcBoxValue = Marker(grid.valueClip, nil, nil, true)

    grid.vscroll = NewScroller()
    grid.hscroll = NewScroller()

    grid.vbar = CreateFrame("Slider", nil, pane)
    grid.vbar:SetPoint("TOPRIGHT", grid.headerClip, "BOTTOMRIGHT", BAR_W, -2)
    grid.vbar:SetPoint("BOTTOM", pane, "BOTTOM", 0, BAR_W + PAD)
    grid.vbar:SetWidth(BAR_W)
    StyleSlider(grid.vbar, false)
    grid.vbar:SetScript("OnValueChanged", function(self, value)
        if self.syncing then return end
        grid.vscroll:JumpTo(value)
        LayoutGrid()
    end)

    grid.hbar = CreateFrame("Slider", nil, pane)
    grid.hbar:SetPoint("BOTTOMLEFT", PAD + NAME_W, PAD / 2)
    grid.hbar:SetPoint("BOTTOMRIGHT", -(BAR_W + PAD), PAD / 2)
    grid.hbar:SetHeight(BAR_W)
    StyleSlider(grid.hbar, true)
    grid.hbar:SetScript("OnValueChanged", function(self, value)
        if self.syncing then return end
        grid.hscroll:JumpTo(value)
        LayoutGrid()
    end)

    -- The wheel scrolls rows; shift-wheel scrolls columns, which saves reaching
    -- for the horizontal bar when the grid is wider than the window.
    for _, target in ipairs({ grid.nameClip, grid.valueClip }) do
        target:EnableMouseWheel(true)
        target:SetScript("OnMouseWheel", function(_, delta)
            if IsShiftKeyDown() then
                grid.hscroll:Nudge(-delta * COL_W)
            else
                grid.vscroll:Nudge(-delta * ROW_H * 3)
            end
        end)
    end

    return pane
end

function UI:Create()
    if frame then return frame end

    frame = CreateFrame("Frame", "CombatSessionViewerFrame", UIParent)
    frame:SetSize(ns.db.width, ns.db.height)
    frame:SetPoint(ns.db.point, UIParent, ns.db.point, ns.db.x, ns.db.y)
    -- MEDIUM rather than HIGH, which is where the game's own panels and most
    -- addon windows sit. On HIGH this window was above all of them whatever the
    -- user did, which is only ever right for the window you happen to be using -
    -- so it shares the layer instead, and SetToplevel raises it within that
    -- layer when it is clicked. Clicking another window then puts that one on
    -- top, which is what everything else in the interface does.
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetResizable(true)
    if frame.SetResizeBounds then frame:SetResizeBounds(760, 380) end
    frame:SetScript("OnMouseDown", function(self) self:Raise() end)
    Fill(frame, { 0.03, 0.03, 0.04, 0.96 })
    Border(frame, ns.COLOR.line)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", PAD, -8)
    title:SetText("CombatSession Viewer |cff808080-- " .. ns.VersionText() .. "|r")

    local drag = CreateFrame("Frame", nil, frame)
    drag:SetPoint("TOPLEFT")
    drag:SetPoint("TOPRIGHT")
    drag:SetHeight(28)
    drag:EnableMouse(true)
    -- Raised by hand as well as by SetToplevel: a click that lands on a child
    -- frame - a row, a cell, the session list - is consumed there and never
    -- reaches the window, so dragging the title bar is otherwise the only thing
    -- that brings it forward.
    --
    -- Named rather than written inline because the warning line sits on top of
    -- this strip and has to go on doing its job; see below.
    local function GrabTitleBar()
        frame:Raise()
        frame:StartMoving()
    end
    local function ReleaseTitleBar()
        frame:StopMovingOrSizing()
        local point, _, _, x, y = frame:GetPoint()
        ns.db.point, ns.db.x, ns.db.y = point, x, y
    end

    drag:SetScript("OnMouseDown", GrabTitleBar)
    drag:SetScript("OnMouseUp", ReleaseTitleBar)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -2, -2)
    close:SetScript("OnClick", function() UI:Hide() end)

    -- Byline, right-justified on the title line. Anchored to the close button
    -- rather than to the frame edge so it keeps its gap whatever that button is
    -- sized at, and pinned to the same y as the title so the two share a line.
    local credit = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    credit:SetPoint("TOPRIGHT", close, "TOPLEFT", -2, -6)
    credit:SetText("|cff808080Created by McDakson|r")

    -- The version mismatch notice, centred on the title bar between the name
    -- and the byline.
    --
    -- Up here rather than over the grid, because it is not about the session
    -- being looked at: while the two halves disagree every figure below it is
    -- suspect, so the warning has to outrank whatever row the user clicked.
    -- Width is set from the window's actual size in Refresh, so it cannot grow
    -- into the title on a narrow window.
    --
    -- A frame rather than a bare FontString, because one line is room for the
    -- instruction but not for the steps, and the steps are the part that gets
    -- somebody unstuck. They live in a tooltip, which needs something hoverable.
    warning = CreateFrame("Frame", nil, frame)
    warning:SetPoint("TOP", frame, "TOP", 0, -5)
    warning:SetHeight(18)
    warning:EnableMouse(true)
    warning:Hide()

    -- Explicitly above the drag strip, which covers the whole top bar and so
    -- covers this. Both are children of the window and neither outranks the
    -- other by default, so which one the cursor lands on comes down to
    -- undefined ordering - and it landed on the drag strip, leaving a warning
    -- whose instructions nobody could reach.
    warning:SetFrameLevel(drag:GetFrameLevel() + 1)

    -- And therefore has to carry the dragging itself, or the middle of the
    -- title bar would stop moving the window for exactly as long as there is
    -- something wrong to report.
    warning:SetScript("OnMouseDown", GrabTitleBar)
    warning:SetScript("OnMouseUp", ReleaseTitleBar)

    warning.text = warning:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    warning.text:SetAllPoints()
    warning.text:SetJustifyH("CENTER")
    warning.text:SetWordWrap(false)
    warning.text:SetTextColor(1, 0.33, 0.33)

    warning:SetScript("OnEnter", function(self)
        if not self.detail then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("CombatSession", 1, 0.82, 0)
        GameTooltip:AddLine(self.detail, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    warning:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local sessionPane = BuildSessionPane(frame)
    BuildGridPane(frame, sessionPane)

    local grip = CreateFrame("Button", nil, frame)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -2, 2)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetScript("OnMouseDown", function() frame:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        ns.db.width, ns.db.height = frame:GetWidth(), frame:GetHeight()
        UI:Refresh()
    end)

    -- One driver for both lists. Sliders are told the new value with a guard so
    -- their own OnValueChanged does not fight the easing that set it.
    frame:SetScript("OnUpdate", function(_, elapsed)
        -- Both are stepped every frame, not short-circuited: `or` would skip the
        -- horizontal step whenever the vertical one was still moving.
        local movedV = grid.vscroll:Step(elapsed)
        local movedH = grid.hscroll:Step(elapsed)
        if movedV or movedH then LayoutGrid() end
        if sessions.scroll:Step(elapsed) then LayoutSessions() end
    end)

    tinsert(UISpecialFrames, "CombatSessionViewerFrame")
    frame:Hide()
    return frame
end

--------------------------------------------------------------------------------

function UI:Show()
    if not ns:API() then
        ns:Print("CombatSession is not loaded - there is nothing to view.")
        return
    end

    self:Create()
    Model:RestoreSort()

    -- Restoring the last session is worth it here in a way that restoring the
    -- expansion is not: it is almost always the match just played, and having
    -- to pick it again on every reload is the sort of friction that stops a
    -- tool being opened at all.
    if not Model:Selected() then
        local list = Model:Sessions()
        local wanted = ns.db.lastKey
        local found
        for _, entry in ipairs(list) do
            if entry.key == wanted then found = entry.key break end
        end
        Model:Select(found or (list[1] and list[1].key))
    end

    frame:Show()
    self:Refresh()
end

function UI:Hide()
    if frame then frame:Hide() end
end

function UI:Toggle()
    if frame and frame:IsShown() then self:Hide() else self:Show() end
end
