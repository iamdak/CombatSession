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
    sortCol   = 1,        -- Damage Done
    sortAsc   = false,
    lastKey   = nil,      -- session selected when the window was last closed

    -- Minimap button placement, kept as an angle on the ring rather than a
    -- point: a remembered x,y detaches from the minimap the moment anything
    -- resizes it.
    minimapAngle  = 198,
    minimapShown  = true,
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
    return date("%d/%m/%Y %H:%M", stamp)
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
loader:SetScript("OnEvent", function()
    ns:InitDB()
    if ns.CreateMinimapButton then ns:CreateMinimapButton() end
    if not ns:API() then
        ns:Print("CombatSession is not loaded - there is nothing to view.")
    end
end)
