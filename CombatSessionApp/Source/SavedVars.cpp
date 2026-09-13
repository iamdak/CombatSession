#include "SavedVars.h"

#include "Version.h"

#include <fstream>
#include <sstream>
#include <vector>

namespace fs = std::filesystem;

namespace cs {
namespace {

// Reads one saved file in a single pass.
//
// The scan needs to know only two things: which keys sit directly inside the
// `cache` table, and what string follows `oldestWanted`. Tracking brace depth
// while stepping over string literals answers both, and stepping over literals
// is what keeps a unit name containing a brace from moving the depth.
AddonState ScanFile(const fs::path& path) {
    AddonState state;

    std::ifstream in(path, std::ios::binary);
    if (!in) return state;

    std::stringstream ss;
    ss << in.rdbuf();
    const std::string text = ss.str();

    int depth = 0;

    // Depth at which the keys of the cache table live, or -1 while outside it.
    int cacheDepth = -1;

    // The most recent string literal, which for `["name"] = value` is the name.
    std::string last;
    bool haveLast = false;

    for (size_t i = 0; i < text.size(); ++i) {
        const char c = text[i];

        if (c == '"') {
            std::string value;
            for (++i; i < text.size(); ++i) {
                if (text[i] == '\\' && i + 1 < text.size()) { value += text[++i]; continue; }
                if (text[i] == '"') break;
                value += text[i];
            }
            // Two strings in a row at the top level is `["field"] = "value"`.
            if (depth == 1 && haveLast) {
                if (last == kFloorField)       state.oldestWanted = value;
                if (last == kAppExpectedField) state.appExpected  = value;
            }
            last = value;
            haveLast = true;
            continue;
        }

        if (c == '{') {
            ++depth;
            if (haveLast && cacheDepth < 0 && last == kCacheField) {
                cacheDepth = depth;
            } else if (cacheDepth >= 0 && depth == cacheDepth + 1 && haveLast) {
                state.cached.insert(last);
            }
            haveLast = false;
            continue;
        }

        if (c == '}') {
            if (depth == cacheDepth) cacheDepth = -1;
            if (depth > 0) --depth;
            haveLast = false;
            continue;
        }
    }

    return state;
}

} // namespace

AddonState ReadAddonState(const fs::path& wtfRoot) {
    std::error_code ec;
    if (!fs::exists(wtfRoot, ec)) return {};

    std::vector<AddonState> found;
    for (const auto& account : fs::directory_iterator(wtfRoot, ec)) {
        if (!account.is_directory()) continue;

        const fs::path saved =
            account.path() / "SavedVariables" / "CombatSession.lua";
        if (!fs::exists(saved, ec)) continue;

        found.push_back(ScanFile(saved));
    }

    if (found.empty()) return {};

    AddonState combined = found.front();
    for (size_t i = 1; i < found.size(); ++i) {
        std::set<std::string> both;
        for (const auto& key : found[i].cached) {
            if (combined.cached.count(key)) both.insert(key);
        }
        combined.cached = std::move(both);

        // An account that has declined nothing pins the floor at "nothing",
        // which is the safe answer: keys lead with a timestamp, so lexical
        // order is chronological and the empty string is below everything.
        if (found[i].oldestWanted.empty() ||
            found[i].oldestWanted < combined.oldestWanted) {
            combined.oldestWanted = found[i].oldestWanted;
        }

        // Every account on one machine loads the same addon files, so these
        // agree in every real case. When they do not, one of them has saved
        // variables from before an addon update and has not logged in since;
        // the highest is the one the installed files actually ask for.
        if (combined.appExpected.empty()
            || ParseVersion(found[i].appExpected) > ParseVersion(combined.appExpected)) {
            combined.appExpected = found[i].appExpected;
        }
    }
    return combined;
}

} // namespace cs
