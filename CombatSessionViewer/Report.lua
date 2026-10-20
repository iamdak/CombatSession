-- CombatSessionViewer :: Report
--
-- Sends a ranked list from the grid to a chat channel. Opened from a cell's right
-- click menu, so it always knows two things: which measure the cell was in, which
-- is the report's subject and its window title, and where in the grid the cell
-- was - the root list of players, a player's breakdown, or one counterpart's
-- spells inside it. Every list the cell sits inside is offered, outermost first,
-- so a report taken from deep in a breakdown can still send the whole ranking.
--
-- What is sent is drawn from the same row data the grid draws, so the figures in
-- chat are the figures on screen.

local ADDON, ns = ...

local Report = {}
ns.Report = Report

local PAD   = 8
local ROW_H = 20
local GAP   = 6
local WIDTH = 340
local TITLE_H = 24
local PREVIEW_LINES = 12

local CHANNELS = {
    { key = "SAY",     label = "Say" },
    { key = "PARTY",   label = "Party" },
    { key = "RAID",    label = "Raid" },
    { key = "WHISPER", label = "Whisper" },
}

-- 0 is every entry in the list.
local LINES = {
    { n = 0,  label = "All" },
    { n = 3,  label = "Top 3" },
    { n = 5,  label = "Top 5" },
    { n = 10, label = "Top 10" },
}

local frame
local current = { col = nil, options = {}, choice = 1 }

--------------------------------------------------------------------------------
-- What is sent
--------------------------------------------------------------------------------

local function IsTime(col)
    local cs = _G.CombatSession
    return cs and cs.COLUMN_IS_TIME and cs.COLUMN_IS_TIME[col]
end

local function Amount(col, value)
    if IsTime(col) then return ("%.1fs"):format((value or 0) / 1000) end
    return ns.Short(value)
end

local function Who(name)
    return ns.ShortName(name) or tostring(name or "?")
end

-- Every list the cell sits inside, outermost first: the players ranked by this
-- measure, then - from inside a player's breakdown - that breakdown, and from a
-- spell row the spells it belongs to. Each option builds its entries when asked,
-- from the row data the grid was drawn from.
--
-- In a group of bouts, every list is the bout's the cell was in: "All Players"
-- means everyone in that fight, not everyone in every one of them.
local function Options(data, col)
    local columns = ns.Model:Columns()
    local measure = columns[col] or ("Column " .. col)
    local options = {}
    local section = data and data.section
    local players = (section and section.players) or ns.Model:Players()

    options[#options + 1] = {
        label = "All Players",
        title = measure,
        entries = function()
            local out = {}
            for _, player in ipairs(players) do
                local value = (player.unit and player.unit.cols and player.unit.cols[col]) or 0
                if value > 0 then out[#out + 1] = { name = player.name, v = value } end
            end
            table.sort(out, function(a, b) return a.v > b.v end)
            return out
        end,
    }

    if not data then return options end
    local root = data.root

    -- The player's own breakdown in this measure: their counterparts, without
    -- the spell totals line, which is the player's whole and not one of them.
    -- A blank row past the end of the active column's list still shows the
    -- other columns' entries at its rank, so it is part of the breakdown too.
    local lists = ((data.kind == "source" or data.kind == "note") and data.lists)
               or (data.kind == "spell" and data.parentLists) or nil
    if root and lists and lists[col] then
        local parts = lists[col]
        options[#options + 1] = {
            label = ("By %s"):format(Who(root)),
            title = ("%s's %s"):format(Who(root), measure),
            entries = function()
                local out = {}
                for _, part in ipairs(parts) do
                    if not part.summary and (part.v or 0) > 0 then
                        out[#out + 1] = { name = part.name, v = part.v }
                    end
                end
                return out
            end,
        }
    end

    -- The spells behind one counterpart, or behind the player's spell totals.
    if data.kind == "spell" and root and data.lists and data.lists[col] then
        local spells = data.lists[col]
        local label, title
        if data.summary then
            label = ("By %s - %s"):format(Who(root), ns.SPELL_TOTALS)
            title = ("%s's %s by spell"):format(Who(root), measure)
        else
            label = ("By %s To %s"):format(Who(root), Who(data.source))
            title = ("%s's %s, %s"):format(Who(root), measure, Who(data.source))
        end
        options[#options + 1] = {
            label = label,
            title = title,
            entries = function()
                local out = {}
                for _, use in ipairs(spells) do
                    if (use.v or 0) > 0 then out[#out + 1] = { name = use.name, v = use.v } end
                end
                return out
            end,
        }
    end

    -- Where the figures are from, for the heading: the session, and in a group
    -- which bout of it.
    local session = ns.Model:Entry()
    local where = (session and session.mapName) and (" - " .. session.mapName) or ""
    local bout = section and section.entry
    if bout and bout.startTime then
        where = ("%s (%s)"):format(where, date("%H:%M:%S", bout.startTime))
    end
    for _, option in ipairs(options) do option.where = where end

    return options
end

-- A heading naming the measure and the match, then the entries ranked, each with
-- its share of the whole list - of everything in it, not only what is sent, so a
-- top three reads as part of the total it came from.
local function Lines(option, col, count)
    local entries = option.entries()
    local total = 0
    for _, entry in ipairs(entries) do total = total + entry.v end

    local out = { ("CombatSession: %s%s"):format(option.title, option.where or "") }

    local limit = #entries
    if count and count > 0 and count < limit then limit = count end
    for i = 1, limit do
        local entry = entries[i]
        local share = ""
        if total > 0 then share = (" (%.1f%%)"):format(100 * entry.v / total) end
        out[#out + 1] = ("%d. %s %s%s"):format(i, Who(entry.name), Amount(col, entry.v), share)
    end
    if #entries == 0 then out[#out + 1] = "Nothing recorded." end
    return out
end

-- Party and raid inside a battleground or a solo queue are the instance group,
-- which has a channel of its own; the home party's would go nowhere. The same
-- routing Details! uses.
local function Destination(key)
    if (key == "PARTY" or key == "RAID") and LE_PARTY_CATEGORY_INSTANCE and GetNumGroupMembers
       and (GetNumGroupMembers(LE_PARTY_CATEGORY_INSTANCE) or 0) > 0 then
        return "INSTANCE_CHAT"
    end
    return key
end

local function SendLine(text, channel, target)
    local fn = SendChatMessage or (C_ChatInfo and C_ChatInfo.SendChatMessage)
    if type(fn) ~= "function" then return false, "this client has no way to send chat" end
    return pcall(fn, text, channel, nil, target)
end

local function Say(text)
    if ns.Print then ns:Print(text) else print(text) end
end

--------------------------------------------------------------------------------
-- Whisper names
--
-- The whisper box finishes a name as it is typed, the way the game's own whisper
-- and mail boxes do: the rest of the first name that fits is filled in and
-- selected, so typing on replaces it, Tab takes it, and Enter sends to it. Done
-- here rather than through the game's AutoComplete template, whose functions are
-- interface code this addon cannot see to rely on - and which knows nothing of
-- the people in the session being reported, the likeliest ones to whisper.
--------------------------------------------------------------------------------

-- Names to finish with, likeliest first: the players in what is being reported,
-- the group, friends, the guild. Each as a whisper takes it - the realm kept,
-- since a whisper across realms needs it, and the region the log adds dropped.
-- A name the game is withholding is skipped rather than compared.
local function WhisperNames()
    local out, seen = {}, {}
    local function Add(name)
        pcall(function()
            if type(name) ~= "string" or name == "" then return end
            name = ns.ShortName(name)
            local key = name:lower()
            if seen[key] then return end
            seen[key] = true
            out[#out + 1] = name
        end)
    end

    for _, player in ipairs(current.players or {}) do Add(player.name) end

    local count = GetNumGroupMembers and GetNumGroupMembers() or 0
    local unit = (IsInRaid and IsInRaid()) and "raid" or "party"
    for i = 1, count do
        if GetUnitName then Add(GetUnitName(unit .. i, true)) end
    end

    local friends = C_FriendList
    if friends and friends.GetNumFriends and friends.GetFriendInfoByIndex then
        for i = 1, friends.GetNumFriends() or 0 do
            local info = friends.GetFriendInfoByIndex(i)
            Add(info and info.name)
        end
    end

    if IsInGuild and IsInGuild() and GetNumGuildMembers and GetGuildRosterInfo then
        for i = 1, GetNumGuildMembers() or 0 do Add((GetGuildRosterInfo(i))) end
    end
    return out
end

-- Fills in the rest of the first name that starts with what has been typed, and
-- selects it. Only while typing forward at the end of the text: after a deletion
-- it would put back what was just removed, and mid-text it would overwrite what
-- follows the cursor.
local function CompleteName(box, userInput)
    local text = box:GetText() or ""
    local grew = #text > (box.typed or 0)
    box.typed = #text
    if not (userInput and grew) or text == "" then return end
    if box:GetCursorPosition() ~= #text then return end

    local lower = text:lower()
    for _, name in ipairs(WhisperNames()) do
        if #name > #text and name:sub(1, #text):lower() == lower then
            -- Written as the name is spelled, whatever case was typed.
            box:SetText(name)
            box:HighlightText(#text, #name)
            box:SetCursorPosition(#text)
            -- The filled-in part is not typing.
            box.typed = #text
            return
        end
    end
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function Toggle(parent, label, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width, ROW_H)
    button.bg = ns.Fill(button, ns.COLOR.header)
    button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    button.text:SetPoint("LEFT", 6, 0)
    button.text:SetPoint("RIGHT", -6, 0)
    button.text:SetWordWrap(false)
    button.text:SetText(label)

    local hover = button:CreateTexture(nil, "ARTWORK")
    hover:SetAllPoints()
    hover:SetColorTexture(1, 1, 1, 0.08)
    hover:Hide()
    button:SetScript("OnEnter", function() hover:Show() end)
    button:SetScript("OnLeave", function() hover:Hide() end)

    function button:SetChosen(on)
        local c = on and ns.COLOR.selected or ns.COLOR.header
        self.bg:SetColorTexture(c[1], c[2], c[3], 1)
        if on then
            self.text:SetTextColor(ns.COLOR.active[1], ns.COLOR.active[2], ns.COLOR.active[3])
        else
            self.text:SetTextColor(0.75, 0.75, 0.75)
        end
    end
    return button
end

local function Label(parent, text)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetText(text)
    return label
end

-- Everything below the title is laid out top to bottom from here, because the
-- number of data options changes with where the window was opened from.
local function Layout()
    local y = -(TITLE_H + GAP)
    local function Place(region, height, x)
        region:ClearAllPoints()
        region:SetPoint("TOPLEFT", frame, "TOPLEFT", x or PAD, y)
        y = y - height
    end

    Place(frame.toLabel, 14); y = y - 2
    local each = (WIDTH - PAD * 2 - 3 * 3) / 4
    for i, button in ipairs(frame.channels) do
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (each + 3), y)
        button:SetChosen(ns.db.reportTo == CHANNELS[i].key)
    end
    y = y - ROW_H - GAP

    if ns.db.reportTo == "WHISPER" then
        frame.whisper:Show()
        Place(frame.whisper, ROW_H + GAP, PAD + 6)
    else
        frame.whisper:Hide()
    end

    Place(frame.linesLabel, 14); y = y - 2
    for i, button in ipairs(frame.lines) do
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD + (i - 1) * (each + 3), y)
        button:SetChosen(ns.db.reportLines == LINES[i].n)
    end
    y = y - ROW_H - GAP

    Place(frame.dataLabel, 14); y = y - 2
    for i, button in ipairs(frame.data) do
        local option = current.options[i]
        if option then
            button.text:SetText(option.label)
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, y)
            button:SetChosen(current.choice == i)
            button:Show()
            y = y - ROW_H - 3
        else
            button:Hide()
        end
    end
    y = y - GAP

    -- What will be sent, exactly as it will be sent.
    Place(frame.previewLabel, 14); y = y - 2
    local option = current.options[current.choice]
    local lines = option and Lines(option, current.col, ns.db.reportLines) or {}
    local shown = {}
    for i = 1, math.min(#lines, PREVIEW_LINES) do shown[i] = lines[i] end
    if #lines > PREVIEW_LINES then
        shown[#shown + 1] = ("|cff888888... and %d more|r"):format(#lines - PREVIEW_LINES)
    end
    frame.preview:SetText(table.concat(shown, "\n"))
    local previewH = math.max(14, frame.preview:GetStringHeight())
    Place(frame.preview, previewH + GAP)

    Place(frame.status, 14)
    y = y - GAP
    frame.send:ClearAllPoints()
    frame.send:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -PAD, y)
    frame.cancel:ClearAllPoints()
    frame.cancel:SetPoint("RIGHT", frame.send, "LEFT", -6, 0)
    y = y - 22 - PAD

    frame:SetHeight(-y)
end

local function SendReport()
    local option = current.options[current.choice]
    if not option then return end

    local key = ns.db.reportTo
    local channel = Destination(key)
    local target
    if key == "WHISPER" then
        target = strtrim(frame.whisper:GetText() or "")
        if target == "" then
            frame.status:SetText("|cffff6666Who should the whisper go to?|r")
            return
        end
        ns.db.reportWhisper = target
    end

    local lines = Lines(option, current.col, ns.db.reportLines)

    -- Say outside an instance needs the click itself behind every line, so those
    -- go now. Everything else is spaced out like Details! does, under the chat
    -- flood limit; a refusal then arrives late and is reported in chat instead.
    if key == "SAY" then
        for _, line in ipairs(lines) do
            local ok, err = SendLine(line, channel, target)
            if not ok then
                frame.status:SetText(("|cffff6666Not sent: %s|r"):format(tostring(err)))
                return
            end
        end
    else
        for i, line in ipairs(lines) do
            C_Timer.After((i - 1) * 0.2, function()
                local ok, err = SendLine(line, channel, target)
                if not ok and i == 1 then Say(("Report not sent: %s"):format(tostring(err))) end
            end)
        end
    end
    frame:Hide()
end

local function Build()
    frame = CreateFrame("Frame", "CombatSessionReportFrame", UIParent)
    frame:SetWidth(WIDTH)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetToplevel(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    ns.Fill(frame, { 0.03, 0.03, 0.04, 0.96 })
    ns.Border(frame, ns.COLOR.line)
    -- Escape closes it, like any other dialog.
    if UISpecialFrames then table.insert(UISpecialFrames, "CombatSessionReportFrame") end

    local bar = CreateFrame("Frame", nil, frame)
    bar:SetPoint("TOPLEFT", 1, -1)
    bar:SetPoint("TOPRIGHT", -1, -1)
    bar:SetHeight(TITLE_H)
    bar:EnableMouse(true)
    bar:RegisterForDrag("LeftButton")
    ns.Fill(bar, ns.COLOR.header)
    bar:SetScript("OnDragStart", function() frame:StartMoving() end)
    bar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)
    frame.title = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.title:SetPoint("LEFT", PAD, 0)
    frame.title:SetPoint("RIGHT", -28, 0)
    frame.title:SetJustifyH("LEFT")
    frame.title:SetWordWrap(false)

    local close = CreateFrame("Button", nil, bar, "UIPanelCloseButton")
    close:SetPoint("RIGHT", 2, 0)
    close:SetSize(22, 22)
    close:SetScript("OnClick", function() frame:Hide() end)

    frame.toLabel = Label(frame, "Report to")
    local each = (WIDTH - PAD * 2 - 3 * 3) / 4
    frame.channels = {}
    for i, channel in ipairs(CHANNELS) do
        local button = Toggle(frame, channel.label, each)
        button:SetScript("OnClick", function()
            ns.db.reportTo = channel.key
            frame.status:SetText("")
            Layout()
        end)
        frame.channels[i] = button
    end

    frame.whisper = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    frame.whisper:SetSize(WIDTH - PAD * 2 - 12, ROW_H)
    frame.whisper:SetAutoFocus(false)
    frame.whisper:SetScript("OnEnterPressed", function(self) self:ClearFocus(); SendReport() end)
    frame.whisper:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame.whisper:SetScript("OnTextChanged", CompleteName)
    -- Tab takes the name that was filled in.
    frame.whisper:SetScript("OnTabPressed", function(self)
        local text = self:GetText() or ""
        self:HighlightText(#text, #text)
        self:SetCursorPosition(#text)
        self.typed = #text
    end)

    frame.linesLabel = Label(frame, "Lines")
    frame.lines = {}
    for i, choice in ipairs(LINES) do
        local button = Toggle(frame, choice.label, each)
        button:SetScript("OnClick", function()
            ns.db.reportLines = choice.n
            Layout()
        end)
        frame.lines[i] = button
    end

    frame.dataLabel = Label(frame, "Data")
    frame.data = {}
    for i = 1, 3 do
        local button = Toggle(frame, "", WIDTH - PAD * 2)
        button:SetScript("OnClick", function()
            current.choice = i
            Layout()
        end)
        frame.data[i] = button
    end

    frame.previewLabel = Label(frame, "Preview")
    frame.preview = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.preview:SetWidth(WIDTH - PAD * 2)
    frame.preview:SetJustifyH("LEFT")
    frame.preview:SetJustifyV("TOP")

    frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    frame.status:SetWidth(WIDTH - PAD * 2)
    frame.status:SetJustifyH("LEFT")

    frame.send = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.send:SetSize(90, 22)
    frame.send:SetText("Send")
    frame.send:SetScript("OnClick", SendReport)

    frame.cancel = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    frame.cancel:SetSize(90, 22)
    frame.cancel:SetText("Cancel")
    frame.cancel:SetScript("OnClick", function() frame:Hide() end)

    frame:Hide()
end

-- Opens the window for one cell: `data` is the row the cell belongs to, `col`
-- the measure it was in.
function Report:Open(data, col)
    if not frame then Build() end
    current.col = col
    current.options = Options(data, col)
    -- The people the whisper box offers first: whoever is in what is reported.
    current.players = (data and data.section and data.section.players) or ns.Model:Players()
    -- Always every player to begin with, wherever the window was opened from;
    -- the breakdowns the cell sits inside are a click away beneath it.
    current.choice = 1

    local columns = ns.Model:Columns()
    frame.title:SetText(("Report: %s"):format(columns[col] or ("Column " .. col)))
    frame.whisper:SetText(ns.db.reportWhisper or "")
    frame.status:SetText("")
    frame:Show()
    frame:Raise()
    Layout()
end

-- The cell's own right-click menu.
function Report:CellMenu(owner, data, col)
    local columns = ns.Model:Columns()
    local measure = columns[col] or ("Column " .. col)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        self:Open(data, col)
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(measure)
        root:CreateButton(("Report %s..."):format(measure), function() Report:Open(data, col) end)
    end)
end
