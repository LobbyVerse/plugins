# LobbyVerse plugins

Server plugins for [LobbyVerse](https://lobbyverse.com), the server list that leaves out fake servers and counts
real players. Each one is small, opens no connection of its own, and takes its data from LobbyVerse over the RCON
connection the server owner already set up.

| Plugin | For | Status |
| --- | --- | --- |
| [Reserved slots](amxmodx/scripting/lobbyverse_reserved.sma) | AMX Mod X 1.9+ (CS 1.6, CZ, DoD and other GoldSrc mods) | 1.0.0 |
| [Reserved slots](sourcemod/scripting/lobbyverse_reserved.sp) | SourceMod 1.11+ (CS:S, TF2, Left 4 Dead 2 and other Source games) | 1.0.0 |
| [Reserved slots](counterstrikesharp/lobbyverse_reserved.cs) | CounterStrikeSharp (CS2) | 1.0.0 |

## Reserved slots for AMX Mod X

Keep a list of players with a reserved slot on [lobbyverse.com/account/reserved](https://lobbyverse.com/account/reserved),
each with an end date or none. LobbyVerse sends the list to every server you claimed that runs this plugin. The
plugin gives listed players the reservation flag (`b`) when they connect, and AMX Mod X's own `adminslots` plugin
keeps the last slots for them. When a player's time is up, LobbyVerse leaves them out of the next list. There is no
`users.ini` to edit.

### Install

1. Download `lobbyverse_reserved.amxx` from the [latest release](https://github.com/LobbyVerse/plugins/releases/latest)
   and put it in `addons/amxmodx/plugins/`.
2. Add `lobbyverse_reserved.amxx` to `addons/amxmodx/configs/plugins.ini` **right after `admin.amxx`** and
   **before `adminslots.amxx`**. `admin.amxx` resets players' flags, so the order matters; the plugin warns in the
   server console when it's wrong.
3. Set `amx_reservation 1` (or the number of slots to keep) in `addons/amxmodx/configs/amxx.cfg`, then restart the
   server.
4. Claim the server on LobbyVerse, save its RCON password, and add your players on the
   [Reserved slots](https://lobbyverse.com/account/reserved) page.

LobbyVerse sees the plugin through its public cvar `lv_reserved_version` and sends the list within a minute of
every change, and again every hour (a restarted server starts with an empty list).

### What it does not do

It opens no connection, reads and writes no file, never kicks or bans anyone, and never removes a flag `users.ini`
gave. The list lives in memory only.

### Protocol (v1)

Server commands, so only RCON and the server console can use them. Every command answers one line starting with
`lv_reserved: `.

| Command | What it does |
| --- | --- |
| `lv_reserved_begin` | Start a new list. The current one stays in force until `lv_reserved_end`. |
| `lv_reserved_add <steamid> ...` | Add up to 20 SteamIDs (`STEAM_0:X:Y` or `STEAM_1:X:Y`). |
| `lv_reserved_end <count>` | Swap the new list in, only when it holds exactly `<count>` SteamIDs. Answers `ok N` or `mismatch`. |
| `lv_reserved_clear` | Empty the list. |
| `lv_reserved_status` | Print the protocol version, the count and the seconds since the last push. |

SteamIDs travel in the legacy `STEAM_0:X:Y` form because Pawn cells are 32 bits and can't hold a SteamID64.

### Build from source

Compile with the `amxxpc` that ships with AMX Mod X (1.10 used for the release):

```
amxxpc lobbyverse_reserved.sma -o lobbyverse_reserved.amxx
```

Each release lists the SHA-256 of its build, the same one [lobbyverse.com/owners/plugin](https://lobbyverse.com/owners/plugin)
shows.

## Reserved slots for SourceMod

The same list and protocol for Source games. The plugin adds the reservation flag (`a`) in
`OnClientPostAdminFilter`, before SourceMod's own `reservedslots.smx` decides, so load order doesn't matter.

### Install

1. Download `lobbyverse_reserved.smx` from the [releases](https://github.com/LobbyVerse/plugins/releases) and put it
   in `addons/sourcemod/plugins/`. It loads on the next map change, or at once with `sm plugins load lobbyverse_reserved`.
2. Keep `reservedslots.smx` loaded (it ships with SourceMod) and set `sm_reserved_slots 1` (or the number of slots to
   keep) in `cfg/sourcemod/sourcemod.cfg`. The plugin warns in the server console when either is missing.
3. Claim the server on LobbyVerse, save its RCON password, and add your players on the
   [Reserved slots](https://lobbyverse.com/account/reserved) page.

The Source console splits command arguments at colons, so the plugin reads `lv_reserved_add`'s SteamIDs from the
raw argument string; quoted or not, they work.

### Build from source

```
spcomp lobbyverse_reserved.sp -o lobbyverse_reserved.smx
```

The release build uses SourceMod 1.12's compiler.

## Reserved slots for CS2 (CounterStrikeSharp)

The same list and protocol for CS2. CS2 has no reserved-slots plugin of its own, so this one keeps the slots, like
SourceMod's `sm_reserve_type 0`: of the server's slots, the last `ReservedSlots` are reserved, and a player who isn't on
your list (and has no `@css/reservation` permission) and takes one is kicked with a message. Players on the list are
never kicked.

### Install

1. Install [Metamod:Source 2](https://www.sourcemm.net/downloads.php) and
   [CounterStrikeSharp](https://github.com/roflmuffin/CounterStrikeSharp/releases) (the `with-runtime` build).
2. Download `lobbyverse_reserved_cs2.zip` from the [releases](https://github.com/LobbyVerse/plugins/releases) and
   unzip it into `addons/counterstrikesharp/plugins/` (it makes a `LobbyVerseReserved` folder). It loads on the next
   map change, or at once with `css_plugins load LobbyVerseReserved`.
3. Set `ReservedSlots` in `addons/counterstrikesharp/configs/plugins/LobbyVerseReserved/LobbyVerseReserved.json`
   (1 by default; the file appears on the first load).
4. Claim the server on LobbyVerse, save its RCON password, and add your players on the
   [Reserved slots](https://lobbyverse.com/account/reserved) page.

CS2 publishes no server rules, so LobbyVerse finds the plugin with its first push over RCON.

### Build from source

```
cd counterstrikesharp && dotnet build -c Release
```

The release is built with the .NET 10 SDK against CounterStrikeSharp.API 1.0.371.

## Feedback

Open an issue here, or reply on the AlliedModders thread.

## License

MIT. See [LICENSE](LICENSE).
