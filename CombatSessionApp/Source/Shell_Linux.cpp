// CombatSession :: Tray, Linux
//
// A status icon, which on Linux means one of two things depending on the
// desktop:
//
//   * A StatusNotifierItem, through Ayatana AppIndicator. KDE Plasma, Xfce,
//     Cinnamon, MATE, Budgie and GNOME with the AppIndicator extension (on by
//     default in Ubuntu) all show these, under X11 and Wayland alike. The menu is
//     exported over D-Bus and drawn by the desktop.
//
//   * GtkStatusIcon, the older XEmbed tray, for a build without AppIndicator. It
//     is deprecated and X11 only, and GNOME shows neither kind without an
//     extension - but it needs nothing beyond GTK.
//
// Like the macOS menu bar item there is no window: the menu carries the settings
// as well (HasWindow is false, so the controller builds the full menu). GTK owns
// the event loop, so Run is gtk_main; and GTK may only be touched on the thread
// running it, so Update marshals through the main context.

#include "Shell.h"

#include "Icon.h"
#include "Platform.h"

#include <gtk/gtk.h>
#ifdef CS_HAVE_APPINDICATOR
#include <libayatana-appindicator/app-indicator.h>
#endif

#include "miniz.h"

#include <atomic>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace cs {
namespace {

// The Linux build is an alpha, and says so wherever it names itself.
constexpr const char* kTitle = "CombatSession (alpha)";

// X11 first, through XWayland on a Wayland desktop. The icon needs it whenever
// there is no status-notifier host: GtkStatusIcon - ours, and AppIndicator's own
// fallback - only exists on X11, and under Wayland it docks nowhere.
bool EnsureGtk() {
    static bool ready = false;
    if (!ready) {
        gdk_set_allowed_backends("x11,*");
        ready = gtk_init_check(nullptr, nullptr);
    }
    return ready;
}

// Menu labels mark their accelerator with '&', as Windows does; GTK marks it with
// '_'. A literal underscore has to be doubled so it is not taken for one.
std::string Mnemonic(const std::string& label) {
    std::string out;
    for (size_t i = 0; i < label.size(); ++i) {
        const char c = label[i];
        if (c == '&') {
            if (i + 1 < label.size() && label[i + 1] == '&') { out += '&'; ++i; }
            else out += '_';
        } else if (c == '_') {
            out += "__";
        } else {
            out += c;
        }
    }
    return out;
}

// The renderer's 0xAARRGGBB words as R, G, B, A bytes, which is what both a PNG
// and a GdkPixbuf want.
std::vector<unsigned char> Rgba(uint32_t accent) {
    const std::vector<uint32_t> pixels = RenderTrayIcon(accent);
    std::vector<unsigned char> out(pixels.size() * 4);
    for (size_t i = 0; i < pixels.size(); ++i) {
        const uint32_t pixel = pixels[i];
        out[i * 4 + 0] = static_cast<unsigned char>((pixel >> 16) & 0xFF);
        out[i * 4 + 1] = static_cast<unsigned char>((pixel >>  8) & 0xFF);
        out[i * 4 + 2] = static_cast<unsigned char>( pixel        & 0xFF);
        out[i * 4 + 3] = static_cast<unsigned char>((pixel >> 24) & 0xFF);
    }
    return out;
}

// In TrayState order: Idle, Working, NeedsReload.
constexpr uint32_t kAccents[] = { kIdleGreen, kWorkingAmber, kReloadRed };

#ifdef CS_HAVE_APPINDICATOR
constexpr const char* kIconNames[] = {
    "combatsession-idle", "combatsession-working", "combatsession-reload",
};

// An AppIndicator is drawn by another process, which can only be told an icon's
// name and a folder to find it in - so the three icons are written out as PNGs,
// into the user's runtime directory, where they are cleared at logout.
fs::path WriteIcons() {
    const fs::path dir = fs::path(g_get_user_runtime_dir()) / "combatsession";
    std::error_code ec;
    fs::create_directories(dir, ec);
    for (size_t i = 0; i < 3; ++i) {
        const std::vector<unsigned char> rgba = Rgba(kAccents[i]);
        size_t size = 0;
        void* png = tdefl_write_image_to_png_file_in_memory(
            rgba.data(), kIconSize, kIconSize, 4, &size);
        if (!png) continue;
        std::ofstream out(dir / (std::string(kIconNames[i]) + ".png"),
                          std::ios::binary | std::ios::trunc);
        out.write(static_cast<const char*>(png), static_cast<std::streamsize>(size));
        mz_free(png);
    }
    return dir;
}
#endif

class LinuxTray : public ShellHost {
public:
    explicit LinuxTray(AppController& controller) : controller_(controller) {}
    ~LinuxTray() override;

    bool Create();

    void Update(TrayState state, const std::string& tooltip) override;
    int  Run() override;
    void Quit() override;
    bool HasWindow() const override { return false; }

private:
    struct Pending {
        LinuxTray*  tray;
        TrayState   state;
        std::string tooltip;
    };

    void Apply(TrayState state, const std::string& tooltip);
    // Rebuilds the menu when what it would show has changed. See Create.
    void Refresh();
    void Fill(GtkWidget* menu);
    std::string Signature() const;

    static void OnItem(GtkMenuItem* item, gpointer self);

    AppController&    controller_;
    GtkWidget*        menu_ = nullptr;
    std::string       shown_;
    guint             timer_ = 0;
    std::atomic<bool> quitting_{ false };

#ifdef CS_HAVE_APPINDICATOR
    AppIndicator*     indicator_ = nullptr;
#else
    GtkStatusIcon*    status_ = nullptr;
    GdkPixbuf*        pixbufs_[3] = {};
#endif
};

void LinuxTray::OnItem(GtkMenuItem* item, gpointer self) {
    auto* tray = static_cast<LinuxTray*>(self);
    const int id = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(item), "cs-command"));
    tray->controller_.OnCommand(id);
    // A command usually changes what the menu says - a setting ticked, a pass
    // started - and the menu should say so the next time it is opened.
    tray->Refresh();
}

// What BuildMenu would show, as text, to tell whether a rebuild would change
// anything. Rebuilding an exported menu re-sends it to the desktop, and doing
// that every few seconds for nothing would make an open menu flicker.
std::string LinuxTray::Signature() const {
    std::string out;
    for (const MenuItem& entry : controller_.BuildMenu(false)) {
        out += std::to_string(entry.id) + '|' + entry.label + '|'
             + (entry.enabled ? '1' : '0') + (entry.checked ? '1' : '0')
             + (entry.separator ? '1' : '0') + '\n';
    }
    return out;
}

void LinuxTray::Fill(GtkWidget* menu) {
    for (const MenuItem& entry : controller_.BuildMenu(false)) {
        GtkWidget* item;
        if (entry.separator) {
            item = gtk_separator_menu_item_new();
        } else if (entry.checked) {
            item = gtk_check_menu_item_new_with_mnemonic(Mnemonic(entry.label).c_str());
            // Before the handler is connected: setting it emits "toggled", and
            // only a click should be a command.
            gtk_check_menu_item_set_active(GTK_CHECK_MENU_ITEM(item), TRUE);
        } else {
            item = gtk_menu_item_new_with_mnemonic(Mnemonic(entry.label).c_str());
        }
        if (!entry.separator) {
            gtk_widget_set_sensitive(item, entry.enabled ? TRUE : FALSE);
            g_object_set_data(G_OBJECT(item), "cs-command", GINT_TO_POINTER(entry.id));
            g_signal_connect(item, "activate", G_CALLBACK(&LinuxTray::OnItem), this);
        }
        gtk_menu_shell_append(GTK_MENU_SHELL(menu), item);
    }
    gtk_widget_show_all(menu);
}

// A menu exported to the desktop is not opened by this process, so there is no
// moment to build it in as the Windows and macOS hosts do. It is rebuilt instead
// whenever anything could have changed it - an update from the watcher, a
// command - and on a short timer for what neither of those announces, such as
// the addon saving a new version. Each time only if it would read differently.
void LinuxTray::Refresh() {
    const std::string signature = Signature();
    if (signature == shown_ && menu_) return;
    shown_ = signature;

    // A reference of our own, so the old menu is still alive to be destroyed
    // here after the indicator has let go of it on being handed the new one.
    GtkWidget* menu = gtk_menu_new();
    g_object_ref_sink(menu);
    Fill(menu);
#ifdef CS_HAVE_APPINDICATOR
    app_indicator_set_menu(indicator_, GTK_MENU(menu));
#endif
    if (menu_) {
        gtk_widget_destroy(menu_);
        g_object_unref(menu_);
    }
    menu_ = menu;
}

bool LinuxTray::Create() {
    if (!EnsureGtk()) return false;

#ifdef CS_HAVE_APPINDICATOR
    const fs::path icons = WriteIcons();
    indicator_ = app_indicator_new_with_path(
        "combatsession", kIconNames[0],
        APP_INDICATOR_CATEGORY_APPLICATION_STATUS, icons.c_str());
    if (!indicator_) return false;
    app_indicator_set_title(indicator_, kTitle);
    app_indicator_set_status(indicator_, APP_INDICATOR_STATUS_ACTIVE);
#else
    for (size_t i = 0; i < 3; ++i) {
        const std::vector<unsigned char> rgba = Rgba(kAccents[i]);
        GdkPixbuf* pixbuf = gdk_pixbuf_new_from_data(
            rgba.data(), GDK_COLORSPACE_RGB, TRUE, 8, kIconSize, kIconSize,
            kIconSize * 4, nullptr, nullptr);
        // A copy, so the pixbuf owns its pixels rather than pointing into the
        // vector about to go out of scope.
        pixbufs_[i] = pixbuf ? gdk_pixbuf_copy(pixbuf) : nullptr;
        if (pixbuf) g_object_unref(pixbuf);
    }
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    status_ = gtk_status_icon_new_from_pixbuf(pixbufs_[0]);
    if (!status_) return false;
    gtk_status_icon_set_tooltip_text(status_, (std::string(kTitle) + " - starting").c_str());
    // Either button opens the menu: there is no window for a left click to show.
    auto popup = +[](GtkStatusIcon*, gpointer self) {
        auto* tray = static_cast<LinuxTray*>(self);
        tray->Refresh();
        gtk_menu_popup_at_pointer(GTK_MENU(tray->menu_), nullptr);
    };
    g_signal_connect(status_, "activate", G_CALLBACK(popup), this);
    g_signal_connect(status_, "popup-menu", G_CALLBACK(+[](GtkStatusIcon* icon, guint, guint,
                                                           gpointer self) {
        auto* tray = static_cast<LinuxTray*>(self);
        tray->Refresh();
        gtk_menu_popup_at_pointer(GTK_MENU(tray->menu_), nullptr);
        (void)icon;
    }), this);
    G_GNUC_END_IGNORE_DEPRECATIONS
#endif

    Refresh();
    timer_ = g_timeout_add_seconds(3, [](gpointer self) -> gboolean {
        static_cast<LinuxTray*>(self)->Refresh();
        return G_SOURCE_CONTINUE;
    }, this);
    return true;
}

void LinuxTray::Apply(TrayState state, const std::string& tooltip) {
    const int index = static_cast<int>(state);
#ifdef CS_HAVE_APPINDICATOR
    // Hosts that show a tooltip take it from the title; the status line at the top
    // of the menu says the same thing for the ones that do not.
    app_indicator_set_icon_full(indicator_, kIconNames[index], tooltip.c_str());
    app_indicator_set_title(indicator_, (std::string(kTitle) + " - " + tooltip).c_str());
#else
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    if (pixbufs_[index]) gtk_status_icon_set_from_pixbuf(status_, pixbufs_[index]);
    gtk_status_icon_set_tooltip_text(status_, (std::string(kTitle) + " - " + tooltip).c_str());
    G_GNUC_END_IGNORE_DEPRECATIONS
#endif
    Refresh();
}

// Called from the watcher thread. The state and text are copied here and applied
// on the GTK thread, which is the only one allowed to touch the icon.
void LinuxTray::Update(TrayState state, const std::string& tooltip) {
    if (quitting_) return;
    auto* pending = new Pending{ this, state, tooltip };
    g_idle_add([](gpointer data) -> gboolean {
        auto* p = static_cast<Pending*>(data);
        if (!p->tray->quitting_) p->tray->Apply(p->state, p->tooltip);
        delete p;
        return G_SOURCE_REMOVE;
    }, pending);
}

int LinuxTray::Run() {
    gtk_main();
    return 0;
}

void LinuxTray::Quit() {
    quitting_ = true;
    g_idle_add([](gpointer) -> gboolean {
        gtk_main_quit();
        return G_SOURCE_REMOVE;
    }, nullptr);
}

LinuxTray::~LinuxTray() {
    if (timer_) g_source_remove(timer_);
#ifdef CS_HAVE_APPINDICATOR
    if (indicator_) {
        app_indicator_set_status(indicator_, APP_INDICATOR_STATUS_PASSIVE);
        g_object_unref(indicator_);
    }
#else
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    if (status_) g_object_unref(status_);
    G_GNUC_END_IGNORE_DEPRECATIONS
    for (GdkPixbuf* pixbuf : pixbufs_) if (pixbuf) g_object_unref(pixbuf);
#endif
    if (menu_) {
        gtk_widget_destroy(menu_);
        g_object_unref(menu_);
    }
}

} // namespace

std::unique_ptr<ShellHost> CreateShell(AppController& controller) {
    auto tray = std::make_unique<LinuxTray>(controller);
    if (!tray->Create()) return nullptr;
    return tray;
}

// The first-run question, Linux. As on macOS: the folder chooser asks exactly
// the question, and a wrong answer is explained and asked again rather than kept.
bool PromptForWowFolder(std::string& path) {
    for (;;) {
        const std::string picked = PickFolder(
            "Select the World of Warcraft folder "
            "(the one containing Logs and Interface)");
        if (picked.empty()) return false;          // cancelled

        if (LooksLikeFlavor(picked)) {
            path = picked;
            return true;
        }

        if (!EnsureGtk()) return false;
        GtkWidget* dialog = gtk_message_dialog_new(
            nullptr, GTK_DIALOG_MODAL, GTK_MESSAGE_WARNING, GTK_BUTTONS_OK,
            "That is not a World of Warcraft folder");
        gtk_message_dialog_format_secondary_text(GTK_MESSAGE_DIALOG(dialog),
            "The folder must contain both Logs and Interface/AddOns. Choose the "
            "flavor folder itself, usually named _retail_ - under Wine it is inside "
            "the prefix, in drive_c/Program Files (x86)/World of Warcraft.");
        gtk_dialog_run(GTK_DIALOG(dialog));
        gtk_widget_destroy(dialog);
        while (gtk_events_pending()) gtk_main_iteration();
    }
}

} // namespace cs
