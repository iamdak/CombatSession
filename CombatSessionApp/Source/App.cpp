// CombatSession :: App
//
// The status-area application: watches the Logs folder, runs the generator when
// a log settles, and reports what it found through the icon and its menu.
//
// Portable. Everything that used to make this file Windows-only - the window,
// the icon, the menu, the pickers, the noise - now sits behind TrayHost and
// Platform.h. What is left is the part that was never about an operating
// system: when to run a pass, what the result means, and what to say about it.

#include "App.h"

#include "Generator.h"
#include "Platform.h"
#include "Tray.h"

#include <atomic>
#include <chrono>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace cs {
namespace {

enum Command {
    kStatus     = 1000,
    kProcessNow = 1001,
    kOpenData   = 1002,
    kOpenLogs   = 1003,
    kAutostart  = 1004,
    kArchive    = 1006,
    kQuit       = 1007,
    kSetWow     = 1008,
    kSetSound   = 1009,
};

class TrayApp : public TrayController {
public:
    explicit TrayApp(Config config) : config_(std::move(config)) {}

    int Run();

    std::vector<TrayMenuItem> BuildMenu() override;
    void OnCommand(int id) override;

private:
    void SetStatus(std::string text);
    void SetState(TrayState state);
    void Publish();

    void WatchLoop();          // runs on its own thread
    uint64_t WatchFingerprint() const;
    bool     AddonHasSeenQueue() const;
    void RunGenerator();       // may block for many seconds on a large session

    Config    config_;
    TrayHost* host_ = nullptr;

    std::atomic<TrayState> state_{ TrayState::Idle };

    std::thread       watcher_;
    std::atomic<bool> quitting_{ false };
    std::atomic<bool> busy_{ false };
    // Set by the watcher when a change is seen; cleared once processed.
    std::atomic<bool> dirty_{ false };
    // The last pass left a session open at end-of-data, so a later pass has to
    // decide whether the log is simply finished.
    std::atomic<bool> openSession_{ false };

    mutable std::mutex statusMutex_;
    std::string        status_ = "starting";
    size_t             sessionCount_ = 0;
};

//------------------------------------------------------------------------------

void TrayApp::SetStatus(std::string text) {
    {
        std::lock_guard<std::mutex> lock(statusMutex_);
        status_ = std::move(text);
    }
    Publish();
}

void TrayApp::SetState(TrayState state) {
    // Compared before publishing so an unchanged state costs nothing: the
    // watcher wakes twice a second and would otherwise repaint every tick.
    if (state_.exchange(state) == state) return;
    Publish();
}

void TrayApp::Publish() {
    if (!host_) return;

    std::string tip;
    {
        std::lock_guard<std::mutex> lock(statusMutex_);
        tip = status_;
    }
    host_->Update(state_.load(), tip);
}

//------------------------------------------------------------------------------

void TrayApp::RunGenerator() {
    if (busy_.exchange(true)) return;   // a pass is already running here
    SetStatus("processing...");
    SetState(TrayState::Working);

    // And not in another process either. busy_ only covers this one.
    NamedLock pass("CombatSessionPass");

    GeneratorOptions options;
    options.addonsRoot   = config_.AddOnsDir();
    options.rawDir       = config_.RawDir();
    options.wtfRoot      = config_.WtfRoot();
    options.rawLimit     = config_.rawLimit;
    options.pendingLimit = config_.pendingLimit;
    options.archiveRaw   = config_.archiveRaw;

    Generator generator(options);

    size_t added = 0;
    bool   anyOpen = false;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(config_.LogsDir(), ec)) {
        const std::string name = entry.path().filename().string();
        if (quitting_) break;   // do not start another log when quitting
        if (name.rfind("WoWCombatLog", 0) == 0 && entry.path().extension() == ".txt") {
            added += generator.ProcessLog(entry.path(), 0,
                                          LogLooksClosed(entry.path(), config_.closedAfterSeconds));
            if (!generator.LastLogComplete()) anyOpen = true;
        }
    }
    openSession_ = anyOpen;
    generator.Commit();

    sessionCount_ = generator.Records().size();
    if (sessionCount_ == 0) {
        SetStatus(added > 0
            ? (std::to_string(added) + " new session(s), all consumed")
            : std::string("up to date"));
        SetState(TrayState::Idle);
    } else if (AddonHasSeenQueue()) {
        // Delivered and loaded; the chunks are only still here because the
        // addon has not written its record yet. Nothing for the user to do.
        SetStatus(std::to_string(sessionCount_)
                  + " session(s) delivered - queue clears on next save");
        SetState(TrayState::Idle);
    } else {
        // Chunks are written and the archive has them; the addon simply cannot
        // see a file that appeared after the client loaded. Red asks for the one
        // thing the application cannot do for itself.
        SetStatus(std::to_string(sessionCount_)
                  + " session(s) waiting - /reload in game");

        // Only on the transition. Repeating it on every pass would turn the one
        // useful noise this makes into something to be muted.
        const bool wasWaiting = (state_.load() == TrayState::NeedsReload);
        SetState(TrayState::NeedsReload);
        if (!wasWaiting) PlaySoundFile(config_.reloadSound);
    }

    busy_ = false;
}

// True when the client has loaded since the newest queued chunk was written.
//
// The addon cannot report consuming a chunk until SavedVariables is next
// written, and the client writes that file at the START of a reload - before
// the new index is loaded and before anything is consumed. So immediately after
// the reload that did the job, the written record still describes the state
// before it, and asking for another reload is asking for nothing.
//
// The timestamps settle it. SavedVariables newer than the newest chunk means a
// client load happened after that chunk existed, so the addon has seen it. The
// queue will drain on the next save; nothing is being asked of the user.
bool TrayApp::AddonHasSeenQueue() const {
    std::error_code ec;

    fs::file_time_type newestChunk{};
    bool haveChunk = false;
    const fs::path queue = config_.AddOnsDir() / "CombatSession_Data";
    for (const auto& entry : fs::directory_iterator(queue, ec)) {
        if (entry.path().extension() != ".lua") continue;
        if (entry.path().filename() == "Index.lua") continue;

        std::error_code fileEc;
        const auto written = fs::last_write_time(entry.path(), fileEc);
        if (fileEc) continue;
        if (!haveChunk || written > newestChunk) {
            newestChunk = written;
            haveChunk = true;
        }
    }
    if (!haveChunk) return true;

    fs::file_time_type newestState{};
    bool haveState = false;
    for (const auto& account : fs::directory_iterator(config_.WtfRoot(), ec)) {
        if (!account.is_directory()) continue;

        std::error_code fileEc;
        const auto written = fs::last_write_time(
            account.path() / "SavedVariables" / "CombatSession.lua", fileEc);
        if (fileEc) continue;
        if (!haveState || written > newestState) {
            newestState = written;
            haveState = true;
        }
    }

    return haveState && newestState > newestChunk;
}

// Total bytes plus newest write time across everything worth reacting to.
//
// Cheap enough to check every tick, and unlike a change notification it cannot
// be missed: a directory watch is not armed while a pass is running, so a write
// landing mid-parse was never reported at all. Correctness should not depend on
// catching every event when comparing a handful of file sizes says the same
// thing - and a poll is the same three lines on every operating system, where
// change notification is a different API on each.
//
// Two things are watched, because two different events matter. The logs growing
// means there may be new sessions to emit. The addon's SavedVariables being
// written means it has published what it now holds, which is the only signal
// that queued chunks have become collectable - and without it the tray went on
// asking for a reload after the reload that had already done the job, because
// nothing else had changed so no pass ran so nothing looked.
uint64_t TrayApp::WatchFingerprint() const {
    uint64_t stamp = 0;
    std::error_code ec;

    auto Add = [&stamp](const fs::path& file) {
        std::error_code fileEc;
        const auto size = fs::file_size(file, fileEc);
        if (fileEc) return;
        stamp += size;

        const auto written = fs::last_write_time(file, fileEc);
        if (fileEc) return;
        stamp += static_cast<uint64_t>(written.time_since_epoch().count() / 10000000);
    };

    for (const auto& entry : fs::directory_iterator(config_.LogsDir(), ec)) {
        const std::string name = entry.path().filename().string();
        if (name.rfind("WoWCombatLog", 0) != 0) continue;
        if (entry.path().extension() != ".txt") continue;
        Add(entry.path());
    }

    for (const auto& account : fs::directory_iterator(config_.WtfRoot(), ec)) {
        if (!account.is_directory()) continue;
        Add(account.path() / "SavedVariables" / "CombatSession.lua");
    }

    return stamp;
}

void TrayApp::WatchLoop() {
    // An initial pass catches anything written while the app was not running.
    RunGenerator();

    uint64_t seen = WatchFingerprint();
    auto lastChange = std::chrono::steady_clock::now();

    while (!quitting_) {
        std::this_thread::sleep_for(std::chrono::milliseconds(500));
        if (quitting_) break;

        const uint64_t now = WatchFingerprint();
        if (now != seen) {
            seen = now;
            dirty_ = true;
            lastChange = std::chrono::steady_clock::now();
            SetStatus("change detected...");
        }

        const auto quiet = std::chrono::steady_clock::now() - lastChange;

        // The client appends continuously during a match, so processing waits
        // until the log has been quiet for settleSeconds. That turns a burst of
        // writes into a single pass once the match is over.
        if (dirty_ && quiet >= std::chrono::seconds(config_.settleSeconds)) {
            dirty_ = false;
            RunGenerator();
            lastChange = std::chrono::steady_clock::now();
            continue;
        }

        // A session still open at end-of-data is withheld, on the assumption the
        // match is still going. But the recorder switches logging off as you
        // leave, so the closing event is often the last thing written - and if
        // it has not reached disk by the time the settle pass runs, nothing
        // further ever arrives to trigger another one. The session then stays
        // withheld for as long as the application runs, which is what "up to
        // date" meant while a finished game sat unprocessed.
        //
        // closedAfterSeconds is the answer to that, but it can only decide a log
        // is finished on a pass that actually happens. This is that pass.
        if (openSession_ && quiet >= std::chrono::seconds(config_.closedAfterSeconds)) {
            RunGenerator();
            lastChange = std::chrono::steady_clock::now();
        }
    }
}

//------------------------------------------------------------------------------

std::vector<TrayMenuItem> TrayApp::BuildMenu() {
    std::vector<TrayMenuItem> menu;

    TrayMenuItem status;
    {
        std::lock_guard<std::mutex> lock(statusMutex_);
        status.label = status_;
    }
    status.id      = kStatus;
    status.enabled = false;
    menu.push_back(status);

    menu.push_back(TrayMenuItem::Divider());
    menu.push_back({ kProcessNow, "Process now", !busy_, false, false });
    menu.push_back({ kOpenData,   "Open data folder", true, false, false });
    menu.push_back({ kOpenLogs,   "Open Logs folder", true, false, false });

    menu.push_back(TrayMenuItem::Divider());
    menu.push_back({ kAutostart, StartAtLoginLabel(), true,
                     config_.startAtLogin, false });
    menu.push_back({ kArchive, "Keep raw archive", true,
                     config_.archiveRaw, false });

    menu.push_back(TrayMenuItem::Divider());
    menu.push_back({ kSetWow, "Set World of Warcraft folder...",
                     true, false, false });
    menu.push_back({ kSetSound,
                     config_.reloadSound.empty() ? "Reload sound: off..."
                                                 : "Reload sound...",
                     true, false, false });

    menu.push_back(TrayMenuItem::Divider());
    menu.push_back({ kQuit, "Quit CombatSession", true, false, false });
    return menu;
}

void TrayApp::OnCommand(int id) {
    switch (id) {
    case kProcessNow:
        // On a worker thread: a large battleground takes seconds to parse and
        // must not stall the event loop.
        if (!busy_) std::thread([this] { RunGenerator(); }).detach();
        break;

    case kOpenData:
        OpenFolder(config_.AddOnsDir() / "CombatSession_Data");
        break;

    case kOpenLogs:
        OpenFolder(config_.LogsDir());
        break;

    case kAutostart:
        config_.startAtLogin = !config_.startAtLogin;
        SetStartAtLogin(config_.startAtLogin);
        config_.Save(DefaultConfigPath());
        break;

    case kArchive:
        config_.archiveRaw = !config_.archiveRaw;
        config_.Save(DefaultConfigPath());
        break;

    case kSetWow: {
        const std::string picked =
            PickFolder("Select the World of Warcraft flavor folder "
                       "(the one containing Logs and Interface)");
        if (picked.empty()) break;

        Config probe = config_;
        probe.wowPath = picked;
        if (probe.IsValid()) {
            config_.wowPath = picked;
            config_.Save(DefaultConfigPath());
            SetStatus("folder changed - processing...");
            if (!busy_) std::thread([this] { RunGenerator(); }).detach();
        } else {
            ShowMessage("CombatSession",
                        "That folder does not contain both Logs and "
                        "Interface/AddOns.\n\nPick the flavor folder itself, "
                        "usually named _retail_.",
                        true);
        }
        break;
    }

    case kSetSound: {
        const std::string picked = PickSoundFile(config_.reloadSound);
        if (!picked.empty()) {
            config_.reloadSound = picked;
            config_.Save(DefaultConfigPath());
            PlaySoundFile(config_.reloadSound);   // so the choice is audible
        }
        break;
    }

    case kQuit:
        // A parse already under way still has to finish before the watcher
        // thread can be joined. Saying so costs nothing and stops a slow exit
        // looking like a hang.
        SetStatus("quitting...");
        quitting_ = true;
        if (host_) host_->Quit();
        break;

    default:
        break;
    }
}

int TrayApp::Run() {
    std::unique_ptr<TrayHost> host = CreateTrayHost(*this);
    if (!host) return 1;
    host_ = host.get();

    watcher_ = std::thread([this] { WatchLoop(); });

    const int code = host->Run();

    quitting_ = true;
    if (watcher_.joinable()) watcher_.join();

    host_ = nullptr;
    return code;
}

} // namespace

//------------------------------------------------------------------------------

// Asks for the flavor folder outside any window of ours.
//
// Exposed because the first run has to ask before the tray exists: detection
// covers the usual install locations, and when it comes up empty the honest
// alternative to asking is an icon that silently does nothing.
std::string PromptForWowFolder() {
    return PickFolder("Select the World of Warcraft flavor folder "
                      "(the one containing Logs and Interface)");
}

int RunTray(Config config) {
    // One tray at a time.
    //
    // Two watchers on the same folder is not merely untidy: both would run
    // passes, both would write the queue and the read offsets, and both would
    // sound the reload alert. The lock is held for the life of the process and
    // released by the operating system however it exits, so a crash cannot lock
    // the user out of their own application.
    //
    // The second instance leaves without a word. A dialog would sit there as a
    // live process until someone dismissed it, which is indistinguishable in a
    // process list from the duplicate it was meant to prevent.
    static NamedLock instance("CombatSessionTray", /*tryOnly=*/true);
    if (!instance.held()) return 0;

    // Keep the login item and the settings file in agreement; the user may have
    // removed the registry value or the LaunchAgent outside the application.
    config.startAtLogin = GetStartAtLogin();

    TrayApp app(std::move(config));
    return app.Run();
}

} // namespace cs
