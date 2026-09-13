// CombatSession :: App
//
// The application: a window, a notification icon, and a thread watching the
// Logs folder. Runs until the user quits.

#pragma once

namespace cs {

// Runs the application and returns the process exit code. Must be called on the
// main thread. A second copy of the program exits immediately and silently.
int RunApp();

} // namespace cs
