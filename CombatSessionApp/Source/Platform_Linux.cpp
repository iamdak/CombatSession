// CombatSession :: Platform, Linux
//
// The counterpart to Platform_Win32.cpp and Platform_Mac.mm. The dialogs are GTK
// 3, which is what every desktop on Linux can show whatever it draws its own
// windows with; opening folders and pages goes through GIO, which hands them to
// whatever the desktop has chosen. Sounds are played by the desktop's own sound
// player rather than by an audio library linked in here: the sound theme, the
// output device and the volume are all the desktop's business already.
//
// World of Warcraft itself runs under Wine or Proton here, and nothing below
// needs to know: its folder is an ordinary directory inside a prefix, and the
// process holding its combat log open is an ordinary process of the same user.

#include "Platform.h"

#include <gtk/gtk.h>

#include <sys/file.h>
#include <sys/stat.h>
#include <sys/vfs.h>

#include <fcntl.h>
#include <unistd.h>

#include <cerrno>
#include <climits>   // PATH_MAX
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace cs {
namespace {

fs::path HomeDir() {
    const char* home = std::getenv("HOME");
    if (home && *home == '/') return fs::path(home);
    return fs::path(g_get_home_dir());
}

// $XDG_CONFIG_HOME, which is ~/.config unless the user has moved it.
fs::path ConfigHome() {
    const char* xdg = std::getenv("XDG_CONFIG_HOME");
    if (xdg && *xdg == '/') return fs::path(xdg);
    return HomeDir() / ".config";
}

// The login item is an XDG autostart entry: a .desktop file the user owns, which
// every desktop that starts anything at login reads, and which can be read, edited
// or deleted with a text editor - the same reasoning as the Startup shortcut and
// the LaunchAgent.
fs::path AutostartPath() {
    return ConfigHome() / "autostart" / "combatsession.desktop";
}

// Every dialog goes through here first. The first-run question is asked before
// the status icon exists, so nothing has started GTK yet; gtk_init_check is safe
// to call again once something has.
bool EnsureGtk() {
    static bool ready = false;
    if (!ready) {
        // X11 first, as the status icon needs; see Shell_Linux.cpp.
        gdk_set_allowed_backends("x11,*");
        ready = gtk_init_check(nullptr, nullptr);
    }
    return ready;
}

// Runs a program by name, without a shell and without waiting for it. GLib reaps
// the child once it exits, so a sound played every few minutes for a week leaves
// nothing behind. False when the program is not installed.
bool Launch(const std::vector<std::string>& argv) {
    std::vector<gchar*> args;
    for (const auto& arg : argv) args.push_back(const_cast<gchar*>(arg.c_str()));
    args.push_back(nullptr);

    const GSpawnFlags flags = static_cast<GSpawnFlags>(
        G_SPAWN_SEARCH_PATH | G_SPAWN_STDOUT_TO_DEV_NULL | G_SPAWN_STDERR_TO_DEV_NULL);
    return g_spawn_async(nullptr, args.data(), nullptr, flags,
                         nullptr, nullptr, nullptr, nullptr) != FALSE;
}

// A sound from the freedesktop sound theme, by event name, or the display's bell
// when no theme player is installed. The bell has to be rung on the UI thread,
// and the version alert is decided on the watcher's.
void PlayThemed(const char* event) {
    if (Launch({ "canberra-gtk-play", "-i", event })) return;
    g_idle_add([](gpointer) -> gboolean {
        if (EnsureGtk()) gdk_display_beep(gdk_display_get_default());
        return G_SOURCE_REMOVE;
    }, nullptr);
}

// Where the combat log lives, when that is a Windows drive seen from WSL: 9p,
// which is how WSL 2 mounts drvfs. The game is then a Windows process, absent
// from /proc, and an empty answer would read as "nobody has it open".
constexpr long kV9fsMagic = 0x01021997;

bool OnWindowsDrive(const fs::path& file) {
    struct statfs info{};
    if (statfs(file.c_str(), &info) != 0) return false;
    return static_cast<long>(info.f_type) == kV9fsMagic;
}

// Whether an open descriptor's flags say it can write. Read from fdinfo, whose
// "flags:" line is the open flags in octal.
bool OpenForWriting(const std::string& fdinfo) {
    std::ifstream in(fdinfo);
    std::string line;
    while (std::getline(in, line)) {
        if (line.rfind("flags:", 0) != 0) continue;
        const unsigned long flags = std::strtoul(line.c_str() + 6, nullptr, 8);
        return (flags & O_ACCMODE) != O_RDONLY;
    }
    // No answer is not "read only": the descriptor exists and names the file.
    return true;
}

std::string Utf8(const fs::path& path) { return path.string(); }

} // namespace

//------------------------------------------------------------------------------
// Process
//------------------------------------------------------------------------------

fs::path ExecutablePath() {
    std::error_code ec;
    const fs::path self = fs::read_symlink("/proc/self/exe", ec);
    if (!ec) return self;

    char resolved[PATH_MAX]{};
    if (realpath("/proc/self/exe", resolved)) return fs::path(resolved);
    return {};
}

// flock on a file in the user's runtime directory - per user, cleared at logout,
// and the place the XDG spec sets aside for exactly this. The lock belongs to the
// open file description, so the kernel drops it however the process exits.
NamedLock::NamedLock(const std::string& name, bool tryOnly) {
    path_ = (fs::path(g_get_user_runtime_dir()) / (name + ".lock")).string();

    fd_ = ::open(path_.c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
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

// "message-new-instant" is the theme's ordinary notification: what the desktop
// already plays when something wants the user's attention.
void PlayDefaultAlert() {
    PlayThemed("message-new-instant");
}

// A file the user chose, through PulseAudio's player - which PipeWire provides
// as well - and failing that the theme player, which also plays files. A file
// either cannot play still makes the noise that was asked for.
void PlaySoundFile(const std::string& path) {
    std::error_code ec;
    if (path.empty() || !fs::exists(path, ec)) {
        PlayDefaultAlert();
        return;
    }
    if (Launch({ "paplay", path })) return;
    if (Launch({ "canberra-gtk-play", "-f", path })) return;
    PlayDefaultAlert();
}

void PlayErrorAlert() {
    PlayThemed("dialog-error");
}

// The one system of the three that can answer this outright: every process's
// open files are listed under /proc, and Wine's are no different. A log the game
// still has open for writing is still being written.
//
// Unknown when /proc cannot be read, and when the log is on a Windows drive under
// WSL, where the game is not a process here at all.
FileBusy FileHeldOpen(const fs::path& file) {
    std::error_code ec;
    const fs::path target = fs::canonical(file, ec);
    if (ec) return FileBusy::Unknown;
    if (OnWindowsDrive(target)) return FileBusy::Unknown;

    const std::string self = std::to_string(::getpid());
    bool readAny = false;
    // Processes come and go while /proc is walked, and stepping past one that
    // has just exited can throw; that is a question not answered, not an error.
    try {
        for (const auto& proc : fs::directory_iterator("/proc", ec)) {
            const std::string pid = proc.path().filename().string();
            if (pid.empty() || pid.find_first_not_of("0123456789") != std::string::npos) continue;
            // This application reads the log too, and that is not what is asked.
            if (pid == self) continue;

            std::error_code fdEc;
            for (const auto& fd : fs::directory_iterator(proc.path() / "fd", fdEc)) {
                readAny = true;
                std::error_code linkEc;
                const fs::path link = fs::read_symlink(fd.path(), linkEc);
                if (linkEc || link != target) continue;
                const std::string info = (proc.path() / "fdinfo" / fd.path().filename()).string();
                if (OpenForWriting(info)) return FileBusy::Yes;
            }
        }
    } catch (const fs::filesystem_error&) {
        return FileBusy::Unknown;
    }
    return readAny ? FileBusy::No : FileBusy::Unknown;
}

void OpenFolder(const fs::path& dir) {
    gchar* uri = g_filename_to_uri(Utf8(dir).c_str(), nullptr, nullptr);
    if (!uri) return;
    g_app_info_launch_default_for_uri(uri, nullptr, nullptr);
    g_free(uri);
}

// See the Windows note: the scheme check is what keeps this from being a general
// "open anything" hole for the sake of two compiled-in addresses.
void OpenUrl(const std::string& url) {
    if (url.rfind("http://", 0) != 0 && url.rfind("https://", 0) != 0) return;
    g_app_info_launch_default_for_uri(url.c_str(), nullptr, nullptr);
}

namespace {

// One message dialog, run to completion. Anything but the first button - closing
// the dialog included - is a no.
bool Ask(const std::string& title, const std::string& text, GtkMessageType type,
         const char* yes, const char* no) {
    if (!EnsureGtk()) return false;

    GtkWidget* dialog = gtk_message_dialog_new(
        nullptr, GTK_DIALOG_MODAL, type, GTK_BUTTONS_NONE, "%s", title.c_str());
    gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog), "%s", text.c_str());
    gtk_dialog_add_buttons(GTK_DIALOG(dialog), no, GTK_RESPONSE_CANCEL,
                           yes, GTK_RESPONSE_ACCEPT, nullptr);
    gtk_window_set_title(GTK_WINDOW(dialog), "CombatSession");
    gtk_window_set_keep_above(GTK_WINDOW(dialog), TRUE);

    const gint response = gtk_dialog_run(GTK_DIALOG(dialog));
    gtk_widget_destroy(dialog);
    while (gtk_events_pending()) gtk_main_iteration();
    return response == GTK_RESPONSE_ACCEPT;
}

// A chooser, through the desktop's own where there is one: GtkFileChooserNative
// uses the portal under Flatpak and on desktops that provide one, and GTK's own
// dialog everywhere else.
std::string Choose(const std::string& title, GtkFileChooserAction action,
                   const fs::path& start, GtkFileFilter* filter) {
    if (!EnsureGtk()) return {};

    GtkFileChooserNative* chooser = gtk_file_chooser_native_new(
        title.c_str(), nullptr, action, "_Select", "_Cancel");
    GtkFileChooser* files = GTK_FILE_CHOOSER(chooser);
    std::error_code ec;
    if (!start.empty() && fs::is_directory(start, ec)) {
        gtk_file_chooser_set_current_folder(files, Utf8(start).c_str());
    }
    if (filter) gtk_file_chooser_add_filter(files, filter);

    std::string picked;
    if (gtk_native_dialog_run(GTK_NATIVE_DIALOG(chooser)) == GTK_RESPONSE_ACCEPT) {
        gchar* name = gtk_file_chooser_get_filename(files);
        if (name) {
            picked = name;
            g_free(name);
        }
    }
    g_object_unref(chooser);
    while (gtk_events_pending()) gtk_main_iteration();
    return picked;
}

} // namespace

bool Confirm(const std::string& title, const std::string& text) {
    return Ask(title, text, GTK_MESSAGE_WARNING, "_Continue", "_Cancel");
}

bool ConfirmAction(const std::string& title, const std::string& text) {
    return Ask(title, text, GTK_MESSAGE_INFO, "_OK", "_Cancel");
}

// Opened where a World of Warcraft install under Wine usually is: ~/Games is
// where Lutris and Heroic put their prefixes, and the home folder otherwise.
std::string PickFolder(const std::string& title) {
    std::error_code ec;
    fs::path start = HomeDir() / "Games";
    if (!fs::is_directory(start, ec)) start = HomeDir();
    return Choose(title, GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER, start, nullptr);
}

std::string PickSoundFile(const std::string& current) {
    if (!EnsureGtk()) return {};

    GtkFileFilter* filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "Sounds");
    gtk_file_filter_add_mime_type(filter, "audio/*");
    for (const char* pattern : { "*.oga", "*.ogg", "*.wav", "*.flac", "*.mp3" }) {
        gtk_file_filter_add_pattern(filter, pattern);
    }

    // The theme's own sounds are the likely choice, and a chooser that opens on
    // the home folder makes the user go and find them.
    fs::path start = "/usr/share/sounds";
    if (!current.empty()) start = fs::path(current).parent_path();
    // The chooser takes ownership of the filter.
    return Choose("Sound to play when a reload is needed",
                  GTK_FILE_CHOOSER_ACTION_OPEN, start, filter);
}

//------------------------------------------------------------------------------
// Login item
//------------------------------------------------------------------------------

namespace {

// Exec= quoting from the Desktop Entry Specification: the whole path in double
// quotes, with the four characters that are special inside them escaped.
std::string QuoteExec(const std::string& path) {
    std::string out = "\"";
    for (const char c : path) {
        if (c == '"' || c == '`' || c == '$' || c == '\\') out += '\\';
        out += c;
    }
    return out + "\"";
}

} // namespace

bool SetStartAtLogin(bool enabled) {
    const fs::path entry = AutostartPath();
    std::error_code ec;

    if (!enabled) {
        fs::remove(entry, ec);
        return true;
    }

    fs::create_directories(entry.parent_path(), ec);
    std::ofstream out(entry, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out << "[Desktop Entry]\n"
        << "Type=Application\n"
        << "Name=CombatSession\n"
        << "Comment=Turns World of Warcraft combat logs into per-session data\n"
        << "Exec=" << QuoteExec(ExecutablePath().string()) << "\n"
        << "Terminal=false\n"
        << "X-GNOME-Autostart-enabled=true\n";
    return out.good();
}

bool GetStartAtLogin() {
    std::error_code ec;
    return fs::exists(AutostartPath(), ec);
}

const char* StartAtLoginLabel() { return "Start at Login"; }

} // namespace cs
