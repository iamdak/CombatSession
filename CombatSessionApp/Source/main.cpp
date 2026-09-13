// CombatSession :: entry point
//
// A windowed application, and deliberately so.
//
// The previous version was a console program that hid and released its own
// console at startup so it could live in the notification area. That worked,
// and it is also precisely the shape of a program that does not want to be
// seen - which is why Microsoft classified the result as potentially unwanted.
// The behaviour was innocent and the pattern was not, and the pattern is what
// gets scanned.
//
// So there is no console to hide. The window is the application: it says what
// the program is, shows every setting, and reports what it is doing. Anything
// that used to be a command-line switch is a button on it.

#include "App.h"

#ifdef _WIN32
#include <windows.h>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    return cs::RunApp();
}

#else

int main() {
    return cs::RunApp();
}

#endif
