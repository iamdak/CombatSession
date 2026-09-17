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
-- True when we enabled combat logging ourselves, so that leaving does not
-- switch off logging the user had turned on manually.
local loggingOwned = false

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

local function StopLoggingSoon()
    if not loggingOwned then return end

    loggingEpoch = loggingEpoch + 1
    local epoch = loggingEpoch

    C_Timer.After(LOGGING_TAIL_SECONDS, function()
        if epoch ~= loggingEpoch then return end   -- re-entered; leave it running
        if loggingOwned and LoggingCombat() then
            LoggingCombat(false)
            ns:Debug("combat logging disabled")
        end
        loggingOwned = false
    end)
end

-- Exposed for the settings toggle, which has to know whether there is a match
-- under way before it starts logging, and whether the logging that is running
-- is this addon to stop. A log the player started by hand with /combatlog is
-- theirs, and turning auto logging off must not switch it off.
function ns:MatchInProgress()
    return current ~= nil
end

function ns:ReleaseLogging()
    if not loggingOwned then return false end
    loggingOwned = false
    if LoggingCombat() then
        LoggingCombat(false)
        ns:Debug("combat logging disabled")
    end
    return true
end

local function BeginMatch(instanceName, instanceID, instanceType)
    local clientVersion, clientBuild = GetBuildInfo()
    local uiMapID = CurrentUiMap()

    current = {
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

    Trace("BEGIN", instanceName)

    -- Cancels any pending stop from the previous match. This must happen even
    -- when logging is already running, or a timer queued on the way out of the
    -- last match would switch it off partway through this one.
    loggingEpoch = loggingEpoch + 1

    -- Advanced logging is forced here rather than only when logging is being
    -- switched on: a log that is already running without the advanced block is
    -- exactly the case worth correcting, and it costs nothing when it is
    -- already set.
    if ns.db.settings.autoLog then
        ns:EnsureAdvancedLogging()
        if not LoggingCombat() then
            LoggingCombat(true)
            loggingOwned = true
            ns:Debug("combat logging enabled")
        end
    end

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
end

-- Called when leaving the instance. A match without a completion snapshot was
-- abandoned: rated status and start time survive, outcome and roster do not.
local function FinalizeMatch()
    if not current then return end

    if not current.complete then
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
-- Round tracking
--------------------------------------------------------------------------------

local lastState = nil

local function OnMatchStateChanged()
    local state = PvPFlag("GetActiveMatchState")
    if state == lastState then return end

    Trace("STATE", ("%s -> %s"):format(tostring(lastState), tostring(state)))
    lastState = state

    if not current then return end

    -- PostRound marks the end of a Solo Shuffle / Blitz round. Recorded as a
    -- boundary regardless of format so the app can segment per round.
    if Enum and Enum.PvPMatchState and state == Enum.PvPMatchState.PostRound then
        table.insert(current.rounds, {
            endedAt  = ns:Now(),
            elapsed  = GetTime() - current.startedGT,
            duration = PvPFlag("GetActiveMatchDuration"),
        })
        Trace("ROUND", ("#%d"):format(#current.rounds))
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
    elseif IsPvPInstance(instanceType) then
        -- A different PvP instance is a real transition, not a glitch.
        if current then FinalizeMatch() end
        BeginMatch(name, instanceID, instanceType)
    elseif current then
        FinalizeSoon()
    end

    -- Deliberately after the transition: on leaving, current is already nil, so
    -- the map being zoned *to* is not recorded as part of the match just ended.
    OnUiMapMaybeChanged()
end

function Recorder:Init()
    ns:RegisterEvent("PLAYER_ENTERING_WORLD",   OnZoneChanged)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA",   OnZoneChanged)
    ns:RegisterEvent("PVP_MATCH_COMPLETE",      function() CompleteMatch() end)
    ns:RegisterEvent("PVP_MATCH_STATE_CHANGED", OnMatchStateChanged)
    ns:RegisterEvent("PVP_MATCH_ACTIVE",        function() Trace("ACTIVE") end)

    -- Sub-map transitions inside an instance, to establish whether a single
    -- battleground can span more than one uiMapID.
    ns:RegisterEvent("ZONE_CHANGED",            OnUiMapMaybeChanged)
    ns:RegisterEvent("ZONE_CHANGED_INDOORS",    OnUiMapMaybeChanged)

    -- Leaving by logout rather than by zoning still needs the record stored.
    ns:RegisterEvent("PLAYER_LOGOUT",           FinalizeMatch)
end

--------------------------------------------------------------------------------

ns:RegisterEvent("ADDON_LOADED", function(_, name)
    if name ~= ADDON then return end
    ns:InitDB()
    Recorder:Init()
    ns:Debug("initialised", ns.VERSION)
end)
