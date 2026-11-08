/*
 * LobbyVerse Reserved Slots for CounterStrikeSharp (CS2)
 * https://lobbyverse.com/owners/plugin
 *
 * Keeps a CS2 server's reserved slots in step with the owner's list on LobbyVerse. LobbyVerse pushes the list over
 * the RCON connection the owner already gave it. CS2 has no stock reserved-slots plugin, so this one keeps the slots
 * itself, like SourceMod's reservedslots with sm_reserve_type 0: of the server's MaxPlayers, the last ReservedSlots are
 * reserved; a player who isn't on the list (and has no @css/reservation permission) and takes one of them is kicked
 * with a message. Listed players keep it.
 *
 * What it does not do: open any connection, read or write any file beyond its own config, ban anyone, or kick a
 * listed player. The list lives in memory only, and LobbyVerse pushes it again after a restart.
 *
 * Install: put the LobbyVerseReserved folder in addons/counterstrikesharp/plugins/. The number of slots is
 * ReservedSlots in addons/counterstrikesharp/configs/plugins/LobbyVerseReserved/LobbyVerseReserved.json (1 by default).
 *
 * Protocol v1 (server commands, so RCON only), the same as the AMX Mod X and SourceMod plugins:
 *   lv_reserved_begin                 start a new list (the current one stays in force until _end)
 *   lv_reserved_add <steamid> ...     add up to 20 SteamIDs (STEAM_0:X:Y or STEAM_1:X:Y)
 *   lv_reserved_end <count>           swap the new list in, only when it holds exactly <count> SteamIDs
 *   lv_reserved_clear                 empty the list
 *   lv_reserved_status                print the count and the seconds since the last push
 * Every command answers one line starting "lv_reserved: ".
 *
 * MIT License, (c) 2026 Groovy Ape, LLC.
 */

using System.Text.Json.Serialization;
using CounterStrikeSharp.API;
using CounterStrikeSharp.API.Core;
using CounterStrikeSharp.API.Core.Attributes.Registration;
using CounterStrikeSharp.API.Modules.Admin;
using CounterStrikeSharp.API.Modules.Commands;

namespace LobbyVerseReserved;

public class ReservedConfig : BasePluginConfig
{
    // How many of the server's slots are kept for the list
    [JsonPropertyName("ReservedSlots")] public int ReservedSlots { get; set; } = 1;

    // What a player who takes a reserved slot without being on the list reads as they're kicked
    [JsonPropertyName("KickMessage")] public string KickMessage { get; set; } = "This slot is reserved. Try again when the server has room.";
}

public class LobbyVerseReserved : BasePlugin, IPluginConfig<ReservedConfig>
{
    public override string ModuleName => "LobbyVerse Reserved Slots";
    public override string ModuleVersion => "1.0.0";
    public override string ModuleAuthor => "LobbyVerse";
    public override string ModuleDescription => "Reserved slots from your list on LobbyVerse";

    private const string Protocol = "1";
    private const int MaxPerAdd = 20;
    private const int MaxList = 1000;
    private const ulong Steam64Base = 76561197960265728UL;

    public ReservedConfig Config { get; set; } = new();

    private HashSet<ulong> _list = new();
    private HashSet<ulong>? _staging;
    private DateTime? _lastPush;

    public void OnConfigParsed(ReservedConfig config)
    {
        config.ReservedSlots = Math.Max(0, config.ReservedSlots);
        Config = config;
    }

    public override void Load(bool hotReload)
    {
        RegisterListener<Listeners.OnClientAuthorized>(OnClientAuthorized);
    }

    // The SteamID is known here; the player holds a slot already, so count everyone in or connecting
    private void OnClientAuthorized(int slot, CounterStrikeSharp.API.Modules.Entities.SteamID steamId)
    {
        Server.NextFrame(() => Check(slot, steamId.SteamId64));
    }

    private void Check(int slot, ulong steam64)
    {
        var player = Utilities.GetPlayerFromSlot(slot);
        if (player == null || !player.IsValid || player.IsBot || player.IsHLTV || Config.ReservedSlots == 0) return;

        var humans = Utilities.GetPlayers().Count(p => p.IsValid && !p.IsBot && !p.IsHLTV
            && p.Connected is PlayerConnectedState.Connected or PlayerConnectedState.Connecting);
        var publicSlots = Server.MaxPlayers - Config.ReservedSlots;
        if (humans <= publicSlots) return;
        if (_list.Contains(steam64) || AdminManager.PlayerHasPermissions(player, "@css/reservation")) return;

        var message = Config.KickMessage.Replace("\"", "'").Replace(";", ",");
        Server.ExecuteCommand($"kickid {player.UserId} \"{message}\"");
    }

    [ConsoleCommand("lv_reserved_begin", "LobbyVerse: start a new reserved list")]
    [CommandHelper(whoCanExecute: CommandUsage.SERVER_ONLY)]
    public void OnBegin(CCSPlayerController? caller, CommandInfo info)
    {
        _staging = new HashSet<ulong>();
        info.ReplyToCommand("lv_reserved: ok begin");
    }

    // The console splits arguments at colons, so the SteamIDs are read from the raw line
    [ConsoleCommand("lv_reserved_add", "LobbyVerse: add SteamIDs to the new list")]
    [CommandHelper(whoCanExecute: CommandUsage.SERVER_ONLY)]
    public void OnAdd(CCSPlayerController? caller, CommandInfo info)
    {
        if (_staging == null)
        {
            info.ReplyToCommand("lv_reserved: error no begin");
            return;
        }

        var ids = info.ArgString.Replace("\"", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries).Take(MaxPerAdd);
        var added = 0;
        foreach (var id in ids)
        {
            if (_staging.Count >= MaxList) break;
            if (TryParse(id, out var steam64) && _staging.Add(steam64)) added++;
        }
        info.ReplyToCommand($"lv_reserved: ok {added}");
    }

    [ConsoleCommand("lv_reserved_end", "LobbyVerse: swap the new list in")]
    [CommandHelper(whoCanExecute: CommandUsage.SERVER_ONLY)]
    public void OnEnd(CCSPlayerController? caller, CommandInfo info)
    {
        if (_staging == null)
        {
            info.ReplyToCommand("lv_reserved: error no begin");
            return;
        }

        int.TryParse(info.ArgCount > 1 ? info.GetArg(1) : "", out var expected);
        if (expected != _staging.Count)
        {
            // A push that lost a line keeps the old list rather than a partial one
            info.ReplyToCommand($"lv_reserved: mismatch {expected} {_staging.Count}");
            _staging = null;
            return;
        }

        _list = _staging;
        _staging = null;
        _lastPush = DateTime.UtcNow;
        info.ReplyToCommand($"lv_reserved: ok {_list.Count}");
    }

    [ConsoleCommand("lv_reserved_clear", "LobbyVerse: empty the list")]
    [CommandHelper(whoCanExecute: CommandUsage.SERVER_ONLY)]
    public void OnClear(CCSPlayerController? caller, CommandInfo info)
    {
        _list = new HashSet<ulong>();
        _lastPush = DateTime.UtcNow;
        info.ReplyToCommand("lv_reserved: ok 0");
    }

    [ConsoleCommand("lv_reserved_status", "LobbyVerse: show the list's state")]
    [CommandHelper(whoCanExecute: CommandUsage.SERVER_ONLY)]
    public void OnStatus(CCSPlayerController? caller, CommandInfo info)
    {
        var ago = _lastPush.HasValue ? (int)(DateTime.UtcNow - _lastPush.Value).TotalSeconds : -1;
        info.ReplyToCommand($"lv_reserved: status v{Protocol} {_list.Count} {ago}");
    }

    // STEAM_0:X:Y or STEAM_1:X:Y, X a single 0 or 1, Y digits, as the other LobbyVerse plugins take them
    internal static bool TryParse(string id, out ulong steam64)
    {
        steam64 = 0;
        if (id.Length < 11 || id.Length > 20 || !id.StartsWith("STEAM_") || (id[6] != '0' && id[6] != '1')) return false;
        if (id[7] != ':' || (id[8] != '0' && id[8] != '1') || id[9] != ':') return false;
        var account = id[10..];
        if (!account.All(char.IsAsciiDigit) || !ulong.TryParse(account, out var y)) return false;
        steam64 = Steam64Base + y * 2 + (ulong)(id[8] - '0');
        return true;
    }
}
