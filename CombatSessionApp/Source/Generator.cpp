#include "Generator.h"

#include "Archive.h"
#include "SavedVars.h"
#include "StreamWriter.h"
#include "Version.h"


#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <chrono>
#include <fstream>

namespace fs = std::filesystem;

namespace cs {
namespace {

constexpr const char* kDataAddon  = "CombatSession_Data";
constexpr const char* kIndexFile  = "Index.lua";
constexpr const char* kInterface  = "120100";
constexpr const char* kArchiveExt = ".log.gz";

// App state, kept beside the archive. Never read by the client.
constexpr const char* kRecordsFile = "records.tsv";

// How far each log file has been consumed. Lives beside the archive so that
// wiping the archive also resets reading position, keeping the two consistent.
constexpr const char* kLogStateFile = "logs.tsv";

std::tm LocalTime(Timestamp ms) {
    const std::time_t s = static_cast<std::time_t>(ms / 1000);
    std::tm tm{};
    localtime_s(&tm, &s);
    return tm;
}

// Writes through a temporary file and renames into place, so a crash or a
// concurrent client load can never observe a partially written file.
bool WriteAtomic(const fs::path& path, const std::string& content) {
    const fs::path temp = path.string() + ".tmp";
    {
        std::ofstream out(temp, std::ios::binary);
        if (!out) return false;
        out.write(content.data(), static_cast<std::streamsize>(content.size()));
        if (!out.good()) return false;
    }
    std::error_code ec;
    fs::rename(temp, path, ec);
    if (ec) {
        // rename fails if the destination exists on some configurations.
        fs::remove(path, ec);
        fs::rename(temp, path, ec);
    }
    return !ec;
}

std::string QuoteLua(const std::string& text) {
    std::string out = "\"";
    for (const char c : text) {
        if (c == '"' || c == '\\') out += '\\';
        out += c;
    }
    return out + "\"";
}

} // namespace

std::string MakeSessionKey(const Session& session) {
    const std::tm tm = LocalTime(session.startTime);
    char buf[64];
    std::snprintf(buf, sizeof buf, "%04d%02d%02d_%02d%02d%02d_%d_%d",
                  tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday,
                  tm.tm_hour, tm.tm_min, tm.tm_sec,
                  session.instanceId, session.roundIndex);
    return buf;
}

bool LogLooksClosed(const fs::path& logPath, int settleSeconds) {
    std::error_code ec;
    const auto written = fs::last_write_time(logPath, ec);
    if (ec) return true;   // unreadable timestamp: treat as finished

    const auto age = fs::file_time_type::clock::now() - written;
    return age > std::chrono::seconds(settleSeconds);
}

fs::path Generator::DataAddonDir() const {
    return opt_.addonsRoot / kDataAddon;
}

//------------------------------------------------------------------------------

size_t Generator::ProcessLog(const fs::path& logPath, uint64_t fromOffset,
                             bool logClosed) {
    LoadExistingRecords();

    lastLogAlreadyRead_ = false;
    const std::string logName = logPath.filename().string();
    std::error_code sizeEc;
    const uint64_t fileSize = fs::file_size(logPath, sizeEc);

    // Resume where the previous pass stopped. A file that has shrunk was
    // replaced or truncated, so its recorded position is meaningless and the
    // whole thing is read again.
    bool settled = false;
    if (fromOffset == 0 && !opt_.ignoreLogState && !forceFullRead_) {
        const auto it = logs_.find(logName);
        if (it != logs_.end() && !sizeEc && fileSize >= it->second.size) {
            fromOffset = it->second.offset;

            // Nothing appended since the last pass, and that pass already ran
            // with this log treated as finished - so re-reading would find
            // exactly what it found then. Worth checking because a session ended
            // by end-of-data deliberately leaves the offset at its start, and a
            // log that stops mid-match (a crash, a client kill) would otherwise
            // be re-parsed in full on every pass for the life of the process,
            // with every later match paying the cost.
            settled = it->second.settled && fileSize == it->second.size;
        }
    }
    if (!sizeEc && settled && logClosed) {
        lastLogComplete_ = true;
        lastLogAlreadyRead_ = true;
        return 0;
    }
    if (!sizeEc && fromOffset >= fileSize) {
        // Nothing new, but the log may have gone quiet since the last pass with
        // a session left open, so completeness still has to be reported.
        lastLogComplete_ = true;
        lastLogAlreadyRead_ = true;
        return 0;
    }

    std::vector<Session> found;
    {
        std::ifstream in(logPath, std::ios::binary);
        if (!in) return 0;
        in.seekg(static_cast<std::streamoff>(fromOffset));

        Segmenter seg([&](const Session& s) { found.push_back(s); });
        std::string line;
        uint64_t offset = fromOffset;
        LogLine parsed;
        while (std::getline(in, line)) {
            const uint64_t len = line.size() + 1;
            if (ParseLine(line, parsed)) seg.Feed(parsed, offset, len);
            offset += len;
        }
        // While the log may still grow, a session open at end-of-data is
        // withheld: it is probably a match in progress, and emitting it would
        // produce a truncated duplicate once more data arrives.
        //
        // Once the file is known to be finished that reasoning inverts. Logging
        // frequently stops without a closing ZONE_CHANGE - the recorder
        // switching it off as you leave, a manual /combatlog, a crash - and
        // withholding then would strand the session permanently.
        lastLogComplete_ = !seg.HasOpenSession();
        if (logClosed && seg.HasOpenSession()) {
            seg.Finish();
            lastLogComplete_ = true;
        }
    }

    std::error_code ec;
    fs::create_directories(DataAddonDir(), ec);
    if (opt_.archiveRaw) fs::create_directories(opt_.rawDir, ec);

    size_t written = 0;
    for (const auto& session : found) {
        const std::string key = MakeSessionKey(session);

        // A session whose chunk is still queued is normally left alone: it has
        // already been emitted and the addon has not taken it yet.
        //
        // Two exceptions. --reprocess exists to rebuild chunks after a defect in
        // generation, and skipping here meant it re-read every log at length and
        // then rebuilt nothing. And a chunk emitted from a guessed end is
        // replaced as soon as more of the match arrives - without that, the
        // truncated version would hold the key forever and the rest of the match
        // would never be written.
        const auto known = std::find_if(records_.begin(), records_.end(),
            [&](const SessionRecord& r) { return r.key == key; });
        if (known != records_.end()) {
            const bool wasGuessed = known->session.termination == Termination::EndOfData;
            const bool haveMore   = session.endOffset > known->session.endOffset;
            if (!opt_.ignoreLogState && !(wasGuessed && haveMore)) continue;
            records_.erase(known);   // rebuilt below, so the old record goes
        }

        const uint64_t rawLen = session.endOffset - session.startOffset;

        // Archive first and unconditionally: the copy is the source of truth,
        // so a parser defect can never cost data. The archive is kept even for
        // sessions the addon will never see as chunks.
        bool archived = false;
        if (opt_.archiveRaw) {
            archived = WriteGzipSlice(logPath, session.startOffset, rawLen,
                                      opt_.rawDir / (key + kArchiveExt));
        }

        // A session the addon is finished with needs no chunk: emitting one
        // would produce a file it ignores and the next Commit deletes. The
        // session still lives in the archive.
        //
        // Note this is not "older than the last one it took". A session it has
        // moved past but does not hold is one it wants back, and re-emitting
        // the chunk is how a cache that failed to save gets rebuilt.
        if (Consumed(key)) continue;

        StreamWriter writer;
        {
            std::ifstream in(logPath, std::ios::binary);
            if (!in) continue;
            in.seekg(static_cast<std::streamoff>(session.startOffset));
            std::string line;
            LogLine parsed;
            uint64_t consumed = 0;
            while (consumed < rawLen && std::getline(in, line)) {
                consumed += line.size() + 1;
                if (ParseLine(line, parsed)) writer.Feed(parsed);
            }
        }

        // Chunks land under a temporary name and are renamed in, so the client
        // never sees a partial Lua file even if it loads mid-generation.
        const fs::path chunk = DataAddonDir() / (key + ".lua");
        const fs::path temp  = DataAddonDir() / (key + ".lua.tmp");
        if (!writer.Write(temp.string(), key, session)) continue;
        fs::remove(chunk, ec);
        fs::rename(temp, chunk, ec);
        if (ec) { fs::remove(temp, ec); continue; }

        SessionRecord record;
        record.key      = key;
        record.session  = session;
        record.archived = archived;
        record.events    = writer.EventCount();
        record.units     = writer.UnitCount();
        record.character = writer.OwnerName();
        records_.push_back(std::move(record));
        ++written;
    }

    // Advance only as far as the last session that actually closed.
    //
    // A session terminated by EndOfData is a guess: the client buffers the
    // combat log, and a gap between flushes looks exactly like a log that has
    // finished. Measured on a live Deephaul Ravine, the gap reached two minutes
    // while the match was still running - long enough to be mistaken for a
    // finished log, which truncated the session at five minutes and orphaned the
    // remaining 32 MB, because the offset had moved past it.
    //
    // Leaving the offset at that session's start is what makes the guess safe.
    // The next pass re-reads it and emits the complete version, so being wrong
    // costs a re-read rather than the rest of the match.
    uint64_t consumedTo = fromOffset;
    for (const auto& session : found) {
        if (session.termination == Termination::EndOfData) break;
        if (session.endOffset > consumedTo) consumedTo = session.endOffset;
    }
    if (logClosed && !sizeEc && found.empty()) consumedTo = fileSize;

    LogState& state = logs_[logName];
    state.offset = consumedTo;
    state.size   = sizeEc ? consumedTo : fileSize;
    // Set only once the log has been treated as finished at this size. Until
    // then a later pass may still have something to add.
    state.settled = logClosed;

    return written;
}

//------------------------------------------------------------------------------

void Generator::LoadExistingRecords() {
    if (loaded_) return;
    loaded_ = true;

    state_ = ReadAddonState(opt_.wtfRoot);

    {
        std::ifstream in(opt_.rawDir / kLogStateFile);
        std::string line;
        while (in && std::getline(in, line)) {
            const size_t a = line.find('\t');
            if (a == std::string::npos) continue;
            const size_t b = line.find('\t', a + 1);
            if (b == std::string::npos) continue;
            LogState state;
            state.offset = std::strtoull(line.substr(a + 1, b - a - 1).c_str(), nullptr, 10);

            // The settled flag is a later addition, so a file written by an
            // earlier build has two columns and no third tab. Absent means not
            // settled, which is the safe reading: at worst one extra pass.
            const size_t c = line.find('\t', b + 1);
            if (c == std::string::npos) {
                state.size = std::strtoull(line.substr(b + 1).c_str(), nullptr, 10);
            } else {
                state.size    = std::strtoull(line.substr(b + 1, c - b - 1).c_str(), nullptr, 10);
                state.settled = (line.substr(c + 1) == "1");
            }
            logs_[line.substr(0, a)] = state;
        }
    }

    std::vector<SessionRecord> sidecar;
    {
        std::ifstream in(opt_.rawDir / kRecordsFile);
        std::string line;
        while (in && std::getline(in, line)) {
            std::vector<std::string> cols;
            size_t start = 0;
            for (size_t i = 0; i <= line.size(); ++i) {
                if (i == line.size() || line[i] == '\t') {
                    cols.push_back(line.substr(start, i - start));
                    start = i + 1;
                }
            }
            if (cols.size() < 16) continue;

            SessionRecord r;
            r.key      = cols[0];
            r.events   = std::strtoull(cols[1].c_str(), nullptr, 10);
            r.units    = std::strtoull(cols[2].c_str(), nullptr, 10);
            r.archived = cols[3] == "1";

            Session& s = r.session;
            s.startTime  = std::strtoll(cols[4].c_str(), nullptr, 10) * 1000;
            s.endTime    = std::strtoll(cols[5].c_str(), nullptr, 10) * 1000;
            s.type       = static_cast<SessionType>(std::atoi(cols[6].c_str()));
            s.instanceId = std::atoi(cols[7].c_str());
            s.uiMapId    = std::atoi(cols[8].c_str());
            s.rated      = cols[9] == "1";
            s.termination = (cols[10] == "1") ? Termination::LoggingReset
                                              : Termination::CleanEnd;
            s.lobbyIndex     = std::atoi(cols[11].c_str());
            s.roundIndex     = std::atoi(cols[12].c_str());
            s.combatantCount = std::atoi(cols[13].c_str());
            s.bracket = cols[14];
            s.mapName = cols[15];
            // Added after the first sidecar format; older rows simply lack it.
            if (cols.size() >= 17) r.character = cols[16];
            sidecar.push_back(std::move(r));
        }
    }

    // Chunk files on disk are the authority on what is pending; the sidecar
    // only supplies their metadata. A chunk deleted by hand simply disappears.
    std::error_code ec;
    for (const auto& file : fs::directory_iterator(DataAddonDir(), ec)) {
        if (file.path().extension() != ".lua") continue;
        if (file.path().filename() == kIndexFile) continue;

        SessionRecord record;
        record.key = file.path().stem().string();

        const auto known = std::find_if(sidecar.begin(), sidecar.end(),
            [&](const SessionRecord& s) { return s.key == record.key; });
        if (known != sidecar.end()) record = *known;

        records_.push_back(std::move(record));
    }

    // Resuming from a stored offset is only sound while the addon still holds
    // the earlier data. Holding nothing and having declined nothing means it
    // has consumed nothing - a fresh install, or a reset - so those offsets
    // point past everything it still needs, which is exactly why running the
    // application after a reset appeared to do nothing at all.
    //
    // Deliberately not also requiring an empty queue: a reset leaves the
    // unconsumed chunks in place, and testing for both would skip the rebuild
    // in precisely the case that needs it. Re-reading while the addon has no
    // history is wasted effort at worst, and stops as soon as it consumes once.
    forceFullRead_ = state_.cached.empty() && state_.oldestWanted.empty();
}

//------------------------------------------------------------------------------

bool Generator::Consumed(const std::string& key) const {
    if (state_.cached.count(key)) return true;

    // Below the floor the addon has said it will never ask again, so these are
    // collectable even though they were never cached - otherwise a backlog
    // larger than its session cap would sit in the queue forever.
    return !state_.oldestWanted.empty() && key < state_.oldestWanted;
}

void Generator::CollectConsumed() {
    lastCollected_ = 0;

    std::error_code ec;
    auto consumed = [&](const SessionRecord& r) { return Consumed(r.key); };

    for (const auto& r : records_) {
        if (consumed(r)) {
            fs::remove(DataAddonDir() / (r.key + ".lua"), ec);
            ++lastCollected_;
        }
    }
    records_.erase(std::remove_if(records_.begin(), records_.end(), consumed),
                   records_.end());
}

void Generator::PrunePending() {
    if (static_cast<int>(records_.size()) <= opt_.pendingLimit) return;

    std::sort(records_.begin(), records_.end(),
              [](const SessionRecord& a, const SessionRecord& b) {
                  return a.key < b.key;   // keys lead with the timestamp
              });

    const size_t excess = records_.size() - static_cast<size_t>(opt_.pendingLimit);
    std::error_code ec;
    for (size_t i = 0; i < excess; ++i) {
        fs::remove(DataAddonDir() / (records_[i].key + ".lua"), ec);
    }
    records_.erase(records_.begin(), records_.begin() + static_cast<long>(excess));
}

void Generator::PruneRaw() {
    std::error_code ec;
    std::vector<fs::path> archives;
    for (const auto& file : fs::directory_iterator(opt_.rawDir, ec)) {
        const std::string name = file.path().filename().string();
        if (name.size() > 7 && name.compare(name.size() - 7, 7, kArchiveExt) == 0) {
            archives.push_back(file.path());
        }
    }
    if (static_cast<int>(archives.size()) <= opt_.rawLimit) return;

    std::sort(archives.begin(), archives.end());
    const size_t excess = archives.size() - static_cast<size_t>(opt_.rawLimit);
    for (size_t i = 0; i < excess; ++i) fs::remove(archives[i], ec);
}

//------------------------------------------------------------------------------

bool Generator::WriteRecords() const {
    std::error_code ec;
    fs::create_directories(opt_.rawDir, ec);

    std::string body;
    for (const auto& r : records_) {
        const Session& s = r.session;
        body += r.key + '\t' + std::to_string(r.events) + '\t'
              + std::to_string(r.units) + '\t' + (r.archived ? "1" : "0") + '\t'
              + std::to_string(s.startTime / 1000) + '\t'
              + std::to_string(s.endTime / 1000) + '\t'
              + std::to_string(static_cast<int>(s.type)) + '\t'
              + std::to_string(s.instanceId) + '\t'
              + std::to_string(s.uiMapId) + '\t'
              + (s.rated ? "1" : "0") + '\t'
              + (s.IsTruncated() ? "1" : "0") + '\t'
              + std::to_string(s.lobbyIndex) + '\t'
              + std::to_string(s.roundIndex) + '\t'
              + std::to_string(s.combatantCount) + '\t'
              + s.bracket + '\t' + s.mapName + '\t' + r.character + '\n';
    }
    return WriteAtomic(opt_.rawDir / kRecordsFile, body);
}

bool Generator::WriteLogState() const {
    std::string body;
    for (const auto& [name, state] : logs_) {
        body += name;
        body += '\t';
        body += std::to_string(state.offset);
        body += '\t';
        body += std::to_string(state.size);
        body += '\t';
        body += (state.settled ? '1' : '0');
        body += '\n';
    }
    return WriteAtomic(opt_.rawDir / kLogStateFile, body);
}

bool Generator::WriteToc() const {
    std::string toc;
    toc += "## Interface: ";
    toc += kInterface;
    toc += "\n## Title: CombatSession Data\n";
    toc += "## Notes: Generated session queue. Do not edit.\n";
    toc += "## Dependencies: CombatSession\n\n";

    // Chunks first, index last, matching the order they are committed in.
    auto sorted = records_;
    std::sort(sorted.begin(), sorted.end(),
              [](const SessionRecord& a, const SessionRecord& b) {
                  return a.key < b.key;
              });
    for (const auto& r : sorted) toc += r.key + ".lua\n";
    toc += kIndexFile;
    toc += "\n";

    return WriteAtomic(DataAddonDir() / (std::string(kDataAddon) + ".toc"), toc);
}

bool Generator::WriteIndex() const {
    auto sorted = records_;
    std::sort(sorted.begin(), sorted.end(),
              [](const SessionRecord& a, const SessionRecord& b) {
                  return a.key < b.key;
              });

    std::string body = "-- Generated by CombatSession. Do not edit.\n";

    // Which application wrote this folder.
    //
    // The addon has no other way to find out. It cannot see the executable, it
    // cannot run one, and the only thing the two of them share is this
    // directory - so the version is published the same way the sessions are, as
    // a line of Lua the client loads. It is rewritten on every pass, including
    // the empty pass at startup, so replacing the executable and launching it is
    // all it takes for the addon to learn what it is now talking to.
    //
    // Written before the index so it is set even if a client somehow stops
    // reading the file part way through.
    body += "CombatSessionAppVersion = { code = "
          + std::to_string(kAppVersion)
          + ", text = " + QuoteLua(CS_VERSION_SHORT)
          + ", full = " + QuoteLua(CS_VERSION_FULL) + " }\n";

    body += "CombatSessionIndex = {\n";
    for (const auto& r : sorted) {
        const Session& s = r.session;
        body += "  { key=" + QuoteLua(r.key)
              + ", events=" + std::to_string(r.events)
              + ", units=" + std::to_string(r.units)
              + ", archived=" + (r.archived ? "true" : "false")
              + ", startTime=" + std::to_string(s.startTime / 1000)
              + ", endTime=" + std::to_string(s.endTime / 1000)
              + ", type=" + (s.type == SessionType::Arena ? "\"arena\""
                                                          : "\"battleground\"")
              + ", instanceId=" + std::to_string(s.instanceId)
              + ", uiMapId=" + std::to_string(s.uiMapId)
              + ", rated=" + (s.rated ? "true" : "false")
              + ", truncated=" + (s.IsTruncated() ? "true" : "false")
              + ", lobby=" + std::to_string(s.lobbyIndex)
              + ", round=" + std::to_string(s.roundIndex)
              + ", combatants=" + std::to_string(s.combatantCount)
              + ", bracket=" + QuoteLua(s.bracket)
              + ", mapName=" + QuoteLua(s.mapName)
              + ", character=" + QuoteLua(r.character)
              + " },\n";
    }
    body += "}\n";

    return WriteAtomic(DataAddonDir() / kIndexFile, body);
}

bool Generator::Commit() {
    // The queue folder has to exist even with nothing to put in it. The client
    // enumerates addon folders at launch, so a data addon that first appears
    // after a match is invisible until a full client restart - and until then
    // the .toc and Index.lua below fail to write at all, silently, because
    // create_directories only ran on the path that had a session to emit.
    std::error_code ec;
    fs::create_directories(DataAddonDir(), ec);

    CollectConsumed();
    PrunePending();
    PruneRaw();

    if (!WriteRecords()) return false;
    if (!WriteLogState()) return false;

    // The .toc names the files the client loads and Index.lua is what the addon
    // trusts, so both are written after every chunk is safely in place. Until
    // this point a newly written chunk is inert.
    if (!WriteToc()) return false;
    return WriteIndex();
}



} // namespace cs
