#include "Segmenter.h"

#include <algorithm>
#include <charconv>

namespace cs {
namespace {

// COMBATLOG_OBJECT_* : unit type, reaction, and affiliation to the recording
// player. PARTY is the player's own subgroup and RAID the rest of the raid, so a
// battleground's teammates arrive under both, and MINE - not tested here - is
// only ever the player themselves.
constexpr uint32_t kFlagPlayer   = 0x400;
constexpr uint32_t kFlagHostile  = 0x40;
constexpr uint32_t kFlagFriendly = 0x10;
constexpr uint32_t kFlagParty    = 0x2;
constexpr uint32_t kFlagRaid     = 0x4;
constexpr uint32_t kFlagMine     = 0x1;
// CONTROL_PLAYER: a player, or a pet or guardian a player commands.
constexpr uint32_t kFlagControlPlayer = 0x100;

// Zero rather than an error for anything that is not a flag field: a payload
// field holding something else simply has none of the bits being asked about.
uint32_t UnitFlags(std::string_view flagField) {
    if (flagField.size() < 3 || flagField[0] != '0'
        || (flagField[1] != 'x' && flagField[1] != 'X')) {
        return 0;
    }
    uint32_t flags = 0;
    std::from_chars(flagField.data() + 2, flagField.data() + flagField.size(),
                    flags, 16);
    return flags;
}

bool IsHostilePlayer(uint32_t flags) {
    return (flags & kFlagPlayer) && (flags & kFlagHostile);
}

bool IsGroupedPlayer(uint32_t flags) {
    return (flags & kFlagPlayer) && (flags & kFlagFriendly)
        && (flags & (kFlagParty | kFlagRaid));
}

// Where a line's advanced block begins, decided by how many parameters the event
// prefix puts in front of it. Confirmed by finding a battleground's own uiMapID
// in real lines: payload field 27 for SPELL_ and RANGE_ (three parameters), 24
// for SWING_ (none).
size_t AdvancedStart(std::string_view event) {
    if (event.rfind("SWING_", 0) == 0)         return 8;
    if (event.rfind("ENVIRONMENTAL_", 0) == 0) return 9;
    return 11;
}

// Where the uiMapID sits inside the advanced block, which ends with position x,
// position y, uiMapID, facing, level.
constexpr size_t kAdvancedMapOffset = 16;

bool IsDecimal(std::string_view text) {
    if (!text.empty() && (text.front() == '-' || text.front() == '+')) {
        text.remove_prefix(1);
    }
    bool digits = false;
    bool point  = false;
    for (char c : text) {
        if (c >= '0' && c <= '9') { digits = true; continue; }
        if (c == '.' && !point)   { point  = true; continue; }
        return false;
    }
    return digits;
}

// A GUID, or the all-zero one events use for "nobody". Half the events in a log
// carry no advanced block at all, and their field 27 holds something else
// entirely, so the block is only read where it demonstrably is one.
bool LooksLikeGuid(std::string_view text) {
    return !text.empty()
        && (text.find('-') != std::string_view::npos
            || text.find_first_not_of('0') == std::string_view::npos);
}

// A PvP training dummy, by the creature id in its GUID:
//   Creature-0-<server>-<instance>-<zone>-<id>-<spawn>
// See the header note for where these five come from.
bool IsPvPDummy(std::string_view guid) {
    if (guid.rfind("Creature-", 0) != 0) return false;
    size_t at = 0;
    for (int i = 0; i < 5; ++i) {
        at = guid.find('-', at);
        if (at == std::string_view::npos) return false;
        ++at;
    }
    const size_t end = guid.find('-', at);
    if (end == std::string_view::npos) return false;

    int32_t id = 0;
    const auto parsed = std::from_chars(guid.data() + at, guid.data() + end, id);
    if (parsed.ec != std::errc{} || parsed.ptr != guid.data() + end) return false;
    switch (id) {
    case 243211: case 243212:   // Silvermoon City
    case 255824: case 255825:   // Quel'Thalas
    case 219250:                // Khaz Algar
        return true;
    default:
        return false;
    }
}

// A player - or their pet - the recording player can be fighting: player
// controlled, not friendly, and not their own.
bool IsOpposingPlayer(uint32_t flags) {
    return (flags & kFlagControlPlayer) && !(flags & kFlagFriendly) && !(flags & kFlagMine);
}

bool EndsWith(std::string_view text, std::string_view tail) {
    return text.size() >= tail.size()
        && text.compare(text.size() - tail.size(), tail.size(), tail) == 0;
}

// The events that are two sides fighting: damage and misses, debuffs, interrupts.
// Not heals or buffs - a PvP dummy is logged as friendly and takes the
// recording player's area heals, which is not a fight with it.
bool IsBoutAction(std::string_view event) {
    return EndsWith(event, "_DAMAGE") || EndsWith(event, "_MISSED")
        || EndsWith(event, "_DAMAGE_LANDED") || event == "SPELL_AURA_APPLIED"
        || event == "SPELL_INTERRUPT" || event == "SPELL_DRAIN"
        || event == "SPELL_LEECH";
}

} // namespace

void Segmenter::OpenSession(const LogLine& line, uint64_t byteOffset) {
    current_ = Session{};
    current_.startTime   = line.time;
    current_.startOffset = byteOffset;
    current_.instanceId  = instanceId_;
    // Solo Shuffle rounds after the first are opened by ARENA_MATCH_START, which
    // carries no name, so it is carried forward from the entering ZONE_CHANGE.
    current_.mapName     = instanceName_;
    sawHostilePlayer_    = false;
    grouped_.clear();
    cutOffset_  = 0;
    cutTime_    = 0;
    cutPending_ = false;
    open_ = true;
}

void Segmenter::CloseSession(Termination why, Timestamp endTime, uint64_t endOffset) {
    if (!open_) return;

    current_.termination = why;
    current_.endTime     = endTime;
    current_.endOffset   = endOffset;

    // The client logs the destination's events before it logs the ZONE_CHANGE
    // that left, so the range handed on stops where a line first named a map that
    // was not this session's. Nothing is truncated without that: a session whose
    // last lines merely carry no map has not gone anywhere.
    if (cutPending_ && cutOffset_ > current_.startOffset) {
        current_.endTime   = cutTime_;
        current_.endOffset = cutOffset_;
    }

    // A visit that turned out to be PvE is discarded: only arenas and
    // battlegrounds are tracked, and a dungeon would otherwise be emitted as a
    // battleground purely for lacking ARENA_MATCH_START.
    //
    // A battleground with no enemy player in it was not a battleground: any
    // instance opens a provisional one, including housing. Nor was one without a
    // raid's worth of teammates: every instance id outside the old world belongs
    // to a continent as readily as to a battleground, and war mode supplies the
    // enemy players.
    const bool looksLikeBattleground = current_.type == SessionType::Battleground
                                    && sawHostilePlayer_
                                    && grouped_.size() >= kMinGroupedPlayers;
    const bool looksPvP = current_.type == SessionType::Arena || looksLikeBattleground;
    const bool emit = !isPvE_ && looksPvP;
    if (emit) sink_(current_);

    // Bouts fought while this was open were fighting in this match if it was
    // one, and are dropped with it; otherwise they were the open world's.
    ReleaseHeldBouts(emit);

    open_ = false;
    current_ = Session{};
}

void Segmenter::TrackBout(const LogLine& line, uint64_t byteOffset, uint64_t lineEnd) {
    // An arena is all bout lines and none of them is a bout, and neither is the
    // end of one.
    if (matchOver_ || (open_ && current_.type == SessionType::Arena)) return;
    if (!IsBoutAction(line.event)) return;

    SplitFields(line.payload, fields_);
    if (fields_.size() < 8) return;
    // SPELL_AURA_APPLIED: ..., spellId, name, school, BUFF|DEBUFF.
    if (line.event == "SPELL_AURA_APPLIED"
        && (fields_.size() < 12 || fields_[11] != "DEBUFF")) {
        return;
    }

    const uint32_t srcFlags = UnitFlags(fields_[2]);
    const uint32_t dstFlags = UnitFlags(fields_[6]);

    // One side is the recording player's - themselves or their pet - and the
    // other is not.
    bool mineActs;
    std::string_view other;
    uint32_t otherFlags;
    if ((srcFlags & kFlagMine) && !(dstFlags & kFlagMine)) {
        mineActs = true;  other = fields_[4]; otherFlags = dstFlags;
    } else if ((dstFlags & kFlagMine) && !(srcFlags & kFlagMine)) {
        mineActs = false; other = fields_[0]; otherFlags = srcFlags;
    } else {
        return;
    }

    SessionType kind;
    if (IsOpposingPlayer(otherFlags))  kind = SessionType::World;
    else if (IsPvPDummy(other))        kind = SessionType::Dummy;
    else return;

    // A tick is the fight's while the fight lasts, but it is the tail of an
    // earlier action, not anyone acting: it cannot open a bout, and it does not
    // hold one open. See the header note.
    const bool periodic = line.event.rfind("SPELL_PERIODIC_", 0) == 0;
    if (!boutOpen_ && periodic) return;

    if (!boutOpen_) {
        bout_ = Session{};
        bout_.type        = kind;
        bout_.startTime   = line.time;
        bout_.startOffset = byteOffset;
        bout_.instanceId  = instanceId_;
        bout_.mapName     = instanceName_;
        bout_.uiMapId     = lastUiMap_;
        boutActions_ = 0;
        boutMine_    = false;
        boutAttacked_ = false;
        boutWho_.clear();
        boutOpen_ = true;
    } else if (kind == SessionType::World) {
        // A player joining a fight at a dummy makes it a fight with a player,
        // which is what the recorder will have called it too.
        bout_.type = SessionType::World;
    }

    ++boutActions_;
    if (mineActs) boutMine_ = true;
    if (!mineActs && !periodic && (otherFlags & kFlagHostile) && kind == SessionType::World) {
        boutAttacked_ = true;
    }
    if (!periodic) boutLastDirect_ = line.time;
    if (kind == SessionType::World) boutWho_.emplace(other);
    bout_.endTime   = line.time;
    bout_.endOffset = lineEnd;
}

void Segmenter::CloseBout(Termination why) {
    if (!boutOpen_) return;
    boutOpen_ = false;
    // A fight is one the recorder will have taken for one too, or the two never
    // meet and the addon's session waits for a log that does not come:
    //   * any blow of the player's own at a dummy - a single one is still a pull;
    //   * kBoutMinActions lines with a player the player acted on as well; a
    //     neutral one's damage over time alone is a battleground's leftovers;
    //   * as many direct attacks from a hostile player, answered or not - a
    //     player killed without striking back was in a fight all the same.
    const bool dummy = bout_.type == SessionType::Dummy;
    const bool fought = boutMine_ && (dummy || boutActions_ >= kBoutMinActions);
    const bool attacked = boutAttacked_ && boutActions_ >= kBoutMinActions;
    if (!fought && !attacked) return;

    bout_.termination = why;
    bout_.participants.assign(boutWho_.begin(), boutWho_.end());
    if (open_ && current_.type == SessionType::Battleground) {
        heldBouts_.push_back(bout_);
    } else {
        sink_(bout_);
    }
}

void Segmenter::ReleaseHeldBouts(bool discard) {
    if (!discard) {
        for (const auto& bout : heldBouts_) sink_(bout);
    }
    heldBouts_.clear();
}

void Segmenter::HandleArenaStart(const LogLine& line, uint64_t byteOffset) {
    ArenaMatchStart start;
    if (!ParseArenaMatchStart(line.payload, start)) return;

    const bool isShuffle = start.bracket.find("Solo Shuffle") != std::string::npos;

    // Whatever was taken for a bout since the instance was entered was the arena
    // being set up - the gates are about to open.
    CloseBout(Termination::Quiet);
    ReleaseHeldBouts(true);

    if (open_ && current_.type == SessionType::Arena) {
        // Solo Shuffle: this start ends the previous round. The round's byte
        // range stops just before this line so the rounds do not overlap.
        CloseSession(Termination::SupersededByStart, line.time, byteOffset);
    }
    // An open provisional session is otherwise converted in place rather than
    // reopened, so the map data gathered since the ZONE_CHANGE survives.

    if (!open_) OpenSession(line, byteOffset);

    current_.type    = SessionType::Arena;
    current_.bracket = start.bracket;
    current_.rated   = IsRatedBracket(start.bracket);
    if (current_.instanceId == 0) current_.instanceId = start.instanceId;

    if (isShuffle) {
        // Rounds of one lobby share a lobbyIndex; the counter only advances on
        // the first round, which is the one that finds the count at zero.
        current_.lobbyIndex = (lobbyRoundCount_ == 0) ? nextLobbyIndex_++
                                                      : nextLobbyIndex_ - 1;
        current_.roundIndex = ++lobbyRoundCount_;
    } else {
        lobbyRoundCount_ = 0;
    }
}

void Segmenter::HandleZoneChange(const LogLine& line, uint64_t byteOffset) {
    ZoneChange zone;
    if (!ParseZoneChange(line.payload, zone)) return;

    if (zone.instanceId == instanceId_) {
        // Same instance, so not a transition - but the NAME may have resolved
        // since. ZONE_CHANGE lags the instance id: entering an arena reports
        // the city you queued from, corrected a second later. Arenas emit no
        // MAP_CHANGE, so this is the only chance to fix the label, and without
        // it six 3v3 sessions were filed as "Silvermoon City".
        //
        // Battlegrounds take their name from MAP_CHANGE, which is authoritative
        // and already set uiMapId - so they ignore this and keep the map name
        // rather than adopting a sub-zone like "Silverwing Hold".
        instanceName_ = zone.name;
        if (open_ && current_.uiMapId == 0) current_.mapName = zone.name;
        return;
    }

    // Leaving the previous instance ends whatever was open there. This is the
    // only terminator battlegrounds ever get, and the one that catches an arena
    // abandoned in progress. A bout first, so that one fought inside a
    // provisional battleground is held when the battleground decides.
    CloseBout(Termination::LeftInstance);
    if (open_) {
        CloseSession(Termination::LeftInstance, line.time, byteOffset);
    }

    instanceId_      = zone.instanceId;
    instanceName_    = zone.name;
    isPvE_           = false;
    lobbyRoundCount_ = 0;
    matchOver_       = false;

    // Zero is the old world - Silvermoon, Eversong, everything on the original
    // two continents - and nothing there is a match. It is kept as a shortcut
    // only: every other continent has an id of its own and is caught instead by
    // the teammate count in CloseSession.
    if (zone.instanceId == 0) return;

    // Entering an instance opens a provisional session. It becomes an arena if
    // ARENA_MATCH_START follows, is discarded if ENCOUNTER_START follows, and
    // otherwise closes as a battleground.
    OpenSession(line, byteOffset);
    current_.type    = SessionType::Battleground;
    current_.mapName = zone.name;
}

void Segmenter::Feed(const LogLine& line, uint64_t byteOffset, uint64_t byteLength) {
    const uint64_t lineEnd = byteOffset + byteLength;

    // Any line at all can show a bout has gone quiet: the time it carries is
    // past the point where someone would have had to act again for the fight to
    // go on.
    if (boutOpen_ && line.time - boutLastDirect_ > kBoutQuietMs) {
        CloseBout(Termination::Quiet);
    }

    switch (line.kind) {
    case Structural::CombatLogVersion:
        // Logging restarted. Anything open is truncated at this point: the gap
        // before this marker is unrecorded, so the session cannot continue.
        CloseBout(Termination::LoggingReset);
        CloseSession(Termination::LoggingReset, line.time, byteOffset);
        instanceId_      = 0;
        isPvE_           = false;
        lobbyRoundCount_ = 0;
        return;

    case Structural::ZoneChange:
        HandleZoneChange(line, byteOffset);
        return;

    case Structural::MapChange: {
        MapChange map;
        if (!ParseMapChange(line.payload, map)) return;
        lastUiMap_ = map.uiMapId;
        if (open_) {
            current_.uiMapId = map.uiMapId;
            // MAP_CHANGE names the map; ZONE_CHANGE names the sub-zone and lags
            // behind the instance id, so it can report the city you just left
            // while the id already points at the battleground. Verified in a
            // Warsong Gulch capture: ZONE_CHANGE,2106,"Silvermoon City" one
            // second before ZONE_CHANGE,2106,"Silverwing Hold". The map name
            // therefore always wins.
            current_.mapName = map.name;
            if (std::find(current_.uiMaps.begin(), current_.uiMaps.end(), map.uiMapId)
                == current_.uiMaps.end()) {
                current_.uiMaps.push_back(map.uiMapId);
            }
        }
        return;
    }

    case Structural::ArenaMatchStart:
        HandleArenaStart(line, byteOffset);
        return;

    case Structural::ArenaMatchEnd: {
        if (!open_) return;
        ArenaMatchEnd end;
        if (ParseArenaMatchEnd(line.payload, end)) {
            current_.endInfo    = end;
            current_.hasEndInfo = true;
            // A skirmish reports 0,0 for both ratings while rated play reports
            // real values, which corroborates the bracket string.
            if (end.newRating1 != 0 || end.newRating2 != 0) current_.rated = true;
        }
        CloseSession(Termination::CleanEnd, line.time, lineEnd);
        lobbyRoundCount_ = 0;
        matchOver_ = true;
        return;
    }

    case Structural::CombatantInfo:
        if (open_) ++current_.combatantCount;
        return;

    case Structural::EncounterStart:
        isPvE_ = true;
        return;

    default:
        break;
    }

    // Ordinary combat events only extend the open session's range and clock.
    // Read before extending it, so a line that turns out to belong to the next
    // zone can hand back the range as it stood in front of it.
    if (open_) {
        Inspect(line);
        current_.endTime   = line.time;
        current_.endOffset = lineEnd;
    }
    TrackBout(line, byteOffset, lineEnd);
}

void Segmenter::Inspect(const LogLine& line) {
    // Who is here is only asked about a provisional battleground, and only until
    // the answer is settled. Where here is has to be asked for the whole session,
    // because the question is where it ENDS - but only once MAP_CHANGE has said
    // what the session's own maps are, which arenas never do.
    const bool wantPlayers = current_.type == SessionType::Battleground
                          && (!sawHostilePlayer_ || grouped_.size() < kMinGroupedPlayers);
    const bool wantMap = !current_.uiMaps.empty();
    if (!wantPlayers && !wantMap) return;

    SplitFields(line.payload, fields_);

    // Source and destination sit at payload fields 0-3 and 4-7: GUID, name,
    // flags, raid flags.
    if (wantPlayers && fields_.size() >= 8) {
        for (size_t at : { size_t(0), size_t(4) }) {
            const uint32_t flags = UnitFlags(fields_[at + 2]);
            if (IsHostilePlayer(flags)) {
                sawHostilePlayer_ = true;
            } else if (IsGroupedPlayer(flags) && grouped_.size() < kMinGroupedPlayers) {
                grouped_.emplace(fields_[at]);
            }
        }
    }

    if (!wantMap) return;

    const size_t start = AdvancedStart(line.event);
    const size_t at    = start + kAdvancedMapOffset;
    if (fields_.size() <= at) return;
    // Three things at once, because an event without an advanced block has
    // something else at these positions: a GUID where the block starts, and a
    // coordinate pair in front of the map id.
    if (!LooksLikeGuid(fields_[start])) return;
    if (!IsDecimal(fields_[at - 2]) || !IsDecimal(fields_[at - 1])) return;

    int32_t uiMapId = 0;
    const auto& text = fields_[at];
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), uiMapId);
    if (parsed.ec != std::errc{} || parsed.ptr != text.data() + text.size()) return;

    // Zero is the load screen, not a map, and the last figures of the match
    // arrive inside it.
    if (uiMapId == 0) return;

    if (std::find(current_.uiMaps.begin(), current_.uiMaps.end(), uiMapId)
        != current_.uiMaps.end()) {
        cutPending_ = false;
    } else if (!cutPending_) {
        // Not this line: the range as it was in front of it.
        cutPending_ = true;
        cutOffset_  = current_.endOffset;
        cutTime_    = current_.endTime;
    }
}

void Segmenter::Finish() {
    CloseBout(Termination::Quiet);
    if (open_) CloseSession(Termination::EndOfData, current_.endTime, current_.endOffset);
    ReleaseHeldBouts(false);
}

} // namespace cs
