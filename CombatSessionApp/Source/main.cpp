// CombatSession :: entry point
//
// With no arguments the application runs as a tray shell. With arguments it
// behaves as a one-shot console tool, which is what the tray path calls into
// and what makes the pipeline testable without any UI.
//
// Built as a console application on Windows, and that is the deliberate half of
// the decision there. Whether a shell waits for a process is decided by the
// subsystem recorded in the executable header and by nothing the program can do
// at runtime, so a windowed binary can never block a command line - it returned
// to the prompt and printed its output afterwards, into whatever had scrolled
// past.
//
// The cost is that Windows hands every console process a console. Background
// mode therefore gives it straight back, before anything is drawn to it, as the
// first thing main does. On macOS none of this arises: a process run from a
// shell blocks because the shell waits for it, and one launched from Finder or
// a LaunchAgent has no terminal to give back.

#include "App.h"
#include "Config.h"
#include "Generator.h"
#include "Platform.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

void Usage() {
    std::puts(
        "CombatSession\n"
        "\n"
        "  CombatSession                 run in the status area (default)\n"
        "  CombatSession --once          process everything, then exit\n"
        "\n"
        "  --wow <path>      flavor folder, the one named _retail_\n"
        "                    detected automatically when omitted\n"
        "  --log <file>      process one specific log\n"
        "  --max <n>         raw archive retention, in sessions (default 200)\n"
        "  --no-archive      skip the Raw archive; reparsing becomes impossible\n"
        "  --list            report what would be processed, write nothing\n"
        "  --reprocess       re-read every log from the start and rebuild chunks\n");
}

// Combat logs are WoWCombatLog-MMDDYY_HHMMSS.txt, so a lexical sort within a
// year is chronological. The newest is assumed to be the one the client still
// holds open and is never a deletion candidate.
std::vector<fs::path> FindLogs(const fs::path& logsDir) {
    std::vector<fs::path> logs;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(logsDir, ec)) {
        const std::string name = entry.path().filename().string();
        if (name.rfind("WoWCombatLog", 0) == 0 && entry.path().extension() == ".txt") {
            logs.push_back(entry.path());
        }
    }
    std::sort(logs.begin(), logs.end());
    return logs;
}

int RunOnce(cs::Config& config, const fs::path& singleLog, bool listOnly,
            bool reprocess) {
    // A command line and a running tray are two processes doing the same work on
    // the same files. Without this they interleave, and whichever finished last
    // would decide what the stored read offsets are.
    cs::NamedLock pass("CombatSessionPass");

    const fs::path logsDir = config.LogsDir();

    std::vector<fs::path> logs;
    if (!singleLog.empty()) logs.push_back(singleLog);
    else                    logs = FindLogs(logsDir);

    if (logs.empty()) {
        std::puts("no combat logs found - is combat logging enabled in game?");
        return 0;
    }

    if (listOnly) {
        std::error_code ec;
        for (const auto& log : logs) {
            std::printf("%-48s %10llu bytes\n", log.filename().string().c_str(),
                        (unsigned long long)fs::file_size(log, ec));
        }
        return 0;
    }

    cs::GeneratorOptions options;
    options.addonsRoot   = config.AddOnsDir();
    options.rawDir       = config.RawDir();
    options.wtfRoot      = config.WtfRoot();
    options.rawLimit     = config.rawLimit;
    options.pendingLimit = config.pendingLimit;
    options.archiveRaw   = config.archiveRaw;
    options.ignoreLogState   = reprocess;

    cs::Generator generator(options);

    size_t total = 0, skipped = 0;

    for (const auto& log : logs) {
        const bool closed = cs::LogLooksClosed(log, config.closedAfterSeconds);
        const size_t n = generator.ProcessLog(log, 0, closed);
        total += n;

        const char* note = "";
        if (generator.LastLogAlreadyRead()) {
            note = "  (already read)";
            ++skipped;
        } else if (!closed) {
            note = "  (still being written)";
        }
        std::printf("%-48s %zu new session(s)%s\n",
                    log.filename().string().c_str(), n, note);

    }

    if (!generator.Commit()) {
        std::puts("failed writing the generated data addon");
        return 1;
    }

    std::printf("\n%zu new session(s); %zu chunk(s) pending, %zu collected\n",
                total, generator.Records().size(), generator.LastCollected());

    // A run that read nothing looks identical to one that found nothing, which
    // is exactly the confusion this reports its way out of.
    if (total == 0 && skipped == logs.size() && !reprocess) {
        std::puts("\nevery log was already read to the end. To rebuild from "
                  "scratch\nafter clearing the addon data, run again with "
                  "--reprocess.");
    }
    return 0;
}

} // namespace

int main(int argc, char** argv) {
    // First thing, before anything can be drawn to it. With arguments the
    // console is kept and the shell waits for us; without, it goes back.
    if (argc <= 1) cs::ReleaseConsole();

    cs::Config config;
    const fs::path settings = cs::DefaultConfigPath();

    // A missing settings file is a first run, not an error. Defaults are written
    // straight away - including a sound - so there is something on disk to edit
    // even if everything after this goes wrong.
    const bool firstRun = !config.Load(settings);
    if (firstRun) {
        config.reloadSound = cs::DefaultAlertSound();
        config.wowPath     = cs::Config::DetectWowPath();
        config.Save(settings);
    }

    fs::path singleLog;
    bool once = false, listOnly = false, sawArgs = false, reprocess = false;

    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        sawArgs = true;
        auto next = [&]() -> std::string {
            return (i + 1 < argc) ? argv[++i] : std::string{};
        };
        if      (arg == "--wow")        config.wowPath = next();
        else if (arg == "--log")      { singleLog = next(); once = true; }
        else if (arg == "--max")        config.rawLimit = std::atoi(next().c_str());
        else if (arg == "--no-archive") config.archiveRaw = false;
        else if (arg == "--once")       once = true;
        else if (arg == "--reprocess") { reprocess = true; once = true; }
        else if (arg == "--list")     { listOnly = true; once = true; }
        else { Usage(); return 1; }
    }

    if (config.wowPath.empty()) config.wowPath = cs::Config::DetectWowPath();

    if (!config.IsValid()) {
        const std::string message =
            "Could not find a World of Warcraft installation.\n\n"
            "Run with --wow \"<path to _retail_>\" once, and it will be remembered.";

        if (sawArgs) {
            std::puts(message.c_str());
            return 1;
        }

        // Detection covers the usual install locations. When it comes up empty
        // the honest alternative to asking is a status icon that sits there
        // doing nothing, so ask - once, and only when there is a user to ask.
        cs::ShowMessage("CombatSession",
            "CombatSession could not find your World of Warcraft installation.\n\n"
            "Choose the flavor folder next - the one containing Logs and "
            "Interface, usually named _retail_.",
            false);

        const std::string picked = cs::PromptForWowFolder();
        if (!picked.empty()) config.wowPath = picked;

        if (!config.IsValid()) {
            cs::ShowMessage("CombatSession", message, true);
            return 1;
        }
    }

    config.Save(settings);

    if (once || listOnly) return RunOnce(config, singleLog, listOnly, reprocess);

    return cs::RunTray(std::move(config));
}
