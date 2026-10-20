-- CombatSession :: Recorder
--
-- Captures the match metadata that the combat log does not contain. Rated
-- status, match outcome, and battleground rosters exist only in the live client
-- API: battlegrounds emit no start/end event, and rated BG / Blitz run on the
-- same maps as random BGs, so nothing in the log distinguishes them.
--
-- Two snapshots per match:
--   entry      - taken on entering the instance. Rated status is valid here,
--                which matters because a player who leaves early never fires
--                PVP_MATCH_COMPLETE and so never reaches the completion path.
--   completion - taken on PVP_MATCH_COMPLETE, where the scoreboard is readable.
--
-- The rated predicate mirrors REFlex, which solves this correctly.

local ADDON, ns = ...

local Recorder = {}
ns.Recorder = Recorder

-- The match currently being observed, or nil outside a PvP instance.
local current = nil

-- Outside a match: the fight being watched, and a finished one waiting for the
-- meter to settle. See "Bouts"; declared here because logging consults them.
local bout = nil
local pending = nil

-- How long a match interrupted by the UI shutting down stays adoptable.
--
-- A reload is indistinguishable from a logout at the moment it happens - both
-- fire PLAYER_LOGOUT and nothing says which - so the match is stored either way
-- and the next entry into the same instance decides. A reload takes seconds;
-- anything older than this was a logout, and the match it belonged to is over.
--
-- Shared with the live session, which has to make the same decision about the
-- same event and must not make it differently.
ns.RESUME_WINDOW = 600

--------------------------------------------------------------------------------
-- Client API guards
--
-- Every C_PvP entry point is probed rather than called directly: this addon has
-- to survive an API being renamed or removed in a patch without the recorder
-- silently dropping an entire match.
--------------------------------------------------------------------------------

local function PvPFlag(name)
    local fn = C_PvP and C_PvP[name]
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn)
    if not ok then return nil end
    return result
end

local function Global(name, ...)
    local fn = _G[name]
    if type(fn) ~= "function" then return nil end
    local results = { pcall(fn, ...) }
    if not results[1] then return nil end
    return unpack(results, 2)
end

--------------------------------------------------------------------------------
-- Instance classification
--------------------------------------------------------------------------------

local function InstanceInfo()
    local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
    return name, instanceType, instanceID
end

-- The combat log writes uiMapID in MAP_CHANGE lines, while GetInstanceInfo
-- returns an instance id from a different id space. Both are recorded so the
-- app can correlate a session's log lines to the match the recorder saw.
local function CurrentUiMap()
    if not (C_Map and type(C_Map.GetBestMapForUnit) == "function") then return nil end
    local ok, id = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok then return nil end
    return id
end

local function IsPvPInstance(instanceType)
    return instanceType == "arena" or instanceType == "pvp"
end

-- REFlex's predicate. Skirmishes and unrated Solo Shuffle both report true for
-- IsRatedArena on some paths, hence the explicit exclusions.
local function IsRatedMatch()
    local isSoloShuffle = PvPFlag("IsSoloShuffle")
    if PvPFlag("IsRatedBattleground") then return true end
    if PvPFlag("IsSoloRBG") then return true end
    if PvPFlag("IsRatedSoloShuffle") then return true end
    if PvPFlag("IsRatedArena") and not Global("IsArenaSkirmish") and not isSoloShuffle then
        return true
    end
    return false
end

--------------------------------------------------------------------------------
-- Instrumentation
--
-- The event order for multi-round formats (Solo Shuffle, Blitz) is not settled:
-- it is not documented whether ARENA_MATCH_START/END bracket the lobby or each
-- round. Every state transition is traced with a timestamp so that a real
-- capture answers the question instead of the segmenter guessing at it.
--------------------------------------------------------------------------------

local function Trace(event, detail)
    local db = ns.db
    if not db then return end
    table.insert(db.trace, {
        t      = ns:Now(),
        gt     = GetTime(),
        event  = event,
        state  = PvPFlag("GetActiveMatchState"),
        detail = detail,
    })
    ns:TrimArray(db.trace, db.settings.maxTrace)
    ns:Debug("trace", event, detail)
end

--------------------------------------------------------------------------------
-- Plain values
--
-- 12.0 can hand back "secret" values from the scoreboard and the UI widgets, and
-- a secret cannot be compared, used in arithmetic or saved meaningfully. These
-- turn a value into an ordinary one or into nil, doing the forbidden operation
-- inside a pcall so a secret is rejected rather than thrown. The comparison is
-- part of each test on purpose: an operation that quietly produced another
-- secret would otherwise pass.
--------------------------------------------------------------------------------

local function SafeCall(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function PlainNumber(value)
    if type(value) ~= "number" then return nil end
    return SafeCall(function()
        local n = value + 0
        if n ~= n then return nil end   -- NaN, and the comparison is the test
        return n
    end)
end

local function PlainString(value)
    if type(value) ~= "string" then return nil end
    return SafeCall(function()
        local s = value .. ""
        if s == "" then return nil end
        return s
    end)
end

-- What kind of match this is, asked again whenever the client has more to say.
--
-- It used to be asked once, on entering the instance, and on this client that is
-- too early to get an answer: all 200 stored match records said unrated and
-- "not an arena", including rated 2v2s whose own scoreboard showed the rating
-- moving by 13. So it is asked again when the match goes live, at every state
-- change and at completion, and a yes is kept - nothing that was rated stops
-- being rated. The scoreboard settles it at the end: a rating that moved is a
-- rated match whatever the flags said.
local function RefreshKind(roster)
    if not current then return end
    if IsRatedMatch() then current.isRated = true end
    if Global("IsActiveBattlefieldArena") then current.isArena = true end
    if Global("IsArenaSkirmish") then current.isSkirmish = true end
    if PvPFlag("IsSoloShuffle") then current.isSoloShuffle = true end
    if PvPFlag("IsRatedSoloShuffle") then current.isRatedSoloShuffle = true end
    if PvPFlag("IsSoloRBG") then current.isSoloRBG = true end
    if PvPFlag("IsInBrawl") then current.isBrawl = true end

    for _, row in ipairs(roster or {}) do
        local change = PlainNumber(row.ratingChange)
        if change and change ~= 0 then current.isRated = true break end
    end

    if current.isRated and ns.Live then ns.Live:SetRated(current) end
end

--------------------------------------------------------------------------------
-- Objectives
--
-- What decides a battleground is not on the scoreboard as a team figure. The
-- scoreboard carries per-player objective columns - flag captures, bases
-- assaulted, orbs held, carts escorted - and the team's running score exists
-- only in the widget across the top of the screen. Both are taken, and the
-- viewer decides which one says who won: the score where a map keeps one, the
-- summed columns where it does not.
--------------------------------------------------------------------------------

-- Column names and order, gathered from the players' own stat entries as the
-- roster is read. A fallback for a client without the column query.
local statMeta = {}

-- A player's objective columns as { [statId] = value }, or nil.
local function ReadStats(list)
    if type(list) ~= "table" then return nil end
    local out = {}
    for _, stat in ipairs(list) do
        local id    = PlainNumber(stat.pvpStatID or stat.statID)
        local value = PlainNumber(stat.pvpStatValue or stat.value)
        if id and value then
            out[id] = value
            if not statMeta[id] then
                statMeta[id] = {
                    name  = PlainString(stat.name),
                    order = PlainNumber(stat.orderIndex) or id,
                }
            end
        end
    end
    return next(out) and out or nil
end

-- The map's objective columns, in scoreboard order, as { id, name, order }.
local function ReadStatColumns()
    local columns = {}

    if C_PvP and type(C_PvP.GetMatchPVPStatColumns) == "function" then
        for _, column in ipairs(SafeCall(C_PvP.GetMatchPVPStatColumns) or {}) do
            local id = PlainNumber(column.pvpStatID)
            if id then
                columns[#columns + 1] = {
                    id    = id,
                    name  = PlainString(column.name)
                            or (statMeta[id] and statMeta[id].name),
                    order = PlainNumber(column.orderIndex) or #columns,
                }
            end
        end
    end

    if #columns == 0 then
        for id, meta in pairs(statMeta) do
            columns[#columns + 1] = { id = id, name = meta.name, order = meta.order }
        end
    end

    table.sort(columns, function(a, b) return a.order < b.order end)
    return #columns > 0 and columns or nil
end

-- The team score from the top-centre widget, or nil for a map that keeps none.
--
-- Found by walking the widget set rather than by a list of widget ids: the ids
-- differ from map to map and change between patches, while "a two-sided bar in
-- the top-centre set" is what a scoring battleground looks like on all of them.
-- Left and right are recorded as the widget draws them; which side is which is
-- the viewer's call.
local function ReadWidgetScore()
    local W = C_UIWidgetManager
    local V = Enum and Enum.UIWidgetVisualizationType
    if not (W and V and V.DoubleStatusBar) then return nil end
    if type(W.GetTopCenterWidgetSetID) ~= "function"
       or type(W.GetAllWidgetsBySetID) ~= "function"
       or type(W.GetDoubleStatusBarWidgetVisualizationInfo) ~= "function" then
        return nil
    end

    local setID = SafeCall(W.GetTopCenterWidgetSetID)
    if not setID then return nil end

    for _, widget in ipairs(SafeCall(W.GetAllWidgetsBySetID, setID) or {}) do
        if widget.widgetType == V.DoubleStatusBar then
            local info = SafeCall(W.GetDoubleStatusBarWidgetVisualizationInfo,
                                  widget.widgetID)
            local left  = info and PlainNumber(info.leftBarValue)
            local right = info and PlainNumber(info.rightBarValue)
            if left and right then
                return {
                    left  = left,
                    right = right,
                    max   = PlainNumber(info.leftBarMax) or PlainNumber(info.rightBarMax),
                }
            end
        end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Scoreboard
--------------------------------------------------------------------------------

-- Prefers C_PvP.GetScoreInfo, which carries talentSpec; falls back to the older
-- positional API. Returns nil when the scoreboard is not yet populated so the
-- caller can retry.
local function ReadRoster()
    Global("SetBattlefieldScoreFaction", -1)

    local count = Global("GetNumBattlefieldScores") or 0
    if count == 0 then return nil end

    local roster = {}
    for i = 1, count do
        local info
        if C_PvP and type(C_PvP.GetScoreInfo) == "function" then
            local ok, result = pcall(C_PvP.GetScoreInfo, i)
            if ok then info = result end
        end

        if type(info) == "table" then
            roster[i] = {
                name    = info.name,
                -- The one field that joins a scoreboard row to anything else
                -- without going through a name: the live session's rows are keyed
                -- by GUID, and so is the log.
                guid    = info.guid,
                class   = info.classToken,
                spec    = info.talentSpec,
                faction = info.faction,
                race    = info.raceName,
                kb      = info.killingBlows,
                deaths  = info.deaths,
                damage  = info.damageDone,
                healing = info.healingDone,
                rating       = info.rating,
                ratingChange = info.ratingChange,
                prematchMMR  = info.prematchMMR,
                mmrChange    = info.mmrChange,
                -- The map's own scoreboard columns - flag captures, bases,
                -- orbs, carts. Guarded on its own so a problem with the one
                -- field that varies by map cannot cost the rest of the row.
                stats        = SafeCall(ReadStats, info.stats),
            }
        else
            local name, kb, _, deaths, _, faction, race, _, classToken, damage, healing =
                Global("GetBattlefieldScore", i)
            if not name then return nil end
            roster[i] = {
                name = name, class = classToken, faction = faction, race = race,
                kb = kb, deaths = deaths, damage = damage, healing = healing,
            }
        end
    end
    return roster
end

local function ReadTeamInfo()
    local teams = {}
    for index = 0, 1 do
        local name, oldRating, newRating, mmr = Global("GetBattlefieldTeamInfo", index)
        if name or oldRating then
            teams[index + 1] = {
                name = name, oldRating = oldRating, newRating = newRating, mmr = mmr,
            }
        end
    end
    return next(teams) and teams or nil
end

--------------------------------------------------------------------------------
-- Dampening
--
-- The arena healing reduction, which climbs for the length of the match. It is
-- the one figure that says how far a match went in terms a player reads, and
-- nothing in the combat log carries it.
--
-- There is no getter for it either: it exists only as a hidden aura on the
-- player whose stack count is the percentage, which is how Blizzard own arena
-- frames read it. Sampled on a timer rather than read once at the end, because
-- the aura is gone by the time the scoreboard is up. It only ever climbs, so
-- the largest value seen is the final one.
--------------------------------------------------------------------------------

local DAMPENING_SPELL = 110310
local matchTicker = nil

local function ReadDampening()
    local get = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
    if type(get) ~= "function" then return nil end

    local ok, aura = pcall(get, DAMPENING_SPELL)
    if not ok or type(aura) ~= "table" then return nil end

    -- Carried as a stack count. Older builds put it in the first aura point
    -- instead, so both are read and whichever answers is used.
    local value = aura.applications
    if type(value) ~= "number" or value <= 0 then
        value = type(aura.points) == "table" and aura.points[1] or nil
    end
    if type(value) ~= "number" or value <= 0 then return nil end
    return value
end

local function SampleDampening()
    if not current then return end
    local value = ReadDampening()
    if value and value > (current.dampening or 0) then
        current.dampening = value
    end
end

--------------------------------------------------------------------------------
-- Honor levels
--
-- Not on the scoreboard. C_PvP.GetScoreInfo carries honor GAINED but not the
-- players honor LEVEL, and there is no lookup by name: UnitHonorLevel wants a
-- unit token. Taking it from whatever tokens exist while the match is running
-- is therefore the only way to have it at all.
--
-- Which means coverage is uneven, and honestly so. Your own side is reliable -
-- a battleground puts you in a raid and an arena in a party - while the other
-- side is only as good as the nameplates that have been on screen. Sampled
-- repeatedly rather than once because nameplates come and go, and a level only
-- ever gets written down once per player.
--------------------------------------------------------------------------------

-- Units whose honor level could not be read because the client handed back a
-- secret value. Reported once at match completion rather than per sample.
local honorFaults = 0

local function SampleHonor()
    if not current then return end
    if type(UnitHonorLevel) ~= "function" then return end

    current.honor = current.honor or {}

    -- Wrapped whole, because 12.0 hands back "secret" values here.
    --
    -- A secret cannot be compared, concatenated or used as a table key - each
    -- of those throws, and which one the client objects to is not something
    -- this code should be trying to predict. UnitName returns one during
    -- PVP_MATCH_COMPLETE, which is where the last reading is taken, and the
    -- throw travelled all the way out of the completion handler.
    --
    -- A missing honor level is cosmetic: the icon is absent for that player.
    -- Losing the match record is not. So this fails quietly per unit and the
    -- caller carries on to the next one.
    local function Take(unit)
        if not UnitExists(unit) or not UnitIsPlayer(unit) then return end

        local ok = pcall(function()
            -- Stored the way the combat log names people, so the viewer can
            -- join on it: UnitName drops the realm for your own, which is the
            -- same shape the scoreboard uses and the same join the class
            -- lookup already makes.
            local name, realm = UnitName(unit)
            if type(name) ~= "string" or name == "" then return end
            if type(realm) == "string" and realm ~= "" then
                name = name .. "-" .. realm
            end
            if current.honor[name] then return end

            local level = UnitHonorLevel(unit)
            if type(level) == "number" and level > 0 then
                current.honor[name] = level
            end
        end)

        -- Counted, never printed: this runs for eighty-odd unit tokens on a
        -- five second ticker, so a message would be unusable. ns:Debug picks it
        -- up at the end of the match for anyone who turns tracing on.
        if not ok then honorFaults = honorFaults + 1 end
    end

    Take("player")
    for i = 1, 4  do Take("party"     .. i) end
    for i = 1, 40 do Take("raid"      .. i) end
    for i = 1, 5  do Take("arena"     .. i) end
    for i = 1, 40 do Take("nameplate" .. i) end
end

--------------------------------------------------------------------------------

-- One ticker for everything sampled during a match. Dampening is arena-only;
-- honor is worth taking everywhere.
-- Kept from the last time the widget could be read. By the time the scoreboard
-- is up the widget has often gone, so the last reading taken while it was on
-- screen is the final score. Arenas have no such widget.
local function SampleScore()
    if not current or current.isArena then return end
    local reading = SafeCall(ReadWidgetScore)
    if reading then current.score = reading end
end

local function SampleMatch()
    if not current then return end
    if current.isArena then SampleDampening() end
    SampleHonor()
    SampleScore()
end

local function StopMatchWatch()
    if not matchTicker then return end
    matchTicker:Cancel()
    matchTicker = nil
end

local function StartMatchWatch()
    StopMatchWatch()
    -- Five seconds is well inside the ten a point of dampening takes to tick
    -- up, and both reads are cheap.
    matchTicker = C_Timer.NewTicker(5, SampleMatch)
    SampleMatch()
end

--------------------------------------------------------------------------------
-- Match lifecycle
--------------------------------------------------------------------------------

-- Seconds to keep logging after leaving a PvP instance.
--
-- Switching logging off the instant we leave loses the session's terminator.
-- The client writes the exit ZONE_CHANGE as part of the same transition that
-- fires our event, and if logging is already off by then the line never reaches
-- the file - leaving the segmenter with a session that never closes. Observed
-- exactly that on a Warsong Gulch capture: the log ended mid-combat with no
-- closing ZONE_CHANGE, and the application withheld the session entirely.
local LOGGING_TAIL_SECONDS = 8

-- Incremented on every entry and exit so a stale timer cannot switch logging
-- off after the player has already re-entered a new match.
local loggingEpoch = 0

-- Whose log it is: the setting's, not this session's.
--
-- There used to be a flag saying whether this addon had switched logging on
-- itself, so that leaving a match would not switch off a log the player had
-- started by hand. It could not survive a reload - the flag is a local and the
-- CVar is not - so a reload inside a match left logging running for good, and
-- everything the character did afterwards went into the file.
--
-- Turning auto logging on is the authority: while it is on, logging is this
-- addon's to switch on at a match and off after one, whoever last touched it.
local function OwnsLogging()
    return ns:AutoLogEnabled()
end

local function StopLoggingSoon(seconds)
    if not OwnsLogging() then return end

    loggingEpoch = loggingEpoch + 1
    local epoch = loggingEpoch

    C_Timer.After(seconds or LOGGING_TAIL_SECONDS, function()
        if epoch ~= loggingEpoch then return end   -- re-entered; leave it running
        -- A fight under way keeps it running; its end starts the tail again.
        if bout or pending then return end
        -- Re-read rather than captured: auto logging may have been switched off
        -- during the tail, and that already stopped the log.
        if OwnsLogging() and LoggingCombat() then
            LoggingCombat(false)
            ns:Debug("combat logging disabled")
        end
        if ns.db then ns.db.boutLogging = nil end
    end)
end

-- Exposed for the settings toggle, which has to know whether there is a match
-- under way before it starts logging.
function ns:MatchInProgress()
    return current ~= nil
end

-- Called when auto logging is switched off, which is the moment the authority is
-- handed back - so the log it was running stops, whoever started it.
function ns:ReleaseLogging()
    if not LoggingCombat() then return false end
    LoggingCombat(false)
    ns:Debug("combat logging disabled")
    return true
end

-- The record of a match this same instance was interrupted in, taken back out of
-- the store so it can be carried on rather than stood beside a second one.
--
-- Searched from the newest end: nothing older than the first candidate can be a
-- better one, and a full store would otherwise be walked on every entry.
local function AdoptInterrupted(instanceID)
    local db = ns.db
    if not (db and db.matches) then return nil end

    local now = ns:Now()
    for i = #db.matches, 1, -1 do
        local record = db.matches[i]
        local age = now - (record.endedAt or record.startedAt or 0)
        if age > ns.RESUME_WINDOW then return nil end
        if record.interrupted and record.map == instanceID then
            table.remove(db.matches, i)
            return record
        end
    end
    return nil
end

-- Everything about a match that can only be read on the way in.
local function NewMatch(instanceName, instanceID, instanceType, uiMapID)
    local clientVersion, clientBuild = GetBuildInfo()

    return {
        startedAt    = ns:Now(),
        startedGT    = GetTime(),
        map          = instanceID,
        mapName      = instanceName,
        instanceType = instanceType,
        uiMapID      = uiMapID,
        -- Every uiMapID seen during the match. A battleground that spans more
        -- than one map would make a bare MAP_CHANGE an unsafe session
        -- terminator, so the segmenter needs the whole set, not just the first.
        uiMaps       = uiMapID and { [uiMapID] = true } or {},
        isArena      = Global("IsActiveBattlefieldArena") or false,
        isRated      = IsRatedMatch(),
        isBrawl      = PvPFlag("IsInBrawl") or false,
        isSoloShuffle      = PvPFlag("IsSoloShuffle") or false,
        isRatedSoloShuffle = PvPFlag("IsRatedSoloShuffle") or false,
        isSoloRBG    = PvPFlag("IsSoloRBG") or false,
        isSkirmish   = Global("IsArenaSkirmish") or false,
        season       = Global("GetCurrentArenaSeason"),
        playerFaction = Global("GetBattlefieldArenaFaction"),
        -- "Alliance" or "Horde", for the recording character rather than for a
        -- side of the match. Stored because the viewer lists sessions from
        -- every character on the account, and the one logged in is rarely the
        -- one that played them - so it cannot be read back later.
        playerFactionGroup = Global("UnitFactionGroup", "player"),
        rounds       = {},

        -- SavedVariables are account-wide, so records from every character land
        -- in one table. Without this there is no way to tell them apart, and no
        -- way to join a record to the right session when two characters played
        -- overlapping matches.
        character     = UnitName("player"),
        characterGuid = UnitGUID("player"),
        realm         = GetRealmName(),

        addonVersion = ns.VERSION,
        clientVersion = clientVersion,
        clientBuild  = clientBuild,
        complete     = false,
    }
end

local function BeginMatch(instanceName, instanceID, instanceType)
    local uiMapID = CurrentUiMap()

    -- A reload inside a match stored the match on the way out and opened it
    -- again on the way back in, which listed one match twice - once abandoned
    -- and once for real. The stored half is carried on instead. It keeps the
    -- start time and the rated status read at the gates, which are the two
    -- things a record made now would have wrong.
    local resumed = AdoptInterrupted(instanceID)
    if resumed then
        current = resumed
        current.interrupted = nil
        -- A match that had already completed keeps the outcome and the time it
        -- ended; one that had not goes back to being in progress.
        if not current.complete then
            current.abandoned = nil
            current.endedAt   = nil
        end
        -- GetTime restarts with the UI, so the observed duration is re-based on
        -- how long ago the match really started rather than on this session.
        current.startedGT = GetTime() - (ns:Now() - (current.startedAt or ns:Now()))
        if uiMapID then
            current.uiMapID = current.uiMapID or uiMapID
            current.uiMaps  = current.uiMaps or {}
            current.uiMaps[uiMapID] = true
        end
        -- Counted because a resumed match is the one case where the recorder's
        -- own view of it has a hole in the middle.
        current.reloads = (current.reloads or 0) + 1
        Trace("RESUMED", current.mapName)
    else
        current = NewMatch(instanceName, instanceID, instanceType, uiMapID)
        Trace("BEGIN", instanceName)
    end

    -- Cancels any pending stop from the previous match. This must happen even
    -- when logging is already running, or a timer queued on the way out of the
    -- last match would switch it off partway through this one.
    loggingEpoch = loggingEpoch + 1
    -- A log a bout started is the match's now, and stops with it.
    ns.db.boutLogging = nil
    -- A fight waiting to be read cannot be any longer: the match goes into the
    -- same meter.
    pending = nil

    -- Advanced logging is forced here rather than only when logging is being
    -- switched on: a log that is already running without the advanced block is
    -- exactly the case worth correcting, and it costs nothing when it is
    -- already set.
    if OwnsLogging() then
        ns:EnsureAdvancedLogging()
        if not LoggingCombat() then
            LoggingCombat(true)
            ns:Debug("combat logging enabled")
        end
    end

    -- Whether this match is being logged, decided once, here, just after the one
    -- place that decides it - and never read again. With auto logging on it is
    -- always yes; with it off, it is whatever the player has running themselves.
    -- It says whether a log of this match is coming, which is what the viewer
    -- needs to know, and not what the flag happens to be at some later moment:
    -- read at the wrong moment - the logging tail of the last match expiring, a
    -- reading taken before the lines above had run - it marked logged matches as
    -- having no log. A match resumed after a reload keeps its original answer.
    if current.logged == nil then
        current.logged = LoggingCombat() and true or false
    end

    -- The live session opens on the same event the log slice will start from, so
    -- what the viewer shows now and what the application delivers later describe
    -- the same match. After the logging decision, which it inherits.
    if ns.Live then ns.Live:Begin(current) end

    -- Every match, not arenas only: dampening is arena-only but honor levels
    -- are worth taking wherever there are unit tokens to read them from.
    StartMatchWatch()
end

-- Called on PVP_MATCH_COMPLETE. The scoreboard occasionally lags the event, so
-- an empty roster schedules a bounded retry rather than storing a hollow record.
local function CompleteMatch(attempt)
    if not current then return end
    attempt = attempt or 1

    -- Column names are gathered as the roster is read, and belong to this map.
    if attempt == 1 then statMeta = {} end

    Global("RequestBattlefieldScoreData")
    local roster = ReadRoster()

    if not roster and attempt < 5 then
        C_Timer.After(0.5, function() CompleteMatch(attempt + 1) end)
        return
    end

    current.endedAt  = ns:Now()
    current.duration = PvPFlag("GetActiveMatchDuration")
    current.winner   = Global("GetBattlefieldWinner")
    current.roster   = roster
    current.teams    = ReadTeamInfo()
    -- After the roster, which is what fills in names on a client whose column
    -- query comes back empty.
    current.statColumns = SafeCall(ReadStatColumns)
    -- The last chance to learn what kind of match it was, with the scoreboard to
    -- settle it.
    RefreshKind(roster)
    current.complete = true

    -- One last read before the aura goes and the group breaks up: completion is
    -- the closest this gets to the end of the match.
    --
    -- Guarded as well as being safe internally, because everything above this
    -- line is the match record and none of it is worth losing to a sampling
    -- problem. Belt and braces on the one path that must not throw.
    pcall(SampleMatch)

    Trace("COMPLETE", ("roster=%d winner=%s honorFaults=%d")
        :format(roster and #roster or 0, tostring(current.winner), honorFaults))

    -- The meter's figures are final at completion; only the enemy names are
    -- still withheld, and those arrive when the map is left.
    if ns.Live then ns.Live:Complete() end
end

-- Called when leaving the instance. A match without a completion snapshot was
-- abandoned: rated status and start time survive, outcome and roster do not.
--
-- `interrupted` says the UI is shutting down rather than that the match ended.
-- The record is stored either way, because a logout has to leave one behind, and
-- is marked so that re-entering the same instance can carry it on instead of
-- starting a second one.
local function FinalizeMatch(interrupted)
    if not current then return end

    if ns.Live then ns.Live:Finish(interrupted) end

    if interrupted then
        -- Kept if completion already set it: that is when the match really
        -- ended, and the UI going away afterwards does not change it.
        current.endedAt     = current.endedAt or ns:Now()
        current.interrupted = true
        -- Abandoned unless it gets picked back up, which is what it looks like
        -- from every other angle until it does.
        if not current.complete then current.abandoned = true end
        Trace("INTERRUPTED", current.mapName)
    elseif not current.complete then
        current.endedAt   = ns:Now()
        current.abandoned = true
        Trace("ABANDONED", current.mapName)
    end

    StopMatchWatch()
    current.durationObserved = GetTime() - current.startedGT

    local db = ns.db
    table.insert(db.matches, current)
    ns:TrimArray(db.matches, db.settings.maxMatches)
    ns:Debug("stored match", current.mapName, current.isRated and "rated" or "unrated")

    current = nil
    StopLoggingSoon()
end

--------------------------------------------------------------------------------
-- Bouts
--
-- Outside arenas and battlegrounds, a fight at a PvP training dummy, a duel and
-- a fight with players in the open world are each recorded as a bout: one
-- combat, from the moment it starts until it drops. The viewer lists
-- consecutive bouts of one kind as a single session.
--
-- What kind of fight it is comes from what the player has targeted - nothing
-- else here can say, with the combat log closed to addons. A player who can be
-- attacked makes it a fight with players, which wins over a dummy; a PvP
-- training dummy, by creature id, makes it a dummy bout; anything else is PvE
-- and is not recorded. The application cuts the same fights out of the log by
-- its own reading, and the two are joined on time.
--
-- With auto logging on, logging is started for a bout and stopped a minute after
-- the last one, so a run of pulls lands in one file. It is started on targeting
-- an opponent out of combat as well, since a log started by the first blow has
-- already missed it.
--------------------------------------------------------------------------------

-- PvP training dummies, by creature id: 243211 and 243212 in Silvermoon City,
-- 255824 and 255825 in Quel'Thalas, 219250 in Khaz Algar. The same five the
-- application looks for.
local PVP_DUMMIES = {
    [243211] = true, [243212] = true, [255824] = true, [255825] = true, [219250] = true,
}

-- How long logging runs on after a bout, in seconds.
local BOUT_TAIL_SECONDS = 60

-- For the meter's baseline, which must not be refreshed under a bout that has
-- not been read yet.
function ns:BoutPending()
    return bout ~= nil or pending ~= nil
end

local function CreatureId(guid)
    local id = guid and guid:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return id and tonumber(id)
end

-- "world" for a player that can be attacked, "dummy" for a PvP training dummy,
-- nil for anything else or for a unit whose answers are withheld.
local function KindOf(unit)
    local kind
    pcall(function()
        if not UnitExists(unit) then return end
        if UnitIsPlayer(unit) then
            if UnitCanAttack("player", unit) then kind = "world" end
            return
        end
        local id = CreatureId(PlainString(UnitGUID(unit)))
        if id and PVP_DUMMIES[id] then kind = "dummy" end
    end)
    return kind
end

-- Somewhere a bout can be fought: not a match, and not a dungeon or raid.
local function BoutGround()
    if current then return false end
    local _, instanceType = InstanceInfo()
    return not (IsPvPInstance(instanceType) or instanceType == "party" or instanceType == "raid")
end

-- Logging this addon started for bouts is marked in the saved file, so that after
-- a reload - which keeps the client logging but forgets the timer that would have
-- stopped it - the tail can be given back to this log and to no other.
local function StartBoutLogging()
    if not OwnsLogging() then return end
    -- Cancels a stop still pending from the bout before.
    loggingEpoch = loggingEpoch + 1
    ns:EnsureAdvancedLogging()
    if not LoggingCombat() and pcall(LoggingCombat, true) then
        ns.db.boutLogging = true
        ns:Debug("combat logging enabled for a bout")
    end
end

-- Whether a log of the bout is being written, decided when it is first known to
-- be one, as a match decides it at the gates.
local function Classify(unit)
    if not bout then return end
    local kind = KindOf(unit)
    if not kind then return end
    if kind == "world" or not bout.kind then
        local first = (bout.kind == nil)
        bout.kind = (bout.kind == "world") and "world" or kind
        if first then
            StartBoutLogging()
            bout.logged = LoggingCombat() and true or false
        end
    end
end

local function OnCombatStart()
    if not BoutGround() then
        -- A fight somewhere bouts are not - a dungeon pulled straight after one -
        -- would only be mixed into it. The log still has the bout.
        pending = nil
        return
    end

    -- Back in combat before the last fight could be read: the meter cannot tell
    -- the two apart - they may share a session - so they are one bout to it, the
    -- first carried on. The log still cuts them apart.
    if pending then
        bout, pending = pending, nil
        bout.merged = true
        Classify("target")
        return
    end

    local name, _, instanceID = InstanceInfo()
    bout = {
        startedAt = ns:Now(),
        -- What the meter held before the first blow, frozen now: the bout is
        -- whatever it gains from here.
        base      = ns.Live and ns.Live:Baseline() or nil,
        map       = instanceID,
        mapName   = PlainString(GetRealZoneText and GetRealZoneText()) or name,
        character = UnitName("player"),
        characterGuid = UnitGUID("player"),
        faction   = Global("UnitFactionGroup", "player"),
    }
    Classify("target")
    Classify("focus")
    Classify("mouseover")
end

local function OnTargetChanged()
    if bout then
        Classify("target")
    elseif BoutGround() and not InCombatLockdown() and KindOf("target") then
        -- Out of combat: an opponent picked out is a fight about to start, and
        -- the log has to be running before its first blow. If none comes, the
        -- tail turns it off again.
        StartBoutLogging()
        StopLoggingSoon(BOUT_TAIL_SECONDS)
    end
end

-- How often a finished fight looks for the meter to have settled, and how many
-- times before it is read anyway - fifteen seconds. Details! polls the same way:
-- the restriction lifts with the combat flag, the figures a moment later.
local SETTLE_TICK = 0.3
local SETTLE_TRIES = 50

-- Reads a finished fight from the meter once it has settled, and takes the next
-- baseline from it. Every fight outside a match comes through here, bout or not:
-- a fight that was not a bout still moved the meter, and the next bout must not
-- be charged with it. A fight that starts while this one waits takes it over -
-- see OnCombatStart - and this chain stops.
local function CaptureBout(finished, tries)
    if pending ~= finished then return end
    if current or not ns.Live then
        pending = nil
        return
    end
    if InCombatLockdown() then return end   -- OnCombatStart has it now

    if not ns.Live:Settled() and tries < SETTLE_TRIES then
        C_Timer.After(SETTLE_TICK, function() CaptureBout(finished, tries + 1) end)
        return
    end
    pending = nil

    if finished.kind then
        local record, detail = ns.Live:Bout(finished)
        StopLoggingSoon(BOUT_TAIL_SECONDS)
        -- What became of it, not only that it happened: this is the one place a
        -- bout the meter had nothing for can be explained after the fact.
        Trace("BOUT", ("%s %ds %s %s%s"):format(finished.kind,
            finished.endedAt - finished.startedAt, record and "stored" or "EMPTY",
            detail or "", (tries >= SETTLE_TRIES) and " unsettled" or ""))
    end
    -- Tried again for a while if the meter is still withholding anything, since
    -- a stale baseline would charge this fight to the next one.
    ns.Live:RefreshBaselineSoon()
end

local function OnCombatEnd()
    local finished = bout
    bout = nil
    if not finished then
        -- A fight that began before a reload has no bout behind it, but it still
        -- moved the meter.
        if ns.Live and BoutGround() then ns.Live:RefreshBaselineSoon() end
        return
    end
    finished.endedAt = ns:Now()
    pending = finished
    -- A frame later: the restriction lifts during the event, not before it.
    C_Timer.After(0, function() CaptureBout(finished, 0) end)
end

--------------------------------------------------------------------------------
-- Round tracking
--------------------------------------------------------------------------------

local lastState = nil

local function OnMatchStateChanged()
    local state = PvPFlag("GetActiveMatchState")
    if state == lastState then return end

    Trace("STATE", ("%s -> %s"):format(tostring(lastState), tostring(state)))
    lastState = state

    if not current then return end
    RefreshKind()

    -- PostRound marks the end of a Solo Shuffle / Blitz round. Recorded as a
    -- boundary regardless of format so the app can segment per round.
    if Enum and Enum.PvPMatchState and state == Enum.PvPMatchState.PostRound then
        table.insert(current.rounds, {
            endedAt  = ns:Now(),
            elapsed  = GetTime() - current.startedGT,
            duration = PvPFlag("GetActiveMatchDuration"),
        })
        Trace("ROUND", ("#%d"):format(#current.rounds))

        -- One live session per round, matching how the application segments a
        -- lobby: the round that just ended closes and the next one opens.
        if ns.Live then ns.Live:Round(current, #current.rounds + 1) end
    end
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

-- Fires far more often than ZONE_CHANGED_NEW_AREA and is only interesting when
-- the map id actually moves, so unchanged ids are dropped rather than traced.
local lastUiMap = nil

local function OnUiMapMaybeChanged()
    local id = CurrentUiMap()
    if id == lastUiMap then return end
    lastUiMap = id

    if not current then return end
    current.uiMaps[id or "unknown"] = true
    Trace("UIMAP", tostring(id))
end

-- Seconds to wait before believing the match is over.
--
-- GetInstanceInfo briefly reports a non-PvP instance type during phase and zone
-- transitions while still inside a battleground. Acting on a single reading
-- split one Twin Peaks match into two records - an abandoned one at 02:18:13
-- and a fresh one six seconds later - so departure is confirmed rather than
-- assumed.
local LEAVE_GRACE_SECONDS = 10

local leaveEpoch = 0

local function FinalizeSoon()
    if not current then return end

    leaveEpoch = leaveEpoch + 1
    local epoch = leaveEpoch

    C_Timer.After(LEAVE_GRACE_SECONDS, function()
        if epoch ~= leaveEpoch or not current then return end

        local _, instanceType, instanceID = InstanceInfo()
        if IsPvPInstance(instanceType) and instanceID == current.map then
            Trace("STAYED", "transient zone reading ignored")
            if ns.Live then ns.Live:Stayed() end
            return
        end
        FinalizeMatch()
    end)
end

local function OnZoneChanged()
    local name, instanceType, instanceID = InstanceInfo()

    if current and IsPvPInstance(instanceType) and instanceID == current.map then
        -- Still in the same match. Cancels any departure awaiting confirmation.
        leaveEpoch = leaveEpoch + 1
        if ns.Live then ns.Live:Stayed() end
    elseif IsPvPInstance(instanceType) then
        -- A different PvP instance is a real transition, not a glitch.
        if current then
            if ns.Live then ns.Live:Left() end
            FinalizeMatch()
        end
        BeginMatch(name, instanceID, instanceType)
    elseif current then
        -- The live session stops taking segments now, not when the departure is
        -- confirmed: anything fought in the next ten seconds is outside, and the
        -- confirmation used to let it in.
        if ns.Live then ns.Live:Left() end
        FinalizeSoon()
    end

    -- Deliberately after the transition: on leaving, current is already nil, so
    -- the map being zoned *to* is not recorded as part of the match just ended.
    OnUiMapMaybeChanged()
end

-- A reload keeps the client logging but loses the timer that was going to stop
-- it, so a reload during a bout's tail left logging on for the rest of the
-- evening. A log this addon started for bouts gets its tail back, in the open
-- world; any other log - a raid's, started by another addon or by hand - is not
-- this addon's to stop.
local function OnWorldEntered()
    if not ns.db.boutLogging then return end
    if not LoggingCombat() then
        ns.db.boutLogging = nil
    elseif not current and OwnsLogging() and BoutGround() then
        StopLoggingSoon(BOUT_TAIL_SECONDS)
    end
end

function Recorder:Init()
    ns:RegisterEvent("PLAYER_ENTERING_WORLD",   OnZoneChanged)
    ns:RegisterEvent("PLAYER_ENTERING_WORLD",   OnWorldEntered)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA",   OnZoneChanged)
    ns:RegisterEvent("PVP_MATCH_COMPLETE",      function() CompleteMatch() end)
    ns:RegisterEvent("PVP_MATCH_STATE_CHANGED", OnMatchStateChanged)
    ns:RegisterEvent("PVP_MATCH_ACTIVE",        function() Trace("ACTIVE"); RefreshKind() end)

    -- Sub-map transitions inside an instance, to establish whether a single
    -- battleground can span more than one uiMapID.
    ns:RegisterEvent("ZONE_CHANGED",            OnUiMapMaybeChanged)
    ns:RegisterEvent("ZONE_CHANGED_INDOORS",    OnUiMapMaybeChanged)

    -- Leaving by logout rather than by zoning still needs the record stored, and
    -- marked: a reload fires this too, and the match is not over.
    ns:RegisterEvent("PLAYER_LOGOUT",           function() FinalizeMatch(true) end)

    -- Bouts outside matches.
    ns:RegisterEvent("PLAYER_REGEN_DISABLED",   OnCombatStart)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED",    OnCombatEnd)
    ns:RegisterEvent("PLAYER_TARGET_CHANGED",   OnTargetChanged)

    if ns.Live then
        ns.Live:Init()
        -- A reload mid-match leaves a session open with its figures but no
        -- baseline; this picks it back up rather than starting a second one.
        ns.Live:Restore()
        -- The first baseline for bouts is taken on entering the world, not here:
        -- at load the meter's list can still be empty, and a bout measured from
        -- an empty baseline is charged with everything already in the session.
    end
end

--------------------------------------------------------------------------------

ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON then return end
    ns:InitDB()
    Recorder:Init()
    ns:Debug("initialised", ns.VERSION)
end)
