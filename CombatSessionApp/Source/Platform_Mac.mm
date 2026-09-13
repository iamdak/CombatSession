// CombatSession :: Platform, macOS
//
// The counterpart to Platform_Win32.cpp. Objective-C++ because the pickers, the
// sound and the alert are Cocoa, and Cocoa is the only way to get a native
// dialog; everything that does not need AppKit is plain POSIX.

#include "Platform.h"

#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <mach-o/dyld.h>

#include <sys/file.h>
#include <sys/stat.h>

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <climits>   // PATH_MAX
#include <cstdlib>   // realpath
#include <vector>

namespace fs = std::filesystem;

namespace cs {
namespace {

NSString* Str(const std::string& text) {
    return [NSString stringWithUTF8String:text.c_str()];
}

std::string FromStr(NSString* text) {
    if (!text) return {};
    const char* utf8 = [text UTF8String];
    return utf8 ? std::string(utf8) : std::string{};
}

fs::path HomeDir() {
    return FromStr(NSHomeDirectory());
}

// The login item is a LaunchAgent the user owns, which needs no privileges and
// can be read, edited or deleted with a text editor. SMAppService would be the
// modern equivalent but is macOS 13 and later only, and this is a plist either
// way - the framework just writes it somewhere the user cannot see.
constexpr const char* kAgentLabel = "com.combatsession.app";

fs::path AgentPath() {
    return HomeDir() / "Library" / "LaunchAgents"
                     / (std::string(kAgentLabel) + ".plist");
}

// Every modal in this file goes through here first, for two reasons.
//
// AppKit needs an NSApplication object before a panel or an alert will run, and
// one of the callers does not have one: the first run asks for the World of
// Warcraft folder from main, before the menu bar item is created. On Windows a
// message box needs nothing to exist; here it does. sharedApplication is
// idempotent, so the case that already has one costs nothing.
//
// The activation covers the other case. A menu bar accessory is not the active
// application when one of its menu items is chosen, and a modal opened by an
// inactive application can come up behind whatever the user was looking at -
// visible only in Mission Control, while the application appears to have hung.
void PrepareForModal() {
    [NSApplication sharedApplication];
    [NSApp activateIgnoringOtherApps:YES];
}

} // namespace

//------------------------------------------------------------------------------
// Process
//------------------------------------------------------------------------------

fs::path ExecutablePath() {
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);

    std::vector<char> buffer(size + 1, (char)0);
    if (_NSGetExecutablePath(buffer.data(), &size) != 0) return {};

    // Resolves symlinks and any ".." the launcher left in the path, so the
    // settings file and the archive land beside the real binary.
    char resolved[PATH_MAX]{};
    if (realpath(buffer.data(), resolved)) return fs::path(resolved);
    return fs::path(buffer.data());
}

// flock on a file in the user's temporary directory.
//
// The lock is a property of the open file description, so the kernel drops it
// when the process exits however it exits - the same guarantee a Windows mutex
// gives, and the reason neither needs a stale-lock recovery path. The file
// itself is left behind and is meant to be: it is zero bytes, and creating it
// fresh each time would race with the locking.
NamedLock::NamedLock(const std::string& name, bool tryOnly) {
    NSString* dir = NSTemporaryDirectory();
    path_ = FromStr([dir stringByAppendingPathComponent:Str(name + ".lock")]);

    fd_ = ::open(path_.c_str(), O_CREAT | O_RDWR, 0600);
    if (fd_ < 0) return;

    const int how = LOCK_EX | (tryOnly ? LOCK_NB : 0);
    while (::flock(fd_, how) != 0) {
        if (errno == EINTR) continue;   // a signal, not a contended lock
        ::close(fd_);
        fd_ = -1;
        return;
    }
    held_ = true;
}

NamedLock::~NamedLock() {
    if (fd_ < 0) return;
    if (held_) ::flock(fd_, LOCK_UN);
    ::close(fd_);
}

//------------------------------------------------------------------------------
// Shell
//------------------------------------------------------------------------------

// The alert sound the user chose in System Settings. Never missing, follows
// whatever they picked, and means the application ships no audio of its own.
void PlayDefaultAlert() {
    NSBeep();
}

void PlaySoundFile(const std::string& path) {
    if (path.empty()) {
        PlayDefaultAlert();
        return;
    }

    @autoreleasepool {
        // A file first, then a named system sound - so a settings file carried
        // over from Windows, or one naming a sound this Mac does not have,
        // still makes a noise rather than nothing.
        NSSound* sound = [[NSSound alloc] initWithContentsOfFile:Str(path)
                                                     byReference:YES];
        if (!sound) {
            NSString* name = [Str(path) lastPathComponent];
            sound = [NSSound soundNamed:[name stringByDeletingPathExtension]];
        }

        if (sound) {
            [sound play];
            return;
        }
    }
    PlayDefaultAlert();
}

// NSBeep is the system alert sound - the one the user picked in Sound
// preferences - which is as close as macOS has to "the error noise" and is what
// every other application uses to say the same thing.
void PlayErrorAlert() {
    NSBeep();
}

void OpenFolder(const fs::path& dir) {
    @autoreleasepool {
        NSURL* url = [NSURL fileURLWithPath:Str(dir.string()) isDirectory:YES];
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

// See the Windows note: the scheme check is what keeps this from being a
// general "open anything" hole for the sake of two compiled-in addresses.
void OpenUrl(const std::string& url) {
    if (url.rfind("http://", 0) != 0 && url.rfind("https://", 0) != 0) return;
    @autoreleasepool {
        NSURL* target = [NSURL URLWithString:Str(url)];
        if (target) [[NSWorkspace sharedWorkspace] openURL:target];
    }
}

bool Confirm(const std::string& title, const std::string& text) {
    @autoreleasepool {
        PrepareForModal();

        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText     = Str(title);
        alert.informativeText = Str(text);
        alert.alertStyle      = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"Continue"];
        [alert addButtonWithTitle:@"Cancel"];

        // The first button added is NSAlertFirstButtonReturn; anything else,
        // including closing the panel, is a no.
        return [alert runModal] == NSAlertFirstButtonReturn;
    }
}

bool ConfirmAction(const std::string& title, const std::string& text) {
    @autoreleasepool {
        PrepareForModal();

        NSAlert* alert = [[NSAlert alloc] init];
        alert.messageText     = Str(title);
        alert.informativeText = Str(text);
        alert.alertStyle      = NSAlertStyleInformational;
        [alert addButtonWithTitle:@"OK"];
        [alert addButtonWithTitle:@"Cancel"];

        return [alert runModal] == NSAlertFirstButtonReturn;
    }
}


std::string PickFolder(const std::string& title) {
    @autoreleasepool {
        PrepareForModal();

        NSOpenPanel* panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories    = YES;
        panel.canChooseFiles          = NO;
        panel.allowsMultipleSelection = NO;
        panel.message                 = Str(title);

        // The flavor folder lives inside the application bundle's own folder on
        // a default install, which is not somewhere Finder opens by default.
        panel.directoryURL =
            [NSURL fileURLWithPath:@"/Applications" isDirectory:YES];

        if ([panel runModal] != NSModalResponseOK) return {};
        return FromStr(panel.URL.path);
    }
}

std::string PickSoundFile(const std::string& current) {
    @autoreleasepool {
        PrepareForModal();

        NSOpenPanel* panel = [NSOpenPanel openPanel];
        panel.canChooseDirectories    = NO;
        panel.canChooseFiles          = YES;
        panel.allowsMultipleSelection = NO;
        panel.message = @"Sound to play when a reload is needed";

        // Content types rather than the older list of extensions, which has
        // been deprecated since macOS 12. UTTypeAudio covers every format
        // NSSound can play, including the .aiff the system sounds are in -
        // filtering by extension would have meant listing them and getting the
        // list wrong somewhere.
        panel.allowedContentTypes = @[ UTTypeAudio ];

        // Somewhere with sounds in it. The stock ones are the likely choice,
        // and a panel that opens on the user's home folder makes the user go
        // find them.
        NSString* start = @"/System/Library/Sounds";
        if (!current.empty()) {
            start = [Str(current) stringByDeletingLastPathComponent];
        }
        panel.directoryURL = [NSURL fileURLWithPath:start isDirectory:YES];

        if ([panel runModal] != NSModalResponseOK) return {};
        return FromStr(panel.URL.path);
    }
}

//------------------------------------------------------------------------------
// Login item
//------------------------------------------------------------------------------

bool SetStartAtLogin(bool enabled) {
    @autoreleasepool {
        const fs::path plist = AgentPath();

        if (!enabled) {
            std::error_code ec;
            fs::remove(plist, ec);
            return true;
        }

        std::error_code ec;
        fs::create_directories(plist.parent_path(), ec);

        NSDictionary* agent = @{
            @"Label"            : Str(kAgentLabel),
            @"ProgramArguments" : @[ Str(ExecutablePath().string()) ],
            @"RunAtLoad"        : @YES,
            // Not a daemon: it should start at login and stay stopped if the
            // user quits it from the menu bar, not be restarted behind them.
            @"KeepAlive"        : @NO,
        };

        return [agent writeToURL:[NSURL fileURLWithPath:Str(plist.string())]
                           error:nil];
    }
}

bool GetStartAtLogin() {
    std::error_code ec;
    return fs::exists(AgentPath(), ec);
}

const char* StartAtLoginLabel() { return "Open at Login"; }

} // namespace cs
