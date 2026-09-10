// CombatSession :: App
//
// The status-area shell: a notification icon on Windows, a menu bar item on
// macOS. Watches the Logs folder and runs the generator when a log settles.

#pragma once

#include "Config.h"

#include <string>

namespace cs {

// Runs until the user quits. Returns the process exit code. Must be called on
// the main thread.
int RunTray(Config config);

// Modal folder picker for the flavor directory, usable before the shell exists.
std::string PromptForWowFolder();

} // namespace cs
