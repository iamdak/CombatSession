-- CombatSession :: Core
-- Namespace, saved-variable bootstrap, and a shared event dispatcher.

local ADDON, ns = ...

ns.ADDON   = ADDON
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata
              and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "0.0.0"

-- Bump when the shape of CombatSessionDB changes. Migrations live in ns.Migrate.
ns.DB_SCHEMA = 2

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

local DEFAULTS = {
    schema   = ns.DB_SCHEMA,
    matches  = {},   -- array of MATCH records written by Recorder.lua
    cache    = {},   -- [sessionKey] = parsed CACHE, written by the data library
    trace    = {},   -- instrumentation ring; see Recorder.lua

    -- The oldest chunk key this addon still wants. Anything older has been
    -- declined for good - the cache is full and newer sessions won it - so the
    -- application may collect those chunks. Empty means nothing is declined.
    --
    -- Which sessions are *held* is not recorded here: it is read straight off
    -- the keys of `cache` above, so a saved file can never claim to hold a
    -- session it does not. That matters because the application deletes chunks
    -- on the strength of it, and SavedVariables are written from memory in one
    -- pass that can come up short.
    oldestWanted = "",

    settings = {
        autoLog    = true,  -- toggle LoggingCombat on PvP instance entry/exit
        debug      = false,
        maxMatches = 200,   -- recorder match records
        maxTrace   = 500,
        -- Sessions this addon keeps caches for, and the most it will consume
        -- from a backlog in one pass. Deliberately far below the application's
        -- archive limit: the archive is for reprocessing, this is for viewing.
        maxSessions = 40,
    },
}

-- Fills in anything missing without clobbering what the user already has.
local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then target[key] = {} end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
    return target
end

function ns:InitDB()
    CombatSessionDB = ApplyDefaults(CombatSessionDB or {}, DEFAULTS)
    self.db = CombatSessionDB

    -- Schema 1 tracked a single "newest consumed" watermark. Schema 2 replaced
    -- it with a floor plus the cache's own keys. The old field has to go rather
    -- than linger: a value under a name nothing writes any more is a trap for
    -- the next reader, and this one would read as a floor far too high.
    if self.db.schema == 1 then
        self.db.lastProcessed = nil
        self.db.schema = ns.DB_SCHEMA
    end

    if self.db.schema ~= ns.DB_SCHEMA then
        -- Anything else is unrecognised; record the mismatch rather than
        -- silently reinterpreting data written by a schema this build does
        -- not know.
        self:Print(("saved data is schema %s, this build expects %s")
            :format(tostring(self.db.schema), tostring(ns.DB_SCHEMA)))
    end
    return self.db
end

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------

local PREFIX = "|cff33ff99CombatSession|r: "

function ns:Print(...)
    print(PREFIX .. strjoin(" ", tostringall(...)))
end

function ns:Debug(...)
    if self.db and self.db.settings.debug then
        print(PREFIX .. "|cff888888" .. strjoin(" ", tostringall(...)) .. "|r")
    end
end

--------------------------------------------------------------------------------
-- Event dispatcher
--------------------------------------------------------------------------------
-- Modules register through this rather than owning frames, so that ordering and
-- error isolation are handled in one place. A handler that errors is reported
-- and unregistered instead of taking down every other listener for that event.

local dispatcher = CreateFrame("Frame")
local handlers   = {}

dispatcher:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        local fn = list[i]
        local ok, err = pcall(fn, event, ...)
        if not ok then
            table.remove(list, i)
            ns:Print(("|cffff5555handler error on %s:|r %s"):format(event, tostring(err)))
        end
    end
end)

function ns:RegisterEvent(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        -- Some events are unavailable on certain client flavors; don't let one
        -- bad registration abort module setup.
        if not pcall(dispatcher.RegisterEvent, dispatcher, event) then
            ns:Debug("could not register event", event)
            handlers[event] = nil
            return false
        end
    end
    table.insert(handlers[event], fn)
    return true
end

--------------------------------------------------------------------------------
-- Utility
--------------------------------------------------------------------------------

-- Trims an array in place to the newest `limit` entries.
function ns:TrimArray(t, limit)
    local excess = #t - limit
    if excess > 0 then
        for _ = 1, excess do table.remove(t, 1) end
    end
    return t
end

-- The combat log writes local wall-clock time, so the app correlates sessions
-- against time(), not GetServerTime().
function ns:Now()
    return time()
end

--------------------------------------------------------------------------------
-- Combat logging
--------------------------------------------------------------------------------

-- Advanced combat logging is not a preference. The parser reads the advanced
-- block on every damage and heal line - it carries the source and destination
-- GUIDs, the owner of a pet, and the absorb figures - so a log recorded without
-- it is missing most of what a session is made of. Forcing it is the difference
-- between data and an unusable file, which is why it is not offered as a
-- setting alongside autoLog.
--
-- The CVar is per-account and sticks, so this is a no-op after the first call.
function ns:EnsureAdvancedLogging()
    if GetCVar and GetCVar("advancedCombatLogging") == "1" then return true end
    if not SetCVar then return false end

    -- Wrapped because the caller is the recorder at match start: a CVar that
    -- turns out to be protected in some future build should cost the advanced
    -- block, not the whole match record.
    return (pcall(SetCVar, "advancedCombatLogging", 1))
end

function ns:AutoLogEnabled()
    return (self.db and self.db.settings.autoLog) and true or false
end

-- Setting autoLog governs what happens at the next match start, but a player
-- who turns it on from a menu during a match means now, so it is applied when
-- there is a match under way. Deliberately not switched on out in the world:
-- that would log everything the character does and hand the application an
-- enormous file of nothing.
function ns:SetAutoLog(enabled)
    if not self.db then return false end
    enabled = enabled and true or false
    self.db.settings.autoLog = enabled

    if enabled then
        self:EnsureAdvancedLogging()
        if self.MatchInProgress and self:MatchInProgress() and not LoggingCombat() then
            LoggingCombat(true)
            self:Debug("combat logging enabled")
        end
    elseif self.ReleaseLogging then
        self:ReleaseLogging()
    end
    return enabled
end

_G.CombatSession = ns
