// CombatSession :: Shell, Windows
//
// An ordinary desktop application: one window that says what the program is,
// shows every setting it has, and reports what it is doing, plus a notification
// icon carrying the same state as a colour.
//
// It is deliberately ordinary. An earlier version was a console program that
// hid its own console at startup so it could sit in the tray - which worked,
// and which is also indistinguishable from what a program does when it does not
// want to be seen. Nothing here is hidden: the window is shown on first run,
// every option is visible and labelled, and the only thing that outlives the
// session is a shortcut the user can see in their Startup folder.
//
// The notification icon is not always present. It appears when the window hides
// into it and goes away when the window comes back, because that is exactly the
// span over which it is the only way to reach the application.

#include "Shell.h"

#include "Icon.h"
#include "Version.h"
#include "Platform.h"

#include <windows.h>
#include <shellapi.h>

#include <atomic>
#include <cstring>
#include <mutex>
#include <string>

namespace cs {
namespace {

constexpr UINT WM_TRAY   = WM_APP + 1;
constexpr UINT WM_STATUS = WM_APP + 2;
constexpr UINT WM_QUITAPP = WM_APP + 3;

// Widening a macro string needs the extra level of expansion.
#define _CSW2(x) L##x
#define _CSW(x)  _CSW2(x)

// Controls that are only ever read, never commanded.
enum ControlId {
    kPathText = 2000,
    kPathHint,
    kStartup,
    kStartMinimized,
    kArchive,
    kMinimize,
    kPollSeconds,
    kSoundOn,
    kSoundText,
    kRepeatOnce,
    kRepeatEvery,
    kRepeatSeconds,
    kAlertNew,
    kStatusText,
    kVersionBanner,
    kAddonStatus,
    kAppStatus,
};

// The icon alternates on a mismatch, which needs something to tick.
constexpr UINT_PTR kAlarmTimer = 1;

//------------------------------------------------------------------------------
// Layout
//
// Fixed 96-dpi coordinates. The process declares no dpi awareness, so Windows
// scales the whole window on a high-dpi display: slightly soft, laid out
// correctly, and none of the per-monitor arithmetic that is the usual source of
// controls landing on top of each other.
//------------------------------------------------------------------------------

constexpr int kWidth   = 560;
constexpr int kMargin  = 20;
constexpr int kRight   = kWidth - kMargin;
constexpr int kRowH    = 24;
constexpr int kButtonH = 26;

std::wstring Widen(const std::string& text) {
    if (text.empty()) return {};
    const int needed = MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                           static_cast<int>(text.size()),
                                           nullptr, 0);
    if (needed <= 0) return {};
    std::wstring out(static_cast<size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.c_str(), static_cast<int>(text.size()),
                        out.data(), needed);
    return out;
}

HFONT MakeFont(int height, int weight) {
    return CreateFontW(-height, 0, 0, 0, weight, FALSE, FALSE, FALSE,
                       DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                       CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                       L"Segoe UI");
}

// The rendered pixels are already the layout a top-down 32bpp DIB section
// wants, so this is a copy plus the 1bpp mask Windows still asks for.
HICON MakeIcon(uint32_t accent) {
    const std::vector<uint32_t> pixels = RenderTrayIcon(accent);

    BITMAPINFO info{};
    info.bmiHeader.biSize        = sizeof info.bmiHeader;
    info.bmiHeader.biWidth       = kIconSize;
    info.bmiHeader.biHeight      = -kIconSize;   // negative: top-down
    info.bmiHeader.biPlanes      = 1;
    info.bmiHeader.biBitCount    = 32;
    info.bmiHeader.biCompression = BI_RGB;

    void* bits = nullptr;
    HBITMAP color = CreateDIBSection(nullptr, &info, DIB_RGB_COLORS, &bits,
                                     nullptr, 0);
    if (!color) return nullptr;

    std::memcpy(bits, pixels.data(), pixels.size() * sizeof(uint32_t));

    // One set bit per transparent pixel, derived from the alpha channel rather
    // than restating which pixels the renderer decided to clear.
    uint8_t mask[kIconSize * 4]{};
    for (int y = 0; y < kIconSize; ++y) {
        for (int x = 0; x < kIconSize; ++x) {
            if ((pixels[static_cast<size_t>(y) * kIconSize + x] & 0xFF000000u) == 0) {
                mask[y * 4 + (x / 8)] |= static_cast<uint8_t>(0x80 >> (x % 8));
            }
        }
    }
    HBITMAP maskBitmap = CreateBitmap(kIconSize, kIconSize, 1, 1, mask);

    ICONINFO icon{};
    icon.fIcon    = TRUE;
    icon.hbmMask  = maskBitmap;
    icon.hbmColor = color;
    HICON handle = CreateIconIndirect(&icon);

    DeleteObject(color);
    DeleteObject(maskBitmap);
    return handle;
}

//------------------------------------------------------------------------------
// First run
//
// Asked before anything else, because without a folder the application has
// nothing to watch and will sit there doing nothing. Two buttons and no default
// path: guessing at where a game is installed means probing the filesystem for
// other people's software, which is not a thing this program should do on its
// own initiative.
//------------------------------------------------------------------------------

struct FirstRun {
    std::string path;      // in: current setting. out: what the user chose.
    bool        accepted = false;
};

constexpr int kFirstRunSetPath = 100;
constexpr int kFirstRunCancel  = 101;

LRESULT CALLBACK FirstRunProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    auto* state = reinterpret_cast<FirstRun*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));

    switch (msg) {
    case WM_COMMAND:
        switch (LOWORD(wp)) {
        case kFirstRunSetPath: {
            const std::string picked = PickFolder(
                "Select the World of Warcraft folder "
                "(the one containing Logs and Interface)");
            if (picked.empty()) return 0;

            if (!LooksLikeFlavor(picked)) {
                MessageBoxW(hwnd,
                    L"That folder does not contain both Logs and "
                    L"Interface\\AddOns.\n\nChoose the flavor folder itself, "
                    L"usually named _retail_.",
                    L"CombatSession", MB_ICONWARNING);
                return 0;
            }

            if (state) {
                state->path = picked;
                state->accepted = true;
            }
            DestroyWindow(hwnd);
            return 0;
        }

        case kFirstRunCancel:
        case IDCANCEL:
            DestroyWindow(hwnd);
            return 0;
        }
        return 0;

    case WM_CTLCOLORSTATIC:
        // The path line, red while there is nothing set.
        if (GetDlgCtrlID(reinterpret_cast<HWND>(lp)) == kPathText) {
            auto dc = reinterpret_cast<HDC>(wp);
            const bool set = state && !state->path.empty();
            SetTextColor(dc, set ? RGB(0x20, 0x20, 0x20) : RGB(0xC0, 0x20, 0x20));
            SetBkMode(dc, TRANSPARENT);
            return reinterpret_cast<LRESULT>(GetSysColorBrush(COLOR_3DFACE));
        }
        break;

    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// Runs its own message loop. Called before the main window exists, so there is
// no parent to disable and nothing else pumping messages.
bool AskForWowFolder(std::string& path) {
    HFONT font = MakeFont(15, FW_NORMAL);
    HICON icon = MakeIcon(kIdleGreen);

    struct Cleanup {
        HFONT font; HICON icon;
        ~Cleanup() { if (font) DeleteObject(font); if (icon) DestroyIcon(icon); }
    } cleanup{ font, icon };

    static const wchar_t* kClass = L"CombatSessionFirstRun";

    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof wc;
    wc.lpfnWndProc   = FirstRunProc;
    wc.hInstance     = GetModuleHandleW(nullptr);
    wc.hCursor       = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = GetSysColorBrush(COLOR_3DFACE);
    wc.lpszClassName = kClass;
    wc.hIcon         = icon;
    RegisterClassExW(&wc);

    FirstRun state;
    state.path = path;

    constexpr int w = 460, h = 262;
    const int x = (GetSystemMetrics(SM_CXSCREEN) - w) / 2;
    const int y = (GetSystemMetrics(SM_CYSCREEN) - h) / 2;

    HWND hwnd = CreateWindowExW(
        WS_EX_DLGMODALFRAME, kClass, L"CombatSession - first run",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU, x, y, w, h,
        nullptr, nullptr, wc.hInstance, nullptr);
    if (!hwnd) return false;

    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(&state));

    RECT client{};
    GetClientRect(hwnd, &client);
    const int cw = client.right;

    auto Add = [&](const wchar_t* cls, const wchar_t* text, DWORD style,
                   int cx, int cy, int cwid, int chei, int id) {
        HWND control = CreateWindowExW(
            0, cls, text, WS_CHILD | WS_VISIBLE | style,
            cx, cy, cwid, chei, hwnd,
            reinterpret_cast<HMENU>(static_cast<UINT_PTR>(id)),
            wc.hInstance, nullptr);
        SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(font), TRUE);
        return control;
    };

    Add(L"STATIC",
        L"CombatSession needs to know where World of Warcraft is installed "
        L"before it can do anything.\n\n"
        L"Choose the flavor folder - the one containing Logs and Interface, "
        L"usually named _retail_.",
        0, 16, 14, cw - 32, 104, -1);

    Add(L"STATIC", state.path.empty() ? L"No path set"
                                      : Widen(state.path).c_str(),
        SS_PATHELLIPSIS, 16, 126, cw - 32, 20, kPathText);

    Add(L"BUTTON", L"Set Path", BS_DEFPUSHBUTTON,
        cw - 16 - 220, 164, 105, kButtonH, kFirstRunSetPath);
    Add(L"BUTTON", L"Cancel", 0,
        cw - 16 - 105, 164, 105, kButtonH, kFirstRunCancel);

    ShowWindow(hwnd, SW_SHOW);
    SetForegroundWindow(hwnd);

    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        if (!IsDialogMessageW(hwnd, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    if (state.accepted) path = state.path;
    return state.accepted;
}

//------------------------------------------------------------------------------
// The application window
//------------------------------------------------------------------------------

class WindowsShell : public ShellHost {
public:
    explicit WindowsShell(AppController& controller) : controller_(controller) {}
    ~WindowsShell() override;

    bool Create();

    void Update(TrayState state, const std::string& tooltip) override;
    int  Run() override;
    void Quit() override;
    bool HasWindow() const override { return true; }

private:
    static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
    LRESULT Handle(HWND, UINT, WPARAM, LPARAM);

    void BuildControls();
    void ReadControls();      // controls -> config
    void WriteControls();     // config -> controls
    void RefreshIcon();
    void ShowMenu();
    void RestoreWindow();
    void ShowTrayIcon(bool shown);
    void HideToTray();

    HWND Add(const wchar_t* cls, const wchar_t* text, DWORD style,
             int x, int y, int w, int h, int id, HFONT font = nullptr);
    HWND Item(int id) const { return GetDlgItem(window_, id); }

    AppController& controller_;

    HWND  window_ = nullptr;
    HFONT fontUI_ = nullptr;
    HFONT fontTitle_ = nullptr;
    HFONT fontSub_ = nullptr;
    HFONT fontSection_ = nullptr;

    NOTIFYICONDATAW icon_{};
    // The notification icon exists only while the window is hidden in it, which
    // is the only time it is the sole way back to the application. With the
    // window on the taskbar its button carries the same colour, and two copies
    // of one indicator is just clutter.
    bool trayShown_ = false;
    // Said once per run, the first time the window disappears into the icon.
    bool toldAboutTray_ = false;
    HICON icons_[3]{};

    // The mismatch alternation: which of the two colours is showing, and
    // whether the timer driving it is running. A separate indicator from the
    // state colour because it means something the state cannot - the state is
    // about the queue, and the queue is fine.
    bool alarmPhase_   = false;
    bool alarmRunning_ = false;

    std::atomic<TrayState> state_{ TrayState::Idle };

    std::mutex  tipMutex_;
    std::string tip_ = "starting";
};

WindowsShell* g_shell = nullptr;

LRESULT CALLBACK WindowsShell::WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (g_shell) return g_shell->Handle(hwnd, msg, wp, lp);
    return DefWindowProcW(hwnd, msg, wp, lp);
}

HWND WindowsShell::Add(const wchar_t* cls, const wchar_t* text, DWORD style,
                       int x, int y, int w, int h, int id, HFONT font) {
    HWND control = CreateWindowExW(
        0, cls, text, WS_CHILD | WS_VISIBLE | style, x, y, w, h, window_,
        reinterpret_cast<HMENU>(static_cast<UINT_PTR>(id)),
        GetModuleHandleW(nullptr), nullptr);
    SendMessageW(control, WM_SETFONT,
                 reinterpret_cast<WPARAM>(font ? font : fontUI_), TRUE);
    return control;
}

void WindowsShell::BuildControls() {
    int y = 18;

    Add(L"STATIC", L"CombatSession", 0, kMargin, y, 320, 38, -1, fontTitle_);
    y += 38;
    Add(L"STATIC", L"Created by McDakson", 0, kMargin, y, 320, 20, -1, fontSub_);

    Add(L"STATIC", L"v" _CSW(CS_VERSION_SHORT), SS_RIGHT,
        kRight - 120, 30, 120, 20, -1, fontSub_);

    // The mismatch notice, directly under the name and above everything else,
    // because it is the one thing on this window that means the rest of it is
    // not currently doing its job.
    //
    // The space is reserved whether or not there is anything to say. Showing
    // and hiding it would move every control below it by twenty pixels the
    // moment the addon saved, which is a window rearranging itself under the
    // user's cursor to tell them about a version number.
    y += 24;
    Add(L"STATIC", L"", 0, kMargin, y, kRight - kMargin, 36, kVersionBanner,
        fontSection_);

    y += 40;
    Add(L"STATIC", L"", SS_ETCHEDHORZ, kMargin, y, kRight - kMargin, 2, -1);

    //--- folder --------------------------------------------------------------
    y += 14;
    Add(L"STATIC", L"World of Warcraft folder", 0,
        kMargin, y, 300, 20, -1, fontSection_);
    y += 24;
    Add(L"STATIC", L"", SS_PATHELLIPSIS, kMargin, y + 4, 380, 20, kPathText);
    Add(L"BUTTON", L"Set Path...", 0, kRight - 120, y, 120, kButtonH,
        kCmdSetWowPath);
    y += 30;
    Add(L"STATIC", L"", 0, kMargin, y, kRight - kMargin, 18, kPathHint, fontSub_);

    //--- options -------------------------------------------------------------
    y += 26;
    Add(L"STATIC", L"", SS_ETCHEDHORZ, kMargin, y, kRight - kMargin, 2, -1);
    y += 14;
    Add(L"STATIC", L"Options", 0, kMargin, y, 300, 20, -1, fontSection_);

    y += 24;
    Add(L"BUTTON", L"Start with Windows", BS_AUTOCHECKBOX,
        kMargin, y, 170, kRowH, kStartup);
    Add(L"BUTTON", L"Start minimized", BS_AUTOCHECKBOX,
        kMargin + 178, y, kRight - kMargin - 178, kRowH, kStartMinimized);
    y += kRowH;
    Add(L"BUTTON", L"Keep a raw archive of processed sessions",
        BS_AUTOCHECKBOX, kMargin, y, kRight - kMargin, kRowH, kArchive);
    y += kRowH;
    Add(L"BUTTON", L"Minimize to the notification area",
        BS_AUTOCHECKBOX, kMargin, y, kRight - kMargin, kRowH, kMinimize);
    y += kRowH + 4;
    Add(L"STATIC", L"Check the Logs folder every", 0,
        kMargin, y + 4, 180, 20, -1);
    Add(L"EDIT", L"", ES_NUMBER | WS_BORDER,
        kMargin + 186, y + 1, 48, 21, kPollSeconds);
    Add(L"STATIC", L"seconds", 0, kMargin + 240, y + 4, 70, 20, -1);

    //--- alert ---------------------------------------------------------------
    y += kRowH + 10;
    Add(L"STATIC", L"", SS_ETCHEDHORZ, kMargin, y, kRight - kMargin, 2, -1);
    y += 14;
    Add(L"STATIC", L"Reload alert", 0, kMargin, y, 300, 20, -1, fontSection_);

    y += 24;
    Add(L"BUTTON", L"Play a sound when a reload is needed", BS_AUTOCHECKBOX,
        kMargin, y, kRight - kMargin, kRowH, kSoundOn);

    y += kRowH + 2;
    Add(L"STATIC", L"Sound:", 0, kMargin + 20, y + 4, 50, 20, -1);
    Add(L"STATIC", L"", SS_PATHELLIPSIS, kMargin + 72, y + 4, 200, 20, kSoundText);
    Add(L"BUTTON", L"Choose...", 0, kRight - 200, y, 95, kButtonH, kCmdSetSound);
    Add(L"BUTTON", L"Use Default", 0, kRight - 100, y, 100, kButtonH,
        kCmdUseDefaultSound);

    y += kButtonH + 6;
    Add(L"BUTTON", L"Play once", BS_AUTORADIOBUTTON | WS_GROUP,
        kMargin + 20, y, 200, kRowH, kRepeatOnce);
    y += kRowH;
    Add(L"BUTTON", L"Repeat every", BS_AUTORADIOBUTTON,
        kMargin + 20, y, 120, kRowH, kRepeatEvery);
    Add(L"EDIT", L"", ES_NUMBER | WS_BORDER,
        kMargin + 146, y + 1, 48, 21, kRepeatSeconds);
    Add(L"STATIC", L"seconds", 0, kMargin + 200, y + 4, 70, 20, -1);

    // Not part of the once-or-repeat group: it is a separate trigger, not a
    // third way of repeating the first one. Placed under the group, and after
    // the WS_GROUP radios, so it is not swallowed into their tab stop.
    y += kRowH + 4;
    Add(L"BUTTON", L"Play again for each new session waiting to load",
        BS_AUTOCHECKBOX | WS_GROUP, kMargin + 20, y, kRight - kMargin - 20, kRowH,
        kAlertNew);

    //--- status and actions --------------------------------------------------
    y += kRowH + 12;
    Add(L"STATIC", L"", SS_ETCHEDHORZ, kMargin, y, kRight - kMargin, 2, -1);
    y += 12;
    Add(L"STATIC", L"", SS_PATHELLIPSIS, kMargin, y, kRight - kMargin, 20,
        kStatusText);

    y += 28;
    Add(L"BUTTON", L"Process Now", 0, kMargin, y, 110, kButtonH, kCmdProcessNow);
    Add(L"BUTTON", L"Data Folder", 0, kMargin + 116, y, 100, kButtonH,
        kCmdOpenData);
    Add(L"BUTTON", L"Logs Folder", 0, kMargin + 222, y, 100, kButtonH,
        kCmdOpenLogs);
    Add(L"BUTTON", L"Rebuild All Data...", 0, kRight - 140, y, 140, kButtonH,
        kCmdRebuildAll);

    //--- versions ------------------------------------------------------------
    //
    // Two halves side by side, each with the line that says where it stands
    // above the button that goes and gets it. Both are always present and both
    // always work: which one is behind is a fact about this moment, and a
    // button that appears only when something is wrong is a button nobody can
    // find when they want to check that nothing is.
    y += kButtonH + 12;
    Add(L"STATIC", L"", SS_ETCHEDHORZ, kMargin, y, kRight - kMargin, 2, -1);

    const int half = (kRight - kMargin - 16) / 2;

    y += 12;
    Add(L"STATIC", L"", 0, kMargin, y, half, 20, kAddonStatus);
    Add(L"STATIC", L"", 0, kMargin + half + 16, y, half, 20, kAppStatus);

    y += 22;
    Add(L"BUTTON", L"Get the Addon (CurseForge)", 0,
        kMargin, y, half, kButtonH, kCmdAddonPage);
    Add(L"BUTTON", L"Get the App (GitHub)", 0,
        kMargin + half + 16, y, half, kButtonH, kCmdAppPage);
}

void WindowsShell::WriteControls() {
    const Config& config = controller_.Settings();

    const bool valid = config.IsValid();
    SetDlgItemTextW(window_, kPathText,
                    config.wowPath.empty() ? L"No path set"
                                           : Widen(config.wowPath).c_str());
    SetDlgItemTextW(window_, kPathHint,
        valid ? L""
              : L"Nothing is processed until a valid folder is set.");

    CheckDlgButton(window_, kStartup,  config.startAtLogin   ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(window_, kStartMinimized,
                   config.startMinimized ? BST_CHECKED : BST_UNCHECKED);

    CheckDlgButton(window_, kArchive,  config.archiveRaw     ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(window_, kMinimize, config.minimizeToTray ? BST_CHECKED : BST_UNCHECKED);
    CheckDlgButton(window_, kSoundOn,  config.soundEnabled   ? BST_CHECKED : BST_UNCHECKED);

    SetDlgItemTextW(window_, kSoundText,
                    config.reloadSound.empty() ? L"System Default"
                                               : Widen(config.reloadSound).c_str());

    const bool every = config.alertRepeat == AlertRepeat::Every;
    CheckDlgButton(window_, kRepeatOnce,  every ? BST_UNCHECKED : BST_CHECKED);
    CheckDlgButton(window_, kRepeatEvery, every ? BST_CHECKED : BST_UNCHECKED);
    SetDlgItemInt(window_, kPollSeconds,
                  static_cast<UINT>(config.pollSeconds), FALSE);
    SetDlgItemInt(window_, kRepeatSeconds,
                  static_cast<UINT>(config.repeatSeconds), FALSE);
    CheckDlgButton(window_, kAlertNew,
                   config.alertOnNewSessions ? BST_CHECKED : BST_UNCHECKED);

    // The alert controls mean nothing while the alert is off, and a control
    // that does nothing should not look like it does. Spelled as an array
    // because the ids come from two different enumerations.
    static const int kAlertControls[] = {
        kSoundText, kCmdSetSound, kCmdUseDefaultSound,
        kRepeatOnce, kRepeatEvery, kRepeatSeconds, kAlertNew,
    };
    for (int id : kAlertControls) {
        EnableWindow(Item(id), config.soundEnabled);
    }
    EnableWindow(Item(kRepeatSeconds), config.soundEnabled && every);

    EnableWindow(Item(kCmdProcessNow), valid && !controller_.Busy());
    EnableWindow(Item(kCmdRebuildAll), valid && !controller_.Busy());
    EnableWindow(Item(kCmdOpenData), valid);
    EnableWindow(Item(kCmdOpenLogs), valid);

    const VersionStatus versions = controller_.Versions();
    SetDlgItemTextW(window_, kVersionBanner, Widen(versions.banner).c_str());
    SetDlgItemTextW(window_, kAddonStatus,   Widen(versions.addonLine).c_str());
    SetDlgItemTextW(window_, kAppStatus,     Widen(versions.appLine).c_str());

    // WM_CTLCOLORSTATIC decides the colours, and it is only asked when a
    // control is about to be drawn - so a label whose text has not changed
    // keeps the colour it had. Invalidated by hand for that reason.
    for (int id : { kVersionBanner, kAddonStatus, kAppStatus }) {
        InvalidateRect(Item(id), nullptr, TRUE);
    }
}

void WindowsShell::ReadControls() {
    Config& config = controller_.Settings();

    config.startAtLogin   = IsDlgButtonChecked(window_, kStartup)  == BST_CHECKED;
    config.startMinimized = IsDlgButtonChecked(window_, kStartMinimized) == BST_CHECKED;
    config.archiveRaw     = IsDlgButtonChecked(window_, kArchive)  == BST_CHECKED;
    config.minimizeToTray = IsDlgButtonChecked(window_, kMinimize) == BST_CHECKED;
    config.soundEnabled   = IsDlgButtonChecked(window_, kSoundOn)  == BST_CHECKED;
    config.alertRepeat    = IsDlgButtonChecked(window_, kRepeatEvery) == BST_CHECKED
                          ? AlertRepeat::Every : AlertRepeat::Once;
    config.alertOnNewSessions = IsDlgButtonChecked(window_, kAlertNew) == BST_CHECKED;

    // Clamped rather than rejected: someone mid-edit has an empty or silly box
    // for a moment, and that should not be an error dialog. A value out of
    // range is simply not taken, and WriteControls puts the old one back.
    auto ReadNumber = [this](int id, int& target, int low, int high) {
        BOOL ok = FALSE;
        const UINT value = GetDlgItemInt(window_, id, &ok, FALSE);
        if (ok && value >= static_cast<UINT>(low)
               && value <= static_cast<UINT>(high)) {
            target = static_cast<int>(value);
        }
    };

    ReadNumber(kPollSeconds,   config.pollSeconds,   1, 300);
    ReadNumber(kRepeatSeconds, config.repeatSeconds, 5, 3600);
}

//------------------------------------------------------------------------------

void WindowsShell::Update(TrayState state, const std::string& tooltip) {
    {
        std::lock_guard<std::mutex> lock(tipMutex_);
        tip_ = tooltip;
    }
    state_.store(state);
    if (window_) PostMessageW(window_, WM_STATUS, 0, 0);
}

void WindowsShell::RefreshIcon() {
    // A version mismatch takes the icon over entirely. The state colours say
    // how the queue is doing, and while the two halves disagree that question
    // is not the one worth answering - so the icon alternates between the
    // working colour and the reload colour, which is a thing no ordinary state
    // ever does and so cannot be mistaken for one.
    const bool alarm = IsMismatch(controller_.Versions().state);
    if (alarm != alarmRunning_) {
        alarmRunning_ = alarm;
        if (alarm) {
            alarmPhase_ = false;
            SetTimer(window_, kAlarmTimer, 1000, nullptr);
        } else {
            KillTimer(window_, kAlarmTimer);
        }
    }

    HICON wanted = alarm
        ? icons_[static_cast<int>(alarmPhase_ ? TrayState::NeedsReload
                                              : TrayState::Working)]
        : icons_[static_cast<int>(state_.load())];
    if (wanted) {
        icon_.hIcon = wanted;

        // The same colour on the window itself, which is what the taskbar
        // button and the title bar draw. Minimising to the notification area is
        // off unless the user turns it on, so for most people the taskbar
        // button is the copy of this icon they are actually looking at - and a
        // state indicator that only updates in the place you are not looking is
        // no indicator at all.
        SendMessageW(window_, WM_SETICON, ICON_SMALL,
                     reinterpret_cast<LPARAM>(wanted));
        SendMessageW(window_, WM_SETICON, ICON_BIG,
                     reinterpret_cast<LPARAM>(wanted));
    }

    std::string tip;
    {
        std::lock_guard<std::mutex> lock(tipMutex_);
        tip = tip_;
    }

    const std::wstring status = Widen(tip);

    // Hidden in the notification area, this tip is the whole of what the
    // application is telling anyone - so a mismatch has to reach it too, or the
    // flashing icon is a signal with nothing behind it.
    const std::wstring hover = alarm
        ? L"CombatSession - "
          + Widen(controller_.Versions().state == VersionState::AddonOutdated
                  ? "addon requires update" : "application requires update")
        : L"CombatSession - " + status;
    wcsncpy_s(icon_.szTip, hover.c_str(), _TRUNCATE);
    if (trayShown_) Shell_NotifyIconW(NIM_MODIFY, &icon_);

    // The window has the name in its title bar already, so the line under the
    // separator is just the state.
    SetDlgItemTextW(window_, kStatusText, status.c_str());
    WriteControls();
}

// Five items, each with an accelerator letter. Everything else the application
// can do is on the window, where there is room to explain it.
void WindowsShell::ShowMenu() {
    HMENU menu = CreatePopupMenu();

    for (const MenuItem& item : controller_.BuildMenu(true)) {
        if (item.separator) {
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            continue;
        }
        const UINT flags = MF_STRING
                         | (item.enabled ? 0u : MF_DISABLED | MF_GRAYED)
                         | (item.checked ? MF_CHECKED : 0u);
        AppendMenuW(menu, flags, static_cast<UINT_PTR>(item.id),
                    Widen(item.label).c_str());
    }

    POINT pt{};
    GetCursorPos(&pt);

    // Anchored to the monitor work area, not the cursor: when the tray is
    // clicked the cursor is inside the taskbar, so a menu anchored there starts
    // underneath it. The work area is the screen minus the taskbar, and its
    // bottom edge is exactly where the menu should end.
    UINT align = TPM_LEFTALIGN;
    MONITORINFO monitor{ sizeof monitor };
    if (GetMonitorInfoW(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), &monitor)) {
        const LONG midY = (monitor.rcWork.top + monitor.rcWork.bottom) / 2;
        const LONG midX = (monitor.rcWork.left + monitor.rcWork.right) / 2;

        if (pt.y > midY) { align |= TPM_BOTTOMALIGN; pt.y = monitor.rcWork.bottom; }
        else             { pt.y = monitor.rcWork.top; }

        if (pt.x > midX) {
            align = (align & ~TPM_LEFTALIGN) | TPM_RIGHTALIGN;
            if (pt.x > monitor.rcWork.right) pt.x = monitor.rcWork.right;
        } else if (pt.x < monitor.rcWork.left) {
            pt.x = monitor.rcWork.left;
        }
    }

    // Required so the menu dismisses when the user clicks elsewhere.
    SetForegroundWindow(window_);
    TrackPopupMenu(menu, align | TPM_LEFTBUTTON | TPM_RIGHTBUTTON,
                   pt.x, pt.y, 0, window_, nullptr);
    PostMessageW(window_, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

void WindowsShell::ShowTrayIcon(bool shown) {
    if (shown == trayShown_) return;
    Shell_NotifyIconW(shown ? NIM_ADD : NIM_DELETE, &icon_);
    trayShown_ = shown;
    if (shown) RefreshIcon();   // so it arrives carrying the current state
}


// Putting the window away into the notification area.
//
// The first time in a session it also says so. A window that vanishes on close
// is a normal pattern for a program that has to keep running, but only when the
// user can find it again - and "where did it go" is the complaint that pattern
// earns when nobody is told.
void WindowsShell::HideToTray() {
    ShowTrayIcon(true);
    ShowWindow(window_, SW_HIDE);

    if (toldAboutTray_) return;
    toldAboutTray_ = true;

    NOTIFYICONDATAW balloon = icon_;
    balloon.uFlags      = NIF_INFO;
    balloon.dwInfoFlags = NIIF_INFO;
    wcscpy_s(balloon.szInfoTitle, L"CombatSession is still running");
    wcscpy_s(balloon.szInfo,
             L"Click the icon to open it again, or right-click it to quit.");
    Shell_NotifyIconW(NIM_MODIFY, &balloon);
}
void WindowsShell::RestoreWindow() {
    ShowWindow(window_, SW_SHOW);
    ShowWindow(window_, SW_RESTORE);
    SetForegroundWindow(window_);
    ShowTrayIcon(false);
}

LRESULT WindowsShell::Handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_TRAY:
        if (LOWORD(lp) == WM_RBUTTONUP) { ShowMenu(); return 0; }
        if (LOWORD(lp) == WM_LBUTTONUP || LOWORD(lp) == WM_LBUTTONDBLCLK) {
            RestoreWindow();
            return 0;
        }
        return 0;

    case WM_STATUS:
        RefreshIcon();
        return 0;

    case WM_QUITAPP:
        // The only thing that actually ends the process. Posted rather than
        // called so it happens on the UI thread whoever asked for it.
        DestroyWindow(hwnd);
        return 0;

    case WM_CTLCOLORSTATIC: {
        const int id = GetDlgCtrlID(reinterpret_cast<HWND>(lp));
        auto dc = reinterpret_cast<HDC>(wp);
        SetBkMode(dc, TRANSPARENT);

        if (id == kPathText && !controller_.Settings().IsValid()) {
            SetTextColor(dc, RGB(0xC0, 0x20, 0x20));
            return reinterpret_cast<LRESULT>(GetSysColorBrush(COLOR_3DFACE));
        }
        if (id == kPathHint) {
            SetTextColor(dc, RGB(0xC0, 0x20, 0x20));
            return reinterpret_cast<LRESULT>(GetSysColorBrush(COLOR_3DFACE));
        }

        // Red on the half that is behind, and on the banner whenever there is
        // one. Only the half that needs doing something about is coloured: two
        // red lines would say the user has two problems when they have one.
        if (id == kVersionBanner || id == kAddonStatus || id == kAppStatus) {
            const VersionStatus versions = controller_.Versions();
            const bool bad =
                (id == kVersionBanner && IsMismatch(versions.state))
             || (id == kAddonStatus && versions.state == VersionState::AddonOutdated)
             || (id == kAppStatus   && versions.state == VersionState::AppOutdated);
            if (bad) {
                SetTextColor(dc, RGB(0xC0, 0x20, 0x20));
                return reinterpret_cast<LRESULT>(GetSysColorBrush(COLOR_3DFACE));
            }
        }
        break;
    }

    case WM_TIMER:
        if (wp == kAlarmTimer) {
            alarmPhase_ = !alarmPhase_;
            RefreshIcon();
            return 0;
        }
        break;

    case WM_COMMAND: {
        const int id = LOWORD(wp);

        // The plain settings controls change the configuration and nothing
        // else; the commands are the application's, and go to the controller.
        switch (id) {
        case kStartup:
        case kStartMinimized:
        case kArchive:
        case kMinimize:
        case kSoundOn:
        case kRepeatOnce:
        case kRepeatEvery:
        case kAlertNew:
            ReadControls();
            controller_.SettingsChanged();
            WriteControls();
            return 0;

        case kPollSeconds:
        case kRepeatSeconds:
            if (HIWORD(wp) == EN_KILLFOCUS) {
                ReadControls();
                controller_.SettingsChanged();
                WriteControls();
            }
            return 0;

        default:
            controller_.OnCommand(id);
            WriteControls();
            return 0;
        }
    }

    case WM_SYSCOMMAND:
        if ((wp & 0xFFF0) == SC_MINIMIZE && controller_.Settings().minimizeToTray) {
            HideToTray();
            return 0;
        }
        break;

    case WM_CLOSE:
        // With the notification area chosen, close puts the window there rather
        // than ending the program - the established behaviour for an application
        // that has to keep running, and defensible only because the user opted
        // into it. Quit is on the icon menu.
        //
        // Without it, close means close. An X that never closes anything is the
        // version of this pattern people rightly complain about.
        if (controller_.Settings().minimizeToTray) {
            HideToTray();
            return 0;
        }
        DestroyWindow(hwnd);
        return 0;

    case WM_DESTROY:
        ShowTrayIcon(false);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

bool WindowsShell::Create() {
    g_shell = this;

    fontUI_      = MakeFont(15, FW_NORMAL);
    fontTitle_   = MakeFont(30, FW_SEMIBOLD);
    fontSub_     = MakeFont(13, FW_NORMAL);
    fontSection_ = MakeFont(15, FW_SEMIBOLD);

    icons_[static_cast<int>(TrayState::Idle)]        = MakeIcon(kIdleGreen);
    icons_[static_cast<int>(TrayState::Working)]     = MakeIcon(kWorkingAmber);
    icons_[static_cast<int>(TrayState::NeedsReload)] = MakeIcon(kReloadRed);

    HICON appIcon = icons_[static_cast<int>(TrayState::Idle)];

    static const wchar_t* kClass = L"CombatSessionWindow";

    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof wc;
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = GetModuleHandleW(nullptr);
    wc.hCursor       = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = GetSysColorBrush(COLOR_3DFACE);
    wc.lpszClassName = kClass;
    wc.hIcon         = appIcon;
    wc.hIconSm       = appIcon;
    RegisterClassExW(&wc);

    RECT wanted{ 0, 0, kWidth, 706 };
    AdjustWindowRect(&wanted, WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU |
                              WS_MINIMIZEBOX, FALSE);
    const int w = wanted.right - wanted.left;
    const int h = wanted.bottom - wanted.top;

    window_ = CreateWindowExW(
        0, kClass, L"CombatSession",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX,
        (GetSystemMetrics(SM_CXSCREEN) - w) / 2,
        (GetSystemMetrics(SM_CYSCREEN) - h) / 2,
        w, h, nullptr, nullptr, wc.hInstance, nullptr);
    if (!window_) return false;

    BuildControls();
    WriteControls();

    icon_.cbSize           = sizeof icon_;
    icon_.hWnd             = window_;
    icon_.uID              = 1;
    icon_.uFlags           = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    icon_.uCallbackMessage = WM_TRAY;
    icon_.hIcon            = appIcon;
    if (!icon_.hIcon) icon_.hIcon = LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
    wcscpy_s(icon_.szTip, L"CombatSession - starting");
    // Described but not added. It appears only when the window hides into it.

    const Config& config = controller_.Settings();

    // Start minimized is a preference about the ordinary case, and a mismatch
    // is not the ordinary case: nothing this application does while the two
    // halves disagree is worth doing, so it opens and says so rather than
    // sitting in the notification area flashing at somebody who is not looking
    // at the notification area.
    if (config.startMinimized && !IsMismatch(controller_.Versions().state)) {
        // Where it goes follows the other setting, so "minimized" means the
        // same thing at startup as it does at any other time.
        //
        // Deliberately ShowTrayIcon rather than HideToTray: no balloon here.
        // That notice explains a surprise - the close button not closing - and
        // starting minimized is not a surprise, it is what the user asked for.
        // Saying it at login would be explaining their own setting back to them
        // on every boot.
        if (config.minimizeToTray) ShowTrayIcon(true);      // window stays hidden
        else                       ShowWindow(window_, SW_SHOWMINIMIZED);
    } else {
        ShowWindow(window_, SW_SHOW);
    }
    return true;
}

int WindowsShell::Run() {
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        // So tab, space and the accelerator keys work in the window.
        if (!IsDialogMessageW(window_, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
    return 0;
}

void WindowsShell::Quit() {
    if (window_) PostMessageW(window_, WM_QUITAPP, 0, 0);
}

WindowsShell::~WindowsShell() {
    for (HICON handle : icons_) if (handle) DestroyIcon(handle);
    for (HFONT font : { fontUI_, fontTitle_, fontSub_, fontSection_ }) {
        if (font) DeleteObject(font);
    }
    g_shell = nullptr;
}

} // namespace

std::unique_ptr<ShellHost> CreateShell(AppController& controller) {
    auto shell = std::make_unique<WindowsShell>(controller);
    if (!shell->Create()) return nullptr;
    return shell;
}

bool PromptForWowFolder(std::string& path) {
    return AskForWowFolder(path);
}

} // namespace cs
