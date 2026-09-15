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
// The windows themselves are bigger things than a function call: the status
// area is in Tray.h, the main window in MainWindow.h.

#pragma once

#include <filesystem>
#include <string>

namespace cs {

//------------------------------------------------------------------------------
// Process
//------------------------------------------------------------------------------

// Absolute path of the running executable. Settings, the raw archive and the
// login item are all resolved from it, so the folder can be moved or copied and
// carries its configuration with it.
std::filesystem::path ExecutablePath();

// Cross-process exclusion by name, released by the operating system however the
// process exits - including a crash, so a dead process cannot lock a user out
// of their own application.
//
// Two of these exist: one held for the life of the application so only one
// runs, and one held for the duration of a pass so two copies cannot both
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
    // system headers. Exactly one platform uses each of the first three, which
    // is what the attribute says: a build for either is right to see the others
    // as dead, and should not have to say so as a warning.
    [[maybe_unused]] void*       handle_ = nullptr;   // Windows: HANDLE
    [[maybe_unused]] int         fd_     = -1;        // POSIX: descriptor
    [[maybe_unused]] std::string path_;               // POSIX: the lock file
    bool                         held_   = false;
};

//------------------------------------------------------------------------------
// Shell
//------------------------------------------------------------------------------

// Plays a sound file. An empty path falls through to PlayDefaultAlert, as does
// a file that cannot be played - a sound the user has since moved should still
// make the noise it was asked for.
void PlaySoundFile(const std::string& path);

// The sound this system already uses to tell the user something has happened.
//
// Preferred to naming a file. It is whatever the user has already decided
// notifications should sound like, it is never missing, it follows their theme,
// and it means the application ships no audio and hunts for none on disk.
void PlayDefaultAlert();

// The system's error sound, and deliberately not configurable.
//
// The reload alert is a convenience and the user owns it - they choose the
// file, or turn it off. A version mismatch is not a convenience: the addon and
// the application no longer agree on the format between them, and whatever is
// produced while that is true is at best wrong. So it speaks in the voice the
// system reserves for errors, which every user already recognises and nobody
// has to have configured.
void PlayErrorAlert();

// Whether another process currently holds the file open for writing.
//
// This is how the application can tell that World of Warcraft has finished with
// a combat log without waiting out a timer: the client holds its log open for
// the whole session and releases it on exit, or when logging is switched off.
// Both of those mean "no more is coming", and both are worth knowing at once.
//
// Three-valued, because not every system can answer. Unknown means the caller
// should fall back to whatever it did before rather than assume either way.
enum class FileBusy { Unknown = 0, No, Yes };
FileBusy FileHeldOpen(const std::filesystem::path& file);

// Reveals a directory in the system file manager.
void OpenFolder(const std::filesystem::path& dir);

// Opens an http or https address in the user's default browser. Anything else
// is refused: this exists to reach two known pages, and a general "run whatever
// this string says" is not a thing this program needs.
void OpenUrl(const std::string& url);

// A yes/no question. True means the user agreed; cancelling or closing means
// no, because the only things asked here are things not worth doing by accident.
bool Confirm(const std::string& title, const std::string& text);

// The same question put as OK and Cancel rather than Yes and No, for an action
// the user has already chosen by clicking something - the dialog is explaining
// what is about to happen, not asking whether they meant it.
bool ConfirmAction(const std::string& title, const std::string& text);

// Modal pickers. Both return an empty string when the user cancels.
std::string PickFolder(const std::string& title);
std::string PickSoundFile(const std::string& current);

//------------------------------------------------------------------------------
// Login item
//------------------------------------------------------------------------------

// Registering the application to start when the user logs in.
//
// Deliberately a file on both systems - a shortcut in the Startup folder on
// Windows, a LaunchAgent plist on macOS - and never a registry value. A user
// can see it, move it and delete it with the tools they already have, where a
// Run key is invisible without a registry editor. That is the difference
// between a program that starts with the system and one that installs itself,
// and it is a difference security software is right to care about.
//
// Enabling is idempotent and always rewrites the entry to point at the running
// executable, replacing any entry left by a copy of this application somewhere
// else - so there is never more than one, and it never launches a binary the
// user has since moved or replaced.
bool SetStartAtLogin(bool enabled);
bool GetStartAtLogin();

// Menu wording, which is not the same thing on both systems and should not read
// as a translation of the other one.
const char* StartAtLoginLabel();

} // namespace cs
