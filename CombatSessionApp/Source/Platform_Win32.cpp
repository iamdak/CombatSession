// CombatSession :: Platform, Windows
//
// Everything here was previously spread through App.cpp, Config.cpp, main.cpp
// and Generator.cpp. Gathering it in one file is what let those four become
// portable, and it is also the honest arrangement: none of this is a decision
// about the application, it is how one operating system spells things.

#include "Platform.h"

#include <windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <commdlg.h>
#include <mmsystem.h>

namespace fs = std::filesystem;

namespace cs {
namespace {

// The system APIs used here are all wide-character, and every path this program
// handles came from std::filesystem, so conversion goes through fs::path rather
// than through a byte-by-byte widening that would mangle anything non-ASCII in
// a user's install path.
std::wstring Widen(const std::string& text) {
    if (text.empty()) return {};
    return fs::path(text).wstring();
}

std::wstring WidenText(const std::string& text) {
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

constexpr const wchar_t* kRunKey =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr const wchar_t* kRunValue = L"CombatSession";

} // namespace

//------------------------------------------------------------------------------
// Process
//------------------------------------------------------------------------------

// Hidden first, then freed. The window exists from process creation until this
// runs - microseconds - and hiding before freeing keeps it from being painted
// in between, which is the difference between no console and a flicker at every
// login for a program set to start with Windows.
void ReleaseConsole() {
    if (HWND console = GetConsoleWindow()) ShowWindow(console, SW_HIDE);
    FreeConsole();
}

fs::path ExecutablePath() {
    wchar_t buffer[MAX_PATH]{};
    GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    return fs::path(buffer);
}

// A named mutex in the Local namespace: per-session, so two users logged into
// the same machine each get their own application rather than one locking the
// other out.
NamedLock::NamedLock(const std::string& name, bool tryOnly) {
    const std::wstring full = L"Local\\" + WidenText(name);

    HANDLE handle = CreateMutexW(nullptr, tryOnly ? TRUE : FALSE, full.c_str());
    if (!handle) return;

    if (tryOnly) {
        // Ownership was requested at creation, so ERROR_ALREADY_EXISTS is the
        // whole answer: somebody else has it.
        if (GetLastError() == ERROR_ALREADY_EXISTS) {
            CloseHandle(handle);
            return;
        }
        handle_ = handle;
        held_   = true;
        return;
    }

    // WAIT_ABANDONED means the previous holder died mid-pass. Its work is
    // incomplete either way, and waiting forever for a dead process helps
    // nobody, so an abandoned mutex is taken like any other.
    WaitForSingleObject(handle, INFINITE);
    handle_ = handle;
    held_   = true;
}

NamedLock::~NamedLock() {
    if (!handle_) return;
    if (held_) ReleaseMutex(static_cast<HANDLE>(handle_));
    CloseHandle(static_cast<HANDLE>(handle_));
}

//------------------------------------------------------------------------------
// Shell
//------------------------------------------------------------------------------

void PlaySoundFile(const std::string& path) {
    if (path.empty()) return;

    const std::wstring wide = Widen(path);
    if (PlaySoundW(wide.c_str(), nullptr,
                   SND_FILENAME | SND_ASYNC | SND_NODEFAULT)) {
        return;
    }
    MessageBeep(MB_ICONASTERISK);
}

void OpenFolder(const fs::path& dir) {
    ShellExecuteW(nullptr, L"open", dir.wstring().c_str(),
                  nullptr, nullptr, SW_SHOWNORMAL);
}

void ShowMessage(const std::string& title, const std::string& text,
                 bool warning) {
    MessageBoxW(nullptr, WidenText(text).c_str(), WidenText(title).c_str(),
                warning ? MB_ICONWARNING : MB_ICONINFORMATION);
}

// SHBrowseForFolder rather than IFileDialog: this is asked once, and the modern
// dialog would pull COM initialisation into a process that otherwise needs none.
std::string PickFolder(const std::string& title) {
    wchar_t display[MAX_PATH]{};
    const std::wstring caption = WidenText(title);

    BROWSEINFOW info{};
    info.pszDisplayName = display;
    info.lpszTitle      = caption.c_str();
    info.ulFlags        = BIF_RETURNONLYFSDIRS | BIF_NEWDIALOGSTYLE;

    LPITEMIDLIST id = SHBrowseForFolderW(&info);
    if (!id) return {};

    wchar_t path[MAX_PATH]{};
    const bool ok = SHGetPathFromIDListW(id, path) != FALSE;
    CoTaskMemFree(id);
    if (!ok) return {};

    return fs::path(path).string();
}

std::string PickSoundFile(const std::string& current) {
    std::wstring buffer(MAX_PATH, L'\0');
    if (!current.empty()) {
        const std::wstring wide = Widen(current);
        wcsncpy_s(buffer.data(), MAX_PATH, wide.c_str(), _TRUNCATE);
    }

    OPENFILENAMEW open{};
    open.lStructSize = sizeof open;
    open.lpstrFilter = L"Wave files\0*.wav\0All files\0*.*\0";
    open.lpstrFile   = buffer.data();
    open.nMaxFile    = MAX_PATH;
    open.lpstrTitle  = L"Sound to play when a reload is needed";
    open.Flags       = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;

    if (!GetOpenFileNameW(&open)) return {};
    return fs::path(buffer.c_str()).string();
}

//------------------------------------------------------------------------------
// Login item
//------------------------------------------------------------------------------

bool SetStartAtLogin(bool enabled) {
    HKEY key{};
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_SET_VALUE, &key)
        != ERROR_SUCCESS) {
        return false;
    }

    bool ok;
    if (enabled) {
        const std::wstring quoted = L"\"" + ExecutablePath().wstring() + L"\"";
        ok = RegSetValueExW(key, kRunValue, 0, REG_SZ,
                            reinterpret_cast<const BYTE*>(quoted.c_str()),
                            static_cast<DWORD>((quoted.size() + 1) * sizeof(wchar_t)))
             == ERROR_SUCCESS;
    } else {
        const LSTATUS status = RegDeleteValueW(key, kRunValue);
        ok = (status == ERROR_SUCCESS || status == ERROR_FILE_NOT_FOUND);
    }

    RegCloseKey(key);
    return ok;
}

bool GetStartAtLogin() {
    HKEY key{};
    if (RegOpenKeyExW(HKEY_CURRENT_USER, kRunKey, 0, KEY_QUERY_VALUE, &key)
        != ERROR_SUCCESS) {
        return false;
    }
    const bool present = RegQueryValueExW(key, kRunValue, nullptr, nullptr,
                                          nullptr, nullptr) == ERROR_SUCCESS;
    RegCloseKey(key);
    return present;
}

const char* StartAtLoginLabel() { return "Start with Windows"; }

//------------------------------------------------------------------------------
// Defaults
//------------------------------------------------------------------------------

std::string DefaultAlertSound() {
    wchar_t root[MAX_PATH]{};
    if (GetWindowsDirectoryW(root, MAX_PATH) == 0) return {};

    const fs::path media = fs::path(root) / "Media";
    std::error_code ec;

    const fs::path candidate = media / "Windows Notify System Generic.wav";
    if (fs::exists(candidate, ec)) return candidate.string();

    // Older or trimmed installations may not have that one; ding.wav has been
    // present since XP. Failing that, an empty string means "use the beep".
    const fs::path fallback = media / "ding.wav";
    if (fs::exists(fallback, ec)) return fallback.string();
    return {};
}

std::vector<fs::path> DefaultWowRoots() {
    return {
        "C:\\Program Files (x86)\\World of Warcraft",
        "C:\\Program Files\\World of Warcraft",
        "C:\\Games\\World of Warcraft",
        "D:\\Games\\World of Warcraft",
    };
}

} // namespace cs
