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
    -- The active column: what the bars measure, what a drill-down breaks down,
    -- and what the names in an open block are ranked by. Always set - there is
    -- always something the bars are drawn against - and independent of both
    -- the sort and of whether anything is open.
    activeCol    = 1,
    activeSource = nil,   -- expanded counterpart within the open unit

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

    -- Class-coloured, which is how a player picks their own character out of a
    -- list of several without reading any of the names.
    local class = self:SessionCharacter(entry)
    local who = ns.Colorize(ns.ShortName(entry.character or ""), class)

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
-- Everything the session list needs about a row that is not already in the
-- index header: the outcome, and who the recording character was.
--
-- One cached lookup rather than three, because each of them costs a cache read,
-- a match join and a roster build - and the list asks for all of them for every
-- row it draws. Fields are false rather than nil when absent so a miss is still
-- a cache hit.
--
-- Cached per session, and only ever asked for the handful of rows on screen.
local function SessionInfo(entry)
    state.info = state.info or {}
    local hit = state.info[entry.key]
    if hit then return hit end

    local api = ns:API()
    local cache = api and api:GetCache(entry.key)
    local match = api and api:GetMatch(entry)

    local info = { mark = false, class = false, faction = false }

    -- Roster is nil-safe about the match record and falls back to the log's own
    -- ARENA_MATCH_END, so this runs on the cache alone.
    if cache then
        local _, teams = api:Roster(entry, cache, match)
        if teams[1].won ~= nil or teams[2].won ~= nil then
            if teams[1].won == false and teams[2].won == false then
                info.mark = "|cffcccc66(D)|r"
            elseif teams[1].won then
                info.mark = "|cff66ff66(W)|r"
            else
                info.mark = "|cffff6666(L)|r"
            end
        end
    end

    if match then
        -- Recorded at the start of the match rather than read now, because the
        -- list shows sessions from every character on the account and the one
        -- logged in is rarely the one that played them.
        info.faction = match.playerFactionGroup or false

        -- The scoreboard names the recording player without their realm when it
        -- matches yours, so the join is on the base name like everywhere else.
        local wanted = BaseName(entry.character or "")
        for _, player in ipairs(match.roster or {}) do
            if BaseName(player.name or "") == wanted then
                info.class = player.class or false
                break
            end
        end
    end

    local character = (cache and cache.header and cache.header.character)
                      or entry.character or ""

    -- Failing that, the log's own combatant list. It carries a spec id, which
    -- yields the class, so an arena still colours its row with no recorder
    -- record behind it at all.
    if not info.class and cache and cache.CI then
        local own = cache.CI[character]
        local byId = own and ns.SpecById(own.s)
        info.class = (byId and byId.class) or false
    end

    -- And the faction from whatever racial they were seen to cast, in this
    -- session or in any other. A character's faction does not change, so one
    -- sighting anywhere answers for all of their sessions - which matters
    -- because plenty of matches go by without anyone pressing a racial.
    if not info.faction then
        info.faction = Model:FactionOf(character) or false
    end

    -- Only remembered once there was a cache to read. Without one this is not
    -- an answer, it is "not yet": the library builds caches over many frames
    -- after login, and the list is drawn long before it finishes. Storing the
    -- empty result is what kept a W or L off a row until that row was clicked -
    -- selecting was the only thing that ever asked again.
    if cache then state.info[entry.key] = info end
    return info
end

-- Forgets what was worked out about a session, because its cache has just been
-- built, rebuilt or dropped. The one that is selected is re-read on the spot so
-- the grid is drawn from the new cache rather than the one it replaced.
function Model:Invalidate(key)
    if state.info then state.info[key] = nil end
    -- Faction is pooled across every cache, so any change can move it.
    state.factions = nil

    if key and key == state.key then
        state.key = nil
        -- Select clears the expansion, which is right: the rows it pointed at
        -- belong to the old cache and may not exist in the new one.
        self:Select(key)
    end
end

-- Faction by character name, pooled across every cache held.
--
-- Built once and kept: it reads a small table off each cache rather than
-- walking any session's events, and the answer cannot change while the client
-- is running except by a session being added, which drops this with the rest of
-- the session info.
function Model:FactionOf(name)
    if not name or name == "" then return nil end

    if not state.factions then
        local map = {}
        local api = ns:API()
        for _, entry in ipairs((api and api:GetViewable()) or {}) do
            local cache = api:GetCache(entry.key)
            for who, faction in pairs((cache and cache.FA) or {}) do
                map[who] = faction
            end
        end
        state.factions = map
    end

    return state.factions[name] or state.factions[BaseName(name)]
end

function Model:OutcomeMark(entry)
    return SessionInfo(entry).mark or nil
end

-- Class token and faction group ("Alliance"/"Horde") of the character who
-- recorded a session, or nil for either when the match predates the recorder
-- storing it.
function Model:SessionCharacter(entry)
    local info = SessionInfo(entry)
    return info.class or nil, info.faction or nil
end

function Model:Select(key)
    if state.key == key then return end

    state.key          = key
    -- The active column survives a change of session: it is a choice about
    -- what to look at, not about which match, and resetting it on every click
    -- in the list would undo that choice for no reason.
    state.activeName   = nil
    state.activeSource = nil
    state.cursorName   = nil
    state.entry        = nil
    state.cache        = nil
    state.match        = nil
    state.players      = nil
    state.teams        = nil
    -- Dropped rather than kept: a session whose chunk was consumed since the
    -- list was last drawn now has an outcome where it had none.
    state.info         = nil
    state.factions     = nil

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
        -- The log's spec id yields a class too, so a session with no scoreboard
        -- behind it still colours its counterpart rows.
        local byId = ns.SpecById(player.specId)
        local class = player.class or (byId and byId.class)
        if class then
            state.classByName[player.name] = class
            state.classByName[BaseName(player.name)] = class
            if player.unit then state.classByName[player.unit.name] = class end
        end
    end

    -- Honor levels, joined the same way and for the same reason: the recorder
    -- writes whatever name the client gave it, which drops the realm for your
    -- own, while the log always carries one.
    state.honorByName = {}
    for name, level in pairs((state.match and state.match.honor) or {}) do
        state.honorByName[name] = level
        state.honorByName[BaseName(name)] = level
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

-- Honor level for a name, or nil for anyone the recorder never had a unit token
-- for - most of the opposing side, usually - and for every session recorded
-- before honor was captured at all.
function Model:HonorOf(name)
    local map = state.honorByName
    if not map then return nil end
    return map[name] or map[BaseName(name)]
end

-- A player as a root row describes them, in the one shape that the grid, the
-- player tooltip and the name menu all read. Kept in one place so a counterpart
-- in a breakdown is described exactly as the same player is at the root.
local function UnitRowData(player)
    local byId = ns.SpecById(player.specId)
    return {
        kind     = "unit",
        name     = player.name,
        -- Recorder first, log second, for every one of these. The scoreboard
        -- names a spec in the client's language; the log names it by id, which
        -- also yields the class. Honor is the reverse: the scoreboard has none
        -- at all, so the log usually answers it.
        class    = player.class or (byId and byId.class) or nil,
        spec     = (player.player and player.player.spec)
                   or (byId and byId.name) or nil,
        specId   = player.specId,
        honor    = Model:HonorOf(player.name) or player.honor,
        team     = player.team,
        -- Set only for a player the scoreboard does not list. They are shown
        -- on the side their reaction implies, but marked as not counted.
        departed = (player.team == nil) and player.inferredTeam or nil,
        unit     = player.unit,
        player   = player,
    }
end

-- The same description for a name met somewhere other than the root - a
-- counterpart in a breakdown - or nil when that name is not a player here.
--
-- Counterparts are named the way the log names them, realm and region
-- included, so the log's own name is tried first. The realm-stripped fallback
-- is taken only when it is unambiguous: two players sharing a name on
-- different realms is ordinary in a battleground, and guessing between them
-- would show one player's details on the other's row.
function Model:PlayerData(name)
    if not (name and state.players) then return nil end

    for _, player in ipairs(state.players) do
        if player.name == name or (player.unit and player.unit.name == name) then
            return UnitRowData(player)
        end
    end

    local base, found = BaseName(name), nil
    for _, player in ipairs(state.players) do
        if BaseName(player.name) == base then
            if found then return nil end   -- ambiguous
            found = player
        end
    end
    return found and UnitRowData(found) or nil
end

function Model:Selected()   return state.key end
function Model:Cache()      return state.cache end
function Model:Entry()      return state.entry end
function Model:Teams()      return state.teams end
function Model:Match()      return state.match end

-- Recorder first, then the log's own account: the recorder sampled the aura
-- while the match ran, and the cache derived the same figure from the largest
-- stack the debuff reached. They should agree; where only one exists, that one
-- stands.
-- How long the match ran, in seconds.
--
-- Three sources, in descending order of how directly they measure it. The
-- recorder asked the client outright. ARENA_MATCH_END is the log's own figure -
-- but for a Solo Shuffle lobby it reports the FINAL ROUND rather than the
-- lobby, so it is not trusted for a session that is a round of one. Failing
-- both, the span the session covers, which includes the gates opening and is
-- therefore the loosest of the three.
function Model:Duration()
    local match = state.match
    if match and match.duration and match.duration > 0 then
        return match.duration
    end

    local entry  = state.entry
    local header = state.cache and state.cache.header
    local isRound = entry and entry.round and entry.round > 0

    if header and header.duration and header.duration > 0 and not isRound then
        return header.duration
    end

    if entry and entry.startTime and entry.endTime then
        local span = entry.endTime - entry.startTime
        if span > 0 then return span end
    end
    return nil
end

function Model:Dampening()
    if state.match and state.match.dampening then return state.match.dampening end
    return state.cache and state.cache.dampening or nil
end

-- The scoreboard column that decides each kind of battleground, with the short
-- name the summary gives it. Earlier entries win when a map has several: Eye of
-- the Storm has both flags and bases, and keeps a score as well, which is used
-- ahead of either when it was captured.
--
-- Matched on the English column names. Another client language falls through to
-- the map's first column under its own name, which is still the right kind of
-- figure - the scoreboard lists the objective columns first.
local WIN_COLUMNS = {
    { name = "Flag Captures",     label = "Flags"   },
    { name = "Victory Points",    label = "Points"  },
    { name = "Carts Controlled",  label = "Carts"   },
    { name = "Azerite Collected", label = "Azerite" },
    { name = "Bases Assaulted",   label = "Bases"   },
    { name = "Orb Possessions",   label = "Orbs"    },
}

local function WinColumn(columns)
    if not (columns and columns[1]) then return nil end
    for _, wanted in ipairs(WIN_COLUMNS) do
        for _, column in ipairs(columns) do
            if column.name == wanted.name then return column, wanted.label end
        end
    end
    return columns[1], columns[1].name or "Objective"
end

-- What decided the match, per team: { label = "Flags", [1] = 3, [2] = 1 }, or
-- nil where there is nothing to say.
--
-- Battlegrounds only. An arena is won by elimination, and there is no figure
-- for that beyond the outcome already on the line.
--
-- The recorder's widget reading comes first, because where a map keeps a score
-- that score IS the win condition. Otherwise the map's deciding scoreboard
-- column, summed over each side's players - which for a capture-the-flag map is
-- exactly the number of flags that side took. Both come from the recorder, so a
-- match played without it, or before this was captured, has neither.
function Model:Objective()
    local match, teams, entry = state.match, state.teams, state.entry
    if not (match and teams and entry) then return nil end
    if entry.type ~= "battleground" then return nil end

    -- Every scoring battleground draws its bar Alliance on the left, Horde on
    -- the right. Sides are numbered the way the scoreboard numbers them.
    local score = match.score
    if score and score.left and score.right then
        local out = { label = "Score" }
        for i = 1, 2 do
            local side = teams[i] and teams[i].side
            if side == 1 then
                out[i] = score.left
            elseif side == 0 then
                out[i] = score.right
            end
        end
        if out[1] or out[2] then return out end
    end

    local column, label = WinColumn(match.statColumns)
    if not column then return nil end

    local out, any = { label = label }, false
    for _, player in ipairs(state.players or {}) do
        local stats = player.player and player.player.stats
        local value = stats and stats[column.id]
        if value and player.team then
            out[player.team] = (out[player.team] or 0) + value
            any = true
        end
    end
    if not any then return nil end

    -- A side that scored nothing scored zero, which is worth saying.
    out[1], out[2] = out[1] or 0, out[2] or 0
    return out
end

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

-- Column 0 is the name column, which sorts but measures nothing.
local NAME_COL = 0
ns.NAME_COL = NAME_COL

-- Sorting and the active column are two separate choices.
--
-- They used to be one: clicking a header both reordered the rows and moved the
-- bars to that column. That made it impossible to rank players by one measure
-- while reading another, and meant a header click could silently change what a
-- drill-down was about. A header now only sorts. The active column is chosen by
-- clicking a value in it.
function Model:SetSort(col)
    if state.sortCol == col then
        state.sortAsc = not state.sortAsc
    else
        state.sortCol = col
        -- Largest-first for a measure; A to Z for a name, which is the only
        -- direction anyone means by "sort by name".
        state.sortAsc = (col == NAME_COL)
    end

    if ns.db then
        ns.db.sortCol = state.sortCol
        ns.db.sortAsc = state.sortAsc
    end
end

function Model:Sort() return state.sortCol, state.sortAsc end

-- The active column. Kept in the saved setting that used to hold the bar
-- column, because it is the same choice under a better rule: what the bars are
-- drawn against.
function Model:ActiveColumn() return state.activeCol or 1 end
function Model:BarColumn()    return self:ActiveColumn() end

function Model:SetActiveColumn(col)
    if not col or col < 1 then return end
    state.activeCol = col
    if ns.db then ns.db.barCol = col end
end

-- Saved settings are read at load; the model is built before them, so both
-- choices have to be pulled across rather than assumed.
function Model:RestoreSort()
    if not ns.db then return end
    state.sortCol   = ns.db.sortCol or 1
    state.sortAsc   = ns.db.sortAsc or false
    state.activeCol = ns.db.barCol or 1
end

local function SortValue(row, col)
    return (row.unit and row.unit.cols and row.unit.cols[col]) or 0
end

--------------------------------------------------------------------------------
-- Expansion
--------------------------------------------------------------------------------

function Model:IsExpanded(name) return state.activeName == name end
function Model:IsOpen()         return state.activeName ~= nil end
function Model:ActiveSource()   return state.activeSource end

-- The row cursor: the root row the yellow selection box is on.
--
-- Usually the open row, but not necessarily open. Making a column active from a
-- row puts the cursor on that row without opening it - the first click on a new
-- measure is a request to look at it, and a second click in the same place is
-- what opens it. The box sits on the cursor either way, around the whole open
-- block when there is one and around the single row when there is not.
function Model:IsSelected(name) return name ~= nil and state.cursorName == name end
function Model:Cursor()         return state.cursorName end

-- Closes the drill-down. The active column and the cursor stay: closing a
-- breakdown is not a decision to stop reading that measure, or that player.
function Model:Collapse()
    state.activeName   = nil
    state.activeSource = nil
end

-- Moves the cursor to a root row. Anything open elsewhere closes, because it is
-- outside the selection now and only the selected row may be open.
function Model:SelectRow(name)
    if state.cursorName == name then return end
    if state.activeName ~= name then self:Collapse() end
    state.cursorName = name
end

-- Opens a unit's breakdown in the active column, or closes it if it is the one
-- already open, and puts the cursor on it either way. Only one unit is open at a
-- time, so opening another closes the first. A player with nothing in the log
-- is still selected, but has nothing to break down.
--
-- The root name used to be inert while collapsed, on the reasoning that there
-- was no column to open until one had been chosen. There always is now - the
-- active column - so the name is the natural thing to click.
function Model:ToggleExpand(name, unit)
    self:SelectRow(name)
    if not unit then return end
    if state.activeName == name then
        self:Collapse()
        return
    end
    state.activeName   = name
    state.activeSource = nil
end

-- Selects a unit and opens its breakdown, leaving it open if it already was.
-- For a click that means "show me this", where a toggle would close a breakdown
-- the user was only trying to look at in a different column.
function Model:Open(name, unit)
    self:SelectRow(name)
    if not unit or state.activeName == name then return end
    state.activeName   = name
    state.activeSource = nil
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
--
-- With nothing open it is the cursor row alone, so the box stays on the
-- selected player between one breakdown and the next.
function Model:OpenBlock()
    local range = state.openRange
    if range then return range.first, range.count end
    if state.cursorRow then return state.cursorRow, 1 end
    return nil
end

-- The same, one level down: the open counterpart and the spells under it. Nil
-- when no counterpart is open, or when the open one turned out to have no
-- spells recorded - nothing was revealed, so nothing wants bracketing.
function Model:OpenSourceBlock()
    local range = state.sourceRange
    if not range then return nil end
    return range.first, range.count
end

-- One column of a unit's breakdown, as the drill-down shows it: the unit's
-- spell totals first when it has any, then each counterpart, largest first.
--
-- Built for every column of the open unit, not only the active one, because an
-- open block now shows a value in every column. Each column is its own ranked
-- list; row N of the block shows the Nth entry of each. Only the active column's
-- list decides how many rows there are and what they are called.
--
-- "Spell Totals" answers the question the per-counterpart lists cannot: what
-- did this unit actually cast? The same spells summed across everyone they were
-- used on. It leads the list because it is the whole of which the rest are
-- parts, and because it leads every column it lines up across all of them.
--
-- Its own value is the unit's column total rather than the sum of the spells
-- beneath it. The itemisation is capped, so the two can differ, and the total
-- is the figure that is exact.
local function ColumnList(api, cache, unit, col)
    local parts, omitted = api:Breakdown(cache, unit.index, col)

    -- Breakdown sorts largest-first, so before the summary goes in, the first
    -- entry is the largest counterpart - the scale every counterpart bar uses.
    local partMax = parts[1] and parts[1].v or 0

    local totals, spellOrder = {}, {}
    for _, part in ipairs(parts) do
        for _, use in ipairs(part.spells or {}) do
            local slot = totals[use.name]
            if not slot then
                slot = { name = use.name, id = use.id,
                         spellId = use.spellId, school = use.school,
                         v = 0, n = 0 }
                totals[use.name] = slot
                spellOrder[#spellOrder + 1] = slot
            end
            slot.v = slot.v + (use.v or 0)
            slot.n = slot.n + (use.n or 0)
            -- The extremes carry across the merge: the largest hit on anyone
            -- is still the largest hit.
            if use.mn and (not slot.mn or use.mn < slot.mn) then slot.mn = use.mn end
            if use.mx and (not slot.mx or use.mx > slot.mx) then slot.mx = use.mx end
        end
    end

    if #spellOrder > 0 then
        table.sort(spellOrder, function(a, b) return a.v > b.v end)
        table.insert(parts, 1, {
            name    = SPELL_TOTALS,
            v       = unit.cols[col] or 0,
            n       = (unit.counts and unit.counts[col]) or 0,
            spells  = spellOrder,
            summary = true,
        })
    end

    return parts, omitted, partMax
end

-- The entry with a given name in a list, or nil. Counterparts are unique by name
-- within a column, and the summary is named SPELL_TOTALS in every column, so a
-- plain name match finds "the same thing" in another column either way.
local function FindEntry(list, name)
    for _, entry in ipairs(list or {}) do
        if entry.name == name then return entry end
    end
    return nil
end

function Model:Rows()
    local rows = {}
    local cache = state.cache
    state.openRange, state.sourceRange, state.cursorRow = nil, nil, nil
    if not (cache and state.players) then return rows end

    local api = ns:API()
    local columns = self:Columns()
    local sortCol, asc = state.sortCol, state.sortAsc

    -- A saved active column from a build with more columns than this session
    -- carries would point past the end of the grid.
    if (state.activeCol or 1) > #columns then state.activeCol = 1 end
    local activeCol = self:ActiveColumn()

    -- Realm-stripped and case-folded, so an alphabetical sort reads the way the
    -- names are drawn rather than the way they are stored: "aiden-Ravencrest"
    -- belongs beside "Aiden", not before every capital letter in the list.
    local function NameKey(player)
        return (ns.ShortName(player.name or "") or ""):lower()
    end

    local order = {}
    for _, player in ipairs(state.players) do order[#order + 1] = player end
    table.sort(order, function(a, b)
        if sortCol == ns.NAME_COL then
            local an, bn = NameKey(a), NameKey(b)
            if an == bn then return (a.name or "") < (b.name or "") end
            if asc then return an < bn end
            return an > bn
        end

        local av, bv = SortValue(a, sortCol), SortValue(b, sortCol)
        if av == bv then return (a.name or "") < (b.name or "") end
        if asc then return av < bv end
        return av > bv
    end)

    -- Bars are scaled so the largest value in the active column fills the name
    -- cell, and every deeper level rescales against its own siblings. A single
    -- global scale would make every drill-down bar a sliver, which is the
    -- opposite of what the level is for: comparing that level's entries.
    local activeMax = 0
    for _, player in ipairs(order) do
        local value = SortValue(player, activeCol)
        if value > activeMax then activeMax = value end
    end
    local function Fraction(value, max)
        if not max or max <= 0 then return 0 end
        return math.min(1, (value or 0) / max)
    end

    -- Every row carries three things the window animates by, because the row
    -- tables themselves are rebuilt on every refresh and cannot be what an
    -- animation is keyed on:
    --
    --   key    a stable identity - the same player, counterpart or spell gets
    --          the same key in the next rebuild
    --   block  the open unit's block this row belongs to; `sub` likewise for
    --          the open counterpart's spell list inside it
    --   opens  the block a row reveals beneath itself when it is open
    for _, player in ipairs(order) do
        local root = player.name
        local block = "b:" .. root

        local unitRow = UnitRowData(player)
        unitRow.frac  = Fraction(SortValue(player, activeCol), activeMax)
        unitRow.key   = "u:" .. root
        unitRow.opens = block
        rows[#rows + 1] = unitRow
        if state.cursorName == player.name then state.cursorRow = #rows end

        if state.activeName == player.name and player.unit then
            local blockFirst = #rows

            local lists, omittedBy, partMax = {}, {}, 0
            for c = 1, #columns do
                local list, dropped, largest = ColumnList(api, cache, player.unit, c)
                lists[c] = list
                if dropped and dropped > 0 then omittedBy[c] = dropped end
                if c == activeCol then partMax = largest end
            end
            local parts = lists[activeCol] or {}

            -- The breakdown is as long as its longest column, whichever column
            -- is active. Sized by the active column instead, it grew and shrank
            -- every time the column changed, and every row beneath it moved
            -- with it - which is exactly the motion a column change should not
            -- cause. At this length no column ever has more entries than rows,
            -- so none of them needs the "..." either.
            local depth = 0
            for c = 1, #columns do
                if #lists[c] > depth then depth = #lists[c] end
            end

            -- A counterpart opened under another column may not exist in this
            -- one, or may exist with no spells behind it. Either way there is
            -- nothing to show open, so it is closed rather than left claiming a
            -- level that has no rows - which would take the yellow off every
            -- counterpart and put it nowhere.
            if state.activeSource then
                local kept = FindEntry(parts, state.activeSource)
                if not (kept and kept.spells and #kept.spells > 0) then
                    state.activeSource = nil
                end
            end

            for rank, part in ipairs(parts) do
                local class = self:ClassOf(part.name)
                local sub = "sb:" .. root .. ":" .. part.name
                rows[#rows + 1] = {
                    kind    = "source",
                    key     = "s:" .. root .. ":" .. part.name,
                    block   = block,
                    opens   = sub,
                    name    = part.name,
                    part    = part,
                    col     = activeCol,
                    team    = player.team,
                    class   = class,
                    summary = part.summary,
                    -- Where this row sits, and the lists the other columns
                    -- draw their Nth entry from.
                    rank    = rank,
                    count   = depth,
                    lists   = lists,
                    -- The player behind a counterpart, for the same tooltip and
                    -- menu a root row gets. Nil for pets, NPCs and the summary.
                    playerData = (not part.summary) and self:PlayerData(part.name) or nil,
                    -- The summary line is the whole, so it always fills. Scaled
                    -- against the counterparts it would simply be the longest
                    -- bar and would squash every real one beside it.
                    frac    = part.summary and 1 or Fraction(part.v, partMax),
                }

                if state.activeSource == part.name and part.spells then
                    local sourceFirst = #rows   -- the counterpart row just added

                    -- The same counterpart's spells in every other column. Its
                    -- spells in column C are what it did to this unit in the
                    -- measure C counts, so a row reads across as one spell
                    -- list per measure, all for the one counterpart that was
                    -- opened.
                    local spellLists = {}
                    for c = 1, #columns do
                        local same = FindEntry(lists[c], part.name)
                        spellLists[c] = (same and same.spells) or {}
                    end

                    local spellMax = part.spells[1] and part.spells[1].v or 0
                    for spellRank, use in ipairs(part.spells) do
                        rows[#rows + 1] = {
                            kind  = "spell",
                            key   = "p:" .. root .. ":" .. part.name .. ":" .. use.name,
                            block = block,
                            sub   = sub,
                            name  = use.name,
                            use   = use,
                            id    = use.spellId or use.id,
                            col   = activeCol,
                            -- The spells belong to the counterpart, so they keep
                            -- that unit's class colour rather than the root's.
                            class = class,
                            rank  = spellRank,
                            count = #part.spells,
                            lists = spellLists,
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

            -- The rest of the breakdown's length, past the end of the active
            -- column's list. These rows have no entry of their own, so their
            -- name is blank and the active column reads "--", but every other
            -- column still shows its entry at that rank and can be clicked to
            -- become active. The first of them says why the name is missing
            -- when the active column has nothing at all.
            --
            -- A breakdown with nothing in any column still gets that one row,
            -- rather than opening to nothing.
            local empty = "no breakdown recorded for this column"
            for rank = #parts + 1, math.max(depth, 1) do
                rows[#rows + 1] = {
                    kind  = "note",
                    key   = "n:" .. root .. ":rank" .. rank,
                    block = block,
                    name  = (rank == 1) and empty or "",
                    col   = activeCol,
                    rank  = rank,
                    count = math.max(depth, 1),
                    lists = lists,
                }
            end

            -- Contributors past the storage cap, per column. Shown whenever any
            -- column has some, not only the active one, so the row does not
            -- come and go as the column changes; each column carries its own
            -- count and the rest are blank.
            if next(omittedBy) then
                rows[#rows + 1] = {
                    kind     = "note",
                    key      = "n:" .. root .. ":omitted",
                    block    = block,
                    name     = "... smaller contributors not stored",
                    col      = activeCol,
                    omitted  = omittedBy,
                }
            end

            state.openRange = { first = blockFirst, count = #rows - blockFirst + 1 }
        end
    end

    return rows
end
