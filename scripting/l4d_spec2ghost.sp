/*
*	Spec2Ghost Teleport
*	Copyright (C) 2022 Silvers
*
*	This program is free software: you can redistribute it and/or modify
*	it under the terms of the GNU General Public License as published by
*	the Free Software Foundation, either version 3 of the License, or
*	(at your option) any later version.
*
*	This program is distributed in the hope that it will be useful,
*	but WITHOUT ANY WARRANTY; without even the implied warranty of
*	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*	GNU General Public License for more details.
*
*	You should have received a copy of the GNU General Public License
*	along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/



#define PLUGIN_VERSION 		"1.6"

/*======================================================================================
	Plugin Info:

*	Name	:	[L4D & L4D2] Spec2Ghost Teleport
*	Author	:	SilverShot
*	Descrp	:	Teleports special infected, who are entering ghost mode, to where they were spectating.
*	Link	:	https://forums.alliedmods.net/showthread.php?t=186249
*	Plugins	:	https://sourcemod.net/plugins.php?exact=exact&sortby=title&search=1&author=Silvers

========================================================================================
	Change Log:

1.6 (30-Jul-2022)
	- Recompiled against SourceMod version 1.11 and Left4DHooks version 1.111. Thanks to "Hawkins" for reporting error messages with Left4DHooks version 1.110.

1.5 (08-Mar-2022)
	- Plugin now teleports to the same eye angles. Thanks to "Eyal282" for reporting.

1.4 (04-Dec-2021)
	- Minor change to code to fix a bad coding practice.
	- The stuck method test no longer requires Left4DHooks and defaults to the games selected spawn position if they are stuck.
	- The method for finding a nearby valid area still requires Left4DHooks.

1.3 (28-Apr-2021)
	- Optionally uses Left4DHooks 1.36+ to detect if a players stuck and finds a valid area nearby. Thanks to "Voevoda" for reporting and testing.
	- Added commmand "sm_stucktest" to test and teleport yourself to a nearby area if stuck. Uses the same method for detection and fixing.
	- Now ignores the players location when first spawning on each new round. Thanks to "s.m.a.c head" and "Beatles" for reporting.

1.2a (24-Sep-2020)
	- Compatibility update for L4D2's "The Last Stand" update.
	- GameData .txt file updated.

1.2 (10-May-2020)
	- Added better error log message when gamedata file is missing.
	- Various changes to tidy up code.

1.1.1 (21-Jul-2018)
	- Changed CreateTimer with RequestFrame, for faster response to teleport.
	- Updated gamedata offsets in L4D1 and L4D2 so the plugin works again.

1.1 (05-May-2018)
	- Converted plugin source to the latest syntax utilizing methodmaps. Requires SourceMod 1.8 or newer.

1.0 (27-May-2012)
	- Initial release.

========================================================================================

	This plugin was made using source code from the following plugins.
	If I have used your code and not credited you, please let me know.

======================================================================================*/

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#define GAMEDATA				"l4d_spec2ghost"
#define MAX_TRIES				8						// Maximum hull traces when attempting to find a valid area for a player

// #include <left4dhooks>
// Left4DHooks natives - optional - (added here to avoid requiring Left4DHooks include)
native void L4D_FindRandomSpot(int NavArea, float vecPos[3]);
native any L4D_GetNearestNavArea(const float vecPos[3], float maxDist = 300.0, bool anyZ = false, bool checkLOS = false, bool checkGround = false, int teamID = 2);
native bool L4D_GetRandomPZSpawnPosition(int client, int zombieClass, int attempts, float vecPos[3]);
bool g_bLeft4DHooks;

Handle g_hOnLeaveGhost;
float g_vPos[MAXPLAYERS+1][3];
float g_vAng[MAXPLAYERS+1][3];
int g_iStart[MAXPLAYERS+1];
int g_iLateLoad;
// bool g_bFinale;



public Plugin myinfo =
{
	name = "[L4D & L4D2] Spec2Ghost Teleport",
	author = "SilverShot",
	description = "Teleports special infected, who are entering ghost mode, to where they were spectating.",
	version = PLUGIN_VERSION,
	url = "https://forums.alliedmods.net/showthread.php?t=186249"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	EngineVersion test = GetEngineVersion();
	if( test != Engine_Left4Dead && test != Engine_Left4Dead2 )
	{
		strcopy(error, err_max, "Plugin only supports Left 4 Dead 1 & 2.");
		return APLRes_SilentFailure;
	}

	MarkNativeAsOptional("L4D_FindRandomSpot");
	MarkNativeAsOptional("L4D_GetNearestNavArea");
	MarkNativeAsOptional("L4D_GetRandomPZSpawnPosition");

	g_iLateLoad = late;
	return APLRes_Success;
}

// ==================================================
// 				LEFT 4 DHOOKS - OPTIONAL
// ==================================================
public void OnLibraryAdded(const char[] sName)
{
	if( strcmp(sName, "left4dhooks") == 0 )
		g_bLeft4DHooks = true;
}

public void OnLibraryRemoved(const char[] sName)
{
	if( strcmp(sName, "left4dhooks") == 0 )
		g_bLeft4DHooks = false;
}

// ==================================================
// 					PLUGIN START
// ==================================================
public void OnPluginStart()
{
	// =========================
	// GAMEDATA + DETOUR
	// =========================
	char sPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, sPath, sizeof(sPath), "gamedata/%s.txt", GAMEDATA);
	if( FileExists(sPath) == false ) SetFailState("\n==========\nMissing required file: \"%s\".\nRead installation instructions again.\n==========", sPath);

	Handle hGameData = LoadGameConfigFile(GAMEDATA);
	if( hGameData == null ) SetFailState("Failed to load \"%s.txt\" gamedata.", GAMEDATA);

	int offset = GameConfGetOffset(hGameData, "CTerrorPlayer_OnEnterGhostState");
	delete hGameData;

	g_hOnLeaveGhost = DHookCreate(offset, HookType_Entity, ReturnType_Int, ThisPointer_CBaseEntity, OnLeaveGhost);

	// =========================
	// CVARS + EVENTS
	// =========================
	CreateConVar("l4d_spec2ghost_version", PLUGIN_VERSION, "Spec2Ghost Teleport plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);

	HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
	HookEvent("player_team", Event_PlayerTeam);

	RegAdminCmd("sm_stucktest", CmdStuckTest, ADMFLAG_ROOT);
}

// ==================================================
// 					EVENTS
// ==================================================
Action CmdStuckTest(int client, int args)
{
	IsClientStuck(client);
	return Plugin_Handled;
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	g_iStart[client] = 1;
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
	for( int i = 1; i <= MaxClients; i++ )
		g_iStart[i] = 1;
}

public void OnMapEnd()
{
	for( int i = 1; i <= MaxClients; i++ )
		g_iStart[i] = 1;
}

public void OnMapStart()
{
	// g_bFinale = FindEntityByClassname(-1, "trigger_finale") != INVALID_ENT_REFERENCE;

	if( g_iLateLoad )
		for( int i = 1; i <= MaxClients; i++ )
			if( IsClientInGame(i) )
				OnClientPutInServer(i);
}

public void OnClientPutInServer(int client)
{
	if( IsFakeClient(client) == false )
	{
		DHookEntity(g_hOnLeaveGhost, false, client);
	}
}

// ==================================================
// 					DETOUR
// ==================================================
MRESReturn OnLeaveGhost(int client)
{
	if( g_iStart[client] )
	{
		g_iStart[client] = 0;
		return MRES_Ignored;
	}

	GetClientAbsOrigin(client, g_vPos[client]);
	GetClientEyeAngles(client, g_vAng[client]);
	RequestFrame(OnFrame_Teleport, GetClientUserId(client));

	return MRES_Ignored;
}

void OnFrame_Teleport(int client)
{
	if( (client = GetClientOfUserId(client)) && IsClientInGame(client) && GetClientTeam(client) == 3 && GetEntProp(client, Prop_Send, "m_isGhost") == 1 )
	{
		if( IsClientStuck(client) == false )
		{
			TeleportEntity(client, g_vPos[client], g_vAng[client], NULL_VECTOR);
		}
	}
}

// ==================================================
// 					STUCK TEST
// ==================================================
bool IsClientStuck(int client)
{
	int tries;

	if( g_bLeft4DHooks )
	{
		// Loop through attempts to validate not stuck and find a valid position
		while( tries < MAX_TRIES )
		{
			// Stuck in world or other non-client object
			if( TraceClientStuck(client, g_vPos[client]) != -1 )
			{
				tries++;

				// Find nav area
				int area = L4D_GetNearestNavArea(g_vPos[client]);
				if( area )
				{
					// Get random spot inside nav area
					L4D_FindRandomSpot(area, g_vPos[client]);
				} else {
					// Failed to find nav area then try getting a spawn position nearby using another function
					L4D_GetRandomPZSpawnPosition(client, 5, 5, g_vPos[client]);
				}
			} else {
				tries = 0;
				break;
			}
		}
	} else {
		if( TraceClientStuck(client, g_vPos[client]) != -1 )
		{
			return true;
		}
	}

	return tries != 0;
}

int TraceClientStuck(int client, float vPos[3])
{
	float vMin[3], vMax[3];

	GetClientMins(client, vMin);
	GetClientMaxs(client, vMax);

	TR_TraceHullFilter(vPos, vPos, vMin, vMax, MASK_ALL, TraceRayCallback);
	return TR_GetEntityIndex();
}

bool TraceRayCallback(int entity, int mask)
{
	// Ignore hitting triggers
	if( entity > MaxClients && IsValidEntity(entity) )
	{
		static char sTemp[10];
		GetEntityClassname(entity, sTemp, sizeof(sTemp));

		if( strncmp(sTemp, "trigger_", 8) == 0 )
			return false;
	}

	// Hit non-client target
	return entity == 0 || entity > MaxClients;
}  
