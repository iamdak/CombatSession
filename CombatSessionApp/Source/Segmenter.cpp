#include "Segmenter.h"

#include <algorithm>
#include <charconv>

namespace cs {
namespace {

// COMBATLOG_OBJECT_TYPE_PLAYER and COMBATLOG_OBJECT_REACTION_HOSTILE.
constexpr uint32_t kFlagPlayer  = 0x400;
constexpr uint32_t kFlagHostile = 0x40;

bool IsHostilePlayer(std::string_view flagField) {
    if (flagField.size() < 3 || flagField[0] != '0'
        || (flagField[1] != 'x' && flagField[1] != 'X')) {
        return false;
    }
    uint32_t flags = 0;
    std::from_chars(flagField.data() + 2, flagField.data() + flagField.size(),
                    flags, 16);
    return (flags & kFlagPlayer) && (flags & kFlagHostile);
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
    open_ = true;
}

void Segmenter::CloseSession(Termination why, Timestamp endTime, uint64_t endOffset) {
    if (!open_) return;

    current_.termination = why;
    current_.endTime     = endTime;
    current_.endOffset   = endOffset;

    // A visit that turned out to be PvE is discarded: only arenas and
    // battlegrounds are tracked, and a dungeon would otherwise be emitted as a
    // battleground purely for lacking ARENA_MATCH_START.
    // A battleground with no enemy player in it was not a battleground: any
    // instanced zone opens a provisional one, including housing.
    const bool looksPvP = current_.type == SessionType::Arena
                       || (current_.type == SessionType::Battleground && sawHostilePlayer_);
    const bool emit = !isPvE_ && looksPvP;
    if (emit) sink_(current_);

    open_ = false;
    current_ = Session{};
}

void Segmenter::HandleArenaStart(const LogLine& line, uint64_t byteOffset) {
    ArenaMatchStart start;
    if (!ParseArenaMatchStart(line.payload, start)) return;

    const bool isShuffle = start.bracket.find("Solo Shuffle") != std::string::npos;

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
    // abandoned in progress.
    if (open_) {
        CloseSession(Termination::LeftInstance, line.time, byteOffset);
    }

    instanceId_      = zone.instanceId;
    instanceName_    = zone.name;
    isPvE_           = false;
    lobbyRoundCount_ = 0;

    if (zone.instanceId == 0) return;   // back to the open world

    // Entering an instance opens a provisional session. It becomes an arena if
    // ARENA_MATCH_START follows, is discarded if ENCOUNTER_START follows, and
    // otherwise closes as a battleground.
    OpenSession(line, byteOffset);
    current_.type    = SessionType::Battleground;
    current_.mapName = zone.name;
}

void Segmenter::Feed(const LogLine& line, uint64_t byteOffset, uint64_t byteLength) {
    const uint64_t lineEnd = byteOffset + byteLength;

    switch (line.kind) {
    case Structural::CombatLogVersion:
        // Logging restarted. Anything open is truncated at this point: the gap
        // before this marker is unrecorded, so the session cannot continue.
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
        if (open_ && ParseMapChange(line.payload, map)) {
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
    if (open_) {
        current_.endTime   = line.time;
        current_.endOffset = lineEnd;

        // Look for an enemy player, but only until one is found - after that
        // this costs nothing. Source and destination flags are payload fields
        // 3 and 7.
        if (!sawHostilePlayer_ && current_.type == SessionType::Battleground) {
            SplitFields(line.payload, fields_);
            if (fields_.size() >= 7) {
                if (IsHostilePlayer(fields_[2]) || IsHostilePlayer(fields_[6])) {
                    sawHostilePlayer_ = true;
                }
            }
        }
    }
}

void Segmenter::Finish() {
    if (!open_) return;
    CloseSession(Termination::EndOfData, current_.endTime, current_.endOffset);
}

} // namespace cs
