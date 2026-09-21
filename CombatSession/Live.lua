-- CombatSession: live session data from the game's own damage meter.
--
-- The advanced combat log is still the authority. This fills the gap before it
-- arrives: from the moment a match starts, the client's damage meter can be read
-- for what everyone in it has done, and that is shown under the same session
-- boundaries the log will later be cut into, so the row a player is looking at
-- is filled in rather than replaced when the real data lands.
--
-- Three things about the meter shape everything here, all of them established by
-- measurement rather than assumption (a throwaway probe addon recorded three
-- days of play; the numbers below are from that):
--
--   * Its figures are CUMULATIVE and never reset on their own. 160 sessions
--     across 15 meter clears were checked and not one figure ever went backwards
--     except across a clear. So a session's own numbers are a reading taken at
--     its start subtracted from a reading taken now, which means our boundaries
--     do not have to match the meter's - and they do not: one of its sessions ran
--     for 29 minutes across several matches.
--
--   * Nothing numeric can be read while the player is in combat; everything can
--     the moment combat drops. Reads are therefore taken on leaving combat,
--     which in a battleground is every fight.
--
--   * A GUID is readable out of combat even when the name beside it is not. Enemy
--     names stay secret until the battleground map itself is left. Rows are
--     therefore keyed by GUID - which is also what the log carries, so the merge
--     needs no name matching - and an enemy is labelled by spec until their name
--     can be read.
--
-- Differencing the meter this way reproduced the game's own scoreboard for 35 of
-- 38 matches at 0.99-1.29 of its figures (usually 1.02-1.10), with every player
-- matched by GUID. The three misses were meter clears, which are detected here.

local ADDON, ns = ...

local Live = {}
ns.Live = Live

--------------------------------------------------------------------------------
-- Secret guards
--
-- A secret value cannot be compared, tested, added to or concatenated by addon
-- code; each of those throws. Every value read below passes through these first,
-- and only a readable one is ever used.
--------------------------------------------------------------------------------

local issecret = issecretvalue or function() return false end
local issecrett = issecrettable or function() return false end

local function Plain(v)
    if issecret(v) then return nil end
    return v
end

local function PlainTable(t)
    if issecret(t) or issecrett(t) then return nil end
    if type(t) ~= "table" then return nil end
    return t
end

local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if not ok then return nil end
    return result
end

-- Whether a returned structure is a list of rows or a single row.
local function IsList(t)
    local first = rawget(t, 1)
    return not issecret(first) and type(first) == "table"
end

--------------------------------------------------------------------------------
-- What the meter offers, and where it goes
--------------------------------------------------------------------------------

local DM = C_DamageMeter
local METER = Enum and Enum.DamageMeterType or {}
local OVERALL = (Enum and Enum.DamageMeterSessionType and Enum.DamageMeterSessionType.Overall) or 0

-- Meter type -> the column it fills. Only these six of our twelve have a
-- counterpart in the meter; the rest wait for the log, which is why a live
-- session is always marked as provisional however complete it looks.
local METER_COLUMNS = {
    { type = METER.DamageDone  or 0, column = "Damage Done"  },
    { type = METER.DamageTaken or 7, column = "Damage Taken" },
    { type = METER.HealingDone or 2, column = "Healing Done" },
    { type = METER.Interrupts  or 5, column = "Interrupts"   },
    { type = METER.Dispels     or 6, column = "Dispels"      },
    -- Deaths is deliberately absent. The meter has the type, but every figure it
    -- returned for a full battleground was zero, and a column of zeros reads as
    -- "nobody died" rather than as "not known yet". The log reports deaths
    -- properly; until that arrives the column is better left empty.
}

-- Resolved on first use: FORMAT_COLUMNS belongs to Data.lua, which may not have
-- loaded yet when this file does.
local columnOf

local function Columns()
    if columnOf then return columnOf end
    columnOf = {}
    local index = {}
    for i, name in ipairs(ns.FORMAT_COLUMNS or {}) do index[name] = i end
    for _, map in ipairs(METER_COLUMNS) do
        local col = index[map.column]
        if col then columnOf[#columnOf + 1] = { type = map.type, col = col } end
    end
    return columnOf
end

-- The same list as column indices, for anything that has to offer a choice of
-- measure. A live meter can only show a column the meter fills: the other seven
-- wait for the log, and offering one of them would be a menu entry that draws an
-- empty list however long the match runs.
function Live:LiveColumns()
    local out = {}
    for _, map in ipairs(Columns()) do out[#out + 1] = map.col end
    return out
end

local FLAG_PLAYER   = 0x00000400
local FLAG_NPC      = 0x00000800
local FLAG_HOSTILE  = 0x00000040
local FLAG_FRIENDLY = 0x00000010

-- How much of a breakdown is kept for one unit and column. The live figures are
-- provisional and the saved file is not the place to hold a full itemisation of
-- every fight, so only the largest are stored - the same shape the log path uses,
-- which records how many it dropped. The log supplies the rest soon enough.
local MAX_PARTS            = 8
local MAX_SPELLS_PER_PART  = 5

-- Full reads walk every source's spells and targets, which is six calls per
-- player. Cheap enough at the end of a match, wasteful every fight, so the
-- shallow read - totals only - covers the fights in between.
local DEEP_EVERY = 4

--------------------------------------------------------------------------------
-- Spec icons
--
-- The meter names a spec only by its icon, which is the one identifying thing it
-- will hand over for an enemy mid-match. Turning that into a spec gives a
-- provisional label for a row whose name is still secret.
--------------------------------------------------------------------------------

-- Spell names for the breakdown. The library has no lookup of its own: a built
-- cache stores the names the log gave it, and the log is not what is being read
-- here.
local spellNames = {}

local function SpellName(id)
    local hit = spellNames[id]
    if hit ~= nil then return hit or nil end
    local name
    if C_Spell and C_Spell.GetSpellName then
        name = Plain(Call(C_Spell.GetSpellName, id))
    end
    spellNames[id] = name or false
    return name
end

local specByIcon

local function SpecFromIcon(icon)
    if icon == nil then return nil end
    if not specByIcon then
        specByIcon = {}
        if type(GetSpecializationInfoByID) == "function" then
            for id = 1, 1600 do
                local ok, specID, name, _, specIcon, _, classFile = pcall(GetSpecializationInfoByID, id)
                if ok then
                    specID, specIcon = Plain(specID), Plain(specIcon)
                    if specID and specIcon and not specByIcon[specIcon] then
                        specByIcon[specIcon] = { id = specID, name = Plain(name), class = Plain(classFile) }
                    end
                end
            end
        end
    end
    return specByIcon[icon]
end

--------------------------------------------------------------------------------
-- State
--
-- Deltas live in the saved record so a reload keeps them. Baselines do not: they
-- are only meaningful against the meter's current run, and losing them is the
-- same situation as the meter being cleared, which is handled either way.
--------------------------------------------------------------------------------

local baseline = {}   -- key -> the reading this session started from
local lastSeen = {}   -- key -> the most recent reading, for banking on a clear
local banked   = {}   -- key -> what was counted before the last clear or reload

-- True only for the reading that establishes a session's starting point. What it
-- decides is what an unseen figure means: during that first reading it is
-- whatever the player had already done before this session, and afterwards it is
-- someone who has only now done something - a player who had not yet swung when
-- the session opened, whose whole contribution belongs to it.
local baselining = false

local current            -- the open record, or nil
local matchRefs = {}     -- live key -> the recorder's in-progress match table
local cacheCache = {}    -- live key -> the cache-shaped view, rebuilt on change
local sampleCount = 0

-- GUID -> the meter's name for a unit whose name the game is withholding, kept
-- as the secret value itself. Never saved and never looked at: a secret cannot
-- be compared or joined to anything, but a font string will draw one, which is
-- how Details! shows enemy names mid-match. Live:SecretName hands it to a viewer
-- for exactly that and nothing else.
local secretNames = {}

-- Live key -> the key of the built session that replaced it. Memory only: the
-- replacement happens in the session the cache is built, and anything that has
-- to follow it - a viewer's remembered selection - asks in that same session.
local successors = {}

local function Key(guid, col, kind, id)
    if kind then return guid .. "|" .. col .. "|" .. kind .. id end
    return guid .. "|" .. col
end

-- The meter's cumulative figure as this session's own.
local function Delta(key, value)
    local base = baseline[key]
    if base == nil then
        -- Anything first seen after the session opened started from nothing, as
        -- far as this session is concerned. Taking its current figure as the
        -- baseline instead would throw away everything that unit had done since
        -- the match began, which is most of it for anyone who joined a fight late.
        base = baselining and value or 0
        baseline[key] = base
    elseif value < base then
        -- The counter went backwards, so the meter was cleared - by another addon
        -- or by the player. What was already counted is kept and counting starts
        -- again from nothing.
        banked[key] = (banked[key] or 0) + ((lastSeen[key] or base) - base)
        base = 0
        baseline[key] = 0
    end
    lastSeen[key] = value
    return (banked[key] or 0) + (value - base)
end

-- After a reload the stored deltas are all that is left of the match so far, so
-- they become the banked total and the next read sets a fresh baseline.
local function Resume(record)
    for guid, unit in pairs(record.units or {}) do
        for col, value in pairs(unit.cols or {}) do
            banked[Key(guid, col)] = value
            baseline[Key(guid, col)] = nil
        end
        -- Only the per-spell figures are banked: a counterpart's own figure is
        -- the sum of them, recomputed on every reading rather than tracked.
        for col, parts in pairs(unit.parts or {}) do
            for name, entry in pairs(parts) do
                for id, value in pairs(entry.s or {}) do
                    banked[Key(guid, col, "t", name .. "|s" .. id)] = value
                    baseline[Key(guid, col, "t", name .. "|s" .. id)] = nil
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Reading the meter
--------------------------------------------------------------------------------

-- Readable means out of combat: in combat every figure comes back secret. The
-- restriction state is what decides it, not the player's own combat flag.
local function Readable()
    if InCombatLockdown() then return false end
    if not (C_RestrictedActions and Enum and Enum.AddOnRestrictionType) then return true end
    local state = Call(C_RestrictedActions.GetAddOnRestrictionState, Enum.AddOnRestrictionType.Combat)
    return not (state and state > 0)
end

-- Names a unit, under one rule: a name read against the unit's own GUID - the
-- meter's, or the scoreboard's at the end of the match - always beats one matched
-- by class, and takes it back from any other unit that was given it by class.
-- Two rows holding one name would collapse into one in the cache's name table.
--
-- Every class match is counted, and so is what became of it once a GUID-backed
-- name arrived, so how often the inference holds can be read from the data.
local function Naming(record)
    local naming = record.naming or { class = 0, confirmed = 0, corrected = 0 }
    record.naming = naming
    return naming
end

local function Rename(record, unit, name, byClass)
    local naming = Naming(record)

    if unit.name == name then
        if not byClass and unit.nameBy == "class" then
            naming.confirmed = naming.confirmed + 1
            unit.nameBy = nil
        end
        return false
    end

    if byClass then
        naming.class = naming.class + 1
    else
        if unit.nameBy == "class" then naming.corrected = naming.corrected + 1 end
        for _, other in pairs(record.units) do
            if other ~= unit and other.nameBy == "class" and other.name == name then
                other.name, other.nameBy = nil, nil
                naming.corrected = naming.corrected + 1
            end
        end
    end

    unit.name = name
    unit.nameBy = byClass and "class" or nil
    return true
end

local function UnitFor(record, guid, src)
    local unit = record.units[guid]
    if not unit then
        unit = { cols = {}, parts = {} }
        record.units[guid] = unit
        record.unitOrder[#record.unitOrder + 1] = guid
    end

    -- Identity is refreshed on every read, because the parts of it that are
    -- secret change as restrictions lift: a name that was withheld during the
    -- match arrives once the map is left. Until then the secret itself is kept
    -- in memory for display.
    local name = src.name
    if issecret(name) then
        secretNames[guid] = name
    elseif type(name) == "string" and name ~= "" then
        secretNames[guid] = nil
        Rename(record, unit, name)
    end

    local class = Plain(src.classFilename)
    if class and class ~= "" then unit.class = class end

    local icon = Plain(src.specIconID)
    if icon then unit.specIcon = icon end

    if Plain(src.isLocalPlayer) then unit.isPlayer = true end

    local display = Plain(src.sourceDisplayType)
    if display == 1 then unit.ally = true
    elseif display == 2 then unit.ally = false end

    local faction = Plain(src.factionGroup)
    if faction and faction ~= "" then unit.faction = faction end

    if unit.kind == nil then
        local kind = guid:match("^(%a+)%-")
        unit.kind = (kind == "Player") and "player" or "npc"
    end
    return unit
end

-- One meter type into one column. Returns false when nothing could be read,
-- which is how a read taken a moment too early is told from an empty session.
local function ReadColumn(record, meterType, col, deep)
    local session = PlainTable(Call(DM and DM.GetCombatSessionFromType, OVERALL, meterType))
    if not session then return false end

    local list = PlainTable(session.combatSources)
    if not list then return false end

    for i = 1, #list do
        local src = PlainTable(list[i])
        local guid = src and Plain(src.sourceGUID)
        local total = src and Plain(src.totalAmount)
        if guid and total then
            local unit = UnitFor(record, guid, src)
            unit.cols[col] = Delta(Key(guid, col), total)

            if deep then
                -- The counterparts of one column, and which spells landed on
                -- each. The meter reports a spell's per-target amounts, so this
                -- is its own account of who was hit with what - nothing is
                -- apportioned or guessed at here.
                local creature = Plain(src.sourceCreatureID)
                local source = PlainTable(Call(DM.GetCombatSessionSourceFromType,
                                               OVERALL, meterType, guid, creature))
                local spells = source and PlainTable(source.combatSpells)
                if spells then
                    local parts = unit.parts[col] or {}
                    unit.parts[col] = parts

                    for j = 1, #spells do
                        local spell = PlainTable(spells[j])
                        local id = spell and Plain(spell.spellID)
                        if id then
                            local details = PlainTable(spell.combatSpellDetails)
                            -- Documented as one structure, named and used as a
                            -- list; both are accepted.
                            if details then
                                local rows = details
                                if not IsList(details) then rows = { details } end
                                for k = 1, #rows do
                                    local row = PlainTable(rows[k])
                                    local who = row and Plain(row.unitName)
                                    local amount = row and Plain(row.amount)
                                    if who and who ~= "" and amount then
                                        local part = parts[who]
                                        if not part then
                                            part = { v = 0, s = {} }
                                            parts[who] = part
                                        end
                                        part.s[id] = Delta(Key(guid, col, "t", who .. "|s" .. id), amount)
                                    end
                                end
                            end
                        end
                    end

                    -- A counterpart's own figure is the sum of what landed on
                    -- them, which is the only figure the meter gives for them.
                    for _, part in pairs(parts) do
                        local sum = 0
                        for _, value in pairs(part.s) do sum = sum + value end
                        part.v = sum
                    end
                end
            end
        end
    end
    return true
end

-- Drops all but the largest, so one match cannot fill the saved file with the
-- itemisation of every spell landed on every player. Dropped keys keep their
-- baseline, so anything that grows back into the top of the list returns with the
-- right figure rather than starting again.
local function Trim(map, keep, valueOf)
    local order = {}
    for k, entry in pairs(map) do order[#order + 1] = { k, valueOf(entry) } end
    if #order <= keep then return end
    table.sort(order, function(a, b) return a[2] > b[2] end)
    for i = keep + 1, #order do map[order[i][1]] = nil end
end

local function PartValue(entry) return entry.v or 0 end
local function PlainValue(value) return value or 0 end

--------------------------------------------------------------------------------
-- Enemy names during the match
--
-- The meter withholds enemy names until the battleground map is left. The
-- scoreboard does not: its names and class tokens are never secret. What it
-- withholds instead, for as long as the match is active, is the GUID - the one
-- field that would join its rows to the meter's. So nothing can be joined by
-- identity until the end, and anything before that is inference.
--
-- One inference is safe enough to store: on the enemy side, a class that appears
-- once on the scoreboard and once among the unnamed enemy rows is the same
-- player. Anything less certain - two warriors, say, since spec is secret on the
-- scoreboard as well - is left unnamed. It can still be wrong in one way: a
-- player who left and was replaced by someone of the same class who has not done
-- anything yet. So these names are marked as matched by class, and the GUID-joined
-- names at the end of the match replace any that were wrong and count them.
--------------------------------------------------------------------------------

local function NamesFromScoreboard(record)
    local get = C_PvP and C_PvP.GetScoreInfo
    local count = Plain(Call(_G.GetNumBattlefieldScores))
    if type(get) ~= "function" or type(count) ~= "number" or count == 0 then return 0 end

    -- Which side is ours, from our own row. The scoreboard leaves the realm off
    -- for players on your own realm, so the bare character name is what it holds.
    --
    -- Fields are read one by one and never iterated: the table itself cannot be
    -- walked by addon code during a match, only indexed.
    local me = Plain(Call(UnitName, "player"))
    local rows, ours = {}, nil
    for i = 1, count do
        local info = Call(get, i)
        if type(info) == "table" then
            local name    = Plain(info.name)
            local class   = Plain(info.classToken)
            local faction = Plain(info.faction)
            if type(name) == "string" and name ~= "" and class and faction ~= nil then
                rows[#rows + 1] = { name = name, class = class, faction = faction }
                if name == me then ours = faction end
            end
        end
    end
    -- What the scoreboard gave, as of the latest attempt. That these fields are
    -- readable mid-match comes from another addon's notes rather than from
    -- anything measured here, so this is what settles it for this client and
    -- this match. Zero rows means they came back secret; rows with no side means
    -- our own row could not be found among them.
    local naming = Naming(record)
    naming.rows = #rows
    naming.side = (ours ~= nil)

    -- Our own row missing means the scoreboard is showing one side only, or is not
    -- populated yet. Either way there is no telling which rows are the enemy.
    if ours == nil then return 0 end

    local taken = {}
    for _, unit in pairs(record.units) do
        if unit.name then taken[unit.name] = true end
    end

    local pool = {}
    for _, row in ipairs(rows) do
        if row.faction ~= ours and not taken[row.name] then
            local list = pool[row.class] or {}
            pool[row.class] = list
            list[#list + 1] = row.name
        end
    end

    -- Only rows the meter itself marked as enemies. The faction fallback the cache
    -- uses for display is wrong under mercenary mode, and giving an ally an enemy's
    -- name is worse than giving nobody one.
    local unnamed = {}
    for _, unit in pairs(record.units) do
        if not unit.name and unit.kind == "player" and unit.ally == false and unit.class then
            local list = unnamed[unit.class] or {}
            unnamed[unit.class] = list
            list[#list + 1] = unit
        end
    end

    local named = 0
    for class, units in pairs(unnamed) do
        local names = pool[class]
        if #units == 1 and names and #names == 1 then
            if Rename(record, units[1], names[1], true) then named = named + 1 end
        end
    end
    return named
end

function Live:Sample(reason)
    local record = current
    if not record or record.closed then return false end
    if not Readable() then return false end

    sampleCount = sampleCount + 1
    local deep = (reason ~= "combat") or (sampleCount % DEEP_EVERY == 0)

    local read = false
    for _, map in ipairs(Columns()) do
        if ReadColumn(record, map.type, map.col, deep) then read = true end
    end
    if not read then return false end

    -- The starting point is set by the first reading that actually read
    -- something: one taken while the figures were still secret settles nothing,
    -- and treating the next one as ordinary would baseline the whole session at
    -- zero and count everyone's pre-match totals into it.
    baselining = false

    if deep then
        for _, unit in pairs(record.units) do
            for _, parts in pairs(unit.parts) do
                Trim(parts, MAX_PARTS, PartValue)
                for _, part in pairs(parts) do
                    Trim(part.s, MAX_SPELLS_PER_PART, PlainValue)
                end
            end
        end
    end

    -- Not for a lobby's rounds: teams are redrawn between them, and whether the
    -- scoreboard's sides follow the current round is not something that has been
    -- measured. A wrong side would name players after their own teammates.
    if not record.round then NamesFromScoreboard(record) end
    -- Asked for after every reading, so the next one works from a scoreboard no
    -- older than the last fight.
    Call(_G.RequestBattlefieldScoreData)

    record.updatedAt = ns:Now()
    record.samples = (record.samples or 0) + 1
    record.reason = reason
    cacheCache[record.key] = nil
    ns:LiveChanged(record.key)
    return true
end

--------------------------------------------------------------------------------
-- Session lifecycle
--
-- Driven by the recorder, so a live session begins and ends exactly where the
-- application will cut the log.
--------------------------------------------------------------------------------

local function Prune()
    local db = ns.db
    if not (db and db.live) then return end
    local keys = {}
    for key in pairs(db.live) do keys[#keys + 1] = key end
    if #keys <= (db.settings.maxLive or 8) then return end
    table.sort(keys)
    for i = 1, #keys - (db.settings.maxLive or 8) do
        db.live[keys[i]] = nil
        cacheCache[keys[i]] = nil
        matchRefs[keys[i]] = nil
    end
end

-- How long an open record stays adoptable. A reload takes seconds; anything
-- older than this was left open by a logout and belongs to a match that is over.
local RESUME_WINDOW = 600

-- `round` opens a session for one round of a Solo Shuffle or Blitz lobby rather
-- than for the whole match, which is how the application cuts the log for them.
function Live:Begin(match, round)
    if not (DM and DM.GetCombatSessionFromType) then return end

    self:Finish()

    local db = ns.db
    db.live = db.live or {}

    wipe(baseline)
    wipe(lastSeen)
    wipe(banked)
    -- Kept until now rather than cleared at the end of a match, so the match just
    -- played still shows its enemies' names until the next one starts.
    wipe(secretNames)
    sampleCount = 0

    -- A reload inside a match makes the recorder open the match again, and this
    -- has to follow it without splitting the match in two: an open record for the
    -- same instance is continued rather than replaced. Its stored figures become
    -- the banked total and the next reading sets a fresh baseline.
    local resumed
    if not round then
        for _, record in pairs(db.live) do
            if not record.closed and record.map == match.map
               and (ns:Now() - (record.updatedAt or record.startedAt or 0)) < RESUME_WINDOW
               and (not resumed or (record.startedAt or 0) > (resumed.startedAt or 0)) then
                resumed = record
            end
        end
    end

    if resumed then
        current = resumed
        Resume(resumed)
        ns:Debug("live session resumed", resumed.key)
    else
        -- Anything still open at this point was left that way by a logout, and
        -- saying "recording" about a match that ended hours ago is worse than
        -- saying nothing.
        for _, record in pairs(db.live) do record.closed = true end

        local key = ("%s_%s_live"):format(date("%Y%m%d_%H%M%S", ns:Now()), tostring(match.map or 0))
        current = {
            key         = key,
            round       = round,
            startedAt   = (round and ns:Now()) or match.startedAt or ns:Now(),
            map         = match.map,
            mapName     = match.mapName,
            type        = match.instanceType,
            rated       = match.isRated,
            character   = match.character,
            characterGuid = match.characterGuid,
            units       = {},
            unitOrder   = {},
            samples     = 0,
        }
        db.live[key] = current
        Prune()
        ns:Debug("live session opened", key)
    end

    matchRefs[current.key] = match
    match.live = current.key
    current.faction = match.playerFactionGroup or current.faction

    -- The baseline read. Taken now rather than at the first fight, so anything
    -- done between the gates opening and the first reading still lands in this
    -- session and not in the one before it.
    baselining = true
    self:Sample("begin")

    -- Said whether or not that read returned anything, which at the gates it
    -- usually does not: nobody has done anything yet, so there is nothing in the
    -- meter's list and Sample reports no reading. The session still exists and is
    -- now the newest one, and anything showing the newest session - the viewer's
    -- meter window does - would otherwise go on showing the last match until the
    -- first fight ended.
    ns:LiveChanged(current.key)
end

-- The scoreboard names every player and carries their GUID, which is the key the
-- live rows are already filed under. So at completion it can name the enemies
-- whose own meter rows still will not - a good half minute before leaving the map
-- makes them readable.
local function NamesFromRoster(record, match)
    if not (record and match and match.roster) then return 0 end
    local filled = 0
    for _, row in ipairs(match.roster) do
        local guid = Plain(row.guid)
        local name = Plain(row.name)
        local unit = guid and record.units[guid]
        if unit and type(name) == "string" and name ~= "" and Rename(record, unit, name) then
            filled = filled + 1
        end
    end
    return filled
end

-- The match is over and its figures are final; only names may still be missing.
function Live:Complete()
    if not current then return end
    self:Sample("complete")
    NamesFromRoster(current, matchRefs[current.key])
    current.complete = true
    current.endedAt = ns:Now()
    cacheCache[current.key] = nil
    ns:LiveChanged(current.key)
end

function Live:Finish()
    if not current then return end
    self:Sample("finish")
    current.endedAt = current.endedAt or ns:Now()
    current.closed = true

    local key = current.key

    -- The naming counts outlive the record. Once the log replaces it, the match
    -- record is the only place left that can say how well enemies were named
    -- before it did. The same table, not a copy, so names filled in when the map
    -- restriction lifts - after this - are counted in it too.
    local match = matchRefs[key]
    if match and current.naming then match.liveNaming = current.naming end

    -- A round session opened for a round that never happened - the lobby ended on
    -- the one before - holds nothing and would list as an empty row.
    if not next(current.units) then
        ns.db.live[key] = nil
        matchRefs[key] = nil
    end

    current = nil
    cacheCache[key] = nil
    ns:LiveChanged(key)
end

-- A round of a lobby ended: close this one and open the next, so live sessions
-- land on the same boundaries the log will be cut on.
function Live:Round(match, index)
    if not current then return end
    self:Complete()
    self:Begin(match, index)
end

-- Enemy names only become readable once the battleground map is left, which is
-- after the session has closed. This re-reads identity - never figures - for the
-- session just played, so its rows stop saying "Frost Mage" and say who it was.
function Live:FillNames()
    local db = ns.db
    if not (db and db.live) then return end

    local newest
    for key, record in pairs(db.live) do
        if record.closed and (not newest or key > newest.key) then newest = record end
    end
    if not (newest and Readable()) then return end

    local map = Columns()[1]
    if not map then return end
    local session = PlainTable(Call(DM and DM.GetCombatSessionFromType, OVERALL, map.type))
    local list = session and PlainTable(session.combatSources)
    if not list then return end

    local filled = 0
    for i = 1, #list do
        local src = PlainTable(list[i])
        local guid = src and Plain(src.sourceGUID)
        local unit = guid and newest.units[guid]
        if unit then
            local name = Plain(src.name)
            if type(name) == "string" and name ~= "" then
                secretNames[guid] = nil
                if Rename(newest, unit, name) then filled = filled + 1 end
            end
        end
    end

    if filled > 0 then
        cacheCache[newest.key] = nil
        ns:LiveChanged(newest.key)
        ns:Debug("live names filled", newest.key, filled)
    end
end

--------------------------------------------------------------------------------
-- The cache-shaped view
--
-- Everything downstream - the roster, the breakdowns, the grid - already reads a
-- built cache. Rather than teach all of it about a second source, a live record
-- is presented in the same shape, so the viewer draws it with the code it
-- already has and the merge is a change of source, not of layout.
--------------------------------------------------------------------------------

-- A row whose name is still secret is labelled by what can be read: its spec,
-- and enough of its GUID to stay distinct while several of them are on screen.
local function LabelFor(guid, unit)
    if unit.name and unit.name ~= "" then return unit.name end
    local spec = SpecFromIcon(unit.specIcon)
    local what = (spec and spec.name) or unit.class or "Unknown"
    local tail = tostring(guid):match("(%w%w%w%w)$") or "?"
    return ("%s #%s"):format(what, tail)
end

function Live:Cache(key)
    local db = ns.db
    local record = db and db.live and db.live[key]
    if not record then return nil end

    local hit = cacheCache[key]
    if hit then return hit end

    local names, indexOf = {}, {}
    local function Intern(name)
        local at = indexOf[name]
        if at then return at end
        names[#names + 1] = name
        indexOf[name] = #names
        return #names
    end

    -- Units in descending damage, which is the order a built cache stores and
    -- the order the grid expects before it sorts.
    local damageCol = Columns()[1] and Columns()[1].col or 1
    local order = {}
    for _, guid in ipairs(record.unitOrder) do
        if record.units[guid] then order[#order + 1] = guid end
    end
    table.sort(order, function(a, b)
        local av = record.units[a].cols[damageCol] or 0
        local bv = record.units[b].cols[damageCol] or 0
        if av == bv then return a < b end
        return av > bv
    end)

    -- Every unit's own label first, in order: a built cache has N[i] naming U[i],
    -- so a counterpart interned between two units would rename a row - and so
    -- would two units sharing a label, since both would point at the first.
    for _, guid in ipairs(order) do
        local label = LabelFor(guid, record.units[guid])
        if indexOf[label] then
            label = ("%s #%s"):format(label, tostring(guid):match("(%w%w%w%w)$") or "?")
        end
        Intern(label)
    end

    local U, SP, SX = {}, {}, {}
    for _, guid in ipairs(order) do
        local unit = record.units[guid]

        local flags = (unit.kind == "player") and FLAG_PLAYER or FLAG_NPC
        -- Friendly and hostile rather than team numbers: the roster derives sides
        -- from reaction when there is no scoreboard yet, which is the case for
        -- every match still being played.
        -- Failing the meter's own ally/enemy marking - which is not always there
        -- for a unit first seen mid-fight - the faction it reported against the
        -- recording player's own. Wrong under mercenary mode, which is why it is
        -- the fallback and not the rule.
        local ally = unit.ally
        if ally == nil and unit.faction and record.faction then
            ally = (unit.faction == record.faction)
        end
        if ally == false then flags = flags + FLAG_HOSTILE
        elseif ally == true or unit.isPlayer then flags = flags + FLAG_FRIENDLY end

        -- Dense, not sparse: a built cache stores a value for every column, and
        -- the roster's activity check walks 1..#cols. With holes in it, `#` stops
        -- early and a healer who dealt no damage would drop out of the roster.
        local cols, counts, b, s = {}, {}, {}, {}
        for col = 1, #(ns.FORMAT_COLUMNS or {}) do
            cols[col] = unit.cols[col] or 0
            counts[col] = 0
        end

        -- Counterparts, and the spells that landed on each of them. Both come
        -- from the meter's own per-target figures, in the same flat encoding a
        -- built cache uses: name, value, count for a counterpart; name, spell,
        -- value, count, least, most for a use. The meter reports no counts and no
        -- extremes, so those are zero rather than invented.
        for col, parts in pairs(unit.parts or {}) do
            local flat, uses = {}, {}
            for who, entry in pairs(parts) do
                if (entry.v or 0) > 0 then
                    local at = Intern(who)
                    flat[#flat + 1] = at
                    flat[#flat + 1] = entry.v
                    flat[#flat + 1] = 0

                    for id, value in pairs(entry.s or {}) do
                        if value > 0 then
                            SP[id] = SP[id] or SpellName(id) or ("spell " .. id)
                            SX[id] = id
                            uses[#uses + 1] = at
                            uses[#uses + 1] = id
                            uses[#uses + 1] = value
                            uses[#uses + 1] = 0
                            uses[#uses + 1] = 0
                            uses[#uses + 1] = 0
                        end
                    end
                end
            end
            if #flat > 0 then b[col] = flat end
            if #uses > 0 then s[col] = uses end
        end

        U[#U + 1] = {
            f = flags, l = 0, c = cols, n = counts,
            b = b, s = s, m = {},
            guid = guid,
        }
    end

    local cache = {
        live    = true,
        header  = {
            startTime  = record.startedAt,
            endTime    = record.endedAt or record.updatedAt or record.startedAt,
            type       = record.type,
            mapName    = record.mapName,
            rated      = record.rated,
            round      = record.round,
            instanceId = record.map,
            character  = record.character,
            characterGuid = record.characterGuid,
            live       = true,
        },
        N = names, U = U, SP = SP, SX = SX,
        -- Names the columns without a version: the column list is what the viewer
        -- reads from here, and claiming a defines version would make this look
        -- like a built cache to anything checking whether one is current.
        FORMAT = { columns = ns.FORMAT_COLUMNS, live = true },
        unitCount = #U, eventCount = 0,
    }
    cacheCache[key] = cache
    return cache
end

-- The recorder's match table while the match is open, and the stored record
-- afterwards. Same table either way as far as the viewer is concerned.
function Live:MatchFor(key)
    local open = matchRefs[key]
    if open then return open end
    for _, record in ipairs((ns.db and ns.db.matches) or {}) do
        if record.live == key then return record end
    end
    return nil
end

-- Live sessions the user can look at, in the shape GetViewable returns. Anything
-- a built session has replaced is already gone by the time this is asked.
function Live:Viewable()
    local db = ns.db
    if not (db and db.live) then return {} end

    local out = {}
    for key, record in pairs(db.live) do
        out[#out + 1] = {
            key = key, cached = true, live = true,
            pending = not record.closed and "recording" or "awaiting log",
            startTime = record.startedAt,
            endTime = record.endedAt or record.updatedAt,
            type = record.type, mapName = record.mapName,
            rated = record.rated, round = record.round,
            instanceId = record.map,
            character = record.character, characterGuid = record.characterGuid,
            units = record.unitOrder and #record.unitOrder or 0,
            events = 0,
        }
    end
    return out
end

-- The log-built session for this match has arrived: the stand-in is deleted,
-- from the saved file as well as from memory, and where it went is remembered
-- for the rest of this session. Returns whether anything was removed.
--
-- The record being recorded is never replaced, whatever claims to cover it: its
-- match is still going, so a cache that seems to cover it is a mistake in the
-- matching, not the real thing.
function Live:Supersede(key, successor)
    local db = ns.db
    if not (db and db.live and db.live[key]) then return false end
    if current and current.key == key then return false end

    db.live[key] = nil
    cacheCache[key] = nil
    matchRefs[key] = nil
    successors[key] = successor
    ns:Debug("live session superseded", key, successor)
    return true
end

function Live:Successor(key)
    return key and successors[key] or nil
end

-- The withheld name for one row of one live session, for display only.
--
-- Nil once the row has a name read against its GUID, so a font string is only
-- ever handed a secret where there is nothing better to show. A name matched by
-- class is not that: the secret is the game's own account of who the row is and
-- the class match is a guess, so the secret wins.
function Live:SecretName(key, guid)
    local record = key and ns.db and ns.db.live and ns.db.live[key]
    local unit = record and guid and record.units[guid]
    if not unit then return nil end
    if unit.name and unit.nameBy ~= "class" then return nil end
    return secretNames[guid]
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

-- Combat dropping is the only moment the meter can be read, so it is the only
-- moment the display can move. In a battleground that is every fight.
local function OnCombatEnd()
    if not current then return end
    -- A frame later: the restriction is released during the event, and reading
    -- inside the dispatch can still come back secret.
    C_Timer.After(0, function() Live:Sample("combat") end)
end

function Live:Init()
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", OnCombatEnd)

    -- Handlers are called as fn(event, ...), so the payload starts at the second
    -- argument. RegisterEvent reports an unavailable event itself.
    ns:RegisterEvent("ADDON_RESTRICTION_STATE_CHANGED", function(_, rtype, state)
        rtype, state = Plain(rtype), Plain(state)
        if not (Enum and Enum.AddOnRestrictionType) then return end
        if rtype == Enum.AddOnRestrictionType.Combat and state == 0 then
            OnCombatEnd()
        elseif rtype == Enum.AddOnRestrictionType.Map and state == 0 then
            -- The map restriction is what withholds enemy names.
            C_Timer.After(0, function() Live:FillNames() end)
        end
    end)

    -- Another addon clearing the meter is not a problem in itself - the banked
    -- figures survive it - but reading right afterwards keeps the loss to
    -- whatever happened since the last read rather than since the last fight.
    ns:RegisterEvent("DAMAGE_METER_RESET", function()
        if not current then return end
        -- Counted because it is the one thing that costs this session accuracy:
        -- whatever happened between the last reading and the clear is gone, and a
        -- session that disagrees with the log is worth being able to explain.
        current.resets = (current.resets or 0) + 1
        C_Timer.After(0, function() Live:Sample("meter-reset") end)
    end)
end

-- At login. A record still open from a reload is left alone: the recorder opens
-- the match again a moment later and Begin adopts it. One left open by a logout
-- is closed, because nothing is going to add to it now.
function Live:Restore()
    local db = ns.db
    if not (db and db.live) then return end

    for _, record in pairs(db.live) do
        if not record.closed
           and (ns:Now() - (record.updatedAt or record.startedAt or 0)) >= RESUME_WINDOW then
            record.closed = true
        end
    end
    self:FillNames()
end
