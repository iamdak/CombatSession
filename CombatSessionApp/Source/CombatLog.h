// CombatSession :: CombatLog
//
// Lexing for WoW combat log lines, and detection of the structural events the
// segmenter keys on. Everything here is derived from a verified 12.1.0 capture
// (COMBAT_LOG_VERSION 22, ADVANCED_LOG_ENABLED 1); field positions that were
// confirmed against real data are noted, and those that were not are marked.

#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

namespace cs {

// A line is "<timestamp>  <event>,<field>,<field>,..." with exactly two spaces
// separating the timestamp from the payload.
inline constexpr std::string_view kFieldSeparator = "  ";

enum class Structural {
    None,
    CombatLogVersion,   // logging (re)started: a reset marker, not a file header
    ZoneChange,         // carries the INSTANCE id, same space as ArenaMatchStart
    MapChange,          // carries the uiMapID, a different id space
    ArenaMatchStart,
    ArenaMatchEnd,
    CombatantInfo,
    EncounterStart,     // PvE; used only to reject dungeon/raid instance visits
    EncounterEnd,
};

// Milliseconds since the Unix epoch, local time as written by the client.
using Timestamp = int64_t;

struct LogLine {
    Timestamp        time = 0;
    std::string_view event;    // e.g. "SPELL_DAMAGE"
    std::string_view payload;  // everything after the event name, uncopied
    Structural       kind = Structural::None;
};

// Splits a raw line. Returns false for blank or malformed lines, which are
// skipped rather than treated as errors: logs are routinely truncated mid-line
// when the client exits.
bool ParseLine(std::string_view raw, LogLine& out);

// Splits a comma-separated payload, honouring double-quoted fields. Quoted
// fields keep their quotes so callers can distinguish "nil" from nil.
void SplitFields(std::string_view payload, std::vector<std::string_view>& out);

//------------------------------------------------------------------------------
// Structural payloads
//------------------------------------------------------------------------------

// ARENA_MATCH_START,<instanceId>,<unk>,<bracket>,<teamId>
//
// Verified: "ARENA_MATCH_START,1911,42,Rated Solo Shuffle,0"
//           "ARENA_MATCH_START,2563,42,2v2,1"
//           "ARENA_MATCH_START,1134,42,Skirmish,0"
//
// The bracket string is what distinguishes rated from unrated arena play, so
// arena rated status does not require the in-game recorder. Battlegrounds do.
struct ArenaMatchStart {
    int32_t     instanceId = 0;
    int32_t     unknown    = 0;
    std::string bracket;      // "2v2", "3v3", "Skirmish", "Rated Solo Shuffle"
    int32_t     teamId     = 0;
};

// ARENA_MATCH_END,<winningTeam>,<duration>,<newRatingTeam1>,<newRatingTeam2>
//
// Verified: "ARENA_MATCH_END,1,112,1582,1596"  (rated 2v2)
//           "ARENA_MATCH_END,1,116,0,0"        (skirmish - zero ratings)
//           "ARENA_MATCH_END,-1,56,1495,1490"  (solo shuffle lobby)
//
// For Solo Shuffle this fires ONCE for the whole lobby and its duration refers
// to the final round only, so it must not be used as the lobby duration.
struct ArenaMatchEnd {
    int32_t winningTeam = 0;   // -1 for a Solo Shuffle lobby
    int32_t duration    = 0;
    int32_t newRating1  = 0;
    int32_t newRating2  = 0;
};

// ZONE_CHANGE,<instanceId>,"<name>",<difficultyId>
// An instanceId of 0 means the open world, which is the cleanest "left the
// encounter" signal available.
struct ZoneChange {
    int32_t     instanceId = 0;
    std::string name;
    int32_t     difficultyId = 0;
};

// MAP_CHANGE,<uiMapId>,"<name>",<x0>,<x1>,<y0>,<y1>
struct MapChange {
    int32_t     uiMapId = 0;
    std::string name;
};

bool ParseArenaMatchStart(std::string_view payload, ArenaMatchStart& out);
bool ParseArenaMatchEnd(std::string_view payload, ArenaMatchEnd& out);
bool ParseZoneChange(std::string_view payload, ZoneChange& out);
bool ParseMapChange(std::string_view payload, MapChange& out);

// True when the bracket string denotes rated play. "Skirmish" is unrated; the
// rated Solo Shuffle bracket names itself. Unknown brackets are treated as
// rated only if ratings were reported at match end, which the caller decides.
bool IsRatedBracket(std::string_view bracket);

//------------------------------------------------------------------------------

// Parses the leading "M/D/YYYY HH:MM:SS.mmm-Z" stamp. The offset suffix is the
// client's UTC offset; it is parsed but the result stays in local time, because
// that is what the file names and the in-game recorder both use.
bool ParseTimestamp(std::string_view text, Timestamp& out);

} // namespace cs
