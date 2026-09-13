// CombatSession :: Version
//
// One definition, included by both the C++ and the resource script, so the
// number in the window, the number in the file properties and the number in the
// release cannot drift apart.

#pragma once

#define CS_VERSION_MAJOR 0
#define CS_VERSION_MINOR 11
#define CS_VERSION_PATCH 0
#define CS_VERSION_BUILD 0

// VERSIONINFO wants four comma-separated numbers; everything else wants text.
#define CS_VERSION_FIELDS 0,11,0,0
#define CS_VERSION_FULL   "0.11.0.0"
#define CS_VERSION_SHORT  "0.11"

// The resource compiler reads this file for the macros above and cannot parse
// C++, so everything below is hidden from it.
#ifndef RC_INVOKED

#include <cstdint>
#include <string>

namespace cs {

// A version as one comparable number.
//
// The addon and the application are shipped separately and updated separately,
// so the only way either can tell whether it is talking to a build it
// understands is to compare version numbers - which means a version has to be
// an ordered value rather than a string that happens to look like one. Four
// fields of three digits each orders correctly up to 999 in every position,
// which is more than this will ever need and small enough to survive a trip
// through Lua's doubles without losing a digit.
using VersionCode = int64_t;

constexpr VersionCode MakeVersion(int major, int minor, int patch, int build) {
    return (static_cast<VersionCode>(major) * 1000000000)
         + (static_cast<VersionCode>(minor) * 1000000)
         + (static_cast<VersionCode>(patch) * 1000)
         +  static_cast<VersionCode>(build);
}

constexpr VersionCode kAppVersion =
    MakeVersion(CS_VERSION_MAJOR, CS_VERSION_MINOR,
                CS_VERSION_PATCH, CS_VERSION_BUILD);

// Parses "0.11", "0.11.2" or "0.11.2.7". Missing fields read as zero, so the
// short form the window shows and the long form the file properties carry
// compare equal - they are the same release written two ways. Returns 0 for
// anything unparseable, which is how "no answer" is told from version zero:
// nothing this program ships is version 0.0.0.0.
inline VersionCode ParseVersion(const std::string& text) {
    int field[4] = { 0, 0, 0, 0 };
    int index = 0;
    bool anyDigit = false;

    for (size_t i = 0; i < text.size() && index < 4; ++i) {
        const char c = text[i];
        if (c >= '0' && c <= '9') {
            field[index] = field[index] * 10 + (c - '0');
            if (field[index] > 999) field[index] = 999;
            anyDigit = true;
        } else if (c == '.') {
            ++index;
        } else {
            break;   // trailing text - a suffix like "-beta" ends the number
        }
    }

    if (!anyDigit) return 0;
    return MakeVersion(field[0], field[1], field[2], field[3]);
}

// Back to text, for a message that has to name the version it is complaining
// about. Trailing zero fields are dropped: "0.11" rather than "0.11.0.0",
// because the short form is what the user sees everywhere else.
inline std::string VersionText(VersionCode code) {
    if (code <= 0) return "unknown";

    int field[4];
    field[0] = static_cast<int>((code / 1000000000) % 1000);
    field[1] = static_cast<int>((code / 1000000) % 1000);
    field[2] = static_cast<int>((code / 1000) % 1000);
    field[3] = static_cast<int>(code % 1000);

    int last = 1;   // major.minor always shown, however small
    for (int i = 3; i >= 2; --i) {
        if (field[i] != 0) { last = i; break; }
    }

    std::string out;
    for (int i = 0; i <= last; ++i) {
        if (i) out += '.';
        out += std::to_string(field[i]);
    }
    return out;
}

} // namespace cs

#endif // RC_INVOKED
