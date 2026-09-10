// CombatSession :: Tray, Windows
//
// A notification-area icon on a hidden top-level window.

#include "Tray.h"

#include "Icon.h"

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

    // 1bpp AND mask, one set bit per transparent pixel. Rows are 32 pixels, so
    // exactly four bytes, which is already the WORD alignment CreateBitmap
    // wants. Derived from the alpha channel rather than restating which pixels
    // the renderer decided to clear.
    uint8_t mask[kIconSize * 4]{};
    for (int y = 0; y < kIconSize; ++y) {
        for (int x = 0; x < kIconSize; ++x) {
            const uint32_t pixel = pixels[static_cast<size_t>(y) * kIconSize + x];
            if ((pixel & 0xFF000000u) == 0) {
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

class Win32Tray : public TrayHost {
public:
    explicit Win32Tray(TrayController& controller) : controller_(controller) {}
    ~Win32Tray() override;

    bool Create();

    void Update(TrayState state, const std::string& tooltip) override;
    int  Run() override;
    void Quit() override;

private:
    static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
    LRESULT Handle(HWND, UINT, WPARAM, LPARAM);

    void ShowMenu(HWND);
    void RefreshIcon();

    TrayController& controller_;

    HWND            window_ = nullptr;
    NOTIFYICONDATAW icon_{};
    HICON           icons_[3]{};

    std::atomic<TrayState> state_{ TrayState::Idle };

    std::mutex  tipMutex_;
    std::string tip_ = "starting";
};

Win32Tray* g_tray = nullptr;

LRESULT CALLBACK Win32Tray::WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (g_tray) return g_tray->Handle(hwnd, msg, wp, lp);
    return DefWindowProcW(hwnd, msg, wp, lp);
}

void Win32Tray::Update(TrayState state, const std::string& tooltip) {
    {
        std::lock_guard<std::mutex> lock(tipMutex_);
        tip_ = tooltip;
    }
    state_.store(state);
    if (window_) PostMessageW(window_, WM_STATUS, 0, 0);
}

void Win32Tray::RefreshIcon() {
    HICON wanted = icons_[static_cast<int>(state_.load())];
    if (wanted) icon_.hIcon = wanted;

    std::lock_guard<std::mutex> lock(tipMutex_);
    const std::wstring tip = L"CombatSession - " + Widen(tip_);
    wcsncpy_s(icon_.szTip, tip.c_str(), _TRUNCATE);
    Shell_NotifyIconW(NIM_MODIFY, &icon_);
}

void Win32Tray::ShowMenu(HWND hwnd) {
    HMENU menu = CreatePopupMenu();

    for (const TrayMenuItem& item : controller_.BuildMenu()) {
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

    // Anchored to the monitor's work area, not to the cursor.
    //
    // The cursor is inside the taskbar when the tray is clicked, so anchoring
    // the menu's bottom there still leaves it starting inside the taskbar and
    // being covered by it. The work area is the screen minus the taskbar, so
    // its bottom edge is exactly where the menu should end.
    UINT align = TPM_LEFTALIGN;
    MONITORINFO monitor{ sizeof monitor };
    if (GetMonitorInfoW(MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST), &monitor)) {
        const LONG midY = (monitor.rcWork.top + monitor.rcWork.bottom) / 2;
        const LONG midX = (monitor.rcWork.left + monitor.rcWork.right) / 2;

        if (pt.y > midY) {
            align |= TPM_BOTTOMALIGN;
            pt.y = monitor.rcWork.bottom;
        } else {
            pt.y = monitor.rcWork.top;
        }

        if (pt.x > midX) {
            align = (align & ~TPM_LEFTALIGN) | TPM_RIGHTALIGN;
            if (pt.x > monitor.rcWork.right) pt.x = monitor.rcWork.right;
        } else if (pt.x < monitor.rcWork.left) {
            pt.x = monitor.rcWork.left;
        }
    }

    // Required so the menu dismisses when the user clicks elsewhere.
    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, align | TPM_LEFTBUTTON | TPM_RIGHTBUTTON,
                   pt.x, pt.y, 0, hwnd, nullptr);
    PostMessageW(hwnd, WM_NULL, 0, 0);
    DestroyMenu(menu);
}

LRESULT Win32Tray::Handle(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_TRAY:
        if (LOWORD(lp) == WM_RBUTTONUP || LOWORD(lp) == WM_LBUTTONUP) {
            ShowMenu(hwnd);
        }
        return 0;

    case WM_STATUS:
        RefreshIcon();
        return 0;

    case WM_COMMAND:
        controller_.OnCommand(static_cast<int>(LOWORD(wp)));
        return 0;

    case WM_DESTROY:
        Shell_NotifyIconW(NIM_DELETE, &icon_);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// A hidden top-level window, not a message-only one.
//
// The distinction matters for exactly one thing: a tray menu has to be
// dismissable, which means its owner must be able to become the foreground
// window, and a message-only window never can. TrackPopupMenu on one either
// shows nothing or closes the instant it opens - so the menu, and with it the
// only way to quit, was unreachable. WS_EX_TOOLWINDOW keeps it out of the
// taskbar and alt-tab; it is never shown, so it stays invisible.
bool Win32Tray::Create() {
    g_tray = this;

    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof wc;
    wc.lpfnWndProc   = WndProc;
    wc.hInstance     = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"CombatSessionTray";
    RegisterClassExW(&wc);

    window_ = CreateWindowExW(WS_EX_TOOLWINDOW, wc.lpszClassName,
                              L"CombatSession", WS_POPUP, 0, 0, 0, 0,
                              nullptr, nullptr, wc.hInstance, nullptr);
    if (!window_) return false;

    icons_[static_cast<int>(TrayState::Idle)]        = MakeIcon(kIdleGreen);
    icons_[static_cast<int>(TrayState::Working)]     = MakeIcon(kWorkingAmber);
    icons_[static_cast<int>(TrayState::NeedsReload)] = MakeIcon(kReloadRed);

    icon_.cbSize           = sizeof icon_;
    icon_.hWnd             = window_;
    icon_.uID              = 1;
    icon_.uFlags           = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    icon_.uCallbackMessage = WM_TRAY;
    // Falls back to the stock application icon only if drawing failed, so a GDI
    // problem costs the colour rather than the tray entry.
    icon_.hIcon = icons_[static_cast<int>(TrayState::Idle)];
    if (!icon_.hIcon) icon_.hIcon = LoadIconW(nullptr, MAKEINTRESOURCEW(32512));
    wcscpy_s(icon_.szTip, L"CombatSession - starting");
    Shell_NotifyIconW(NIM_ADD, &icon_);
    return true;
}

int Win32Tray::Run() {
    MSG msg;
    while (GetMessageW(&msg, nullptr, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

void Win32Tray::Quit() {
    if (window_) PostMessageW(window_, WM_CLOSE, 0, 0);
}

Win32Tray::~Win32Tray() {
    for (HICON handle : icons_) {
        if (handle) DestroyIcon(handle);
    }
    g_tray = nullptr;
}

} // namespace

std::unique_ptr<TrayHost> CreateTrayHost(TrayController& controller) {
    auto tray = std::make_unique<Win32Tray>(controller);
    if (!tray->Create()) return nullptr;
    return tray;
}

} // namespace cs
