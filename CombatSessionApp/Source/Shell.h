// CombatSession :: Shell
//
// The user interface, split so the same application logic drives a Windows
// window with a notification icon and a macOS menu bar item.
//
// The split is along one line: the controller decides what the application is
// doing and what a command means, the shell knows how to draw and how to pump
// an event loop. Nothing on the controller side is a decision about an
// operating system, which is what keeps it portable by construction.

#pragma once

#include "Config.h"

#include <memory>
#include <string>
#include <vector>

namespace cs {

// What the icon colour means. NeedsReload is not an error: the chunks are
// written and safe, the addon simply cannot see them until the client next
// loads, and nothing but the user can make that happen.
enum class TrayState { Idle = 0, Working = 1, NeedsReload = 2 };

// Command ids, shared so a menu item and a button that do the same thing are
// the same thing. The ampersand in a label marks the keyboard accelerator.
enum Command {
    kCmdStatus     = 1000,   // the status line; never actionable
    kCmdProcessNow = 1001,
    kCmdOpenData   = 1002,
    kCmdOpenLogs   = 1003,
    kCmdQuit       = 1004,

    // Reachable only from the window, so they are absent from the menu.
    kCmdSetWowPath = 1010,
    kCmdSetSound   = 1011,
    kCmdUseDefaultSound = 1012,
    kCmdRebuildAll = 1013,

    // The two update pages. Which one a user needs depends on which half is
    // behind, which is why both are always present and the labels above them
    // say which - rather than one button that changes where it goes.
    kCmdAddonPage  = 1014,
    kCmdAppPage    = 1015,
};

// Where the two halves stand relative to each other.
//
// The addon states an application version it is written against, and the
// application knows its own. Those two numbers are the whole of it: there is no
// negotiation and no compatibility range, because the format between them
// changes shape rather than gaining fields, and a half that guesses is worse
// than a half that stops and says so.
enum class VersionState {
    // Nothing to compare yet. A fresh install before the addon has ever saved,
    // or no World of Warcraft folder set. Not a mismatch.
    Unknown = 0,
    Match,
    // The addon is written against an OLDER application than the one running,
    // so the addon is the half that is behind.
    AddonOutdated,
    // The addon wants a NEWER application than the one running.
    AppOutdated,
};

struct VersionStatus {
    VersionState state = VersionState::Unknown;

    std::string running;    // the version of this application
    std::string expected;   // the version the installed addon asks for

    // Ready-made lines, so no shell has to work out its own wording and the
    // Windows window and the macOS menu cannot end up saying different things.
    std::string addonLine;  // over the CurseForge button
    std::string appLine;    // over the GitHub button
    std::string banner;     // across the top; empty when there is nothing wrong
};

inline bool IsMismatch(VersionState state) {
    return state == VersionState::AddonOutdated
        || state == VersionState::AppOutdated;
}

struct MenuItem {
    int         id        = 0;
    std::string label;
    bool        enabled   = true;
    bool        checked   = false;
    bool        separator = false;

    static MenuItem Divider() {
        MenuItem item;
        item.separator = true;
        return item;
    }
};

// The application side. Called on the UI thread.
class AppController {
public:
    virtual ~AppController() = default;

    // Built fresh every time a menu opens, so what it shows is the state as of
    // the click rather than as of startup.
    //
    // Compact drops everything the window already offers, which on Windows is
    // most of it. A shell with nowhere else to put the settings asks for the
    // full menu instead, so no platform ends up with an option it cannot reach.
    virtual std::vector<MenuItem> BuildMenu(bool compact) = 0;
    virtual void OnCommand(int id) = 0;

    // Settings, for a shell that has somewhere to show them. The shell mutates
    // the returned object and then calls SettingsChanged, which is what makes
    // the change durable and applies anything that has an immediate effect.
    virtual Config& Settings() = 0;
    virtual void    SettingsChanged() = 0;

    virtual std::string StatusText() const = 0;
    virtual bool        Busy() const = 0;

    // Read on every repaint rather than pushed, for the same reason the menu is
    // built on every open: the answer changes when the addon next saves, which
    // is a moment no shell is told about.
    virtual VersionStatus Versions() const = 0;
};

class ShellHost {
public:
    virtual ~ShellHost() = default;

    // Safe to call from any thread: the watcher runs on its own and must not
    // touch the interface directly. Implementations marshal to the UI thread.
    virtual void Update(TrayState state, const std::string& tooltip) = 0;

    // Runs the event loop on the calling thread until Quit. Returns the exit
    // code. Must be called on the process's main thread - macOS requires it,
    // and Windows does not care.
    virtual int Run() = 0;

    // Asks the loop to finish. Safe from any thread.
    virtual void Quit() = 0;

    // True when this shell has a window of its own, and so already offers the
    // settings that would otherwise have to live in the menu.
    virtual bool HasWindow() const = 0;
};

// Null when the interface cannot be created, which is a reason to exit rather
// than to run on invisibly.
std::unique_ptr<ShellHost> CreateShell(AppController& controller);

// The first-run question, asked before the application has a window.
//
// `path` carries the current setting in and the chosen one out; the return value
// says whether the user chose rather than cancelled. Cancelling is allowed and
// leaves the application running with nothing to do, which it then says plainly
// rather than nagging.
bool PromptForWowFolder(std::string& path);

} // namespace cs
