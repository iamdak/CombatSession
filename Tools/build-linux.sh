#!/bin/sh
# Builds the Linux application, on a Linux machine or in WSL on Windows.
#
# The executable lands in CombatSessionApp/Binary beside the Windows one, as
# CombatSession with no extension, so the two never overwrite each other. The
# build tree is Build-linux, kept apart from the Visual Studio one in Build.
#
# Needs, on Debian and Ubuntu (WSL's default included):
#
#   sudo apt install build-essential cmake pkg-config libgtk-3-dev \
#                    libayatana-appindicator3-dev
#
# Run from anywhere:   sh Tools/build-linux.sh
set -e

root=$(cd "$(dirname "$0")/.." && pwd)
app="$root/CombatSessionApp"

cmake -S "$app" -B "$app/Build-linux" -DCMAKE_BUILD_TYPE=Release
cmake --build "$app/Build-linux" -j "$(nproc)"

echo
echo "Built $app/Binary/CombatSession"
