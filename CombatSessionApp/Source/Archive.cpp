#include "Archive.h"

#include "miniz.h"

#include <algorithm>
#include <cstring>
#include <fstream>
#include <vector>

namespace fs = std::filesystem;

namespace cs {
namespace {

constexpr size_t kChunk = 1 << 20;   // 1 MiB in, matching the output buffer

void PutLE32(std::ofstream& out, uint32_t value) {
    char bytes[4] = {
        static_cast<char>(value & 0xFF),
        static_cast<char>((value >> 8) & 0xFF),
        static_cast<char>((value >> 16) & 0xFF),
        static_cast<char>((value >> 24) & 0xFF),
    };
    out.write(bytes, 4);
}

// Minimal 10-byte gzip header: magic, deflate method, no flags, no mtime, no
// extra fields, unknown OS.
void WriteGzipHeader(std::ofstream& out) {
    const unsigned char header[10] = {
        0x1F, 0x8B, 0x08, 0x00,
        0x00, 0x00, 0x00, 0x00,   // mtime omitted; the file system carries it
        0x00, 0xFF,
    };
    out.write(reinterpret_cast<const char*>(header), sizeof header);
}

} // namespace

bool WriteGzipSlice(const fs::path& source, uint64_t offset, uint64_t length,
                    const fs::path& dest) {
    std::ifstream in(source, std::ios::binary);
    if (!in) return false;
    in.seekg(static_cast<std::streamoff>(offset));
    if (!in) return false;

    std::ofstream out(dest, std::ios::binary);
    if (!out) return false;

    WriteGzipHeader(out);

    // TDEFL_WRITE_ZLIB_HEADER is deliberately absent: a gzip member wraps raw
    // deflate, and adding a zlib header here would corrupt the container.
    tdefl_compressor* deflator = static_cast<tdefl_compressor*>(
        std::malloc(sizeof(tdefl_compressor)));
    if (!deflator) return false;

    struct Guard {
        tdefl_compressor* p;
        ~Guard() { std::free(p); }
    } guard{deflator};

    if (tdefl_init(deflator, nullptr, nullptr,
                   TDEFL_DEFAULT_MAX_PROBES) != TDEFL_STATUS_OKAY) {
        return false;
    }

    std::vector<char> inBuf(kChunk);
    std::vector<char> outBuf(kChunk);

    uint32_t crc = MZ_CRC32_INIT;
    uint64_t remaining = length;
    uint64_t totalIn = 0;

    for (;;) {
        size_t have = 0;
        if (remaining > 0) {
            const std::streamsize want =
                static_cast<std::streamsize>((std::min)(remaining, (uint64_t)inBuf.size()));
            in.read(inBuf.data(), want);
            have = static_cast<size_t>(in.gcount());
            if (have == 0) remaining = 0;
        }

        const bool final = (remaining == 0) || (have == 0);
        if (have > 0) {
            crc = static_cast<uint32_t>(
                mz_crc32(crc, reinterpret_cast<const unsigned char*>(inBuf.data()),
                         have));
            remaining -= have;
            totalIn   += have;
        }

        // One input block can expand into several output blocks, so the
        // compressor is pumped until it stops asking for more room.
        const char* next = inBuf.data();
        size_t left = have;
        for (;;) {
            size_t inBytes  = left;
            size_t outBytes = outBuf.size();

            const tdefl_status status = tdefl_compress(
                deflator, next, &inBytes, outBuf.data(), &outBytes,
                final ? TDEFL_FINISH : TDEFL_NO_FLUSH);

            if (outBytes > 0) out.write(outBuf.data(), static_cast<std::streamsize>(outBytes));
            next += inBytes;
            left -= inBytes;

            if (status == TDEFL_STATUS_DONE) { left = 0; break; }
            if (status != TDEFL_STATUS_OKAY) return false;
            if (left == 0 && outBytes < outBuf.size()) break;
        }

        if (final) break;
    }

    PutLE32(out, crc);
    PutLE32(out, static_cast<uint32_t>(totalIn & 0xFFFFFFFFu));   // ISIZE mod 2^32
    return out.good();
}

bool ReadGzip(const fs::path& source, std::string& out) {
    std::ifstream in(source, std::ios::binary);
    if (!in) return false;

    std::string raw((std::istreambuf_iterator<char>(in)),
                    std::istreambuf_iterator<char>());
    if (raw.size() < 18) return false;

    const auto* bytes = reinterpret_cast<const unsigned char*>(raw.data());
    if (bytes[0] != 0x1F || bytes[1] != 0x8B || bytes[2] != 0x08) return false;

    // Only the fixed 10-byte header this module writes is supported; files from
    // other tools may carry optional fields we do not skip.
    if (bytes[3] != 0x00) return false;

    const size_t bodyStart = 10;
    const size_t bodyLen   = raw.size() - bodyStart - 8;

    const uint32_t isize =
        static_cast<uint32_t>(bytes[raw.size() - 4]) |
        (static_cast<uint32_t>(bytes[raw.size() - 3]) << 8) |
        (static_cast<uint32_t>(bytes[raw.size() - 2]) << 16) |
        (static_cast<uint32_t>(bytes[raw.size() - 1]) << 24);

    out.resize(isize);
    const size_t produced = tinfl_decompress_mem_to_mem(
        out.data(), isize, raw.data() + bodyStart, bodyLen, 0);

    return produced != TINFL_DECOMPRESS_MEM_TO_MEM_FAILED;
}

} // namespace cs
