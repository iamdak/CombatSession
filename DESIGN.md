# CombatSession — Design

Status: confirmed 2026-09-07. Revision 2 — supersedes revision 1, which placed compressed
raw log data inside the addon. Raw now lives in an app-only archive; the addon receives a
normalized event stream.

## Target environment (verified on this machine)

| | |
|---|---|
| Client | 12.1.0.69587 (Midnight) |
| Interface | `120100` |
| `COMBAT_LOG_VERSION` | `22`, `ADVANCED_LOG_ENABLED 1`, `PROJECT_ID 1` |
| `advancedCombatLogging` | already `"1"` in `Config.wtf` — required; addon must verify |
| Install root | `C:\Games\World of Warcraft` (flavors: `_retail_`, `_ptr_`, `_beta_`, `_xptr_`) |
| Toolchain | CMake 3.21+, C++20, static CRT. Windows: MSVC x64. macOS: AppleClang, 11.0+ |
| Platform layer | `Platform.h` + `Tray.h`; one implementation pair per system, everything else portable |

Measured on a 36,801 byte sample log: gzip -9 gives **10.5×**; GUIDs are 19% of bytes with
353 occurrences of 19 unique values; quoted strings 29%; timestamps 11%.

## Pipeline

The data addon is a **queue**, not storage. The application produces chunks, the addon consumes
them into its own `CACHE`, and the application then collects what was consumed. Steady state is
an empty queue.

```
Logs/WoWCombatLog-*.txt
  │
  ├─ app segments SESSION boundaries
  ├─ app ARCHIVES the slice ──► App/Binary/Raw/<key>.log.gz     app-only, own limit
  └─ app PARSES the archive ──► CombatSession_Data/<key>.lua    the queue
                                CombatSession_Data/Index.lua    written LAST

                     addon consumes newest-first, up to its own cap
                                        │
                     the keys of CombatSessionDB.cache ARE the receipt
                                        │
              app reads those keys, deletes chunks it holds, rewrites the index
```

Copy-before-parse is deliberate: the archive is the source of truth, so parsing is re-runnable
and a parser defect never costs data. Because a slice is archived before its source is touched,
log cleanup is lossless by construction.

### Ordering and atomicity

Chunks are written under a temporary name and renamed into place, and the `.toc` and `Index.lua`
are written last. The `.toc` is what the client actually loads, so committing it before the
chunks are in place would let a half-written file be parsed as Lua and take the whole data addon
down with a syntax error. Until the commit, a newly written chunk is inert.

### Consequences

- **Consumption is reported by the cache itself, not by a marker beside it.** A marker and a
  cache are two statements that can disagree. They did: the client serialises from memory in one
  pass, and when that pass came up short the marker saved intact while most of the cache did not,
  so the app collected chunks for sessions that were never really held. The keys of `cache`
  cannot disagree with `cache`, so a short write now reads back as work still pending.
- **The state lags by one logout or `/reload`**, because that is when the client writes
  SavedVariables. Chunks simply linger a little longer than strictly necessary.
- **The app never emits a chunk for a session the addon is finished with.** It would be ignored
  and deleted on the next commit; the session still reaches the archive. "Finished with" means
  held in the cache, or older than the floor below.
- **The index lists only unconsumed work.** A processed session is gone from it, so the viewer
  lists from `CACHE` (`API:GetViewable`) rather than from the index.
- **The addon consumes proactively, and the viewer triggers no work at all.** Consumption runs at
  login, newest-first, so the session most likely to be looked at is ready first. The viewer only
  expands what is already stored - there is no parse-on-click path, because building a cache from
  the viewer would create a key the application then collects, and the next login's prune would
  discard the cache it had just paid for.
- **Backlog beyond the cap is declined explicitly.** With 100 pending and a cap of 40, the newest
  40 are built and `oldestWanted` is published as the oldest key still held, which frees the app
  to collect the rest. Without that floor the declined sessions would be re-offered every login,
  rebuilt, and pruned again - forty caches of work thrown away per login. The skipped sessions
  remain recoverable from the archive.
- **A format change drops stale cache entries at load.** The app cannot tell a current entry from
  an obsolete one, so an entry left behind would license deleting the one chunk that could rebuild
  it. `DropStaleCaches` runs before anything reads the cache.

## Ownership split

The client owns `WTF/.../SavedVariables/CombatSession.lua`: it reads at load and rewrites the
whole file from memory at logout/reload/exit, so any external write during a client session is
destroyed on the next save. Neither side writes what the other owns:

```
App   writes ->  CombatSession_Data/             generated .toc, chunks, Index.lua
App   writes ->  App/Binary/Raw/                 archive, never distributed
App   writes ->  App/Binary/settings.json        own settings
Addon writes ->  SavedVariables/CombatSession.lua  CACHE, MATCH records, floor, UI state
```

The app **reads** two things from that file and writes nothing the client owns: the keys of the
`cache` table, and the `oldestWanted` floor. Rather than embedding a Lua parser, `SavedVars.cpp`
makes a single depth-tracking pass over the file, stepping over string literals so a brace inside
a unit name cannot shift the depth - a few milliseconds on a file far larger than this one gets.
With more than one account, the intersection of their caches and the lowest floor win, so a chunk
is only collected once every account is done with it.

## Two levels of reparse

| Trigger | Who | Source | Cost |
|---|---|---|---|
| `FORMAT` / `EVENTS` definitions changed | Addon, in-game | `STREAM` | cheap, per session opened |
| Stream schema changed | App, out-of-game | `Raw/*.log.gz` | native speed, then `/reload` |

The addon can no longer reparse from raw, because there is no file I/O in the addon sandbox and
the archive is `.txt`. This is a net gain: full reparse now runs in C++ rather than pure Lua.

## Data model

```
DEFINES {
  VERSION { Addon, Stream },
  FORMAT [ { NAME }, ... ],   -- parser code ships as addon Lua, not as data
  EVENTS [ { NAME }, ... ]
}

SESSION [ {
  HEADER { StartTime, EndTime, Map, RawArchived, Version { Client, App, Stream } },
  MATCH  { IsRated, Bracket, Outcome, Roster[], MMR, ... },   -- addon-owned, from Recorder
  STREAM { units[], spells[], events[] },                     -- app-generated, load-on-demand
  CACHE  { FORMAT[], UNITS[], EVENTS[] }                      -- addon-computed from STREAM
} ]
```

`HEADER.RawArchived` tells the UI whether a full app-side reparse is still possible or whether
the archive has aged out. A session whose archive is gone remains viewable from `CACHE`.

`DEFINES.FORMAT[]` / `DEFINES.EVENTS[]` carry `{NAME, VERSION}` only. Parsers ship as normal
TOC-loaded addon Lua. `loadstring` does work in retail (Details! uses it), but storing code as
data buys nothing here: a reparse always uses the current definitions, and older sessions are
served by their existing `CACHE` plus its version stamp — which is the self-containment the
original design wanted. Revisit only if sessions become shareable between users on different
addon versions.

### STREAM

Normalized, pared down, addon-loadable. Per-event rows with units interned to indices, spells
to ids plus a string table, event names to enum codes, timestamps as deltas. The addon computes
`FORMAT` columns, `UNITS` and `EVENTS` from it, so adding a column recomputes in-game without
re-running the app.

Anything the stream omits can still be recovered by regenerating it from the archive, so the
foreclosure problem — a dropped field blocking a future `FORMAT` column — no longer applies.

### UNITS

- **`PARENT` is free**: the advanced parameter block carries `ownerGUID` directly (verified:
  `Pet-0-4228-...,Player-104-0B879FB5`). `SPELL_SUMMON` is the fallback for pets that never
  appear as an advanced info-unit. Minor pets group into one entry per owner, classified by
  NPC id from the curated list.
- **Names may log as `"Unknown"`** (verified in-log) — backfill across the session.
- **`level` in the advanced block is item level for players** (262 in the sample), creature
  level for NPCs. Store as two distinct fields; do not label both `Level`.
- **Class**: from `COMBATANT_INFO` in arenas; not emitted in battlegrounds, so BG class comes
  from the recorder's scoreboard roster.

### EVENTS

- Window of the last N seconds of major actions preceding each event. Units by index into `UNITS`.
- Spell taxonomy (CC / major defensive / dispel) is a hand-curated, versioned Lua table of
  PvP-relevant spell ids, maintained in the addon and stamped into `DEFINES.VERSION`. Needs
  manual review each patch.
- **Distance is approximate by construction**: positions are logged for one unit per event (the
  advanced info-unit), so any pair distance is last-known-position at T1 vs T2. Document the
  staleness budget; do not present it as exact range.

## Components

### 1. Application (C++, portable)

Tray application, single portable exe, no installer / registry / admin, with an opt-in autostart
checkbox (HKCU `Run`). Settings JSON beside the exe.

- Watch `<flavor>/Logs/` via `ReadDirectoryChangesW`; track byte offsets per file.
- Segment sessions. A single log file may contain several logging runs — `COMBAT_LOG_VERSION` is
  a reset marker, not a file preamble (verified: two occurrences in one 37 KB file). Arena:
  `ARENA_MATCH_START` / `ARENA_MATCH_END`. Battleground: `ZONE_CHANGE` / `MAP_CHANGE` into a BG
  `uiMapID`.
- Archive each slice gzip-compressed (miniz), then parse the archive into a stream chunk.
- Maintain the generated TOCs and prune to the N most recent sessions (default 200). The same
  count cap governs `Raw/` and the stream chunks.
- Optional `Logs/` cleanup. Cannot touch the active file — the client holds it open for append.
  No addon reads these files (there is no file I/O in the addon sandbox); only external tools do,
  such as the WarcraftLogs uploader, Raider.IO and Wipefest.

### 2. In-game recorder — implemented

**Corrected against a real capture.** Arena rated status *is* derivable from the log:
`ARENA_MATCH_START` field 4 is the bracket string (`Rated Solo Shuffle`, `2v2`, `Skirmish`), and
`ARENA_MATCH_END` reports `0,0` ratings for a skirmish against `1582,1596` for a rated 2v2. The
recorder is not needed for arenas.

It remains necessary for **battlegrounds**, which emit no start or end event, no
`COMBATANT_INFO`, and no rated marker of any kind — a rated Blitz and a random battleground are
structurally identical in the log. Rated status, outcome and roster for those exist only live.
Predicate mirrors REFlex:

```lua
if C_PvP.IsRatedBattleground() or C_PvP.IsSoloRBG()
   or (C_PvP.IsRatedArena() and not IsArenaSkirmish() and not C_PvP.IsSoloShuffle())
   or C_PvP.IsRatedSoloShuffle() then
```

- **Entry snapshot** (`PLAYER_ENTERING_WORLD`): rated flag, bracket, map, wall-clock start.
  Needed because leaving early never fires `PVP_MATCH_COMPLETE`.
- **Completion snapshot** (`PVP_MATCH_COMPLETE`): `SetBattlefieldScoreFaction(-1)`, then
  `GetNumBattlefieldScores()` / `C_PvP.GetScoreInfo(i)` for the roster with class and spec,
  `GetBattlefieldWinner()`, `C_PvP.GetActiveMatchDuration()`, `GetBattlefieldTeamInfo(0/1)`.
- Auto-toggles `LoggingCombat`, and only switches it off if it turned it on itself.
- Traces every match state transition, so a real Solo Shuffle capture settles the per-lobby vs
  per-round question rather than the segmenter guessing.
- Borrow REFlex's `MapIDRemap` and bad-map blacklist (1170, 2177).

### 3. Data library (headless API)

Consumes the generated stream addons plus SavedVariables and exposes the SESSION list. Usable by
any UI shell. Computes `CACHE` from `STREAM` when no compatible cache exists.

No compression library is required in-game any more — `Lib/` is currently empty.

### 4. UI shell

Tree inspector over the library. `/combatsession inspect`.

## Session scoping

- Arena: one SESSION per match.
- Solo Shuffle / Blitz: one SESSION per round, linked to a parent lobby id.
- Battleground: one SESSION per match.

### Termination

A start event is never assumed to have a matching end. Leaving an arena in progress produces an
`ARENA_MATCH_START` with no `ARENA_MATCH_END`, and battlegrounds emit no end event under any
circumstances. A session therefore closes on whichever of these comes first:

1. The explicit end event (`ARENA_MATCH_END`), where the format has one.
2. A map change out of the encounter.
3. A new `COMBAT_LOG_VERSION` header — client restart or `/combatlog` toggled mid-match.
4. End of a file that is no longer the active log.
5. A new start event with no intervening end (defensive).

Only case 1 is a clean end. Every other case sets a truncated flag in `HEADER`, which should
agree with the recorder's independently captured `abandoned` flag; disagreement between the two
is a useful validation signal rather than something to reconcile silently.

Terminator 2 cannot mean *any* `MAP_CHANGE` line. If a battleground spans more than one
`uiMapID`, a bare map change would truncate sessions mid-match. Arenas are single-map, but that
is not assumed for every BG. The recorder therefore records the full set of `uiMapID` values
seen during each match (`uiMaps`), alongside the `GetInstanceInfo` instance id — the combat log
writes `uiMapID` in `MAP_CHANGE` while `GetInstanceInfo` returns a different id space, so both
are needed to correlate a log slice to a recorded match. The segmenter ends a session on a map
change to an id outside that instance's map set, not on the first change of any kind.

Post-match events after `ARENA_MATCH_END` but before the port-out are excluded: the explicit
end wins.

## Layout

The repository is the source; a World of Warcraft install is a deployment of it, and the two
are shaped differently. `Tools/deploy.ps1` copies one into the other and is the only thing that
should ever write to the game tree - editing there produces two versions of a file with no
record of which is newer, which has already cost this project a day.

```
repository
  README.md  DESIGN.md  LICENSE
  Docs/                           icons, the viewer mock, store copy
  Tools/deploy.ps1                repository -> game install

  CombatSession/                  recorder addon and data library
    CombatSession.toc
    Core.lua  Recorder.lua  Spells.lua  Data.lua  Inspect.lua  Commands.lua
  CombatSessionViewer/            viewer addon; read-only, owns no data
    CombatSessionViewer.toc
    Core.lua  Model.lua  Window.lua  Minimap.lua  Commands.lua
  CombatSessionApp/
    CMakeLists.txt                the build; generates VS, Xcode, Ninja or make
    Source/                       C++ written for this project only
                                  Platform_*/Tray_* are the only per-system files
    Lib/miniz/                    third-party C (MIT)

game install, under Interface/AddOns/
  CombatSession/                  <- repository CombatSession/
    App/                          <- repository CombatSessionApp/
      Binary/                     executable + settings.json; never in the repository
        Raw/<key>.log.gz          archive; explicitly NOT distributed
      Build/                      generated project + intermediates, disposable
  CombatSessionViewer/            <- repository CombatSessionViewer/

  CombatSession_Data/             generated queue; one folder, eagerly loaded
    CombatSession_Data.toc        chunks listed first, Index.lua last
    <key>.lua                     UNCONSUMED chunks only
    Index.lua                     commit point
```

`Binary/` and `Build/` exist only in the game tree and deploy never touches them, so copying
the addons across costs neither the compiled executable nor the raw archive.

Two independent limits: `rawLimit` (default 200 sessions) governs the archive, and the addon's
own `maxSessions` (default 40, `API:SetMaxSessions`) governs how much it caches and how much of
a backlog it will consume at once. `pendingLimit` (default 100) is only a safety valve for the
case where the addon never runs and the queue would otherwise grow without bound.

Shipping an exe inside `Interface/AddOns/` is functional (no TOC means not an addon) but will
draw antivirus attention and confuse addon-manager packaging. Accepted as specified. `Raw` now
lives under `Binary`, so zipping `Binary` to distribute would include combat logs — the archive
is explicitly not for distribution.

## Verified against a real capture

A single 83 MB log containing a rated Solo Shuffle, a rated 2v2, a 3v2 skirmish, an Arathi Basin
Blitz and a Temple of Kotmogu battleground. 291,737 lines, **0 unparseable**, 10 sessions found.

| Fact | Evidence |
|---|---|
| Solo Shuffle emits one `ARENA_MATCH_START` per round, one `ARENA_MATCH_END` per lobby | 6 starts, 1 end; the end's 56s duration matches only the final round |
| `ZONE_CHANGE` carries the instance id, `MAP_CHANGE` the uiMapID | `ZONE_CHANGE,1911` matches `ARENA_MATCH_START,1911`; AB is `ZONE_CHANGE,2107` / `MAP_CHANGE,1366` |
| Arenas emit no `MAP_CHANGE` at all | every arena session has uiMapId 0 |
| `COMBATANT_INFO` count equals the participant count, and is absent in BGs | 6 per shuffle round, 4 for the 2v2, **5 for the 3v2 skirmish**, 0 for both BGs |
| Advanced parameter block is 19 fields | `SPELL_CAST_SUCCESS` has no suffix: 30 payload fields − 11 prefix |
| The advanced block is absent on aura and death events | `SPELL_AURA_APPLIED` is 12 fields, `UNIT_DIED` is 9 |
| No battleground spanned more than one uiMapID | one `MAP_CHANGE` each; only 2 samples, so the map set is still carried |
| Session sizes span an order of magnitude | 1.3 MB arena to 54.4 MB Kotmogu |
| gzip ratio | 10.4x–12.7x; the 78 MB archive compresses to 7.4 MB, verified with system `gzip -t` |
| Stream encoding | ~6.2x smaller than raw text; Kotmogu is 190k events in an 8.35 MB chunk |
| 97% of battleground events involve a player GUID | no meaningful lossless filtering exists |

## Implementation status

Built and verified end to end: `CombatLog`, `Segmenter`, `StreamWriter`, `Generator`, `Archive`
(miniz, MIT, vendored in `App/Lib`), `Config`, `App` (tray + `ReadDirectoryChangesW`), the VS
project, and on the addon side `Core`, `Recorder`, `Spells`, `Data`, `Inspect`, `Commands`.

**All addon Lua remains unrun.** There is no Lua interpreter on this machine, so it has been
structurally checked and reviewed but never executed in the client.

## Open / deferred

- Multi-account and multi-flavor selection in app settings (only `IAMDAK` / `_retail_` here).
- Advanced-parameter field order beyond what this machine's log confirms — validate against a
  real arena and BG log before locking the tokenizer.
- Desktop Lua 5.1 harness with WoW API stubs, so the parsing library is testable outside the
  client. Requires obtaining an interpreter; none is installed.
