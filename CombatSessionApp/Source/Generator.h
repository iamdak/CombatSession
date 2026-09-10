// CombatSession :: Generator
//
// Drives the pipeline for one log file, and maintains the generated data addon.
//
// The data addon is a QUEUE, not storage. The application produces chunks, the
// addon consumes them into its own CACHE, and the application then collects the
// consumed ones. Steady state is an empty or near-empty folder.
//
//   App/Binary/Raw/<key>.log.gz     app-owned archive, own limit, never shipped
//   CombatSession_Data/<key>.lua    UNPROCESSED chunks only
//   CombatSession_Data/Index.lua    commit point, written last
//
// Ordering matters. Chunks are written to a temporary name and renamed into
// place, and the .toc and Index.lua are written last. The .toc is what the
// client actually loads, so committing it early would let a half-written chunk
// be parsed as Lua and take the whole data addon down with a syntax error.

#pragma once

#include "SavedVars.h"
#include "Segmenter.h"

#include <cstdint>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace cs {

struct GeneratorOptions {
    std::filesystem::path addonsRoot;   // ...\Interface\AddOns
    std::filesystem::path rawDir;       // App\Binary\Raw
    std::filesystem::path wtfRoot;      // ...\WTF\Account, for addon state

    // Archive retention, in sessions. Independent of the chunk queue: the
    // archive is for external use and reprocessing, and outlives consumption.
    int rawLimit = 200;

    // Safety valve on the queue. Chunks are normally removed once the addon has
    // consumed them, but if the addon never runs they would otherwise grow
    // without bound. The addon only ever processes its newest N anyway, so
    // holding more pending than this serves no purpose.
    int pendingLimit = 100;

    bool archiveRaw = true;

    // Ignore stored per-log read offsets and re-read every log from the start.
    // Needed after a defect in chunk generation, where the sessions themselves
    // are unchanged but their chunks have to be rebuilt.
    bool ignoreLogState = false;
};

struct SessionRecord {
    std::string key;          // stable identity and file name stem
    Session     session;
    std::string character;    // logging character, from AFFILIATION_MINE
    size_t      events = 0;
    size_t      units  = 0;
    bool        archived = false;
};

class Generator {
public:
    explicit Generator(GeneratorOptions options) : opt_(std::move(options)) {}

    // Processes one log from `fromOffset` onward. Returns sessions written.
    //
    // `logClosed` says the file will not grow again, which lets a session still
    // open at end-of-data be emitted as truncated rather than withheld. Logging
    // can stop without a closing ZONE_CHANGE - the recorder disabling it on exit,
    // a manual /combatlog, or a client crash - and without this such a session
    // would be stranded forever.
    size_t ProcessLog(const std::filesystem::path& logPath, uint64_t fromOffset = 0,
                      bool logClosed = false);

    // Collects consumed chunks, applies both limits, then writes the .toc and
    // Index.lua as the final, committing step.
    bool Commit();

    const std::vector<SessionRecord>& Records() const { return records_; }

    // False when the last processed log ended mid-match, meaning it is still
    // being appended to and must not be deleted.
    bool LastLogComplete() const { return lastLogComplete_; }

    // Chunks removed during the last Commit because the addon had consumed them.
    size_t LastCollected() const { return lastCollected_; }

    // True when the last log was skipped because its stored read offset was
    // already at the end of the file. Without surfacing this, a run that does
    // nothing looks identical to a run that found nothing.
    bool LastLogAlreadyRead() const { return lastLogAlreadyRead_; }

private:
    std::filesystem::path DataAddonDir() const;

    bool WriteIndex() const;
    bool WriteToc() const;
    bool WriteRecords() const;
    void CollectConsumed();
    void PruneRaw();
    void PrunePending();
    void LoadExistingRecords();
    bool WriteLogState() const;

    // True when the addon is finished with a session: it holds the cache, or it
    // has declined everything that old. Either way its chunk has no reader left.
    bool Consumed(const std::string& key) const;

    GeneratorOptions opt_;
    bool   loaded_ = false;
    bool   lastLogComplete_ = false;
    bool   lastLogAlreadyRead_ = false;

    // Set when the addon holds nothing and has declined nothing: it has no
    // history at all, so stored read offsets describe data it will never see.
    bool   forceFullRead_ = false;
    size_t lastCollected_ = 0;

    // What the addon says it holds, and the oldest key it still wants. Chunks
    // are collected on the strength of this and nothing else.
    AddonState state_;

    // How far into each log file has already been consumed, so a pass does not
    // re-parse tens of megabytes it has already seen. Keyed by file name.
    // `settled` records that the pass at this size already ran with the log
    // treated as finished. A session ended by end-of-data deliberately leaves
    // the offset at its start so more data can complete it - which means a log
    // that ends mid-match, as one does after a crash, would otherwise be
    // re-parsed from that point on every pass for as long as the application
    // ran, and every later match would pay for it.
    struct LogState { uint64_t offset = 0; uint64_t size = 0; bool settled = false; };
    std::map<std::string, LogState> logs_;

    std::vector<SessionRecord> records_;
};

// Generator passes are serialised across processes by a NamedLock called
// "CombatSessionPass", taken by every caller that runs one.
//
// The tray watcher and a command line are separate processes doing the same
// work on the same files. Two passes at once would each read the log, each
// write chunks, and each write logs.tsv and records.tsv - whichever finished
// last deciding what the read offsets are, silently discarding the other's
// progress. Chunk writes are atomic on their own, so the damage is to
// bookkeeping rather than to data, which is the kind that goes unnoticed.

// Stable per-session identity: start time plus instance and round, unchanged if
// the same log is reprocessed.
std::string MakeSessionKey(const Session& session);

// True when a log has not been written to for `settleSeconds`, which is taken to
// mean the client has stopped appending to it.
bool LogLooksClosed(const std::filesystem::path& logPath, int settleSeconds);

} // namespace cs
