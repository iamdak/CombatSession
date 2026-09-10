// CombatSession :: Archive
//
// Writes a byte range of a combat log to a gzip file.
//
// The archive is the source of truth for reprocessing, so it is written before
// the session is parsed. Output is a real gzip container rather than a raw
// deflate or zlib stream, so the files stay openable with any archiver if the
// user wants to look at a session by hand.

#pragma once

#include <cstdint>
#include <filesystem>

namespace cs {

// Copies [offset, offset + length) from `source` into `dest` as gzip.
// Streams in fixed-size blocks: a battleground session can exceed 50 MB and
// there is no reason to hold one in memory.
bool WriteGzipSlice(const std::filesystem::path& source,
                    uint64_t                     offset,
                    uint64_t                     length,
                    const std::filesystem::path& dest);

// Reads a gzip file produced by WriteGzipSlice back into memory. Used when
// regenerating stream chunks from the archive after a schema change.
bool ReadGzip(const std::filesystem::path& source, std::string& out);

} // namespace cs
