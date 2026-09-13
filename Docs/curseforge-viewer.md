# CombatSession Viewer

Per-session PvP statistics, read from World of Warcraft's own combat log.

Because the log is a file on disk and addons cannot read files, this viewer needs
a small companion application — **[CombatSession, on GitHub](GITHUB_URL_HERE)** —
which watches your Logs folder and hands each finished match to the addon. Install
that first; the viewer has nothing to show without it.

Open with **`/csv`**, or the minimap button.

Sessions are listed down the left, the grid on the right. Sort by any column, then
click a player to see which spells did the work, and click a spell to see who it
landed on. Columns cover damage, healing, absorbs, overhealing, interrupts,
dispels, purges, deaths and crowd control — with teams coloured, results marked,
and bars scaled to whichever column you are sorting by.

**Requires:** the CombatSession addon, and the companion application for Windows
or macOS.

# AI Disclosure

As a courtesy to those taking a stance on AI, please note that this addon was created using Claude heavily.  I am a professional software engineer so while this isn't exactly slop, it is certainly a vibe project.  You're welcome to use the CombatSession library as a basis for your own projects, but please include this ai disclosure.