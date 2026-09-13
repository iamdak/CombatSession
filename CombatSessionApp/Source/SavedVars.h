// CombatSession :: SavedVars
//
// Reads the addon's consumption state out of its SavedVariables.
//
// This is the only place the application looks at a client-written file, and it
// only ever reads. The client rewrites SavedVariables wholesale at logout,
// reload and exit, so the value seen here always lags the game by one of those
// events - chunks simply linger slightly longer than strictly necessary.
//
// What is read is deliberately the addon's own cache table rather than a
// progress marker it writes alongside. A marker and a cache are two statements
// that can disagree: the client serialises from memory in a single pass, and
// when that pass came up short the marker saved intact while most of the cache
// did not, so the application collected chunks for sessions that were never
// really held. Reading the keys of the cache itself cannot disagree with the
// cache, because it is the cache.
//
// Rather than embedding a Lua parser, this scans the saved form directly. The
// file is one flat brace-nested table, so a single pass tracking depth and
// stepping over string literals is enough - and cheap, a few milliseconds on a
// file far larger than this one ever gets.

#pragma once

#include <filesystem>
#include <set>
#include <string>

namespace cs {

// Field carrying the floor, e.g.
//   ["oldestWanted"] = "20260907_162319_998_0"
inline constexpr const char* kFloorField = "oldestWanted";

// Table whose keys are the session keys the addon holds.
inline constexpr const char* kCacheField = "cache";

// The application version the installed addon is written against, e.g.
//   ["appExpected"] = "0.12"
//
// Written as text rather than as a number for one practical reason: this
// scanner already reads `["field"] = "string"` pairs and would need a second
// kind of parsing to read anything else. A version is a string everywhere else
// in both programs anyway.
inline constexpr const char* kAppExpectedField = "appExpected";

struct AddonState {
    // Session keys the addon currently holds a parsed cache for.
    std::set<std::string> cached;

    // What the addon says it needs. Empty when no addon has written its saved
    // variables yet, which is the ordinary state of a fresh install and is not
    // a mismatch - there is nothing to disagree with.
    std::string appExpected;

    // Oldest key the addon still wants. Sessions below it have been declined
    // for good - its cache is full and newer sessions won - so their chunks are
    // collectable even though they were never cached. Empty means nothing has
    // been declined, and therefore nothing may be collected on this basis.
    std::string oldestWanted;
};

// Combines the state of every account folder under `wtfRoot` (.../WTF/Account):
// the intersection of their caches and the lowest floor. Both are deliberate.
// With more than one account using the addon, a chunk is only safe to delete
// once all of them are done with it.
AddonState ReadAddonState(const std::filesystem::path& wtfRoot);

} // namespace cs
