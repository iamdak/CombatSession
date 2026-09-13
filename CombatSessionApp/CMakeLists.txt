# CombatSession application
#
# This replaces the checked-in Visual Studio project. The reason is not that
# CMake is nicer to read - it is that there is now more than one system to build
# for, and a .vcxproj can only ever describe one of them. Generating the project
# means the Windows and macOS builds cannot drift apart, which is exactly what
# happened to the old one: it was still linking three libraries while the build
# script had grown to seven, and the mismatch only surfaced as a link error.
#
# Run from this folder. Paths are relative to it rather than to a named parent,
# because this folder is "App" inside a live addon install and "CombatSessionApp"
# in the repository, and the commands should not need editing between the two.
#
#   Windows:  cmake -S . -B Build -G "Visual Studio 17 2022" -A x64
#             cmake --build Build --config Release
#
#   macOS:    cmake -S . -B Build -G Xcode
#             cmake --build Build --config Release
#
#   Anywhere: cmake -S . -B Build -DCMAKE_BUILD_TYPE=Release
#             cmake --build Build
#
# The build tree is disposable. Everything needed to run ends up in Binary/, so
# Build/ can be deleted without affecting distribution - the same promise the
# old VS/ folder used to make.

cmake_minimum_required(VERSION 3.21)

# Set before project(), which is when the compiler is probed against it.
# 11.0 is the oldest macOS that runs on Apple silicon, and there is nothing here
# that would work on an older one anyway.
set(CMAKE_OSX_DEPLOYMENT_TARGET "11.0"
    CACHE STRING "Minimum macOS version")

project(CombatSession
        VERSION 0.11
        DESCRIPTION "Turns World of Warcraft combat logs into per-session data"
        LANGUAGES C CXX)

# Objective-C++ for the macOS shell. Enabled only where it exists, so a Windows
# generator does not go looking for a compiler it has no use for.
if(APPLE)
    enable_language(OBJCXX)
endif()

# Single-config generators have no default, and a build with no optimisation is
# not what anyone typing `cmake --build` for this expects.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

#-------------------------------------------------------------------------------
# miniz
#
# Third-party C, built separately so its warnings and its language stay its own.
#-------------------------------------------------------------------------------

add_library(miniz STATIC Lib/miniz/miniz.c)
target_include_directories(miniz PUBLIC Lib/miniz)

#-------------------------------------------------------------------------------
# The application
#-------------------------------------------------------------------------------

set(CS_SOURCES
    Source/main.cpp
    Source/App.cpp
    Source/Archive.cpp
    Source/CombatLog.cpp
    Source/Config.cpp
    Source/Generator.cpp
    Source/Icon.cpp
    Source/SavedVars.cpp
    Source/Segmenter.cpp
    Source/StreamWriter.cpp
)

set(CS_HEADERS
    Source/App.h
    Source/Archive.h
    Source/CombatLog.h
    Source/Config.h
    Source/Generator.h
    Source/Icon.h
    Source/Platform.h
    Source/SavedVars.h
    Source/Segmenter.h
    Source/StreamWriter.h
    Source/Shell.h
    Source/Version.h
)

# The only per-system part of the build. Everything above parses logs and writes
# chunks and does not know which system it is on.
if(WIN32)
    list(APPEND CS_SOURCES Source/Platform_Win32.cpp Source/Shell_Win32.cpp)

    # Version resource. Enabled explicitly rather than relied on: the Visual
    # Studio generator picks .rc files up on its own, Ninja and makefiles do not.
    enable_language(RC)
    list(APPEND CS_SOURCES Source/CombatSession.rc)
elseif(APPLE)
    list(APPEND CS_SOURCES Source/Platform_Mac.mm Source/Shell_Mac.mm)
else()
    # Said plainly rather than left to fail at link time with undefined symbols
    # that do not name the problem.
    message(FATAL_ERROR
        "CombatSession has no platform layer for ${CMAKE_SYSTEM_NAME}.\n"
        "Everything but the status-area shell is portable: add "
        "Platform_${CMAKE_SYSTEM_NAME}.cpp and Shell_${CMAKE_SYSTEM_NAME}.cpp "
        "implementing Source/Platform.h and Source/Shell.h, then add them here.")
endif()

add_executable(CombatSession ${CS_SOURCES} ${CS_HEADERS})

target_include_directories(CombatSession PRIVATE Source)
target_compile_features(CombatSession PRIVATE cxx_std_20)
set_target_properties(CombatSession PROPERTIES CXX_EXTENSIONS OFF)

target_link_libraries(CombatSession PRIVATE miniz)

# std::thread needs an explicit link on most POSIX toolchains and none on MSVC;
# this is the portable spelling of both.
set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)
target_link_libraries(CombatSession PRIVATE Threads::Threads)

#-------------------------------------------------------------------------------
# Per-compiler settings
#-------------------------------------------------------------------------------

if(MSVC)
    target_compile_options(CombatSession PRIVATE /W4 /permissive-)
    # Third-party code is not held to the project's warning level.
    target_compile_options(miniz PRIVATE /W1)

    # Static CRT: the application must run from a copied folder with no
    # redistributable installed. Both targets, or the two halves disagree about
    # which runtime they are linking and the build fails at the end.
    set_property(TARGET CombatSession miniz PROPERTY
                 MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")

    # Windowed. An earlier version was a console application that hid its own
    # console at startup so it could sit in the notification area - which is the
    # shape of a program that does not want to be seen, and was classified as
    # potentially unwanted for it. There is now no console to hide.
    set_target_properties(CombatSession PROPERTIES WIN32_EXECUTABLE TRUE)
else()
    target_compile_options(CombatSession PRIVATE -Wall -Wextra)
endif()

if(WIN32)
    # gdi32 draws the icon, winmm plays the alert, comdlg32 and ole32 are the
    # file picker, the folder picker and the startup shortcut.
    #
    # advapi32 is deliberately absent. It was here for the HKCU Run value, and
    # with that replaced by a Startup shortcut the binary imports no registry
    # API at all - which is checkable with dumpbin /IMPORTS, and is the kind of
    # claim worth being able to demonstrate rather than assert.
    target_link_libraries(CombatSession PRIVATE
        user32 shell32 gdi32 winmm comdlg32 ole32)

    # The old .vcxproj set CharacterSet=Unicode, which is where these came from;
    # CMake does not define them for you. Without them the IDC_* and IDI_*
    # resource macros expand to narrow strings and will not pass to the wide
    # functions this code calls throughout.
    target_compile_definitions(CombatSession PRIVATE UNICODE _UNICODE)
endif()

if(APPLE)
    # ARC for the Objective-C++ only. The C++ has no retain/release to manage,
    # and the .mm files are written assuming ARC - without it they leak every
    # panel and alert they open.
    set_source_files_properties(
        Source/Platform_Mac.mm Source/Shell_Mac.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

    # UniformTypeIdentifiers is the sound picker's file filter. AppKit does not
    # pull it in, and it is macOS 11 or later - which the deployment target
    # above already is.
    target_link_libraries(CombatSession PRIVATE
        "-framework Cocoa"
        "-framework UniformTypeIdentifiers")
endif()

#-------------------------------------------------------------------------------
# Output
#
# App/Binary is the distributable, and holds the executable and nothing else
# that was not put there deliberately. Multi-config generators want to add a
# Debug/ or Release/ level of their own, so each configuration is pointed at the
# same place explicitly.
#-------------------------------------------------------------------------------

set(CS_BINARY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/Binary")

set_target_properties(CombatSession PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CS_BINARY_DIR}")

foreach(config ${CMAKE_CONFIGURATION_TYPES})
    string(TOUPPER "${config}" config_upper)
    set_target_properties(CombatSession PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY_${config_upper} "${CS_BINARY_DIR}")
endforeach()

# Opening the generated solution should land on something runnable rather than
# on ALL_BUILD.
set_property(DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
             PROPERTY VS_STARTUP_PROJECT CombatSession)
