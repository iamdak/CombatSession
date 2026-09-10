// CombatSession :: Config
//
// Settings live in a JSON file beside the executable rather than in the
// registry or in Application Support, so the whole application stays portable:
// copying the Binary folder carries its configuration with it, and the same
// file means the same thing on both systems.

#pragma once

#include <filesystem>
#include <string>

namespace cs {

struct Config {
    // Flavor folder - the one containing Logs and Interface. Stored rather than
    // the install root because a machine commonly has _retail_, _ptr_, _beta_
    // and _xptr_ side by side.
    std::string wowPath;

    // Archive retention in sessions. Independent of the chunk queue.
    int  rawLimit     = 200;
    // Safety valve on the chunk queue for when the addon never runs.
    int  pendingLimit = 100;
    bool archiveRaw   = true;

    // Start when the user logs in: an HKCU Run value on Windows, a LaunchAgent
    // on macOS. Neither needs administrator rights.
    bool startAtLogin = false;

    // How long to wait after a log stops changing before processing it, so a
    // burst of writes results in one pass rather than many.
    int settleSeconds = 5;

    // How long a log must sit unchanged before it counts as finished, which is
    // what allows a session still open at end-of-data to be emitted at all.
    //
    // Well above settleSeconds, and deliberately generous. The client buffers
    // the combat log, so "unchanged" means "not flushed lately", not "the match
    // is over" - a live Deephaul Ravine went two minutes between flushes. At the
    // old 120 that was mistaken for a finished log and the match was cut short.
    // A finished log stays quiet forever, so the only cost of a long window is
    // waiting a little longer for the rare session that never got a closing
    // event.
    int closedAfterSeconds = 600;

    // Played once when a session becomes visible but the addon has not loaded it
    // yet, since that is the only state the application cannot resolve on its
    // own - it needs the user to reload. Empty disables it; a missing file falls
    // back to the system alert sound rather than failing silently.
    std::string reloadSound;

    bool Load(const std::filesystem::path& path);
    bool Save(const std::filesystem::path& path) const;

    // Best-effort detection when wowPath is unset: walks up from the executable,
    // then probes this system's usual install locations for a folder containing
    // both Logs and Interface/AddOns.
    static std::string DetectWowPath();

    std::filesystem::path LogsDir()   const;
    std::filesystem::path AddOnsDir() const;
    // .../WTF/Account, read-only, for the addon consumption state.
    std::filesystem::path WtfRoot()   const;
    // Raw archive lives beside the executable and is never distributed.
    std::filesystem::path RawDir()    const;
    bool IsValid() const;
};

// Path to settings.json beside the running executable.
std::filesystem::path DefaultConfigPath();

} // namespace cs
