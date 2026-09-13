<img src="icon-idle-256.png" width="72" align="left" alt="">

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

# NOTE: This executable is being rejected by Microsoft; I'm working on a fix.  Please
# build the executable from the source for now!

**[Download CombatSession.exe](../../../releases/latest/download/CombatSession.exe)**
(Windows, 64-bit)

macOS is supported in the source but there is no prebuilt binary — see
[Building](#building).

---

## Install

1. Install the addon from [CurseForge](https://www.curseforge.com/wow/addons/combatsession) or download and copy the **`CombatSession`**
   and **`CombatSessionViewer`** folders into:
   `World of Warcraft/_retail_/Interface/AddOns/`.
   
2. Download the binary and extract `CombatSession.exe` to any folder and run it.
   On first launch it will ask for the World of Warcraft installation folder.
   Choose the flavor folder, the one containing `Logs` and `Interface`, usually
   named `_retail_`.
   
3. Log into WoW and type **`/csv`** or click the minimap icon.


You can tell the application to Start with Windows; if you move the application
to a new location, just run it from the new folder and turn "Start with Windows"
off and on again to set the new location.

---

### What the colour means

The icon on the taskbar button — and in the notification area, if you put it
there — carries the state.

| | Colour | Meaning |
|---|---|---|
| <img src="icon-idle.png" width="24" alt=""> | **Green** | Idle. Everything the addon can see, it has. |
| <img src="icon-working.png" width="24" alt=""> | **Amber** | Reading a log. |
| <img src="icon-reload.png" width="24" alt=""> | **Red** | Sessions are waiting — **`/reload`** in game to pick them up. |

Red is not an error. The addon can only load files that existed when the client
started, so a match played just now needs one `/reload` before it appears. That
is the whole reason the icon has colours, and the only thing it ever asks of you.

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
   ├─ archives each match  ──►  Raw/<session>.log.gz   (beside the .exe, optional)
   └─ writes a data file   ──►  Interface/AddOns/CombatSession_Data/

                    addon loads it at /reload and caches it
                                   │
                    application then deletes what was consumed
```

`CombatSession_Data` is generated — it is a queue, not storage, and it is normal
for it to be empty. The archive beside the executable is what makes rebuilding
possible; it is off by default, never distributed, and contains your raw combat
logs.

| Folder | What it is |
|---|---|
| `CombatSession/` | The recorder addon and the data library. No UI of its own. |
| `CombatSessionViewer/` | The viewer. Read-only; owns no data. |
| `CombatSessionApp/` | The background application, C++20. |

### What it touches

Everything it writes, and nothing else:

- `settings.json` and `Raw/` beside the executable
- `CombatSession_Data/` inside the World of Warcraft folder you chose
- a shortcut in your own Startup folder, only while **Start with Windows** is on

No registry, no network, no installer. Deleting the folder removes it.

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

Only two files are specific to an operating system: `Platform_*` and `Shell_*`,
implementing `Platform.h` and `Shell.h`. Everything else — reading logs, cutting
sessions, writing data — is portable, so a third system means writing that pair
and adding them to `CMakeLists.txt`.

`Tools/deploy.ps1` copies the repository into a live World of Warcraft install.
The two trees are shaped differently, and that script is the only thing that
should ever write to the game folder.

---

## Requirements

World of Warcraft *Midnight* (interface 120100). Windows 10 or later, or
macOS 11 or later.
