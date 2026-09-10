<img src="Docs/icon-idle-256.png" width="72" align="left" alt="">

# CombatSession

Per-session combat statistics for World of Warcraft PvP, built from the game's own
combat log rather than from what an addon can see while a match is running.

<br clear="left">


World of Warcraft writes a full combat log to disk, but addons cannot read files.
CombatSession closes that gap with a small background application: it watches the
`Logs` folder, cuts the log into matches, and hands each one to the addon as a
compact data file. The addon loads it, and **CombatSession Viewer** shows the
result — damage, healing, absorbs, interrupts, dispels, purges, deaths and crowd
control, per player, drillable to the individual spell and the individual target.

Nothing is uploaded anywhere. Everything stays on your machine.

---

## Download

After downloading the binary; move it to wherever you want it to live then just
run it. It will become a background tray task; clicking on the task icon will
open more settings. You'll be able to start it at boot.

**[Download CombatSession.exe](../../releases/latest/download/CombatSession.exe)**
(Windows, 64-bit)

---

## Install

1. Copy the **`CombatSession`** and **`CombatSessionViewer`** folders into
   `World of Warcraft/_retail_/Interface/AddOns/`.
2. Put `CombatSession.exe` somewhere of its own and run it. It writes
   `settings.json` beside itself, finds your WoW folder if it can, and asks
   if it cannot.
3. Log in and type **`/csv`**.

The application lives in the system tray and needs to be running for new matches
to appear. Between matches it checks the size and timestamp of a handful of files
twice a second and does nothing else.

### The tray icon

| | Colour | Meaning |
|---|---|---|
| <img src="Docs/icon-idle.png" width="24" alt=""> | **Green** | Idle. Everything the addon can see, it has. |
| <img src="Docs/icon-working.png" width="24" alt=""> | **Amber** | Reading a log. |
| <img src="Docs/icon-reload.png" width="24" alt=""> | **Red** | Sessions are waiting — **`/reload`** in game to pick them up. |

Red is not an error. The addon can only load files that existed when the client
started, so a match played just now needs one `/reload` before it appears. That
is the whole reason the icon has colours, and the only thing it ever asks of you.
A sound plays once when it turns red; you can change or silence it from the menu.

---

## Application arguments

Run with no arguments, it sits in the tray. Run with any argument, it does that
one job on the command line, prints what it did, and exits.

| Argument | What it does |
|---|---|
| *(none)* | Run in the system tray |
| `--once` | Process everything now, then exit |
| `--list` | Report which logs would be processed; write nothing |
| `--reprocess` | Re-read every log from the beginning and rebuild all data |
| `--log <file>` | Process one specific log file |
| `--wow <path>` | Use this flavor folder (the one named `_retail_`); remembered |
| `--max <n>` | How many sessions to keep in the raw archive (default 200) |
| `--no-archive` | Skip the raw archive — reprocessing then becomes impossible |

`--reprocess` is the recovery path after an addon update changes the data
format. The full sequence is `/combatsession reset` → `/reload` →
`CombatSession.exe --reprocess` → `/reload`.

---

## Addon commands

### `/csv` — the viewer

| Command | What it does |
|---|---|
| `/csv` | Open or close the viewer |
| `/csv icon` | Show or hide the minimap button (`/csv icon on\|off` to set it) |
| `/csv reset` | Put the window back to its default size and position |
| `/csv status` | Version and how many sessions are viewable |

Right-clicking the minimap button opens a short menu: hide the icon, toggle
automatic combat logging, or print status.

### `/combatsession` — the recorder

Also `/csession`. You will rarely need these; the addon records matches on its
own.

| Command | What it does |
|---|---|
| `/combatsession` | Status: sessions held, sessions queued, zone, settings |
| `/combatsession inspect` | The built-in text inspector |
| `/combatsession autolog on\|off` | Start combat logging automatically in PvP instances |
| `/combatsession sessions <n>` | How many sessions to keep cached (default 40) |
| `/combatsession trace [n]` | Recent recorder events, for diagnosing a missed match |
| `/combatsession debug` | Verbose logging to chat |
| `/combatsession reset` | Clear cached sessions and ask for them again |
| `/combatsession wipe confirm` | Erase everything, including match results — permanent |

`autolog` is on by default and also forces `advancedCombatLogging`, which the
data depends on: without it the log omits the fields that say who did what to
whom. `wipe` destroys recorded results and rosters, which cannot be rebuilt from
logs — `reset` is almost always the one you want.

---

## How it fits together

```
Logs/WoWCombatLog-*.txt
   │  application segments the log into matches
   ├─ archives each match  ──►  Raw/<session>.log.gz   (beside the .exe)
   └─ writes a data file   ──►  Interface/AddOns/CombatSession_Data/

                    addon loads it at /reload and caches it
                                   │
                    application then deletes what was consumed
```

`CombatSession_Data` is generated — it is a queue, not storage, and it is normal
for it to be empty. The archive beside the executable is what makes reprocessing
possible; it is never distributed and contains your raw combat logs.

| Folder | What it is |
|---|---|
| `CombatSession/` | The recorder addon and the data library. No UI of its own. |
| `CombatSessionViewer/` | The viewer. Read-only; owns no data. |
| `CombatSessionApp/` | The background application, C++20. |

---

## Building

CMake, from inside `CombatSessionApp`. The executable lands in `Binary/`; the
`Build/` tree is disposable.

```
cmake -S . -B Build -DCMAKE_BUILD_TYPE=Release
cmake --build Build --config Release
```

Any generator CMake supports works — `-G "Visual Studio 17 2022" -A x64`,
`-G Xcode`, `-G Ninja`. Requires CMake 3.21 and a C++20 compiler; macOS 11 or
later.

Only two files are specific to an operating system: `Platform_*` and `Tray_*`,
implementing `Platform.h` and `Tray.h`. Everything else — reading logs, cutting
sessions, writing data — is portable, so a third system means writing that pair
and adding them to `CMakeLists.txt`.

---

## Requirements

World of Warcraft *Midnight* (interface 120100). Windows 10 or later, or
macOS 11 or later.
