// CombatSession :: Icon
//
// The status icon, drawn in code rather than shipped as an image.
//
// Three states means three images, and a resource script would pull rc.exe into
// the Windows build and an .iconset into the macOS one - for a single shape in
// three colours. Drawing it keeps the binary self-contained, makes recolouring
// trivial, and means both systems show the same mark rather than two files that
// drift apart.
//
// The mark is three ascending bars on a baseline, which is what the addon
// actually produces: a table of per-unit totals, drawn as bars in the viewer.
// The bars carry the state colour and are most of the icon, so the state reads
// at status-area size without any detail having to survive the downscale. The
// minimap button in CombatSessionViewer draws the same three bars.

#pragma once

#include <cstdint>
#include <vector>

namespace cs {

constexpr int kIconSize = 32;

// State colours, as 0xRRGGBB.
constexpr uint32_t kIdleGreen    = 0x3FC35Au;
constexpr uint32_t kWorkingAmber = 0xE8C02Eu;
constexpr uint32_t kReloadRed    = 0xE04B45u;

// kIconSize * kIconSize pixels, top-down, each 0xAARRGGBB with premultiplied
// alpha - which for this icon means fully opaque or fully clear, since the only
// transparent pixels are the four corners. Both systems want exactly this
// layout, one as a DIB section and one as a bitmap image rep.
std::vector<uint32_t> RenderTrayIcon(uint32_t accentRgb);

} // namespace cs
