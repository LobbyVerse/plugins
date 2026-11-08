/*
 * LobbyVerse Reserved Slots for SourceMod
 * https://lobbyverse.com/owners/plugin
 *
 * Keeps a server's reserved slots in step with the owner's list on LobbyVerse. LobbyVerse pushes the list over the
 * RCON connection the owner already gave it; this plugin grants the reservation flag ("a", ADMFLAG_RESERVATION) to
 * listed players as their admin status is settled, and SourceMod's stock reservedslots plugin does the rest
 * (sm_reserved_slots, sm_reserve_type).
 *
 * What it does not do: open any connection, read or write any file, kick or ban anyone, or remove a flag. Flags from
 * admins.cfg or admins_simple.ini are left alone; the list lives in memory only, and LobbyVerse pushes it again after
 * a restart.
 *
 * Install: put lobbyverse_reserved.smx in addons/sourcemod/plugins/, keep reservedslots.smx loaded, and set
 * sm_reserved_slots to the number of slots to keep (1 is usual). Load order doesn't matter: the flag is added in
 * OnClientPostAdminFilter, which runs before any plugin's OnClientPostAdminCheck.
 *
 * Protocol v1 (server commands, so RCON only):
 *   lv_reserved_begin                 start a new list (the current one stays in force until _end)
 *   lv_reserved_add <steamid> ...     add up to 20 SteamIDs (STEAM_0:X:Y or STEAM_1:X:Y)
 *   lv_reserved_end <count>           swap the new list in, only when it holds exactly <count> SteamIDs
 *   lv_reserved_clear                 empty the list
 *   lv_reserved_status                print the count and the seconds since the last push
 * Every command answers one line starting "lv_reserved: ".
 *
 * Protocol v2 adds (also a server command):
 *   lv_tell <userid> <text>           print "[LobbyVerse] text" in that one player's chat (chat command answers);
 *                                     answers "lv_tell: ok" or "lv_tell: no player"
 *
 * MIT License, (c) 2026 Groovy Ape, LLC.
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "2.0.0"
#define PROTOCOL "2"

#define MAX_PER_ADD 20
#define MAX_LIST 1000
#define AUTHID_LEN 32
#define ARGS_LEN 1024

public Plugin myinfo =
{
	name = "LobbyVerse Reserved Slots",
	author = "LobbyVerse",
	description = "Reserved slots from your list on LobbyVerse",
	version = PLUGIN_VERSION,
	url = "https://lobbyverse.com/owners/plugin"
};

StringMap g_list;
StringMap g_staging;
int g_count;
int g_stagingCount;
int g_lastPush;

public void OnPluginStart()
{
	// Public in the server's rules (FCVAR_NOTIFY), so LobbyVerse sees which protocol a server speaks without asking
	CreateConVar("lv_reserved_version", PROTOCOL, "LobbyVerse reserved slots protocol", FCVAR_NOTIFY | FCVAR_DONTRECORD | FCVAR_SPONLY);

	RegServerCmd("lv_reserved_begin", Cmd_Begin, "LobbyVerse: start a new reserved list");
	RegServerCmd("lv_reserved_add", Cmd_Add, "LobbyVerse: add SteamIDs to the new list");
	RegServerCmd("lv_reserved_end", Cmd_End, "LobbyVerse: swap the new list in");
	RegServerCmd("lv_reserved_clear", Cmd_Clear, "LobbyVerse: empty the list");
	RegServerCmd("lv_reserved_status", Cmd_Status, "LobbyVerse: show the list's state");
	RegServerCmd("lv_tell", Cmd_Tell, "LobbyVerse: a chat line for one player");

	g_list = new StringMap();
}

public void OnConfigsExecuted()
{
	ConVar slots = FindConVar("sm_reserved_slots");
	if (slots == null)
	{
		PrintToServer("[LobbyVerse] reservedslots.smx isn't loaded: reserved slots won't be enforced.");
	}
	else if (slots.IntValue < 1)
	{
		PrintToServer("[LobbyVerse] sm_reserved_slots is 0: set it to the number of slots to keep (1 is usual).");
	}
}

// Runs after SourceMod settles a player's admin flags and before every plugin's OnClientPostAdminCheck, where
// reservedslots decides; flags added here survive that, and admins.cfg flags are kept
public void OnClientPostAdminFilter(int client)
{
	Grant(client);
}

void Grant(int client)
{
	if (g_count == 0 || IsFakeClient(client) || IsClientSourceTV(client)) return;

	char authid[AUTHID_LEN];
	if (!GetClientAuthId(client, AuthId_Steam2, authid, sizeof(authid), true)) return;
	if (!Normalize(authid)) return;

	int value;
	if (g_list.GetValue(authid, value))
	{
		AddUserFlags(client, Admin_Reservation);
	}
}

public Action Cmd_Begin(int args)
{
	delete g_staging;
	g_staging = new StringMap();
	g_stagingCount = 0;
	PrintToServer("lv_reserved: ok begin");
	return Plugin_Handled;
}

public Action Cmd_Add(int args)
{
	if (g_staging == null)
	{
		PrintToServer("lv_reserved: error no begin");
		return Plugin_Handled;
	}

	// The Source console splits arguments at colons, so the SteamIDs are read from the raw line and split on spaces
	char line[ARGS_LEN];
	GetCmdArgString(line, sizeof(line));
	ReplaceString(line, sizeof(line), "\"", " ");

	char ids[MAX_PER_ADD + 1][AUTHID_LEN];
	int found = ExplodeString(line, " ", ids, sizeof(ids), sizeof(ids[]));
	int added, seen;
	for (int i = 0; i < found && seen < MAX_PER_ADD; i++)
	{
		TrimString(ids[i]);
		if (ids[i][0] == '\0') continue;
		seen++;
		if (!Normalize(ids[i]) || g_stagingCount >= MAX_LIST) continue;
		if (g_staging.SetValue(ids[i], 1, false))
		{
			g_stagingCount++;
			added++;
		}
	}
	PrintToServer("lv_reserved: ok %d", added);
	return Plugin_Handled;
}

public Action Cmd_End(int args)
{
	if (g_staging == null)
	{
		PrintToServer("lv_reserved: error no begin");
		return Plugin_Handled;
	}

	int expected = GetCmdArgInt(1);
	if (expected != g_stagingCount)
	{
		// A push that lost a line keeps the old list rather than a partial one
		PrintToServer("lv_reserved: mismatch %d %d", expected, g_stagingCount);
		delete g_staging;
		return Plugin_Handled;
	}

	delete g_list;
	g_list = g_staging;
	g_staging = null;
	g_count = g_stagingCount;
	g_lastPush = GetTime();

	// Players already in get the flag now, so a VIP added mid-map keeps their seat
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && IsClientAuthorized(client)) Grant(client);
	}

	PrintToServer("lv_reserved: ok %d", g_count);
	return Plugin_Handled;
}

public Action Cmd_Clear(int args)
{
	g_list.Clear();
	g_count = 0;
	g_lastPush = GetTime();
	PrintToServer("lv_reserved: ok 0");
	return Plugin_Handled;
}

public Action Cmd_Status(int args)
{
	int ago = g_lastPush ? GetTime() - g_lastPush : -1;
	PrintToServer("lv_reserved: status v%s %d %d", PROTOCOL, g_count, ago);
	return Plugin_Handled;
}

// lv_tell <userid> <text>: the raw argument string, since the Source console splits text at colons
public Action Cmd_Tell(int args)
{
	char line[256];
	GetCmdArgString(line, sizeof(line));
	TrimString(line);
	int space = FindCharInString(line, ' ');
	int client = 0;
	if (space > 0)
	{
		line[space] = '\0';
		client = GetClientOfUserId(StringToInt(line));
	}
	if (client == 0 || !IsClientInGame(client) || IsFakeClient(client) || line[space + 1] == '\0')
	{
		PrintToServer("lv_tell: no player");
		return Plugin_Handled;
	}
	char text[256];
	strcopy(text, sizeof(text), line[space + 1]);
	TrimString(text);
	PrintToChat(client, "[LobbyVerse] %s", text);
	PrintToServer("lv_tell: ok");
	return Plugin_Handled;
}

// STEAM_0:X:Y or STEAM_1:X:Y, X a single 0 or 1, Y digits; rewritten as STEAM_0 so both universes match
bool Normalize(char[] authid)
{
	if (strncmp(authid, "STEAM_", 6) != 0) return false;
	if (authid[6] != '0' && authid[6] != '1') return false;
	if (authid[7] != ':' || (authid[8] != '0' && authid[8] != '1') || authid[9] != ':') return false;

	int len = strlen(authid);
	if (len < 11 || len > 20) return false;
	for (int i = 10; i < len; i++)
	{
		if (!IsCharNumeric(authid[i])) return false;
	}
	authid[6] = '0';
	return true;
}
