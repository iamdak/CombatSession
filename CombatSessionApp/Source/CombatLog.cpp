#include "CombatLog.h"

#include <algorithm>
#include <charconv>
#include <ctime>

namespace cs {
namespace {

// from_chars on a string_view, tolerating leading '-' and surrounding space.
template <typename T>
bool ToNumber(std::string_view text, T& out) {
    while (!text.empty() && text.front() == ' ') text.remove_prefix(1);
    while (!text.empty() && text.back() == ' ') text.remove_suffix(1);
    if (text.empty()) return false;
    const auto* first = text.data();
    const auto* last  = text.data() + text.size();
    return std::from_chars(first, last, out).ec == std::errc{};
}

std::string_view Unquote(std::string_view text) {
    if (text.size() >= 2 && text.front() == '"' && text.back() == '"') {
        return text.substr(1, text.size() - 2);
    }
    return text;
}

Structural ClassifyEvent(std::string_view event) {
    if (event == "COMBAT_LOG_VERSION") return Structural::CombatLogVersion;
    if (event == "ZONE_CHANGE")        return Structural::ZoneChange;
    if (event == "MAP_CHANGE")         return Structural::MapChange;
    if (event == "ARENA_MATCH_START")  return Structural::ArenaMatchStart;
    if (event == "ARENA_MATCH_END")    return Structural::ArenaMatchEnd;
    if (event == "COMBATANT_INFO")     return Structural::CombatantInfo;
    if (event == "ENCOUNTER_START")    return Structural::EncounterStart;
    if (event == "ENCOUNTER_END")      return Structural::EncounterEnd;
    return Structural::None;
}

} // namespace

//------------------------------------------------------------------------------

bool ParseTimestamp(std::string_view text, Timestamp& out) {
    // "9/7/2026 15:37:02.502-4"
    int month = 0, day = 0, year = 0, hour = 0, minute = 0, second = 0, millis = 0;

    auto take = [&text](char delim, std::string_view& piece) {
        const size_t pos = text.find(delim);
        if (pos == std::string_view::npos) return false;
        piece = text.substr(0, pos);
        text.remove_prefix(pos + 1);
        return true;
    };

    std::string_view piece;
    if (!take('/', piece) || !ToNumber(piece, month)) return false;
    if (!take('/', piece) || !ToNumber(piece, day))   return false;
    if (!take(' ', piece) || !ToNumber(piece, year))  return false;
    if (!take(':', piece) || !ToNumber(piece, hour))  return false;
    if (!take(':', piece) || !ToNumber(piece, minute)) return false;
    if (!take('.', piece) || !ToNumber(piece, second)) return false;

    // Remaining text is "mmm" followed by the UTC offset, e.g. "502-4". The
    // offset is deliberately discarded: file names and the in-game recorder
    // both work in local time, so converting here would desynchronise them.
    const size_t offsetPos = text.find_first_of("+-");
    const std::string_view millisText =
        offsetPos == std::string_view::npos ? text : text.substr(0, offsetPos);
    if (!ToNumber(millisText, millis)) return false;

    std::tm tm{};
    tm.tm_year  = year - 1900;
    tm.tm_mon   = month - 1;
    tm.tm_mday  = day;
    tm.tm_hour  = hour;
    tm.tm_min   = minute;
    tm.tm_sec   = second;
    tm.tm_isdst = -1;   // let the CRT resolve DST for this local timestamp

    const std::time_t epoch = std::mktime(&tm);
    if (epoch == static_cast<std::time_t>(-1)) return false;

    out = static_cast<Timestamp>(epoch) * 1000 + millis;
    return true;
}

bool ParseLine(std::string_view raw, LogLine& out) {
    while (!raw.empty() && (raw.back() == '\r' || raw.back() == '\n')) raw.remove_suffix(1);
    if (raw.empty()) return false;

    const size_t sep = raw.find(kFieldSeparator);
    if (sep == std::string_view::npos) return false;

    if (!ParseTimestamp(raw.substr(0, sep), out.time)) return false;

    std::string_view rest = raw.substr(sep + kFieldSeparator.size());
    const size_t comma = rest.find(',');
    out.event   = comma == std::string_view::npos ? rest : rest.substr(0, comma);
    out.payload = comma == std::string_view::npos ? std::string_view{}
                                                  : rest.substr(comma + 1);
    out.kind    = ClassifyEvent(out.event);
    return true;
}

void SplitFields(std::string_view payload, std::vector<std::string_view>& out) {
    out.clear();
    size_t start = 0;
    bool quoted = false;

    for (size_t i = 0; i < payload.size(); ++i) {
        const char c = payload[i];
        if (c == '"') {
            quoted = !quoted;
        } else if (c == ',' && !quoted) {
            out.push_back(payload.substr(start, i - start));
            start = i + 1;
        }
    }
    out.push_back(payload.substr(start));
}

//------------------------------------------------------------------------------

bool ParseArenaMatchStart(std::string_view payload, ArenaMatchStart& out) {
    std::vector<std::string_view> f;
    SplitFields(payload, f);
    if (f.size() < 4) return false;

    if (!ToNumber(f[0], out.instanceId)) return false;
    ToNumber(f[1], out.unknown);
    out.bracket = std::string(Unquote(f[2]));
    ToNumber(f[3], out.teamId);
    return true;
}

bool ParseArenaMatchEnd(std::string_view payload, ArenaMatchEnd& out) {
    std::vector<std::string_view> f;
    SplitFields(payload, f);
    if (f.size() < 4) return false;

    ToNumber(f[0], out.winningTeam);
    ToNumber(f[1], out.duration);
    ToNumber(f[2], out.newRating1);
    ToNumber(f[3], out.newRating2);
    return true;
}

bool ParseZoneChange(std::string_view payload, ZoneChange& out) {
    std::vector<std::string_view> f;
    SplitFields(payload, f);
    if (f.size() < 2) return false;

    if (!ToNumber(f[0], out.instanceId)) return false;
    out.name = std::string(Unquote(f[1]));
    if (f.size() > 2) ToNumber(f[2], out.difficultyId);
    return true;
}

bool ParseMapChange(std::string_view payload, MapChange& out) {
    std::vector<std::string_view> f;
    SplitFields(payload, f);
    if (f.size() < 2) return false;

    if (!ToNumber(f[0], out.uiMapId)) return false;
    out.name = std::string(Unquote(f[1]));
    return true;
}

bool ParseCombatantInfo(std::string_view payload, CombatantInfo& out) {
    // GUID and faction are the only fields ahead of the arrays, so they can be
    // taken by splitting the head. Everything after them is stats until the
    // spec id, which sits immediately before the first bracket.
    const size_t firstBracket = payload.find('[');
    const size_t lastBracket  = payload.rfind(']');
    if (firstBracket == std::string_view::npos) return false;

    std::string_view head = payload.substr(0, firstBracket);
    std::vector<std::string_view> f;
    SplitFields(head, f);
    // guid, faction, 22 stats, specId - and the trailing comma before the
    // bracket leaves an empty last field, so the spec is the one before it.
    if (f.size() < 4) return false;

    out.guid = std::string(Unquote(f[0]));
    if (out.guid.empty() || out.guid == "nil") return false;
    ToNumber(f[1], out.faction);

    // Walked back from the bracket rather than indexed from the front: the
    // stat block has changed width between expansions and the spec has always
    // been the last thing before the talents.
    for (size_t i = f.size(); i-- > 2; ) {
        if (f[i].empty()) continue;
        if (ToNumber(f[i], out.specId)) break;
    }

    // honorLevel, season, rating, tier - the only fields after the arrays.
    if (lastBracket != std::string_view::npos && lastBracket + 1 < payload.size()) {
        std::vector<std::string_view> tail;
        SplitFields(payload.substr(lastBracket + 1), tail);
        // The first entry is whatever followed the closing bracket before the
        // comma, which is empty.
        std::vector<std::string_view> values;
        for (const auto& item : tail) {
            if (!item.empty()) values.push_back(item);
        }
        if (values.size() >= 4) {
            ToNumber(values[0], out.honorLevel);
            ToNumber(values[1], out.season);
            ToNumber(values[2], out.rating);
            ToNumber(values[3], out.tier);
        }
    }

    return out.specId != 0;
}

bool IsRatedBracket(std::string_view bracket) {
    // Verified brackets: "2v2", "Skirmish", "Rated Solo Shuffle". Anything
    // naming itself rated is rated; a skirmish never is. Plain "NvN" is rated
    // arena, since skirmishes report "Skirmish" rather than their size.
    if (bracket.find("Skirmish") != std::string_view::npos) return false;
    if (bracket.find("Rated") != std::string_view::npos)    return true;
    if (bracket == "2v2" || bracket == "3v3" || bracket == "5v5") return true;
    return false;
}

} // namespace cs
