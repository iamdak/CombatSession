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

// COM is needed for the folder picker and for writing the startup shortcut.
// Initialised per call, on the calling thread, because both are used from the
// UI thread and neither is hot.
struct ComScope {
    bool owned = false;

    ComScope() {
        const HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        // S_FALSE means this thread had already initialised COM, and
        // uninitialising it here would take away something somebody else is
        // still using.
        owned = SUCCEEDED(hr) && hr != S_FALSE;
    }
    ~ComScope() { if (owned) CoUninitialize(); }

    ComScope(const ComScope&) = delete;
    ComScope& operator=(const ComScope&) = delete;
};

fs::path StartupShortcut() {
    PWSTR folder = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_Startup, 0, nullptr, &folder))) {
        return {};
    }
    fs::path path = fs::path(folder) / L"CombatSession.lnk";
    CoTaskMemFree(folder);
    return path;
}

bool WriteShortcut(const fs::path& target, const fs::path& link) {
    ComScope com;

    IShellLinkW* shell = nullptr;
    if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_IShellLinkW,
                                reinterpret_cast<void**>(&shell)))) {
        return false;
    }

    shell->SetPath(target.wstring().c_str());
    shell->SetWorkingDirectory(target.parent_path().wstring().c_str());
    shell->SetDescription(L"CombatSession - combat log processor for "
                          L"World of Warcraft");

    IPersistFile* file = nullptr;
    bool ok = false;
    if (SUCCEEDED(shell->QueryInterface(IID_IPersistFile,
                                        reinterpret_cast<void**>(&file)))) {
        ok = SUCCEEDED(file->Save(link.wstring().c_str(), TRUE));
        file->Release();
    }

    shell->Release();
    return ok;
}

} // namespace

//------------------------------------------------------------------------------
// Process
//------------------------------------------------------------------------------

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

// The registered notification sound, which is what the user already hears when
// anything else on the system tells them something. SND_ALIAS resolves it
// through their current sound scheme, so it follows their theme and cannot be
// missing.
void PlayDefaultAlert() {
    if (PlaySoundW(L"Notification.Default", nullptr,
                   SND_ALIAS | SND_ASYNC | SND_NODEFAULT)) {
        return;
    }
    MessageBeep(MB_ICONASTERISK);
}

void PlaySoundFile(const std::string& path) {
    if (path.empty()) {
        PlayDefaultAlert();
        return;
    }

    const std::wstring wide = Widen(path);
    if (PlaySoundW(wide.c_str(), nullptr,
                   SND_FILENAME | SND_ASYNC | SND_NODEFAULT)) {
        return;
    }
    // A chosen file that has since been moved or deleted should still make the
    // noise it was asked for rather than silently doing nothing.
    PlayDefaultAlert();
}

// MessageBeep rather than PlaySound: this one is the system's error sound by
// definition, it needs no alias name that a future Windows might rename, and it
// is the same sound a user hears from every other program that has hit
// something it cannot work around.
void PlayErrorAlert() {
    MessageBeep(MB_ICONERROR);
}

// Asked by opening the file with no sharing allowed. If the client still has it,
// the open fails with a sharing violation and nothing has been disturbed - the
// handle is closed immediately either way, and the file is never written to.
FileBusy FileHeldOpen(const fs::path& file) {
    HANDLE handle = CreateFileW(file.wstring().c_str(), GENERIC_READ,
                                0 /* no sharing */, nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL, nullptr);
    if (handle != INVALID_HANDLE_VALUE) {
        CloseHandle(handle);
        return FileBusy::No;
    }

    const DWORD error = GetLastError();
    if (error == ERROR_SHARING_VIOLATION || error == ERROR_LOCK_VIOLATION) {
        return FileBusy::Yes;
    }

    // Anything else - gone, renamed, permissions - is not an answer to the
    // question that was asked.
    return FileBusy::Unknown;
}

void OpenFolder(const fs::path& dir) {
    ShellExecuteW(nullptr, L"open", dir.wstring().c_str(),
                  nullptr, nullptr, SW_SHOWNORMAL);
}

// ShellExecute runs whatever the string names, so the scheme is checked first.
// The two addresses this program opens are compiled into it and cannot be
// configured, but a launcher that will start anything is worth not having at
// all - the check costs one comparison and removes the whole question.
void OpenUrl(const std::string& url) {
    if (url.rfind("http://", 0) != 0 && url.rfind("https://", 0) != 0) return;
    ShellExecuteW(nullptr, L"open", WidenText(url).c_str(),
                  nullptr, nullptr, SW_SHOWNORMAL);
}

bool Confirm(const std::string& title, const std::string& text) {
    return MessageBoxW(GetActiveWindow(), WidenText(text).c_str(),
                       WidenText(title).c_str(),
                       MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) == IDYES;
}

bool ConfirmAction(const std::string& title, const std::string& text) {
    return MessageBoxW(GetActiveWindow(), WidenText(text).c_str(),
                       WidenText(title).c_str(),
                       MB_OKCANCEL | MB_ICONINFORMATION) == IDOK;
}

// SHBrowseForFolder rather than IFileDialog: this is asked rarely, and the
// modern dialog is a good deal more machinery for the same answer.
std::string PickFolder(const std::string& title) {
    ComScope com;

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
    open.lpstrFilter = L"Sound files\0*.wav\0All files\0*.*\0";
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

// A shortcut in the user's own Startup folder. No registry, no elevation, and
// it lands where people already look - Task Manager lists it under Startup apps
// exactly as a Run value would, and File Explorer can delete it.
//
// Enabling always removes first and writes fresh. Somebody who has run this
// application from two places would otherwise keep a shortcut pointing at
// whichever copy happened to be enabled first, which is how a program ends up
// launching a binary its user has forgotten they had.
bool SetStartAtLogin(bool enabled) {
    const fs::path link = StartupShortcut();
    if (link.empty()) return false;

    std::error_code ec;
    fs::remove(link, ec);
    if (!enabled) return true;

    return WriteShortcut(ExecutablePath(), link);
}

bool GetStartAtLogin() {
    const fs::path link = StartupShortcut();
    if (link.empty()) return false;

    std::error_code ec;
    return fs::exists(link, ec);
}

const char* StartAtLoginLabel() { return "Start with Windows"; }

} // namespace cs
