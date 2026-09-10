// CombatSession :: Tray
//
// The status-area shell, split so the same application logic drives a Windows
// notification icon and a macOS menu bar item.
//
// The split is along one line: the controller decides what the menu says and
// what a click means, the host knows how to draw a menu and pump an event loop.
// Everything that made the old tray Windows-only was on the host side - HWNDs,
// HICONs, a message pump - and none of it was ever a decision about the
// application. What is left in the controller is portable by construction.

#pragma once

#include <memory>
#include <string>
#include <vector>

namespace cs {

// What the icon colour means. NeedsReload is not an error: the chunks are
// written and safe, the addon simply cannot see them until the client next
// loads, and nothing but the user can make that happen.
enum class TrayState { Idle = 0, Working = 1, NeedsReload = 2 };

struct TrayMenuItem {
    int         id        = 0;
    std::string label;
    bool        enabled   = true;
    bool        checked   = false;
    bool        separator = false;

    static TrayMenuItem Divider() {
        TrayMenuItem item;
        item.separator = true;
        return item;
    }
};

// The application side. Implemented by the tray app; called on the UI thread.
class TrayController {
public:
    virtual ~TrayController() = default;

    // Built fresh every time the menu opens, so what it shows is the state as
    // of the click rather than as of startup.
    virtual std::vector<TrayMenuItem> BuildMenu() = 0;
    virtual void OnCommand(int id) = 0;
};

// The system side. Implemented once per platform.
class TrayHost {
public:
    virtual ~TrayHost() = default;

    // Safe to call from any thread: the watcher runs on its own and must not
    // touch the status area directly. Implementations marshal to the UI thread.
    virtual void Update(TrayState state, const std::string& tooltip) = 0;

    // Runs the event loop on the calling thread until Quit. Returns the exit
    // code. Must be called on the process's main thread - macOS requires it,
    // and Windows does not care.
    virtual int Run() = 0;

    // Asks the loop to finish. Safe from any thread.
    virtual void Quit() = 0;
};

// Null when the status area is unavailable, which is a reason to exit rather
// than to run on invisibly.
std::unique_ptr<TrayHost> CreateTrayHost(TrayController& controller);

} // namespace cs
