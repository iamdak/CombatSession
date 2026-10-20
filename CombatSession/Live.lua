-- CombatSession: live session data from the game's own damage meter.
--
-- The advanced combat log is still the authority. This fills the gap before it
-- arrives: from the moment a match starts, the client's damage meter can be read
-- for what everyone in it has done, and that is shown under the same session
-- boundaries the log will later be cut into, so the row a player is looking at
-- is filled in rather than replaced when the real data lands.
--
-- Three things about the meter shape everything here:
--
--   * It keeps a segment per combat, numbered as they open, alongside a running
--     total. A match is read as the sum of the segments that opened during it -
--     see "Segments" below for why not the running total, which is what this
--     used to read and which counted a rematch twice.
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
-- Once the match completes, Damage Done and Healing Done are the scoreboard's own
-- figures, joined by GUID: that window is what everything is compared against,
-- and the recorder has it in hand by then. What the meter said is kept beside it
-- in the match record (liveCheck), so how far the two disagree is measured on
-- every match rather than assumed.

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

-- What is kept per unit while a match is being added up, before the trim to what
-- is shown. Wider, because these are sums across segments: a counterpart trimmed
-- away after one fight and back on top after the next would otherwise come back
-- short by whatever the first fight said.
local KEEP_PARTS  = 16
local KEEP_SPELLS = 8

-- A reading after a fight is spread over as many frames as it needs, this many
-- milliseconds at a time.
--
-- It used to be taken in one go, and a deep one walks every spell the meter holds
-- against every target it landed on for the whole match so far - which grows for
-- as long as the match does, so the stall on leaving combat grew with it. The
-- figures cannot move between frames out of combat, so reading them across several
-- gives the same answer as reading them in one; if a fight starts partway, the
-- rest waits for the next reading. A source is always read whole: the pause comes
-- between one source and the next, never inside one.
local SLICE_MS = 4

-- Set while a reading is being spread out, to the moment the current frame's
-- share runs out. Nil otherwise, which is what makes Breathe a no-op for the
-- readings that have to be taken whole.
local sliceUntil

-- The reading being spread over frames, and the session it is reading into.
local reading, readingFor
-- Which spread reading the frame timers belong to. A reading dropped and
-- replaced within one frame would otherwise leave two timer chains driving the
-- new coroutine, each resuming it once a frame.
local generation = 0
-- Its cost so far, for the debug line that reports it.
local readingMs, readingFrames = 0, 0
-- When the last spread reading finished having read something.
local lastReadAt = -math.huge

-- Only the spread reading yields. A whole reading taken from inside somebody
-- else's coroutine must run to the end in that frame, not hand control back to
-- a caller expecting a spread one.
local function Breathe()
    if sliceUntil and reading and coroutine.running() == reading
       and debugprofilestop() > sliceUntil then
        coroutine.yield()
    end
end

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
-- Everything a match has added up so far lives in its saved record, segment by
-- segment, so a reload keeps it and nothing here has to be rebuilt.
--------------------------------------------------------------------------------

local current            -- the open record, or nil
local matchRefs = {}     -- live key -> the recorder's in-progress match table
local cacheCache = {}    -- live key -> the cache-shaped view, rebuilt on change

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

    -- Asked while the match runs: the group is gone by the time the last reading
    -- is taken, and whoever was in it is the clearest answer to which side a row
    -- is on that the meter itself leaves blank.
    if not unit.inGroup and Plain(Call(_G.IsGUIDInGroup, guid)) then
        unit.inGroup = true
    end

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

-- Drops all but the largest, so one match cannot fill the saved file with the
-- itemisation of every spell landed on every player.
local function Trim(map, keep, valueOf)
    local order = {}
    for k, entry in pairs(map) do order[#order + 1] = { k, valueOf(entry) } end
    if #order <= keep then return end
    table.sort(order, function(a, b) return a[2] > b[2] end)
    for i = keep + 1, #order do map[order[i][1]] = nil end
end

local function PartValue(entry) return entry.v or 0 end
local function PlainValue(value) return value or 0 end

-- Counterpart maps are col -> who -> { v = total, s = { spell -> amount } }.
local function AddParts(into, from)
    for col, byWho in pairs(from or {}) do
        local dest = into[col]
        if not dest then dest = {}; into[col] = dest end
        for who, part in pairs(byWho) do
            local d = dest[who]
            if not d then d = { v = 0, s = {} }; dest[who] = d end
            d.v = d.v + (part.v or 0)
            for id, amount in pairs(part.s or {}) do d.s[id] = (d.s[id] or 0) + amount end
        end
    end
end

local function TrimParts(parts, keepParts, keepSpells)
    for _, byWho in pairs(parts) do
        Trim(byWho, keepParts, PartValue)
        for _, part in pairs(byWho) do Trim(part.s, keepSpells, PlainValue) end
    end
end

--------------------------------------------------------------------------------
-- Segments
--
-- This used to read the meter's running total and subtract a reading taken at
-- the gates, which works for anyone whose row is readable at the gates and for
-- nobody else. An opponent's is not, so their starting point was taken as
-- nothing - and an opponent met earlier the same evening had both matches
-- counted. Against the final scoreboards of eight arenas on 2026-10-13, the four
-- rematches read 117-678% of the scoreboard, each figure the sum of the two
-- matches to within 3%, while the recording player's own side read 92-101%.
--
-- A segment cannot carry what happened before it opened, so a match is the sum of
-- the segments that opened during it, each held under its id so that reading one
-- twice replaces what it said instead of adding to it. Leaving the instance or
-- completing the match caps the range: a fight at a target dummy in Silvermoon
-- opens a segment of its own past the cap, where it used to be folded into the
-- match by whichever reading came after it.
--
-- One segment needs care: the newest one at the gates. Details! records the
-- segment it settles on for each arena, and for one character 196 of 332 of
-- those are named after a different arena or a creature, so whether a segment can
-- run on from one match into the next is not something anything on disk settles.
-- That segment is read at the gates and only its growth counts, without a
-- breakdown; if any of its rows cannot be read then, it is left out instead,
-- because a row with no starting point is exactly the fault described above.
--
-- Ids mean something only until the meter is cleared - by another addon, or by a
-- relog - so each clear starts a new epoch, and anything still open from the one
-- before is kept as last read.
--------------------------------------------------------------------------------

-- The meter's segment ids, oldest first.
local function SegmentIds()
    local ids = {}
    local list = PlainTable(Call(DM and DM.GetAvailableCombatSessions))
    if not list then return ids end
    for i = 1, #list do
        local entry = PlainTable(list[i])
        local id = entry and Plain(entry.sessionID)
        if type(id) == "number" then ids[#ids + 1] = id end
    end
    table.sort(ids)
    return ids
end

local function SegKey(record, id)
    return (record.epoch or 1) .. ":" .. id
end

-- Whether a segment of the current epoch belongs to the record's match.
local function InRange(record, id)
    local epoch = record.epoch or 1
    if record.capEpoch then
        if epoch > record.capEpoch then return false end
        if epoch == record.capEpoch and id > record.cap then return false end
    end
    local from = (epoch == (record.fromEpoch or 1)) and (record.from or 0) or 0
    return id >= from
end

-- The counterparts of one column for one source in one segment, and which spells
-- landed on each. The meter reports a spell's per-target amounts, so this is its
-- own account of who was hit with what - nothing is apportioned or guessed at.
local function ReadParts(id, meterType, guid, creature)
    local source = PlainTable(Call(DM.GetCombatSessionSourceFromID, id, meterType, guid, creature))
    local spells = source and PlainTable(source.combatSpells)
    if not spells then return nil end

    local parts = {}
    for j = 1, #spells do
        local spell = PlainTable(spells[j])
        local spellId = spell and Plain(spell.spellID)
        local details = spellId and PlainTable(spell.combatSpellDetails)
        if details then
            -- Documented as one structure, named and used as a list; both are
            -- accepted.
            local rows = details
            if not IsList(details) then rows = { details } end
            for k = 1, #rows do
                local row = PlainTable(rows[k])
                local who = row and Plain(row.unitName)
                local amount = row and Plain(row.amount)
                if who and who ~= "" and amount then
                    local part = parts[who]
                    if not part then part = { v = 0, s = {} }; parts[who] = part end
                    part.s[spellId] = (part.s[spellId] or 0) + amount
                    part.v = part.v + amount
                end
            end
        end
    end
    return parts
end

-- Rows the meter will not name.
--
-- Since 12.1.5 a row's sourceGUID is secret whenever its unit's identity is, and
-- an enemy player's identity stays secret until the map is left. Keyed by GUID,
-- every enemy row was dropped for the whole match - a rated Twin Peaks showed its
-- ten allies throughout and its ten enemies only twelve seconds after leaving.
-- The total beside the GUID is not secret, so such a row is kept as part of a
-- WITHHELD GROUP: every row of one side, class and spec, summed - what can be
-- said about them without telling apart two players the meter will not name. A
-- group of one carries its name as the secret value, which a font string draws.
--
-- A segment holding any is never settled early: once the map is left the same
-- segment is read again by GUID, and the group gives way to the real rows.
--
-- A pet or guardian carries its owner's class and no spec, so it is told apart
-- by its creature id - or, where that is withheld too, by having no spec - and
-- grouped apart from the players: listed as one, it was a phantom enemy, and it
-- made its owner's class look twice-taken to the scoreboard naming.
local function AnonKey(src)
    local display = Plain(src.sourceDisplayType)
    local side = (display == 1 or display == 2) and display or 0
    local class = Plain(src.classFilename)
    if type(class) ~= "string" then class = "" end
    local spec = Plain(src.specIconID)
    if type(spec) ~= "number" then spec = 0 end
    local creatureId = Plain(src.sourceCreatureID)
    local creature
    if type(creatureId) == "number" then
        creature = creatureId ~= 0
    else
        creature = (spec == 0)
    end
    return ("Anon-%d-%s-%s-%d"):format(side, creature and "c" or "p", class, spec),
           side, class, spec, creature
end

-- `segs` counts the segments a group was read from: two players of one spec who
-- never fought in the same segment read as one row of one in each, and only one
-- segment's group of one is known to be one player.
local function AddAnon(into, akey, side, class, spec, creature, col, total, rows, segs)
    local group = into[akey]
    if not group then
        group = { side = side, class = class, spec = spec, creature = creature,
                  n = 0, segs = segs or 1, cols = {} }
        into[akey] = group
    end
    group.cols[col] = (group.cols[col] or 0) + total
    if rows > group.n then group.n = rows end
end

local function MergeAnon(into, from)
    for akey, g in pairs(from or {}) do
        local had = into[akey]
        for col, total in pairs(g.cols) do
            AddAnon(into, akey, g.side, g.class, g.spec, g.creature, col, total, g.n, g.segs)
        end
        if had and into[akey] then
            into[akey].segs = (had.segs or 1) + (g.segs or 1)
        end
    end
end

-- One segment, every column the meter fills: guid -> { cols, parts }. `complete`
-- says every row could be keyed; one that could not is read again later rather
-- than settled on. `any` says the segment held anything at all. `anon` is its
-- withheld groups, akey -> { side, class, spec, n, cols }.
--
-- record.diag, when present, counts what the first column held: rows kept,
-- rows withheld by name only, rows hidden outright, and the withheld rows' sides
-- as the meter marked them - the record that says what the meter gave, rather
-- than what this code made of it.
local function ReadSegment(record, id)
    local seg, complete, any, anon = {}, true, false, {}
    local diag = record.diag
    -- The segment carried over from before the gates counts only its growth, and
    -- a withheld row has no starting point to take it from: it would bring a
    -- rematched opponent's whole earlier match with it. Such rows wait for their
    -- GUID, as the carry's own reading does.
    local carried = record.carry and record.carry[SegKey(record, id)]
    for c, map in ipairs(Columns()) do
        local session = PlainTable(Call(DM.GetCombatSessionFromID, id, map.type))
        local list = session and PlainTable(session.combatSources)
        if list then
            local counted = {}
            for i = 1, #list do
                Breathe()
                local src = PlainTable(list[i])
                local guid = src and Plain(src.sourceGUID)
                local total = src and Plain(src.totalAmount)
                if guid and total then
                    UnitFor(record, guid, src)
                    any = true
                    local entry = seg[guid]
                    if not entry then entry = { cols = {}, parts = {} }; seg[guid] = entry end
                    entry.cols[map.col] = total
                    local parts = ReadParts(id, map.type, guid, Plain(src.sourceCreatureID))
                    if parts then
                        entry.parts[map.col] = parts
                        TrimParts(entry.parts, KEEP_PARTS, KEEP_SPELLS)
                    end
                    if diag and c == 1 then diag.kept = diag.kept + 1 end
                else
                    complete = false
                    if src and type(total) == "number" and not carried then
                        local akey, side, class, spec, creature = AnonKey(src)
                        counted[akey] = (counted[akey] or 0) + 1
                        AddAnon(anon, akey, side, class, spec, creature, map.col, total, counted[akey])
                        any = true
                        -- The secret itself, for display: only while it is the
                        -- one row of its kind, since two cannot be told apart.
                        -- Filed under the record as well as the group, which
                        -- recurs - a lobby's next round has its own Frost Mage.
                        local named = (record.key or "") .. "|" .. akey
                        if counted[akey] == 1 then
                            secretNames[named] = src.name
                        else
                            secretNames[named] = nil
                        end
                        if diag and c == 1 then
                            diag.withheld = diag.withheld + 1
                            diag.sides[side] = (diag.sides[side] or 0) + 1
                            if class ~= "" then diag.classed = diag.classed + 1 end
                        end
                    elseif diag and c == 1 then
                        diag.hidden = diag.hidden + 1
                    end
                end
            end
        end
    end
    return seg, complete, any, anon
end

-- The newest segment at the gates, read whole: guid -> col -> total. Nil when a
-- row cannot be read, which leaves that segment out of the match altogether.
local function ReadCarry(id)
    local carry = {}
    for _, map in ipairs(Columns()) do
        local session = PlainTable(Call(DM.GetCombatSessionFromID, id, map.type))
        local list = session and PlainTable(session.combatSources)
        for i = 1, (list and #list or 0) do
            local src = PlainTable(list[i])
            local guid = src and Plain(src.sourceGUID)
            local total = src and Plain(src.totalAmount)
            if not (guid and total) then return nil end
            carry[guid] = carry[guid] or {}
            carry[guid][map.col] = total
        end
    end
    return carry
end

-- A breakdown less an earlier reading of the same one: what each counterpart,
-- and each spell on it, gained since. Counterpart maps as in AddParts.
local function PartsGrowth(now, before)
    if not before then return now end
    local out = {}
    for col, byWho in pairs(now or {}) do
        local earlier = before[col] or {}
        for who, part in pairs(byWho) do
            local was = earlier[who]
            local v = (part.v or 0) - (was and was.v or 0)
            if v > 0 then
                local s = {}
                for id, amount in pairs(part.s or {}) do
                    local grew = amount - (was and was.s and was.s[id] or 0)
                    if grew > 0 then s[id] = grew end
                end
                out[col] = out[col] or {}
                out[col][who] = { v = v, s = s }
            end
        end
    end
    return out
end

-- What a segment's reading adds for one unit: its figures, less what the segment
-- already held at the gates if it is the one carried over.
local function Grown(record, key, guid, entry, into, parts)
    local carry = record.carry and record.carry[key]
    local base = carry and carry[guid]
    for col, total in pairs(entry.cols) do
        local grew = total - (base and base[col] or 0)
        if grew > 0 then into[col] = (into[col] or 0) + grew end
    end
    if not parts then return end
    if not carry then
        AddParts(parts, entry.parts)
        return
    end
    -- A breakdown can only be carried when its starting point was read too,
    -- which a bout's baseline is and a match's gates reading is not; without
    -- one the carried segment contributes figures only.
    local before = record.carryParts and record.carryParts[key]
    if before then AddParts(parts, PartsGrowth(entry.parts, before[guid])) end
end

-- A segment is settled: what it said joins each unit's running sum, and it is
-- never read again.
local function Fold(record, key)
    local seg = record.open and record.open[key]
    if seg then
        for guid, entry in pairs(seg) do
            local unit = record.units[guid]
            if unit then
                local fold = unit.fold
                if not fold then fold = { cols = {}, parts = {} }; unit.fold = fold end
                Grown(record, key, guid, entry, fold.cols, fold.parts)
                TrimParts(fold.parts, KEEP_PARTS, KEEP_SPELLS)
            end
        end
        record.open[key] = nil
    end
    -- A segment settled with rows still withheld keeps them as groups: one closed
    -- between a lobby's rounds, or cut short by the meter being cleared, is never
    -- read again by name, so the groups are the best there is of those rows -
    -- until a fully keyed scoreboard names everyone and they give way (see
    -- AdoptRoster), its Damage and Healing standing in for theirs.
    local anon = record.openAnon and record.openAnon[key]
    if anon then
        record.anonFold = record.anonFold or {}
        MergeAnon(record.anonFold, anon)
        record.openAnon[key] = nil
    end
    if record.carry then record.carry[key] = nil end
    if record.carryParts then record.carryParts[key] = nil end
    record.done = record.done or {}
    record.done[key] = true
end

-- The meter was cleared: the ids before it are gone and the next ones may reuse
-- their numbers. What was still open is kept as last read.
local function NewEpoch(record)
    for key in pairs(record.open or {}) do Fold(record, key) end
    record.epoch = (record.epoch or 1) + 1
    record.maxSeen = 0
end

-- Each unit's figures as shown: everything settled, plus the latest reading of
-- every segment still open, and the scoreboard's own figure where it has one.
-- `meterOnly` leaves the scoreboard out, which is how the two are compared.
local function Recompute(record, meterOnly)
    for guid, unit in pairs(record.units) do
        local fold = unit.fold
        if not fold then
            -- A record from before segments were read: what it holds already is
            -- its settled sum.
            fold = { cols = unit.cols or {}, parts = unit.parts or {} }
            unit.fold = fold
        end
        local cols, parts = {}, {}
        for col, value in pairs(fold.cols) do cols[col] = value end
        AddParts(parts, fold.parts)
        for key, seg in pairs(record.open or {}) do
            local entry = seg[guid]
            if entry then Grown(record, key, guid, entry, cols, parts) end
        end
        local board = not meterOnly and record.board and record.board[guid]
        if board then
            for col, value in pairs(board) do cols[col] = value end
        end
        TrimParts(parts, MAX_PARTS, MAX_SPELLS_PER_PART)
        unit.cols, unit.parts = cols, parts
    end

    -- The withheld groups as shown: settled ones and the latest reading of every
    -- open segment. None once the scoreboard has named everyone; see AdoptRoster.
    local anon = {}
    if not record.anonRetired then
        MergeAnon(anon, record.anonFold)
        for _, groups in pairs(record.openAnon or {}) do MergeAnon(anon, groups) end
    end
    record.anon = next(anon) and anon or nil
end

-- Caps the segments a session can take at the newest one there is now. Leaving
-- and completion both call it; whichever comes first holds.
local function Cap(record, why)
    if record.capEpoch then return end
    local ids = SegmentIds()
    record.cap = ids[#ids] or 0
    record.capEpoch = record.epoch or 1
    record.capWhy = why
end

-- Where a new session starts counting: past every segment that exists now, except
-- that the newest is carried if it can be read whole.
local function StartSegments(record)
    local ids = SegmentIds()
    local newest = ids[#ids]
    record.epoch, record.fromEpoch = 1, 1
    record.maxSeen = newest or 0
    record.open, record.done, record.carry = {}, {}, nil
    record.from = 0
    if newest then
        local carry = Readable() and ReadCarry(newest) or nil
        if carry then
            record.from = newest
            record.carry = { [SegKey(record, newest)] = carry }
        else
            record.from = newest + 1
        end
    end
end

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
    -- A withheld group of one enemy is a candidate the same way - and a group of
    -- several, though it cannot be named, still counts against its class, or the
    -- one named player could be any of them.
    for akey, group in pairs(record.anon or {}) do
        if group.side == 2 and group.class ~= "" and not group.creature then
            local list = unnamed[group.class] or {}
            unnamed[group.class] = list
            for _ = 1, group.n do list[#list + 1] = (group.n == 1) and akey or false end
        end
    end

    local named = 0
    record.anonNames = record.anonNames or {}
    for class, units in pairs(unnamed) do
        local names = pool[class]
        if #units == 1 and names and #names == 1 then
            local only = units[1]
            if type(only) == "string" then
                if record.anonNames[only] ~= names[1] then
                    record.anonNames[only] = names[1]
                    named = named + 1
                end
            elseif only and Rename(record, only, names[1], true) then
                named = named + 1
            end
        end
    end
    return named
end

-- The reading itself, into `record`: every segment of the match not yet settled.
-- Returns whether anything was read.
local function Read(record, reason)
    if not (DM and DM.GetCombatSessionFromID) then return false end
    record.open = record.open or {}
    record.done = record.done or {}

    local ids = SegmentIds()
    local newest = ids[#ids] or 0
    -- Ids going backwards means the meter was cleared without saying so - a relog
    -- does it - which is the same as being told.
    if newest < (record.maxSeen or 0) then NewEpoch(record) end
    if newest > (record.maxSeen or 0) then record.maxSeen = newest end

    -- At the end of the match everything is settled whatever state it is in:
    -- nothing more is coming for any of it.
    local final = (reason == "finish")
    local present, read = {}, false
    record.diag = { reason = reason, kept = 0, withheld = 0, hidden = 0, classed = 0, sides = {} }
    for _, id in ipairs(ids) do
        local key = SegKey(record, id)
        present[key] = true
        if InRange(record, id) and not record.done[key] then
            local seg, complete, any, anon = ReadSegment(record, id)
            if any then
                record.open[key] = seg
                -- Replaced, not added to: the same rows read again, now perhaps
                -- by name, take the place of what they were read as before.
                record.openAnon = record.openAnon or {}
                record.openAnon[key] = next(anon) and anon or nil
                read = true
            end
            -- The newest segment may still be growing, and one with a row that
            -- could not be keyed may be readable next time.
            if final or (id < newest and complete) then Fold(record, key) end
        end
    end
    -- Gone from the meter without being settled - another addon cleared it - so
    -- what was last read of it is all there will be.
    for key in pairs(record.open) do
        if final or not present[key] then Fold(record, key) end
    end

    Recompute(record)

    -- The most the meter withheld in any one reading, kept beside the latest.
    local most = record.diagMost
    if not most or record.diag.withheld > most.withheld then record.diagMost = record.diag end

    -- Not for a lobby's rounds: teams are redrawn between them, and whether the
    -- scoreboard's sides follow the current round is not something that has been
    -- measured. A wrong side would name players after their own teammates. Nor
    -- for a bout, which has no scoreboard.
    if not (record.round or record.bout) then NamesFromScoreboard(record) end
    -- Asked for after every reading, so the next one works from a scoreboard no
    -- older than the last fight.
    Call(_G.RequestBattlefieldScoreData)

    record.updatedAt = ns:Now()
    record.samples = (record.samples or 0) + 1
    record.reason = reason
    cacheCache[record.key] = nil
    ns:LiveChanged(record.key)
    return read
end

local function StopReading()
    generation = generation + 1
    reading, readingFor = nil, nil
end

-- One frame's share of a spread reading, and the next frame booked if it is not
-- finished. `gen` is the reading this call was booked for; a later one has its
-- own chain.
local function Continue(gen)
    local co = reading
    if not co or gen ~= generation then return end

    -- Abandoned rather than finished when the session it was reading into is no
    -- longer the one being recorded: the baselines it would write into belong to
    -- the next session now. And when a fight has started, because the figures are
    -- secret again - the next reading after that fight covers what was left.
    if readingFor ~= current or not current or current.closed or not Readable() then
        StopReading()
        return
    end

    local started = debugprofilestop()
    sliceUntil = started + SLICE_MS
    local ok, result = coroutine.resume(co)
    sliceUntil = nil
    readingMs = readingMs + (debugprofilestop() - started)
    readingFrames = readingFrames + 1

    if not ok then
        StopReading()
        -- A coroutine hands its error back instead of raising it, and one that
        -- is not raised is one nobody sees. With its own stack, which the
        -- message alone does not carry.
        geterrorhandler()(debug.traceback(co, tostring(result)))
        return
    end
    if coroutine.status(co) ~= "dead" then
        C_Timer.After(0, function() Continue(gen) end)
        return
    end

    StopReading()
    if result then lastReadAt = GetTime() end
    ns:Debug(("live reading: %.1fms over %d frame(s)"):format(readingMs, readingFrames))
end

-- Readings that open or close a session are taken whole and at once: the one at
-- logout has no later frame to finish in, and the one at completion is what the
-- scoreboard is compared against. Anything already being spread out is dropped
-- in favour of them - they read everything it would have.
--
-- The rest are spread out. Leaving combat is announced twice - the regen event
-- and the restriction lifting - and a reading that has just finished, or is
-- still going, already covers the second one.
local SPREAD = { combat = true, ["meter-reset"] = true }

function Live:Sample(reason)
    local record = current
    if not record or record.closed then return false end
    if not Readable() then return false end

    if not SPREAD[reason] then
        StopReading()
        local started = debugprofilestop()
        local read = Read(record, reason)
        ns:Debug(("live reading (%s): %.1fms"):format(tostring(reason), debugprofilestop() - started))
        return read
    end

    if reading or GetTime() - lastReadAt < 1 then return true end

    generation = generation + 1
    reading = coroutine.create(function() return Read(record, reason) end)
    readingFor = record
    readingMs, readingFrames = 0, 0
    Continue(generation)
    return true
end

--------------------------------------------------------------------------------
-- Session lifecycle
--
-- Driven by the recorder, so a live session begins and ends exactly where the
-- application will cut the log.
--------------------------------------------------------------------------------

-- Two caps, because there are two kinds of record here.
--
-- A session waiting for its log is a stand-in, and a backlog of stand-ins is of
-- no use to anyone: maxLive of them, and the rest go. A session played with
-- logging off is not waiting for anything - it is the only account of that match
-- there will ever be - so it is kept like a session, up to maxSessions.
--
-- Oldest first within each kind, keys being timestamps.
--
-- Bouts are capped apart from both. A row of the list holds up to a group's worth
-- of them, so the cap is the session cap's worth of full groups; one replaced by
-- its log is deleted on the spot, so this only ever bites on bouts with no log.
local function Prune()
    local db = ns.db
    if not (db and db.live) then return end

    local standins, kept, bouts = {}, {}, {}
    for key, record in pairs(db.live) do
        local into = record.bout and bouts
                  or (record.logged == false) and kept or standins
        into[#into + 1] = key
    end

    local function Drop(keys, limit)
        if #keys <= limit then return end
        table.sort(keys)
        for i = 1, #keys - limit do
            db.live[keys[i]] = nil
            cacheCache[keys[i]] = nil
            matchRefs[keys[i]] = nil
        end
    end

    Drop(standins, db.settings.maxLive or 8)
    Drop(kept, db.settings.maxSessions or 40)
    Drop(bouts, (db.settings.maxSessions or 40) * (tonumber(db.settings.groupCap) or 20))
end

-- `round` opens a session for one round of a Solo Shuffle or Blitz lobby rather
-- than for the whole match, which is how the application cuts the log for them.
function Live:Begin(match, round)
    if not (DM and DM.GetAvailableCombatSessions and DM.GetCombatSessionFromID) then return end

    self:Finish()

    local db = ns.db
    db.live = db.live or {}

    -- Kept until now rather than cleared at the end of a match, so the match just
    -- played still shows its enemies' names until the next one starts.
    wipe(secretNames)

    -- A reload inside a match makes the recorder open the match again, and this
    -- has to follow it without splitting the match in two: a record for the same
    -- instance is continued rather than replaced. Everything it has added up is
    -- in the record, segment by segment, so it simply carries on.
    --
    -- Either still open or closed by the shutdown itself. The second case is the
    -- one a reload actually produces - PLAYER_LOGOUT closes the session before
    -- the reload, and without it the closed half stayed in the list saying
    -- "awaiting log" beside the new one, which is the double entry.
    local resumed
    if not round then
        for _, record in pairs(db.live) do
            if (not record.closed or record.interrupted) and record.map == match.map
               and (ns:Now() - (record.updatedAt or record.startedAt or 0)) < ns.RESUME_WINDOW
               and (not resumed or (record.startedAt or 0) > (resumed.startedAt or 0)) then
                resumed = record
            end
        end
    end

    if resumed then
        current = resumed
        current.closed      = nil
        current.interrupted = nil
        -- A record kept by a build that read the running total has no segment
        -- range. What it holds becomes its settled sum, and it counts on from the
        -- segments that open from here.
        if not current.epoch then StartSegments(current) end
        ns:Debug("live session resumed", resumed.key)
    else
        -- Anything still open at this point was left that way by a logout, and
        -- saying "recording" about a match that ended hours ago is worse than
        -- saying nothing. The mark goes too: a new match starting settles the
        -- question of whether the last one was coming back.
        for _, record in pairs(db.live) do
            record.closed      = true
            record.interrupted = nil
        end

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
        StartSegments(current)
        db.live[key] = current
        Prune()
        ns:Debug("live session opened", key, "from segment", current.from)
    end

    matchRefs[current.key] = match
    match.live = current.key
    current.faction = match.playerFactionGroup or current.faction

    -- Whether this match has a log coming, as the recorder decided it when the
    -- match began - the session's own fact, never the flag as it stands now. A
    -- resumed session keeps what it had. `logging`, which an earlier build set
    -- from readings of the live flag and set wrongly, is ignored and cleared.
    if current.logged == nil then current.logged = match.logged end
    current.logging = nil

    -- Nothing of the match exists yet; this reads whatever the carried segment
    -- has grown by and refreshes identity, which costs nothing when it is empty.
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

-- The column index of a named measure, from the shared format.
local function ColumnIndex(name)
    for i, column in ipairs(ns.FORMAT_COLUMNS or {}) do
        if column == name then return i end
    end
end

-- What the meter said against what the scoreboard says, for every player both
-- name by GUID - kept in the match record, so whether the live figures can be
-- trusted is measured on every match instead of argued about. Totals across the
-- match, and the player furthest out in either direction.
local function CheckAgainstBoard(record, roster)
    local damageCol, healingCol = ColumnIndex("Damage Done"), ColumnIndex("Healing Done")
    if not (damageCol and healingCol and roster) then return nil end

    Recompute(record, true)
    local check = { players = 0, damage = 0, damageBoard = 0, healing = 0, healingBoard = 0 }
    local worst, worstOff
    for _, row in ipairs(roster) do
        local guid = Plain(row.guid)
        local unit = guid and record.units[guid]
        local damage, healing = Plain(row.damage), Plain(row.healing)
        if unit and type(damage) == "number" and type(healing) == "number" then
            local mine = unit.cols[damageCol] or 0
            check.players = check.players + 1
            check.damage = check.damage + mine
            check.damageBoard = check.damageBoard + damage
            check.healing = check.healing + (unit.cols[healingCol] or 0)
            check.healingBoard = check.healingBoard + healing
            if damage > 0 then
                local off = math.abs(mine / damage - 1)
                if not worstOff or off > worstOff then
                    worstOff, worst = off, { name = Plain(row.name), live = mine, board = damage }
                end
            end
        end
    end
    check.worst = worst
    return check
end

-- The scoreboard's own Damage Done and Healing Done, joined by GUID. Only for a
-- whole match: a lobby's scoreboard covers every round, and a round's session
-- shown with the lobby's totals would be wrong by the other five.
local function AdoptBoard(record, roster)
    local damageCol, healingCol = ColumnIndex("Damage Done"), ColumnIndex("Healing Done")
    if record.round or not (damageCol and healingCol and roster) then return end
    record.board = record.board or {}
    for _, row in ipairs(roster) do
        local guid = Plain(row.guid)
        local damage, healing = Plain(row.damage), Plain(row.healing)
        if guid and record.units[guid] and type(damage) == "number" and type(healing) == "number" then
            record.board[guid] = { [damageCol] = damage, [healingCol] = healing }
        end
    end
end

-- Everyone on the final scoreboard gets a row, by the GUID the scoreboard carries
-- by then - which is everyone the meter would not name, ten seconds and more
-- before leaving the map lets it. Side from the scoreboard's own numbering
-- against our own row there, which is exact where the meter's factions are not:
-- a rated battleground can put the same faction on both sides. The meter's own
-- figures join these rows when it can finally read them by GUID; until then the
-- scoreboard's Damage and Healing are theirs, through AdoptBoard.
--
-- The withheld groups give way once every row has its GUID: they were those
-- players, and counting both would count them twice. Returns rows added and
-- whether every scoreboard row could be keyed.
local function AdoptRoster(record, roster)
    if record.round or not roster then return 0, false end

    local own
    for _, row in ipairs(roster) do
        if Plain(row.guid) == record.characterGuid then own = Plain(row.faction) break end
    end
    if own == nil then
        local me = Plain(Call(UnitName, "player"))
        for _, row in ipairs(roster) do
            if Plain(row.name) == me then own = Plain(row.faction) break end
        end
    end

    -- All or nothing. Rows are only added, and the groups only retired, when every
    -- scoreboard row has its GUID: with one missing, the players who were added
    -- would also still be in their groups, and be counted twice.
    local keyed = 0
    for _, row in ipairs(roster) do
        local guid = Plain(row.guid)
        if type(guid) == "string" and guid ~= "" then keyed = keyed + 1 end
    end
    local all = keyed > 0 and keyed == #roster

    local added = 0
    for _, row in ipairs(roster) do
        local guid = Plain(row.guid)
        local unit = type(guid) == "string" and record.units[guid] or nil
        if all and type(guid) == "string" and guid ~= "" and not unit then
            unit = { cols = {}, parts = {}, kind = "player", fromBoard = true }
            record.units[guid] = unit
            record.unitOrder[#record.unitOrder + 1] = guid
            added = added + 1
        end
        if unit then
            local name, class, faction = Plain(row.name), Plain(row.class), Plain(row.faction)
            if type(name) == "string" and name ~= "" and (not unit.name or unit.nameBy == "class") then
                Rename(record, unit, name)
            end
            if type(class) == "string" and class ~= "" and not unit.class then unit.class = class end
            if unit.ally == nil and own ~= nil and faction ~= nil then unit.ally = (faction == own) end
        end
    end

    if all then record.anonRetired = true end
    return added, all
end

-- What the meter gave and what became of it, in the match record: the live record
-- is deleted when the log replaces it, and this is the account of whether the
-- meter withheld anyone and how they were shown.
--
-- A lobby's rounds share one match record, so each round's account is kept under
-- its own number rather than written over the last.
local function Diagnose(record, match, stage, extra)
    if not match then return end
    local diag = match.liveDiag or {}
    match.liveDiag = diag
    if record.round then
        diag.rounds = diag.rounds or {}
        diag.rounds[record.round] = diag.rounds[record.round] or {}
        diag = diag.rounds[record.round]
    end
    diag[stage] = record.diag
    diag.most = record.diagMost
    for k, v in pairs(extra or {}) do diag[k] = v end
end

-- The match is over and its figures are final; only names may still be missing.
function Live:Complete()
    if not current then return end
    self:Sample("complete")
    -- Nothing after this belongs to the match, whatever the meter goes on to
    -- record before the instance is left.
    Cap(current, "complete")

    local match = matchRefs[current.key]
    NamesFromRoster(current, match)
    -- Not for a round: the scoreboard covers the whole lobby.
    if match and match.roster and not current.round then
        local check = CheckAgainstBoard(current, match.roster)
        if check then
            current.liveCheck = check
            match.liveCheck = check
        end
        local added, all = AdoptRoster(current, match.roster)
        AdoptBoard(current, match.roster)
        Diagnose(current, match, "complete",
                 { roster = #match.roster, adopted = added, rosterKeyed = all })
    end
    Recompute(current)

    current.complete = true
    current.endedAt = ns:Now()
    cacheCache[current.key] = nil
    ns:LiveChanged(current.key)
end

-- The instance was left. Caps the session where it stands, so the closing
-- reading - taken after the recorder has made sure the departure is real - can
-- settle the match's own segments and nothing that opened outside it.
function Live:Left()
    if current then Cap(current, "left") end
end

-- The recorder has learned the match is rated, which it can only do once the
-- match is under way. Every session standing for it says so - a Solo Shuffle
-- lobby has one per round - since each copied the flag when it opened.
function Live:SetRated(match)
    local db = ns.db
    if not (db and db.live) then return end
    for key, ref in pairs(matchRefs) do
        local record = db.live[key]
        if ref == match and record and not record.rated then
            record.rated = true
            cacheCache[key] = nil
            ns:LiveChanged(key)
        end
    end
end

-- The departure was a passing zone reading after all, and the match goes on.
function Live:Stayed()
    if current and current.capWhy == "left" then
        current.cap, current.capEpoch, current.capWhy = nil, nil, nil
    end
end

-- `interrupted` says the UI is shutting down rather than that the match ended.
-- The session is closed either way - a logout has to leave nothing open - but
-- marked, so that re-entering the same instance can reopen this one instead of
-- listing a second session beside it.
function Live:Finish(interrupted)
    if not current then return end
    -- A shutdown is not the end of the match: a reload is back in seconds and
    -- carries on from here. Its reading settles nothing, so a segment holding rows
    -- the meter will not name yet is read again - by name - once the map is left.
    self:Sample(interrupted and "interrupt" or "finish")
    current.endedAt = current.endedAt or ns:Now()
    current.closed = true
    current.interrupted = interrupted or nil

    local key = current.key

    -- The naming counts outlive the record. Once the log replaces it, the match
    -- record is the only place left that can say how well enemies were named
    -- before it did. The same table, not a copy, so names filled in when the map
    -- restriction lifts - after this - are counted in it too.
    local match = matchRefs[key]
    if match and current.naming then match.liveNaming = current.naming end
    Diagnose(current, match, interrupted and "interrupted" or "finish")

    -- A round session opened for a round that never happened - the lobby ended on
    -- the one before - holds nothing and would list as an empty row.
    if not next(current.units) and not current.anon then
        ns.db.live[key] = nil
        matchRefs[key] = nil
    elseif not interrupted then
        -- Over for good: what is shown is all that is left to keep. The running
        -- sums and the segment bookkeeping exist so a match can be carried on,
        -- and one closed by anything but a shutdown never is - kept, they would
        -- only make the saved file bigger. The withheld groups as shown stay.
        for _, unit in pairs(current.units) do unit.fold = nil end
        current.open, current.done, current.carry = nil, nil, nil
        current.openAnon, current.anonFold = nil, nil
    end

    current = nil
    cacheCache[key] = nil
    ns:LiveChanged(key)

    -- The match went into the meter too, and the first bout after it is measured
    -- from whatever the baseline holds - which, left alone, was from before it.
    if not interrupted then self:RefreshBaselineSoon() end
end

--------------------------------------------------------------------------------
-- Bouts
--
-- A fight at a PvP training dummy, or with players outside a match: what the
-- meter gained while it lasted.
--
-- The meter does not open a session per fight. On 2026-10-15 three pulls on a
-- Silvermoon dummy all went into session 21, which had been opened forty-two hours
-- earlier by a hit landing just after an arena ended - it had outlived a logout
-- and two zone changes - and reading only the sessions newer than the last bout's
-- found nothing for the second and third. Sometimes it does open a new one; what
-- decides it is not known. So a bout is measured against a BASELINE: a whole
-- reading of the newest session, taken out of combat, kept current - on entering
-- the world, after every fight, and whenever the meter changes out of combat. A
-- bout is then that session's growth, plus every newer session whole.
--
-- A clear starts everything over: the baseline becomes "nothing", and whatever is
-- in the meter after it belongs to whatever comes next.
--
-- The recorder decides what was a bout, freezes the baseline when combat starts,
-- and asks for the reading once the meter has settled. The record is closed from
-- the start, there being nothing more to come but its log.
--------------------------------------------------------------------------------

-- The current baseline: { id, epoch, cols = guid -> col -> total, parts = guid ->
-- counterparts }, or nil until one has been read. Replaced, never changed in
-- place, so a bout can hold the one it started with.
local baseline
-- Counts clears of the meter, so a baseline taken before one is known to be stale.
local meterEpoch = 0

-- Whether the meter's figures can be read now, which is out of combat.
function Live:CanRead()
    return DM ~= nil and Readable()
end

-- Whether the newest session reads in full: no row of it still withheld. The
-- restriction can lift a moment before the figures do, which is why Details!
-- polls the rows themselves after a fight rather than trusting the flag.
function Live:Settled()
    if not self:CanRead() then return false end
    local ids = SegmentIds()
    local newest = ids[#ids]
    if not newest then return true end
    for _, map in ipairs(Columns()) do
        local session = Call(DM.GetCombatSessionFromID, newest, map.type)
        if session ~= nil and not PlainTable(session) then return false end
        local list = session and PlainTable(session.combatSources)
        for i = 1, (list and #list or 0) do
            -- A withheld GUID is not unsettled: it stays withheld for as long as
            -- the unit's identity does, and waiting for it only cost every bout
            -- fought beside an enemy the full fifteen seconds.
            local src = PlainTable(list[i])
            if not (src and Plain(src.totalAmount)) then return false end
        end
    end
    return true
end

-- One session as it stands, for every source and column whose total differs from
-- `known` (guid -> col -> total; nil reads everything): guid -> { cols, parts },
-- the parts untrimmed. A bout is the difference between two readings of a session
-- that may have run for hours, so its breakdown cannot be trimmed to the largest
-- entries before the subtraction - what happened before the fight would crowd the
-- fight's own spells off the list. Reading only what moved is what keeps that
-- affordable: after a fight at a dummy it is the player's few columns, however
-- much else the session holds.
--
-- `complete` is false when anything was withheld: a whole column, a row, or the
-- breakdown behind a total that moved. Not a row whose GUID alone is withheld -
-- an enemy's, while their identity is - which is left out of the baseline and the
-- bout alike, and so costs neither anything.
--
-- `withheld` says such a row was left out. A baseline taken with one cannot
-- tell that player's history from a later bout's, should their GUID become
-- readable, so a reading against it (`strict`) leaves out anyone the baseline
-- does not know rather than charging them with everything before.
local function ReadChanged(record, id, known, strict)
    local seg, complete, withheld = {}, true, false
    for _, map in ipairs(Columns()) do
        local raw = Call(DM.GetCombatSessionFromID, id, map.type)
        local session = PlainTable(raw)
        if raw ~= nil and not session then complete = false end
        local list = session and PlainTable(session.combatSources)
        for i = 1, (list and #list or 0) do
            local src = PlainTable(list[i])
            local guid = src and Plain(src.sourceGUID)
            local total = src and Plain(src.totalAmount)
            if not (guid and total) then
                if src and type(total) == "number" then
                    withheld = true
                else
                    complete = false
                end
            elseif strict and known and not known[guid] then
                withheld = true
            else
                local before = known and known[guid] and known[guid][map.col]
                if total ~= (before or 0) then
                    UnitFor(record, guid, src)
                    local entry = seg[guid]
                    if not entry then entry = { cols = {}, parts = {} }; seg[guid] = entry end
                    entry.cols[map.col] = total
                    local parts = ReadParts(id, map.type, guid, Plain(src.sourceCreatureID))
                    if parts then
                        entry.parts[map.col] = parts
                    elseif total > 0 then
                        complete = false
                    end
                end
            end
        end
    end
    return seg, complete, withheld
end

-- Reads the newest session and makes it the baseline. False when the meter cannot
-- be read, when anything in it is still withheld - a baseline missing a row would
-- hand that row's whole history to the next bout - and when the list is empty,
-- which at login can mean "not filled in yet" as easily as "nothing there": a
-- baseline of nothing would charge the next bout with all of a session that turns
-- up a moment later. A cleared meter sets its empty baseline itself.
--
-- The same session read again only re-reads what moved since; a new one is read
-- in full, and is small for being new.
--
-- `partial` takes what can be read once asking again has stopped helping. A row
-- the meter never gives up is as invisible to the bout's reading as to this one,
-- so leaving it out costs nothing - where having no baseline at all would leave
-- the next bout to take the whole session.
function Live:RefreshBaseline(partial)
    if not self:CanRead() then return false end
    local ids = SegmentIds()
    local newest = ids[#ids]
    if not newest then return false end

    local same = baseline and baseline.epoch == meterEpoch and baseline.id == newest
    local scratch = { units = {}, unitOrder = {} }
    local seg, complete, withheld = ReadChanged(scratch, newest, same and baseline.cols or nil)
    if not complete and not partial then return false end

    local cols, parts = {}, {}
    if same then
        for guid, byCol in pairs(baseline.cols) do
            cols[guid], parts[guid] = {}, {}
            for col, total in pairs(byCol) do cols[guid][col] = total end
            for col, list in pairs(baseline.parts[guid] or {}) do parts[guid][col] = list end
        end
    end
    for guid, entry in pairs(seg) do
        cols[guid], parts[guid] = cols[guid] or {}, parts[guid] or {}
        for col, total in pairs(entry.cols) do
            cols[guid][col] = total
            parts[guid][col] = entry.parts[col]
        end
    end
    baseline = { id = newest, epoch = meterEpoch, cols = cols, parts = parts,
                 withheld = withheld or (same and baseline.withheld) or nil }
    return true
end

-- The baseline as it stands, for a bout to hold from its first moment.
function Live:Baseline()
    return baseline
end

-- One bout, read against the baseline it started with. Returns the stored
-- record, or nil, and a line saying how it was read - for the trace, which is
-- the only place a bout that came to nothing can be explained afterwards.
function Live:Bout(bout)
    if not (DM and DM.GetCombatSessionFromID) or not Readable() then
        return nil, "meter unreadable"
    end
    local ids = SegmentIds()
    local newest = ids[#ids]
    if not newest then return nil, "meter empty" end

    local db = ns.db
    db.live = db.live or {}

    local key = ("%s_%s_%s_live"):format(date("%Y%m%d_%H%M%S", bout.startedAt),
                                         tostring(bout.map or 0), bout.kind)

    -- Where the bout's figures start. With a baseline: its session's growth, and
    -- every newer session whole. With none - a fight before the meter could first
    -- be read - the newest session whole, which may hold more than the fight. A
    -- clear since the baseline, announced or shown by ids going backwards, leaves
    -- everything in the meter to this bout.
    local base = bout.base
    local from, via
    if not base then
        from, via = newest, "unbased"
    elseif base.epoch ~= meterEpoch or newest < base.id then
        from, via = 1, "reset"
    else
        from = base.id
        via = (newest > base.id) and "new" or "continued"
    end

    local record = {
        key = key, bout = bout.kind, type = bout.kind,
        startedAt = bout.startedAt, endedAt = bout.endedAt,
        map = bout.map, mapName = bout.mapName,
        character = bout.character, characterGuid = bout.characterGuid,
        faction = bout.faction, logged = bout.logged,
        units = {}, unitOrder = {}, samples = 1,
        epoch = 1, fromEpoch = 1, from = from, maxSeen = newest,
        cap = newest, capEpoch = 1, capWhy = "bout",
        open = {}, done = {},
        closed = true,
        merged = bout.merged,
    }
    local carried = (via == "new" or via == "continued") and base.id or nil
    if carried then
        local at = SegKey(record, carried)
        record.carry      = { [at] = base.cols }
        record.carryParts = { [at] = base.parts }
    end

    -- Every session from `from` on: the carried one read only where it moved,
    -- and its growth taken by Fold against the baseline; any newer one whole.
    -- Each settled at once, there being nothing more to come for any of them.
    local complete = true
    for _, id in ipairs(ids) do
        if id >= from then
            local at = SegKey(record, id)
            local strict = (id == carried) and base.withheld or nil
            local seg, whole = ReadChanged(record, id, (id == carried) and base.cols or nil, strict)
            if not whole then complete = false end
            record.open[at] = seg
            Fold(record, at)
        end
    end
    Recompute(record)
    record.updatedAt = ns:Now()
    if not complete then record.partial = true end
    db.live[key] = record

    -- The continued session names everyone who ever fought in it; only those who
    -- did something in this fight belong to the bout.
    local kept = {}
    for _, guid in ipairs(record.unitOrder) do
        local unit = record.units[guid]
        local active = false
        for _, value in pairs(unit and unit.cols or {}) do
            if value > 0 then active = true break end
        end
        if active then kept[#kept + 1] = guid else record.units[guid] = nil end
    end
    record.unitOrder = kept

    local detail = ("base=%s via=%s newest=%d units=%d%s"):format(
        base and tostring(base.id) or "none", via, newest, #kept,
        complete and "" or " partial")

    if #kept == 0 then
        db.live[key] = nil
        cacheCache[key] = nil
        ns:LiveChanged(key)
        return nil, detail
    end

    -- Settled for good, as a finished match is: the running sums only exist so
    -- that a record can be carried on.
    for _, unit in pairs(record.units) do unit.fold = nil end
    record.open, record.done, record.carry, record.carryParts = nil, nil, nil, nil
    record.via = via
    -- The reading is stamped with when the bout ended, which is when it is from.
    record.updatedAt = bout.endedAt
    Prune()
    cacheCache[key] = nil
    ns:LiveChanged(key)
    ns:Debug("live bout", key, detail)
    return record, detail
end

-- Baselines out of combat: on entering the world, as soon as the meter can be
-- read - at login its list can still be empty - after every fight in the open
-- world and after every match, and whenever the meter changes with no fight on,
-- so a heal over time ticking between pulls is not charged to the next one.
--
-- Only in the open world, where bouts are: a dungeon's or a raid's meter moving
-- out of combat would otherwise be read for nothing. A fight starting ends the
-- attempts - its own end asks again - and a failed one is tried again a second
-- later while it has tries left. Requests that arrive while one is waiting add
-- their tries to it rather than being dropped.
local baselineDue, baselineTries = false, 0

local function OpenWorld()
    local _, instanceType = GetInstanceInfo()
    return instanceType == "none" or instanceType == nil
end

local function RefreshSoon(delay, tries)
    baselineTries = math.max(baselineTries, tries or 0)
    if baselineDue then return end
    baselineDue = true
    C_Timer.After(delay, function()
        baselineDue = false
        if current or InCombatLockdown() or ns:BoutPending() or not OpenWorld() then
            baselineTries = 0
            return
        end
        -- The last try settles for what it can read; see RefreshBaseline.
        if Live:RefreshBaseline(baselineTries == 1) then
            baselineTries = 0
        elseif baselineTries > 0 then
            baselineTries = baselineTries - 1
            RefreshSoon(1, baselineTries)
        end
    end)
end

-- After a fight has been read, or one that was not a bout has ended: the next
-- bout is measured from here. Asked for straight away, and again for a while if
-- the meter is still withholding anything.
function Live:RefreshBaselineSoon()
    RefreshSoon(0, 10)
end

function Live:OnWorldEntered()
    RefreshSoon(1, 10)
end

-- Every tick of anything sends this, so it waits half a second for the next one.
function Live:OnMeterChanged()
    if current or InCombatLockdown() or ns:BoutPending() then return end
    RefreshSoon(0.5, 0)
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

    -- The record's units, and a row for every withheld group beside them: what
    -- can be said of the players the meter will not name yet - their side, their
    -- spec, their figures. Labelled by spec, or by the name the scoreboard gave the
    -- one player of a class on the other side; a group of several says how many.
    -- A group with no class is a pet or guardian, which rolls up nowhere until the
    -- log says whose it is, and is not listed as a player.
    local units = {}
    for guid, unit in pairs(record.units) do units[guid] = unit end
    local order = {}
    for _, guid in ipairs(record.unitOrder) do
        if units[guid] then order[#order + 1] = guid end
    end
    for akey, group in pairs(record.anon or {}) do
        local specIcon = (group.spec ~= 0) and group.spec or nil
        local spec = SpecFromIcon(specIcon)
        local class = (group.class ~= "") and group.class or nil
        local label = record.anonNames and record.anonNames[akey]
        if not label or group.n > 1 then
            label = (spec and spec.name) or class or "Unknown"
            -- How many it held at once in one reading, which is the most that can
            -- be said: across several readings it may be more.
            if group.n > 1 then
                label = ("%s (%d%s)"):format(label, group.n, ((group.segs or 1) > 1) and "+" or "")
            end
        end
        units[akey] = {
            name = label, cols = group.cols, parts = {},
            kind = (class and not group.creature) and "player" or "npc",
            class = class, specIcon = specIcon,
            -- Unmarked is the other side: whoever is on ours is in our group,
            -- and their identities are not withheld.
            ally = (group.side == 1),
            withheld = true,
        }
        order[#order + 1] = akey
    end

    -- Units in descending damage, which is the order a built cache stores and
    -- the order the grid expects before it sorts.
    local damageCol = Columns()[1] and Columns()[1].col or 1
    table.sort(order, function(a, b)
        local av = units[a].cols[damageCol] or 0
        local bv = units[b].cols[damageCol] or 0
        if av == bv then return a < b end
        return av > bv
    end)

    -- Every unit's own label first, in order: a built cache has N[i] naming U[i],
    -- so a counterpart interned between two units would rename a row - and so
    -- would two units sharing a label, since both would point at the first.
    --
    -- Until the label is unique, not just once. A pet gets a new GUID every time
    -- it is summoned, and the new one differs only in the leading byte of its
    -- spawn field - Pet-0-3778-726-3210-417-0104C3FA5B, then ...-0204C3FA5B,
    -- both named Gzaadhon - so every summon of it shares the name AND the four
    -- characters the suffix is made of. Suffixing once handled the second summon
    -- and the third produced a label that already existed, which Intern returns
    -- without appending: N came out two short of U in a battleground, every unit
    -- after the first miss wore the next unit's name, and the last two had none,
    -- which Roster threw on and took three windows down with it.
    for _, guid in ipairs(order) do
        local base = LabelFor(guid, units[guid])
        local label = base
        if indexOf[label] then
            local tail = tostring(guid):match("(%w%w%w%w)$") or "?"
            label = ("%s #%s"):format(base, tail)
            local n = 1
            while indexOf[label] do
                n = n + 1
                label = ("%s #%s-%d"):format(base, tail, n)
            end
        end
        Intern(label)
    end
    -- Cannot fail after the loop above; kept because the failure it would catch
    -- is a silent one - wrong names on rows - and went unnoticed until it threw.
    if #names ~= #order then
        geterrorhandler()(("CombatSession: live cache %s has %d names for %d units")
            :format(tostring(key), #names, #order))
    end

    local U, SP, SX = {}, {}, {}
    for _, guid in ipairs(order) do
        local unit = units[guid]

        local flags = (unit.kind == "player") and FLAG_PLAYER or FLAG_NPC
        -- Friendly and hostile rather than team numbers: the roster derives sides
        -- from reaction when there is no scoreboard yet, which is the case for
        -- every match still being played.
        --
        -- Failing the meter's own ally/enemy marking - not always there for a
        -- unit first seen mid-fight - group membership decides: the teams of a
        -- match are its groups, and in a bout the group fought together. A player
        -- outside it is the other side. Faction used to be the fallback, and is
        -- wrong both under mercenary mode and in a rated battleground, which can
        -- put one faction on both sides.
        local ally = unit.ally
        if ally == nil then
            if unit.isPlayer or unit.inGroup then
                ally = true
            elseif unit.kind == "player" then
                ally = false
            end
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
            -- A withheld group, and the class it showed, for the roster to join
            -- to the scoreboard row it stands for.
            wh = unit.withheld or nil, cl = unit.withheld and unit.class or nil,
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

-- What a closed session is still waiting for, or is not going to get.
--
-- "awaiting log" is a promise: the application is going to cut this match out of
-- the combat log and replace this with the real thing. A match that was not being
-- logged has no log to cut, so the promise would never be kept and the row would
-- say it forever. That session is all there will ever be of its match, and saying
-- so is the difference between a stand-in and a record.
--
-- Only an explicit no. A session recorded before this was decided has no answer,
-- and is treated as logged: a wrong "awaiting log" corrects itself when the log
-- arrives, and a wrong "log disabled" never would.
--
-- "no log recorded" is the promise broken: the application has read the log well
-- past the end of this session and cut nothing for it - a fight too slight to be
-- one in the log, or one made only of a previous fight's damage over time. It
-- publishes how far it has read as CombatSessionLogThrough. Still only a label:
-- a log that turns up after all replaces the session as it always would.
local NO_LOG_AFTER = 120

local function Waiting(record)
    if not record.closed then return "recording" end
    if record.logged == false then return "log disabled" end
    local through = tonumber(rawget(_G, "CombatSessionLogThrough"))
    local ended = record.endedAt or record.updatedAt or record.startedAt
    if through and ended and through > ended + NO_LOG_AFTER then return "no log recorded" end
    return "awaiting log"
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
            pending = Waiting(record),
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
    if not (record and guid) then return nil end
    -- A withheld group of one, read from one segment: the meter's secret name is
    -- the only one there is, unless the scoreboard has named it. From several
    -- segments it may be several players of one spec, and one of their names on
    -- all of their figures would be wrong.
    local group = record.anon and record.anon[guid]
    if group then
        if group.n ~= 1 or (group.segs or 1) > 1 then return nil end
        if record.anonNames and record.anonNames[guid] then return nil end
        return secretNames[key .. "|" .. guid]
    end
    local unit = record.units[guid]
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

    -- Another addon clearing the meter is not a problem in itself - every
    -- segment already read is kept - but the ids before the clear mean nothing
    -- after it, so a new epoch starts, and reading right away keeps the loss to
    -- whatever happened since the last reading.
    ns:RegisterEvent("DAMAGE_METER_RESET", function()
        -- Whatever a bout's baseline said is gone with the clear: everything in
        -- the meter from here belongs to whatever comes next.
        meterEpoch = meterEpoch + 1
        baseline = { id = 0, epoch = meterEpoch, cols = {}, parts = {} }

        if not current then return end
        -- Counted because it is the one thing that costs this session accuracy:
        -- whatever happened between the last reading and the clear is gone, and a
        -- session that disagrees with the log is worth being able to explain.
        current.resets = (current.resets or 0) + 1
        -- A reading in flight holds ids from before the clear.
        StopReading()
        NewEpoch(current)
        cacheCache[current.key] = nil
        C_Timer.After(0, function() Live:Sample("meter-reset") end)
    end)

    -- Keeping the bouts' baseline current; see "Bouts".
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function() Live:OnWorldEntered() end)
    ns:RegisterEvent("DAMAGE_METER_COMBAT_SESSION_UPDATED", function() Live:OnMeterChanged() end)
end

-- At login. A record the shutdown closed is left marked: the recorder opens the
-- match again a moment later and Begin reopens it. One too old for that belongs
-- to a match that is over, and saying "recording" about it would be a lie.
function Live:Restore()
    local db = ns.db
    if not (db and db.live) then return end

    for _, record in pairs(db.live) do
        if (ns:Now() - (record.updatedAt or record.startedAt or 0)) >= ns.RESUME_WINDOW then
            record.closed      = true
            record.interrupted = nil
        end
        -- Set by the build that read the live flag, and wrong on matches that
        -- were logged. Those have no answer now, which reads as "awaiting log"
        -- until their log replaces them - the right outcome for them.
        record.logging = nil
    end
    self:FillNames()
end
