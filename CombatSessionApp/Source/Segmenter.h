// CombatSession :: Segmenter
//
// Turns a stream of combat log lines into SESSION byte ranges.
//
// The rules below are derived from a verified 12.1.0 capture containing a rated
// Solo Shuffle, a rated 2v2, a 3v2 skirmish, an Arathi Basin Blitz and a Temple
// of Kotmogu battleground.
//
// What that capture established:
//
//   * Solo Shuffle emits ARENA_MATCH_START once PER ROUND (six of them) and
//     ARENA_MATCH_END once for the whole lobby. A superseding start is
//     therefore the primary round terminator, not a defensive fallback. The
//     duration in that single ARENA_MATCH_END refers only to the final round.
//
//   * ZONE_CHANGE carries the INSTANCE id and matches ARENA_MATCH_START's first
//     field (1911 Mugambala, 2563 Nokhudon, 1134 Tiger's Peak). MAP_CHANGE
//     carries the uiMapID, a different id space (ZONE_CHANGE 2107 versus
//     MAP_CHANGE 1366 for Arathi Basin). Boundaries key on ZONE_CHANGE.
//
//   * Battlegrounds emit no start or end event and no COMBATANT_INFO at all.
//     Rated Blitz and a random battleground are structurally identical, which
//     is why rated status for battlegrounds can only come from the in-game
//     recorder. Arenas need no such help: ARENA_MATCH_START's bracket field
//     distinguishes "2v2" from "Skirmish" from "Rated Solo Shuffle".
//
// Two further rules come from a census of thirty-three logs, 3.6GB, covering
// fifty-one instance visits:
//
//   * A ZONE_CHANGE instance of 0 is NOT "the open world". It is the OLD world:
//     Silvermoon City and Eversong Woods both report 0, while Khaz Algar reports
//     2552 and Quel'Thalas 2771 - non-zero ids that opened a provisional
//     battleground and, with war mode on, emitted "Isle of Dorn" and "Slayer's
//     Rise" as battlegrounds. So a non-zero instance cannot mean "instanced".
//     What separates the two is the GROUP: a battleground fills a raid, and
//     every one of the twenty-four sampled had at least nine distinct grouped
//     teammates in its log, while the nine open-world visits had at most three -
//     even the one played from a raid group against a hundred and seven enemy
//     players. See kMinGroupedPlayers.
//
//   * The client writes the destination zone's events BEFORE the ZONE_CHANGE
//     that says it left, so the tail of a battleground carries Silvermoon: other
//     people's buffs, duels and target dummy hits, which then counted as part of
//     the match. The advanced block places each line on a uiMapID, and in all
//     twenty-four battlegrounds a line naming another map was only ever the tail.
//     So a session ends just before the first line another map accounts for.
//
//     A uiMapID of 0 is NOT another map: it is what the client writes during the
//     load, with position 0.00,0.00 to match, and the last ticks and absorbs of
//     the match itself land in that window - thirteen seconds of them in a
//     Gilneas capture. Cutting on those took real figures out of the match.
//     See Inspect and cutPending_.
//
// Outside arenas and battlegrounds the log is also cut into BOUTS: one fight at a
// PvP training dummy, or against players - a duel or world PvP. The log has no
// combat start or end, so a bout is the run of lines in which the recording
// player (or their pet) and an opponent act on each other, closed once neither
// has acted directly for kBoutQuietMs. The addon groups consecutive bouts of one
// kind into a single session; here each is cut on its own. See TrackBout.
//
//   * Damage over time is part of a fight while it lasts but does not keep one
//     going, nor start one. The client drops combat with a dummy while the
//     player's own damage over time is still ticking on it: a warrior's Rend
//     ran on for fourteen seconds after combat ended, and with every tick
//     counted, two pulls eighteen seconds apart were cut as one fight.
//
//   * PvP training dummies are recognised by creature id. A census of sixty-two
//     logs found five, all named "PvP Training Dummy": 243211 and 243212 in
//     Silvermoon City, 255824 and 255825 in Quel'Thalas, 219250 in Khaz Algar.
//     The name is not used - it is localised - and the dummies beside them
//     ("Training Dummy", "Cleave Training Dummy") are PvE ones and stay out.
//
//   * Players are opponents when they are player-controlled and not friendly.
//     The same census held no duel, so whether the client logs a duel opponent
//     as hostile or as neutral is unknown, and both are taken. Neutral is also
//     what an opponent's damage over time logs as after a battleground has been
//     left, so a bout needs the recording player to have acted on the opponent
//     as well, and kBoutMinActions such lines in all.

#pragma once

#include "CombatLog.h"

#include <cstdint>
#include <functional>
#include <set>
#include <string>
#include <vector>

namespace cs {

// Stored as a number in records.tsv, so new kinds go on the end.
enum class SessionType {
    Unknown,
    Arena,
    Battleground,
    Dummy,              // a bout at a PvP training dummy
    World,              // a bout against players outside arenas and battlegrounds
};

inline bool IsBout(SessionType type) {
    return type == SessionType::Dummy || type == SessionType::World;
}

enum class Termination {
    CleanEnd,           // ARENA_MATCH_END - the only clean case
    SupersededByStart,  // next Solo Shuffle round began
    LeftInstance,       // ZONE_CHANGE away; the only battleground terminator
    LoggingReset,       // COMBAT_LOG_VERSION mid-session: restart or /combatlog
    EndOfData,          // log ran out while the session was still open
    Quiet,              // a bout's fighting stopped
};

struct Session {
    SessionType type = SessionType::Unknown;
    Termination termination = Termination::EndOfData;

    int32_t     instanceId = 0;
    int32_t     uiMapId    = 0;   // last MAP_CHANGE seen inside the session
    std::string mapName;
    std::string bracket;          // arena only; empty for battlegrounds

    // Every uiMapID observed. Neither sampled battleground spanned more than
    // one, but that is two samples, so the set is carried rather than assumed.
    std::vector<int32_t> uiMaps;

    Timestamp startTime = 0;
    Timestamp endTime   = 0;

    // Byte range of this session within its source log, used to slice the
    // archive without re-reading or re-parsing.
    uint64_t startOffset = 0;
    uint64_t endOffset   = 0;

    // Solo Shuffle: rounds sharing a lobby carry the same lobbyIndex and a
    // 1-based roundIndex. Everything else has roundIndex 0.
    int32_t lobbyIndex = 0;
    int32_t roundIndex = 0;

    bool          rated = false;
    bool          hasEndInfo = false;
    ArenaMatchEnd endInfo{};

    // COMBATANT_INFO rows, which equal the participant count in arenas and are
    // always zero in battlegrounds. The 3v2 skirmish in the sample produced 5.
    int32_t combatantCount = 0;

    // A bout's opponents, by GUID. The bout's byte range also holds everyone
    // else's fighting nearby - a capital city's other duels and dummies - so its
    // chunk keeps only the lines that involve the recording player, their group
    // or one of these. Empty for a dummy bout, which keeps the player's own lines
    // only: a dummy is shared, and whoever else is hitting it is not part of it.
    std::vector<std::string> participants;

    // "Truncated" means data is missing, not merely that no end event was seen.
    // A Solo Shuffle round legitimately ends when the next round starts, and
    // LeftInstance is the ONLY terminator a battleground can ever have, so
    // treating either as truncation would make the flag meaningless.
    //
    // A battleground abandoned in progress is indistinguishable from one played
    // to the end in the log itself; the recorder's MATCH record supplies that,
    // which is the same split as rated status.
    //
    // A bout ends cleanly by going quiet or by the zone changing under it.
    bool IsClean() const {
        switch (termination) {
        case Termination::CleanEnd:          return true;
        case Termination::SupersededByStart: return true;
        case Termination::Quiet:             return true;
        case Termination::LeftInstance:      return type != SessionType::Arena;
        default:                             return false;   // reset, end of data
        }
    }
    bool IsTruncated() const { return !IsClean(); }
};

// Streaming segmenter. Feed lines in order; completed sessions are handed to
// the sink as soon as they close, so a long log never needs to be held whole.
class Segmenter {
public:
    using Sink = std::function<void(const Session&)>;

    explicit Segmenter(Sink sink) : sink_(std::move(sink)) {}

    // byteOffset is the position of this line's first byte in the source file;
    // byteLength includes the line terminator.
    void Feed(const LogLine& line, uint64_t byteOffset, uint64_t byteLength);

    // True when a session is still open, meaning the log ends mid-match - or a
    // bout is, or bouts are being held until the instance they were fought in is
    // known not to be a battleground.
    bool HasOpenSession() const { return open_ || boutOpen_ || !heldBouts_.empty(); }

    // Call once the log has no more data. Any still-open session is emitted
    // with Termination::EndOfData; an open bout ends as quiet, since nothing more
    // of it is coming.
    void Finish();

    // Distinct grouped teammates a battleground must show before it is believed
    // to be one. The sampled battlegrounds ran from 9 to 56; the open-world
    // visits, war mode and all, from 0 to 3. Five sits in that gap, nearer the
    // floor of the smaller side: losing a battleground would be worse than
    // keeping a duel, and the smallest bracket still fills a raid of eight.
    static constexpr size_t kMinGroupedPlayers = 5;

    // How long a bout can go without either side acting directly on the other -
    // damage over time ticking does not count - before it is over. The client
    // drops combat about five seconds after the last hostile action, and the
    // recorder's own bout ends there; a little over that keeps one fight with a
    // pause in it from being cut in two.
    static constexpr Timestamp kBoutQuietMs = 8000;

    // Lines between the two sides a bout needs before it is one. Keeps a single
    // stray hit - an area effect clipping a passer-by - from becoming a session.
    static constexpr int kBoutMinActions = 3;

private:
    void OpenSession(const LogLine& line, uint64_t byteOffset);
    void CloseSession(Termination why, Timestamp endTime, uint64_t endOffset);
    void HandleZoneChange(const LogLine& line, uint64_t byteOffset);
    void HandleArenaStart(const LogLine& line, uint64_t byteOffset);
    // Reads what an ordinary combat line says about who is here and where here
    // is, which is everything the two rules above are decided on. Called before
    // the line extends the session, so the range it remembers is the range as it
    // stood BEFORE the line being looked at.
    void Inspect(const LogLine& line);

    // Bouts. TrackBout looks at one combat line; CloseBout ends the open bout and
    // hands it on - to the sink, or to heldBouts_ while a provisional
    // battleground is open, since a battleground is full of exactly the lines a
    // bout is made of and only its close says whether it was one.
    void TrackBout(const LogLine& line, uint64_t byteOffset, uint64_t lineEnd);
    void CloseBout(Termination why);
    void ReleaseHeldBouts(bool discard);

    Sink sink_;

    bool    open_ = false;
    Session current_{};

    // Instance the client is currently inside. Zero is the old world, not the
    // open world - see the header note; every continent has an id of its own.
    int32_t instanceId_ = 0;
    std::string instanceName_;
    // Set when ENCOUNTER_START is seen, which marks the visit as PvE. Such a
    // session is dropped rather than emitted as a battleground.
    bool    isPvE_ = false;

    // Set once a hostile player unit is seen. Entering any instance opens a
    // provisional battleground, which swept up housing zones ("Home Interior",
    // "Founder's Point") and anything else instanced. A battleground is
    // definitionally somewhere with enemy players in it, so a session that never
    // saw one is not emitted.
    bool    sawHostilePlayer_ = false;

    // Friendly players in the recording player's own party or raid, by GUID.
    // Collected only up to the threshold: five short strings is the whole cost,
    // and a battleground reaches it in its first exchange.
    std::set<std::string> grouped_;

    // Where the session stood when a line first named a map that is not one of
    // its own, which is where it really ended. Cleared again by a line back on
    // its own map, so only a run that reaches the close truncates anything.
    uint64_t  cutOffset_  = 0;
    Timestamp cutTime_    = 0;
    bool      cutPending_ = false;

    // Scratch buffer for the field scan, reused so it does not allocate.
    std::vector<std::string_view> fields_;

    int32_t nextLobbyIndex_ = 1;
    int32_t lobbyRoundCount_ = 0;

    // The bout being fought, if any. Its range runs from the first line between
    // the two sides to the last; actions counts those lines, and mine says one of
    // them was the recording player acting rather than only being acted on.
    bool    boutOpen_ = false;
    Session bout_{};
    int     boutActions_ = 0;
    bool    boutMine_ = false;
    // A hostile player acted directly on the recording player.
    bool    boutAttacked_ = false;
    // The last direct action between the two sides, which is what the quiet
    // window runs from.
    Timestamp boutLastDirect_ = 0;
    std::set<std::string> boutWho_;
    std::vector<Session>  heldBouts_;

    // The last MAP_CHANGE seen anywhere, open session or not, which is where a
    // bout in the open world takes its uiMapID from.
    int32_t lastUiMap_ = 0;

    // Set once a match ends inside its own instance and cleared on leaving it.
    // ARENA_MATCH_END comes before the fighting stops - a last kill, damage over
    // time still ticking - and in a capture of nine arenas that tail was cut as
    // a world bout after six of them.
    bool    matchOver_ = false;
};

} // namespace cs
