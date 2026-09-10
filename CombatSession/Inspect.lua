-- CombatSession :: Inspect
--
-- Tree viewer over the data API. Deliberately a thin shell: everything it shows
-- comes from CombatSessionAPI, so an alternative viewer can replace this file
-- without touching anything else.
--
-- Hierarchy:
--   Date/Time, Session Name, Character
--     Team N (Faction) Win/Lose
--       Total Damage / Total Healing
--       Roster (count)
--         Player  Damage  Healing
--           Column  Total
--             Counterpart  Value  (count)
--               Spell  Value  (count)
--     Not on scoreboard (n)
--     Events
--       Significant event
--         Actions leading to it
--
-- Team membership comes from the recorder's scoreboard when there is one, and
-- from unit reaction flags only as a fallback. The scoreboard is authoritative
-- because the log is not: enabling combat logging dumps the auras of every
-- visible unit, so a session picks up bystanders, and reaction is relative to
-- the logging character rather than to the two sides.
--
-- Units are addressed by name throughout, matching how the data library keys
-- them. Pet output is already folded into its owner during aggregation, so
-- nothing here walks a parent chain.

local ADDON, ns = ...

local API = ns.API
local UI = {}
ns.UI = UI

local ROW_HEIGHT = 16
local VISIBLE_ROWS = 24

local frame          -- main window, built lazily on first open
local rows = {}      -- reusable row buttons
local tree = {}      -- flattened visible nodes
local expanded = {}  -- [nodeId] = true

local COL_DAMAGE_DONE  = 1
local COL_HEALING_DONE = 3

--------------------------------------------------------------------------------

local function Commas(n)
    n = math.floor(tonumber(n) or 0)
    local text = tostring(n)
    local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

local function Short(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return ("%.1fm"):format(n / 1000000) end
    if n >= 1000 then return ("%.0fk"):format(n / 1000) end
    return tostring(math.floor(n))
end

-- "Name-Realm" and a scoreboard's "Name" should match each other.
local function BaseName(name)
    return (tostring(name or ""):match("^([^-]+)") or tostring(name or ""))
end

-- Time columns hold milliseconds; everything else holds an amount.
local function FormatValue(cache, col, value, count)
    if ns.COLUMN_IS_TIME[col] then
        return ("%.1fs |cff888888x%d|r"):format((value or 0) / 1000, count or 0)
    end
    if count and count > 1 then
        return ("%s |cff888888(%d)|r"):format(Commas(value), count)
    end
    return Commas(value)
end

local function SessionLabel(entry)
    local y, mo, d, h, mi = entry.key:match("^(%d%d%d%d)(%d%d)(%d%d)_(%d%d)(%d%d)")
    local stamp = y and ("%s-%s-%s %s:%s"):format(y, mo, d, h, mi) or entry.key

    local name = entry.mapName
    if not name or name == "" then name = entry.type or "session" end

    -- "Rated Solo Shuffle" already says rated; do not say it twice.
    local bracket = entry.bracket
    local rated = entry.rated and "|cffffcc00Rated|r" or "|cff888888Unrated|r"
    if bracket and bracket:find("Rated") then rated = "|cffffcc00Rated|r" end

    local suffix = ""
    if bracket and bracket ~= "" then
        suffix = " |cff888888" .. bracket:gsub("^Rated ", "") .. "|r"
    end
    if (entry.round or 0) > 0 then
        suffix = suffix .. (" |cff888888R%d|r"):format(entry.round)
    end

    -- Several characters share one account-wide store, so whose session this is
    -- belongs on the row rather than buried inside it.
    local who = ""
    if entry.character and entry.character ~= "" then
        who = " |cff88bb88" .. BaseName(entry.character) .. "|r"
    end

    return ("%s  %s %s%s%s  |cff666666%s events, %s units|r%s")
        :format(stamp, rated, name, suffix, who,
                Commas(entry.events), Commas(entry.units),
                entry.truncated and "  |cffff5555truncated|r" or "")
end

--------------------------------------------------------------------------------
-- Tree construction
--------------------------------------------------------------------------------

local function AddNode(depth, id, text, onClick)
    tree[#tree + 1] = { depth = depth, id = id, text = text, onClick = onClick }
end

local function Toggler(id)
    return function()
        expanded[id] = not expanded[id]
        UI:Refresh()
    end
end

-- Enabling combat logging makes the client dump the existing auras of every
-- visible unit, so queueing in a city sweeps up bystanders who never act. They
-- have no damage, healing, casts or deaths, which is what separates them from
-- a participant who happened to be quiet.
local function HasActivity(unit)
    if not unit then return false end
    for i = 1, #unit.cols do
        if (unit.cols[i] or 0) ~= 0 then return true end
    end
    return false
end

local function Damage(unit)  return unit and unit.cols[COL_DAMAGE_DONE] or 0 end
local function Healing(unit) return unit and unit.cols[COL_HEALING_DONE] or 0 end

-- Per-column drill-down: the counterparts that make up one total, largest
-- first. Which side is listed depends on the column - who this unit acted on,
-- or who acted on it.
local function BuildColumnRows(cache, unit, playerId, depth)
    -- `unit` is an expanded entry from API:UnitList, so it carries a name and a
    -- resolved kind; the stored form holds neither.
    -- Every column is listed, including zeros. Hiding empty ones made the list
    -- look truncated and left no way to tell "nothing happened" apart from
    -- "not tracked".
    for col = 1, #cache.FORMAT.columns do
        local value = unit.cols[col] or 0
        local count = unit.counts and unit.counts[col] or 0
        local colId = playerId .. ":c" .. col
        local parts, omitted = API:Breakdown(cache, unit.index, col)
        local hasBreakdown = #parts > 0

        local suffix = ""
        if hasBreakdown then
            suffix = expanded[colId] and " |cff666666v|r" or " |cff666666>|r"
        elseif value ~= 0 then
            -- Overhealing names no counterpart; anything else with a total but
            -- no breakdown had only itself or an unnamed source involved.
            suffix = " |cff555555-|r"
        end

        AddNode(depth, colId,
            ("|cff%s%-16s|r %s%s")
                :format(value ~= 0 and "999999" or "555555",
                        cache.FORMAT.columns[col],
                        FormatValue(cache, col, value, count), suffix),
            hasBreakdown and Toggler(colId) or nil)

        if hasBreakdown and expanded[colId] then
            -- API:Breakdown already resolved names, attached spells and sorted
            -- both levels by contribution.
            for i, part in ipairs(parts) do
                local otherId = colId .. ":" .. i
                local hasSpells = part.spells ~= nil and #part.spells > 0

                AddNode(depth + 1, otherId,
                    ("|cff777777%-22s|r %s%s")
                        :format(part.name,
                                FormatValue(cache, col, part.v, part.n),
                                hasSpells and (expanded[otherId] and " |cff555555v|r"
                                                                 or " |cff555555>|r") or ""),
                    hasSpells and Toggler(otherId) or nil)

                if hasSpells and expanded[otherId] then
                    for u, use in ipairs(part.spells) do
                        AddNode(depth + 2, otherId .. ":s" .. u,
                            ("|cff666666%-24s|r %s")
                                :format(use.name,
                                        FormatValue(cache, col, use.v, use.n)))
                    end
                end
            end

            -- The totals are exact; only the itemisation is capped, so say so
            -- rather than let a trimmed list read as complete.
            if omitted then
                AddNode(depth + 1, colId .. ":more",
                    ("|cff555555... %d smaller contributor(s) not stored|r")
                        :format(omitted))
            end
        end
    end
end

local function BuildTeamRows(entry, cache, match, nodeId, depth)
    local teams = {
        { label = "Team 1", members = {} },
        { label = "Team 2", members = {} },
    }

    -- UNITS is already keyed by name, so scoreboard entries join directly. A
    -- scoreboard omits the realm for players on your own realm, hence matching
    -- on the base name.
    --
    -- Every unit is indexed, not just player-flagged ones: if a name is on the
    -- scoreboard then it played, and refusing to join because our flag
    -- classification disagreed is how a whole team ended up reading zero.
    -- Player-flagged units still win any base-name collision.
    -- The stored cache holds interned names and flags; API:UnitList turns that
    -- back into named entries with kind and reaction resolved.
    local units, byName = API:UnitList(cache), {}
    for _, unit in ipairs(units) do byName[unit.name] = unit end

    local byBase = {}
    for _, unit in ipairs(units) do
        local base = BaseName(unit.name)
        if not byBase[base] or unit.kind == "player" then
            byBase[base] = unit.name
        end
    end

    local haveRoster = match and match.roster and #match.roster > 0
    local claimed = {}

    if haveRoster then
        -- The scoreboard decides who played; log data only supplies numbers.
        -- Reaction flags cannot do this job: a rated Eye of the Storm whose
        -- scoreboard listed 20 players produced 38 player units in the log,
        -- and neither raw flags nor an activity filter reproduced the 10/10.
        local own = match.playerFaction
        for _, player in ipairs(match.roster) do
            local side = 1
            if own ~= nil and player.faction ~= nil then
                side = (player.faction == own) and 1 or 2
            end
            local unitName = byBase[BaseName(player.name)]
            if unitName then claimed[unitName] = true end
            table.insert(teams[side].members, { player = player, unit = unitName })
        end
    else
        -- No recorder data, so fall back to reaction flags. Activity is
        -- required here, since nothing else keeps the aura burst out.
        for _, unit in ipairs(units) do
            if unit.kind == "player" and HasActivity(unit) then
                local side = (unit.reaction == "friendly") and 1
                          or (unit.reaction == "hostile") and 2 or nil
                if side then table.insert(teams[side].members, { unit = unit.name }) end
            end
        end
    end

    -- Fought but absent from the scoreboard: left early or backfilled out.
    -- Listed apart rather than folded into a team, so team counts stay true.
    local strays = {}
    if haveRoster then
        for _, unit in ipairs(units) do
            if unit.kind == "player" and not claimed[unit.name] and HasActivity(unit) then
                strays[#strays + 1] = unit.name
            end
        end
        table.sort(strays, function(a, b)
            return Damage(byName[a]) > Damage(byName[b])
        end)
    end

    for teamIndex, team in ipairs(teams) do
        if #team.members > 0 then
            local damage, healing = 0, 0
            for _, member in ipairs(team.members) do
                local unit = member.unit and byName[member.unit]
                damage  = damage + Damage(unit)
                healing = healing + Healing(unit)
            end

            -- Faction and outcome are only knowable from the recorder.
            local faction, outcome = "", ""
            if match then
                local own = match.playerFaction
                if own ~= nil then
                    local side = (teamIndex == 1) and own or (own == 0 and 1 or 0)
                    -- GetBattlefieldArenaFaction returns 0/1. In a battleground
                    -- those are Horde and Alliance; in an arena they are just
                    -- the two teams, so naming them after factions is wrong.
                    if entry.type == "battleground" then
                        faction = (side == 0) and " |cffdd4444Horde|r"
                                              or " |cff5599ffAlliance|r"
                    end
                    if match.winner ~= nil and match.winner >= 0 then
                        outcome = (match.winner == side)
                            and "  |cff66ff66Win|r" or "  |cffff6666Lose|r"
                    end
                end
            end

            local teamId = nodeId .. ":team" .. teamIndex
            AddNode(depth, teamId,
                ("%s%s%s  |cff888888dmg %s  heal %s|r")
                    :format(team.label, faction, outcome, Short(damage), Short(healing)),
                Toggler(teamId))

            if expanded[teamId] then
                AddNode(depth + 1, teamId .. ":dmg",
                    ("|cff999999Total Damage|r   %s"):format(Commas(damage)))
                AddNode(depth + 1, teamId .. ":heal",
                    ("|cff999999Total Healing|r  %s"):format(Commas(healing)))

                local rosterId = teamId .. ":roster"
                AddNode(depth + 1, rosterId,
                    ("|cff99ccffRoster|r |cff888888(%d)|r"):format(#team.members),
                    Toggler(rosterId))

                if expanded[rosterId] then
                    local order = {}
                    for _, member in ipairs(team.members) do order[#order + 1] = member end
                    table.sort(order, function(a, b)
                        return Damage(a.unit and byName[a.unit])
                             > Damage(b.unit and byName[b.unit])
                    end)

                    for n, member in ipairs(order) do
                        local unit = member.unit and byName[member.unit]
                        local player = member.player
                        local name = (player and player.name) or member.unit or "?"
                        local class = player and player.class or nil
                        local playerId = rosterId .. ":" .. n

                        -- On the scoreboard but never seen in the log: joined
                        -- late, or acted entirely out of logging range.
                        local note = (not unit) and " |cff886644(no log data)|r" or ""

                        AddNode(depth + 2, playerId,
                            ("%-24s %-12s |cff888888dmg|r %-8s |cff888888heal|r %s%s")
                                :format(name,
                                        class and ("|cff999999" .. class .. "|r") or "",
                                        Short(Damage(unit)), Short(Healing(unit)), note),
                            unit and Toggler(playerId) or nil)

                        if unit and expanded[playerId] then
                            BuildColumnRows(cache, unit, playerId, depth + 3)
                        end
                    end
                end
            end
        end
    end

    if #strays > 0 then
        local strayId = nodeId .. ":strays"
        AddNode(depth, strayId,
            ("|cff886644Not on scoreboard|r |cff888888(%d)|r"):format(#strays),
            Toggler(strayId))
        if expanded[strayId] then
            for n, name in ipairs(strays) do
                local unit = byName[name]
                local strayPlayerId = strayId .. ":" .. n
                AddNode(depth + 1, strayPlayerId,
                    ("%-24s |cff888888dmg|r %-8s |cff888888heal|r %s")
                        :format(name, Short(Damage(unit)), Short(Healing(unit))),
                    Toggler(strayPlayerId))
                if expanded[strayPlayerId] then
                    BuildColumnRows(cache, unit, strayPlayerId, depth + 2)
                end
            end
        end
    end
end

local function BuildEventRows(cache, nodeId, depth)
    -- Expanded from the stored flat runs; the cache holds name indices and six
    -- numbers per action, not tables.
    local events = API:EventList(cache)

    local id = nodeId .. ":events"
    AddNode(depth, id,
        ("|cffffcc99Events|r |cff888888(%d)|r"):format(#events),
        Toggler(id))
    if not expanded[id] then return end

    if #events == 0 then
        AddNode(depth + 1, id .. ":none", "|cff666666no significant events|r")
        return
    end

    for i, event in ipairs(events) do
        local eventId = id .. ":" .. i
        AddNode(depth + 1, eventId,
            ("|cffff8888death|r %-22s |cff888888%.1fs  %d action(s)|r")
                :format(tostring(event.unit), (event.t or 0) / 1000,
                        event.context and #event.context or 0),
            Toggler(eventId))

        if expanded[eventId] then
            if not event.context or #event.context == 0 then
                AddNode(depth + 2, eventId .. ":none",
                    "|cff666666nothing recorded in the preceding window|r")
            end
            for n, action in ipairs(event.context or {}) do
                local colour = action.category == "cc" and "ffffcc00"
                            or action.category == "defensive" and "ff66ccff"
                            or action.category == "immunity" and "ffccffff"
                            or action.category == "dispel" and "ffff99ff"
                            or action.category == "interrupt" and "ffff9966"
                            or "ffaaaaaa"
                AddNode(depth + 2, eventId .. ":a" .. n,
                    ("|cff888888%+.1fs|r |c%s%s|r %s%s")
                        :format(action.t / 1000, colour, action.name or "?",
                                action.src and ("|cff777777" .. action.src .. "|r") or "",
                                (action.amount or 0) ~= 0
                                    and ("  " .. Commas(action.amount)) or ""))
            end
        end
    end
end

-- Shown for a queued session whose cache is not built yet, which now only
-- happens while the login pass is still working through a backlog.
--
-- Not actionable, deliberately. Sessions are consumed at login, not on demand,
-- and a row that offered to parse one would be doing work the addon has already
-- declined: the application would see the new key, collect the chunk, and the
-- next login's prune would discard the cache it had just paid for.
local QUEUED_TEXT = "|cff775555queued - built at the next login or |r|cffffcc00/reload|r"

local function BuildTree()
    wipe(tree)

    local sessions = API:GetViewable()
    if #sessions == 0 then
        AddNode(0, "empty",
            "|cffff8888No session data.|r Run the CombatSession application, then /reload.")
        return
    end

    -- Nested rather than early-continue: WoW runs Lua 5.1, which has no goto.
    for i = #sessions, 1, -1 do   -- newest first
        local entry = sessions[i]
        local nodeId = "s:" .. entry.key

        AddNode(0, nodeId, SessionLabel(entry), Toggler(nodeId))

        if expanded[nodeId] then
            local cache = API:GetCache(entry.key)
            if cache then
                local match = API:GetMatch(entry)
                BuildTeamRows(entry, cache, match, nodeId, 1)
                -- Abandonment is a property of the match, not of either side,
                -- so it is stated once rather than stamped on both teams.
                if match and match.abandoned then
                    AddNode(1, nodeId .. ":abandoned",
                        "|cffff8855match abandoned - no result recorded|r")
                end
                if not match then
                    AddNode(1, nodeId .. ":nomatch",
                        "|cff775555no recorder data - faction and result unavailable|r")
                end
                BuildEventRows(cache, nodeId, 1)
            else
                AddNode(1, nodeId .. ":unavailable", QUEUED_TEXT)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Rendering
--------------------------------------------------------------------------------

function UI:Refresh()
    if not frame or not frame:IsShown() then return end
    BuildTree()

    local offset = FauxScrollFrame_GetOffset(frame.scroll) or 0
    FauxScrollFrame_Update(frame.scroll, #tree, VISIBLE_ROWS, ROW_HEIGHT)

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local node = tree[i + offset]
        if node then
            row.node = node
            row.label:SetText(("%s%s"):format(string.rep("   ", node.depth), node.text))
            row:Show()
        else
            row.node = nil
            row:Hide()
        end
    end
end

local function CreateWindow()
    frame = CreateFrame("Frame", "CombatSessionInspectFrame", UIParent,
                        "BasicFrameTemplateWithInset")
    frame:SetSize(820, VISIBLE_ROWS * ROW_HEIGHT + 60)
    frame:SetPoint("CENTER")
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:SetFrameStrata("DIALOG")
    frame.TitleText:SetText("CombatSession")
    tinsert(UISpecialFrames, "CombatSessionInspectFrame")   -- Escape closes it

    frame.scroll = CreateFrame("ScrollFrame", "CombatSessionInspectScroll", frame,
                               "FauxScrollFrameTemplate")
    frame.scroll:SetPoint("TOPLEFT", 12, -32)
    frame.scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    frame.scroll:SetScript("OnVerticalScroll", function(self, delta)
        FauxScrollFrame_OnVerticalScroll(self, delta, ROW_HEIGHT, function() UI:Refresh() end)
    end)

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, frame)
        row:SetSize(760, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 14, -30 - (i - 1) * ROW_HEIGHT)

        row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.label:SetPoint("LEFT")
        row.label:SetJustifyH("LEFT")

        row:SetScript("OnClick", function(self)
            if self.node and self.node.onClick then self.node.onClick() end
        end)
        row:SetScript("OnEnter", function(self) self.label:SetAlpha(0.7) end)
        row:SetScript("OnLeave", function(self) self.label:SetAlpha(1) end)

        rows[i] = row
    end

    -- CreateFrame returns a shown frame. Without this the first Toggle sees a
    -- visible window and hides it, so the command has to be typed twice.
    frame:Hide()
end

function UI:Toggle()
    if not frame then CreateWindow() end
    if frame:IsShown() then
        frame:Hide()
    else
        frame:Show()
        self:Refresh()
    end
end
