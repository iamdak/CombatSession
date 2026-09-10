-- CombatSession :: Spells
--
-- Curated PvP spell taxonomy used by the EVENTS parser.
--
-- This is deliberately hand-maintained rather than derived at runtime: "major
-- defensive" has no API-visible marker, and an aura's dispel type says nothing
-- about whether losing it mattered. The list is versioned so that a session
-- parsed under an older taxonomy is recomputed rather than silently mixed.
--
-- Coverage is PvP-relevant only, and is expected to need review each patch.
-- Unlisted spells are not errors; they simply do not appear in death context.

local ADDON, ns = ...

-- Bump when entries are added or reclassified. Stamped into DEFINES.VERSION so
-- caches built under an older taxonomy are rebuilt.
ns.SPELL_TAXONOMY_VERSION = 1

local CC        = "cc"          -- loss of control
local DEFENSIVE = "defensive"   -- major personal or external mitigation
local IMMUNITY  = "immunity"
local DISPEL    = "dispel"
local INTERRUPT = "interrupt"

-- [spellId] = category
local T = {}

--------------------------------------------------------------------------------
-- Crowd control
--------------------------------------------------------------------------------

local CC_IDS = {
    118,     -- Polymorph
    51514,   -- Hex
    605,     -- Mind Control
    5782,    -- Fear
    5484,    -- Howl of Terror
    6358,    -- Seduction
    853,     -- Hammer of Justice
    20066,   -- Repentance
    2094,    -- Blind
    408,     -- Kidney Shot
    1833,    -- Cheap Shot
    408,     -- Kidney Shot
    6770,    -- Sap
    3355,    -- Freezing Trap
    19577,   -- Intimidation
    24394,   -- Intimidation (stun)
    51722,   -- Dismantle
    47476,   -- Strangulate
    91800,   -- Gnaw
    108194,  -- Asphyxiate
    221562,  -- Asphyxiate (Blood)
    207167,  -- Blinding Sleet
    339,     -- Entangling Roots
    2637,    -- Hibernate
    33786,   -- Cyclone
    99,      -- Incapacitating Roar
    5211,    -- Mighty Bash
    22570,   -- Maim
    115078,  -- Paralysis
    119381,  -- Leg Sweep
    202274,  -- Incendiary Brew
    853,     -- Hammer of Justice
    105421,  -- Blinding Light
    10326,   -- Turn Evil
    8122,    -- Psychic Scream
    605,     -- Mind Control
    64044,   -- Psychic Horror
    88625,   -- Holy Word: Chastise
    115268,  -- Mesmerize
    30283,   -- Shadowfury
    5484,    -- Howl of Terror
    710,     -- Banish
    118699,  -- Fear
    6789,    -- Mortal Coil
    46968,   -- Shockwave
    107570,  -- Storm Bolt
    132169,  -- Storm Bolt (talent)
    132168,  -- Shockwave (talent)
    51490,   -- Thunderstorm
    118905,  -- Static Charge
    51514,   -- Hex
    76780,   -- Bind Elemental
    64695,   -- Earthgrab
    115750,  -- Blinding Light
    31661,   -- Dragon's Breath
    82691,   -- Ring of Frost
    122,     -- Frost Nova
    33395,   -- Freeze
    157997,  -- Ice Nova
    198898,  -- Song of Chi-Ji
    233759,  -- Grapple Weapon
    204490,  -- Sigil of Silence
    207685,  -- Sigil of Misery
    179057,  -- Chaos Nova
    211881,  -- Fel Eruption
    217832,  -- Imprison
    360806,  -- Sleep Walk
    355689,  -- Landslide
    368970,  -- Tail Swipe
    372245,  -- Terror of the Skies
}
for _, id in ipairs(CC_IDS) do T[id] = CC end

--------------------------------------------------------------------------------
-- Major defensives
--------------------------------------------------------------------------------

local DEFENSIVE_IDS = {
    871,     -- Shield Wall
    12975,   -- Last Stand
    118038,  -- Die by the Sword
    97462,   -- Rallying Cry
    22812,   -- Barkskin
    61336,   -- Survival Instincts
    102342,  -- Ironbark
    104773,  -- Unending Resolve
    108416,  -- Dark Pact
    48792,   -- Icebound Fortitude
    55233,   -- Vampiric Blood
    49028,   -- Dancing Rune Weapon
    186265,  -- Aspect of the Turtle
    264735,  -- Survival of the Fittest
    45438,   -- Ice Block
    11426,   -- Ice Barrier
    110960,  -- Greater Invisibility
    122278,  -- Dampen Harm
    115203,  -- Fortifying Brew
    115176,  -- Zen Meditation
    498,     -- Divine Protection
    642,     -- Divine Shield
    1022,    -- Blessing of Protection
    6940,    -- Blessing of Sacrifice
    31850,   -- Ardent Defender
    86659,   -- Guardian of Ancient Kings
    47585,   -- Dispersion
    33206,   -- Pain Suppression
    47788,   -- Guardian Spirit
    62618,   -- Power Word: Barrier
    31224,   -- Cloak of Shadows
    5277,    -- Evasion
    1966,    -- Feint
    108271,  -- Astral Shift
    98008,   -- Spirit Link Totem
    196555,  -- Netherwalk
    198589,  -- Blur
    187827,  -- Metamorphosis (Vengeance)
    363916,  -- Obsidian Scales
    374348,  -- Renewing Blaze
    357170,  -- Time Dilation
}
for _, id in ipairs(DEFENSIVE_IDS) do T[id] = DEFENSIVE end

local IMMUNITY_IDS = {
    642,     -- Divine Shield
    45438,   -- Ice Block
    186265,  -- Aspect of the Turtle
    31224,   -- Cloak of Shadows
    196555,  -- Netherwalk
    1022,    -- Blessing of Protection
}
for _, id in ipairs(IMMUNITY_IDS) do T[id] = IMMUNITY end

--------------------------------------------------------------------------------
-- Dispels and interrupts
--------------------------------------------------------------------------------

local DISPEL_IDS = {
    527,     -- Purify
    32375,   -- Mass Dispel
    528,     -- Dispel Magic
    4987,    -- Cleanse
    213644,  -- Cleanse Toxins
    88423,   -- Nature's Cure
    2782,    -- Remove Corruption
    475,     -- Remove Curse
    51886,   -- Cleanse Spirit
    77130,   -- Purify Spirit
    370,     -- Purge
    30449,   -- Spellsteal
    115450,  -- Detox
    218164,  -- Detox
    360823,  -- Naturalize
    374251,  -- Cauterizing Flame
}
for _, id in ipairs(DISPEL_IDS) do T[id] = DISPEL end

local INTERRUPT_IDS = {
    6552,    -- Pummel
    2139,    -- Counterspell
    1766,    -- Kick
    47528,   -- Mind Freeze
    57994,   -- Wind Shear
    96231,   -- Rebuke
    106839,  -- Skull Bash
    116705,  -- Spear Hand Strike
    183752,  -- Disrupt
    147362,  -- Counter Shot
    187707,  -- Muzzle
    15487,   -- Silence
    351338,  -- Quell
}
for _, id in ipairs(INTERRUPT_IDS) do T[id] = INTERRUPT end

--------------------------------------------------------------------------------

ns.SpellCategory = T

ns.SpellCategories = {
    CC = CC, DEFENSIVE = DEFENSIVE, IMMUNITY = IMMUNITY,
    DISPEL = DISPEL, INTERRUPT = INTERRUPT,
}

function ns:CategoryOf(spellId)
    return T[spellId]
end
