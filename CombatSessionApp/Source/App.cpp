// CombatSession :: App
//
// Watches the Logs folder, runs the generator when a log settles, and reports
// what it found through the window and the notification icon.
//
// Portable. Everything that used to make this file Windows-only - the window,
// the icon, the menu, the pickers, the noise - sits behind Shell.h and
// Platform.h. What is left is the part that was never about an operating
// system: when to run a pass, what the result means, and what to say about it.

#include "App.h"

#include "Generator.h"
#include "Platform.h"
#include "SavedVars.h"
#include "Shell.h"
#include "Version.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace cs {
namespace {

using Clock = std::chrono::steady_clock;

// Where each half is published. Compiled in rather than configurable: they are
// the addresses of this project, and a setting that lets something else point
// the update prompt somewhere is a setting worth not having.
constexpr const char* kAddonUrl = "https://www.curseforge.com/wow/addons/combatsession";
constexpr const char* kAppUrl   = "https://github.com/iamdak/CombatSession";

// The addon's requirement, read out of its .toc.
//
// This is the authoritative side of the handshake and the only one that is
// current. The addon also writes the number into its saved variables, but the
// client writes that file at the START of a reload, from the state as it was
// BEFORE the new files loaded - so a freshly installed addon's requirement does
// not reach disk until the reload after the one that installed it. For one
// whole session the addon warns the user and this application, reading the
// stale file, sees nothing to warn about.
//
// The .toc has no such lag. It is what is installed, it says so the moment it
// is installed, and it does not need the addon to have loaded even once - which
// also means a disabled addon still states what it would need.
//
// Returns empty when the file is not there, which is not a mismatch: it means
// the addon is not installed in the folder being watched.
std::string ReadAddonRequirement(const fs::path& addonsRoot) {
    std::ifstream in(addonsRoot / "CombatSession" / "CombatSession.toc");
    if (!in) return {};

    constexpr const char* kKey = "## X-CombatSession-App:";
    const size_t keyLength = std::strlen(kKey);

    std::string line;
    while (std::getline(in, line)) {
        if (line.compare(0, keyLength, kKey) != 0) continue;

        std::string value = line.substr(keyLength);
        // The client is relaxed about spacing here and so is this. A .toc saved
        // on Windows also carries the carriage return that getline leaves.
        const size_t first = value.find_first_not_of(" \t\r\n");
        if (first == std::string::npos) return {};
        const size_t last = value.find_last_not_of(" \t\r\n");
        return value.substr(first, last - first + 1);
    }
    return {};
}

class App : public AppController {
public:
    int Run();

    // AppController
    std::vector<MenuItem> BuildMenu(bool compact) override;
    void OnCommand(int id) override;
    Config& Settings() override { return config_; }
    void SettingsChanged() override;
    std::string StatusText() const override;
    bool Busy() const override { return busy_.load(); }
    VersionStatus Versions() const override;

private:
    void SetStatus(std::string text);
    void SetState(TrayState state);
    void Publish();

    void RefreshVersions();
    void OfferAppUpdate();

    void WatchLoop();
    uint64_t WatchFingerprint() const;
    bool     AddonHasSeenQueue() const;
    void RunGenerator();
    void RunGeneratorAsync();
    void RebuildAll();
    void Alert(bool firstTime);
    void Wake();

    Config     config_;
    ShellHost* shell_ = nullptr;

    std::atomic<TrayState> state_{ TrayState::Idle };

    std::thread       watcher_;
    std::atomic<bool> quitting_{ false };
    std::atomic<bool> busy_{ false };
    std::atomic<bool> dirty_{ false };
    std::atomic<bool> openSession_{ false };
    // Set when the folder changes, so the watcher starts over rather than
    // comparing a fingerprint taken from a different installation.
    std::atomic<bool> restart_{ false };

    // Waking the watcher out of its poll. Without this a quit, or a settings
    // change, would sit there until the next tick - which at a five second
    // poll is a visible pause and at the maximum is most of a coffee break.
    std::mutex              wakeMutex_;
    std::condition_variable wake_;

    // When the reload alert last sounded, for the repeating mode.
    Clock::time_point lastAlert_{};

    // The only two settings the watcher's own state depends on, as they were
    // when it last started over. Compared on a settings change so that ticking
    // a checkbox does not restart a watcher that is watching the same folder on
    // the same interval it was a moment ago.
    std::string watchedPath_;
    int         watchedPoll_ = 0;

    mutable std::mutex statusMutex_;
    std::string        status_ = "starting";

    // What the addon asks for against what this is, recomputed whenever the
    // addon might have saved. Guarded because the watcher recomputes it and the
    // interface reads it.
    mutable std::mutex versionMutex_;
    VersionStatus      versions_;

    // So the error sound marks the arrival of a mismatch rather than every
    // pass that finds one still there. A flashing icon is a state and can go on
    // saying so indefinitely; a noise is an event and has to be one.
    VersionState       announced_ = VersionState::Unknown;
};

//------------------------------------------------------------------------------

std::string App::StatusText() const {
    std::lock_guard<std::mutex> lock(statusMutex_);
    return status_;
}

void App::SetStatus(std::string text) {
    {
        std::lock_guard<std::mutex> lock(statusMutex_);
        status_ = std::move(text);
    }
    Publish();
}

void App::SetState(TrayState state) {
    // Compared before publishing so an unchanged state costs nothing: the
    // watcher would otherwise repaint the interface on every tick.
    if (state_.exchange(state) == state) return;
    Publish();
}

// Cuts the watcher's poll short, for anything that should not wait for the next
// tick: quitting, and a settings change that makes what it is watching wrong.
void App::Wake() {
    std::lock_guard<std::mutex> lock(wakeMutex_);
    wake_.notify_all();
}

void App::Publish() {
    if (shell_) shell_->Update(state_.load(), StatusText());
}

// The one noise this application makes, and only when asked to.
//
// It exists because a reload is the single state the program cannot resolve on
// its own: the data is written and safe, and only the user can make the client
// pick it up. Everything else resolves itself and stays silent.
void App::Alert(bool firstTime) {
    if (!config_.soundEnabled) return;
    if (!firstTime && config_.alertRepeat != AlertRepeat::Every) return;

    lastAlert_ = Clock::now();
    if (config_.reloadSound.empty()) PlayDefaultAlert();
    else                             PlaySoundFile(config_.reloadSound);
}

//------------------------------------------------------------------------------
// Versions
//------------------------------------------------------------------------------

VersionStatus App::Versions() const {
    std::lock_guard<std::mutex> lock(versionMutex_);
    return versions_;
}

// Compares what the installed addon says it needs against what this is.
//
// The addon's answer arrives through its saved variables, which the client
// rewrites at logout, reload and exit - so this is only ever as current as the
// last of those. That is the right latency: an addon updated while the game is
// running has not been loaded yet either, and announcing a mismatch against
// files the client has not read would be announcing something that is not true
// until the next reload.
void App::RefreshVersions() {
    VersionStatus next;
    next.running = VersionText(kAppVersion);

    const VersionCode running = kAppVersion;
    VersionCode expected = 0;
    if (config_.IsValid()) {
        expected = ParseVersion(ReadAddonRequirement(config_.AddOnsDir()));

        // The saved variables carry the same number, and are the fallback for
        // an addon whose .toc could not be read - installed under a renamed
        // folder, or a future layout this does not know about. Stale by up to
        // one reload, which is why it is second and not first.
        if (expected == 0) {
            expected = ParseVersion(ReadAddonState(config_.WtfRoot()).appExpected);
        }
    }
    next.expected = VersionText(expected);

    if (expected == 0) {
        // No addon has saved yet. Says nothing either way, and must not: a
        // fresh install spends its first session here and being shouted at
        // before anything has gone wrong is how a warning stops being read.
        next.state     = VersionState::Unknown;
        next.addonLine = "Addon version not known yet.";
        next.appLine   = "Application up to date.";
    } else if (expected == running) {
        next.state     = VersionState::Match;
        next.addonLine = "Addon up to date.";
        next.appLine   = "Application up to date.";
    } else if (expected < running) {
        next.state     = VersionState::AddonOutdated;
        next.addonLine = "Addon requires update.";
        next.appLine   = "Application up to date.";
        next.banner    = "The addon is out of date. It was written for "
                         "CombatSession " + next.expected + ", and this is "
                         + next.running + ".";
    } else {
        next.state     = VersionState::AppOutdated;
        next.addonLine = "Addon up to date.";
        next.appLine   = "Application requires update.";
        next.banner    = "This application is out of date. The addon needs "
                         "CombatSession " + next.expected + ", and this is "
                         + next.running + ".";
    }

    {
        std::lock_guard<std::mutex> lock(versionMutex_);
        versions_ = next;
    }

    // Sounded on the way in, once. announced_ is only touched here, and this
    // runs on the watcher thread or before it starts, never both at once.
    if (IsMismatch(next.state) && next.state != announced_) PlayErrorAlert();
    announced_ = next.state;

    Publish();
}

// The one update that cannot be done while the thing being updated is running.
//
// An addon is files in a folder the game reads at load, so replacing it needs
// nothing from this program. The application is this program: the file is
// locked while it runs, so the only honest offer is to get out of the way -
// which is what the third step does, and why it is spelled out before it
// happens rather than after.
void App::OfferAppUpdate() {
    const fs::path exe    = ExecutablePath();
    const std::string name = exe.filename().string();

    const std::string text =
        "The addon needs a newer version of CombatSession than the one you "
        "are running.\n\n"
        "Clicking OK will:\n"
        "    1.  Open the download page in your browser.\n"
        "    2.  Open the folder CombatSession is running from.\n"
        "    3.  Close CombatSession.\n\n"
        "Then, to finish the update:\n"
        "    4.  Download the new version from the page.\n"
        "    5.  In the folder that opened, delete " + name + ".\n"
        "    6.  Put the new " + name + " in its place.\n"
        "    7.  Start CombatSession again.\n\n"
        "Your settings and your archived sessions are kept. They are stored "
        "separately from the program, so replacing it does not touch them.\n\n"
        "Click Cancel to leave everything as it is.";

    if (!ConfirmAction("Update CombatSession", text)) return;

    OpenUrl(kAppUrl);
    OpenFolder(exe.parent_path());

    quitting_ = true;
    Wake();
    if (shell_) shell_->Quit();
}

//------------------------------------------------------------------------------

void App::RunGenerator() {
    if (!config_.IsValid()) {
        SetStatus("no World of Warcraft folder set");
        SetState(TrayState::Idle);
        return;
    }

    if (busy_.exchange(true)) return;   // a pass is already running here

    // Read BEFORE the pass marks itself Working, which overwrites the very
    // thing this is asking about. Taken at the end instead, it was always false
    // - the state was Working by then, never NeedsReload - so every pass that
    // finished with sessions outstanding announced itself as a first-time
    // arrival and sounded the alert, whatever the once-or-repeat setting said.
    // Toggling any option runs a pass, which is why a checkbox made a noise.
    const bool wasWaiting = (state_.load() == TrayState::NeedsReload);

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

    const size_t pending = generator.Records().size();
    if (pending == 0) {
        SetStatus(added > 0
            ? (std::to_string(added) + " new session(s), all consumed")
            : std::string("up to date"));
        SetState(TrayState::Idle);
    } else if (AddonHasSeenQueue()) {
        // Delivered and loaded; the chunks are only still here because the
        // addon has not written its record yet. Nothing for the user to do.
        SetStatus(std::to_string(pending)
                  + " session(s) delivered - queue clears on next save");
        SetState(TrayState::Idle);
    } else {
        // Chunks are written and the archive has them; the addon simply cannot
        // see a file that appeared after the client loaded. Red asks for the one
        // thing the application cannot do for itself.
        SetStatus(std::to_string(pending) + " session(s) waiting - /reload in game");

        SetState(TrayState::NeedsReload);

        // The first arrival always counts. A later one counts only when the
        // user asked to hear about each session, and only when this pass
        // actually produced one - a pass run because the addon saved, or
        // because a setting changed, adds nothing and must stay quiet.
        const bool arrived = !wasWaiting
                          || (config_.alertOnNewSessions && added > 0);
        Alert(arrived);
    }

    busy_ = false;
    Publish();

    // After the pass, because the pass has just rewritten Index.lua with this
    // application's version and because the thing that most often triggers a
    // pass is the addon writing its saved variables - which is exactly when its
    // answer changes.
    RefreshVersions();
}

// A large battleground takes seconds to parse and must not stall the interface.
void App::RunGeneratorAsync() {
    if (busy_) return;
    std::thread([this] { RunGenerator(); }).detach();
}

// Discards every stored read offset so the next pass re-reads every log from
// the beginning. Only ever the right thing after the addon's data format has
// changed, and minutes of work on a large Logs folder, so it is a deliberate
// action rather than something that happens on its own.
void App::RebuildAll() {
    if (busy_ || !config_.IsValid()) return;

    if (!Confirm("Rebuild all data",
                 "Every combat log will be read again from the beginning.\n\n"
                 "On a large Logs folder this takes several minutes, and it is "
                 "only worth doing after the addon's data format has changed.\n\n"
                 "Continue?")) {
        return;
    }

    // The read offsets live beside the archive, not beside the executable.
    // Removing the file is what makes the next pass start from nothing.
    std::error_code ec;
    fs::remove(config_.RawDir() / "logs.tsv", ec);
    RunGeneratorAsync();
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
bool App::AddonHasSeenQueue() const {
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
// that queued chunks have become collectable - and without it the icon went on
// asking for a reload after the reload that had already done the job, because
// nothing else had changed so no pass ran so nothing looked.
uint64_t App::WatchFingerprint() const {
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

    // The addon's own manifest, so installing or updating the addon is noticed
    // on its own account. Without it the version check only ran when something
    // else happened to trigger a pass, and a user who updated their addon
    // between matches could sit in front of a program that had not looked.
    Add(config_.AddOnsDir() / "CombatSession" / "CombatSession.toc");

    return stamp;
}

void App::WatchLoop() {
    // An initial pass catches anything written while the application was not
    // running - but only if there is somewhere to look.
    if (config_.IsValid()) RunGenerator();
    else                   SetStatus("no World of Warcraft folder set");

    uint64_t seen = config_.IsValid() ? WatchFingerprint() : 0;
    auto lastChange = Clock::now();

    while (!quitting_) {
        {
            // Interruptible: a quit or a settings change should not wait out
            // the poll interval, which the user can set as high as five
            // minutes.
            std::unique_lock<std::mutex> lock(wakeMutex_);
            wake_.wait_for(lock, std::chrono::seconds(config_.pollSeconds),
                           [this] { return quitting_.load() || restart_.load(); });
        }
        if (quitting_) break;

        // The folder was set or changed while running, so everything the loop
        // knows is about a different installation.
        if (restart_.exchange(false)) {
            if (config_.IsValid()) {
                RunGenerator();
                seen = WatchFingerprint();
            } else {
                SetStatus("no World of Warcraft folder set");
                SetState(TrayState::Idle);
                // Nowhere to read an addon from any more, so whatever was
                // being said about versions is about a folder that is no
                // longer the one in use.
                RefreshVersions();
            }
            lastChange = Clock::now();
            continue;
        }

        if (!config_.IsValid()) continue;   // inert, by the user's choice

        const uint64_t now = WatchFingerprint();
        if (now != seen) {
            seen = now;
            dirty_ = true;
            lastChange = Clock::now();
            SetStatus("change detected...");
        }

        const auto quiet = Clock::now() - lastChange;

        // The client appends continuously during a match, so processing waits
        // until the log has been quiet for settleSeconds. That turns a burst of
        // writes into a single pass once the match is over.
        if (dirty_ && quiet >= std::chrono::seconds(config_.settleSeconds)) {
            dirty_ = false;
            RunGenerator();
            lastChange = Clock::now();
            continue;
        }

        // Still waiting on a reload, and the user asked to be reminded.
        if (state_.load() == TrayState::NeedsReload
            && config_.soundEnabled
            && config_.alertRepeat == AlertRepeat::Every
            && Clock::now() - lastAlert_ >= std::chrono::seconds(config_.repeatSeconds)) {
            Alert(false);
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
            lastChange = Clock::now();
        }
    }
}

//------------------------------------------------------------------------------

std::vector<MenuItem> App::BuildMenu(bool compact) {
    std::vector<MenuItem> menu;

    MenuItem status;
    status.id      = kCmdStatus;
    status.label   = StatusText();
    status.enabled = false;
    menu.push_back(status);

    // A mismatch is the one thing worth saying in a five-item menu, and on a
    // shell with no window of its own this is the only place it can be said.
    const VersionStatus versions = Versions();
    if (IsMismatch(versions.state)) {
        MenuItem warning;
        warning.id      = kCmdStatus;
        warning.label   = versions.state == VersionState::AddonOutdated
                        ? "Addon requires update" : "Application requires update";
        warning.enabled = false;
        menu.push_back(warning);
        menu.push_back({ kCmdAddonPage, "Get the Addon (CurseForge)...",
                         true, false, false });
        menu.push_back({ kCmdAppPage, "Get the Application (GitHub)...",
                         true, false, false });
    }

    menu.push_back(MenuItem::Divider());

    const bool valid = config_.IsValid();
    menu.push_back({ kCmdProcessNow, "&Process Now", valid && !busy_, false, false });
    menu.push_back({ kCmdOpenData,   "Open &Data Folder", valid, false, false });
    menu.push_back({ kCmdOpenLogs,   "Open &Log Folder",  valid, false, false });

    // Only where there is no window carrying them. On Windows every one of
    // these is a control the user can see and read a label for, and repeating
    // them in a menu would mean two places to change the same thing.
    if (!compact) {
        menu.push_back(MenuItem::Divider());
        menu.push_back({ kCmdSetWowPath, "Set World of Warcraft Folder...",
                         true, false, false });
        menu.push_back({ kCmdSetSound, "Reload Sound...", true, false, false });
    }

    menu.push_back(MenuItem::Divider());
    menu.push_back({ kCmdQuit, "&Quit", true, false, false });
    return menu;
}

void App::OnCommand(int id) {
    switch (id) {
    case kCmdProcessNow:
        RunGeneratorAsync();
        break;

    case kCmdOpenData:
        OpenFolder(config_.AddOnsDir() / "CombatSession_Data");
        break;

    case kCmdOpenLogs:
        OpenFolder(config_.LogsDir());
        break;

    case kCmdSetWowPath: {
        std::string picked = config_.wowPath;
        if (!PromptForWowFolder(picked) || picked.empty()) break;
        config_.wowPath = picked;
        SettingsChanged();
        break;
    }

    case kCmdSetSound: {
        const std::string picked = PickSoundFile(config_.reloadSound);
        if (picked.empty()) break;
        config_.reloadSound = picked;
        SettingsChanged();
        PlaySoundFile(config_.reloadSound);   // so the choice is audible
        break;
    }

    case kCmdUseDefaultSound:
        config_.reloadSound.clear();
        SettingsChanged();
        PlayDefaultAlert();
        break;

    case kCmdRebuildAll:
        RebuildAll();
        break;

    case kCmdAddonPage:
        // Always the page, whichever way round the mismatch is. Someone
        // checking whether there is a newer addon is entitled to go and look
        // without this program deciding they do not need to.
        OpenUrl(kAddonUrl);
        break;

    case kCmdAppPage:
        if (Versions().state == VersionState::AppOutdated) OfferAppUpdate();
        else                                               OpenUrl(kAppUrl);
        break;

    case kCmdQuit:
        quitting_ = true;
        Wake();
        if (shell_) shell_->Quit();
        break;

    default:
        break;
    }
}

void App::SettingsChanged() {
    // The login item is the only setting that lives outside this file, so it is
    // the only one that has to be pushed anywhere. Always rewritten when on, so
    // it points at the copy of the application the user is actually running.
    SetStartAtLogin(config_.startAtLogin);

    config_.Save(DefaultConfigPath());

    // A changed folder invalidates everything the watcher has been comparing,
    // and a changed poll interval should take effect now rather than after the
    // old one elapses. Nothing else here is any of the watcher's business.
    //
    // This used to restart unconditionally, so every checkbox kicked off a full
    // pass: the status line flicked to "processing...", Process Now and Rebuild
    // All Data greyed out for as long as it took, and the alert sounded. The
    // pass was at least never a reprocess - it resumed from each log's stored
    // read offset like any other - but it was work nobody asked for.
    const bool watchChanged = (config_.wowPath != watchedPath_)
                           || (config_.pollSeconds != watchedPoll_);
    watchedPath_ = config_.wowPath;
    watchedPoll_ = config_.pollSeconds;

    if (watchChanged) {
        restart_ = true;
        Wake();
    }
    Publish();
}

//------------------------------------------------------------------------------

int App::Run() {
    const fs::path settings = DefaultConfigPath();
    const bool firstRun = !config_.Load(settings);

    // The one question the application cannot start without, asked before any
    // other window exists so it is the first thing on screen.
    if (firstRun) {
        std::string picked;
        if (PromptForWowFolder(picked) && !picked.empty()) {
            config_.wowPath = picked;
        }
        config_.Save(settings);
    }

    // The filesystem is the truth about the login item - the user may have
    // deleted the shortcut themselves - and when it is on it is rewritten, so a
    // copy of this application somewhere else cannot leave a stale entry.
    config_.startAtLogin = GetStartAtLogin();
    if (config_.startAtLogin) SetStartAtLogin(true);

    // Seeded from what the watcher is about to start with, so the first
    // settings change is compared against reality rather than against an empty
    // path it would always differ from.
    watchedPath_ = config_.wowPath;
    watchedPoll_ = config_.pollSeconds;

    // Before the window is built, because a mismatch overrules the start
    // minimized setting - and a window cannot decide whether to appear after it
    // has already decided not to.
    RefreshVersions();

    std::unique_ptr<ShellHost> shell = CreateShell(*this);
    if (!shell) return 1;
    shell_ = shell.get();

    Publish();
    watcher_ = std::thread([this] { WatchLoop(); });

    const int code = shell->Run();

    quitting_ = true;
    Wake();
    if (watcher_.joinable()) watcher_.join();

    shell_ = nullptr;
    return code;
}

} // namespace

//------------------------------------------------------------------------------

int RunApp() {
    // One at a time.
    //
    // Two watchers on the same folder is not merely untidy: both would run
    // passes, both would write the queue and the read offsets, and both would
    // sound the reload alert. The lock is held for the life of the process and
    // released by the operating system however it exits, so a crash cannot lock
    // the user out of their own application.
    static NamedLock instance("CombatSessionApp", /*tryOnly=*/true);
    if (!instance.held()) return 0;

    App app;
    return app.Run();
}

} // namespace cs
