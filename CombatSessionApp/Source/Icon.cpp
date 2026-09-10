#include "Icon.h"

namespace cs {
namespace {

constexpr uint32_t kTile     = 0x1B1B21u;
constexpr uint32_t kEdge     = 0x4A4A55u;
constexpr uint32_t kBaseline = 0x6A6A76u;

constexpr uint32_t Opaque(uint32_t rgb) { return 0xFF000000u | rgb; }

struct Canvas {
    std::vector<uint32_t>& pixels;

    void Fill(int x0, int y0, int x1, int y1, uint32_t rgb) {
        const uint32_t value = Opaque(rgb);
        for (int y = y0; y <= y1; ++y) {
            if (y < 0 || y >= kIconSize) continue;
            for (int x = x0; x <= x1; ++x) {
                if (x < 0 || x >= kIconSize) continue;
                pixels[static_cast<size_t>(y) * kIconSize + x] = value;
            }
        }
    }
};

} // namespace

std::vector<uint32_t> RenderTrayIcon(uint32_t accentRgb) {
    std::vector<uint32_t> pixels(static_cast<size_t>(kIconSize) * kIconSize, 0);
    Canvas canvas{ pixels };

    const int last = kIconSize - 1;

    canvas.Fill(0, 0, last, last, kTile);
    canvas.Fill(0, 0, last, 0, kEdge);
    canvas.Fill(0, last, last, last, kEdge);
    canvas.Fill(0, 0, 0, last, kEdge);
    canvas.Fill(last, 0, last, last, kEdge);

    canvas.Fill(6, 25, 25, 25, kBaseline);
    canvas.Fill(7,  20, 11, 24, accentRgb);
    canvas.Fill(13, 14, 17, 24, accentRgb);
    canvas.Fill(19,  8, 23, 24, accentRgb);

    // Clipped corners, which take the hard edge off the tile at the small sizes
    // both status areas actually draw. Cleared to fully transparent rather than
    // to a background colour: the Windows tray and the macOS menu bar are
    // different colours, and either can change under the user.
    const int corner[3][2] = { { 0, 0 }, { 1, 0 }, { 0, 1 } };
    for (const auto& point : corner) {
        const int x = point[0], y = point[1];
        pixels[static_cast<size_t>(y) * kIconSize + x] = 0;
        pixels[static_cast<size_t>(y) * kIconSize + (last - x)] = 0;
        pixels[static_cast<size_t>(last - y) * kIconSize + x] = 0;
        pixels[static_cast<size_t>(last - y) * kIconSize + (last - x)] = 0;
    }

    return pixels;
}

} // namespace cs
