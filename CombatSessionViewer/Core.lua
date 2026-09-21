-- CombatSessionViewer :: Core
--
-- A viewer shell over CombatSession. It owns no data: everything it draws comes
-- from CombatSessionAPI, the headless library the recording addon exposes as a
-- global for exactly this purpose. Nothing here writes back.
--
-- Two addons can read each other's tables because every addon shares one Lua
-- environment, so the dependency is only about load order - the .toc declares
-- CombatSession so the API exists by the time this file runs.

local ADDON, ns = ...

ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata
              and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "0.0.0"

-- The .toc is the one place a version is written, for both addons. Displayed
-- padded to two minor digits so the title keeps a fixed shape however the .toc
-- is worded: 0.1, 0.10 and 0.1.0 all read as 0.10. A version that is not two
-- numbers at all is shown verbatim rather than mangled into one.
function ns.FormatVersion(text)
    local major, minor = tostring(text or ""):match("^(%d+)%.(%d+)")
    if not major then return tostring(text or "?") end
    if #minor < 2 then minor = minor .. string.rep("0", 2 - #minor) end
    return major .. "." .. minor
end

-- Viewer version with the library's in parentheses. They are separate addons
-- and can be updated independently, so a bug report naming only one of them is
-- half a report - the pair is what identifies a build.
--
-- The library's comes from the global it already publishes rather than from a
-- second metadata lookup: if CombatSession is missing, the version should be
-- missing with it, not read off a .toc for an addon that never loaded.
function ns.VersionText()
    local viewer = ns.FormatVersion(ns.VERSION)
    local cs = _G.CombatSession
    if not (cs and cs.VERSION) then return viewer end
    return ("%s (%s)"):format(viewer, ns.FormatVersion(cs.VERSION))
end

--------------------------------------------------------------------------------
-- Saved settings
--------------------------------------------------------------------------------

-- Window placement and the sort the user last chose. Deliberately not the
-- expansion state: which row was open is a property of looking at something,
-- not of the session, and restoring it across a reload is more surprising than
-- helpful.
local DEFAULTS = {
    point     = "CENTER",
    x         = 0,
    y         = 0,
    width     = 1040,
    height    = 620,
    sortCol   = 1,        -- Damage Done; 0 sorts by name
    sortAsc   = false,
    -- The column the bars are drawn against. Tracks sortCol except while the
    -- sort is alphabetical, which has no quantity behind it to scale bars to.
    barCol    = 1,
    lastKey   = nil,      -- session selected when the window was last closed

    -- Set by the Reload UI button and cleared the moment it is honoured. The
    -- window is not otherwise reopened on login: a reload asked for from inside
    -- the viewer is a round trip, and coming back to a closed window loses the
    -- place the user was in the middle of.
    reopen    = false,

    -- Minimap button placement, kept as an angle on the ring rather than a
    -- point: a remembered x,y detaches from the minimap the moment anything
    -- resizes it.
    minimapAngle  = 198,
    minimapShown  = true,

    -- The meter window: a small always-on list of one measure, standing in for
    -- the damage meter it sits beside. Unlike the main window it does come back
    -- on login, because that is the whole point of it - a window that has to be
    -- opened by hand every session is not something anyone plays with on screen.
    --
    -- Flat keys rather than a nested table, like everything above: a nested
    -- default is copied by reference on first login and never revisited, so a
    -- field added later would never reach a database that already exists.
    -- Open and unlocked on first run, so it is found and can be put where it is
    -- wanted. Closing it is remembered like any other choice; this only decides
    -- what a new install starts with.
    meterShown  = true,
    meterLocked = false,
    meterPoint  = "CENTER",
    meterX      = 0,
    meterY      = 0,
    -- Blizzard's own meter window's footprint, which is what this one is meant
    -- to sit beside or in place of.
    meterW      = 260,
    meterH      = 208,
    -- Nil until chosen, then a column index. Resolved against the columns the
    -- meter can actually fill at the moment it is read, so a format change
    -- cannot leave this pointing at something that no longer moves.
    meterCol    = nil,
    -- How opaque the whole window is, text included: 0.90 is the 90% the slider
    -- in its menu shows.
    meterOpacity = 0.90,
}

local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if target[key] == nil then target[key] = value end
    end
    return target
end

function ns:InitDB()
    CombatSessionViewerDB = ApplyDefaults(CombatSessionViewerDB or {}, DEFAULTS)
    self.db = CombatSessionViewerDB

    -- The meter's first opacity setting stored the background's opacity under
    -- a default that turned out to be backwards. It is replaced by meterOpacity
    -- rather than reinterpreted: the value already saved is that wrong default
    -- far more often than a choice, and applied to the whole window it would
    -- leave a window that can barely be seen.
    self.db.meterAlpha = nil

    return self.db
end

--------------------------------------------------------------------------------
-- The library
--------------------------------------------------------------------------------

-- Resolved on every call rather than cached at load. CombatSession could in
-- principle be disabled while this addon is enabled, and a nil check at the
-- point of use gives a clear message instead of an error inside a frame script.
function ns:API()
    return _G.CombatSessionAPI
end

function ns:Defines()
    local api = self:API()
    return api and api:GetDefines() or nil
end

-- The application version warning as one line, or nil when nothing is wrong.
--
-- The comparison belongs to CombatSession: this addon never talks to the
-- application and has no business deciding what its version numbers mean. All
-- that happens here is the wording, which names the older half first, because
-- that is the one the user has to go and do something about.
function ns:VersionWarning()
    local api = self:API()
    if not (api and api.AppVersions) then return nil end

    local v = api:AppVersions()
    if v.state == "addon" then
        return ("Update the CombatSession addon from CurseForge - the app is already %s")
            :format(v.currentText),
               ("The CombatSession addon is older than the application.\n\n"
             .. "|cffffffffYou have:|r  addon built for app %s\n"
             .. "|cffffffffYou need:|r  addon built for app %s\n\n"
             .. "1.  Open your addon manager, or go to\n"
             .. "     |cff66bbffcurseforge.com/wow/addons/combatsession|r\n"
             .. "2.  Update CombatSession to the latest version.\n"
             .. "3.  Type |cffffffff/reload|r, or log out and back in.")
            :format(v.expectedText, v.currentText)
    elseif v.state == "app" then
        return ("Update the CombatSession app to %s - you are running %s")
            :format(v.expectedText, v.currentText),
               ("The CombatSession application is older than this addon.\n\n"
             .. "|cffffffffYou have:|r  application %s\n"
             .. "|cffffffffYou need:|r  application %s or later\n\n"
             .. "1.  Open the CombatSession application window.\n"
             .. "2.  Click |cffffffffGet the App (GitHub)|r at the bottom and\n"
             .. "     follow the steps it gives you.")
            :format(v.currentText, v.expectedText)
    end
    return nil
end

function ns:Print(...)
    local parts = { ... }
    for i = 1, #parts do parts[i] = tostring(parts[i]) end
    print("|cff33ff99CombatSessionViewer|r: " .. table.concat(parts, " "))
end

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

-- The mock calls for "12.1m", not "12,148,332": the point of the grid is
-- comparing units at a glance, and full precision makes columns ragged. The
-- exact figure is one drill-down away.
function ns.Short(n)
    n = tonumber(n) or 0
    if n >= 1000000 then return ("%.1fm"):format(n / 1000000) end
    if n >= 1000    then return ("%.1fk"):format(n / 1000) end
    if n == 0       then return "0" end
    return tostring(math.floor(n))
end

function ns.Commas(n)
    n = math.floor(tonumber(n) or 0)
    local text = tostring(n)
    local out = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""))
end

-- Crowd control columns hold milliseconds, and their counts hold how many times
-- the effect landed. Both matter and neither substitutes for the other: eight
-- seconds from one cast is a different thing from eight seconds of chain
-- stuns, so the cell shows "(3) 10.3s". Sorting stays on the time, which is
-- the quantity being totalled.
function ns.FormatCell(col, value, count)
    local cs = _G.CombatSession
    if cs and cs.COLUMN_IS_TIME and cs.COLUMN_IS_TIME[col] then
        return ("(%d) %.1fs"):format(count or 0, (tonumber(value) or 0) / 1000)
    end
    return ns.Short(value)
end

function ns.FormatExact(col, value, count)
    local cs = _G.CombatSession
    if cs and cs.COLUMN_IS_TIME and cs.COLUMN_IS_TIME[col] then
        return ("%.1fs over %d"):format((tonumber(value) or 0) / 1000, count or 0)
    end
    if (count or 0) > 1 then
        return ("%s  (%d)"):format(ns.Commas(value), count)
    end
    return ns.Commas(value)
end

function ns.FormatTime(stamp)
    if not stamp then return "" end
    return date("%m/%d/%Y %H:%M", stamp)
end

-- How long something took, as m:ss - or h:mm:ss once past the hour, which a
-- long battleground can reach. Nil rather than "0:00" when there is nothing to
-- report, so the caller can leave the field empty instead of stating a zero.
function ns.FormatDuration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds <= 0 then return nil end

    local hours = math.floor(seconds / 3600)
    local mins  = math.floor((seconds % 3600) / 60)
    local secs  = seconds % 60

    if hours > 0 then return ("%d:%02d:%02d"):format(hours, mins, secs) end
    return ("%d:%02d"):format(mins, secs)
end

-- Header labels only. The library's names stay as they are: they are stored in
-- every cache as FORMAT.columns, they key the aggregation, and the inspector
-- reads them, so abbreviating at the source would mean a format change to save
-- a few pixels. Anything absent here is already short enough.
--
-- The full name still shows in the header and cell tooltips, so nothing is lost
-- by the shortening - it only moves.
local SHORT_COLUMN = {
    ["Damage Done"]   = "Dmg Done",
    ["Damage Taken"]  = "Dmg Taken",
    ["Healing Done"]  = "Heal Done",
    ["Healing Taken"] = "Heal Taken",
    ["Overhealing"]   = "Overheal",
    ["Killing Blows"] = "Kills",
}

function ns.ColumnLabel(name)
    return SHORT_COLUMN[name] or name or ""
end

--------------------------------------------------------------------------------
-- Identity
--------------------------------------------------------------------------------

-- The region suffix carries no information in a match where everyone shares it,
-- and it costs a quarter of the name column. Stripped by a whitelist rather than
-- by trimming any trailing "-XX", so a realm that happens to end that way keeps
-- its name.
local REGIONS = { US = true, EU = true, KR = true, TW = true, CN = true }

function ns.ShortName(name)
    if type(name) ~= "string" then return name end
    local head, tail = name:match("^(.*)%-([A-Z][A-Z])$")
    if head and REGIONS[tail] then return head end
    return name
end

-- Spec and role for a scoreboard entry, from the class token plus the localised
-- spec name it carries. There is no spec id in the scoreboard, so the class's
-- specs are enumerated and matched by name - which also means it resolves in
-- whatever locale the client is running.
local specCache = {}

function ns.SpecInfo(classToken, specName)
    if not (classToken and specName and specName ~= "") then return nil end

    local key = classToken .. "|" .. specName
    local hit = specCache[key]
    if hit ~= nil then return hit or nil end

    local classId
    for id = 1, 20 do
        local info = C_CreatureInfo and C_CreatureInfo.GetClassInfo
                 and C_CreatureInfo.GetClassInfo(id)
        if info and info.classFile == classToken then classId = id break end
    end

    local found = false
    if classId and GetSpecializationInfoForClassID then
        for index = 1, 5 do
            local id, name, _, icon, role = GetSpecializationInfoForClassID(classId, index)
            if not id then break end
            if name == specName then
                found = { id = id, icon = icon, role = role }
                break
            end
        end
    end

    specCache[key] = found or false
    return found or nil
end

-- A colour escape around a string, for the places a string is all there is to
-- work with. Takes the palette's own {r, g, b} form.
function ns.ColorizeRGB(text, color)
    if not color then return text end
    return ("|cff%02x%02x%02x%s|r")
        :format(color[1] * 255, color[2] * 255, color[3] * 255, text)
end

-- The same, for a class. Formatted from the components rather than taken from
-- the table's colorStr, which is not present on every path that hands one of
-- these out.
function ns.Colorize(text, classToken)
    local c = classToken and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classToken]
    if not c then return text end
    return ns.ColorizeRGB(text, { c.r, c.g, c.b })
end

-- Spec from the id the combat log carries in COMBATANT_INFO.
--
-- Better than SpecInfo above in every way that matters: it is the game's own
-- identifier rather than a localised display name, it needs no class token to
-- disambiguate, and it hands back the class as well - so an arena with no
-- scoreboard behind it still knows what everyone was playing. It is only
-- available where the log carries combatants at all, which means arenas.
local specByIdCache = {}

function ns.SpecById(specId)
    specId = tonumber(specId)
    if not specId or specId <= 0 then return nil end

    local hit = specByIdCache[specId]
    if hit ~= nil then return hit or nil end

    local found = false
    if GetSpecializationInfoByID then
        local ok, id, name, _, icon, role, classFile =
            pcall(GetSpecializationInfoByID, specId)
        if ok and id then
            found = { id = id, name = name, icon = icon,
                      role = role, class = classFile }
        end
    end

    specByIdCache[specId] = found
    return found or nil
end

-- Fallback when the spec is unknown: every class has an icon in one atlas.
function ns.ClassIcon(classToken)
    if not classToken then return nil end
    return "Interface\\Icons\\ClassIcon_" .. classToken:lower()
end

ns.ROLE_ATLAS = {
    TANK    = "roleicon-tiny-tank",
    HEALER  = "roleicon-tiny-healer",
    DAMAGER = "roleicon-tiny-dps",
}

-- The badge art for an honor level.
--
-- There is no icon per level. The honor system issues a reward every few levels
-- and the badge belongs to the reward, so a level sitting between two of them
-- has none of its own - which is most levels. Walked downward to the last level
-- that did issue one, which is the badge that player is currently wearing.
--
-- Cached both ways round: a miss is stored as false so a level with no badge
-- anywhere below it is not re-walked on every row that is drawn.
local honorBadge = {}

function ns.HonorBadge(level)
    level = tonumber(level)
    if not level or level < 1 then return nil end

    local hit = honorBadge[level]
    if hit ~= nil then return hit or nil end

    local found = false
    local get = C_PvP and C_PvP.GetHonorRewardInfo
    if type(get) == "function" then
        -- Sixty levels is well past the widest gap between rewards, and the
        -- walk stops at the first hit, so the long form is only ever paid by a
        -- level that has no badge at all.
        for probe = level, math.max(1, level - 60), -1 do
            local ok, info = pcall(get, probe)
            if ok and type(info) == "table" and info.badgeFileDataID then
                found = info.badgeFileDataID
                break
            end
        end
    end

    honorBadge[level] = found
    return found or nil
end

-- Faction crest for a session row. The big Timer art rather than a small badge:
-- it is drawn oversized and cropped by the row, so it wants a shape that still
-- reads when most of it is outside the frame.
ns.FACTION_EMBLEM = {
    Alliance = "Interface\\Timer\\Alliance-Logo",
    Horde    = "Interface\\Timer\\Horde-Logo",
}

--------------------------------------------------------------------------------
-- Spell schools
--------------------------------------------------------------------------------

-- The combat log masks a spell's school into a byte, one bit per school, and
-- a spell may be more than one of them: Frostfire Bolt is frost and fire, and
-- the log says so rather than picking a side.
--
-- The badge beside a spell row is the school's, not the spell's - the spell
-- already has its own icon next to it, and the point of this one is the kind of
-- damage rather than which button was pressed.
--
-- Colour, not art, and the window draws it from plain fills.
--
-- The badge exists because spell art beside spell art reads as two spells, so
-- the school had to stop looking like an icon. Copying what a raid frame does
-- for a dispellable debuff was the obvious answer and is not available: those
-- are dispel TYPES - Magic, Curse, Disease, Poison, Bleed - five of them
-- against seven damage schools, with Magic alone covering six of the seven.
--
-- Tinting the overlay those frames tint was the next answer, and the texture
-- behind it does not resolve in 12.1. A texture that fails to load draws
-- nothing at all and reports nothing, so the badge simply vanished. Two solid
-- rectangles cannot fail that way, and what was ever doing the work here was
-- the colour rather than the shape.
--
-- The colours are the game's own, from the combat text defaults, so a player
-- who has read a frost hit in floating text already knows what pale blue means.
-- Melee carries no school field at all and is physical by definition.
--
-- Muted before use. Those values are chosen to carry over a lit 3D scene at
-- speed, and against a dark grid they were the loudest thing on the row - which
-- is backwards, since the stripe is a qualifier on the spell and not the point
-- of the line. Each is pulled part of the way toward its own grey and then
-- taken down in brightness, so the hues stay recognisably the game's and only
-- the shouting goes. Two constants tune the whole set.
local SCHOOL_MUTE  = 0.35   -- how far toward grey
local SCHOOL_LEVEL = 0.82   -- and then how bright

local function Mute(color)
    local grey = (color[1] + color[2] + color[3]) / 3
    local out = {}
    for i = 1, 3 do
        out[i] = (color[i] + (grey - color[i]) * SCHOOL_MUTE) * SCHOOL_LEVEL
    end
    return out
end

local SCHOOL_BIT = {
    [0x01] = { name = "Physical", color = Mute({ 1.00, 1.00, 0.00 }) },
    [0x02] = { name = "Holy",     color = Mute({ 1.00, 0.90, 0.50 }) },
    [0x04] = { name = "Fire",     color = Mute({ 1.00, 0.50, 0.00 }) },
    [0x08] = { name = "Nature",   color = Mute({ 0.30, 1.00, 0.30 }) },
    [0x10] = { name = "Frost",    color = Mute({ 0.50, 1.00, 1.00 }) },
    [0x20] = { name = "Shadow",   color = Mute({ 0.50, 0.50, 1.00 }) },
    [0x40] = { name = "Arcane",   color = Mute({ 1.00, 0.50, 1.00 }) },
}

-- Anything with more than one bit set. Named by joining the schools it actually
-- holds rather than from a table of Blizzard's compound names: the joined name
-- is always right, where a table would go quietly wrong the first time a new
-- combination appeared.
local schoolCache = {}

function ns.SchoolInfo(mask)
    mask = tonumber(mask)
    if not mask or mask <= 0 then return nil end

    local pure = SCHOOL_BIT[mask]
    if pure then return pure end

    local hit = schoolCache[mask]
    if hit then return hit end

    -- Tested arithmetically rather than with the bit library, because the loop
    -- variable would otherwise have to be named around it.
    local parts = {}
    for index = 0, 6 do
        local flag = 2 ^ index
        if math.floor(mask / flag) % 2 == 1 then
            parts[#parts + 1] = SCHOOL_BIT[flag].name
        end
    end

    -- Averaged across the schools it holds rather than given a colour of its
    -- own, so Frostfire lands between frost and fire instead of being a third
    -- thing to learn. Two schools that happen to average to something close to
    -- a pure school is a cost worth paying for a rule with nothing to remember.
    local r, g, b = 0, 0, 0
    for index = 0, 6 do
        local flag = 2 ^ index
        if math.floor(mask / flag) % 2 == 1 then
            local c = SCHOOL_BIT[flag].color
            r, g, b = r + c[1], g + c[2], b + c[3]
        end
    end
    local n = math.max(1, #parts)

    local entry = {
        name  = (#parts > 0) and table.concat(parts, "/") or "Unknown",
        color = { r / n, g / n, b / n },
    }
    schoolCache[mask] = entry
    return entry
end

--------------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------------

-- Each row is a bar on a track, so every row colour comes in a pair: the bar
-- carries the team or class colour at full strength, and the track behind it is
-- the same hue well darkened. Reading a column then works at a glance from the
-- bar lengths alone, with the tint still saying which side a unit is on.
--
-- Team 1 is the recording player's side; in an arena the two sides are just
-- teams, so the colours mean "yours" and "theirs", not Alliance and Horde.
ns.COLOR = {
    team1Bar    = { 0.19, 0.34, 0.56 },
    team1Track  = { 0.07, 0.10, 0.16 },
    team1Open   = { 0.11, 0.16, 0.25 },

    team2Bar    = { 0.54, 0.19, 0.21 },
    team2Track  = { 0.16, 0.07, 0.08 },
    team2Open   = { 0.25, 0.11, 0.12 },

    noTeamBar   = { 0.36, 0.36, 0.40 },
    noTeamTrack = { 0.12, 0.12, 0.14 },
    noTeamOpen  = { 0.18, 0.18, 0.20 },

    source      = { 0.11, 0.11, 0.13 },
    spell       = { 0.08, 0.08, 0.09 },
    panel       = { 0.06, 0.06, 0.07 },
    header      = { 0.12, 0.12, 0.14 },
    line        = { 0.30, 0.30, 0.34 },
    active      = { 1.00, 0.82, 0.20 },
    activeDim   = { 0.72, 0.58, 0.12 },   -- the column box, under the header box
    selected    = { 0.20, 0.34, 0.24 },
    neutral     = { 0.45, 0.45, 0.48 },   -- pets and NPCs, which have no class

    -- The sorted header. Grey on purpose: yellow means "the active column" in
    -- the grid body, and a header that sorted in yellow read as a second claim
    -- about which column was active.
    sortBox     = { 0.52, 0.52, 0.56 },
    sortBg      = { 0.26, 0.26, 0.29 },

    -- Cell washes inside an open block. The innermost level - the figures the
    -- drill-down is actually about - gets the faint one; each value that was
    -- opened to reveal them gets the stronger one, so the chain from the root
    -- down to what is being read can be traced by colour alone.
    cellInner   = { 1.00, 0.82, 0.20, 0.10 },
    cellParent  = { 1.00, 0.82, 0.20, 0.22 },
}

-- Value text. Named because the same few greys are chosen between in several
-- places and a bare triple does not say which state it belongs to.
ns.TEXT = {
    normal   = { 0.85, 0.85, 0.85 },   -- nothing open
    recede   = { 0.42, 0.42, 0.45 },   -- outside an open block
    inBlock  = { 0.58, 0.58, 0.62 },   -- inside one, not the thing being read
    empty    = { 0.35, 0.35, 0.38 },   -- "--"
    active   = { 1.00, 0.85, 0.30 },   -- the innermost level's own figures
    -- On the stronger wash. Grey went muddy against yellow and full yellow
    -- disappeared into it, so an opened value is a pale cream: warm enough to
    -- belong to the wash, light enough to read on it.
    parent   = { 1.00, 0.95, 0.80 },
}

-- Opening a level pushes the whole level behind it back, not just the row that
-- was clicked. Dimming only the clicked row made it the odd one out and left
-- its siblings competing with the rows it had just revealed; dimming the level
-- as a group reads as depth, and the newly shown rows are the bright ones.
ns.SHADE = {
    unitOpen     = 0.55,   -- every root bar, while any drill-down is open
    source       = 0.72,
    sourceOpen   = 0.40,   -- every counterpart, while any spell list is open
    spell        = 0.72,

    -- Diagonal hatching on a row that is shown on a side but not counted in it.
    -- Barely above the track it sits on: the stripes have to read as texture on
    -- the background, not as a second colour competing with the bar. Anything
    -- brighter turned the row into the loudest thing in the grid, which is the
    -- opposite of what "not counted" should look like.
    hatch        = 1.45,
}

function ns.Shade(color, factor)
    return { color[1] * factor, color[2] * factor, color[3] * factor }
end

-- RAID_CLASS_COLORS is keyed by the class token the recorder stores. Anything
-- without one - a pet, a totem, an NPC - falls back to neutral rather than to
-- an arbitrary class colour, which would read as a claim about who it is.
function ns.ClassColor(token)
    local c = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
    if not c then return ns.COLOR.neutral end
    return { c.r, c.g, c.b }
end

--------------------------------------------------------------------------------

local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
-- The remembered selection, moved on if it was a live session that a built one
-- has since replaced. Kept up to date whether or not the window is open: the
-- replacement is only known about in the session it happens, so waiting for the
-- window to be opened could mean waiting until it has been forgotten.
local function FollowSuccessor(api)
    local successor = api.Successor and api:Successor(ns.db.lastKey)
    if successor then ns.db.lastKey = successor end
end

loader:SetScript("OnEvent", function()
    ns:InitDB()
    if ns.CreateMinimapButton then ns:CreateMinimapButton() end
    local api = ns:API()
    if not api then
        ns:Print("CombatSession is not loaded - there is nothing to view.")
    elseif api.OnCacheChanged then
        -- The library sweeps at its own login, which runs before this one.
        FollowSuccessor(api)

        -- Caches arrive one at a time over the first seconds after login, so a
        -- redraw per cache would be dozens of full layouts in a row. One redraw
        -- shortly after the last of a burst is all the window needs.
        local pending = false
        api:OnCacheChanged(function(key)
            if ns.Model then ns.Model:Invalidate(key) end
            FollowSuccessor(api)
            if pending then return end
            pending = true
            C_Timer.After(0.2, function()
                pending = false
                if ns.UI then ns.UI:Refresh() end
                -- The same signal carries a live reading, which is what the
                -- meter window is drawing: it moves on every one of them.
                if ns.Meter then ns.Meter:Refresh() end
            end)
        end)
    end

    -- Set by the viewer's own Reload UI button. Cleared before it is acted on,
    -- so a login that goes wrong cannot leave the flag set and reopen the
    -- window on every login thereafter.
    if ns.db.reopen then
        ns.db.reopen = false
        -- Deferred by a frame: the library consumes pending chunks on its own
        -- PLAYER_LOGIN, and opening ahead of that shows the session list as it
        -- was rather than as it now is - which is the whole point of the
        -- reload that got us here.
        C_Timer.After(0, function()
            if ns.UI then ns.UI:Show() end
        end)
    end

    -- The meter window does come back, and for the same reason the main one
    -- does not: it is meant to be left on screen, so a login that hid it would
    -- be a setting the user has to set again every time they play. Deferred for
    -- the same frame the main window is, so it opens on the sessions the library
    -- has by then rather than on the ones it had at login.
    if ns.db.meterShown and ns.Meter then
        C_Timer.After(0, function() ns.Meter:Show() end)
    end
end)
