/*
 * LobbyVerse Reserved Slots
 * https://lobbyverse.com/owners/plugin
 *
 * Keeps a server's reserved slots in step with the owner's list on LobbyVerse. LobbyVerse pushes the list over the
 * RCON connection the owner already gave it; this plugin grants the reservation flag ("b", ADMIN_RESERVATION) to
 * listed players when they connect, and the stock adminslots plugin does the rest (amx_reservation).
 *
 * What it does not do: open any connection, read or write any file, kick or ban anyone, or remove a flag. Flags from
 * users.ini are left alone; the list lives in memory only, and LobbyVerse pushes it again after a restart.
 *
 * Install: put lobbyverse_reserved.amxx in plugins.ini AFTER admin.amxx and BEFORE adminslots.amxx, and set
 * amx_reservation to the number of slots to keep (1 is usual).
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

#include <amxmodx>
#include <celltrie>

#define PLUGIN  "LobbyVerse Reserved Slots"
#define VERSION "2.0.0"
#define AUTHOR  "LobbyVerse"
#define PROTOCOL "2"

#define MAX_PER_ADD 20
#define MAX_LIST 1000
#define AUTHID_LEN 35

new Trie:g_list = Invalid_Trie;
new Trie:g_staging = Invalid_Trie;
new g_count;
new g_stagingCount;
new g_lastPush;

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);
	// Public in the server's rules, so LobbyVerse sees which protocol a server speaks without asking
	register_cvar("lv_reserved_version", PROTOCOL, FCVAR_SERVER | FCVAR_SPONLY);

	register_srvcmd("lv_reserved_begin", "cmdBegin");
	register_srvcmd("lv_reserved_add", "cmdAdd");
	register_srvcmd("lv_reserved_end", "cmdEnd");
	register_srvcmd("lv_reserved_clear", "cmdClear");
	register_srvcmd("lv_reserved_status", "cmdStatus");
	register_srvcmd("lv_tell", "cmdTell");

	g_list = TrieCreate();
}

public plugin_cfg()
{
	warnAboutOrder();
}

public plugin_end()
{
	if (g_list != Invalid_Trie) TrieDestroy(g_list);
	if (g_staging != Invalid_Trie) TrieDestroy(g_staging);
}

// admin.amxx resets a player's flags at each of these; running after it, we add ours back
public client_authorized(id)
{
	grant(id);
}

public client_putinserver(id)
{
	grant(id);
}

public client_infochanged(id)
{
	grant(id);
}

grant(id)
{
	if (g_count == 0 || is_user_bot(id) || is_user_hltv(id)) return;

	new authid[AUTHID_LEN];
	get_user_authid(id, authid, charsmax(authid));
	if (!normalize(authid)) return;

	if (TrieKeyExists(g_list, authid))
	{
		set_user_flags(id, get_user_flags(id) | ADMIN_RESERVATION);
	}
}

public cmdBegin()
{
	if (g_staging != Invalid_Trie) TrieDestroy(g_staging);
	g_staging = TrieCreate();
	g_stagingCount = 0;
	server_print("lv_reserved: ok begin");
	return PLUGIN_HANDLED;
}

public cmdAdd()
{
	if (g_staging == Invalid_Trie)
	{
		server_print("lv_reserved: error no begin");
		return PLUGIN_HANDLED;
	}

	new args = read_argc() - 1;
	if (args > MAX_PER_ADD) args = MAX_PER_ADD;

	new authid[AUTHID_LEN];
	new added;
	for (new i = 1; i <= args; i++)
	{
		read_argv(i, authid, charsmax(authid));
		if (!normalize(authid) || g_stagingCount >= MAX_LIST) continue;
		if (!TrieKeyExists(g_staging, authid))
		{
			TrieSetCell(g_staging, authid, 1);
			g_stagingCount++;
			added++;
		}
	}
	server_print("lv_reserved: ok %d", added);
	return PLUGIN_HANDLED;
}

public cmdEnd()
{
	if (g_staging == Invalid_Trie)
	{
		server_print("lv_reserved: error no begin");
		return PLUGIN_HANDLED;
	}

	new expected = read_argv_int(1);
	if (expected != g_stagingCount)
	{
		// A push that lost a line keeps the old list rather than a partial one
		server_print("lv_reserved: mismatch %d %d", expected, g_stagingCount);
		TrieDestroy(g_staging);
		g_staging = Invalid_Trie;
		return PLUGIN_HANDLED;
	}

	TrieDestroy(g_list);
	g_list = g_staging;
	g_staging = Invalid_Trie;
	g_count = g_stagingCount;
	g_lastPush = get_systime();

	// Players already in get the flag now, so a VIP added mid-map keeps their seat across the next reconnect
	new players[MAX_PLAYERS], num;
	get_players(players, num, "ch");
	for (new i = 0; i < num; i++) grant(players[i]);

	server_print("lv_reserved: ok %d", g_count);
	return PLUGIN_HANDLED;
}

public cmdClear()
{
	TrieClear(g_list);
	g_count = 0;
	g_lastPush = get_systime();
	server_print("lv_reserved: ok 0");
	return PLUGIN_HANDLED;
}

public cmdStatus()
{
	new ago = g_lastPush ? get_systime() - g_lastPush : -1;
	server_print("lv_reserved: status v%s %d %d", PROTOCOL, g_count, ago);
	return PLUGIN_HANDLED;
}

// lv_tell <userid> <text>: the rest of the line after the userid is the text
public cmdTell()
{
	new line[256], userid[12];
	read_args(line, charsmax(line));
	trim(line);
	strtok(line, userid, charsmax(userid), line, charsmax(line), ' ', 1);
	trim(line);

	new id = find_player("k", str_to_num(userid));
	if (!id || !line[0] || is_user_bot(id))
	{
		server_print("lv_tell: no player");
		return PLUGIN_HANDLED;
	}
	client_print(id, print_chat, "[LobbyVerse] %s", line);
	server_print("lv_tell: ok");
	return PLUGIN_HANDLED;
}

// STEAM_0:X:Y or STEAM_1:X:Y, X a single 0 or 1, Y digits; rewritten as STEAM_0 so both universes match
bool:normalize(authid[])
{
	if (!equal(authid, "STEAM_", 6)) return false;
	if (authid[6] != '0' && authid[6] != '1') return false;
	if (authid[7] != ':' || (authid[8] != '0' && authid[8] != '1') || authid[9] != ':') return false;

	new len = strlen(authid);
	if (len < 11 || len > 20) return false;
	for (new i = 10; i < len; i++)
	{
		if (!isdigit(authid[i])) return false;
	}
	authid[6] = '0';
	return true;
}

// adminslots must see our flag, so it has to load after us; admin.amxx must load before us or it resets the flag
warnAboutOrder()
{
	new self = -1, admin = -1, slots = -1;
	new count = get_pluginsnum();
	new file[64], name[2], version[2], author[2], status[2];
	for (new i = 0; i < count; i++)
	{
		get_plugin(i, file, charsmax(file), name, 0, version, 0, author, 0, status, 0);
		if (equali(file, "lobbyverse_reserved.amxx")) self = i;
		else if (equali(file, "admin.amxx") || equali(file, "admin_sql.amxx")) admin = i;
		else if (equali(file, "adminslots.amxx")) slots = i;
	}

	if (slots == -1)
	{
		server_print("[LobbyVerse] adminslots.amxx isn't loaded: reserved slots won't be enforced.");
	}
	else if (self > slots)
	{
		server_print("[LobbyVerse] Put lobbyverse_reserved.amxx ABOVE adminslots.amxx in plugins.ini, or VIPs won't get in.");
	}
	if (admin != -1 && self < admin)
	{
		server_print("[LobbyVerse] Put lobbyverse_reserved.amxx BELOW admin.amxx in plugins.ini, or admin.amxx will reset its flag.");
	}
}
