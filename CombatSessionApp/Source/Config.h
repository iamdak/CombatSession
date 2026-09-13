// CombatSession :: Config
//
// Settings live in a JSON file beside the executable rather than in the
// registry or in Application Support, so the whole application stays portable:
// copying the folder carries its configuration with it, the file can be read
// and edited with a text editor, and deleting it leaves nothing behind.
//
// Options default off, with one exception noted where it is declared. Nothing
// is written outside this folder, and no work is done until the user has said
// so - including the World of Warcraft folder, which is asked for rather than
// guessed at.

#pragma once

#include <filesystem>
#include <string>

namespace cs {

// How often the reload alert repeats while a reload is still outstanding.
enum class AlertRepeat {
    Once  = 0,    // one sound when the state is first reached
    Every = 1,    // every repeatSeconds until the user reloads
};

struct Config {
    // The flavor folder - the one containing Logs and Interface. Empty until
    // the user sets it, and empty means the application does nothing at all.
    // Never detected: probing a machine for game installations is not something
    // a program should do before being asked.
    std::string wowPath;

    //--------------------------------------------------------------------------
    // Options, all off until chosen
    //--------------------------------------------------------------------------

    // Start when the user logs in. A shortcut in the Startup folder, never a
    // registry value - see Platform.h.
    bool startAtLogin = false;

    // Start without putting a window on screen, however the program was
    // launched. Independent of startAtLogin: the two are often wanted together,
    // but a user who runs this by hand and wants it out of the way should not
    // have to enable a login item to get that.
    bool startMinimized = false;

    // Keep a compressed copy of each processed session. Off by default: it is
    // the only thing here that consumes disk without being asked, and the cost
    // of it being off is that rebuilding data from scratch is not possible.
    bool archiveRaw = false;

    // Minimise into the notification area rather than the taskbar. Off is the
    // ordinary behaviour, which is what someone who has not chosen expects.
    bool minimizeToTray = false;

    // How often the Logs folder and the addon's saved variables are checked.
    //
    // Five seconds rather than the twice a second this used to poll at. The
    // cost of a slower poll is only how soon a finished match is noticed, and
    // the settle delay already means nothing is processed the instant it is
    // seen - so the responsiveness that was bought by polling hard was never
    // visible to anyone. What it did buy was a process enumerating a directory
    // forty times a minute forever, which is a strange thing for a program to
    // be doing when looked at from outside.
    int pollSeconds = 5;

    //--------------------------------------------------------------------------
    // Reload alert
    //--------------------------------------------------------------------------

    // Whether to make any noise when a reload becomes necessary. On, unlike
    // everything else here: a reload is the one state the application cannot
    // resolve on its own, and a user who has not looked at the window has no
    // other way to learn about it. The default sound is the system's own
    // notification, so it is the noise they already expect from a notification
    // rather than anything this program brought with it.
    bool soundEnabled = true;

    // The sound to play. Empty means the system notification sound, which is
    // the default and is what the user has already chosen for notifications.
    std::string reloadSound;

    AlertRepeat alertRepeat   = AlertRepeat::Once;
    int         repeatSeconds = 60;

    //--------------------------------------------------------------------------
    // Tuning, not shown in the window
    //--------------------------------------------------------------------------

    // Archive retention in sessions. Independent of the chunk queue.
    int rawLimit = 200;
    // Safety valve on the chunk queue for when the addon never runs.
    int pendingLimit = 100;

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

    //--------------------------------------------------------------------------

    bool Load(const std::filesystem::path& path);
    bool Save(const std::filesystem::path& path) const;

    std::filesystem::path LogsDir()   const;
    std::filesystem::path AddOnsDir() const;
    // .../WTF/Account, read-only, for the addon consumption state.
    std::filesystem::path WtfRoot()   const;
    // Raw archive lives beside the executable and is never distributed.
    std::filesystem::path RawDir()    const;

    // True when wowPath names a folder that really is a flavor directory. The
    // application is inert until this is true, and says so.
    bool IsValid() const;
};

// Path to settings.json beside the running executable.
std::filesystem::path DefaultConfigPath();

// True when a folder looks like a World of Warcraft flavor directory. Exposed
// so the window can reject a wrong choice without saving it first.
bool LooksLikeFlavor(const std::filesystem::path& dir);

} // namespace cs
