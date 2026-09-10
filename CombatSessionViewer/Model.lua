-- CombatSessionViewer :: Model
--
-- Turns a session's cache into the flat list of rows the window draws, and owns
-- what is expanded.
--
-- Flattening rather than nesting is what makes the grid scroll smoothly: the
-- window keeps a small pool of row frames and maps them onto a slice of this
-- array, so the cost of drawing is bounded by the height of the window rather
-- than by the size of the session.

local ADDON, ns = ...

local Model = {}
ns.Model = Model

local SPELL_TOTALS = "Spell Totals"
ns.SPELL_TOTALS = SPELL_TOTALS

local function BaseName(name)
    return (tostring(name or ""):match("^([^-]+)") or tostring(name or ""))
end

-- Only ever one root unit and one counterpart open at a time. That is a
-- deliberate constraint rather than a simplification: with eleven columns and
-- twenty-five counterparts each, free-form expansion buries the grid, and the
-- comparison between units - the reason for a grid at all - is lost.
local state = {
    key          = nil,   -- selected session
    entry        = nil,   -- its index/cache header
    cache        = nil,
    match        = nil,   -- recorder record, may be nil
    players      = nil,
    teams        = nil,

    activeName   = nil,   -- expanded unit, by player name
    activeCol    = nil,   -- which column of it is open
    activeSource = nil,   -- expanded counterpart within that column

    sortCol      = 1,
    sortAsc      = false,
}

ns.state = state

--------------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------------

-- Newest first, which is the order the list is read in: the match just played
-- is the one being looked at.
function Model:Sessions()
    local api = ns:API()
    if not api then return {} end

    local list = api:GetViewable()
    table.sort(list, function(a, b) return a.key > b.key end)
    return list
end

function Model:SessionLabel(entry)
    local name = entry.mapName or "Unknown"
    if entry.rated then name = "|cffffd100Rated|r " .. name end
    if entry.round and entry.round > 0 then
        name = ("%s  |cff888888round %d|r"):format(name, entry.round)
    end

    local who = ns.ShortName(entry.character or "")
    local mark = self:OutcomeMark(entry)
    if mark then who = who .. "  " .. mark end

    return name, ns.FormatTime(entry.startTime), who
end

-- (W), (L) or (D) for the recording player, or nil when the match never
-- completed - abandoned, or played before the recorder existed.
--
-- Deliberately routed through API:Roster rather than comparing winner against
-- the recorded playerFaction directly, so the list and the grid can never
-- disagree about who won: the faction numbering the scoreboard reports for you
-- is not reliable, and Roster derives it from the log instead.
--
-- Cached per session, and only ever asked for the handful of rows on screen.
function Model:OutcomeMark(entry)
    state.outcomes = state.outcomes or {}
    local hit = state.outcomes[entry.key]
    if hit ~= nil then return hit or nil end

    local api = ns:API()
    local cache = api and api:GetCache(entry.key)
    local match = api and api:GetMatch(entry)

    local mark = false
    if cache and match then
        local _, teams = api:Roster(entry, cache, match)
        if teams[1].won ~= nil or teams[2].won ~= nil then
            if teams[1].won == false and teams[2].won == false then
                mark = "|cffcccc66(D)|r"
            elseif teams[1].won then
                mark = "|cff66ff66(W)|r"
            else
                mark = "|cffff6666(L)|r"
            end
        end
    end

    state.outcomes[entry.key] = mark
    return mark or nil
end

function Model:Select(key)
    if state.key == key then return end

    state.key          = key
    state.activeName   = nil
    state.activeCol    = nil
    state.activeSource = nil
    state.entry        = nil
    state.cache        = nil
    state.match        = nil
    state.players      = nil
    state.teams        = nil
    state.outcomes     = nil

    local api = ns:API()
    if not (api and key) then return end

    for _, entry in ipairs(api:GetViewable()) do
        if entry.key == key then state.entry = entry break end
    end

    state.cache = api:GetCache(key)
    if not (state.entry and state.cache) then return end

    state.match = api:GetMatch(state.entry)
    state.players, state.teams = api:Roster(state.entry, state.cache, state.match)

    -- A breakdown names counterparts as strings, so the only way back to a
    -- class is the scoreboard. Both the full and the base name are indexed: the
    -- scoreboard drops the realm for your own realm's players, while the log
    -- keeps it, and a counterpart can arrive in either form.
    state.classByName = {}
    for _, player in ipairs(state.players) do
        if player.class then
            state.classByName[player.name] = player.class
            state.classByName[BaseName(player.name)] = player.class
            if player.unit then state.classByName[player.unit.name] = player.class end
        end
    end

    if ns.db then ns.db.lastKey = key end
end

-- Class token for a name, or nil for anything the scoreboard does not cover -
-- pets, totems, NPCs, and players who never appeared on it.
function Model:ClassOf(name)
    local map = state.classByName
    if not map then return nil end
    return map[name] or map[BaseName(name)]
end

function Model:Selected()   return state.key end
function Model:Cache()      return state.cache end
function Model:Entry()      return state.entry end
function Model:Teams()      return state.teams end

function Model:Columns()
    local cache = state.cache
    if cache and cache.FORMAT and cache.FORMAT.columns then
        return cache.FORMAT.columns
    end
    -- Falling back to the library's current list rather than to nothing keeps
    -- the header drawn while no session is chosen.
    local cs = _G.CombatSession
    return (cs and cs.FORMAT_COLUMNS) or {}
end

--------------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------------

function Model:SetSort(col)
    if state.sortCol == col then
        state.sortAsc = not state.sortAsc
    else
        state.sortCol = col
        state.sortAsc = false        -- a new column always starts largest-first
    end
    if ns.db then
        ns.db.sortCol = state.sortCol
        ns.db.sortAsc = state.sortAsc
    end
end

function Model:Sort() return state.sortCol, state.sortAsc end

-- Saved settings are read at load; the model is built before them, so the sort
-- has to be pulled across rather than assumed.
function Model:RestoreSort()
    if not ns.db then return end
    state.sortCol = ns.db.sortCol or 1
    state.sortAsc = ns.db.sortAsc or false
end

local function SortValue(row, col)
    return (row.unit and row.unit.cols and row.unit.cols[col]) or 0
end

--------------------------------------------------------------------------------
-- Expansion
--------------------------------------------------------------------------------

function Model:IsExpanded(name) return state.activeName == name end
function Model:ActiveColumn()   return state.activeCol end
function Model:ActiveSource()   return state.activeSource end

function Model:Collapse()
    state.activeName   = nil
    state.activeCol    = nil
    state.activeSource = nil
end

-- Clicking a value opens that column. Clicking the same value again closes it,
-- which is the only way a cell click can be undone without moving the mouse to
-- the name.
function Model:ToggleColumn(name, col, unit)
    if not unit then return end
    if state.activeName == name and state.activeCol == col then
        self:Collapse()
        return
    end
    state.activeName   = name
    state.activeCol    = col
    state.activeSource = nil
end

-- The root name is inert while collapsed, per the layout: there is nothing to
-- show until a column has been chosen, so a click there would either do nothing
-- visible or guess at a column on the user's behalf.
function Model:ClickName(name)
    if state.activeName == name then self:Collapse() end
end

function Model:ToggleSource(sourceName)
    if state.activeSource == sourceName then
        state.activeSource = nil
    else
        state.activeSource = sourceName
    end
end

--------------------------------------------------------------------------------
-- Row list
--------------------------------------------------------------------------------

-- Rebuilt whenever something changes rather than patched in place. A session
-- tops out at a few dozen players and one open drill-down, so this is cheap,
-- and an incrementally maintained list would be one more thing to get wrong.
-- Where the open unit's block sits in the flat list: its own row plus every
-- row revealed beneath it. Returned as an index range rather than measured from
-- the rendered rows, because the unit row can be scrolled off the top while its
-- children are still on screen, and the box has to be drawn either way.
function Model:OpenBlock()
    local range = state.openRange
    if not range then return nil end
    return range.first, range.count
end

-- The same, one level down: the open counterpart and the spells under it. Nil
-- when no counterpart is open, or when the open one turned out to have no
-- spells recorded - nothing was revealed, so nothing wants bracketing.
function Model:OpenSourceBlock()
    local range = state.sourceRange
    if not range then return nil end
    return range.first, range.count
end

function Model:Rows()
    local rows = {}
    local cache = state.cache
    state.openRange, state.sourceRange = nil, nil
    if not (cache and state.players) then return rows end

    local api = ns:API()
    local col, asc = state.sortCol, state.sortAsc

    local order = {}
    for _, player in ipairs(state.players) do order[#order + 1] = player end
    table.sort(order, function(a, b)
        local av, bv = SortValue(a, col), SortValue(b, col)
        if av == bv then return (a.name or "") < (b.name or "") end
        if asc then return av < bv end
        return av > bv
    end)

    -- Bars are scaled so the largest value in the active column fills the
    -- name cell, and every deeper level rescales against its own siblings. A
    -- single global scale would make every drill-down bar a sliver, which is
    -- the opposite of what the level is for: comparing that level's entries.
    local activeMax = 0
    for _, player in ipairs(order) do
        local value = SortValue(player, col)
        if value > activeMax then activeMax = value end
    end
    local function Fraction(value, max)
        if not max or max <= 0 then return 0 end
        return math.min(1, (value or 0) / max)
    end

    for _, player in ipairs(order) do
        rows[#rows + 1] = {
            kind     = "unit",
            name     = player.name,
            class    = player.class,
            spec     = player.player and player.player.spec or nil,
            team     = player.team,
            -- Set only for a player the scoreboard does not list. They are shown
            -- on the side their reaction implies, but marked as not counted.
            departed = (player.team == nil) and player.inferredTeam or nil,
            unit     = player.unit,
            player   = player,
            frac     = Fraction(SortValue(player, col), activeMax),
        }

        if state.activeName == player.name and state.activeCol and player.unit then
            local blockFirst = #rows
            local parts, omitted =
                api:Breakdown(cache, player.unit.index, state.activeCol)

            -- Breakdown returns both levels already sorted largest-first, so the
            -- first entry is the maximum and no second pass is needed.
            local partMax = parts[1] and parts[1].v or 0

            -- "Spell Totals" answers the question the per-counterpart lists
            -- cannot: what did this unit actually cast? The same spells summed
            -- across everyone they were used on. It leads the list because it is
            -- the whole of which the rest are parts.
            --
            -- Its own value is the unit's column total rather than the sum of
            -- the spells beneath it. The itemisation is capped, so the two can
            -- differ, and the total is the figure that is exact.
            local totals, spellOrder = {}, {}
            for _, part in ipairs(parts) do
                for _, use in ipairs(part.spells or {}) do
                    local slot = totals[use.name]
                    if not slot then
                        slot = { name = use.name, id = use.id,
                                 spellId = use.spellId, v = 0, n = 0 }
                        totals[use.name] = slot
                        spellOrder[#spellOrder + 1] = slot
                    end
                    slot.v = slot.v + (use.v or 0)
                    slot.n = slot.n + (use.n or 0)
                    -- The extremes carry across the merge: the largest hit on
                    -- anyone is still the largest hit.
                    if use.mn and (not slot.mn or use.mn < slot.mn) then
                        slot.mn = use.mn
                    end
                    if use.mx and (not slot.mx or use.mx > slot.mx) then
                        slot.mx = use.mx
                    end
                end
            end

            if #spellOrder > 0 then
                table.sort(spellOrder, function(a, b) return a.v > b.v end)
                local unit = player.unit
                table.insert(parts, 1, {
                    name    = SPELL_TOTALS,
                    v       = unit.cols[state.activeCol] or 0,
                    n       = (unit.counts and unit.counts[state.activeCol]) or 0,
                    spells  = spellOrder,
                    summary = true,
                })
            end

            for _, part in ipairs(parts) do
                local class = self:ClassOf(part.name)
                rows[#rows + 1] = {
                    kind    = "source",
                    name    = part.name,
                    part    = part,
                    col     = state.activeCol,
                    team    = player.team,
                    class   = class,
                    summary = part.summary,
                    -- The summary line is the whole, so it always fills. Scaled
                    -- against the counterparts it would simply be the longest
                    -- bar and would squash every real one beside it.
                    frac    = part.summary and 1 or Fraction(part.v, partMax),
                }

                if state.activeSource == part.name and part.spells then
                    local sourceFirst = #rows   -- the counterpart row just added
                    local spellMax = part.spells[1] and part.spells[1].v or 0
                    for _, use in ipairs(part.spells) do
                        rows[#rows + 1] = {
                            kind  = "spell",
                            name  = use.name,
                            use   = use,
                            id    = use.spellId or use.id,
                            col   = state.activeCol,
                            -- The spells belong to the counterpart, so they keep
                            -- that unit's class colour rather than the root's.
                            class = class,
                            frac  = Fraction(use.v, spellMax),
                        }
                    end

                    -- Only when something was actually revealed. A counterpart
                    -- with an empty spell list is open in name only, and
                    -- bracketing a single row would say otherwise.
                    if #rows > sourceFirst then
                        state.sourceRange =
                            { first = sourceFirst, count = #rows - sourceFirst + 1 }
                    end
                end
            end

            if omitted then
                rows[#rows + 1] = {
                    kind = "note",
                    name = ("... %d smaller contributor(s) not stored"):format(omitted),
                }
            elseif #parts == 0 then
                rows[#rows + 1] = {
                    kind = "note",
                    name = "no breakdown recorded for this column",
                }
            end

            state.openRange = { first = blockFirst, count = #rows - blockFirst + 1 }
        end
    end

    return rows
end
