// CombatSession :: StreamWriter
//
// Emits a session as a Lua chunk the addon loads on demand.
//
// Shape is dictated by measurement rather than taste. A Temple of Kotmogu
// battleground in the reference capture produced 189,859 events, of which 97%
// involve a player GUID - so there is no meaningful lossless filtering to be
// had, and efficiency has to come from encoding. One Lua table per event would
// mean ~190k tables, which wrecks both memory and GC. The stream is therefore
// stored as parallel column arrays of plain numbers: Lua keeps those in a
// table's dense array part at 8 bytes per slot with no per-event overhead.
//
// Strings are interned once into unit and spell tables; every event refers to
// them by index. This costs nothing at load and lets the addon resolve names
// without touching the event columns.

#pragma once

#include "Segmenter.h"

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace cs {

// Event kinds carried in the stream. Values are persisted inside generated Lua,
// so existing entries must never be renumbered - append only, and bump
// kStreamVersion when the set changes.
enum class EventKind : uint8_t {
    Other = 0,
    SpellDamage,
    SpellPeriodicDamage,
    SwingDamage,
    RangeDamage,
    SpellHeal,
    SpellPeriodicHeal,
    SpellAbsorbed,
    SpellHealAbsorbed,
    SpellAuraApplied,
    SpellAuraRemoved,
    SpellAuraRefresh,
    SpellAuraAppliedDose,
    SpellAuraRemovedDose,
    SpellAuraBrokenSpell,
    SpellCastStart,
    SpellCastSuccess,
    SpellCastFailed,
    SpellMissed,
    SpellPeriodicMissed,
    SwingMissed,
    RangeMissed,
    SpellEnergize,
    SpellPeriodicEnergize,
    SpellDispel,
    SpellSummon,
    SpellInterrupt,
    DamageSplit,
    UnitDied,
    UnitDestroyed,
    PartyKill,
    CombatantInfo,
    // The damage half of SPELL_ABSORBED, credited to the ATTACKER. The event
    // names three units and the stream carries two, so it is emitted twice:
    // once as SpellAbsorbed (absorber -> victim) and once as this (attacker ->
    // victim). Without it, damage stopped by a shield is credited to nobody,
    // which left every attacker 10-30% short of their scoreboard damage.
    DamageAbsorbed,
    // Augmentation Evoker support damage. WoW credits it to the supporter and
    // the scoreboard counts it, so dropping it left an Augmentation player
    // well short of their own scoreboard line.
    SpellDamageSupport,
    // An offensive dispel: a BUFF taken off a target, as opposed to SpellDispel
    // which is a DEBUFF removed from a friend. SPELL_DISPEL and SPELL_STOLEN
    // both arrive as one event name and are told apart only by the auraType
    // field, so the split is made here rather than by name.
    SpellPurge,
};

inline constexpr int kStreamVersion = 6;

EventKind ClassifyEventKind(std::string_view event);

// One interned unit. Flags are the last seen value, which is enough to
// establish faction and player/pet/NPC type.
struct StreamUnit {
    std::string guid;
    std::string name;
    uint32_t    flags      = 0;
    int32_t     ownerIndex = 0;   // 1-based index into units, 0 when none
    int32_t     level      = 0;   // item level for players, creature level otherwise
};

class StreamWriter {
public:
    // Feeds one line belonging to the session. Lines are expected in order.
    void Feed(const LogLine& line);

    // Writes the Lua chunk. `key` identifies the session inside the global
    // stream table; `session` supplies the header.
    bool Write(const std::string& path,
               const std::string& key,
               const Session&     session) const;

    size_t EventCount() const { return t_.size(); }
    size_t UnitCount()  const { return units_.size(); }

    // The character whose client wrote this log. Exactly one player unit
    // carries COMBATLOG_OBJECT_AFFILIATION_MINE, verified across both reference
    // logs, which makes the logging character identifiable without any help
    // from the addon.
    std::string OwnerName() const;
    std::string OwnerGuid() const;

    // Read access to what was accumulated, so the aggregation the addon
    // performs can be reproduced and checked against a scoreboard offline.
    struct EventRow {
        int32_t t; uint8_t kind; int32_t src, dst, spell;
        int64_t amount, over, absorbed;
    };
    const std::vector<StreamUnit>& Units() const { return units_; }
    std::vector<EventRow> Events() const;

private:
    int32_t InternUnit(std::string_view guid, std::string_view name, uint32_t flags);
    int32_t InternSpell(int32_t spellId, std::string_view name, uint32_t school);

    std::vector<StreamUnit> units_;
    std::unordered_map<std::string, int32_t> unitIndex_;

    // COMBATANT_INFO rows, deduplicated by GUID. A Solo Shuffle lobby emits a
    // fresh set per round and nothing in them changes between rounds, so the
    // last seen wins rather than the table growing a copy per round.
    std::vector<CombatantInfo> combatants_;
    std::unordered_map<std::string, size_t> combatantIndex_;

    std::vector<int32_t>     spellIds_;
    std::vector<std::string> spellNames_;
    // Spell school mask (SCHOOL_MASK_*), a property of the spell rather than of
    // the event, so it is interned once beside the name instead of costing a
    // column across every event in the session.
    std::vector<uint8_t>     spellSchools_;
    std::unordered_map<int32_t, int32_t> spellIndex_;

    // Parallel event columns. Every vector is kept the same length.
    std::vector<int32_t> t_;        // ms since session start
    std::vector<uint8_t> kind_;
    std::vector<int32_t> src_;      // unit index, 0 = none
    std::vector<int32_t> dst_;
    std::vector<int32_t> spell_;    // spell index, 0 = none
    std::vector<int64_t> amount_;
    std::vector<int64_t> over_;     // overkill or overhealing
    std::vector<int64_t> absorbed_;
    std::vector<uint8_t> crit_;
    std::vector<int32_t> posX_;     // rounded; advanced logging only
    std::vector<int32_t> posY_;
    std::vector<int32_t> hp_;
    std::vector<int32_t> hpMax_;

    // Index of the unit flagged AFFILIATION_MINE, or 0 if never seen.
    int32_t   ownerIndex_ = 0;

    Timestamp base_ = 0;
    bool      haveBase_ = false;
};

} // namespace cs
