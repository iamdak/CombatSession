#include "StreamWriter.h"

#include <algorithm>
#include <charconv>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <type_traits>

namespace cs {
namespace {

// Base prefix present on every event: source and destination GUID, name, flags
// and raid flags.
constexpr size_t kBaseFields = 8;
// SPELL_* events add spellId, spellName and spellSchool.
constexpr size_t kSpellFields = 3;

// Advanced block width, confirmed against a 12.1.0 capture: SPELL_CAST_SUCCESS
// carries no suffix and has 30 payload fields, giving 30 - 11 = 19. The block
// is absent entirely on aura, summon and death events, so its presence is
// validated per line rather than assumed from the event name.
constexpr size_t kAdvancedFields = 19;

// Offsets within the advanced block, verified field by field against
// "SPELL_HEAL,...,Pet-...,Player-...,116985,141594,...,8555.27,-4322.89,2393,0.0059,154".
constexpr size_t kAdvOwnerGuid = 1;
constexpr size_t kAdvCurrentHp = 2;
constexpr size_t kAdvMaxHp     = 3;
constexpr size_t kAdvPosX      = 14;
constexpr size_t kAdvPosY      = 15;
constexpr size_t kAdvLevel     = 18;

template <typename T>
bool ToNumber(std::string_view text, T& out) {
    while (!text.empty() && text.front() == ' ') text.remove_prefix(1);
    while (!text.empty() && text.back() == ' ') text.remove_suffix(1);
    if (text.empty() || text == "nil") return false;
    if constexpr (std::is_floating_point_v<T>) {
        // from_chars for floats is available but MSVC's is fine here; keep the
        // strtod path so "8555.27" parses identically on other toolchains.
        char buf[64];
        const size_t n = (std::min)(text.size(), sizeof buf - 1);
        std::memcpy(buf, text.data(), n);
        buf[n] = '\0';
        char* end = nullptr;
        out = static_cast<T>(std::strtod(buf, &end));
        return end != buf;
    } else {
        const auto* first = text.data();
        const auto* last  = text.data() + text.size();
        return std::from_chars(first, last, out).ec == std::errc{};
    }
}

// Flags arrive as "0x548"; from_chars will not take the prefix.
uint32_t ToFlags(std::string_view text) {
    if (text.size() > 2 && text[0] == '0' && (text[1] == 'x' || text[1] == 'X')) {
        uint32_t v = 0;
        std::from_chars(text.data() + 2, text.data() + text.size(), v, 16);
        return v;
    }
    uint32_t v = 0;
    ToNumber(text, v);
    return v;
}

std::string_view Unquote(std::string_view text) {
    if (text.size() >= 2 && text.front() == '"' && text.back() == '"') {
        return text.substr(1, text.size() - 2);
    }
    return text;
}

bool IsNilGuid(std::string_view guid) {
    return guid.empty() || guid == "nil" || guid == "0000000000000000";
}

// A GUID is "Player-104-0B879FB5", "Pet-0-4228-...", "Creature-0-...". The
// all-zero form is a valid "no unit" marker.
bool LooksLikeGuid(std::string_view text) {
    if (IsNilGuid(text)) return true;
    return text.find('-') != std::string_view::npos;
}

bool HasSpellPrefix(EventKind kind) {
    switch (kind) {
    case EventKind::SwingDamage:
    case EventKind::SwingMissed:
    case EventKind::UnitDied:
    case EventKind::UnitDestroyed:
    case EventKind::PartyKill:
    case EventKind::CombatantInfo:
        return false;
    default:
        return true;
    }
}

} // namespace

//------------------------------------------------------------------------------

EventKind ClassifyEventKind(std::string_view e) {
    struct Entry { std::string_view name; EventKind kind; };
    static constexpr Entry kTable[] = {
        {"SPELL_DAMAGE",             EventKind::SpellDamage},
        {"SPELL_DAMAGE_SUPPORT",     EventKind::SpellDamageSupport},
        {"SPELL_PERIODIC_DAMAGE",    EventKind::SpellPeriodicDamage},
        {"SWING_DAMAGE",             EventKind::SwingDamage},
        {"SWING_DAMAGE_LANDED",      EventKind::SwingDamage},
        {"RANGE_DAMAGE",             EventKind::RangeDamage},
        {"SPELL_HEAL",               EventKind::SpellHeal},
        {"SPELL_PERIODIC_HEAL",      EventKind::SpellPeriodicHeal},
        {"SPELL_ABSORBED",           EventKind::SpellAbsorbed},
        {"SPELL_HEAL_ABSORBED",      EventKind::SpellHealAbsorbed},
        {"SPELL_AURA_APPLIED",       EventKind::SpellAuraApplied},
        {"SPELL_AURA_REMOVED",       EventKind::SpellAuraRemoved},
        {"SPELL_AURA_REFRESH",       EventKind::SpellAuraRefresh},
        {"SPELL_AURA_APPLIED_DOSE",  EventKind::SpellAuraAppliedDose},
        {"SPELL_AURA_REMOVED_DOSE",  EventKind::SpellAuraRemovedDose},
        {"SPELL_AURA_BROKEN_SPELL",  EventKind::SpellAuraBrokenSpell},
        {"SPELL_CAST_START",         EventKind::SpellCastStart},
        {"SPELL_CAST_SUCCESS",       EventKind::SpellCastSuccess},
        {"SPELL_CAST_FAILED",        EventKind::SpellCastFailed},
        {"SPELL_MISSED",             EventKind::SpellMissed},
        {"SPELL_PERIODIC_MISSED",    EventKind::SpellPeriodicMissed},
        {"SWING_MISSED",             EventKind::SwingMissed},
        {"RANGE_MISSED",             EventKind::RangeMissed},
        {"SPELL_ENERGIZE",           EventKind::SpellEnergize},
        {"SPELL_PERIODIC_ENERGIZE",  EventKind::SpellPeriodicEnergize},
        {"SPELL_DISPEL",             EventKind::SpellDispel},
        {"SPELL_STOLEN",             EventKind::SpellDispel},   // Spellsteal is a dispel
        {"SPELL_SUMMON",             EventKind::SpellSummon},
        {"SPELL_INTERRUPT",          EventKind::SpellInterrupt},
        {"DAMAGE_SPLIT",             EventKind::DamageSplit},
        {"UNIT_DIED",                EventKind::UnitDied},
        {"UNIT_DESTROYED",           EventKind::UnitDestroyed},
        {"PARTY_KILL",               EventKind::PartyKill},
        {"COMBATANT_INFO",           EventKind::CombatantInfo},
    };
    for (const auto& entry : kTable) {
        if (entry.name == e) return entry.kind;
    }
    return EventKind::Other;
}

//------------------------------------------------------------------------------

int32_t StreamWriter::InternUnit(std::string_view guid, std::string_view name,
                                 uint32_t flags) {
    if (IsNilGuid(guid)) return 0;

    const std::string key(guid);
    auto it = unitIndex_.find(key);
    if (it != unitIndex_.end()) {
        // Names frequently log as "Unknown" before the client resolves them,
        // so a later real name replaces the placeholder.
        StreamUnit& unit = units_[static_cast<size_t>(it->second) - 1];
        if (!name.empty() && name != "Unknown" && unit.name == "Unknown") {
            unit.name = std::string(name);
        }
        if (flags) unit.flags = flags;
        return it->second;
    }

    units_.push_back(StreamUnit{key, std::string(name), flags, 0, 0});
    const auto index = static_cast<int32_t>(units_.size());
    unitIndex_.emplace(key, index);

    // COMBATLOG_OBJECT_AFFILIATION_MINE (0x1) on a player unit marks the
    // character whose client produced this log. Exactly one unit carries it.
    if ((flags & 0x1) && (flags & 0x400) && ownerIndex_ == 0) {
        ownerIndex_ = index;
    }
    return index;
}

std::string StreamWriter::OwnerName() const {
    if (ownerIndex_ == 0) return {};
    return units_[static_cast<size_t>(ownerIndex_) - 1].name;
}

std::vector<StreamWriter::EventRow> StreamWriter::Events() const {
    std::vector<EventRow> out;
    out.reserve(t_.size());
    for (size_t i = 0; i < t_.size(); ++i) {
        out.push_back(EventRow{ t_[i], kind_[i], src_[i], dst_[i], spell_[i],
                                amount_[i], over_[i], absorbed_[i] });
    }
    return out;
}

std::string StreamWriter::OwnerGuid() const {
    if (ownerIndex_ == 0) return {};
    return units_[static_cast<size_t>(ownerIndex_) - 1].guid;
}

int32_t StreamWriter::InternSpell(int32_t spellId, std::string_view name) {
    if (spellId == 0) return 0;
    auto it = spellIndex_.find(spellId);
    if (it != spellIndex_.end()) return it->second;

    spellIds_.push_back(spellId);
    spellNames_.emplace_back(name);
    const auto index = static_cast<int32_t>(spellIds_.size());
    spellIndex_.emplace(spellId, index);
    return index;
}

void StreamWriter::Feed(const LogLine& line) {
    EventKind kind = ClassifyEventKind(line.event);
    if (kind == EventKind::Other) return;

    // COMBATANT_INFO does not follow the standard prefix. Its payload is
    //   playerGUID, faction, strength, agility, ...
    // so parsing it as a normal event interns the player with the FACTION as
    // their name - every arena combatant became a unit called "0" or "1", and
    // because units are keyed by name they all merged into one entry. That is
    // why arenas showed a team with no damage and no healing while
    // battlegrounds, which emit no COMBATANT_INFO, looked fine.
    if (kind == EventKind::CombatantInfo) return;

    if (!haveBase_) { base_ = line.time; haveBase_ = true; }

    std::vector<std::string_view> f;
    SplitFields(line.payload, f);
    if (f.size() < kBaseFields) return;

    int32_t src = InternUnit(f[0], Unquote(f[1]), ToFlags(f[2]));
    const int32_t dst = InternUnit(f[4], Unquote(f[5]), ToFlags(f[6]));

    // SPELL_ABSORBED names three units, not two: the attacker (source), the
    // shielded unit (destination), and the ABSORBER who supplied the shield.
    // The absorber is what matters for attribution - the scoreboard counts
    // absorbs you provide as healing you did, which is why crediting the
    // destination left healers roughly 3M short on the reference match.
    //
    // The event has three arities (18, 21 and 22 payload fields) depending on
    // whether the incoming attack had a spell, so the tail is indexed from the
    // end, which is stable across all of them:
    //   ... absorberGUID, name, flags, raidFlags, spellId, spellName, school,
    //       absorbedAmount, totalAmount, critical
    if (kind == EventKind::SpellAbsorbed) {
        const size_t n = f.size();
        if (n >= 10 && LooksLikeGuid(f[n - 10]) && !IsNilGuid(f[n - 10])) {
            const int32_t absorber =
                InternUnit(f[n - 10], Unquote(f[n - 9]), ToFlags(f[n - 8]));

            int32_t shieldId = 0;
            ToNumber(f[n - 6], shieldId);
            const int32_t shieldIdx = InternSpell(shieldId, Unquote(f[n - 5]));

            int64_t absorbed = 0;
            ToNumber(f[n - 3], absorbed);

            // The attacker's own spell, which is a different spell entirely from
            // the shield that stopped it. Attributing both rows to the shield
            // put every absorbed hit into the attacker's damage under the
            // healer's spell name - "Holy Bulwark" showing up as damage dealt.
            //
            // Present only in the longer forms: a melee swing carries no spell
            // prefix, and its damage row is attributed to Melee like any other
            // swing.
            int32_t attackIdx = 0;
            if (n >= kBaseFields + kSpellFields + 10) {
                int32_t attackId = 0;
                ToNumber(f[kBaseFields], attackId);
                attackIdx = InternSpell(attackId, Unquote(f[kBaseFields + 1]));
            }

            auto emit = [&](EventKind rowKind, int32_t rowSrc, int32_t rowSpell) {
                t_.push_back(static_cast<int32_t>(line.time - base_));
                kind_.push_back(static_cast<uint8_t>(rowKind));
                src_.push_back(rowSrc);
                dst_.push_back(dst);           // the unit that took the hit
                spell_.push_back(rowSpell);
                amount_.push_back(absorbed);
                over_.push_back(0);
                absorbed_.push_back(absorbed);
                crit_.push_back(0);
                posX_.push_back(0);
                posY_.push_back(0);
                hp_.push_back(0);
                hpMax_.push_back(0);
            };

            // Two rows, because the event names three units and the stream
            // carries two: the shield provider gets the absorb under the shield
            // spell, the attacker gets the damage their hit would have done
            // under the spell they actually cast.
            emit(EventKind::SpellAbsorbed, absorber, shieldIdx);
            if (src != 0) emit(EventKind::DamageAbsorbed, src, attackIdx);
        }
        return;
    }

    // SPELL_SUMMON states ownership directly, and is the only source for a pet
    // that never appears as an advanced info-unit. Since the advanced block
    // describes the DESTINATION on damage events, a pet that only deals damage
    // and never takes any is otherwise never assigned an owner - leaving its
    // output stranded in its own row instead of its summoner's.
    if (kind == EventKind::SpellSummon && src != 0 && dst != 0 && src != dst) {
        units_[static_cast<size_t>(dst) - 1].ownerIndex = src;
    }

    size_t cursor = kBaseFields;
    int32_t spellIndex = 0;
    if (HasSpellPrefix(kind) && f.size() >= cursor + kSpellFields) {
        int32_t spellId = 0;
        ToNumber(f[cursor], spellId);
        spellIndex = InternSpell(spellId, Unquote(f[cursor + 1]));
        cursor += kSpellFields;
    }

    // The advanced block is present only on damage, heal, energize and cast
    // events. Detected by shape rather than by event name so that an unexpected
    // layout degrades to "no advanced data" instead of misreading the suffix.
    int32_t posX = 0, posY = 0, hp = 0, hpMax = 0;
    bool advanced = false;
    if (f.size() >= cursor + kAdvancedFields && LooksLikeGuid(f[cursor])
        && !IsNilGuid(f[cursor])) {
        advanced = true;
        const size_t adv = cursor;

        ToNumber(f[adv + kAdvCurrentHp], hp);
        ToNumber(f[adv + kAdvMaxHp], hpMax);

        double x = 0.0, y = 0.0;
        ToNumber(f[adv + kAdvPosX], x);
        ToNumber(f[adv + kAdvPosY], y);
        posX = static_cast<int32_t>(std::lround(x));
        posY = static_cast<int32_t>(std::lround(y));

        // The advanced block describes the INFO unit, which is the destination
        // for damage and healing and the caster only for casts. Measured on a
        // real log: SPELL_DAMAGE reports info==dest 2979 times and info==source
        // never, while SPELL_CAST_SUCCESS is the reverse.
        //
        // Attributing ownerGUID to the source was wrong in every damage case:
        // an enemy hitting your pet became a child of you, which removed them
        // from the roster and folded their damage into your own.
        int32_t infoIndex = 0;
        {
            const auto it = unitIndex_.find(std::string(f[adv]));
            if (it != unitIndex_.end()) infoIndex = it->second;
        }

        if (infoIndex != 0) {
            StreamUnit& info = units_[static_cast<size_t>(infoIndex) - 1];

            const std::string_view owner = f[adv + kAdvOwnerGuid];
            if (!IsNilGuid(owner)) {
                const auto it = unitIndex_.find(std::string(owner));
                // A unit is never its own parent: players report themselves as
                // the owner on their own events.
                if (it != unitIndex_.end() && it->second != infoIndex) {
                    info.ownerIndex = it->second;
                }
            }

            int32_t level = 0;
            if (ToNumber(f[adv + kAdvLevel], level)) info.level = level;
        }

        cursor += kAdvancedFields;
    }

    // Suffix offsets differ per family. Only the fields the FORMAT columns
    // actually consume are extracted; the rest stay in the archive.
    int64_t amount = 0, over = 0, absorbed = 0;
    uint8_t crit = 0;
    const size_t remaining = f.size() > cursor ? f.size() - cursor : 0;

    switch (kind) {
    case EventKind::SpellDamage:
    case EventKind::SpellPeriodicDamage:
    case EventKind::SwingDamage:
    case EventKind::RangeDamage:
    case EventKind::DamageSplit:
    case EventKind::SpellDamageSupport:
        // amount, baseAmount, overkill, school, resisted, blocked, absorbed,
        // critical, glancing, crushing, isOffHand
        if (remaining >= 8) {
            ToNumber(f[cursor + 0], amount);
            ToNumber(f[cursor + 2], over);
            ToNumber(f[cursor + 6], absorbed);
            crit = (f[cursor + 7] == "1") ? 1 : 0;
        }
        break;

    case EventKind::SpellHeal:
    case EventKind::SpellPeriodicHeal:
        // amount, baseAmount, overhealing, absorbed, critical
        if (remaining >= 5) {
            ToNumber(f[cursor + 0], amount);
            ToNumber(f[cursor + 2], over);
            ToNumber(f[cursor + 3], absorbed);
            crit = (f[cursor + 4] == "1") ? 1 : 0;
        }
        break;

    case EventKind::SpellEnergize:
    case EventKind::SpellPeriodicEnergize:
        if (remaining >= 1) ToNumber(f[cursor + 0], amount);
        break;

    case EventKind::SpellInterrupt:
    case EventKind::SpellDispel:
        // extraSpellId, extraSpellName, extraSpellSchool - and on a dispel an
        // auraType after them.
        //
        // The base spell is the one that was used: Cleanse, Purge, Spellsteal,
        // Kick. The extra spell is what it acted on - the aura that came off, or
        // the cast that was stopped - and that is the half worth leading with,
        // since "Kick" alone says nothing about what it saved you from.
        //
        // It is interned like any other spell and its index rides in `amount`,
        // which is otherwise always zero on these events. A column of its own
        // would cost eight bytes on every event in the session to serve a few
        // hundred of them.
        if (remaining >= 3) {
            int32_t extraId = 0;
            ToNumber(f[cursor + 0], extraId);
            amount = InternSpell(extraId, Unquote(f[cursor + 1]));

            // auraType separates the two directions of a dispel: a DEBUFF off a
            // friend is a dispel, a BUFF off anyone is a purge, and Spellsteal
            // takes a buff so it lands with the purges. Only a dispel carries
            // the field, so an interrupt must never be tested for it.
            if (kind == EventKind::SpellDispel && remaining >= 4
                && Unquote(f[cursor + 3]) == "BUFF") {
                kind = EventKind::SpellPurge;
            }
        }
        break;

    default:
        break;
    }

    t_.push_back(static_cast<int32_t>(line.time - base_));
    kind_.push_back(static_cast<uint8_t>(kind));
    src_.push_back(src);
    dst_.push_back(dst);
    spell_.push_back(spellIndex);
    amount_.push_back(amount);
    over_.push_back(over);
    absorbed_.push_back(absorbed);
    crit_.push_back(crit);
    posX_.push_back(advanced ? posX : 0);
    posY_.push_back(advanced ? posY : 0);
    hp_.push_back(hp);
    hpMax_.push_back(hpMax);
}

//------------------------------------------------------------------------------

namespace {

void WriteEscaped(std::ofstream& out, std::string_view text) {
    out << '"';
    for (const char c : text) {
        if (c == '"' || c == '\\') out << '\\';
        out << c;
    }
    out << '"';
}

// Column arrays dominate the file, so they are written without whitespace and
// wrapped only often enough to keep lines from growing unbounded.
template <typename T>
void WriteColumn(std::ofstream& out, const char* name, const std::vector<T>& v) {
    out << "  " << name << "={";
    for (size_t i = 0; i < v.size(); ++i) {
        if (i) out << ',';
        if ((i & 0x3F) == 0x3F) out << '\n';
        out << static_cast<int64_t>(v[i]);
    }
    out << "},\n";
}

const char* TypeName(SessionType t) {
    switch (t) {
    case SessionType::Arena:        return "arena";
    case SessionType::Battleground: return "battleground";
    default:                        return "unknown";
    }
}

} // namespace

bool StreamWriter::Write(const std::string& path, const std::string& key,
                         const Session& session) const {
    std::ofstream out(path, std::ios::binary);
    if (!out) return false;

    out << "-- Generated by CombatSession. Do not edit.\n";
    out << "CombatSessionStream = CombatSessionStream or {}\n";
    out << "CombatSessionStream[";
    WriteEscaped(out, key);
    out << "] = {\n";

    out << "  version=" << kStreamVersion << ",\n";
    out << "  header={\n";
    out << "    type=\"" << TypeName(session.type) << "\",\n";
    out << "    startTime=" << session.startTime / 1000 << ",\n";
    out << "    endTime=" << session.endTime / 1000 << ",\n";
    out << "    instanceId=" << session.instanceId << ",\n";
    out << "    uiMapId=" << session.uiMapId << ",\n";
    out << "    mapName="; WriteEscaped(out, session.mapName); out << ",\n";
    out << "    bracket="; WriteEscaped(out, session.bracket); out << ",\n";
    out << "    rated=" << (session.rated ? "true" : "false") << ",\n";
    out << "    truncated=" << (session.IsTruncated() ? "true" : "false") << ",\n";
    out << "    lobby=" << session.lobbyIndex << ",\n";
    out << "    round=" << session.roundIndex << ",\n";
    out << "    combatants=" << session.combatantCount << ",\n";
    // Which character's client produced this session. With several characters
    // or clients writing into one Logs folder, this is what separates them.
    out << "    character="; WriteEscaped(out, OwnerName()); out << ",\n";
    out << "    characterGuid="; WriteEscaped(out, OwnerGuid()); out << ",\n";
    out << "  },\n";

    out << "  units={\n";
    for (const auto& unit : units_) {
        out << "    {";
        WriteEscaped(out, unit.guid); out << ',';
        WriteEscaped(out, unit.name);
        out << ',' << unit.flags << ',' << unit.ownerIndex << ',' << unit.level
            << "},\n";
    }
    out << "  },\n";

    out << "  spells={\n";
    for (size_t i = 0; i < spellIds_.size(); ++i) {
        out << "    {" << spellIds_[i] << ',';
        WriteEscaped(out, spellNames_[i]);
        out << "},\n";
    }
    out << "  },\n";

    WriteColumn(out, "t",   t_);
    WriteColumn(out, "k",   kind_);
    WriteColumn(out, "s",   src_);
    WriteColumn(out, "d",   dst_);
    WriteColumn(out, "sp",  spell_);
    WriteColumn(out, "am",  amount_);
    WriteColumn(out, "ov",  over_);
    WriteColumn(out, "ab",  absorbed_);
    WriteColumn(out, "cr",  crit_);
    WriteColumn(out, "px",  posX_);
    WriteColumn(out, "py",  posY_);
    WriteColumn(out, "hp",  hp_);
    WriteColumn(out, "hpm", hpMax_);

    out << "}\n";
    return out.good();
}

} // namespace cs
