// CombatSession :: Platform
//
// Everything the application needs from the operating system, and nothing else.
//
// The parsing half of this program - logs, sessions, chunks, the archive - is
// plain C++ and standard library, and was portable already. What tied it to
// Windows was a thin outer layer: where the executable is, how to make a noise,
// how to ask for a folder, how to keep two copies of the program out of each
// other's way. That layer is declared here and implemented once per platform,
// so adding a system means adding one file rather than threading #ifdefs
// through code that has nothing to do with any of it.
//
// The tray itself is a bigger thing than a function call and lives in Tray.h.

#pragma once

#include <filesystem>
#include <string>
#include <vector>

namespace cs {

//------------------------------------------------------------------------------
// Process
//------------------------------------------------------------------------------

// Hands back a console the system attached to this process.
//
// Only Windows has anything to do here: it gives every console-subsystem
// process a console window whether it wants one or not, and the subsystem is
// what decides whether a shell waits for us - so the executable asks for a
// console in order to behave on a command line, then gives it back when it is
// running as a background app. Elsewhere a process inherits a terminal or does
// not, and there is nothing to hand back.
void ReleaseConsole();

// Absolute path of the running executable. Settings, the raw archive and the
// login item are all resolved from it, so the folder can be moved or copied and
// carries its configuration with it.
std::filesystem::path ExecutablePath();

// Cross-process exclusion by name, released by the operating system however the
// process exits - including a crash, so a dead process cannot lock a user out
// of their own application.
//
// Two of these exist: one held for the life of the tray so only one runs, and
// one held for the duration of a pass so a command line and a tray cannot both
// rewrite the read offsets.
class NamedLock {
public:
    // Blocks until the lock is available. With tryOnly, returns immediately and
    // held() reports whether it was taken.
    explicit NamedLock(const std::string& name, bool tryOnly = false);
    ~NamedLock();

    NamedLock(const NamedLock&) = delete;
    NamedLock& operator=(const NamedLock&) = delete;

    bool held() const { return held_; }

private:
    // One system's worth of state each, kept opaque so this header stays free of
    // system headers: Windows uses a mutex handle, POSIX a descriptor on a lock
    // file. Two unused words on either system is cheaper than a pimpl for a
    // class whose whole job is to be created on the stack and destroyed.
    // Exactly one system uses each of the first three, which is what the
    // attribute says: a build for either one is right to see the others as
    // dead, and should not have to say so as a warning.
    [[maybe_unused]] void*       handle_ = nullptr;   // Windows: HANDLE
    [[maybe_unused]] int         fd_     = -1;        // POSIX: descriptor
    [[maybe_unused]] std::string path_;               // POSIX: the lock file
    bool                         held_   = false;
};

//------------------------------------------------------------------------------
// Shell
//------------------------------------------------------------------------------

// Plays a sound file, falling back to the system alert sound if it cannot be
// played. An empty path is silence, which is a setting rather than a failure.
void PlaySoundFile(const std::string& path);

// Reveals a directory in the system file manager.
void OpenFolder(const std::filesystem::path& dir);

// A modal notice. Used only where there is something the user must decide -
// mostly the first run with no World of Warcraft folder to be found.
void ShowMessage(const std::string& title, const std::string& text, bool warning);

// Modal pickers. Both return an empty string when the user cancels.
std::string PickFolder(const std::string& title);
std::string PickSoundFile(const std::string& current);

//------------------------------------------------------------------------------
// Login item
//------------------------------------------------------------------------------

// Registering the application to start when the user logs in. Never requires
// administrator rights on either system: an HKCU Run value on Windows, a
// LaunchAgent in the user's own Library on macOS.
bool SetStartAtLogin(bool enabled);
bool GetStartAtLogin();

// Menu wording, which is not the same thing on both systems and should not read
// as a translation of the other one.
const char* StartAtLoginLabel();

//------------------------------------------------------------------------------
// Defaults
//------------------------------------------------------------------------------

// A notification sound that exists on this system, or empty if none does.
std::string DefaultAlertSound();

// Where World of Warcraft is usually installed here, most likely first. Probed
// in order when the flavor folder has not been set.
std::vector<std::filesystem::path> DefaultWowRoots();

} // namespace cs
