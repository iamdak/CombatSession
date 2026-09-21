-- CombatSession :: Data
--
-- Headless API over the generated session data. No UI dependencies, so any
-- shell can build its own viewer on top of this.
--
-- Sessions arrive as parallel column arrays produced by the application (see
-- App/Source/StreamWriter.cpp). A Temple of Kotmogu battleground is ~190k
-- events, so aggregation runs in chunks across frames rather than in one pass:
-- a single synchronous loop over that many events visibly freezes the client.

local ADDON, ns = ...

local API = {}
ns.API = API

-- Bump when the shape or meaning of a computed CACHE changes, so caches built by
-- an older build are recomputed rather than displayed as if current.
--
-- 2: unit parenting was attributed to the event source instead of the advanced
--    block, which parented enemies to the local player.
-- 3: absorbs are credited to the shield provider rather than the shielded unit.
-- 4: ten columns with per-counterpart breakdowns; UNITS keyed by name instead
--    of index, and absorbs folded into Healing Done.
-- 5: unit identity taken from the unit itself rather than from whichever of it
--    or its pet was seen first, which mistyped owners as pets.
-- 6: absorbed damage credited to the attacker, support damage counted, pet
--    ownership from SPELL_SUMMON, and absorbs split back out of healing.
-- 7: self-targeted damage, healing and absorbs excluded.
-- 8: reverted 7 - self-targeted output counts and is listed as its own
--    counterpart in the breakdown, rather than being silently dropped there.
-- 9: per-counterpart spell breakdown, with names held once per session.
-- 10: breakdown detail capped. Uncapped it reached ~750 KB per session, and a
--     40-session cache could not be written at logout - the client saved a
--     fraction while the watermark saved intact, so the application collected
--     chunks for sessions that were never really cached.
-- 11: the cache became an encoding rather than a rendering - names interned
--     once, units and breakdowns held as flat numeric runs, and kind, reaction
--     and spell category derived on read instead of stored. The viewer expands
--     it. Version 10 had un-interned everything the chunk carefully interned.
-- 12: absorbs folded into healing, reversing 6 - prevented damage counts as
--     Healing Done for the shielder and Healing Taken for the shielded, and the
--     separate Absorb Done column is gone. Crowd control now records the spell
--     that opened each effect, so a CC counterpart expands to the fears and
--     stuns behind the time. Column indices shifted, which is why this is a
--     version bump and not a cosmetic change.
-- 13: dispels lead with the aura removed rather than the spell that removed it
--     - "Shadow Word: Pain (Cleanse)" - and offensive dispels moved to a new
--     Purges column, spell steals included. The pair is keyed by a synthetic
--     id so relabelling a dispelled aura cannot follow that spell into the
--     damage breakdowns it also appears in.
-- 14: Overhealing gained a counterpart breakdown instead of being a bare total,
--     interrupts now lead with the spell they stopped - "Polymorph (Kick)" -
--     and every composite records the real spell it leads with, so dispels,
--     purges and interrupts show an icon and the client tooltip like any other
--     row rather than being the only ones without.
-- 15: pet and guardian deaths no longer count as their owner's. Everything a
--     pet does rolls up to its owner, which is right for output and wrong for
--     dying, so every felguard and water elemental was inflating a player's
--     death count. Absorbed damage is also attributed to the attacker's own
--     spell rather than to the shield that stopped it, which had been putting
--     healers' shield names into attackers' damage breakdowns.
-- 16: per-spell smallest and largest recorded alongside the sum, so a value can
--     be read as a range rather than only an average. The flat spell run went
--     from four numbers per entry to six. Also: the recording player's side is
--     derived from the log rather than from GetBattlefieldArenaFaction, which
--     disagrees with GetBattlefieldWinner in skirmishes and had a won match
--     reported as a loss, and a winner that names no side is no longer treated
--     as one.
-- 17: Killing Blows added as a column of its own, alongside three corrections
--     to what the existing ones count. Feign Death no longer registers as a
--     death: the client emits UNIT_DIED for it like any other, and the
--     unconsciousOnDeath field that tells them apart is now carried through.
--     Damage a unit deals to itself - Ultimate Sacrifice and the like - is no
--     longer counted as damage done, only as damage taken. And spell schools
--     ride along in the stream, so a breakdown row can show what kind of damage
--     it was.
-- 18: the log is now read for everything it can answer, with the recorder kept
--     as the preferred source and the log filling what it left out or never
--     had. COMBATANT_INFO is parsed instead of discarded, which gives arenas a
--     participant list, each combatant's side, spec id, honor level and
--     pre-match rating; ARENA_MATCH_END gives the winner and both final
--     ratings; and dampening is recovered from the largest stack of the debuff
--     itself. None of it exists in a battleground log, where the recorder
--     remains the only source.
-- 19: faction derived from racial abilities. Nothing in a log states Alliance
--     or Horde - unit flags carry reaction and COMBATANT_INFO carries the arena
--     team index - but every race is faction-locked, so a cast racial names the
--     caster's side. Works in battlegrounds, which is where almost nothing else
--     does.
-- 22: damage, healing and absorbs counted in casts rather than log lines, so a
--     count, average, smallest and largest describe what one cast did. A Life
--     Cocoon that absorbed thirty hits had been thirty "casts" averaging a
--     thirtieth of its real size. Units also carry each spell's casts taken
--     whole across targets, for spell totals.
local DEFINES_VERSION = 22

--------------------------------------------------------------------------------
-- Event kinds, mirroring EventKind in StreamWriter.h. Values are persisted in
-- generated Lua, so these must stay in sync and must never be renumbered.
--------------------------------------------------------------------------------

local K = {
    SPELL_DAMAGE = 1, SPELL_PERIODIC_DAMAGE = 2, SWING_DAMAGE = 3, RANGE_DAMAGE = 4,
    SPELL_HEAL = 5, SPELL_PERIODIC_HEAL = 6,
    SPELL_ABSORBED = 7, SPELL_HEAL_ABSORBED = 8,
    AURA_APPLIED = 9, AURA_REMOVED = 10, AURA_REFRESH = 11,
    AURA_APPLIED_DOSE = 12, AURA_REMOVED_DOSE = 13, AURA_BROKEN_SPELL = 14,
    CAST_START = 15, CAST_SUCCESS = 16, CAST_FAILED = 17,
    SPELL_MISSED = 18, PERIODIC_MISSED = 19, SWING_MISSED = 20, RANGE_MISSED = 21,
    ENERGIZE = 22, PERIODIC_ENERGIZE = 23,
    DISPEL = 24, SUMMON = 25, INTERRUPT = 26, DAMAGE_SPLIT = 27,
    UNIT_DIED = 28, UNIT_DESTROYED = 29, PARTY_KILL = 30, COMBATANT_INFO = 31,
    -- The damage half of SPELL_ABSORBED, credited to the attacker.
    DAMAGE_ABSORBED = 32,
    -- Augmentation Evoker support damage.
    DAMAGE_SUPPORT = 33,
    -- A BUFF removed from a target, as opposed to DISPEL which is a DEBUFF
    -- taken off a friend. Spell steals arrive here too: they take a buff.
    PURGE = 34,
}
ns.EventKind = K

-- Damage stopped by a shield still counts as damage dealt, and the scoreboard
-- counts it: omitting it left attackers 10-30 percent short.
local IS_DAMAGE = {
    [K.SPELL_DAMAGE] = true, [K.SPELL_PERIODIC_DAMAGE] = true,
    [K.SWING_DAMAGE] = true, [K.RANGE_DAMAGE] = true, [K.DAMAGE_SPLIT] = true,
    [K.DAMAGE_ABSORBED] = true, [K.DAMAGE_SUPPORT] = true,
}
local IS_HEAL = {
    [K.SPELL_HEAL] = true, [K.SPELL_PERIODIC_HEAL] = true,
}

--------------------------------------------------------------------------------
-- Unit flags (COMBATLOG_OBJECT_*)
--------------------------------------------------------------------------------

local FLAG_PLAYER   = 0x00000400
local FLAG_NPC      = 0x00000800
local FLAG_PET      = 0x00001000
local FLAG_GUARDIAN = 0x00002000
local FLAG_HOSTILE  = 0x00000040
local FLAG_FRIENDLY = 0x00000010

local band = bit.band

local function HasFlag(flags, mask)
    return band(flags or 0, mask) ~= 0
end

local function UnitKind(flags)
    if HasFlag(flags, FLAG_PLAYER)   then return "player" end
    if HasFlag(flags, FLAG_PET)      then return "pet" end
    if HasFlag(flags, FLAG_GUARDIAN) then return "guardian" end
    if HasFlag(flags, FLAG_NPC)      then return "npc" end
    return "unknown"
end

local function UnitReaction(flags)
    if HasFlag(flags, FLAG_HOSTILE)  then return "hostile" end
    if HasFlag(flags, FLAG_FRIENDLY) then return "friendly" end
    return "neutral"
end

-- Declared here rather than beside GetMatch, which is where they are mostly
-- used: the session list joins live sessions against built ones and needs both,
-- and a local declared further down the file would be a nil global to it.
local MATCH_TOLERANCE = 90   -- seconds of slack at each end of the range

-- The log writes "Name-Realm", the client's UnitName writes "Name".
local function BaseName(name)
    return (tostring(name or ""):match("^([^-]+)") or "")
end

--------------------------------------------------------------------------------
-- DEFINES
--
-- Column parsers ship as addon code rather than as data. A reparse always uses
-- the current definitions, and older sessions are served by their stored CACHE
-- plus its version stamp, so storing code alongside the data would buy nothing.
--
-- Each column contributes to a single pass over the event columns; running one
-- pass per column would multiply the cost by the column count.
--------------------------------------------------------------------------------

local FORMAT_COLUMNS = {
    "Damage Done", "Damage Taken", "Healing Done", "Healing Taken",
    "Overhealing", "Interrupts", "Dispels", "Purges",
    "Deaths", "Killing Blows", "CC Done", "CC Taken",
}

local COL = {}
for i, name in ipairs(FORMAT_COLUMNS) do COL[name] = i end

-- Which side of an event a column's breakdown names. "dest" lists units this
-- unit acted on; "source" lists units that acted on this unit.
local COLUMN_SIDE = {
    [COL["Damage Done"]]   = "dest",   [COL["Damage Taken"]]  = "source",
    [COL["Healing Done"]]  = "dest",   [COL["Healing Taken"]] = "source",
    [COL["Overhealing"]]   = "dest",
    [COL["Interrupts"]]    = "dest",   [COL["Dispels"]]       = "dest",
    [COL["Purges"]]        = "dest",
    [COL["Deaths"]]        = "source",  -- who landed the killing blow
    [COL["Killing Blows"]] = "dest",    -- who this unit put down
    [COL["CC Done"]]       = "dest",   [COL["CC Taken"]]      = "source",
}

-- Columns whose value is a duration in milliseconds rather than an amount.
-- Their counts carry the "quantity" half of quantity-and-time.
local COLUMN_IS_TIME = {
    [COL["CC Done"]] = true, [COL["CC Taken"]] = true,
}

ns.FORMAT_COLUMNS = FORMAT_COLUMNS
ns.COLUMN_SIDE    = COLUMN_SIDE
ns.COLUMN_IS_TIME = COLUMN_IS_TIME

function API:GetDefines()
    return {
        VERSION = DEFINES_VERSION,
        FORMAT  = FORMAT_COLUMNS,
        EVENTS  = { "death" },
    }
end

-- The columns that can move while a match is being played, as indices into
-- FORMAT_COLUMNS. Everything else in the format is derived from the log and
-- appears only once the application has delivered it, so a display that updates
-- live has these and no others to choose from.
function API:LiveColumns()
    if not ns.Live then return {} end
    return ns.Live:LiveColumns()
end

-- The application version handshake, for a viewer that has to say so.
--
-- Exposed through the API rather than read off the globals directly, so an
-- alternative viewer gets the comparison already made and cannot arrive at a
-- different answer than this addon did from the same two numbers.
function API:AppVersions()
    return ns.AppVersions()
end

-- Told whenever a session's cache is built or dropped.
--
-- Caches are built a few at a time across many frames after login, so anything
-- that draws from them is drawn before most of them exist. A viewer that asks
-- once and remembers the answer then remembers "nothing here" for every session
-- that was still being built - which is why a session's W or L appeared only
-- after it was clicked, since selecting one was the only thing that asked again.
-- This is how a reader learns that its answer has changed.
--
-- Declared here, ahead of the build, because the build's completion callback
-- closes over it: a local declared after that closure is written would be a
-- global of the same name as far as the closure is concerned.
local cacheListeners = {}

function API:OnCacheChanged(fn)
    if type(fn) == "function" then
        cacheListeners[#cacheListeners + 1] = fn
    end
end

local function NotifyCacheChanged(key)
    for _, fn in ipairs(cacheListeners) do
        -- A listener belongs to another addon; its fault is not ours to raise.
        pcall(fn, key)
    end
end

-- A live session changing is the same event as a cache arriving, as far as
-- anything drawing it is concerned: the session's contents moved and the row has
-- to be redrawn. Live.lua calls this after every reading it takes.
function ns:LiveChanged(key)
    NotifyCacheChanged(key)
end

--------------------------------------------------------------------------------
-- Session discovery
--------------------------------------------------------------------------------

-- The delivery queue: chunks the application has produced and this addon has
-- not yet consumed. Empty in steady state. CombatSessionIndex is defined by
-- CombatSession_Data/Index.lua.
--
-- This is NOT the list of sessions to display. A consumed session is deleted
-- from the queue by the application, so anything already processed is absent
-- here and lives only in CACHE. Use GetViewable for the user-facing list.
function API:GetSessions()
    return CombatSessionIndex or {}
end

-- Live sessions stand in until the log arrives. The same match is recognised the
-- way the application recognises it: same instance, overlapping in time, same
-- character. Compared on headers rather than through GetMatch so it stays cheap
-- enough to run on every listing while a match is being recorded.
local function LiveRanges()
    local ranges = {}
    if not ns.Live then return ranges end
    for _, record in pairs((ns.db and ns.db.live) or {}) do
        ranges[#ranges + 1] = {
            key  = record.key,
            from = record.startedAt or 0,
            to   = record.endedAt or record.updatedAt or record.startedAt or 0,
            map  = record.map,
            who  = BaseName(record.character),
        }
    end
    return ranges
end

-- `h` is anything carrying a session's instance, character and time span: a
-- cache header, or an entry from the delivery queue.
local function SameMatch(h, range)
    return h.instanceId == range.map
       and BaseName(h.character) == range.who
       and (h.startTime or 0) <= range.to + MATCH_TOLERANCE
       and (h.endTime or 0) >= range.from - MATCH_TOLERANCE
end

-- A built cache is the real thing, so the stand-in for its match goes - from the
-- saved file, not only from the list.
--
-- Run wherever a cache can have arrived or a stand-in can be looked at: when one
-- is built, at login, and on every listing. Only the listing used to do it, which
-- left a replaced session saved for as long as nothing asked for the list - a
-- login with the viewer closed kept it indefinitely.
local function SweepLive()
    if not (ns.Live and ns.db and ns.db.cache) then return end
    local ranges = LiveRanges()
    if #ranges == 0 then return end

    for key, cache in pairs(ns.db.cache) do
        local h = cache.header or {}
        for _, range in ipairs(ranges) do
            if not range.gone and SameMatch(h, range) then
                range.gone = ns.Live:Supersede(range.key, key)
            end
        end
    end
end

-- The built session that replaced a live one, or nil while it has not been
-- replaced. For anything that remembered a live session by key - the viewer's
-- selection across a reload - and needs to follow it to the real thing.
function API:Successor(key)
    if not ns.Live then return nil end
    SweepLive()
    return ns.Live:Successor(key)
end

-- The name the game is withholding for one row of a live session, as the secret
-- value itself, or nil when the row has a readable name worth showing instead.
--
-- It cannot be compared, concatenated, formatted as a string or saved - each of
-- those throws. What it can be is handed to FontString:SetText, which draws it.
-- That is the only thing a caller should do with it.
function API:SecretName(key, guid)
    if not ns.Live then return nil end
    return ns.Live:SecretName(key, guid)
end

-- Every session the user can look at: everything cached, plus anything still
-- queued. Entries share one shape regardless of which side they came from.
function API:GetViewable()
    SweepLive()

    local out, seen = {}, {}

    if ns.db and ns.db.cache then
        for key, cache in pairs(ns.db.cache) do
            local h = cache.header or {}
            seen[key] = true
            out[#out + 1] = {
                key = key, cached = true,
                startTime = h.startTime, endTime = h.endTime,
                type = h.type, mapName = h.mapName, bracket = h.bracket,
                rated = h.rated, truncated = h.truncated,
                instanceId = h.instanceId, lobby = h.lobby, round = h.round,
                combatants = h.combatants,
                character = h.character, characterGuid = h.characterGuid,
                events = cache.eventCount or 0,
                units  = cache.unitCount or 0,
            }
        end
    end

    -- What is left after the sweep is only stand-ins with no built session yet.
    local live = LiveRanges()
    local function CoveringLive(entry)
        for _, range in ipairs(live) do
            if SameMatch(entry, range) then return range end
        end
    end

    -- Queued sessions the addon has not built yet are listed so a backlog does
    -- not look like missing data. Declined ones are not: below the floor the
    -- cache is full and these have lost their place to newer sessions, so they
    -- are gone as far as this addon is concerned and the application collects
    -- their chunks on its next run. Listing them would show rows that hold
    -- nothing, cannot be opened, and vanish on their own a minute later.
    local floor = (ns.db and ns.db.oldestWanted) or ""
    for _, entry in ipairs(self:GetSessions()) do
        if not seen[entry.key] and (floor == "" or entry.key >= floor) then
            -- Unless a live session already stands for that match: it holds the
            -- meter's account of it and says the log is still to come, which is
            -- both of these rows in one and the only one that can be opened.
            if not CoveringLive(entry) then
                local copy = {}
                for k, v in pairs(entry) do copy[k] = v end
                copy.cached = false
                out[#out + 1] = copy
            end
        end
    end

    if ns.Live then
        for _, entry in ipairs(ns.Live:Viewable()) do
            out[#out + 1] = entry
        end
    end

    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

function API:GetSession(key)
    for _, entry in ipairs(self:GetSessions()) do
        if entry.key == key then return entry end
    end
end

-- Chunks in CombatSession_Data are loaded eagerly by the client, so a pending
-- session's stream is already resident. Nothing is loaded on demand: the folder
-- is a queue that the application empties once these have been consumed.
function API:LoadStream(key)
    local stream = CombatSessionStream and CombatSessionStream[key]
    if not stream then
        -- Either never delivered, or already consumed and collected. Sessions
        -- in the latter state are served from CACHE and need no stream.
        return nil, "no pending chunk for this session"
    end
    return stream
end

--------------------------------------------------------------------------------
-- Consumption
--
-- The application deletes chunks once this addon reports them processed, so
-- processing has to be proactive rather than waiting for the user to click.
-- Work runs newest-first in the background, so the session most likely to be
-- looked at is ready first and the backlog fills in behind it.
--------------------------------------------------------------------------------

function API:GetMaxSessions()
    return (ns.db and ns.db.settings.maxSessions) or 40
end

function API:SetMaxSessions(count)
    count = tonumber(count)
    if not count or count < 1 then return false, "count must be a positive number" end

    local previous = ns.db.settings.maxSessions or 0
    ns.db.settings.maxSessions = math.floor(count)

    -- Raising the cap has to lower the floor with it, or what the old cap
    -- declined stays declined forever: GetPending filters on the floor, so
    -- those sessions would never be offered again, and PruneCaches - the only
    -- thing that recomputes the floor - would never see them. Whatever is still
    -- queued becomes eligible at the next login. Whatever the application has
    -- already collected is archive-only either way.
    if ns.db.settings.maxSessions > previous then
        ns.db.oldestWanted = ""
    end
    return true
end

-- Queued sessions this addon does not actually hold, newest first.
--
-- Pending means "not held", not "newer than a mark". A session missing from the
-- cache is wanted however old it is, which is what makes a short SavedVariables
-- write recoverable: whatever failed to save simply reads back as pending, and
-- its chunk was never collected because the application asks the same question.
--
-- The floor is the one exception. Once the cache is full, sessions below it have
-- been declined for good, and without saying so they would be re-offered every
-- login, rebuilt, and immediately pruned again - forty caches of work per login,
-- discarded each time.
function API:GetPending()
    local floor = (ns.db and ns.db.oldestWanted) or ""
    local pending = {}
    for _, entry in ipairs(self:GetSessions()) do
        local cache = self:GetCache(entry.key)

        -- A queued chunk holding more events than the cached copy is a session
        -- that was emitted from a guessed end and has since been completed, so
        -- it supersedes what is held. Treating "cached" as final meant the
        -- fuller chunk was passed over and then collected, leaving a truncated
        -- Deephaul Ravine in place permanently - the application could rebuild
        -- the chunk, but nothing would ever take it.
        local supersedes = cache and entry.events
                       and entry.events > (cache.eventCount or 0)

        if (not cache or supersedes) and (floor == "" or entry.key >= floor) then
            pending[#pending + 1] = entry
        end
    end
    table.sort(pending, function(a, b) return a.key > b.key end)
    return pending
end

-- Trims stored caches to the session cap, oldest first, and republishes the
-- floor.
--
-- The floor is published whenever the cache is FULL, not only when it
-- overflowed on this pass. Landing exactly on the cap still means older
-- sessions are being turned away, and saying nothing there was a real defect:
-- with 65 queued and a cap of 40 the first login built the newest 40, found
-- #keys == limit, declared no floor, and so re-offered the other 25 on the next
-- login - building all 25 only for this function to throw them straight back
-- out. A full cache is a closed door whether or not it slammed on this pass.
--
-- Recomputed rather than only ever raised: the cap can be raised, or entries
-- can fall out for being stale, and a floor left above what is actually held
-- would decline sessions still wanted - which the application reads as
-- permission to delete their chunks.
local function PruneCaches()
    local db = ns.db
    if not db or not db.cache then return end

    local keys = {}
    for key in pairs(db.cache) do keys[#keys + 1] = key end
    local limit = (db.settings and db.settings.maxSessions) or 40

    if #keys < limit then
        db.oldestWanted = ""
        return
    end

    table.sort(keys)
    for i = 1, #keys - limit do db.cache[keys[i]] = nil end
    db.oldestWanted = keys[#keys - limit + 1]
end

-- Consumes the backlog. Only sessions that will still be held once it is done are
-- built: the newest `maxSessions` of everything, counting what is already cached
-- alongside what is queued. PruneCaches then publishes the floor, which declines
-- the rest for good - the application collects their chunks and they live on in
-- the raw archive. Raising the cap lowers the floor and reopens whatever is
-- still queued.
--
-- The queue used to be ranked on its own: the newest `maxSessions` of it were
-- built whatever was already held, and PruneCaches then discarded every one that
-- landed below sessions already cached. With 30 held and 400 queued, that was 40
-- sessions parsed and up to 30 of them thrown away on the spot.
function API:ProcessPending(onDone)
    local pending = self:GetPending()
    if #pending == 0 then
        if onDone then onDone(0, 0) end
        return
    end

    local limit = self:GetMaxSessions()

    local ranked, seen = {}, {}
    for key in pairs((ns.db and ns.db.cache) or {}) do
        ranked[#ranked + 1] = key
        seen[key] = true
    end
    for _, entry in ipairs(pending) do
        if not seen[entry.key] then
            ranked[#ranked + 1] = entry.key
            seen[entry.key] = true
        end
    end
    table.sort(ranked, function(a, b) return a > b end)

    local kept = {}
    for i = 1, math.min(#ranked, limit) do kept[ranked[i]] = true end

    -- Still newest first, so the sessions most likely to be looked at arrive
    -- first.
    local build = {}
    for _, entry in ipairs(pending) do
        if kept[entry.key] then build[#build + 1] = entry end
    end

    local take    = #build
    local skipped = #pending - take

    local index = 1
    local function Next()
        if index > take then
            PruneCaches()
            if onDone then onDone(take, skipped) end
            return
        end

        local key = build[index].key
        index = index + 1

        self:BuildCache(key, function(_, err)
            if err then ns:Debug("skipped", key, err) end
            Next()
        end)
    end

    Next()
end

--------------------------------------------------------------------------------
-- Cache
--------------------------------------------------------------------------------

local function CacheIsCurrent(cache)
    return cache and cache.FORMAT and cache.FORMAT.version == DEFINES_VERSION
end

-- Drops cache entries written by an older format.
--
-- They are not merely unreadable, they are misleading. The application decides
-- which chunks to collect by reading the keys of `cache` out of the saved file,
-- and it has no way to tell a current entry from an obsolete one - so an entry
-- left behind after a format change would license the deletion of the one chunk
-- that could rebuild it. Clearing them at load keeps the file an honest
-- statement of what is held.
local function DropStaleCaches()
    local db = ns.db
    if not db or not db.cache then return end

    local dropped = 0
    for key, cache in pairs(db.cache) do
        if not CacheIsCurrent(cache) then
            db.cache[key] = nil
            dropped = dropped + 1
            NotifyCacheChanged(key)
        end
    end
    if dropped > 0 then
        ns:Debug(("dropped %d cache entry(s) from an older format"):format(dropped))
    end
end

--------------------------------------------------------------------------------
-- Event context
--
-- For each recorded death, the preceding window of major actions involving the
-- dying unit. Deaths are rare (230 in the reference battleground) but each scan
-- walks back over thousands of events, so this runs as its own chunked phase
-- rather than inside the aggregation loop.
--------------------------------------------------------------------------------

-- Caps on how much breakdown detail is stored per column.
--
-- Everything cached is serialised into SavedVariables at every logout, and the
-- per-counterpart spell layer multiplies out: players x columns x counterparts
-- x spells. Uncapped it produced ~750 KB per session, so a 40-session cache was
-- ~30 MB - which the client failed to write, saving only a couple of sessions
-- while the watermark saved fine, telling the application those sessions were
-- consumed and letting it delete their chunks. That second failure is closed
-- now - the application reads the cache keys themselves, so a short write can
-- no longer claim sessions it did not save - but a cache small enough to write
-- in the first place is still the better answer, and losing the long tail of a
-- drill-down costs nothing that matters.
--
-- The totals are always exact; only the itemisation is trimmed, and the number
-- omitted is recorded so the viewer can say so.
local MAX_BREAKDOWN_COUNTERPARTS = 25
local MAX_SPELLS_PER_COUNTERPART = 12

local CONTEXT_WINDOW_MS = 8000
local CONTEXT_MAX_ENTRIES = 16

-- Damage below this fraction of the victim's maximum health is not interesting
-- enough to occupy a context slot.
local CONTEXT_MIN_DAMAGE_FRACTION = 0.05

--------------------------------------------------------------------------------
-- Compaction
--
-- Aggregation builds a convenient shape - units keyed by name, breakdowns keyed
-- by counterpart name, leaves as {v=,n=} tables. That shape is fine in memory
-- and ruinous on disk: SavedVariables writes one line per table entry, so every
-- leaf cost five lines and every counterpart name was repeated once per column
-- per unit. Two sessions came to 109,021 lines, with "Dakson-Lightning'sBlade-US"
-- written 126 times.
--
-- The stored form is therefore encoded, not rendered:
--   N   names, interned once
--   SP  [spellId] = name
--   U   units, indexed by name index, with flags kept and kind/reaction dropped
--       because both derive from flags
--   b   flat numeric runs: nameIdx, value, count, ...
--   s   flat numeric runs: nameIdx, spellId, value, count, ...
--
-- Nothing here is human readable, which is the point - Inspect.lua expands it.
local function Compact(UNITS, events)
    local names, nameIndex = {}, {}
    local function Intern(name)
        local i = nameIndex[name]
        if not i then
            names[#names + 1] = name
            i = #names
            nameIndex[name] = i
        end
        return i
    end

    -- Interned in descending damage order so the viewer's default sort is close
    -- to index order and the common case barely has to sort at all.
    local ordered = {}
    for name in pairs(UNITS) do ordered[#ordered + 1] = name end
    table.sort(ordered, function(a, b)
        return (UNITS[a].cols[1] or 0) > (UNITS[b].cols[1] or 0)
    end)
    for _, name in ipairs(ordered) do Intern(name) end

    local U = {}
    for _, name in ipairs(ordered) do
        local entry = UNITS[name]
        local out = {
            f = entry.flags,
            l = entry.level ~= 0 and entry.level or nil,
            c = entry.cols,
            n = entry.counts,
        }

        for col, map in pairs(entry.by) do
            local flat, spellFlat = {}, {}
            for other, slot in pairs(map) do
                local oi = Intern(other)
                flat[#flat + 1] = oi
                flat[#flat + 1] = slot.v
                flat[#flat + 1] = slot.n
                if slot.s then
                    for spellId, use in pairs(slot.s) do
                        spellFlat[#spellFlat + 1] = oi
                        spellFlat[#spellFlat + 1] = spellId
                        spellFlat[#spellFlat + 1] = use.v
                        spellFlat[#spellFlat + 1] = use.n
                        spellFlat[#spellFlat + 1] = use.mn or 0
                        spellFlat[#spellFlat + 1] = use.mx or 0
                    end
                end
            end
            if #flat > 0 then
                out.b = out.b or {}
                out.b[col] = flat
            end
            if #spellFlat > 0 then
                out.s = out.s or {}
                out.s[col] = spellFlat
            end
        end

        -- Each spell's casts taken whole, for the unit's own spell totals: spell
        -- id, casts, smallest and largest, four numbers a spell. Summing the
        -- per-target rows cannot give these - one Wild Growth on six allies is
        -- six rows there and one cast here.
        --
        -- Counted per spell name and written once under every id the name was
        -- seen with, so whichever of them survived trimming carries the figure.
        -- A reader takes it from any one of them; adding them up would count a
        -- cast once for every id it touched.
        for col, totals in pairs(entry.whole or {}) do
            local flat = {}
            for _, w in pairs(totals) do
                if w.n > 0 then
                    for spellId in pairs(w.ids) do
                        flat[#flat + 1] = spellId
                        flat[#flat + 1] = w.n
                        flat[#flat + 1] = w.mn or 0
                        flat[#flat + 1] = w.mx or 0
                    end
                end
            end
            if #flat > 0 then
                out.w = out.w or {}
                out.w[col] = flat
            end
        end
        out.m = entry.more
        U[nameIndex[name]] = out
    end

    -- Death events: unit and context units become indices, context actions
    -- become flat runs of six numbers.
    local E = {}
    for _, event in ipairs(events) do
        local flat = {}
        for _, a in ipairs(event.context or {}) do
            flat[#flat + 1] = a.t
            flat[#flat + 1] = a.kind
            flat[#flat + 1] = a.src and Intern(a.src) or 0
            flat[#flat + 1] = a.dst and Intern(a.dst) or 0
            flat[#flat + 1] = a.spell or 0
            flat[#flat + 1] = a.amount or 0
        end
        E[#E + 1] = { t = event.t, u = Intern(event.unit), c = flat }
    end

    return names, U, E
end

-- Keeps the largest contributors and discards the tail, recording how many were
-- dropped so the viewer never implies the list is complete.
local function TrimBreakdowns(UNITS)
    for _, entry in pairs(UNITS) do
        for col, map in pairs(entry.by) do
            local order = {}
            for name, slot in pairs(map) do
                order[#order + 1] = { name = name, slot = slot }
            end
            table.sort(order, function(a, b) return a.slot.v > b.slot.v end)

            if #order > MAX_BREAKDOWN_COUNTERPARTS then
                for i = MAX_BREAKDOWN_COUNTERPARTS + 1, #order do
                    map[order[i].name] = nil
                end
                entry.more = entry.more or {}
                entry.more[col] = #order - MAX_BREAKDOWN_COUNTERPARTS
            end

            for i = 1, math.min(#order, MAX_BREAKDOWN_COUNTERPARTS) do
                local spells = order[i].slot.s
                if spells then
                    local uses = {}
                    for id, use in pairs(spells) do
                        uses[#uses + 1] = { id = id, use = use }
                    end
                    if #uses > MAX_SPELLS_PER_COUNTERPART then
                        table.sort(uses, function(a, b) return a.use.v > b.use.v end)
                        for j = MAX_SPELLS_PER_COUNTERPART + 1, #uses do
                            spells[uses[j].id] = nil
                        end
                        order[i].slot.m = #uses - MAX_SPELLS_PER_COUNTERPART
                    end
                end
            end
        end
    end
end

local function BuildEventContext(stream, nameOf, UNITS, events, onDone)
    local t, k, s, d = stream.t, stream.k, stream.s, stream.d
    local sp, am, hpm = stream.sp, stream.am, stream.hpm
    local spells = stream.spells

    local categoryOf = ns.SpellCategory
    local i = 1

    local function Step()
        local stop = math.min(i + 40 - 1, #events)

        for e = i, stop do
            local death = events[e]
            local at, victim = death.at, death.unit   -- victim is a name
            local cutoff = t[at] - CONTEXT_WINDOW_MS

            -- UNIT_DIED carries no advanced block, so its hpMax column is zero.
            -- The victim's real maximum comes from a damage event aimed at them,
            -- where the advanced block describes the destination. Learned during
            -- the backward scan below; until then every hit qualifies.
            local threshold = 0

            local context = {}
            for j = at - 1, 1, -1 do
                if t[j] < cutoff then break end

                -- Compared by name, matching how units are keyed everywhere
                -- else, so a pet's action counts as its owner's.
                local src = s[j] ~= 0 and nameOf[s[j]] or nil
                local dst = d[j] ~= 0 and nameOf[d[j]] or nil

                if dst == victim and (hpm[j] or 0) > 0 and threshold == 0 then
                    threshold = hpm[j] * CONTEXT_MIN_DAMAGE_FRACTION
                end

                if src == victim or dst == victim then
                    local spellIndex = sp[j]
                    local spellId = spellIndex ~= 0 and spells[spellIndex]
                                    and spells[spellIndex][1] or nil
                    local category = spellId and categoryOf[spellId]

                    -- Categorised actions always qualify; raw damage only when
                    -- it was a meaningful share of the victim's health pool.
                    local keep = category ~= nil
                    if not keep and IS_DAMAGE[k[j]] and dst == victim then
                        keep = am[j] >= threshold
                    end

                    if keep then
                        -- On a dispel or purge the amount column carries the
                        -- removed aura's spell index, not a quantity, so it
                        -- would render as a meaningless small number here.
                        local isDispel = k[j] == K.DISPEL or k[j] == K.PURGE
                        context[#context + 1] = {
                            t        = t[j] - t[at],   -- negative: before death
                            kind     = k[j],
                            src      = src,
                            dst      = dst,
                            spell    = spellId,
                            name     = spellIndex ~= 0 and spells[spellIndex]
                                       and spells[spellIndex][2] or nil,
                            amount   = not isDispel and am[j] or 0,
                            category = category,
                        }
                        if #context >= CONTEXT_MAX_ENTRIES then break end
                    end
                end
            end

            -- Collected backwards; reverse so the timeline reads forwards.
            for a = 1, math.floor(#context / 2) do
                context[a], context[#context - a + 1] = context[#context - a + 1], context[a]
            end
            death.context = context
        end

        i = stop + 1
        if i <= #events then C_Timer.After(0, Step) else onDone() end
    end

    if #events == 0 then onDone() else Step() end
end

--------------------------------------------------------------------------------
-- Match overlay
--
-- Rated status, outcome and battleground rosters exist only in what the
-- recorder captured live. Sessions are joined to a match record by overlapping
-- time range: a Solo Shuffle lobby produces one record but six sessions, so all
-- six rounds legitimately map to the same record.
--------------------------------------------------------------------------------

function API:GetMatch(entry)
    -- A live session knows its own record, and while the match is still being
    -- played that record is not in db.matches yet - the recorder stores it on the
    -- way out - so there is nothing here to search for.
    if entry.live and ns.Live then return ns.Live:MatchFor(entry.key) end

    if not (ns.db and ns.db.matches) then return nil end
    if not entry.startTime then return nil end

    local wanted = BaseName(entry.character)

    local best, bestScore
    for _, record in ipairs(ns.db.matches) do
        local recEnd = record.endedAt or (record.startedAt + 3600)
        local overlaps = record.startedAt <= entry.endTime + MATCH_TOLERANCE
                     and recEnd >= entry.startTime - MATCH_TOLERANCE
        if overlaps then
            -- Weighted so the strongest evidence wins outright. Instance is the
            -- most specific, then which character played it, and completeness
            -- only breaks ties between otherwise equal candidates.
            local score = 0
            if record.map == entry.instanceId then score = score + 8 end
            -- Records are account-wide, so time and map alone can tie when
            -- several characters played overlapping matches.
            if wanted ~= "" and BaseName(record.character) == wanted then
                score = score + 4
            end
            -- A completed record beats an abandoned one covering the same
            -- match. A transient zone reading used to file both, and without
            -- this the phantom won purely by being seen first.
            if record.complete then score = score + 2 end

            if not bestScore or score > bestScore then
                best, bestScore = record, score
            end
        end
    end
    return best
end

--------------------------------------------------------------------------------
-- Expansion
--
-- The stored cache is an encoding: interned names, flat numeric runs, kind and
-- reaction left to be derived from flags. These turn it back into something a
-- viewer can render, so no shell has to understand the storage layout.
--------------------------------------------------------------------------------

-- Units in stored order, which is descending damage.

--------------------------------------------------------------------------------
-- Roster
--------------------------------------------------------------------------------

local function HasActivity(unit)
    if not unit then return false end
    for i = 1, #unit.cols do
        if (unit.cols[i] or 0) ~= 0 then return true end
    end
    return false
end

-- Who played, which side they were on, and what each side totalled.
--
-- This lives in the API rather than in a viewer because getting it wrong is not
-- obvious: a rated Eye of the Storm whose scoreboard listed 20 players produced
-- 38 player units in the log, and neither raw reaction flags nor an activity
-- filter reproduced the 10/10. The scoreboard decides who played; log data only
-- supplies the numbers. Two shells reading this differently would disagree
-- about something the user can check against their own scoreboard.
--
-- Returns players, teams:
--   players[i] = { name, unit, class, team = 1|2|nil, player = <scoreboard row> }
--   teams[i]   = { damage, healing, count, side = 0|1|nil, won = bool|nil }
-- team is nil for units that fought but are absent from the scoreboard - they
-- left early or were backfilled out. Formatting a side as a faction is left to
-- the caller: in an arena 0 and 1 are just the two teams, not Horde and
-- Alliance.
function API:Roster(entry, cache, match)
    local units, byName = self:UnitList(cache), {}
    for _, unit in ipairs(units) do byName[unit.name] = unit end

    -- A scoreboard omits the realm for players on your own realm, so names join
    -- on the base name. Player-flagged units win any collision.
    local byBase = {}
    for _, unit in ipairs(units) do
        local base = BaseName(unit.name)
        if not byBase[base] or unit.kind == "player" then
            byBase[base] = unit.name
        end
    end

    local damageCol, healingCol = COL["Damage Done"], COL["Healing Done"]
    local players, claimed = {}, {}
    local teams = {
        { damage = 0, healing = 0, count = 0 },
        { damage = 0, healing = 0, count = 0 },
    }

    -- Which faction number belongs to the recording player.
    --
    -- Not GetBattlefieldArenaFaction, which the recorder stores as
    -- playerFaction: in a skirmish it disagrees with GetBattlefieldWinner. A won
    -- Maldraxxus Coliseum came back winner=0 against playerFaction=1 and was
    -- reported as a loss, and reading a win as a loss is worse than saying
    -- nothing at all.
    --
    -- The log settles it. Units friendly to the recording player are on the
    -- recording player's side by definition, so whichever faction number those
    -- roster entries carry is theirs - and it is expressed in the same numbering
    -- the winner is, because both come off the same scoreboard.
    local function OwnFaction()
        local votes = {}
        for _, player in ipairs((match and match.roster) or {}) do
            local unitName = byBase[BaseName(player.name)]
            local unit = unitName and byName[unitName]
            if unit and player.faction ~= nil and unit.reaction == "friendly" then
                votes[player.faction] = (votes[player.faction] or 0) + 1
            end
        end

        local best, bestCount
        for faction, count in pairs(votes) do
            if not bestCount or count > bestCount then
                best, bestCount = faction, count
            end
        end
        return best or (match and match.playerFaction)
    end

    -- COMBATANT_INFO, which the log itself carries for an arena and never for a
    -- battleground. Keyed by name, resolved from GUID when the cache was built.
    local ci = cache.CI
    local haveCombatants = false
    if ci then for _ in pairs(ci) do haveCombatants = true break end end

    local header = cache.header or {}

    local haveRoster = match and match.roster and #match.roster > 0

    -- Which faction number is the recording player's. The scoreboard answers it
    -- when there is one; COMBATANT_INFO answers it from the log by naming the
    -- recording character's own side, in the same 0/1 numbering ARENA_MATCH_END
    -- reports the winner in.
    local ownFaction = OwnFaction()
    if ownFaction == nil and haveCombatants then
        local ownName = header.character
        local own = ownName and (ci[ownName] or ci[byBase[BaseName(ownName)] or ""])
        if own then ownFaction = own.f end
    end

    if haveRoster then
        local own = ownFaction
        for _, player in ipairs(match.roster) do
            local team = 1
            if own ~= nil and player.faction ~= nil then
                team = (player.faction == own) and 1 or 2
            end
            local unitName = byBase[BaseName(player.name)]
            if unitName then claimed[unitName] = true end

            -- The recorder wins where it has an answer, and the log fills what
            -- it left out. A scoreboard carries no honor level at all, so that
            -- one comes from here whenever the log has it.
            local logged = (unitName and ci and ci[unitName]) or nil

            players[#players + 1] = {
                name   = player.name,
                unit   = unitName and byName[unitName] or nil,
                class  = player.class,
                team   = team,
                player = player,
                specId = logged and logged.s or nil,
                honor  = logged and logged.h or nil,
                rating = player.rating or (logged and logged.r) or nil,
            }
        end

    elseif haveCombatants then
        -- No recorder record, but an arena log states its own participants.
        -- COMBATANT_INFO is emitted once per combatant, so it defines the
        -- roster as authoritatively as the scoreboard does - and unlike the
        -- reaction fallback below it needs no activity filter, because it lists
        -- exactly the people who were in the match.
        for name, info in pairs(ci) do
            local unit = byName[name]
            local team
            if ownFaction ~= nil and info.f ~= nil then
                team = (info.f == ownFaction) and 1 or 2
            end
            claimed[name] = true
            players[#players + 1] = {
                name   = name,
                unit   = unit,
                specId = info.s,
                honor  = info.h,
                rating = info.r,
                team   = team,
            }
        end

    else
        -- Neither, so fall back to reaction flags. Activity is required here,
        -- since nothing else keeps the aura burst out.
        for _, unit in ipairs(units) do
            if unit.kind == "player" and HasActivity(unit) then
                local team = (unit.reaction == "friendly") and 1
                          or (unit.reaction == "hostile") and 2 or nil
                if team then
                    players[#players + 1] =
                        { name = unit.name, unit = unit, team = team }
                end
            end
        end
    end

    if haveRoster or haveCombatants then
        for _, unit in ipairs(units) do
            if unit.kind == "player" and not claimed[unit.name] and HasActivity(unit) then
                -- Fought but absent from the scoreboard: left early, or was
                -- backfilled out. They are deliberately not counted in a team's
                -- totals, since the scoreboard defines who played - but which
                -- side they were on is still knowable from their reaction to the
                -- recording player, and a row with no side at all is the one
                -- thing a viewer cannot show honestly.
                local inferred = (unit.reaction == "friendly") and 1
                              or (unit.reaction == "hostile") and 2 or nil
                players[#players + 1] = {
                    name = unit.name, unit = unit, team = nil, inferredTeam = inferred,
                }
            end
        end
    end

    for _, row in ipairs(players) do
        local team = row.team and teams[row.team]
        if team then
            team.count   = team.count + 1
            team.damage  = team.damage  + (row.unit and row.unit.cols[damageCol] or 0)
            team.healing = team.healing + (row.unit and row.unit.cols[healingCol] or 0)
        end
    end

    if ownFaction ~= nil then
        teams[1].side = ownFaction
        teams[2].side = (ownFaction == 0) and 1 or 0

        -- Only 0 and 1 name a side. GetBattlefieldWinner reports 0xFFFFFFFF for
        -- a match that ended without one, which arrives in Lua as a large
        -- positive number and sailed straight through a ">= 0" test.
        --
        -- ARENA_MATCH_END is the log's own answer and stands in when there is no
        -- recorder record. Its -1 means a Solo Shuffle lobby, which has no
        -- single winner, and is rejected by the same test.
        local winner = match and match.winner
        if winner == nil then winner = header.winner end
        if winner == 0 or winner == 1 then
            teams[1].won = (winner == teams[1].side)
            teams[2].won = (winner == teams[2].side)
        end

        -- Rating and MMR come from GetBattlefieldTeamInfo, which the recorder
        -- stores indexed by arena team id. Only a rated match populates them.
        for i = 1, 2 do
            local info = match and match.teams and teams[i].side ~= nil
                     and match.teams[teams[i].side + 1]
            if info then
                teams[i].teamName = info.name
                teams[i].rating   = info.newRating
                teams[i].mmr      = info.mmr
                if info.newRating and info.oldRating then
                    teams[i].ratingChange = info.newRating - info.oldRating
                end
            end
        end

        -- The log's ratings, for the sides the recorder did not describe.
        -- ARENA_MATCH_END reports both teams' NEW ratings indexed by the same
        -- 0/1 side; the change is recoverable because COMBATANT_INFO carries
        -- what each player's rating was before the match. MMR is in neither, so
        -- it stays absent rather than being guessed at.
        for i = 1, 2 do
            local side = teams[i].side
            if teams[i].rating == nil and side ~= nil then
                local rating = (side == 0) and header.rating1 or header.rating2
                if rating and rating > 0 then
                    teams[i].rating = rating

                    local before
                    for _, row in ipairs(players) do
                        if row.team == i and row.rating and row.rating > 0 then
                            before = row.rating
                            break
                        end
                    end
                    if before then teams[i].ratingChange = rating - before end
                end
            end
        end
    end

    return players, teams
end

function API:UnitList(cache)
    local out = {}
    for i, u in ipairs(cache.U or {}) do
        out[i] = {
            index    = i,
            name     = cache.N[i],
            flags    = u.f,
            level    = u.l,
            kind     = UnitKind(u.f),
            reaction = UnitReaction(u.f),
            cols     = u.c,
            counts   = u.n,
            -- Live sessions only. A built cache names units and nothing more,
            -- but a live row's GUID is what its withheld name is filed under.
            guid     = u.guid,
        }
    end
    return out
end

function API:UnitIndexByName(cache, name)
    for i, n in ipairs(cache.N or {}) do
        if n == name then return i end
    end
end

-- Counterparts making up one column for one unit, largest first, each with the
-- spells that contributed. Second return is how many were dropped when stored.
function API:Breakdown(cache, index, col)
    local unit = cache.U and cache.U[index]
    if not unit then return {} end

    local flat = unit.b and unit.b[col]
    if not flat then return {}, unit.m and unit.m[col] end

    local out, byIndex = {}, {}
    for i = 1, #flat, 3 do
        local entry = { name = cache.N[flat[i]], v = flat[i + 1], n = flat[i + 2] }
        byIndex[flat[i]] = entry
        out[#out + 1] = entry
    end

    local spells = unit.s and unit.s[col]
    if spells then
        for i = 1, #spells, 6 do
            local entry = byIndex[spells[i]]
            if entry then
                entry.spells = entry.spells or {}
                local id = spells[i + 1]
                entry.spells[#entry.spells + 1] = {
                    -- `id` keys the entry and picks its label. `spellId` is the
                    -- real spell behind it, for an icon and the client tooltip:
                    -- the same thing for an ordinary spell, and for a composite
                    -- - "Polymorph (Kick)" - the spell it leads with.
                    id      = id,
                    spellId = (cache.SX and cache.SX[id]) or id,
                    name    = (cache.SP and cache.SP[id]) or ("spell " .. id),
                    -- Nil for a session cached before schools were recorded,
                    -- which the viewer draws as no school icon rather than as
                    -- a wrong one.
                    school  = cache.SS and cache.SS[id] or nil,
                    v       = spells[i + 2],
                    n       = spells[i + 3],
                    mn      = spells[i + 4],
                    mx      = spells[i + 5],
                }
            end
        end
    end

    table.sort(out, function(a, b) return a.v > b.v end)
    for _, entry in ipairs(out) do
        if entry.spells then
            table.sort(entry.spells, function(a, b) return a.v > b.v end)
        end
    end
    return out, unit.m and unit.m[col]
end

-- One unit's casts in one column, by spell name: { [name] = { n, mn, mx } },
-- each cast taken whole across every target it landed on. What a spell-totals
-- line should show for a count, smallest and largest; the per-counterpart rows
-- Breakdown returns count a cast once per target instead.
--
-- Empty for a session built before these were recorded, and for a live one.
function API:SpellCasts(cache, index, col)
    local unit = cache.U and cache.U[index]
    local flat = unit and unit.w and unit.w[col]
    local out = {}
    if not flat then return out end

    for i = 1, #flat, 4 do
        local name = cache.SP and cache.SP[flat[i]]
        -- Written once per id under the same name with the same figures, so
        -- the first one found stands for all of them.
        if name and not out[name] then
            out[name] = { n = flat[i + 1], mn = flat[i + 2], mx = flat[i + 3] }
        end
    end
    return out
end

-- Death events with their preceding action window, names resolved.
function API:EventList(cache)
    local categoryOf = ns.SpellCategory
    local out = {}
    for i, e in ipairs(cache.E or {}) do
        local context = {}
        for j = 1, #e.c, 6 do
            local id = e.c[j + 4]
            context[#context + 1] = {
                t        = e.c[j],
                kind     = e.c[j + 1],
                src      = e.c[j + 2] ~= 0 and cache.N[e.c[j + 2]] or nil,
                dst      = e.c[j + 3] ~= 0 and cache.N[e.c[j + 3]] or nil,
                spell    = id ~= 0 and id or nil,
                name     = id ~= 0 and ((cache.SP and cache.SP[id]) or ("spell " .. id)) or nil,
                amount   = e.c[j + 5],
                -- Derived rather than stored: the taxonomy is a lookup the
                -- reader already has, so keeping it out of the cache costs
                -- nothing and saves a string per context entry.
                category = id ~= 0 and categoryOf[id] or nil,
            }
        end
        out[i] = { name = "death", t = e.t, unit = cache.N[e.u], context = context }
    end
    return out
end

function API:GetCache(key)
    local cache = ns.db and ns.db.cache and ns.db.cache[key]
    if CacheIsCurrent(cache) then return cache end

    -- A live session has no stored cache: it is presented in the same shape from
    -- what the game's damage meter has reported so far, so everything that draws
    -- a session draws this one with the code it already has.
    if ns.Live then return ns.Live:Cache(key) end
    return nil
end

-- Aggregates a stream into a CACHE, yielding between chunks so the client stays
-- responsive. onDone(cache) fires when finished; onProgress(done, total) is
-- optional. Returns immediately.
function API:BuildCache(key, onDone, onProgress)
    local stream, err = self:LoadStream(key)
    if not stream then
        if onDone then onDone(nil, err) end
        return
    end

    -- Units are keyed by name rather than by index. Names are stable across a
    -- reparse, readable in the stored cache, and collapse the many transient
    -- GUIDs a battleground creates for identically named creatures into one
    -- entry. The stream's numeric indices stay an encoding detail.
    local nameOf = {}   -- stream unit index -> name it contributes to
    local nameByGuid = {}   -- unit GUID -> that same name
    local rawKind = {}  -- stream unit index -> what THAT unit is, before rollup
    local rawReact = {} -- stream unit index -> that unit's own reaction, ditto
    local UNITS = {}

    local function UnitEntry(name)
        local entry = UNITS[name]
        if not entry then
            entry = { name = name, cols = {}, counts = {}, by = {} }
            for c = 1, #FORMAT_COLUMNS do
                entry.cols[c] = 0
                entry.counts[c] = 0
            end
            UNITS[name] = entry
        end
        return entry
    end

    local function SetIdentity(entry, u)
        entry.guid     = u[1]
        entry.flags    = u[3]
        entry.level    = u[5]
        entry.kind     = UnitKind(u[3])
        entry.reaction = UnitReaction(u[3])
    end

    -- Identity is taken from units that own themselves, in a pass of their own.
    -- Doing this inline while rolling pets up meant a pet appearing before its
    -- owner stamped the owner's entry with the PET's flags, leaving a real
    -- player typed as "pet" - excluded from the roster join, so their row read
    -- zero and would not expand.
    for _, u in ipairs(stream.units) do
        if u[4] == 0 then
            SetIdentity(UnitEntry((u[2] ~= "" and u[2]) or u[1]), u)
        end
    end

    for i, u in ipairs(stream.units) do
        -- Pets and guardians contribute to their owner: a warlock's damage is
        -- not meaningfully separate from its felguard's, and rolling up here
        -- means nothing downstream has to walk a parent chain.
        local name = (u[2] ~= "" and u[2]) or u[1]
        local ownerIndex = u[4]
        local guard = 0
        while ownerIndex ~= 0 and stream.units[ownerIndex] and guard < 16 do
            local owner = stream.units[ownerIndex]
            name = (owner[2] ~= "" and owner[2]) or owner[1]
            ownerIndex = owner[4]
            guard = guard + 1   -- a cycle in the owner chain must not hang
        end
        nameOf[i] = name
        rawKind[i] = UnitKind(u[3])
        rawReact[i] = UnitReaction(u[3])
        -- GUID to the name its output lands under, which is what lets
        -- COMBATANT_INFO join: it identifies people by GUID and the cache
        -- stores units by name and keeps no GUID of its own.
        nameByGuid[u[1]] = name

        -- An orphan whose owner never appeared standalone still needs an entry.
        local entry = UnitEntry(name)
        if not entry.guid then SetIdentity(entry, u) end
    end

    -- COMBATANT_INFO, rekeyed from GUID to unit name. The chunk identifies
    -- combatants by GUID because that is what the log does; the cache stores
    -- units by name and carries no GUID at all, so the join is resolved once
    -- here rather than being impossible later.
    --
    -- Empty for every battleground, which emits none of these.
    local CI = nil
    for _, c in ipairs(stream.combatants or {}) do
        local name = nameByGuid[c[1]]
        if name then
            CI = CI or {}
            -- f faction (0 or 1), s spec id, h honor level, r rating before
            -- the match. Season and tier are carried by the log and dropped
            -- here: nothing reads them.
            CI[name] = { f = c[2], s = c[3], h = c[4], r = c[6] }
        end
    end

    local t, k   = stream.t,  stream.k
    local s, d   = stream.s,  stream.d
    local am, ov = stream.am, stream.ov
    local sp     = stream.sp
    local spells = stream.spells
    local total  = #t

    local events = {}
    local dmgDone, dmgTaken   = COL["Damage Done"], COL["Damage Taken"]
    local healDone, healTaken = COL["Healing Done"], COL["Healing Taken"]
    local overCol             = COL["Overhealing"]
    local interruptCol, dispelCol = COL["Interrupts"], COL["Dispels"]
    local purgeCol            = COL["Purges"]
    local deathCol            = COL["Deaths"]
    local kbCol               = COL["Killing Blows"]
    local ccDone, ccTaken     = COL["CC Done"], COL["CC Taken"]

    local categoryOf = ns.SpellCategory
    local CC = "cc"

    -- Open crowd control, so a duration can be closed out on aura removal.
    -- Keyed by victim name then spell id.
    local openCC = {}

    -- Dampening is an ordinary stacking debuff, one stack per point, so the
    -- largest dose anyone reached is the figure the match ended on. That makes
    -- it the one piece of arena state recoverable from a log with no help from
    -- the client at all.
    local DAMPENING = 110310
    local maxDampening = 0

    -- Faction by player name, from the racials they cast. The only account a
    -- log gives of which side anyone actually plays - see Spells.lua.
    local racialOf = ns.RACIAL_FACTION or {}
    local factionOf = nil

    -- Adds to a total and, when the column names a counterpart, to that unit's
    -- per-counterpart breakdown.
    -- Spell names are held once per session and referenced by id, rather than
    -- repeated inside every counterpart's spell table. With a dozen spells
    -- against twenty counterparts for twenty players, repeating the strings
    -- would dominate the stored cache.
    local spellNames = { [0] = "Melee" }

    -- Spell school mask, as the stream carries it. A melee swing has no spell
    -- and so no school field; it is physical by definition, which is what the
    -- zero slot stands for. Older chunks predate the field entirely and simply
    -- leave this empty, which reads downstream as "school unknown".
    local spellSchools = { [0] = 1 }

    -- A dispel row reads "<aura removed> (<spell used>)", so the pair needs one
    -- id to key the breakdown by - the stored format carries a single spell id
    -- per entry, and widening it for this alone is not worth the bytes.
    --
    -- Keying by the aura's own id instead would be wrong: Shadow Word: Pain is
    -- a damage spell as well as a dispel target, and relabelling its name would
    -- follow it into every damage breakdown in the session. Synthetic ids sit
    -- far above anything Blizzard issues, so they cannot collide with a real
    -- one, and only dispel and purge columns ever refer to them.
    local COMPOSITE_BASE = 1000000000
    local compositeIds, nextComposite = {}, COMPOSITE_BASE

    -- Synthetic id back to the real spell it leads with, so a shell can still
    -- reach an icon and the client tooltip. Without it these rows were the only
    -- ones in the grid with no icon.
    local compositeSpell = {}

    local function CompositeSpell(auraIndex, dispelId)
        local aura = auraIndex ~= 0 and spells[auraIndex]
        -- No aura recorded: fall back to naming the dispel itself, which is
        -- what the old format showed and is better than an unnamed row.
        if not aura then return dispelId end

        local tag = aura[1] .. ":" .. (dispelId or 0)
        local id = compositeIds[tag]
        if not id then
            nextComposite = nextComposite + 1
            id = nextComposite
            compositeIds[tag] = id
            compositeSpell[id] = aura[1]

            local used = dispelId and dispelId ~= 0 and spellNames[dispelId]
            spellNames[id] = used and (aura[2] .. " (" .. used .. ")") or aura[2]
        end
        return id
    end

    -- Self counts as a counterpart. A unit healing or damaging itself is real
    -- output and is listed by name like anyone else, so a self-healer's row can
    -- be opened to see how much of their healing was on themselves.
    -- `partial` marks a value that is one piece of a cast still being added up.
    -- Its count, smallest and largest are left alone here and settled when the
    -- cast closes, from the cast's own total; the pairing and spell it landed in
    -- are returned so the cast can find them again.
    local function AddBreakdown(entry, col, other, value, count, spellId, partial)
        if not other then return end

        local map = entry.by[col]
        if not map then map = {}; entry.by[col] = map end
        local slot = map[other]
        if not slot then slot = { v = 0, n = 0 }; map[other] = slot end
        slot.v = slot.v + value
        slot.n = slot.n + count

        -- Which spells made up this pairing. Keyed by id; the name lives in the
        -- session's spell table.
        --
        -- Smallest and largest are tracked alongside the sum because they cannot
        -- be recovered from it: an average says a spell hit for 40k, and only the
        -- range says whether that was every cast or one crit carrying twenty
        -- glancing ticks. Two numbers per spell is the cheapest way to answer a
        -- question the totals genuinely cannot.
        local use
        if spellId then
            local spells = slot.s
            if not spells then spells = {}; slot.s = spells end
            use = spells[spellId]
            if not use then
                use = { v = 0, n = 0 }
                spells[spellId] = use
            end
            use.v = use.v + value
            if not partial then
                use.n = use.n + count
                if not use.mn or value < use.mn then use.mn = value end
                if not use.mx or value > use.mx then use.mx = value end
            end
        end
        return slot, use
    end

    local function Add(entry, col, other, value, count, spellId)
        entry.cols[col]   = entry.cols[col] + value
        entry.counts[col] = entry.counts[col] + count
        AddBreakdown(entry, col, other, value, count, spellId)
    end

    ----------------------------------------------------------------------------
    -- Casts
    --
    -- Damage, healing and absorbs are counted in casts, not in log lines. The
    -- log writes a line per tick of a DoT, per absorbed hit on a shield, per bolt
    -- of a channel - a single Life Cocoon that soaked thirty hits was thirty
    -- lines, and was being shown as thirty casts averaging a thirtieth of what it
    -- actually absorbed. What anyone reading a breakdown wants is what one cast
    -- did, so each line is assigned to the cast it came from and a cast's count,
    -- average, smallest and largest are its whole total.
    --
    -- The log never says which cast a line came from, so it is inferred, per
    -- source, target and spell NAME - by name because a spell's effect often
    -- has an id of its own: Spinning Crane Kick is cast as 101546 and hits as
    -- 107270, Consecration is cast as 26573, ticks as 81297 and slows as 204242.
    -- Three rules, in order:
    --
    --   * An aura - a DoT, a HoT, a shield, a channel's debuff - is one cast from
    --     application to removal, and a reapplication is a new one. Everything
    --     under that name from that source on that target in between is it.
    --   * Otherwise, a spell the source casts: each SPELL_CAST_SUCCESS is a cast,
    --     and a hit belongs to the earliest cast this target has not been hit by
    --     yet that is recent enough to have caused it - so a projectile landing
    --     after the next cast began still counts against its own cast, and a
    --     channel's later ticks stay with the cast that started it.
    --   * Otherwise - a proc, a passive, anything never cast under its own name -
    --     each hit is its own, except hits landing in the same instant.
    --
    -- Melee swings are always one each.
    --
    -- Against a full evening's log this matched Life Cocoon 8 for 8, Spinning
    -- Crane Kick 31 per-target casts to 32 casts, and put every Consecration at
    -- 20 ticks or fewer where the per-line count had one running to 658.
    --
    -- A cast has two sides. For the target it is simply what landed on them.
    -- For the caster, one cast can land on several targets - a Wild Growth, a
    -- Power Word: Radiance - and those pieces are one cast in the caster's own
    -- spell totals: "whole" below. Per target, in a breakdown's counterpart
    -- rows, each target's share stays its own.
    ----------------------------------------------------------------------------

    local LINK_MS   = 250    -- an event this close to an application or removal belongs to it
    local FLIGHT_MS = 1500   -- the longest a cast's first hit can trail the cast
    local BURST_MS  = 50     -- hits of an uncast effect this close together are one
    local RECENT    = 8      -- casts remembered per source and spell

    -- Spell names as small integers, so the keys below can be numbers and a
    -- quarter of a million events do not each build a string.
    local nameIds, nameCount = {}, 0
    local nameIdOf = {}      -- spell index -> name id
    local function NameId(spellIndex)
        local id = nameIdOf[spellIndex]
        if id then return id end
        local row = spells[spellIndex]
        local name = row and row[2] or ("#" .. spellIndex)
        id = nameIds[name]
        if not id then
            nameCount = nameCount + 1
            id = nameCount
            nameIds[name] = id
        end
        nameIdOf[spellIndex] = id
        return id
    end

    local open    = {}    -- source, target, name -> the cast still collecting
    local claimed = {}    -- source, target, name -> the last cast it was hit by
    local castLog = {}    -- source, name -> { n = casts so far, [serial] = time }
    local wholes  = {}    -- source, name -> serial -> the cast across targets
    local early   = {}    -- source, name -> applications still waiting for their cast

    local function NewWhole()
        return { acc = {}, open = 0 }
    end

    -- The caster's view of a cast is shared by every target it landed on, so
    -- casts that claimed the same serial meet here. Anything with no cast behind
    -- it gets one of its own.
    local function WholeFor(castKey, serial)
        if not serial then return NewWhole() end
        local bySerial = wholes[castKey]
        if not bySerial then bySerial = {}; wholes[castKey] = bySerial end
        local whole = bySerial[serial]
        if not whole then
            whole = NewWhole()
            whole.key, whole.serial = castKey, serial
            bySerial[serial] = whole
        end
        return whole
    end

    -- The unit's running figures for one spell name in one column: casts,
    -- smallest, largest, and every id the name was seen under. By name, because
    -- that is how spell totals are drawn - Penance hits under one id and heals
    -- under another, and one cast of it is still one cast.
    local function WholeOf(entry, col, name)
        entry.whole = entry.whole or {}
        local totals = entry.whole[col]
        if not totals then totals = {}; entry.whole[col] = totals end
        local w = totals[name]
        if not w then w = { n = 0, ids = {} }; totals[name] = w end
        return w
    end

    -- A finished cast into the per-spell and per-column figures of every unit it
    -- was credited to.
    local function SettleWhole(whole)
        for entry, cols in pairs(whole.acc) do
            for col, byName in pairs(cols) do
                entry.counts[col] = entry.counts[col] + 1
                for name, total in pairs(byName) do
                    local w = WholeOf(entry, col, name)
                    w.n = w.n + 1
                    if not w.mn or total < w.mn then w.mn = total end
                    if not w.mx or total > w.mx then w.mx = total end
                end
            end
        end
    end

    local function CloseCast(key)
        local cast = open[key]
        if not cast then return end
        open[key] = nil

        for use, total in pairs(cast.uses) do
            use.n = use.n + 1
            if not use.mn or total < use.mn then use.mn = total end
            if not use.mx or total > use.mx then use.mx = total end
        end
        for slot in pairs(cast.slots) do slot.n = slot.n + 1 end

        -- The target's side: this cast is all of it.
        SettleWhole(cast)

        local whole = cast.whole
        whole.open = whole.open - 1
        if whole.open == 0 then
            SettleWhole(whole)
            -- A target hit later still by the same cast - rare, and only ever a
            -- straggler - starts a fresh one rather than reopening a settled one.
            if whole.key then wholes[whole.key][whole.serial] = nil end
        end
    end

    -- The earliest cast after `after` recent enough to have caused a hit now.
    local function FreshCast(castKey, after, now)
        local log = castLog[castKey]
        if not log then return nil end
        for serial = math.max(after + 1, log.n - RECENT + 1), log.n do
            local at = log[serial]
            if at and at >= now - FLIGHT_MS then return serial end
        end
        return nil
    end

    local function OpenCast(key, castKey, now, aura, serial)
        if serial then claimed[key] = serial end
        local cast = {
            key = key, t0 = now, last = now, aura = aura, serial = serial or 0,
            uses = {}, slots = {}, acc = {},
        }
        cast.whole = WholeFor(castKey, serial)
        cast.whole.open = cast.whole.open + 1
        open[key] = cast
        return cast
    end

    local function Keys(i, nameId)
        local castKey = s[i] * 65536 + nameId
        return castKey * 65536 + d[i], castKey
    end

    -- The cast event i belongs to, opened if need be. The third return is true
    -- for a melee swing, which the caller closes as soon as it is credited.
    local function CastFor(i)
        local now = t[i]
        local spellIndex = sp[i]
        if spellIndex == 0 then
            local key = -(s[i] * 65536 + d[i]) - 1
            CloseCast(key)
            return OpenCast(key, 0, now, false, nil), key, true
        end

        local key, castKey = Keys(i, NameId(spellIndex))
        local cast = open[key]
        local serial
        if cast then
            local split
            if cast.removedAt then
                split = now - cast.removedAt > LINK_MS
            elseif cast.aura then
                split = false
            elseif castLog[castKey] then
                serial = FreshCast(castKey, claimed[key] or 0, now)
                split = serial ~= nil and serial > cast.serial
            else
                split = now - cast.last > BURST_MS
            end
            if split then
                CloseCast(key)
                cast = nil
            end
        end

        if not cast then
            local log = castLog[castKey]
            if log then
                serial = serial or FreshCast(castKey, claimed[key] or 0, now) or log.n
            end
            cast = OpenCast(key, castKey, now, false, serial)
        end
        cast.last = now
        return cast, key, false
    end

    -- One event's worth of a cast, credited to one unit's column. `whole` is what
    -- the unit's own spell totals count it as: the cast across every target for
    -- the unit that cast it, this target's share for the unit it landed on.
    local function Credit(cast, whole, entry, col, other, value, spellId)
        entry.cols[col] = entry.cols[col] + value

        local slot, use = AddBreakdown(entry, col, other, value, 0, spellId, true)
        if use then cast.uses[use] = (cast.uses[use] or 0) + value end
        if slot then cast.slots[slot] = true end

        local name = spellNames[spellId] or spellId
        WholeOf(entry, col, name).ids[spellId] = true

        local cols = whole.acc[entry]
        if not cols then cols = {}; whole.acc[entry] = cols end
        local byName = cols[col]
        if not byName then byName = {}; cols[col] = byName end
        byName[name] = (byName[name] or 0) + value
    end

    -- Aura boundaries. An application just after a direct hit under the same
    -- name is that hit's own cast carrying on - Moonfire lands, then its DoT goes
    -- up - so it is adopted rather than starting another.
    local function AuraApplied(i)
        local spellIndex = sp[i]
        if spellIndex == 0 then return end
        local key, castKey = Keys(i, NameId(spellIndex))
        local now = t[i]
        local cast = open[key]
        if cast and not cast.aura and not cast.removedAt and now - cast.t0 <= LINK_MS then
            cast.aura = true
            return
        end
        CloseCast(key)
        local serial = castLog[castKey] and FreshCast(castKey, claimed[key] or 0, now) or nil
        cast = OpenCast(key, castKey, now, true, serial)

        -- The caster's own copy of a spell that lands on several people is
        -- written a moment BEFORE the cast itself: Wild Growth goes up on the
        -- druid, then SPELL_CAST_SUCCESS, then everyone else. Held here so the
        -- cast can claim it when it arrives, or it would stand as a cast of its
        -- own and every Wild Growth would count twice.
        --
        -- Kept as one batch per source and spell, restarted once it is too old
        -- for a cast to claim. Most applications with no cast behind them never
        -- get one - every Atonement a discipline priest's damage puts up - and a
        -- list that only grew would hold all of them to the end of the log.
        if not serial then
            local waiting = early[castKey]
            if not waiting or now - waiting.t > LINK_MS then
                waiting = { t = now }
                early[castKey] = waiting
            end
            waiting[#waiting + 1] = cast
        end
    end

    -- An application that went up just before its cast joins that cast: the
    -- piece of it credited so far moves to the cast's shared whole.
    local function Adopt(cast, castKey, serial)
        local old, whole = cast.whole, WholeFor(castKey, serial)
        for entry, cols in pairs(old.acc) do
            local into = whole.acc[entry]
            if not into then into = {}; whole.acc[entry] = into end
            for col, byName in pairs(cols) do
                local c = into[col]
                if not c then c = {}; into[col] = c end
                for name, value in pairs(byName) do c[name] = (c[name] or 0) + value end
            end
        end
        -- The whole it leaves was its alone, and is dropped unsettled.
        old.open = old.open - 1
        whole.open = whole.open + 1
        cast.whole, cast.serial = whole, serial
        claimed[cast.key] = serial
    end

    local function AuraRemoved(i)
        local spellIndex = sp[i]
        if spellIndex == 0 then return end
        local cast = open[(Keys(i, NameId(spellIndex)))]
        if cast and cast.aura then cast.removedAt = t[i] end
    end

    local function CastSucceeded(i)
        local spellIndex = sp[i]
        if spellIndex == 0 then return end
        local _, castKey = Keys(i, NameId(spellIndex))
        local log = castLog[castKey]
        if not log then log = { n = 0 }; castLog[castKey] = log end
        log.n = log.n + 1
        log[log.n] = t[i]
        log[log.n - RECENT] = nil

        local waiting = early[castKey]
        if waiting then
            for _, cast in ipairs(waiting) do
                if open[cast.key] == cast and cast.serial == 0
                   and t[i] - cast.t0 <= LINK_MS then
                    Adopt(cast, castKey, log.n)
                end
            end
            early[castKey] = nil
        end
    end

    -- One table rather than six locals, for the event loop's sake. Lua 5.1 lets
    -- a function reach at most sixty variables from outside itself, the loop
    -- below was already close, and going over is not a warning: the whole file
    -- fails to compile, the API is never created, and the viewer reports there
    -- is nothing to view.
    local Casts = {
        For = CastFor, Credit = Credit, Close = CloseCast,
        Applied = AuraApplied, Removed = AuraRemoved, Succeeded = CastSucceeded,
    }

    -- Whatever was still collecting when the log ran out is finished now.
    -- Clearing a field during a traversal is allowed; CloseCast only ever
    -- clears the one it was given.
    function Casts.CloseAll()
        for openKey in pairs(open) do CloseCast(openKey) end
    end

    -- Everything after the last event, in a function of its own. It runs once,
    -- and written inside the loop it counted against the loop's upvalue limit
    -- as though it ran for every slice.
    local function Finish()
        -- Counted before trimming drops the rows it would be counted into.
        Casts.CloseAll()

        BuildEventContext(stream, nameOf, UNITS, events, function()
            TrimBreakdowns(UNITS)

            local unitCount = 0
            for _ in pairs(UNITS) do unitCount = unitCount + 1 end

            local N, U, E = Compact(UNITS, events)

            -- Only spells still referenced are worth keeping, since trimming
            -- and compaction may have dropped the rest. Composites carry a
            -- second entry pointing at the real spell they lead with, kept
            -- on the same "only if still referenced" basis.
            local usedSpells, usedComposites, usedSchools = {}, {}, {}
            local function Keep(id)
                usedSpells[id] = spellNames[id] or ("spell " .. id)
                local school = spellSchools[id]
                if compositeSpell[id] then
                    usedComposites[id] = compositeSpell[id]
                    -- A composite is a label over a pair, so it has no
                    -- school of its own; it borrows the one belonging to
                    -- the spell it leads with.
                    school = school or spellSchools[compositeSpell[id]]
                end
                if school then usedSchools[id] = school end
            end

            for _, unit in pairs(U) do
                for _, flat in pairs(unit.s or {}) do
                    for i = 2, #flat, 6 do Keep(flat[i]) end
                end
            end
            for _, event in ipairs(E) do
                for i = 5, #event.c, 6 do
                    if event.c[i] ~= 0 then Keep(event.c[i]) end
                end
            end

            -- Short field names throughout: every one is written to disk
            -- once per session, and the viewer is the only reader.
            local cache = {
                FORMAT = {
                    version  = DEFINES_VERSION,
                    taxonomy = ns.SPELL_TAXONOMY_VERSION,
                    columns  = FORMAT_COLUMNS,
                },
                N  = N,           -- interned unit names
                U  = U,           -- units, indexed into N
                E  = E,           -- death events, flat context runs
                SP = usedSpells,      -- [spellId] = name
                SX = usedComposites,  -- [syntheticId] = the real spell
                SS = usedSchools,     -- [spellId] = school mask
                CI = CI,              -- [name] = combatant info, arena only
                FA = factionOf,       -- [name] = "Alliance" or "Horde"
                -- Highest dampening stack anyone reached, or nil outside an
                -- arena where the debuff never exists.
                dampening = maxDampening > 0 and maxDampening or nil,
                -- The chunk is deleted by the application once consumed, so
                -- everything the viewer needs has to be copied in here.
                header     = stream.header,
                key        = key,
                eventCount = total,
                unitCount  = unitCount,
            }
            if ns.db then
                ns.db.cache = ns.db.cache or {}
                ns.db.cache[key] = cache
            end
            -- Before anyone is told, so a listener asking where a live
            -- session went already gets the answer.
            SweepLive()
            NotifyCacheChanged(key)
            if onDone then onDone(cache) end
        end)
    end

    local index = 1
    local CHUNK = 20000   -- ~4-8ms per slice on the reference battleground

    local function Step()
        local stop = math.min(index + CHUNK - 1, total)

        for i = index, stop do
            local kind = k[i]
            local srcName = s[i] ~= 0 and nameOf[s[i]] or nil
            local dstName = d[i] ~= 0 and nameOf[d[i]] or nil
            local amount  = am[i]

            -- Resolved once per event rather than per column. Id 0 means no
            -- spell was involved, which is a melee swing.
            local spellIndex = sp[i]
            local spellRow   = spellIndex ~= 0 and spells[spellIndex] or nil
            local spellId    = spellRow and spellRow[1] or 0
            if spellRow and spellNames[spellId] == nil then
                spellNames[spellId] = spellRow[2]
                spellSchools[spellId] = spellRow[3]
            end

            if IS_DAMAGE[kind] then
                -- Damage that never crossed the line between the two sides is
                -- not output. Ultimate Sacrifice, Touch of Karma and the rest
                -- were being counted twice - once as done and once as taken -
                -- which credited a player with damage nobody else ever
                -- received. It is real damage and it is still counted where it
                -- landed, which is Damage Taken.
                --
                -- Self-damage is the obvious case, but not the only one: a
                -- Lightsmith paladin's Tempered in Battle damages the paladin's
                -- own allies to fuel its healing, and every one of its damage
                -- events in the reference log named two units on the same team.
                -- Testing the reaction rather than the name covers both, and
                -- covers whatever the next expansion invents, without a spell
                -- list to maintain. Sides come from the log's own flags, which
                -- describe everyone relative to the recording player, so
                -- hostile-on-hostile is the enemy team hitting itself exactly
                -- as friendly-on-friendly is ours.
                local reflexive = srcName ~= nil and dstName ~= nil
                    and (srcName == dstName
                         or rawReact[s[i]] == rawReact[d[i]])

                local cast, castKey, single = Casts.For(i)
                if srcName and not reflexive then
                    Casts.Credit(cast, cast.whole, UnitEntry(srcName), dmgDone, dstName, amount, spellId)
                end
                if dstName then
                    Casts.Credit(cast, cast, UnitEntry(dstName), dmgTaken, srcName, amount, spellId)
                end
                if single then Casts.Close(castKey) end

                -- Overkill above zero marks the killing blow, and is the only
                -- attribution available: UNIT_DIED carries no source, and
                -- PARTY_KILL covers party members only. It names the killer but
                -- does not count the death - UNIT_DIED does that - because a
                -- death can occur with no overkill damage behind it (a periodic
                -- tick landing exactly, or environmental damage). Counting here
                -- as well would miss those; counting only there would lose the
                -- killer. The total may therefore exceed the breakdown.
                if ov[i] > 0 and dstName and rawKind[d[i]] == "player" then
                    AddBreakdown(UnitEntry(dstName), deathCol, srcName, 1, 1, spellId)

                    -- The same event read from the other end. Killing Blows is
                    -- the count of these, which is why it can differ from the
                    -- sum of everyone else's Deaths: a kill with no overkill
                    -- behind it is a death with no killer. Dying to your own
                    -- spell is not a killing blow for anyone.
                    if srcName and not reflexive then
                        Add(UnitEntry(srcName), kbCol, dstName, 1, 1, spellId)
                    end
                end

            elseif IS_HEAL[kind] then
                -- Overhealing is included in amount, so effective healing is
                -- the remainder.
                local effective = amount - ov[i]
                local cast, castKey, single = Casts.For(i)
                if srcName then
                    Casts.Credit(cast, cast.whole, UnitEntry(srcName), healDone, dstName, effective, spellId)
                    -- Credited only when there was overhealing, so the count is
                    -- "casts that overhealed" rather than "casts".
                    if ov[i] > 0 then
                        Casts.Credit(cast, cast.whole, UnitEntry(srcName), overCol, dstName, ov[i], spellId)
                    end
                end
                if dstName then
                    Casts.Credit(cast, cast, UnitEntry(dstName), healTaken, srcName, effective, spellId)
                end
                if single then Casts.Close(castKey) end

            elseif kind == K.SPELL_ABSORBED then
                -- src is the ABSORBER, rewritten by the application; the
                -- attacker arrives separately as DAMAGE_ABSORBED.
                --
                -- Damage prevented is healing: it is counted in Healing Done for
                -- the shielder and Healing Taken for the shielded, the same as a
                -- direct heal, and the shield spell shows up in the breakdown
                -- alongside them.
                --
                -- This does not reproduce the scoreboard, and no rule does. One
                -- healer matched to the exact gold with absorbs excluded, while
                -- a DPS with 6.35M of self-shields reads 135% high with them
                -- included. Blizzard's healing figure is not a function of the
                -- log; counting prevented damage as healing is at least a rule
                -- that can be stated.
                local cast, castKey, single = Casts.For(i)
                if srcName then
                    Casts.Credit(cast, cast.whole, UnitEntry(srcName), healDone, dstName, amount, spellId)
                end
                if dstName then
                    Casts.Credit(cast, cast, UnitEntry(dstName), healTaken, srcName, amount, spellId)
                end
                if single then Casts.Close(castKey) end

            elseif kind == K.INTERRUPT then
                -- Named for the spell that was stopped, with the interrupt in
                -- parentheses: "Polymorph (Kick)". A bare "Kick" says nothing
                -- about what it was worth.
                if srcName then
                    Add(UnitEntry(srcName), interruptCol, dstName, 1, 1,
                        CompositeSpell(am[i], spellId))
                end

            elseif kind == K.DISPEL or kind == K.PURGE then
                -- The application put the removed aura's spell index in the
                -- amount column, which a dispel otherwise leaves at zero, and
                -- split the two directions by auraType: a debuff off a friend
                -- is a dispel, a buff off an enemy is a purge, and a spell
                -- steal is a purge because it takes a buff.
                --
                -- Only counted when the aura came off a PLAYER. A summoned
                -- guardian that shrugs a root off itself is logged as a dispel
                -- by whoever owns it - a druid's treants each produce one, so a
                -- single cast of anything that roots them credits the druid
                -- with a handful of dispels they did not perform, named after
                -- the spell that rooted them. What this column is for is a
                -- player taking something off another player, and that is what
                -- it now counts.
                local col = (kind == K.DISPEL) and dispelCol or purgeCol
                if srcName and dstName and rawKind[d[i]] == "player" then
                    Add(UnitEntry(srcName), col, dstName, 1, 1,
                        CompositeSpell(am[i], spellId))
                end

            elseif kind == K.AURA_REFRESH then
                -- Reapplied before it ran out: a DoT or HoT cast again, which is
                -- a new cast of it.
                Casts.Applied(i)

            elseif kind == K.AURA_APPLIED then
                Casts.Applied(i)

                local spellIndex = sp[i]
                local spellId = spellIndex ~= 0 and spells[spellIndex]
                                and spells[spellIndex][1] or nil
                if spellId and categoryOf[spellId] == CC and dstName then
                    local perVictim = openCC[dstName]
                    if not perVictim then perVictim = {}; openCC[dstName] = perVictim end
                    -- A re-application while still active keeps the original
                    -- start, so overlapping refreshes do not double count.
                    if not perVictim[spellId] then
                        perVictim[spellId] = { t = t[i], src = srcName }
                    end
                end

            elseif kind == K.AURA_REMOVED then
                Casts.Removed(i)

                local spellIndex = sp[i]
                local spellId = spellIndex ~= 0 and spells[spellIndex]
                                and spells[spellIndex][1] or nil
                local perVictim = dstName and openCC[dstName]
                local opened = perVictim and spellId and perVictim[spellId]
                if opened then
                    perVictim[spellId] = nil
                    local ms = t[i] - opened.t
                    if ms > 0 then
                        -- Attributed to the spell that opened the effect, which
                        -- is the key this was stored under, so a counterpart can
                        -- be opened to see which fears and stuns made up the
                        -- time rather than only the total.
                        if opened.src then
                            Add(UnitEntry(opened.src), ccDone, dstName, ms, 1, spellId)
                        end
                        Add(UnitEntry(dstName), ccTaken, opened.src, ms, 1, spellId)
                    end
                end

            elseif kind == K.CAST_SUCCESS then
                Casts.Succeeded(i)

                local spellIndex = sp[i]
                local cast = spellIndex ~= 0 and spells[spellIndex]
                             and spells[spellIndex][1] or nil
                local faction = cast and racialOf[cast]
                if faction and srcName then
                    factionOf = factionOf or {}
                    factionOf[srcName] = faction
                end

            elseif kind == K.AURA_APPLIED_DOSE then
                local spellIndex = sp[i]
                local dosed = spellIndex ~= 0 and spells[spellIndex]
                              and spells[spellIndex][1] or nil
                if dosed == DAMPENING and amount > maxDampening then
                    maxDampening = amount
                end

            elseif kind == K.UNIT_DIED then
                -- Only units that are themselves players.
                --
                -- Everything a pet does rolls up to its owner, which is right
                -- for damage and healing and wrong for dying: a warlock's
                -- felguard, a mage's water elemental and a shaman's totems were
                -- all adding to their owner's death count. The rollup name is
                -- still used for the entry, so a pet death would land on the
                -- player - the guard has to be on what the unit IS, before the
                -- rollup, which is what rawKind carries.
                --
                -- Feign Death is the other thing this guard keeps out. It writes
                -- a genuine UNIT_DIED for a hunter who is still standing, and
                -- the only thing separating the two is the unconsciousOnDeath
                -- field the application carries here in the amount column.
                --
                -- Not detected from the aura, which was the obvious approach and
                -- is wrong: the talent that grants it applies Survival Tactics
                -- (202748) rather than Feign Death (5384), so watching for the
                -- named spell finds nothing. A chunk written before the field
                -- existed reads zero and counts the death, which is what it
                -- did before.
                local unconscious = am[i] == 1
                if dstName and rawKind[d[i]] == "player" and not unconscious then
                    Add(UnitEntry(dstName), deathCol, nil, 1, 1)
                    events[#events + 1] = {
                        name = "death", t = t[i], unit = dstName, at = i,
                    }
                end
            end
        end

        index = stop + 1
        if onProgress then onProgress(stop, total) end

        if index <= total then
            C_Timer.After(0, Step)
        else
            Finish()
        end
    end

    Step()
end

--------------------------------------------------------------------------------

-- PLAYER_LOGIN rather than ADDON_LOADED: CombatSession_Data depends on this
-- addon and therefore loads after it, so the index does not exist yet at
-- ADDON_LOADED time.
ns:RegisterEvent("PLAYER_LOGIN", function()
    -- First, because it is the one thing here that still has to happen when
    -- the versions disagree - it is how the application finds out that they do.
    ns:RecordAppVersion()

    -- Said once at login, in full, because chat is where a user can read a
    -- sentence and an address without the room a window has. The viewer's title
    -- bar carries the short form for anyone who missed it.
    local versions = ns.AppVersions()
    if versions.state == "addon" then
        ns:Print("|cffff5555the addon is out of date.|r "
            .. ("It was built for CombatSession %s and the application is %s. ")
               :format(versions.expectedText, versions.currentText)
            .. "|cffffffffUpdate CombatSession in your addon manager|r, or get it "
            .. "from |cff66bbffcurseforge.com/wow/addons/combatsession|r, then /reload.")
    elseif versions.state == "app" then
        ns:Print("|cffff5555the CombatSession application is out of date.|r "
            .. ("You are running %s and this addon needs %s or later. ")
               :format(versions.currentText, versions.expectedText)
            .. "|cffffffffOpen the CombatSession application and click "
            .. "\"Get the App (GitHub)\"|r at the bottom of its window - it will "
            .. "walk you through replacing it.")
    end

    DropStaleCaches()
    -- Stand-ins whose log was built in an earlier session, before anything here
    -- asked for the list.
    SweepLive()
    API:ProcessPending(function(processed, skipped)
        if processed == 0 then return end
        if skipped > 0 then
            ns:Print(("processed %d session(s); skipped %d beyond the %d-session limit")
                :format(processed, skipped, API:GetMaxSessions()))
        else
            ns:Debug(("processed %d session(s)"):format(processed))
        end
        if ns.UI then ns.UI:Refresh() end
    end)
end)

_G.CombatSessionAPI = API
