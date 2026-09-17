-- CombatSession :: Core
-- Namespace, saved-variable bootstrap, and a shared event dispatcher.

local ADDON, ns = ...

ns.ADDON   = ADDON
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata
              and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "0.0.0"

-- Bump when the shape of CombatSessionDB changes. Migrations live in ns.Migrate.
ns.DB_SCHEMA = 2

--------------------------------------------------------------------------------
-- Application version
--
-- The addon and the application ship separately, from different places, and are
-- updated by different means - one through an addon manager, one by replacing a
-- file by hand. So they drift, and the format they pass between them does not
-- survive drift: chunks change shape rather than gain fields, and a reader that
-- guesses at a shape it does not know produces numbers that look real.
--
-- Each half therefore states a version and checks the other's. The application
-- publishes its own into CombatSession_Data/Index.lua, which is the only thing
-- the two of them share. This addon states the one it was written against
-- below, and writes it into its saved variables where the application can read
-- it - the saved file being the only channel that runs the other way.
--------------------------------------------------------------------------------

-- Declared in the .toc, as X-CombatSession-App, and read back from there.
--
-- Not written here as a Lua constant, because the application has to read the
-- same number and its only immediate way to do that is off disk. A value in
-- Lua source would mean either parsing Lua from C++ or waiting for this addon
-- to load and save it - and waiting is what made the first version of this
-- wrong: the client writes saved variables at the START of a reload, from the
-- state before the new files loaded, so a freshly updated addon's requirement
-- did not reach disk until the reload AFTER the one that installed it. The
-- addon warned and the application sat there agreeing with the old number.
--
-- The .toc has neither problem. It is a line of "## Key: Value" that both
-- sides can read, it is current the moment the files are installed, and it
-- does not need the addon to have run even once.
--
-- It must equal the version of the application released alongside this addon.
--
-- The two are compared for equality, not for "at least": an application newer
-- than this number reports the ADDON as out of date, and an older one reports
-- the application. So whenever a release moves the application's version, this
-- moves with it - even for a release where the addon changed nothing - or the
-- addon being shipped would tell every user it needs updating. It is a
-- statement about which application this addon is meant to run with, not a
-- copy of the addon's own version, which can move independently.
--
-- Nil when the metadata is missing, which reads downstream as "no answer" and
-- turns the check off rather than guessing at a number.
ns.APP_EXPECTED = C_AddOns and C_AddOns.GetAddOnMetadata
                  and C_AddOns.GetAddOnMetadata(ADDON, "X-CombatSession-App")

-- "0.11", "0.11.2" and "0.11.2.7" all compare as one ordered number, with
-- missing fields reading as zero so the short form and the long form of one
-- release are equal. Zero means unparseable or absent, which is how "no answer"
-- stays distinct from a real version.
function ns.ParseVersion(text)
    if type(text) == "number" then return text end
    if type(text) ~= "string" then return 0 end

    local field, index, any = { 0, 0, 0, 0 }, 1, false
    for i = 1, #text do
        local c = text:sub(i, i)
        local digit = tonumber(c)
        if digit then
            field[index] = math.min(field[index] * 10 + digit, 999)
            any = true
        elseif c == "." then
            index = index + 1
            if index > 4 then break end
        else
            break   -- a suffix such as "-beta" ends the number
        end
    end

    if not any then return 0 end
    return field[1] * 1000000000 + field[2] * 1000000
         + field[3] * 1000        + field[4]
end

-- What the application last told us it was. Read from the data addon when it is
-- present, and otherwise from what was stored the last time it was - the folder
-- is deleted and recreated by the application as sessions come and go, and its
-- absence says nothing about which application is installed.
function ns.CurrentAppVersion()
    local published = _G.CombatSessionAppVersion
    if type(published) == "table" and published.code then
        return published.code, published.text or "unknown"
    end
    local db = ns.db
    if db and db.appVersion and db.appVersion ~= "" then
        return ns.ParseVersion(db.appVersion), db.appVersion
    end
    return 0, "unknown"
end

-- Where the two halves stand. Mirrors VersionState in the application's
-- Shell.h, and must keep meaning the same things.
--   "unknown"  nothing to compare - the application has never run here
--   "match"    agreed
--   "addon"    the addon is behind: it asks for an older application than this
--   "app"      the application is behind: the addon asks for a newer one
function ns.AppVersions()
    local expected = ns.ParseVersion(ns.APP_EXPECTED)
    local current, currentText = ns.CurrentAppVersion()

    local state
    if current == 0 or expected == 0 then state = "unknown"
    elseif current == expected then state = "match"
    elseif current > expected  then state = "addon"
    else                            state = "app"
    end

    return {
        state        = state,
        expected     = expected,
        expectedText = ns.APP_EXPECTED or "unknown",
        current      = current,
        currentText  = currentText,
    }
end

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

    -- The version handshake, written here rather than merely computed because
    -- the application cannot see anything else this addon holds. It reads this
    -- file to find out what the installed addon asks of it; appVersion is the
    -- other direction, kept so the answer survives the data folder being
    -- emptied. Both are text, because the reader on the other side scans for
    -- quoted strings and would need a second kind of parsing for anything else.
    appExpected = "",
    appVersion  = "",

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

-- Publishes the handshake into the saved file.
--
-- Called once the data addon has loaded, which is PLAYER_LOGIN - the queue
-- addon depends on this one and so loads after it. What lands on disk is
-- whatever was true at the last logout or reload, which is the same latency the
-- application already lives with for everything else it reads here.
function ns:RecordAppVersion()
    if not self.db then return end
    self.db.appExpected = ns.APP_EXPECTED

    -- Only overwritten when the application has actually said something. An
    -- empty data folder means no sessions are queued, not that the application
    -- is gone, and forgetting its version on that basis would report "unknown"
    -- to a user whose installation is perfectly fine.
    local published = _G.CombatSessionAppVersion
    if type(published) == "table" and published.text then
        self.db.appVersion = published.text
    end
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

-- How many times each handler has thrown. Kept so the same fault reports once
-- and then goes quiet, rather than either spamming chat or being silent.
local faults = {}

dispatcher:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = #list, 1, -1 do
        local fn = list[i]
        local ok, err = pcall(fn, event, ...)
        if not ok then
            -- A handler that throws is NOT unregistered.
            --
            -- It used to be, on the reasoning that a broken listener should not
            -- be left running. That reasoning was wrong for anything that
            -- accumulates: one throw inside PVP_MATCH_COMPLETE removed the
            -- recorder's completion handler for the rest of the session, so
            -- every later match that day was filed as abandoned - no roster, no
            -- outcome, no class data - and the only way to get it back was a
            -- /reload nobody knew they needed. A transient fault in one match
            -- must not silently disable recording for all the others.
            --
            -- The pcall is what provides isolation: the loop carries on to the
            -- other listeners either way. Removal was never what made this safe.
            local count = (faults[fn] or 0) + 1
            faults[fn] = count

            if count <= 3 then
                ns:Print(("|cffff5555handler error on %s:|r %s"):format(event, tostring(err)))
                if count == 3 then
                    ns:Print("|cff888888further errors from that handler will be counted, not printed.|r")
                end
            end
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
